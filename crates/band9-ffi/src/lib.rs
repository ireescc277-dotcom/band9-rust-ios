//! Owned-string C ABI for inventory diagnosis and authenticated band sessions.
//! Bluetooth object ownership and callbacks stay on the Swift main queue.
mod diagnostics;
mod session;

use diagnostics::{diagnose, Diagnosis, Inventory};
use std::ffi::{c_char, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};

const MAX_REQUEST_BYTES: usize = 128 * 1024;

/// # Safety
/// `input` is null or a readable NUL-terminated C string; returned bytes borrow it.
unsafe fn bounded_c_string<'a>(input: *const c_char, maximum: usize) -> Option<&'a [u8]> {
    if input.is_null() {
        return None;
    }
    for length in 0..=maximum {
        // SAFETY: caller guarantees the input allocation through its first NUL.
        if unsafe { *input.add(length) } == 0 {
            // SAFETY: inspected bytes are within that same live allocation.
            return Some(unsafe { std::slice::from_raw_parts(input.cast(), length) });
        }
    }
    None
}

#[no_mangle]
pub extern "C" fn band9_core_version() -> *const c_char {
    concat!(env!("CARGO_PKG_VERSION"), "\0").as_ptr().cast()
}

fn diagnose_bytes(bytes: &[u8]) -> Diagnosis {
    if bytes.len() > MAX_REQUEST_BYTES {
        return Diagnosis::error("诊断输入超过 128 KiB。");
    }
    match serde_json::from_slice::<Inventory>(bytes) {
        Ok(inventory) => diagnose(inventory),
        Err(_) => Diagnosis::error("诊断清单格式不正确。"),
    }
}

fn owned_json(value: Diagnosis) -> *mut c_char {
    match serde_json::to_string(&value)
        .ok()
        .and_then(|v| CString::new(v).ok())
    {
        Some(json) => json.into_raw(),
        None => std::ptr::null_mut(),
    }
}

/// Return an owned UTF-8 JSON result, or null on allocation/serialization failure.
/// The caller must free non-null results once with `band9_string_free`.
///
/// # Safety
/// `input` must be null or point to a readable, NUL-terminated C string whose
/// allocation remains alive for this call. No concurrent mutation is permitted.
#[no_mangle]
pub unsafe extern "C" fn band9_diagnose_json(input: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        if input.is_null() {
            return Diagnosis::error("诊断输入为空。");
        }
        // Bound the scan; do not create a reference to an unbounded C string.
        let mut length = 0;
        while length <= MAX_REQUEST_BYTES {
            // SAFETY: caller guarantees a readable C string through its NUL.
            if unsafe { *input.add(length) } == 0 {
                // SAFETY: inspected bytes before NUL belong to the same string.
                return diagnose_bytes(unsafe { std::slice::from_raw_parts(input.cast(), length) });
            }
            length += 1;
        }
        Diagnosis::error("诊断输入超过 128 KiB。")
    }));
    owned_json(result.unwrap_or_else(|_| Diagnosis::error("Rust 核心发生内部错误。")))
}

/// Release one owned JSON result. Null is accepted.
///
/// # Safety
/// A non-null pointer must be returned by `band9_diagnose_json`, unchanged and
/// not previously freed. The borrowed `band9_core_version` pointer is not owned.
#[no_mangle]
pub unsafe extern "C" fn band9_string_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        // SAFETY: guaranteed by caller as described above.
        drop(unsafe { CString::from_raw(pointer) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;

    #[test]
    fn c_abi_returns_owned_json_for_valid_invalid_and_null_requests() {
        let valid = CString::new(r#"{"services":[]}"#).unwrap();
        let invalid = CString::new("not json").unwrap();
        for input in [valid.as_ptr(), invalid.as_ptr(), std::ptr::null()] {
            // SAFETY: all input CStrings remain alive; returned allocation is freed once.
            unsafe {
                let pointer = band9_diagnose_json(input);
                assert!(!pointer.is_null());
                let d: Diagnosis =
                    serde_json::from_slice(CStr::from_ptr(pointer).to_bytes()).unwrap();
                assert_eq!(d.core_version, env!("CARGO_PKG_VERSION"));
                assert_eq!(d.profile, "unknown");
                band9_string_free(pointer);
            }
        }
    }

    #[test]
    fn large_and_non_utf8_requests_return_errors() {
        assert!(diagnose_bytes(&vec![b'a'; MAX_REQUEST_BYTES + 1]).warnings[0].contains("128"));
        assert!(diagnose_bytes(&[0xff]).warnings[0].contains("格式"));
    }
}
