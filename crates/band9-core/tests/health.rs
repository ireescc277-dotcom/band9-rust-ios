//! Synthetic format fixtures. These are not recordings from a physical device.
use band9_core::health::{crc32, parse_health_file, ActivityAssembler, ActivityFileId};

const TIME: u32 = 1_700_000_000;

fn file(version: u8, subtype: u8, detail: u8, body: &[u8]) -> Vec<u8> {
    let mut bytes = TIME.to_le_bytes().to_vec();
    bytes.extend_from_slice(&[32, version, (subtype << 2) | detail, 0]);
    bytes.extend_from_slice(body);
    bytes.extend_from_slice(&crc32(&bytes).to_le_bytes());
    bytes
}
fn chunk(total: u16, number: u16, data: &[u8]) -> Vec<u8> {
    let mut bytes = total.to_le_bytes().to_vec();
    bytes.extend_from_slice(&number.to_le_bytes());
    bytes.extend_from_slice(data);
    bytes
}
fn measurement(time: u32, kind: u8, value: u8) -> Vec<u8> {
    let mut bytes = time.to_le_bytes().to_vec();
    bytes.extend_from_slice(&[kind, value]);
    bytes
}
fn sleep_header(version: u8, duration: u32) -> Vec<u8> {
    let mut body = vec![0; if version == 5 { 2 } else { 1 }];
    body.push(0);
    body.extend_from_slice(&TIME.to_le_bytes());
    body.extend_from_slice(&(TIME + duration).to_le_bytes());
    if version == 5 {
        body.extend_from_slice(&[0; 17]);
    }
    body
}
fn sleep_packet(time: u32, kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut bytes = vec![0xfb, 0xfa, 0xfc, 0xff, 17];
    bytes.extend_from_slice(&u64::from(time).to_le_bytes());
    bytes.extend_from_slice(&[0, kind]);
    bytes.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    bytes.extend_from_slice(payload);
    bytes
}

#[test]
fn crc_matches_independent_standard_check_vector() {
    assert_eq!(crc32(b"123456789"), 0xcbf4_3926);
    assert_eq!(crc32(b""), 0);
}

#[test]
fn file_id_has_exact_length_and_checked_timezone_and_time() {
    let bytes = file(4, 8, 1, &[]);
    let id = ActivityFileId::parse(&bytes[..7]).unwrap();
    assert_eq!((id.timestamp, id.timezone_quarters), (u64::from(TIME), 32));
    assert_eq!(
        (id.version, id.file_type, id.subtype, id.detail_type),
        (4, 0, 8, 1)
    );
    assert!(ActivityFileId::parse(&bytes[..6]).is_err());
    let mut bad = bytes[..7].to_vec();
    bad[4] = 57;
    assert!(ActivityFileId::parse(&bad).is_err());
    bad[4] = 32;
    bad[..4].fill(0);
    assert!(ActivityFileId::parse(&bad).is_err());
}

#[test]
fn assembly_is_ordered_crc_checked_and_last_retransmission_is_idempotent() {
    let bytes = file(2, 6, 0, &measurement(TIME, 0x11, 73));
    let a = chunk(3, 1, &bytes[..4]);
    let b = chunk(3, 2, &bytes[4..9]);
    let c = chunk(3, 3, &bytes[9..]);
    let mut assembler = ActivityAssembler::new();
    assert!(assembler.push(&a).unwrap().is_none());
    assert!(assembler.push(&a).unwrap().is_none());
    assert!(assembler.push(&b).unwrap().is_none());
    assert!(assembler.push(&b).unwrap().is_none());
    let complete = assembler.push(&c).unwrap().unwrap();
    assert_eq!(complete.raw_hex, hex::encode(&bytes));
    assert_eq!(complete.parsed.records[0].value, Some(73.0));
    assert!(assembler.push(&b).is_err());
    assert!(assembler.push(&chunk(1, 1, &bytes)).unwrap().is_some());
}

#[test]
fn sequence_errors_reset_and_never_mix_files() {
    let bytes = file(2, 6, 0, &measurement(TIME, 0x12, 97));
    let mut a = ActivityAssembler::new();
    a.push(&chunk(3, 1, &bytes[..7])).unwrap();
    assert!(a.push(&chunk(3, 3, &bytes[7..])).is_err());
    assert!(a.push(&chunk(3, 2, &bytes[7..])).is_err());
    a.push(&chunk(2, 1, &bytes[..7])).unwrap();
    assert!(a.push(&chunk(3, 2, &bytes[7..])).is_err());
    a.push(&chunk(2, 1, &bytes[..7])).unwrap();
    assert!(a.push(&chunk(2, 1, &[1; 7])).is_err());
    a.push(&chunk(2, 1, &bytes[..7])).unwrap();
    a.reset();
    assert!(a.push(&chunk(2, 2, &bytes[7..])).is_err());
    assert!(a.push(&chunk(0, 0, &[1])).is_err());
    assert!(a.push(&chunk(4097, 1, &[1])).is_err());
}

#[test]
fn corrupted_files_never_emit_records() {
    let mut bytes = file(2, 6, 0, &measurement(TIME, 0x11, 73));
    bytes[9] ^= 1;
    assert!(parse_health_file(&bytes).is_err());
    let mut a = ActivityAssembler::new();
    assert!(a.push(&chunk(1, 1, &bytes)).is_err());
}

#[test]
fn unknown_versions_and_invalid_bodies_preserve_complete_raw_file() {
    let unknown = file(99, 0, 0, &[3, 4, 5]);
    let parsed = parse_health_file(&unknown).unwrap();
    assert_eq!(parsed.parsed.status, "unsupported");
    assert_eq!(parsed.raw_hex, hex::encode(unknown));
    assert!(parsed.parsed.records.is_empty());
    let truncated = file(2, 6, 0, &[1, 2]);
    let parsed = parse_health_file(&truncated).unwrap();
    assert_eq!(parsed.parsed.status, "invalid");
    assert_eq!(parsed.raw_hex, hex::encode(truncated));
    assert!(parsed.parsed.records.is_empty());
}

#[test]
fn v4_daily_nibble_layout_produces_five_metrics_per_minute() {
    // g0 steps, g1 calorie low 6 bits, g3 distance, g4 HR, g7 SpO2.
    // All other groups have present bits clear, including optional v4 fields.
    let mut body = vec![0xfa, 0x0c, 0xc0, 0x0c, 0x00, 0x00];
    for (steps, calories, distance, hr, spo2) in [(81_u16, 3, 62_u16, 73, 98), (0, 0, 0, 0, 255)] {
        body.extend_from_slice(&steps.to_le_bytes());
        body.push(calories);
        body.extend_from_slice(&distance.to_le_bytes());
        body.extend_from_slice(&[hr, spo2]);
    }
    let result = parse_health_file(&file(4, 0, 0, &body)).unwrap();
    assert_eq!(
        result.parsed.status, "supported",
        "{:?}",
        result.parsed.reason
    );
    let records = result.parsed.records;
    assert_eq!(records.len(), 8); // missing-value sensors do not become zero measurements
    assert_eq!(records[0].kind, "steps");
    assert_eq!(records[0].value, Some(81.0));
    assert_eq!(records[1].value, Some(3.0));
    assert_eq!(records[2].unit, "m");
    assert_eq!(records[2].value, Some(62.0));
    assert_eq!(records[3].value, Some(73.0));
    assert_eq!(records[4].value, Some(98.0));
    assert_eq!(records[5].start_time, u64::from(TIME + 60));
    assert_eq!(records[5].value, Some(0.0));
}

#[test]
fn daily_truncation_and_ambiguous_extra_entry_are_not_partially_decoded() {
    let mut body = vec![0xf0, 0, 0, 0];
    body.extend_from_slice(&10_u16.to_le_bytes());
    body.push(4); // incomplete next minute
    let parsed = parse_health_file(&file(1, 0, 0, &body)).unwrap();
    assert_eq!(parsed.parsed.status, "invalid");
    assert!(parsed.parsed.records.is_empty());
    let body = [0xf0, 0, 0, 0, 1, 0x40];
    let parsed = parse_health_file(&file(2, 0, 0, &body)).unwrap();
    assert_eq!(parsed.parsed.status, "unsupported");
    let parsed = parse_health_file(&file(1, 0, 0, &[0, 0, 0, 0, 1])).unwrap();
    assert_eq!(parsed.parsed.status, "invalid");
}

#[test]
fn summaries_expose_totals_without_fabricating_sensor_measurements() {
    for (version, header_size) in [(3, 3), (5, 4)] {
        let mut body = vec![0; header_size + 53];
        body[header_size..header_size + 4].copy_from_slice(&4321_i32.to_le_bytes());
        body[header_size + 25..header_size + 27].copy_from_slice(&123_i16.to_le_bytes());
        body[header_size + 18] = 68; // HR average is not a measured point
        body[header_size + 40] = 98; // SpO2 average likewise
        let result = parse_health_file(&file(version, 0, 1, &body)).unwrap();
        assert_eq!(result.parsed.status, "supported");
        assert_eq!(result.parsed.records.len(), 2);
        assert_eq!(result.parsed.records[0].value, Some(4321.0));
        assert_eq!(result.parsed.records[1].value, Some(123.0));
        assert_eq!(result.parsed.records[0].aggregation, "daily_total");
        assert_eq!(result.parsed.records[0].end_time, u64::from(TIME) + 86400);
    }
}

#[test]
fn manual_samples_respect_type_width_time_and_value_bounds() {
    let mut body = measurement(TIME, 0x11, 71);
    body.extend(measurement(TIME + 30, 0x12, 96));
    body.extend(measurement(TIME + 31, 0x13, 20));
    body.extend_from_slice(&(TIME + 32).to_le_bytes());
    body.extend_from_slice(&[0x44, 0, 0, 0, 0]);
    let result = parse_health_file(&file(2, 6, 0, &body)).unwrap();
    assert_eq!(result.parsed.records.len(), 2);
    assert_eq!(result.parsed.records[1].kind, "spo2");
    assert_eq!(result.parsed.records[1].aggregation, "measurement");
    for (bad, status) in [
        (measurement(TIME, 0x12, 101), "invalid"),
        (measurement(0, 0x11, 71), "invalid"),
        (measurement(TIME, 0x77, 71), "unsupported"),
    ] {
        let result = parse_health_file(&file(2, 6, 0, &bad)).unwrap();
        assert_eq!(result.parsed.status, status);
        assert!(result.parsed.records.is_empty());
    }
}

#[test]
fn sleep_transition_events_define_intervals_and_unknown_phases_leave_gaps() {
    let mut body = vec![0; 7];
    body.extend_from_slice(&90_u16.to_le_bytes());
    body.extend_from_slice(&TIME.to_le_bytes());
    body.extend_from_slice(&(TIME + 7200).to_le_bytes());
    body.extend_from_slice(&[0; 3 + 8 + 1]);
    for (delta, phase) in [(0, 3), (1800, 2), (3600, 1), (5400, 4)] {
        body.extend_from_slice(&(TIME + delta).to_le_bytes());
        body.push(phase);
    }
    let result = parse_health_file(&file(2, 3, 0, &body)).unwrap();
    assert_eq!(result.parsed.status, "supported");
    let records = result.parsed.records;
    assert_eq!(records.len(), 3);
    assert_eq!(records[0].stage.as_deref(), Some("light"));
    assert_eq!(records[1].stage.as_deref(), Some("deep"));
    assert_eq!(records[2].stage.as_deref(), Some("rem"));
    assert_eq!(records[1].end_time, u64::from(TIME + 3600));
    assert_eq!(records[2].start_time, u64::from(TIME + 5400));
}

#[test]
fn sleep_duration_packets_decode_big_endian_words_and_preserve_unknown_sensor_sections() {
    for version in [2, 5] {
        let mut body = sleep_header(version, 3600);
        let payload = [0x10, 0x1e, 0x20, 0x14, 0x30, 0x0a]; // light30, deep20, REM10 minutes
        body.extend(sleep_packet(TIME, 17, &payload));
        let result = parse_health_file(&file(version, 8, 0, &body)).unwrap();
        assert_eq!(
            result.parsed.status, "supported",
            "{:?}",
            result.parsed.reason
        );
        let records = result.parsed.records;
        assert_eq!(records.len(), 3);
        assert_eq!(records[0].end_time, u64::from(TIME + 1800));
        assert_eq!(records[2].end_time, u64::from(TIME + 3600));
        assert_eq!(records[2].stage.as_deref(), Some("rem"));
        assert!(records.iter().all(|r| r.kind == "sleep"));
    }
}

#[test]
fn sleep_summary_alone_never_becomes_a_synthetic_timeline() {
    let mut body = sleep_header(2, 3600);
    body.extend(sleep_packet(
        TIME,
        16,
        &[0, 0, 60, 0, 0, 0, 30, 0, 10, 0, 20],
    ));
    let result = parse_health_file(&file(2, 8, 0, &body)).unwrap();
    assert_eq!(result.parsed.status, "supported");
    assert!(result.parsed.records.is_empty());
    assert!(result.parsed.reason.unwrap().contains("never"));
}

#[test]
fn conflicting_sleep_overlap_and_truncated_stage_words_fail_atomically() {
    let mut body = sleep_header(2, 3600);
    body.extend(sleep_packet(TIME, 17, &[0x10, 0x1e]));
    body.extend(sleep_packet(TIME + 600, 17, &[0x20, 0x1e]));
    let result = parse_health_file(&file(2, 8, 0, &body)).unwrap();
    assert_eq!(result.parsed.status, "invalid");
    assert!(result.parsed.records.is_empty());
    let mut body = sleep_header(2, 3600);
    body.extend(sleep_packet(TIME, 17, &[0x10]));
    assert_eq!(
        parse_health_file(&file(2, 8, 0, &body))
            .unwrap()
            .parsed
            .status,
        "invalid"
    );
}

#[test]
fn serialized_contract_matches_health_file_event() {
    let result = parse_health_file(&file(2, 6, 0, &measurement(TIME, 0x11, 73))).unwrap();
    let json = serde_json::to_value(result).unwrap();
    assert!(json["file_id"]["hex"].is_string());
    assert!(json["raw_hex"].is_string());
    assert!(json["crc32"].is_u64());
    assert_eq!(json["parsed"]["status"], "supported");
    let record = &json["parsed"]["records"][0];
    for key in [
        "id",
        "kind",
        "start_time",
        "end_time",
        "value",
        "unit",
        "stage",
        "aggregation",
        "source_file_id",
    ] {
        assert!(record.get(key).is_some(), "missing {key}");
    }
}

#[test]
fn sleep_legacy_sensor_mask_is_skipped_without_emitting_guessed_measurements() {
    let mut body = sleep_header(2, 3600);
    body[0] = 0x20; // legacy HR section mask, different from the Swift reference
    body.extend_from_slice(&60_u16.to_le_bytes());
    body.extend_from_slice(&2_u16.to_le_bytes());
    body.extend_from_slice(&TIME.to_le_bytes());
    body.extend_from_slice(&[71, 72]);
    body.extend(sleep_packet(TIME, 17, &[0x10, 0x3c]));
    let result = parse_health_file(&file(2, 8, 0, &body)).unwrap();
    assert_eq!(result.parsed.status, "supported");
    assert_eq!(result.parsed.records.len(), 1);
    assert_eq!(result.parsed.records[0].kind, "sleep");
}

#[test]
fn every_truncated_manual_record_is_invalid_and_has_no_partial_results() {
    let complete = measurement(TIME, 0x11, 71);
    for cut in 1..complete.len() {
        let mut body = complete.clone();
        body.extend_from_slice(&complete[..cut]);
        let result = parse_health_file(&file(2, 6, 0, &body)).unwrap();
        assert_eq!(result.parsed.status, "invalid", "cut={cut}");
        assert!(result.parsed.records.is_empty());
    }
}

#[test]
fn transfer_has_finite_memory_and_resets_after_size_limit() {
    let mut assembler = ActivityAssembler::new();
    let data = vec![0; 65_531];
    for number in 1..=64 {
        assert!(assembler.push(&chunk(65, number, &data)).unwrap().is_none());
    }
    assert!(assembler.push(&chunk(65, 65, &data)).is_err());
    let good = file(2, 6, 0, &measurement(TIME, 0x11, 73));
    assert!(assembler.push(&chunk(1, 1, &good)).unwrap().is_some());
}
