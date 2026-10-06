//! Bounded activity-file decoding, independently implemented from wire-format observations.
//!
//! Format references (not copied implementations): Gadgetbridge commit
//! a0948ee1cbc2a870f91d313f8e37df5f524465f7, Xiaomi activity parsers; my-band
//! commit 56a8109bff3760bf05ba06c19e26ce2c51f6eea8, PacketParser files.
//! These layouts have not yet been validated against this user's Band 9.
//! CRC checks integrity, not authenticity. No consume/delete acknowledgement is emitted.

use serde::Serialize;
use std::fmt;

const MAX_FILE: usize = 4 * 1024 * 1024;
const MAX_CHUNKS: u16 = 4096;
const MIN_TIME: u64 = 946_684_800; // 2000-01-01 UTC
const MAX_TIME: u64 = 4_102_444_800; // 2100-01-01 UTC
const MAX_SLEEP: u64 = 48 * 3600;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HealthError {
    Invalid(&'static str),
    Unsupported(&'static str),
}
impl fmt::Display for HealthError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid(s) => write!(f, "invalid activity data: {s}"),
            Self::Unsupported(s) => write!(f, "unsupported activity data: {s}"),
        }
    }
}
impl std::error::Error for HealthError {}
type Result<T> = std::result::Result<T, HealthError>;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ActivityFileId {
    pub hex: String,
    pub timestamp: u64,
    pub timezone_quarters: i8,
    pub version: u8,
    pub file_type: u8,
    pub subtype: u8,
    pub detail_type: u8,
}
impl ActivityFileId {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        if bytes.len() != 7 {
            return Err(HealthError::Invalid(
                "file identifier must have seven bytes",
            ));
        }
        let timestamp = u64::from(u32::from_le_bytes(bytes[..4].try_into().unwrap()));
        valid_time(timestamp)?;
        let timezone_quarters = bytes[4] as i8;
        if !(-48..=56).contains(&timezone_quarters) {
            return Err(HealthError::Invalid("timezone is outside UTC-12 to UTC+14"));
        }
        Ok(Self {
            hex: hex::encode(bytes),
            timestamp,
            timezone_quarters,
            version: bytes[5],
            file_type: bytes[6] >> 7,
            subtype: (bytes[6] & 0x7f) >> 2,
            detail_type: bytes[6] & 3,
        })
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct HealthFile {
    pub file_id: ActivityFileId,
    /// Entire CRC-verified file, including its ID, padding and trailing CRC.
    pub raw_hex: String,
    pub crc32: u32,
    pub parsed: HealthParseResult,
}
#[derive(Debug, Clone, Serialize)]
pub struct HealthParseResult {
    pub status: String,
    pub reason: Option<String>,
    pub records: Vec<HealthRecord>,
}
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct HealthRecord {
    pub id: String,
    pub kind: String,
    pub start_time: u64,
    pub end_time: u64,
    pub value: Option<f64>,
    pub unit: String,
    pub stage: Option<String>,
    /// daily_total is an alternative to minute samples, never an additional amount.
    pub aggregation: String,
    pub source_file_id: String,
}

/// One in-flight channel-5 transfer. Reset on disconnect or request timeout.
#[derive(Debug, Default)]
pub struct ActivityAssembler {
    total: u16,
    last_number: u16,
    last_start: usize,
    bytes: Vec<u8>,
}
pub type HealthAssembler = ActivityAssembler;
impl ActivityAssembler {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn reset(&mut self) {
        self.total = 0;
        self.last_number = 0;
        self.last_start = 0;
        self.bytes.clear();
    }
    /// chunk = total_count:u16LE, one_based_index:u16LE, fragment.
    /// Only a byte-identical retransmission of the last chunk is idempotent.
    pub fn push(&mut self, chunk: &[u8]) -> Result<Option<HealthFile>> {
        let result = self.push_inner(chunk);
        if result.is_err() {
            self.reset();
        }
        result
    }
    fn push_inner(&mut self, chunk: &[u8]) -> Result<Option<HealthFile>> {
        if !(5..=65_535).contains(&chunk.len()) {
            return Err(HealthError::Invalid("channel-5 chunk length"));
        }
        let total = u16::from_le_bytes([chunk[0], chunk[1]]);
        let number = u16::from_le_bytes([chunk[2], chunk[3]]);
        let data = &chunk[4..];
        if total == 0 || total > MAX_CHUNKS || number == 0 || number > total {
            return Err(HealthError::Invalid("channel-5 sequence bounds"));
        }
        if self.total == 0 {
            if number != 1 {
                return Err(HealthError::Invalid("transfer did not start at chunk one"));
            }
            self.total = total;
        } else if total != self.total {
            return Err(HealthError::Invalid("chunk count changed during transfer"));
        } else if number == self.last_number {
            return if &self.bytes[self.last_start..] == data {
                Ok(None)
            } else {
                Err(HealthError::Invalid("retransmitted chunk changed"))
            };
        } else if number != self.last_number + 1 {
            return Err(HealthError::Invalid("missing or out-of-order chunk"));
        }
        if self.bytes.len() + data.len() > MAX_FILE {
            return Err(HealthError::Invalid("activity file exceeds size limit"));
        }
        self.last_start = self.bytes.len();
        self.bytes.extend_from_slice(data);
        self.last_number = number;
        if number != total {
            return Ok(None);
        }
        let file = parse_health_file(&self.bytes);
        self.reset();
        file.map(Some)
    }
}

/// IEEE CRC-32 (ISO-HDLC), stored as a little-endian u32 at the end of a file.
pub fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = u32::MAX;
    for &byte in bytes {
        crc ^= u32::from(byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xedb8_8320 & 0_u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}

pub fn parse_health_file(bytes: &[u8]) -> Result<HealthFile> {
    if !(12..=MAX_FILE).contains(&bytes.len()) {
        return Err(HealthError::Invalid("complete file length"));
    }
    let end = bytes.len() - 4;
    let expected = u32::from_le_bytes(bytes[end..].try_into().unwrap());
    if crc32(&bytes[..end]) != expected {
        return Err(HealthError::Invalid("CRC32 mismatch"));
    }
    let file_id = ActivityFileId::parse(&bytes[..7])?;
    let decoded = if bytes[7] != 0 {
        Err(HealthError::Unsupported("nonzero file-ID padding"))
    } else {
        decode(&file_id, &bytes[8..end])
    };
    let parsed = match decoded {
        Ok((records, reason)) => HealthParseResult {
            status: "supported".into(),
            reason,
            records,
        },
        Err(error) => HealthParseResult {
            status: match error {
                HealthError::Unsupported(_) => "unsupported",
                HealthError::Invalid(_) => "invalid",
            }
            .into(),
            reason: Some(error.to_string()),
            records: Vec::new(),
        },
    };
    Ok(HealthFile {
        file_id,
        raw_hex: hex::encode(bytes),
        crc32: expected,
        parsed,
    })
}
type Decoded = (Vec<HealthRecord>, Option<String>);
fn decode(id: &ActivityFileId, body: &[u8]) -> Result<Decoded> {
    if id.file_type != 0 {
        return Err(HealthError::Unsupported("sports file"));
    }
    match (id.subtype, id.detail_type) {
        (0, 0) => daily(id, body),
        (0, 1) => summary(id, body),
        (6, 0) => manual(id, body),
        (3, 0) => sleep_transitions(id, body),
        (8, 0 | 1) => sleep_details(id, body),
        _ => Err(HealthError::Unsupported(
            "activity subtype/detail combination",
        )),
    }
}
fn valid_time(time: u64) -> Result<()> {
    if !(MIN_TIME..MAX_TIME).contains(&time) {
        Err(HealthError::Invalid("timestamp outside 2000-2100"))
    } else {
        Ok(())
    }
}
fn finish_time(start: u64, duration: u64) -> Result<u64> {
    let end = start
        .checked_add(duration)
        .ok_or(HealthError::Invalid("time overflow"))?;
    valid_time(start)?;
    valid_time(end)?;
    Ok(end)
}
fn record(
    id: &ActivityFileId,
    kind: &str,
    times: (u64, u64),
    value: Option<f64>,
    unit: &str,
    aggregation: &str,
    stage: Option<&str>,
) -> HealthRecord {
    HealthRecord {
        id: format!(
            "{}:{}:{}:{}:{}:{}",
            id.hex,
            kind,
            times.0,
            times.1,
            aggregation,
            stage.unwrap_or("")
        ),
        kind: kind.into(),
        start_time: times.0,
        end_time: times.1,
        value,
        unit: unit.into(),
        stage: stage.map(str::to_owned),
        aggregation: aggregation.into(),
        source_file_id: id.hex.clone(),
    }
}
fn measurement(
    id: &ActivityFileId,
    kind: &str,
    time: u64,
    value: u8,
    records: &mut Vec<HealthRecord>,
    aggregation: &str,
) -> Result<()> {
    if value == 0 || value == 255 {
        return Ok(()); // documented missing-value sentinels
    }
    let (unit, maximum) = if kind == "spo2" {
        ("%", 100)
    } else {
        ("bpm", 254)
    };
    if value > maximum {
        return Err(HealthError::Invalid("sensor value outside encoded range"));
    }
    records.push(record(
        id,
        kind,
        (time, time),
        Some(f64::from(value)),
        unit,
        aggregation,
        None,
    ));
    Ok(())
}
struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
}
impl<'a> Reader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }
    fn left(&self) -> usize {
        self.data.len() - self.pos
    }
    fn take(&mut self, count: usize) -> Result<&'a [u8]> {
        if count > self.left() {
            return Err(HealthError::Invalid("truncated binary field"));
        }
        let result = &self.data[self.pos..self.pos + count];
        self.pos += count;
        Ok(result)
    }
    fn byte(&mut self) -> Result<u8> {
        Ok(self.take(1)?[0])
    }
    fn short(&mut self) -> Result<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }
    fn word(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }
}
fn group(reader: &mut Reader<'_>, header: &[u8], index: usize, width: usize) -> Result<(u8, u16)> {
    let byte = *header
        .get(index / 2)
        .ok_or(HealthError::Invalid("group header exhausted"))?;
    let flags = if index.is_multiple_of(2) {
        byte >> 4
    } else {
        byte & 15
    };
    let value = if flags & 8 == 0 {
        0
    } else if width == 2 {
        reader.short()?
    } else {
        u16::from(reader.byte()?)
    };
    Ok((if flags & 8 == 0 { 0 } else { flags }, value))
}
fn daily(id: &ActivityFileId, body: &[u8]) -> Result<Decoded> {
    let header_len = match id.version {
        1 | 2 => 4,
        3 => 5,
        4 => 6,
        _ => return Err(HealthError::Unsupported("daily details version")),
    };
    let mut r = Reader::new(body);
    let header = r.take(header_len)?;
    let mut records = Vec::new();
    let mut minute = 0_u64;
    while r.left() > 0 {
        if minute >= 2880 {
            return Err(HealthError::Invalid("daily details exceed 48 hours"));
        }
        let before = r.pos;
        let start = finish_time(id.timestamp, minute * 60)?;
        let end = finish_time(start, 60)?;
        let (flags, steps) = group(&mut r, header, 0, 2)?;
        if flags & 2 != 0 && steps & 0x4000 != 0 {
            return Err(HealthError::Unsupported(
                "daily extra-entry layout needs device verification",
            ));
        }
        if flags & 1 != 0 {
            records.push(record(
                id,
                "steps",
                (start, end),
                Some(f64::from(steps & 0x3fff)),
                "count",
                "minute",
                None,
            ));
        }
        let (flags, calories) = group(&mut r, header, 1, 1)?;
        if flags & 2 != 0 {
            records.push(record(
                id,
                "active_calories",
                (start, end),
                Some(f64::from(calories & 63)),
                "kcal",
                "minute",
                None,
            ));
        }
        group(&mut r, header, 2, 1)?;
        let (flags, distance) = group(&mut r, header, 3, 2)?;
        if flags & 4 != 0 {
            records.push(record(
                id,
                "distance",
                (start, end),
                Some(f64::from(distance)),
                "m",
                "minute",
                None,
            ));
        }
        let (flags, hr) = group(&mut r, header, 4, 1)?;
        if flags & 4 != 0 {
            measurement(id, "heart_rate", start, hr as u8, &mut records, "minute")?;
        }
        group(&mut r, header, 5, 1)?;
        group(&mut r, header, 6, 2)?;
        if id.version >= 3 {
            let (flags, spo2) = group(&mut r, header, 7, 1)?;
            if flags & 4 != 0 {
                measurement(id, "spo2", start, spo2 as u8, &mut records, "minute")?;
            }
            group(&mut r, header, 8, 1)?;
        }
        if id.version >= 4 {
            group(&mut r, header, 9, 2)?;
            group(&mut r, header, 10, 2)?;
        }
        if r.pos == before {
            return Err(HealthError::Invalid("daily record has no encoded fields"));
        }
        minute += 1;
    }
    Ok((records, Some("Distance/meters and calories/kcal follow the reference layout; device validation is pending. Minute and daily_total amounts are alternatives.".into())))
}
fn summary(id: &ActivityFileId, body: &[u8]) -> Result<Decoded> {
    let header_len = match id.version {
        3 => 3,
        5 => 4,
        _ => return Err(HealthError::Unsupported("daily summary version")),
    };
    let mut r = Reader::new(body);
    r.take(header_len)?;
    let data = r.take(41)?; // complete known core, not the shorter unsafe 30-byte guard
    let steps = i32::from_le_bytes(data[..4].try_into().unwrap());
    let calories = i16::from_le_bytes(data[25..27].try_into().unwrap());
    if steps < 0 || calories < 0 {
        return Err(HealthError::Invalid("negative daily total"));
    }
    let end = finish_time(id.timestamp, 86400)?;
    Ok((vec![
        record(id, "steps", (id.timestamp,end), Some(f64::from(steps)), "count", "daily_total", None),
        record(id, "active_calories", (id.timestamp,end), Some(f64::from(calories)), "kcal", "daily_total", None),
    ], Some("Daily totals are alternatives to minute samples. Summary averages are not emitted as point measurements; opaque trailing fields remain in raw_hex.".into())))
}
fn manual(id: &ActivityFileId, body: &[u8]) -> Result<Decoded> {
    if id.version != 2 {
        return Err(HealthError::Unsupported("manual measurement version"));
    }
    let mut r = Reader::new(body);
    let mut records = Vec::new();
    let mut count = 0;
    while r.left() > 0 {
        count += 1;
        if count > 65_536 {
            return Err(HealthError::Invalid("too many manual measurements"));
        }
        let timestamp = u64::from(r.word()?);
        valid_time(timestamp)?;
        match r.byte()? {
            0x11 => measurement(
                id,
                "heart_rate",
                timestamp,
                r.byte()?,
                &mut records,
                "measurement",
            )?,
            0x12 => measurement(
                id,
                "spo2",
                timestamp,
                r.byte()?,
                &mut records,
                "measurement",
            )?,
            0x13 => {
                r.byte()?;
            }
            0x44 => {
                r.take(4)?;
            }
            _ => {
                return Err(HealthError::Unsupported(
                    "manual measurement type has unknown width",
                ))
            }
        }
    }
    Ok((records, None))
}
fn sleep_window(bed: u64, wake: u64) -> Result<()> {
    valid_time(bed)?;
    valid_time(wake)?;
    if wake <= bed || wake - bed > MAX_SLEEP {
        return Err(HealthError::Invalid("sleep window must be within 48 hours"));
    }
    Ok(())
}
fn sleep_record(id: &ActivityFileId, start: u64, end: u64, stage: &str) -> HealthRecord {
    record(
        id,
        "sleep",
        (start, end),
        None,
        "stage",
        "sleep_interval",
        Some(stage),
    )
}
fn sleep_transitions(id: &ActivityFileId, body: &[u8]) -> Result<Decoded> {
    if id.version != 2 {
        return Err(HealthError::Unsupported("sleep transitions version"));
    }
    let mut r = Reader::new(body);
    r.take(7)?;
    let duration = r.short()? as i16;
    let bed = u64::from(r.word()?);
    let wake = u64::from(r.word()?);
    sleep_window(bed, wake)?;
    if !(0..=2880).contains(&duration) {
        return Err(HealthError::Invalid("sleep summary duration"));
    }
    r.take(3)?;
    for _ in 0..4 {
        if r.short()? > 2880 {
            return Err(HealthError::Invalid("sleep stage summary duration"));
        }
    }
    r.take(1)?;
    if !r.left().is_multiple_of(5) {
        return Err(HealthError::Invalid("partial sleep transition"));
    }
    if r.left() / 5 > 16_384 {
        return Err(HealthError::Invalid("too many sleep transitions"));
    }
    let mut events = Vec::new();
    while r.left() > 0 {
        let time = u64::from(r.word()?);
        let phase = r.byte()?;
        if time < bed.saturating_sub(6 * 3600) || time > wake || phase > 5 {
            return Err(HealthError::Invalid(
                "sleep transition outside known window or phase range",
            ));
        }
        valid_time(time)?;
        if events.last().is_some_and(|&(last, _)| last >= time) {
            return Err(HealthError::Invalid(
                "sleep transitions are not strictly increasing",
            ));
        }
        events.push((time, phase));
    }
    let mut records = Vec::new();
    for (index, &(time, phase)) in events.iter().enumerate() {
        let end = events.get(index + 1).map_or(wake, |e| e.0);
        let stage = match phase {
            2 => "deep",
            3 => "light",
            4 => "rem",
            5 => "awake",
            _ => continue,
        };
        if end > time {
            records.push(sleep_record(id, time, end, stage));
        }
    }
    Ok(sleep_result(records))
}
fn sleep_result(records: Vec<HealthRecord>) -> Decoded {
    let reason = if records.is_empty() {
        "No explicit sleep stages; summary durations are retained only in raw_hex and are never turned into an invented timeline."
    } else {
        "Only explicit sleep stages are emitted. Sleep HR/SpO2 sections remain raw because reference header layouts disagree."
    };
    (records, Some(reason.into()))
}
fn sleep_details(id: &ActivityFileId, body: &[u8]) -> Result<Decoded> {
    if !(1..=5).contains(&id.version) {
        return Err(HealthError::Unsupported("sleep details version"));
    }
    // The references disagree about section-mask indexes. Accept only a structurally
    // complete layout; if both parse, their explicit stage timelines must agree.
    let modern = sleep_layout(id, body, false);
    if id.version == 5 {
        return modern.map(sleep_result);
    }
    let legacy = sleep_layout(id, body, true);
    match (legacy, modern) {
        (Ok(a), Ok(b)) if a == b => Ok(sleep_result(a)),
        (Ok(_), Ok(_)) => Err(HealthError::Unsupported(
            "ambiguous sleep header produces different timelines",
        )),
        (Ok(a), Err(_)) | (Err(_), Ok(a)) => Ok(sleep_result(a)),
        (Err(a), Err(_)) => Err(a),
    }
}
fn sleep_layout(id: &ActivityFileId, body: &[u8], legacy: bool) -> Result<Vec<HealthRecord>> {
    let mut r = Reader::new(body);
    let header = r.take(if id.version == 5 { 2 } else { 1 })?;
    let flag = |index: usize| {
        header
            .get(index / 8)
            .is_some_and(|b| b & (0x80 >> (index % 8)) != 0)
    };
    if r.byte()? > 1 {
        return Err(HealthError::Invalid("sleep awake flag"));
    }
    let bed = u64::from(r.word()?);
    let wake = u64::from(r.word()?);
    sleep_window(bed, wake)?;
    if id.version >= 4 && (legacy || flag(3)) {
        r.byte()?;
    }
    if id.version == 5 {
        r.take(17)?;
    }
    let index = if id.version == 5 {
        9
    } else if id.version >= 4 {
        4
    } else {
        3
    } - usize::from(legacy);
    for (field, width) in [(0, 1), (1, 1), (2, 4)] {
        if field == 2 && id.version < 3 {
            continue;
        }
        if !flag(index + field) {
            continue;
        }
        let unit = r.short()?;
        let count = usize::from(r.short()?);
        if count > 0 {
            if count > 10_000 || unit == 0 {
                return Err(HealthError::Invalid("sleep sensor section bounds"));
            }
            if id.version >= 2 {
                r.word()?;
            } // time interpretation also differs; do not emit measurements
            r.take(count * width)?;
        }
    }
    let mut records = Vec::new();
    let mut packets = 0;
    while r.left() > 0 {
        packets += 1;
        if packets > 8192 {
            return Err(HealthError::Invalid("too many sleep packets"));
        }
        if r.take(4)? != [0xfb, 0xfa, 0xfc, 0xff] || r.byte()? != 17 {
            return Err(HealthError::Invalid("sleep packet magic/header length"));
        }
        let time = u64::from_le_bytes(r.take(8)?.try_into().unwrap());
        r.byte()?;
        let kind = r.byte()?;
        let len = usize::from(u16::from_be_bytes(r.take(2)?.try_into().unwrap()));
        if matches!(kind, 2 | 3 | 9 | 12 | 13 | 14 | 15) {
            continue;
        }
        let payload = r.take(len)?;
        if kind != 16 && kind != 17 {
            continue;
        }
        valid_time(time)?;
        if kind == 16 {
            if len < 11 {
                return Err(HealthError::Invalid("truncated sleep summary packet"));
            }
            continue; // aggregate durations do not specify a timeline
        }
        if !len.is_multiple_of(2) {
            return Err(HealthError::Invalid("partial sleep stage word"));
        }
        let mut start = time;
        for bytes in payload.as_chunks::<2>().0 {
            let word = u16::from_be_bytes(*bytes);
            let phase = word >> 12;
            let minutes = u64::from(word & 0x0fff);
            if phase > 4 {
                return Err(HealthError::Unsupported("sleep stage code"));
            }
            let end = finish_time(start, minutes * 60)?;
            if start < bed.saturating_sub(6 * 3600) || end > wake || end - start > MAX_SLEEP {
                return Err(HealthError::Invalid("sleep stage outside session window"));
            }
            if end > start && phase != 4 {
                if records.len() >= 65_536 {
                    return Err(HealthError::Invalid("too many sleep intervals"));
                }
                let stage = ["awake", "light", "deep", "rem"][usize::from(phase)];
                records.push(sleep_record(id, start, end, stage));
            }
            start = end;
        }
    }
    records.sort_by_key(|record| (record.start_time, record.end_time));
    records.dedup();
    let mut merged: Vec<HealthRecord> = Vec::new();
    for next in records {
        if let Some(last) = merged.last_mut() {
            if next.start_time < last.end_time {
                if next.stage != last.stage {
                    return Err(HealthError::Invalid("conflicting overlapping sleep stages"));
                }
                let end = last.end_time.max(next.end_time);
                *last = sleep_record(id, last.start_time, end, last.stage.as_deref().unwrap());
                continue;
            }
        }
        merged.push(next);
    }
    Ok(merged)
}
