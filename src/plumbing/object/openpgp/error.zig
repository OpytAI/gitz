//! OpenPGP error set and shared packet/cipher/hash constants.

pub const Error = error{
    InvalidArmor,
    InvalidPacket,
    UnsupportedAlgorithm,
    KeyNotFound,
    InvalidSignature,
    MultipleSignatures,
    /// Private key is still passphrase-encrypted (go-git: "signing key is encrypted").
    EncryptedKey,
    /// Wrong passphrase or corrupt secret-key material.
    DecryptFailed,
    /// Entity has no private key material (public-only ring).
    NoPrivateKey,
};

// Packet tags
pub const tag_public_key: u8 = 6;
pub const tag_public_subkey: u8 = 14;
pub const tag_secret_key: u8 = 5;
pub const tag_secret_subkey: u8 = 7;
pub const tag_user_id: u8 = 13;
pub const tag_signature: u8 = 2;

// Public-key algorithms
pub const pk_rsa: u8 = 1;
pub const pk_rsa_encrypt: u8 = 2;
pub const pk_rsa_sign: u8 = 3;
pub const pk_eddsa: u8 = 22;

// Hash algorithms
pub const hash_sha1: u8 = 2;
pub const hash_sha256: u8 = 8;
pub const hash_sha512: u8 = 10;

// Symmetric ciphers (OpenPGP IDs)
pub const cipher_aes128: u8 = 7;
pub const cipher_aes192: u8 = 8;
pub const cipher_aes256: u8 = 9;

// S2K specifier types (RFC 4880 §3.7)
pub const s2k_simple: u8 = 0;
pub const s2k_salted: u8 = 1;
pub const s2k_iterated: u8 = 3;

// Key flags subpacket (type 27): bit 0 certify, 1 sign, 2 encrypt comm, 3 encrypt storage
pub const key_flag_certify: u8 = 0x01;
pub const key_flag_sign: u8 = 0x02;
