//! Shared error set for objfile reader and writer.

/// Errors for objfile Reader/Writer (go-git package-level `Err*` names in comments).
pub const Error = error{
    /// objfile: already closed
    Closed,
    /// objfile: invalid header
    Header,
    /// objfile: Header must be called before Read
    HeaderNotRead,
    /// objfile: negative object size
    NegativeSize,
    /// objfile: declared data length exceeded (overflow)
    Overflow,
    /// zlib inflate/deflate failure (go-git surfaces this via packfile.ErrZLib)
    ZLib,
};
