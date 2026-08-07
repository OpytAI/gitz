//! Repository format version and object format constants.
//!
//! Port of go-git v5.19.2 `plumbing/format/config/format.go`.

/// Repository format version as per
/// https://git-scm.com/docs/repository-version
pub const RepositoryFormatVersion = []const u8;

/// Version 0 — initial git repository format (go-git `Version_0`).
pub const Version0: RepositoryFormatVersion = "0";

/// Version 1 — same as 0 plus required extensions.* keys (go-git `Version_1`).
pub const Version1: RepositoryFormatVersion = "1";

/// Default repository format version (Version0).
pub const DefaultRepositoryFormatVersion: RepositoryFormatVersion = Version0;

/// Object hash format name.
pub const ObjectFormat = []const u8;

/// SHA-1 object format.
pub const SHA1: ObjectFormat = "sha1";

/// SHA-256 object format.
pub const SHA256: ObjectFormat = "sha256";

/// Default object format (SHA1).
pub const DefaultObjectFormat: ObjectFormat = SHA1;
