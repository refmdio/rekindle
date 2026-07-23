use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeSet;
use std::io::{self, Read, Write};

pub const MAX_HEADER: usize = 65_536;
pub const MAX_PAYLOAD: usize = 1_048_576;

pub struct Frame {
    pub header: Value,
    pub payload: Vec<u8>,
}

pub fn read<R: Read>(reader: &mut R) -> Result<Option<Frame>, String> {
    let mut length = [0_u8; 4];
    let mut length_read = 0;

    while length_read < length.len() {
        match reader.read(&mut length[length_read..]) {
            Ok(0) if length_read == 0 => return Ok(None),
            Ok(0) => return Err("frame length read failed: truncated prefix".into()),
            Ok(count) => length_read += count,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(format!("frame length read failed: {error}")),
        }
    }

    let header_len = u32::from_be_bytes(length) as usize;
    if header_len > MAX_HEADER {
        return Err("header too large".into());
    }

    let mut header_bytes = vec![0; header_len];
    reader
        .read_exact(&mut header_bytes)
        .map_err(|error| format!("header read failed: {error}"))?;
    let header: Value = serde_json::from_slice(&header_bytes)
        .map_err(|error| format!("invalid header json: {error}"))?;
    let canonical = serde_jcs::to_vec(&header).map_err(|error| error.to_string())?;
    if canonical != header_bytes {
        return Err("header is not canonical JSON".into());
    }

    let object = header
        .as_object()
        .ok_or_else(|| "header must be an object".to_string())?;
    if object.get("v").and_then(Value::as_u64) != Some(1)
        || object.get("type").and_then(Value::as_str).is_none()
        || !is_request_id(object.get("request_id"))
    {
        return Err("invalid ToolFrame base".into());
    }
    let payload_len = object
        .get("payload_len")
        .and_then(Value::as_u64)
        .ok_or_else(|| "invalid payload length".to_string())? as usize;
    if payload_len > MAX_PAYLOAD {
        return Err("payload too large".into());
    }
    let mut payload = vec![0; payload_len];
    reader
        .read_exact(&mut payload)
        .map_err(|error| format!("payload read failed: {error}"))?;
    Ok(Some(Frame { header, payload }))
}

pub fn write<W: Write, T: Serialize>(
    writer: &mut W,
    header: &T,
    payload: &[u8],
) -> Result<(), String> {
    if payload.len() > MAX_PAYLOAD {
        return Err("payload too large".into());
    }
    let header_bytes = serde_jcs::to_vec(header).map_err(|error| error.to_string())?;
    if header_bytes.len() > MAX_HEADER {
        return Err("header too large".into());
    }
    writer
        .write_all(&(header_bytes.len() as u32).to_be_bytes())
        .and_then(|_| writer.write_all(&header_bytes))
        .and_then(|_| writer.write_all(payload))
        .and_then(|_| writer.flush())
        .map_err(|error| format!("frame write failed: {error}"))
}

pub fn exact_keys(value: &Value, expected: &[&str]) -> bool {
    let Some(object) = value.as_object() else {
        return false;
    };
    let actual = object.keys().map(String::as_str).collect::<BTreeSet<_>>();
    let expected = expected.iter().copied().collect::<BTreeSet<_>>();
    actual == expected
}

pub fn is_request_id(value: Option<&Value>) -> bool {
    value.and_then(Value::as_str).is_some_and(|value| {
        value.len() == 32
            && value
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
    })
}

#[cfg(test)]
mod tests {
    use super::read;
    use std::io::Cursor;

    #[test]
    fn distinguishes_clean_eof_from_every_truncated_length_prefix() {
        assert!(read(&mut Cursor::new([])).unwrap().is_none());

        for length in 1..=3 {
            let prefix = [0_u8, 0, 0, 1];
            let Err(error) = read(&mut Cursor::new(&prefix[..length])) else {
                panic!("partial frame prefix was accepted");
            };
            assert_eq!(error, "frame length read failed: truncated prefix");
        }
    }
}
