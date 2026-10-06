//! Main-queue-only opaque session ownership for the Swift bridge.
use band9_core::session::{Session, SessionOptions, SessionRequest};
use serde::Deserialize;
use serde_json::{json, Value};
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

pub struct SessionHandle {
    session: Option<Session>,
}

#[derive(Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
enum Command {
    Start { now_ms: u64 },
    Receive { hex: String, now_ms: u64 },
    Tick { now_ms: u64 },
    Battery { now_ms: u64 },
    DeviceInfo { now_ms: u64 },
    Sync { now_ms: u64 },
    Disconnect { now_ms: u64 },
}

fn error(message: &str) -> Value {
    json!({"state":"failed","outbound":[],"events":[],"error":message})
}

fn result_string(value: Value) -> *mut c_char {
    serde_json::to_string(&value)
        .ok()
        .and_then(|value| CString::new(value).ok())
        .map_or(std::ptr::null_mut(), CString::into_raw)
}

fn decode_hex(value: &str) -> Option<Vec<u8>> {
    if value.len() > 65536 || !value.len().is_multiple_of(2) {
        return None;
    }
    value
        .as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| {
            let digit = |byte: u8| match byte {
                b'0'..=b'9' => Some(byte - b'0'),
                b'a'..=b'f' => Some(byte - b'a' + 10),
                b'A'..=b'F' => Some(byte - b'A' + 10),
                _ => None,
            };
            Some(digit(pair[0])? * 16 + digit(pair[1])?)
        })
        .collect()
}

/// Create a session from a key, secure phone nonce, and negotiated write size.
/// Null means invalid configuration. No device I/O takes place in this call.
///
/// # Safety
/// `config_json` must point to a readable NUL-terminated string for this call.
/// The returned handle must be freed once, and never accessed concurrently.
#[no_mangle]
pub unsafe extern "C" fn band9_session_create(config_json: *const c_char) -> *mut SessionHandle {
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller supplies a live C string per the API contract.
        let bytes = unsafe { crate::bounded_c_string(config_json, 8192) }?;
        let options: SessionOptions = serde_json::from_slice(bytes).ok()?;
        let session = Session::new(options).ok()?;
        Some(Box::into_raw(Box::new(SessionHandle {
            session: Some(session),
        })))
    }));
    result.ok().flatten().unwrap_or(std::ptr::null_mut())
}

/// Process one session command and return owned JSON, freed with band9_string_free.
/// It performs no Bluetooth calls. Swift sends returned bytes in FIFO order.
///
/// # Safety
/// `handle` is null or a live handle from band9_session_create, used exclusively.
/// `request_json` is a readable NUL-terminated C string that remains alive here.
#[no_mangle]
pub unsafe extern "C" fn band9_session_command(
    handle: *mut SessionHandle,
    request_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        return result_string(error("连接会话不存在，请重新连接。"));
    }
    // SAFETY: the API contract grants exclusive access to a live handle.
    let handle = unsafe { &mut *handle };
    let result = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller supplies a live C string per the API contract.
        let Some(bytes) = (unsafe { crate::bounded_c_string(request_json, 128 * 1024) }) else {
            return error("会话请求为空或超过长度限制。");
        };
        let Ok(command) = serde_json::from_slice::<Command>(bytes) else {
            return error("会话请求格式不正确。");
        };
        let Some(session) = handle.session.as_mut() else {
            return error("会话已停止，请重新连接。");
        };
        let update = match command {
            Command::Start { now_ms } => session.start(now_ms),
            Command::Receive { hex, now_ms } => {
                let Some(bytes) = decode_hex(&hex) else {
                    return error("蓝牙输入格式或长度不正确。");
                };
                session.receive(&bytes, now_ms)
            }
            Command::Tick { now_ms } => session.tick(now_ms),
            Command::Battery { now_ms } => session.request(SessionRequest::Battery, now_ms),
            Command::DeviceInfo { now_ms } => session.request(SessionRequest::DeviceInfo, now_ms),
            Command::Sync { now_ms } => session.request(SessionRequest::SyncHealth, now_ms),
            Command::Disconnect { now_ms } => session.request(SessionRequest::Disconnect, now_ms),
        };
        serde_json::to_value(update).unwrap_or_else(|_| error("无法编码会话结果。"))
    }));
    match result {
        Ok(value) => result_string(value),
        Err(_) => {
            // A panicked engine is never reused with partly mutated state.
            handle.session = None;
            result_string(error("协议会话发生内部错误，请重新连接。"))
        }
    }
}

/// Destroy a session and clear the owned session keys. Null is accepted.
///
/// # Safety
/// A non-null handle must come from band9_session_create, have no active calls,
/// and not have been freed before. No pointer may be used after this call.
#[no_mangle]
pub unsafe extern "C" fn band9_session_free(handle: *mut SessionHandle) {
    if !handle.is_null() {
        // SAFETY: ownership is transferred back exactly once by the caller.
        drop(unsafe { Box::from_raw(handle) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    unsafe fn command(handle: *mut SessionHandle, request: &str) -> Value {
        let request = CString::new(request).unwrap();
        // SAFETY: caller owns handle; request lives until the ABI call returns.
        let result = unsafe { band9_session_command(handle, request.as_ptr()) };
        assert!(!result.is_null());
        // SAFETY: ABI returned an owned, live NUL-terminated allocation.
        let value = serde_json::from_slice(unsafe { CStr::from_ptr(result) }.to_bytes()).unwrap();
        // SAFETY: free this owned result exactly once.
        unsafe { crate::band9_string_free(result) };
        value
    }

    #[test]
    fn abi_owns_state_and_rejects_malformed_requests_without_echoing_secrets() {
        let options = CString::new(r#"{"key_hex":"a0a1a2a3a4a5a6a7a8a9aaabacadaeaf","phone_nonce_hex":"000102030405060708090a0b0c0d0e0f","mtu":185}"#).unwrap();
        // SAFETY: all allocations remain alive and are owned exclusively here.
        unsafe {
            let handle = band9_session_create(options.as_ptr());
            assert!(!handle.is_null());
            let start = command(handle, r#"{"op":"start","now_ms":0}"#);
            assert!(!start["outbound"].as_array().unwrap().is_empty());
            let malformed = command(handle, "private-invalid-input");
            assert!(malformed["error"].is_string());
            assert!(!malformed.to_string().contains("private-invalid-input"));
            let invalid_hex = command(handle, r#"{"op":"receive","hex":"💡","now_ms":1}"#);
            assert!(invalid_hex["error"].is_string());
            command(handle, r#"{"op":"disconnect","now_ms":2}"#);
            band9_session_free(handle);
            band9_session_free(std::ptr::null_mut());
            assert!(band9_session_create(std::ptr::null()).is_null());
            assert!(command(std::ptr::null_mut(), "{}")["error"].is_string());
        }
    }

    #[test]
    fn hex_decoder_is_bounded_and_ascii_only() {
        assert_eq!(decode_hex("00fFa5"), Some(vec![0, 255, 165]));
        for invalid in ["0", "gg", "é", "\0a"] {
            assert!(decode_hex(invalid).is_none());
        }
        assert!(decode_hex(&"a".repeat(65538)).is_none());
    }
}
