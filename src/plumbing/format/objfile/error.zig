//! Shared error set for objfile reader and writer.
//!
//! Port of go-git v5.19.2 package-level `Err*` values in
//! `plumbing/format/objfile/{reader,writer}.go`.

/// Errors for objfile Reader/Writer (go-git package-level `Err*` names in comments).
pub const Error = error{
    /// objfile: already closed (`ErrClosed`)
    Closed,
    /// objfile: invalid header (`ErrHeader`)
    Header,
    /// objfile: Header must be called before Read (`ErrHeaderNotRead`)
    HeaderNotRead,
    /// objfile: negative object size (`ErrNegativeSize`)
    NegativeSize,
    /// objfile: declared data length exceeded (overflow) (`ErrOverflow`)
    Overflow,
    /// zlib inflate/deflate failure (go-git surfaces this via `packfile.ErrZLib`)
    ZLib,
};
