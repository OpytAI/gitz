//! Transport package errors (go-git `plumbing/transport/common.go` package vars).

/// Error set for transport operations and endpoint parsing.
pub const Error = error{
    /// Repository was not found (go-git `ErrRepositoryNotFound`).
    RepositoryNotFound,
    /// Remote repository exists but is empty (go-git `ErrEmptyRemoteRepository`).
    EmptyRemoteRepository,
    /// Authentication is required (go-git `ErrAuthenticationRequired`).
    AuthenticationRequired,
    /// Authorization failed (go-git `ErrAuthorizationFailed`).
    AuthorizationFailed,
    /// Empty git-upload-pack request (go-git `ErrEmptyUploadPackRequest`).
    EmptyUploadPackRequest,
    /// Auth method is invalid for this transport (go-git `ErrInvalidAuthMethod`).
    InvalidAuthMethod,
    /// Session already established (go-git `ErrAlreadyConnected`).
    AlreadyConnected,
    /// Endpoint string is not a valid absolute URL (go-git permanent client error).
    InvalidEndpoint,
    /// Proxy URL failed to parse (go-git `ProxyOptions.Validate`).
    InvalidProxyURL,
    /// Unsupported URL scheme for `client.NewClient`.
    UnsupportedScheme,
    /// Protocol entry exists but the client is null/malformed.
    MalformedClient,
};
