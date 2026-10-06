//! Loss-tolerant framing of an arbitrarily fragmented SPP V2 byte stream.

use crate::crc16_arc;
use std::fmt;

pub const HEADER_SIZE: usize = 8;
pub const MAX_WIRE_PAYLOAD: usize = u16::MAX as usize;
/// Hard ceiling on one feed, regardless of the caller's configured limit.
pub const MAX_INPUT_SIZE: usize = 256 * 1024;
pub const TYPE_ACK: u8 = 1;
pub const TYPE_SESSION_CONFIG: u8 = 2;
pub const TYPE_DATA: u8 = 3;
pub const CHANNEL_PROTOBUF: u8 = 1;
pub const OPCODE_PLAINTEXT: u8 = 1;
pub const OPCODE_ENCRYPTED: u8 = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameError {
    InvalidLimit { name: &'static str, maximum: usize },
    InputTooLarge { actual: usize, maximum: usize },
    PayloadTooLarge { actual: usize, maximum: usize },
    Incomplete { expected: usize, actual: usize },
    TrailingBytes { expected: usize, actual: usize },
    InvalidPreamble,
    CrcMismatch { expected: u16, actual: u16 },
    NotData { packet_type: u8 },
    DataHeaderMissing { actual: usize },
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidLimit { name, maximum } => {
                write!(f, "invalid {name} limit (maximum {maximum})")
            }
            Self::InputTooLarge { actual, maximum } => {
                write!(f, "input has {actual} bytes; feed limit is {maximum}")
            }
            Self::PayloadTooLarge { actual, maximum } => {
                write!(f, "payload has {actual} bytes; limit is {maximum}")
            }
            Self::Incomplete { expected, actual } => write!(
                f,
                "incomplete frame: expected {expected} bytes, got {actual}"
            ),
            Self::TrailingBytes { expected, actual } => {
                write!(f, "expected one {expected}-byte frame, got {actual} bytes")
            }
            Self::InvalidPreamble => f.write_str("frame does not start with A5 A5"),
            Self::CrcMismatch { expected, actual } => write!(
                f,
                "payload CRC mismatch: header {expected:04x}, computed {actual:04x}"
            ),
            Self::NotData { packet_type } => write!(f, "packet type {packet_type} is not DATA"),
            Self::DataHeaderMissing { actual } => {
                write!(f, "DATA requires channel and opcode; got {actual} bytes")
            }
        }
    }
}

impl std::error::Error for FrameError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// Preserve all flag bits; unknown types are left for the caller to handle.
    pub type_flags: u8,
    pub sequence: u8,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn packet_type(&self) -> u8 {
        self.type_flags & 0x0f
    }
    pub fn flags(&self) -> u8 {
        self.type_flags & 0xf0
    }

    pub fn data(&self) -> Result<DataPayload<'_>, FrameError> {
        if self.packet_type() != TYPE_DATA {
            return Err(FrameError::NotData {
                packet_type: self.packet_type(),
            });
        }
        if self.payload.len() < 2 {
            return Err(FrameError::DataHeaderMissing {
                actual: self.payload.len(),
            });
        }
        Ok(DataPayload {
            raw_channel: self.payload[0],
            opcode: self.payload[1],
            bytes: &self.payload[2..],
        })
    }

    pub fn encode(&self) -> Result<Vec<u8>, FrameError> {
        build_frame(self.type_flags, self.sequence, &self.payload)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DataPayload<'a> {
    /// Full channel byte, including flags; use channel() for the low nibble.
    pub raw_channel: u8,
    pub opcode: u8,
    pub bytes: &'a [u8],
}

impl DataPayload<'_> {
    pub fn channel(&self) -> u8 {
        self.raw_channel & 0x0f
    }
}

pub fn build_frame(type_flags: u8, sequence: u8, payload: &[u8]) -> Result<Vec<u8>, FrameError> {
    let length = u16::try_from(payload.len()).map_err(|_| FrameError::PayloadTooLarge {
        actual: payload.len(),
        maximum: MAX_WIRE_PAYLOAD,
    })?;
    let mut bytes = Vec::with_capacity(HEADER_SIZE + payload.len());
    bytes.extend_from_slice(&[0xa5, 0xa5, type_flags, sequence]);
    bytes.extend_from_slice(&length.to_le_bytes());
    bytes.extend_from_slice(&crc16_arc(payload).to_le_bytes());
    bytes.extend_from_slice(payload);
    Ok(bytes)
}

/// Parse exactly one frame, rejecting trailing bytes and incomplete input.
pub fn parse_frame(bytes: &[u8], max_payload: usize) -> Result<Frame, FrameError> {
    check_payload_limit(max_payload)?;
    if bytes.len() < HEADER_SIZE {
        return Err(FrameError::Incomplete {
            expected: HEADER_SIZE,
            actual: bytes.len(),
        });
    }
    if bytes[..2] != [0xa5, 0xa5] {
        return Err(FrameError::InvalidPreamble);
    }
    let payload_len = usize::from(u16::from_le_bytes([bytes[4], bytes[5]]));
    if payload_len > max_payload {
        return Err(FrameError::PayloadTooLarge {
            actual: payload_len,
            maximum: max_payload,
        });
    }
    let total = HEADER_SIZE + payload_len;
    if bytes.len() < total {
        return Err(FrameError::Incomplete {
            expected: total,
            actual: bytes.len(),
        });
    }
    if bytes.len() > total {
        return Err(FrameError::TrailingBytes {
            expected: total,
            actual: bytes.len(),
        });
    }
    let expected = u16::from_le_bytes([bytes[6], bytes[7]]);
    let actual = crc16_arc(&bytes[HEADER_SIZE..]);
    if expected != actual {
        return Err(FrameError::CrcMismatch { expected, actual });
    }
    Ok(Frame {
        type_flags: bytes[2],
        sequence: bytes[3],
        payload: bytes[HEADER_SIZE..].to_vec(),
    })
}

pub fn build_ack(sequence: u8) -> Vec<u8> {
    vec![0xa5, 0xa5, TYPE_ACK, sequence, 0, 0, 0, 0]
}

/// Wire settings only: this struct does not implement a transmission window,
/// retry timer, or negotiation. A transport must honor any settings it advertises.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionConfig {
    pub version: [u8; 3],
    pub max_packet_size: u16,
    pub transmit_window: u16,
    pub send_timeout_ms: u16,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            version: [1, 0, 0],
            max_packet_size: 0xfc00,
            transmit_window: 32,
            send_timeout_ms: 10_000,
        }
    }
}

impl SessionConfig {
    /// START_SESSION_REQUEST at sequence 0, encoded as key/length/value entries.
    pub fn build(&self) -> Vec<u8> {
        let mut payload = vec![1, 1, 3, 0];
        payload.extend_from_slice(&self.version);
        for (key, value) in [
            (2, self.max_packet_size),
            (3, self.transmit_window),
            (4, self.send_timeout_ms),
        ] {
            payload.extend_from_slice(&[key, 2, 0]);
            payload.extend_from_slice(&value.to_le_bytes());
        }
        let mut bytes = vec![0xa5, 0xa5, TYPE_SESSION_CONFIG, 0, 22, 0];
        bytes.extend_from_slice(&crc16_arc(&payload).to_le_bytes());
        bytes.extend_from_slice(&payload);
        bytes
    }
}

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct DecodeBatch {
    pub frames: Vec<Frame>,
    /// Invalid candidate frames encountered while recovering synchronization.
    pub errors: Vec<FrameError>,
    pub discarded_bytes: usize,
}

/// A bounded stream decoder. Noise is skipped, retaining a final A5 so split
/// preambles work. Corrupt/oversize candidates resynchronize from the next byte.
/// A plausible incomplete frame is retained; reset it on timeout/disconnect.
/// Maximum buffered byte count is max_payload + HEADER_SIZE + max_input.
pub struct StreamDecoder {
    buffer: Vec<u8>,
    max_payload: usize,
    max_input: usize,
    resynchronizing: bool,
}

impl StreamDecoder {
    pub fn new(max_payload: usize, max_input: usize) -> Result<Self, FrameError> {
        check_payload_limit(max_payload)?;
        if max_input == 0 || max_input > MAX_INPUT_SIZE {
            return Err(FrameError::InvalidLimit {
                name: "input",
                maximum: MAX_INPUT_SIZE,
            });
        }
        Ok(Self {
            buffer: Vec::new(),
            max_payload,
            max_input,
            resynchronizing: false,
        })
    }

    pub fn buffered_len(&self) -> usize {
        self.buffer.len()
    }

    pub fn reset(&mut self) {
        self.buffer.clear();
        self.resynchronizing = false;
    }

    /// Oversize feeds are rejected atomically; retained bytes remain unchanged.
    pub fn push(&mut self, input: &[u8]) -> Result<DecodeBatch, FrameError> {
        if input.len() > self.max_input {
            return Err(FrameError::InputTooLarge {
                actual: input.len(),
                maximum: self.max_input,
            });
        }
        self.buffer.extend_from_slice(input);
        let mut result = DecodeBatch::default();
        let mut position = 0;
        while position < self.buffer.len() {
            let remaining = &self.buffer[position..];
            if remaining[0] != 0xa5 || (remaining.len() >= 2 && remaining[1] != 0xa5) {
                position += 1;
                result.discarded_bytes += 1;
                continue;
            }
            if remaining.len() < HEADER_SIZE {
                break;
            }
            let payload_len = usize::from(u16::from_le_bytes([remaining[4], remaining[5]]));
            if payload_len > self.max_payload {
                result.errors.push(FrameError::PayloadTooLarge {
                    actual: payload_len,
                    maximum: self.max_payload,
                });
                position += 1;
                result.discarded_bytes += 1;
                self.resynchronizing = true;
                continue;
            }
            let total = HEADER_SIZE + payload_len;
            if remaining.len() < total {
                // A damaged frame can contain a false preamble with a plausible
                // length. Once corruption is known, prefer a later complete,
                // CRC-valid frame over waiting on that false candidate forever.
                // Normal fragmented frames never take this speculative path.
                if self.resynchronizing {
                    if let Some(offset) = next_complete_frame(remaining, self.max_payload) {
                        position += offset;
                        result.discarded_bytes += offset;
                        continue;
                    }
                }
                break;
            }
            match parse_frame(&remaining[..total], self.max_payload) {
                Ok(frame) => {
                    result.frames.push(frame);
                    position += total;
                    self.resynchronizing = false;
                }
                Err(error) => {
                    result.errors.push(error);
                    position += 1;
                    result.discarded_bytes += 1;
                    self.resynchronizing = true;
                }
            }
        }
        self.buffer.drain(..position);
        Ok(result)
    }
}

fn next_complete_frame(bytes: &[u8], max_payload: usize) -> Option<usize> {
    for offset in 1..bytes.len().saturating_sub(HEADER_SIZE - 1) {
        let candidate = &bytes[offset..];
        if candidate[..2] != [0xa5, 0xa5] {
            continue;
        }
        let length = usize::from(u16::from_le_bytes([candidate[4], candidate[5]]));
        if length > max_payload || HEADER_SIZE + length > candidate.len() {
            continue;
        }
        let expected = u16::from_le_bytes([candidate[6], candidate[7]]);
        if crc16_arc(&candidate[HEADER_SIZE..HEADER_SIZE + length]) == expected {
            return Some(offset);
        }
    }
    None
}

fn check_payload_limit(maximum: usize) -> Result<(), FrameError> {
    if maximum > MAX_WIRE_PAYLOAD {
        Err(FrameError::InvalidLimit {
            name: "payload",
            maximum: MAX_WIRE_PAYLOAD,
        })
    } else {
        Ok(())
    }
}
