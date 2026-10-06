//! Pure Xiaomi SPP V2 byte processing. No Bluetooth, network, storage, or runtime.
//!
//! The fixtures are public synthetic inputs, not device compatibility evidence.
//! Authentication/session sequencing and reliable delivery belong to a future
//! state machine; the primitives here do not imply a connected/authenticated band.

pub mod crypto;
pub mod frame;
pub mod health;
pub mod proto;
pub mod session;

/// CRC-16/ARC (poly 0x8005 reflected, init 0, xorout 0), over payload only.
pub fn crc16_arc(bytes: &[u8]) -> u16 {
    let mut crc = 0u16;
    for &byte in bytes {
        crc ^= u16::from(byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ if crc & 1 != 0 { 0xa001 } else { 0 };
        }
    }
    crc
}

/// Protobuf Command { type: 2, subtype: 1 }. Does not send a command.
pub const fn battery_command() -> [u8; 4] {
    [0x08, 0x02, 0x10, 0x01]
}
