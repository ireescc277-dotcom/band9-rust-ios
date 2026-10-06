//! Protocol-compatible cryptography using RustCrypto implementations.
//! Callers must generate fresh unpredictable 16-byte phone nonces. These
//! primitives do not provide randomness or an authentication state machine.

use aes::Aes128;
use ccm::{
    aead::{Aead, KeyInit},
    consts::{U12, U4},
    Ccm,
};
use ctr::cipher::{KeyIvInit, StreamCipher};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::fmt;
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

type HmacSha256 = Hmac<Sha256>;
type AesCcm = Ccm<Aes128, U4, U12>;
type AesCtr = ctr::Ctr128BE<Aes128>;

/// Byte-processing ceiling, sufficient for one maximum-size SPP V2 payload.
pub const MAX_CRYPTO_INPUT_SIZE: usize = u16::MAX as usize;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CryptoError {
    InvalidLength {
        field: &'static str,
        expected: usize,
        actual: usize,
    },
    InputTooLarge {
        actual: usize,
        maximum: usize,
    },
    AuthenticationFailed,
    CipherFailure,
}

impl fmt::Display for CryptoError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidLength {
                field,
                expected,
                actual,
            } => write!(f, "{field} must contain {expected} bytes, got {actual}"),
            Self::InputTooLarge { actual, maximum } => write!(
                f,
                "cryptographic input has {actual} bytes; limit is {maximum}"
            ),
            Self::AuthenticationFailed => {
                f.write_str("authentication proof or ciphertext tag does not match")
            }
            Self::CipherFailure => f.write_str("cryptographic operation failed"),
        }
    }
}

impl std::error::Error for CryptoError {}

/// Directional keys and transcript. No key getters, no Clone, redacted Debug.
/// Owned secret arrays and temporary HKDF output are zeroized on drop; callers
/// retain responsibility for wiping their input auth_key and exported plaintext.
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct SessionKeys {
    decryption_key: [u8; 16],
    encryption_key: [u8; 16],
    decryption_nonce_prefix: [u8; 4],
    encryption_nonce_prefix: [u8; 4],
    phone_nonce: [u8; 16],
    watch_nonce: [u8; 16],
}

impl fmt::Debug for SessionKeys {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("SessionKeys([REDACTED])")
    }
}

impl SessionKeys {
    /// HKDF-SHA256, salt=P||W, IKM=K, info="miwear-auth", output length 64.
    /// This only derives keys. Use derive_verified before trusting a watch.
    pub fn derive(
        phone_nonce: &[u8],
        watch_nonce: &[u8],
        auth_key: &[u8],
    ) -> Result<Self, CryptoError> {
        let phone = array::<16>(phone_nonce, "phone nonce")?;
        let watch = array::<16>(watch_nonce, "watch nonce")?;
        let key = array::<16>(auth_key, "auth key")?;
        let mut salt = Zeroizing::new([0u8; 32]);
        salt[..16].copy_from_slice(phone);
        salt[16..].copy_from_slice(watch);
        let hkdf = Hkdf::<Sha256>::new(Some(salt.as_slice()), key);
        let mut output = Zeroizing::new([0u8; 64]);
        hkdf.expand(b"miwear-auth", output.as_mut_slice())
            .map_err(|_| CryptoError::CipherFailure)?;
        let mut keys = Self {
            decryption_key: [0; 16],
            encryption_key: [0; 16],
            decryption_nonce_prefix: [0; 4],
            encryption_nonce_prefix: [0; 4],
            phone_nonce: *phone,
            watch_nonce: *watch,
        };
        keys.decryption_key.copy_from_slice(&output[..16]);
        keys.encryption_key.copy_from_slice(&output[16..32]);
        keys.decryption_nonce_prefix
            .copy_from_slice(&output[32..36]);
        keys.encryption_nonce_prefix
            .copy_from_slice(&output[36..40]);
        Ok(keys)
    }

    /// Derive first, then verify HMAC(decKey, W||P) in constant time.
    /// A failure drops and zeroizes the newly derived secret arrays.
    pub fn derive_verified(
        phone_nonce: &[u8],
        watch_nonce: &[u8],
        auth_key: &[u8],
        proof: &[u8],
    ) -> Result<Self, CryptoError> {
        let keys = Self::derive(phone_nonce, watch_nonce, auth_key)?;
        keys.verify_watch_hmac(proof)?;
        Ok(keys)
    }

    pub fn verify_watch_hmac(&self, proof: &[u8]) -> Result<(), CryptoError> {
        array::<32>(proof, "watch HMAC")?;
        let mut mac = <HmacSha256 as Mac>::new_from_slice(&self.decryption_key)
            .map_err(|_| CryptoError::CipherFailure)?;
        mac.update(&self.watch_nonce);
        mac.update(&self.phone_nonce);
        mac.verify_slice(proof)
            .map_err(|_| CryptoError::AuthenticationFailed)
    }

    /// HMAC(encKey, P||W), the phone proof, not encrypted nonce bytes.
    pub fn phone_hmac(&self) -> Result<[u8; 32], CryptoError> {
        let mut mac = <HmacSha256 as Mac>::new_from_slice(&self.encryption_key)
            .map_err(|_| CryptoError::CipherFailure)?;
        mac.update(&self.phone_nonce);
        mac.update(&self.watch_nonce);
        Ok(mac.finalize().into_bytes().into())
    }

    pub fn encryption_nonce(&self) -> [u8; 12] {
        let mut nonce = [0u8; 12];
        nonce[..4].copy_from_slice(&self.encryption_nonce_prefix);
        nonce
    }

    pub fn decryption_nonce(&self) -> [u8; 12] {
        let mut nonce = [0u8; 12];
        nonce[..4].copy_from_slice(&self.decryption_nonce_prefix);
        nonce
    }

    /// Authentication device-info bytes only. The protocol uses a zero suffix
    /// with fresh session keys; do not reuse this nonce for multiple messages.
    pub fn encrypt_auth_info(&self, plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
        ccm_encrypt(&self.encryption_key, &self.encryption_nonce(), plaintext)
    }

    /// V2 compatibility behavior: encryption key is also the initial CTR IV.
    /// This is not a general-purpose encryption construction.
    pub fn encrypt_v2(&self, plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
        ctr_v2(&self.encryption_key, plaintext)
    }

    pub fn decrypt_v2(&self, ciphertext: &[u8]) -> Result<Vec<u8>, CryptoError> {
        ctr_v2(&self.decryption_key, ciphertext)
    }
}

/// AES-128-CCM, exactly 12 nonce bytes and 4 tag bytes, no associated data.
/// The output includes the authentication tag at the end.
pub fn ccm_encrypt(key: &[u8], nonce: &[u8], plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
    array::<16>(key, "AES key")?;
    let nonce = array::<12>(nonce, "CCM nonce")?;
    bounded(plaintext.len(), MAX_CRYPTO_INPUT_SIZE)?;
    let cipher = AesCcm::new_from_slice(key).map_err(|_| CryptoError::CipherFailure)?;
    cipher
        .encrypt(nonce.into(), plaintext)
        .map_err(|_| CryptoError::CipherFailure)
}

/// Reject an invalid tag without returning unauthenticated plaintext.
pub fn ccm_decrypt(
    key: &[u8],
    nonce: &[u8],
    ciphertext_and_tag: &[u8],
) -> Result<Vec<u8>, CryptoError> {
    array::<16>(key, "AES key")?;
    let nonce = array::<12>(nonce, "CCM nonce")?;
    bounded(ciphertext_and_tag.len(), MAX_CRYPTO_INPUT_SIZE + 4)?;
    if ciphertext_and_tag.len() < 4 {
        return Err(CryptoError::AuthenticationFailed);
    }
    let cipher = AesCcm::new_from_slice(key).map_err(|_| CryptoError::CipherFailure)?;
    cipher
        .decrypt(nonce.into(), ciphertext_and_tag)
        .map_err(|_| CryptoError::AuthenticationFailed)
}

/// Apply the V2 keystream in either direction, incrementing the 128-bit initial
/// key-as-IV counter in big-endian order. No authentication is provided by CTR.
pub fn ctr_v2(key: &[u8], input: &[u8]) -> Result<Vec<u8>, CryptoError> {
    array::<16>(key, "AES key")?;
    bounded(input.len(), MAX_CRYPTO_INPUT_SIZE)?;
    let mut cipher = AesCtr::new_from_slices(key, key).map_err(|_| CryptoError::CipherFailure)?;
    let mut output = input.to_vec();
    cipher
        .try_apply_keystream(&mut output)
        .map_err(|_| CryptoError::CipherFailure)?;
    Ok(output)
}

fn array<'a, const N: usize>(
    bytes: &'a [u8],
    field: &'static str,
) -> Result<&'a [u8; N], CryptoError> {
    bytes.try_into().map_err(|_| CryptoError::InvalidLength {
        field,
        expected: N,
        actual: bytes.len(),
    })
}

fn bounded(actual: usize, maximum: usize) -> Result<(), CryptoError> {
    if actual > maximum {
        Err(CryptoError::InputTooLarge { actual, maximum })
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn derived_key_slices_match_public_fixture_and_debug_redacts() {
        let value: serde_json::Value = serde_json::from_str(include_str!(
            "../tests/fixtures/xiaomi-v2-synthetic-vectors.json"
        ))
        .unwrap();
        let bytes = |key: &str| hex::decode(value["auth"][key].as_str().unwrap()).unwrap();
        let keys = SessionKeys::derive(
            &bytes("phone_nonce"),
            &bytes("watch_nonce"),
            &bytes("synthetic_auth_key"),
        )
        .unwrap();
        assert_eq!(keys.decryption_key.as_slice(), bytes("decryption_key"));
        assert_eq!(keys.encryption_key.as_slice(), bytes("encryption_key"));
        assert_eq!(
            keys.decryption_nonce_prefix.as_slice(),
            bytes("decryption_nonce_prefix")
        );
        assert_eq!(
            keys.encryption_nonce_prefix.as_slice(),
            bytes("encryption_nonce_prefix")
        );
        assert_eq!(format!("{keys:?}"), "SessionKeys([REDACTED])");
    }
}
