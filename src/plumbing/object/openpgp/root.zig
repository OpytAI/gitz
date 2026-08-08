//! OpenPGP detached-signature verify **and** sign for Git.
//!
//! Mirrors go-git / ProtonMail go-crypto for the algorithms Git signing uses:
//! - ASCII armor (PUBLIC KEY BLOCK / PRIVATE KEY BLOCK / SIGNATURE)
//! - v4 public/secret key packets (RSA; EdDSA/Ed25519) + secret/public subkeys
//! - S2K simple / salted / iterated+salted (SHA-1 / SHA-256 / SHA-512)
//! - AES-128/192/256-CFB secret-key decrypt (usage 254 SHA-1 checksum, 255 sum16)
//! - v4 signature packets (SHA-1 / SHA-256 / SHA-512)
//! - RSA PKCS#1 v1.5 and Ed25519 (EdDSA) sign/verify over OpenPGP hash trailer
//! - Signing-key selection prefers a decrypted sign-capable subkey (go-crypto)
//! - `ArmoredDetachSign` for tag/commit signing (`CreateTagOptions.sign_key`)

const err_mod = @import("error.zig");
const armor_mod = @import("armor.zig");
const packet_mod = @import("packet.zig");
const s2k_mod = @import("s2k.zig");
const rsa_mod = @import("rsa.zig");
const entity_mod = @import("entity.zig");
const sign_mod = @import("sign.zig");
const verify_mod = @import("verify.zig");
const fixtures_mod = @import("fixtures.zig");

pub const Error = err_mod.Error;

// Constants re-exported for tests / advanced use.
pub const tag_public_key = err_mod.tag_public_key;
pub const tag_public_subkey = err_mod.tag_public_subkey;
pub const tag_secret_key = err_mod.tag_secret_key;
pub const tag_secret_subkey = err_mod.tag_secret_subkey;
pub const tag_user_id = err_mod.tag_user_id;
pub const tag_signature = err_mod.tag_signature;
pub const pk_rsa = err_mod.pk_rsa;
pub const pk_rsa_encrypt = err_mod.pk_rsa_encrypt;
pub const pk_rsa_sign = err_mod.pk_rsa_sign;
pub const pk_eddsa = err_mod.pk_eddsa;
pub const hash_sha1 = err_mod.hash_sha1;
pub const hash_sha256 = err_mod.hash_sha256;
pub const hash_sha512 = err_mod.hash_sha512;
pub const cipher_aes128 = err_mod.cipher_aes128;
pub const cipher_aes192 = err_mod.cipher_aes192;
pub const cipher_aes256 = err_mod.cipher_aes256;
pub const s2k_simple = err_mod.s2k_simple;
pub const s2k_salted = err_mod.s2k_salted;
pub const s2k_iterated = err_mod.s2k_iterated;
pub const key_flag_certify = err_mod.key_flag_certify;
pub const key_flag_sign = err_mod.key_flag_sign;

pub const decodeArmor = armor_mod.decodeArmor;
pub const encodeArmor = armor_mod.encodeArmor;
pub const crc24 = armor_mod.crc24;

pub const Packet = packet_mod.Packet;
pub const nextPacket = packet_mod.nextPacket;
pub const readMpi = packet_mod.readMpi;
pub const fingerprintV4 = packet_mod.fingerprintV4;
pub const appendPacket = packet_mod.appendPacket;
pub const appendMpi = packet_mod.appendMpi;
pub const appendSubpacket = packet_mod.appendSubpacket;

pub const s2kDerive = s2k_mod.s2kDerive;
pub const s2kCount = s2k_mod.s2kCount;
pub const cipherKeyLen = s2k_mod.cipherKeyLen;
pub const cipherBlockLen = s2k_mod.cipherBlockLen;
pub const aesCfbDecrypt = s2k_mod.aesCfbDecrypt;
pub const aesCfbEncrypt = s2k_mod.aesCfbEncrypt;
pub const sealSecretUsage254 = s2k_mod.sealSecretUsage254;

pub const rsaVerify = rsa_mod.rsaVerify;
pub const rsaSign = rsa_mod.rsaSign;

pub const KeyMaterial = entity_mod.KeyMaterial;
pub const Subkey = entity_mod.Subkey;
pub const Entity = entity_mod.Entity;
pub const freeEntities = entity_mod.freeEntities;
pub const readArmoredKeyRing = entity_mod.readArmoredKeyRing;
pub const generateEd25519Entity = entity_mod.generateEd25519Entity;
pub const generateEd25519Subkey = entity_mod.generateEd25519Subkey;
pub const entityAttachSubkey = entity_mod.entityAttachSubkey;
pub const buildEd25519PublicBody = entity_mod.buildEd25519PublicBody;

pub const armoredDetachSign = sign_mod.armoredDetachSign;
pub const buildV4SignaturePacket = sign_mod.buildV4SignaturePacket;
pub const selectSigningKey = sign_mod.selectSigningKey;
pub const SigningSelection = sign_mod.SigningSelection;

pub const checkArmoredDetachedSignature = verify_mod.checkArmoredDetachedSignature;
pub const parseKeyring = verify_mod.parseKeyring;
pub const parsePublicKey = verify_mod.parsePublicKey;
pub const parseSignature = verify_mod.parseSignature;
pub const parseDetachedSignature = verify_mod.parseDetachedSignature;
pub const PublicKey = verify_mod.PublicKey;
pub const Signature = verify_mod.Signature;
pub const hashDocument = verify_mod.hashDocument;

pub const go_git_armored_private_key = fixtures_mod.go_git_armored_private_key;
pub const go_git_key_passphrase = fixtures_mod.go_git_key_passphrase;
pub const fixtures = fixtures_mod;

test {
    _ = @import("tests.zig");
}
