//! storage/memory errors (go-git `storage/memory`).

/// Error set for the in-memory storage backend.
pub const Error = error{
    /// Object type cannot be stored in type maps (go-git `ErrUnsupportedObjectType`).
    /// Returned for OFS/REF delta and other non commit/tree/blob/tag types on Set.
    UnsupportedObjectType,
    /// Operation is not supported by this backend (go-git `errNotSupported`).
    NotSupported,
};
