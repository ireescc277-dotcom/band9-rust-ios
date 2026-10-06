//! Small, bounded protobuf wire reader/writer, independently implemented from
//! public field-number facts. No generated/vendor schema or implementation.
//! Explicit zero values are retained on the wire (proto2 presence matters).

#[derive(Debug, Clone, Copy)]
pub enum Value<'a> {
    UInt(u64),
    Bytes(&'a [u8]),
    Fixed32,
    Fixed64,
}

#[derive(Debug)]
pub struct Message<'a> {
    fields: Vec<(u32, Value<'a>)>,
}

impl<'a> Message<'a> {
    pub fn parse(input: &'a [u8]) -> Result<Self, String> {
        if input.len() > 65535 {
            return Err("protobuf exceeds 65535 bytes".into());
        }
        let mut remaining = input;
        let mut fields = Vec::new();
        while !remaining.is_empty() {
            if fields.len() >= 1024 {
                return Err("protobuf exceeds field limit".into());
            }
            let tag = read_varint(&mut remaining)?;
            let field = tag >> 3;
            if field == 0 || field > 0x1fff_ffff {
                return Err("invalid protobuf field number".into());
            }
            let value = match tag & 7 {
                0 => Value::UInt(read_varint(&mut remaining)?),
                1 => {
                    take(&mut remaining, 8)?;
                    Value::Fixed64
                }
                2 => {
                    let len = usize::try_from(read_varint(&mut remaining)?)
                        .map_err(|_| "protobuf length overflow")?;
                    Value::Bytes(take(&mut remaining, len)?)
                }
                5 => {
                    take(&mut remaining, 4)?;
                    Value::Fixed32
                }
                _ => return Err("unsupported protobuf wire type".into()),
            };
            fields.push((field as u32, value));
        }
        Ok(Self { fields })
    }

    fn field(&self, number: u32) -> Result<Option<Value<'a>>, String> {
        let mut matches = self.fields.iter().filter(|(n, _)| *n == number);
        let first = matches.next().map(|(_, value)| *value);
        if matches.next().is_some() {
            return Err(format!("duplicate singular protobuf field {number}"));
        }
        Ok(first)
    }

    pub fn uint(&self, number: u32) -> Result<Option<u32>, String> {
        match self.field(number)? {
            None => Ok(None),
            Some(Value::UInt(v)) => u32::try_from(v)
                .map(Some)
                .map_err(|_| format!("protobuf field {number} exceeds uint32")),
            _ => Err(format!("protobuf field {number} has wrong wire type")),
        }
    }

    pub fn bytes(&self, number: u32) -> Result<Option<&'a [u8]>, String> {
        match self.field(number)? {
            None => Ok(None),
            Some(Value::Bytes(v)) => Ok(Some(v)),
            _ => Err(format!("protobuf field {number} has wrong wire type")),
        }
    }

    pub fn nested(&self, number: u32) -> Result<Option<Message<'a>>, String> {
        self.bytes(number)?.map(Self::parse).transpose()
    }

    pub fn repeated_bytes(&self, number: u32, limit: usize) -> Result<Vec<&'a [u8]>, String> {
        let mut values = Vec::new();
        for (_, value) in self.fields.iter().filter(|(n, _)| *n == number) {
            if values.len() >= limit {
                return Err(format!("protobuf repeated field {number} exceeds limit"));
            }
            match value {
                Value::Bytes(bytes) => values.push(*bytes),
                _ => return Err(format!("protobuf field {number} has wrong wire type")),
            }
        }
        Ok(values)
    }

    pub fn text(&self, number: u32) -> Result<Option<String>, String> {
        self.bytes(number)?
            .map(|s| {
                std::str::from_utf8(s)
                    .map(str::to_owned)
                    .map_err(|_| "invalid UTF-8 protobuf string".into())
            })
            .transpose()
    }
}

fn take<'a>(input: &mut &'a [u8], length: usize) -> Result<&'a [u8], String> {
    if length > input.len() {
        return Err("truncated protobuf field".into());
    }
    let (value, rest) = input.split_at(length);
    *input = rest;
    Ok(value)
}

fn read_varint(input: &mut &[u8]) -> Result<u64, String> {
    let mut value = 0u64;
    for index in 0..10 {
        let byte = take(input, 1)?[0];
        if index == 9 && byte > 1 {
            return Err("protobuf varint overflow".into());
        }
        value |= u64::from(byte & 0x7f) << (7 * index);
        if byte & 0x80 == 0 {
            return Ok(value);
        }
    }
    Err("protobuf varint overflow".into())
}

fn varint(out: &mut Vec<u8>, mut value: u64) {
    while value > 0x7f {
        out.push((value as u8 & 0x7f) | 0x80);
        value >>= 7;
    }
    out.push(value as u8);
}

pub fn uint(out: &mut Vec<u8>, field: u32, value: u32) {
    varint(out, u64::from(field) << 3);
    varint(out, u64::from(value));
}

pub fn bytes(out: &mut Vec<u8>, field: u32, value: &[u8]) {
    varint(out, (u64::from(field) << 3) | 2);
    varint(out, value.len() as u64);
    out.extend_from_slice(value);
}

pub fn command(kind: u32, subtype: u32, payload: Option<(u32, &[u8])>) -> Vec<u8> {
    let mut out = Vec::new();
    uint(&mut out, 1, kind);
    uint(&mut out, 2, subtype);
    if let Some((field, value)) = payload {
        bytes(&mut out, field, value);
    }
    out
}

pub fn nonce_command(nonce: &[u8; 16]) -> Vec<u8> {
    let mut inner = Vec::new();
    bytes(&mut inner, 1, nonce);
    let mut auth = Vec::new();
    bytes(&mut auth, 30, &inner);
    command(1, 26, Some((3, &auth)))
}

pub fn auth_command(proof: &[u8; 32], device_info_ciphertext: &[u8]) -> Vec<u8> {
    let mut inner = Vec::new();
    bytes(&mut inner, 1, proof);
    bytes(&mut inner, 2, device_info_ciphertext);
    let mut auth = Vec::new();
    bytes(&mut auth, 32, &inner);
    command(1, 27, Some((3, &auth)))
}

pub fn device_info(
    device_type: u32,
    api_level: f32,
    phone_name: &str,
    capabilities: u32,
    region: &str,
) -> Vec<u8> {
    let mut out = Vec::new();
    uint(&mut out, 1, device_type);
    varint(&mut out, (2 << 3) | 5);
    out.extend_from_slice(&api_level.to_le_bytes());
    bytes(&mut out, 3, phone_name.as_bytes());
    uint(&mut out, 4, capabilities);
    bytes(&mut out, 5, region.as_bytes());
    out
}

pub fn today_command() -> Vec<u8> {
    let mut today = Vec::new();
    uint(&mut today, 1, 0);
    let mut health = Vec::new();
    bytes(&mut health, 5, &today);
    command(8, 1, Some((10, &health)))
}

pub fn file_command(file_id: &[u8; 7]) -> Vec<u8> {
    let mut health = Vec::new();
    bytes(&mut health, 2, file_id);
    command(8, 3, Some((10, &health)))
}

pub fn set_watchface_command(face_id: &str) -> Vec<u8> {
    let mut watchface = Vec::new();
    bytes(&mut watchface, 2, face_id.as_bytes());
    command(4, 1, Some((6, &watchface)))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_explicit_zero_and_nested_nonce() {
        assert_eq!(command(2, 0, None), [8, 2, 16, 0]);
        let encoded = today_command();
        let cmd = Message::parse(&encoded).unwrap();
        assert_eq!(
            cmd.nested(10)
                .unwrap()
                .unwrap()
                .nested(5)
                .unwrap()
                .unwrap()
                .uint(1)
                .unwrap(),
            Some(0)
        );
        let nonce = nonce_command(&[9; 16]);
        let cmd = Message::parse(&nonce).unwrap();
        assert_eq!(
            cmd.nested(3)
                .unwrap()
                .unwrap()
                .nested(30)
                .unwrap()
                .unwrap()
                .bytes(1)
                .unwrap(),
            Some([9u8; 16].as_slice())
        );
    }
    #[test]
    fn rejects_ambiguous_and_malformed_input() {
        for bad in [
            &[0][..],
            &[0x0a, 9, 1],
            &[0x0b],
            &[
                0x08, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02,
            ],
        ] {
            assert!(Message::parse(bad).is_err());
        }
        assert!(Message::parse(&[8, 1, 8, 2]).unwrap().uint(1).is_err());
        assert!(Message::parse(&[10, 0]).unwrap().uint(1).is_err());
    }
}
