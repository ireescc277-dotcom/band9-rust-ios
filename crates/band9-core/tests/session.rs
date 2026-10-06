//! These simulate both peers using public synthetic keys. They do not assert
//! that a particular Band 9 firmware exposes or accepts this BLE protocol.
use band9_core::{
    crypto::{ccm_decrypt, ctr_v2},
    frame::{self, Frame},
    proto::{self, Message},
    session::{Session, SessionOptions, SessionRequest, SessionUpdate},
};
use serde_json::{json, Value};

fn fixture() -> Value {
    serde_json::from_str(include_str!("fixtures/xiaomi-v2-synthetic-vectors.json")).unwrap()
}
fn val(name: &str) -> Vec<u8> {
    hex::decode(fixture()["auth"][name].as_str().unwrap()).unwrap()
}
fn options() -> SessionOptions {
    serde_json::from_value(json!({"key_hex":fixture()["auth"]["synthetic_auth_key"],"phone_nonce_hex":fixture()["auth"]["phone_nonce"],"mtu":512})).unwrap()
}
fn frames(update: &SessionUpdate) -> Vec<Frame> {
    let bytes: Vec<u8> = update
        .outbound
        .iter()
        .flat_map(|o| hex::decode(&o.hex).unwrap())
        .collect();
    frame::StreamDecoder::new(64512, 65536)
        .unwrap()
        .push(&bytes)
        .unwrap()
        .frames
}
fn peer(proto: &[u8], seq: u8, encrypted: bool) -> Vec<u8> {
    let mut body = vec![1, if encrypted { 2 } else { 1 }];
    body.extend(if encrypted {
        ctr_v2(&val("decryption_key"), proto).unwrap()
    } else {
        proto.to_vec()
    });
    frame::build_frame(3, seq, &body).unwrap()
}
fn watch_nonce() -> Vec<u8> {
    let mut watch = Vec::new();
    proto::bytes(&mut watch, 1, &val("watch_nonce"));
    proto::bytes(&mut watch, 2, &val("expected_watch_hmac"));
    let mut auth = Vec::new();
    proto::bytes(&mut auth, 31, &watch);
    proto::command(1, 26, Some((3, &auth)))
}
fn negotiated(session: &mut Session) -> SessionUpdate {
    let start = session.start(0);
    assert_eq!(start.state, "negotiating");
    let mut config = frame::parse_frame(&frame::SessionConfig::default().build(), 64512).unwrap();
    config.payload[0] = 2;
    session.receive(&config.encode().unwrap(), 1)
}
fn authenticate(session: &mut Session) -> SessionUpdate {
    let nonce = negotiated(session);
    assert_eq!(nonce.state, "awaiting_nonce");
    let proof = session.receive(&peer(&watch_nonce(), 50, false), 2);
    assert_eq!(proof.state, "awaiting_auth");
    let result = session.receive(&peer(&proto::command(1, 27, None), 51, false), 3);
    assert_eq!(result.state, "ready");
    assert!(result.events.iter().any(|e| e.kind == "authenticated"));
    result
}
fn ready() -> Session {
    let mut session = Session::new(options()).unwrap();
    authenticate(&mut session);
    let mut info = Vec::new();
    proto::bytes(&mut info, 1, b"SYNTHETIC");
    proto::bytes(&mut info, 2, b"0.0-test");
    proto::bytes(&mut info, 4, b"synthetic watch");
    let mut system = Vec::new();
    proto::bytes(&mut system, 3, &info);
    let update = session.receive(
        &peer(&proto::command(2, 2, Some((4, &system))), 52, true),
        4,
    );
    assert!(update.events.iter().any(|e| e.kind == "device_info"));
    let update = session.receive(&peer(&battery(0), 53, true), 5);
    assert_eq!(
        update
            .events
            .iter()
            .find(|e| e.kind == "battery")
            .unwrap()
            .data["percent"],
        0
    );
    session
}
fn battery(percent: u32) -> Vec<u8> {
    let mut battery = Vec::new();
    proto::uint(&mut battery, 1, percent);
    proto::uint(&mut battery, 2, 0);
    let mut power = Vec::new();
    proto::bytes(&mut power, 1, &battery);
    let mut system = Vec::new();
    proto::bytes(&mut system, 2, &power);
    proto::command(2, 1, Some((4, &system)))
}
fn list(subtype: u32, ids: &[u8]) -> Vec<u8> {
    let mut health = Vec::new();
    proto::bytes(&mut health, 2, ids);
    proto::command(8, subtype, Some((10, &health)))
}

#[test]
fn full_handshake_proves_correct_nonce_hmac_ccm_and_explicit_confirmation() {
    let mut session = Session::new(options()).unwrap();
    let nonce = negotiated(&mut session);
    let outgoing = frames(&nonce);
    assert_eq!(outgoing[0].sequence, 0);
    let cmd = Message::parse(outgoing[0].data().unwrap().bytes).unwrap();
    assert_eq!(cmd.uint(1).unwrap(), Some(1));
    assert_eq!(cmd.uint(2).unwrap(), Some(26));
    assert_eq!(
        session.receive(&frame::build_ack(0), 2).state,
        "awaiting_nonce"
    );
    let proof = session.receive(&peer(&watch_nonce(), 50, false), 3);
    let outgoing = frames(&proof);
    assert_eq!(outgoing[0].packet_type(), 1);
    assert_eq!(outgoing[1].sequence, 1);
    let cmd = Message::parse(outgoing[1].data().unwrap().bytes).unwrap();
    let auth = cmd.nested(3).unwrap().unwrap();
    let step = auth.nested(32).unwrap().unwrap();
    assert_eq!(
        step.bytes(1).unwrap().unwrap(),
        val("phone_hmac_encryptedNonces_field")
    );
    let info = ccm_decrypt(
        &val("encryption_key"),
        &val("auth_ccm_nonce"),
        step.bytes(2).unwrap().unwrap(),
    )
    .unwrap();
    let parsed = Message::parse(&info).unwrap();
    assert_eq!(parsed.uint(1).unwrap(), Some(1));
    assert_eq!(parsed.text(3).unwrap().as_deref(), Some("iPhone"));
    assert_eq!(
        session.receive(&frame::build_ack(1), 4).state,
        "awaiting_auth"
    );
    let success = session.receive(&peer(&proto::command(1, 27, None), 51, false), 5);
    assert_eq!(success.state, "ready");
    assert!(success.events.iter().any(|e| e.kind == "authenticated"));
}

#[test]
fn rejects_bad_hmac_and_out_of_order_auth_does_not_authenticate() {
    let mut session = Session::new(options()).unwrap();
    negotiated(&mut session);
    let unexpected = session.receive(&peer(&proto::command(1, 27, None), 20, false), 2);
    assert_eq!(unexpected.state, "awaiting_nonce");
    let mut bad = watch_nonce();
    *bad.last_mut().unwrap() ^= 1;
    let rejected = session.receive(&peer(&bad, 21, false), 3);
    assert_eq!(rejected.state, "failed");
    assert!(rejected.error.is_some());
    assert!(!rejected.events.iter().any(|e| e.kind == "authenticated"));
}

#[test]
fn rejection_status_does_not_become_auth_success() {
    let mut session = Session::new(options()).unwrap();
    negotiated(&mut session);
    session.receive(&peer(&watch_nonce(), 20, false), 2);
    let mut response = proto::command(1, 27, None);
    proto::uint(&mut response, 100, 5);
    assert_eq!(
        session.receive(&peer(&response, 21, false), 3).state,
        "failed"
    );
}

#[test]
fn ack_retry_preserves_frame_and_sequence_and_is_bounded() {
    let mut session = Session::new(options()).unwrap();
    let first = session.start(0);
    assert_eq!(frames(&session.tick(10_000)), frames(&first));
    assert_eq!(frames(&session.tick(20_000)), frames(&first));
    let failed = session.tick(30_000);
    assert_eq!(failed.state, "failed");
    assert!(failed.outbound.is_empty());
    assert!(session.start(30_001).error.is_some());
}

#[test]
fn semantic_timeout_after_ack_uses_a_fresh_sequence() {
    let mut session = ready();
    let outgoing = session.request(SessionRequest::Battery, 6);
    let seq = frames(&outgoing)[0].sequence;
    session.receive(&frame::build_ack(seq), 7);
    assert!(session.tick(10_007).outbound.is_empty());
    let retry = session.tick(30_006);
    assert_eq!(frames(&retry)[0].sequence, seq.wrapping_add(1));
}

#[test]
fn duplicate_packets_are_reacked_without_duplicate_commands() {
    let mut session = Session::new(options()).unwrap();
    negotiated(&mut session);
    let watch = peer(&watch_nonce(), 20, false);
    let first = session.receive(&watch, 2);
    assert_eq!(frames(&first).len(), 2);
    let duplicate = session.receive(&watch, 3);
    let response = frames(&duplicate);
    assert_eq!(response.len(), 1);
    assert_eq!(response[0].packet_type(), 1);
}

#[test]
fn small_mtu_splits_frames_without_reordering_bytes() {
    let mut options = options();
    options.mtu = 3;
    let mut session = Session::new(options).unwrap();
    let update = negotiated(&mut session);
    assert!(update.outbound.iter().all(|o| o.hex.len() <= 6));
    assert_eq!(frames(&update).len(), 1);
    let update = session.receive(&peer(&watch_nonce(), 50, false), 2);
    assert!(update.outbound.iter().all(|o| o.hex.len() <= 6));
    assert_eq!(frames(&update).len(), 2);
}

#[test]
fn health_lists_deduplicate_and_download_one_file_at_a_time() {
    let mut session = ready();
    session.request(SessionRequest::SyncHealth, 6);
    let id = [1, 2, 3, 4, 5, 6, 7];
    let mut duplicate = id.to_vec();
    duplicate.extend_from_slice(&id);
    let today = session.receive(&peer(&list(1, &duplicate), 54, true), 7);
    assert!(today.events.iter().any(|e| e.kind == "health_file_list"));
    let past = session.receive(&peer(&list(2, &id), 55, true), 8);
    let commands = frames(&past);
    assert_eq!(commands.len(), 2);
    let command = ctr_v2(&val("encryption_key"), commands[1].data().unwrap().bytes).unwrap();
    let parsed = Message::parse(&command).unwrap();
    assert_eq!(parsed.uint(1).unwrap(), Some(8));
    assert_eq!(parsed.uint(2).unwrap(), Some(3));
    assert_eq!(
        parsed
            .nested(10)
            .unwrap()
            .unwrap()
            .bytes(2)
            .unwrap()
            .unwrap(),
        id
    );
    assert!(session.tick(9).outbound.is_empty());
    let fake_completion = session.request(
        SessionRequest::FileReceived {
            file_id_hex: hex::encode(id),
        },
        10,
    );
    assert!(fake_completion.error.is_some());
}

#[test]
fn empty_directories_complete_sync_without_consuming_history() {
    let mut session = ready();
    let started = session.request(SessionRequest::SyncHealth, 6);
    assert!(started.events.iter().any(|e| e.kind == "sync_started"));
    session.receive(&peer(&list(1, &[]), 54, true), 7);
    let done = session.receive(&peer(&list(2, &[]), 55, true), 8);
    assert!(done.events.iter().any(|e| e.kind == "sync_complete"));
    assert!(frames(&done).iter().all(|f| f.packet_type() == 1));
}

#[test]
fn unsupported_channels_preserve_evidence_without_fabricating_records() {
    let mut session = ready();
    let data = frame::build_frame(3, 80, &[2, 1, 99]).unwrap();
    let update = session.receive(&data, 6);
    let event = update
        .events
        .iter()
        .find(|e| e.kind == "unsupported_channel")
        .unwrap();
    assert_eq!(event.data["hex"], "63");
    assert!(!update.events.iter().any(|e| e.kind == "health_file"));
}

#[test]
fn invalid_config_clock_and_plaintext_after_auth_are_rejected() {
    let mut invalid = options();
    invalid.key_hex = "ff".into();
    assert!(Session::new(invalid).is_err());
    let mut invalid = options();
    invalid.phone_nonce_hex = "00".into();
    assert!(Session::new(invalid).is_err());
    let mut invalid = options();
    invalid.mtu = 0;
    assert!(Session::new(invalid).is_err());
    let mut session = ready();
    assert!(session.tick(4).error.is_some());
    let update = session.receive(&peer(&battery(5), 70, false), 6);
    assert!(update.error.is_some());
    assert!(!update.events.iter().any(|e| e.kind == "battery"));
}

#[test]
fn pairing_prompt_allows_human_confirmation_and_late_nonce_does_not_restart_auth() {
    let mut session = Session::new(options()).unwrap();
    negotiated(&mut session);
    let prompt = session.receive(&peer(&proto::command(1, 16, None), 40, false), 2);
    assert!(prompt.events.iter().any(|e| e.kind == "pairing_required"));
    assert!(session.tick(60_000).outbound.is_empty());
    let proof = session.receive(&peer(&watch_nonce(), 41, false), 60_001);
    assert_eq!(proof.state, "awaiting_auth");
    let mut stale = watch_nonce();
    *stale.last_mut().unwrap() ^= 1;
    let late = session.receive(&peer(&stale, 42, false), 60_002);
    assert_eq!(late.state, "awaiting_auth");
    assert!(late.error.is_none());
    let confirmed = session.receive(&peer(&proto::command(1, 27, None), 43, false), 60_003);
    assert_eq!(confirmed.state, "ready");
}

#[test]
fn ready_peer_restart_requires_fresh_nonce_instead_of_reusing_old_keys() {
    let mut session = ready();
    let response = frame::build_frame(2, 0, &[2]).unwrap();
    let update = session.receive(&response, 6);
    assert_eq!(update.state, "failed");
    assert!(update.events.iter().any(|e| e.kind == "reconnect_required"));
    assert!(session.start(7).error.is_some());
}

#[test]
fn session_reopened_after_pairing_requires_fresh_nonce_at_both_auth_stages() {
    for proof_sent in [false, true] {
        let mut session = Session::new(options()).unwrap();
        negotiated(&mut session);
        if proof_sent {
            assert_eq!(
                session.receive(&peer(&watch_nonce(), 39, false), 2).state,
                "awaiting_auth"
            );
        }
        let prompt = session.receive(&peer(&proto::command(1, 16, None), 40, false), 3);
        assert!(prompt.events.iter().any(|e| e.kind == "pairing_required"));
        let response = frame::build_frame(2, 0, &[2]).unwrap();
        let update = session.receive(&response, 4);
        assert_eq!(update.state, "failed");
        let event = update
            .events
            .iter()
            .find(|e| e.kind == "reconnect_required")
            .unwrap();
        assert_eq!(event.data["fresh_nonce_required"], true);
        assert!(update.outbound.is_empty());
        assert!(session.start(5).error.is_some());
        assert!(session
            .receive(&peer(&watch_nonce(), 41, false), 6)
            .error
            .is_some());
        assert!(session.tick(120_000).outbound.is_empty());
    }
}

#[test]
fn ordinary_duplicate_session_accept_does_not_restart_an_active_handshake() {
    let mut session = Session::new(options()).unwrap();
    negotiated(&mut session);
    let response = frame::build_frame(2, 0, &[2]).unwrap();
    let duplicate = session.receive(&response, 2);
    assert_eq!(duplicate.state, "awaiting_nonce");
    assert!(duplicate.outbound.is_empty());
    assert!(duplicate.error.is_none());
    assert!(!duplicate
        .events
        .iter()
        .any(|e| e.kind == "reconnect_required"));
    assert_eq!(
        session.receive(&peer(&watch_nonce(), 40, false), 3).state,
        "awaiting_auth"
    );
    let duplicate = session.receive(&response, 4);
    assert_eq!(duplicate.state, "awaiting_auth");
    assert!(duplicate.outbound.is_empty());
    assert!(duplicate.error.is_none());
    assert!(!duplicate
        .events
        .iter()
        .any(|e| e.kind == "reconnect_required"));
    assert_eq!(
        session
            .receive(&peer(&proto::command(1, 27, None), 41, false), 5)
            .state,
        "ready"
    );
}

fn unknown_file(timestamp: u32) -> Vec<u8> {
    let mut raw = timestamp.to_le_bytes().to_vec();
    raw.extend_from_slice(&[32, 99, 0, 0]);
    raw.extend_from_slice(&band9_core::health::crc32(&raw).to_le_bytes());
    raw
}
fn activity(raw: &[u8], seq: u8) -> Vec<u8> {
    let mut chunk = vec![1, 0, 1, 0];
    chunk.extend_from_slice(raw);
    let mut payload = vec![5, 2];
    payload.extend(ctr_v2(&val("decryption_key"), &chunk).unwrap());
    frame::build_frame(3, seq, &payload).unwrap()
}

#[test]
fn completed_crc_verified_files_are_emitted_and_next_file_starts_serially() {
    let mut session = ready();
    session.request(SessionRequest::SyncHealth, 6);
    let first = unknown_file(1_700_000_000);
    let second = unknown_file(1_700_000_001);
    let mut ids = first[..7].to_vec();
    ids.extend_from_slice(&second[..7]);
    session.receive(&peer(&list(1, &ids), 54, true), 7);
    session.receive(&peer(&list(2, &[]), 55, true), 8);
    let one = session.receive(&activity(&first, 56), 9);
    let file = one.events.iter().find(|e| e.kind == "health_file").unwrap();
    assert_eq!(file.data["raw_hex"], hex::encode(&first));
    assert_eq!(file.data["parsed"]["status"], "unsupported");
    let outgoing = frames(&one);
    assert_eq!(outgoing.len(), 2);
    let plain = ctr_v2(&val("encryption_key"), outgoing[1].data().unwrap().bytes).unwrap();
    let command = Message::parse(&plain).unwrap();
    assert_eq!(command.uint(2).unwrap(), Some(3));
    assert_eq!(
        command
            .nested(10)
            .unwrap()
            .unwrap()
            .bytes(2)
            .unwrap()
            .unwrap(),
        &second[..7]
    );
    let two = session.receive(&activity(&second, 57), 10);
    assert!(two.events.iter().any(|e| e.kind == "health_file"));
    assert!(two.events.iter().any(|e| e.kind == "sync_complete"));
    assert!(frames(&two).iter().all(|f| f.packet_type() == 1)); // No history-consumption command.
}

#[test]
fn wrong_file_identity_and_crc_never_emit_a_health_file() {
    let mut session = ready();
    let expected = unknown_file(1_700_000_000);
    session.request(
        SessionRequest::RequestFile {
            file_id_hex: hex::encode(&expected[..7]),
        },
        6,
    );
    let wrong = session.receive(&activity(&unknown_file(1_700_000_001), 54), 7);
    assert!(wrong.error.is_some());
    assert!(!wrong.events.iter().any(|e| e.kind == "health_file"));
    let mut corrupt = expected;
    corrupt[7] ^= 1;
    let wrong = session.receive(&activity(&corrupt, 55), 8);
    assert!(wrong.error.is_some());
    assert!(!wrong.events.iter().any(|e| e.kind == "health_file"));
}

#[test]
fn exhausted_directory_retries_end_sync_with_failure_event() {
    let mut session = ready();
    session.request(SessionRequest::SyncHealth, 6);
    for time in [10_006, 20_006, 30_006, 40_006, 50_006] {
        session.tick(time);
    }
    let ended = session.tick(60_006);
    assert!(ended.events.iter().any(|e| e.kind == "sync_failed"));
    assert!(ended.events.iter().any(|e| e.kind == "sync_complete"));
}
