use band9_core::{
    battery_command, crc16_arc,
    crypto::{ccm_decrypt, ccm_encrypt, ctr_v2, CryptoError, SessionKeys, MAX_CRYPTO_INPUT_SIZE},
    frame::*,
};
use serde_json::Value;

fn fixture() -> Value {
    serde_json::from_str(include_str!("fixtures/xiaomi-v2-synthetic-vectors.json")).unwrap()
}

fn bytes(value: &Value, group: &str, key: &str) -> Vec<u8> {
    hex::decode(value[group][key].as_str().unwrap()).unwrap()
}

fn session(value: &Value) -> SessionKeys {
    SessionKeys::derive_verified(
        &bytes(value, "auth", "phone_nonce"),
        &bytes(value, "auth", "watch_nonce"),
        &bytes(value, "auth", "synthetic_auth_key"),
        &bytes(value, "auth", "expected_watch_hmac"),
    )
    .unwrap()
}

#[test]
fn public_synthetic_auth_vectors_match() {
    let value = fixture();
    let keys = session(&value);
    assert_eq!(
        keys.phone_hmac().unwrap().as_slice(),
        bytes(&value, "auth", "phone_hmac_encryptedNonces_field")
    );
    assert_eq!(
        keys.encryption_nonce().as_slice(),
        bytes(&value, "auth", "auth_ccm_nonce")
    );
    let plaintext = bytes(&value, "auth", "ccm_test_plaintext_not_device_info");
    let expected = bytes(&value, "auth", "ccm_test_ciphertext_and_4byte_tag");
    assert_eq!(keys.encrypt_auth_info(&plaintext).unwrap(), expected);
    assert_eq!(
        ccm_decrypt(
            &bytes(&value, "auth", "encryption_key"),
            &keys.encryption_nonce(),
            &expected
        )
        .unwrap(),
        plaintext
    );
    assert_eq!(
        keys.encrypt_v2(&battery_command()).unwrap(),
        bytes(&value, "spp_v2", "battery_command_ctr")
    );
    assert_eq!(
        battery_command().as_slice(),
        bytes(&value, "spp_v2", "battery_command_proto")
    );
}

#[test]
fn ctr_receive_uses_the_decryption_direction_key() {
    let value = fixture();
    let keys = session(&value);
    let incoming = ctr_v2(
        &bytes(&value, "auth", "decryption_key"),
        b"incoming watch message",
    )
    .unwrap();
    assert_eq!(
        keys.decrypt_v2(&incoming).unwrap(),
        b"incoming watch message"
    );
    assert_ne!(
        keys.encrypt_v2(&incoming).unwrap(),
        b"incoming watch message"
    );
}

#[test]
fn public_frames_match_byte_for_byte() {
    let value = fixture();
    assert_eq!(crc16_arc(b"123456789"), 0xbb3d);
    assert_eq!(crc16_arc(&[]), 0);
    assert_eq!(build_ack(42), bytes(&value, "spp_v2", "ack_seq_42"));
    assert_eq!(
        SessionConfig::default().build(),
        bytes(&value, "spp_v2", "session_config")
    );
    let mut payload = vec![CHANNEL_PROTOBUF, OPCODE_ENCRYPTED];
    payload.extend_from_slice(&session(&value).encrypt_v2(&battery_command()).unwrap());
    let encoded = build_frame(TYPE_DATA, 1, &payload).unwrap();
    assert_eq!(
        encoded,
        bytes(&value, "spp_v2", "battery_command_frame_seq_1")
    );
    let frame = parse_frame(&encoded, MAX_WIRE_PAYLOAD).unwrap();
    let data = frame.data().unwrap();
    assert_eq!((data.channel(), data.opcode), (1, 2));
    assert_eq!(data.bytes, &payload[2..]);
    assert_eq!(frame.encode().unwrap(), encoded);
}

#[test]
fn framing_works_at_every_fragment_boundary() {
    let value = fixture();
    let frame = bytes(&value, "spp_v2", "battery_command_frame_seq_1");
    let expected = parse_frame(&frame, 1024).unwrap();
    for split in 0..=frame.len() {
        let mut decoder = StreamDecoder::new(1024, 1024).unwrap();
        let mut first = decoder.push(&frame[..split]).unwrap();
        let second = decoder.push(&frame[split..]).unwrap();
        first.frames.extend(second.frames);
        assert_eq!(first.frames, vec![expected.clone()], "split {split}");
        assert!(first.errors.is_empty());
        assert!(second.errors.is_empty());
        assert_eq!(decoder.buffered_len(), 0);
    }
}

#[test]
fn coalesced_and_bytewise_frames_preserve_order_and_flags() {
    let one = build_frame(0x83, 7, &[0xa1, 2, 9]).unwrap();
    let two = build_ack(8);
    let three = SessionConfig::default().build();
    let stream = [one.clone(), two.clone(), three.clone()].concat();
    let expected: Vec<_> = [&one, &two, &three]
        .into_iter()
        .map(|x| parse_frame(x, 1024).unwrap())
        .collect();
    let mut decoder = StreamDecoder::new(1024, 1024).unwrap();
    assert_eq!(decoder.push(&stream).unwrap().frames, expected);
    let mut bytewise = Vec::new();
    for byte in stream {
        bytewise.extend(decoder.push(&[byte]).unwrap().frames);
    }
    assert_eq!(bytewise, expected);
    assert_eq!(bytewise[0].flags(), 0x80);
    assert_eq!(bytewise[0].data().unwrap().raw_channel, 0xa1);
    assert_eq!(bytewise[0].data().unwrap().channel(), 1);
}

#[test]
fn noise_retains_final_a5_and_reset_discards_partial_frames() {
    let mut decoder = StreamDecoder::new(32, 64).unwrap();
    let batch = decoder.push(&[0, 1, 0xa5, 2, 0xa5]).unwrap();
    assert_eq!(batch.discarded_bytes, 4);
    assert_eq!(decoder.buffered_len(), 1);
    assert_eq!(
        decoder.push(&build_ack(42)[1..]).unwrap().frames[0].sequence,
        42
    );
    decoder
        .push(&[0xa5, 0xa5, 3, 0, 30, 0, 0, 0, 1, 2])
        .unwrap();
    assert_eq!(decoder.buffered_len(), 10);
    decoder.reset();
    assert_eq!(decoder.buffered_len(), 0);
    assert_eq!(decoder.push(&build_ack(3)).unwrap().frames[0].sequence, 3);
}

#[test]
fn corrupt_crc_recovers_to_the_next_frame() {
    let mut bad = build_frame(TYPE_DATA, 1, &[1, 2, 3, 4]).unwrap();
    bad[9] ^= 1;
    bad.extend_from_slice(&build_ack(9));
    let mut decoder = StreamDecoder::new(32, 64).unwrap();
    let batch = decoder.push(&bad).unwrap();
    assert!(matches!(
        batch.errors.as_slice(),
        [FrameError::CrcMismatch { .. }]
    ));
    assert_eq!(batch.frames.len(), 1);
    assert_eq!(batch.frames[0].sequence, 9);
    assert_eq!(decoder.buffered_len(), 0);
}

#[test]
fn corruption_recovery_skips_a_false_incomplete_header() {
    let mut corrupt = build_frame(TYPE_DATA, 1, &[0xa5, 0xa5, 3, 0, 100, 0, 0, 0]).unwrap();
    corrupt[6] ^= 1;
    let mut decoder = StreamDecoder::new(128, 128).unwrap();
    assert!(decoder.push(&corrupt).unwrap().frames.is_empty());
    let recovered = decoder.push(&build_ack(42)).unwrap();
    assert_eq!(recovered.frames.len(), 1);
    assert_eq!(recovered.frames[0].sequence, 42);
    assert_eq!(decoder.buffered_len(), 0);
}

#[test]
fn normal_partial_frame_keeps_an_embedded_ack_as_payload() {
    let mut payload = build_ack(42);
    payload.extend_from_slice(&[0; 32]);
    let encoded = build_frame(TYPE_DATA, 9, &payload).unwrap();
    let mut decoder = StreamDecoder::new(128, 128).unwrap();
    assert!(decoder.push(&encoded[..16]).unwrap().frames.is_empty());
    let decoded = decoder.push(&encoded[16..]).unwrap();
    assert_eq!(decoded.frames.len(), 1);
    assert_eq!(decoded.frames[0].sequence, 9);
    assert_eq!(decoded.frames[0].payload, payload);
}

#[test]
fn oversize_declared_payload_is_rejected_without_waiting_or_allocating_it() {
    let mut input = vec![0xa5, 0xa5, 3, 1, 0xff, 0xff, 0, 0];
    input.extend_from_slice(&build_ack(9));
    let mut decoder = StreamDecoder::new(32, 64).unwrap();
    let batch = decoder.push(&input).unwrap();
    assert_eq!(
        batch.errors,
        vec![FrameError::PayloadTooLarge {
            actual: 65535,
            maximum: 32
        }]
    );
    assert_eq!(batch.frames[0].sequence, 9);
    assert_eq!(decoder.buffered_len(), 0);
}

#[test]
fn rejected_feed_is_atomic_and_configuration_is_bounded() {
    assert!(StreamDecoder::new(MAX_WIRE_PAYLOAD + 1, 8).is_err());
    assert!(StreamDecoder::new(8, 0).is_err());
    assert!(StreamDecoder::new(8, MAX_INPUT_SIZE + 1).is_err());
    let mut decoder = StreamDecoder::new(8, 8).unwrap();
    decoder.push(&[0xa5]).unwrap();
    assert_eq!(
        decoder.push(&[0; 9]),
        Err(FrameError::InputTooLarge {
            actual: 9,
            maximum: 8
        })
    );
    assert_eq!(decoder.buffered_len(), 1);
    assert_eq!(
        decoder.push(&build_ack(7)[1..]).unwrap().frames[0].sequence,
        7
    );
}

#[test]
fn strict_single_frame_errors_and_data_header_validation() {
    let frame = build_frame(TYPE_DATA, 1, &[1]).unwrap();
    for length in 0..frame.len() {
        assert!(matches!(
            parse_frame(&frame[..length], 32),
            Err(FrameError::Incomplete { .. })
        ));
    }
    let mut trailing = frame.clone();
    trailing.push(0);
    assert!(matches!(
        parse_frame(&trailing, 32),
        Err(FrameError::TrailingBytes { .. })
    ));
    let mut bad_preamble = frame.clone();
    bad_preamble[0] = 0;
    assert_eq!(
        parse_frame(&bad_preamble, 32),
        Err(FrameError::InvalidPreamble)
    );
    assert!(matches!(
        parse_frame(&frame, 0),
        Err(FrameError::PayloadTooLarge { .. })
    ));
    assert!(matches!(
        parse_frame(&frame, 32).unwrap().data(),
        Err(FrameError::DataHeaderMissing { actual: 1 })
    ));
    assert!(matches!(
        parse_frame(&build_ack(0), 32).unwrap().data(),
        Err(FrameError::NotData {
            packet_type: TYPE_ACK
        })
    ));
    assert!(matches!(
        build_frame(3, 0, &vec![0; 65536]),
        Err(FrameError::PayloadTooLarge { .. })
    ));
}

#[test]
fn all_wire_payload_boundaries_round_trip() {
    for length in [0, 1, 15, 16, 17, 255, 256, 257, 4097, 65535] {
        let payload: Vec<_> = (0..length).map(|i| i as u8).collect();
        let frame = build_frame(3, 255, &payload).unwrap();
        assert_eq!(
            parse_frame(&frame, MAX_WIRE_PAYLOAD).unwrap().payload,
            payload
        );
        let mut decoder = StreamDecoder::new(MAX_WIRE_PAYLOAD, 257).unwrap();
        let mut frames = Vec::new();
        for chunk in frame.chunks(257) {
            frames.extend(decoder.push(chunk).unwrap().frames);
        }
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].payload, payload);
        assert_eq!(decoder.buffered_len(), 0);
    }
}

#[test]
fn arbitrary_noise_keeps_buffer_bounded_and_never_panics() {
    let mut decoder = StreamDecoder::new(128, 256).unwrap();
    let mut state = 0x9123_4abcu32;
    for _ in 0..300 {
        let mut chunk = [0u8; 256];
        for byte in &mut chunk {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            *byte = state as u8;
        }
        decoder.push(&chunk).unwrap();
        assert!(decoder.buffered_len() < 128 + HEADER_SIZE);
    }
}

#[test]
fn every_auth_input_requires_exact_length() {
    for length in [0, 1, 15, 17, 32] {
        assert!(matches!(
            SessionKeys::derive(&vec![0; length], &[0; 16], &[0; 16]),
            Err(CryptoError::InvalidLength {
                field: "phone nonce",
                ..
            })
        ));
        assert!(matches!(
            SessionKeys::derive(&[0; 16], &vec![0; length], &[0; 16]),
            Err(CryptoError::InvalidLength {
                field: "watch nonce",
                ..
            })
        ));
        assert!(matches!(
            SessionKeys::derive(&[0; 16], &[0; 16], &vec![0; length]),
            Err(CryptoError::InvalidLength {
                field: "auth key",
                ..
            })
        ));
    }
    let keys = session(&fixture());
    for length in [0, 16, 31, 33, 64] {
        assert!(matches!(
            keys.verify_watch_hmac(&vec![0; length]),
            Err(CryptoError::InvalidLength {
                field: "watch HMAC",
                ..
            })
        ));
    }
}

#[test]
fn every_modified_watch_hmac_byte_fails_and_raw_key_is_not_verification_key() {
    let value = fixture();
    let keys = session(&value);
    let proof = bytes(&value, "auth", "expected_watch_hmac");
    for index in 0..proof.len() {
        let mut changed = proof.clone();
        changed[index] ^= 1;
        assert_eq!(
            keys.verify_watch_hmac(&changed),
            Err(CryptoError::AuthenticationFailed)
        );
    }
    let mut key = bytes(&value, "auth", "synthetic_auth_key");
    key[0] ^= 1;
    assert!(matches!(
        SessionKeys::derive_verified(
            &bytes(&value, "auth", "phone_nonce"),
            &bytes(&value, "auth", "watch_nonce"),
            &key,
            &proof
        ),
        Err(CryptoError::AuthenticationFailed)
    ));
    // Reversing the transcript is also rejected, even with the same long-term key.
    assert!(matches!(
        SessionKeys::derive_verified(
            &bytes(&value, "auth", "watch_nonce"),
            &bytes(&value, "auth", "phone_nonce"),
            &bytes(&value, "auth", "synthetic_auth_key"),
            &proof
        ),
        Err(CryptoError::AuthenticationFailed)
    ));
}

#[test]
fn ccm_never_returns_plaintext_for_a_modified_message_or_nonce() {
    let value = fixture();
    let key = bytes(&value, "auth", "encryption_key");
    let mut nonce = bytes(&value, "auth", "auth_ccm_nonce");
    let ciphertext = bytes(&value, "auth", "ccm_test_ciphertext_and_4byte_tag");
    for index in 0..ciphertext.len() {
        let mut modified = ciphertext.clone();
        modified[index] ^= 0x80;
        assert_eq!(
            ccm_decrypt(&key, &nonce, &modified),
            Err(CryptoError::AuthenticationFailed)
        );
    }
    nonce[0] ^= 1;
    assert_eq!(
        ccm_decrypt(&key, &nonce, &ciphertext),
        Err(CryptoError::AuthenticationFailed)
    );
    assert_eq!(
        ccm_decrypt(&key, &nonce, &[0; 3]),
        Err(CryptoError::AuthenticationFailed)
    );
}

#[test]
fn crypto_block_boundaries_and_empty_messages_round_trip() {
    let value = fixture();
    let key = bytes(&value, "auth", "encryption_key");
    let nonce = bytes(&value, "auth", "auth_ccm_nonce");
    for length in [0, 1, 15, 16, 17, 31, 32, 255, 256, 257, 4097] {
        let plain: Vec<_> = (0..length).map(|i| i as u8).collect();
        let encrypted = ccm_encrypt(&key, &nonce, &plain).unwrap();
        assert_eq!(encrypted.len(), plain.len() + 4);
        assert_eq!(ccm_decrypt(&key, &nonce, &encrypted).unwrap(), plain);
        assert_eq!(ctr_v2(&key, &ctr_v2(&key, &plain).unwrap()).unwrap(), plain);
    }
}

#[test]
fn crypto_key_nonce_and_allocation_limits_are_strict() {
    assert!(matches!(
        ctr_v2(&[0; 15], &[]),
        Err(CryptoError::InvalidLength {
            field: "AES key",
            ..
        })
    ));
    assert!(matches!(
        ccm_encrypt(&[0; 16], &[0; 13], &[]),
        Err(CryptoError::InvalidLength {
            field: "CCM nonce",
            ..
        })
    ));
    assert!(matches!(
        ccm_decrypt(&[0; 17], &[0; 12], &[0; 4]),
        Err(CryptoError::InvalidLength {
            field: "AES key",
            ..
        })
    ));
    let oversized = vec![0; MAX_CRYPTO_INPUT_SIZE + 1];
    assert!(matches!(
        ctr_v2(&[0; 16], &oversized),
        Err(CryptoError::InputTooLarge { .. })
    ));
    assert!(matches!(
        ccm_encrypt(&[0; 16], &[0; 12], &oversized),
        Err(CryptoError::InputTooLarge { .. })
    ));
}
