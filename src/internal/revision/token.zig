//! Lexical tokens for revision strings (go-git `internal/revision/token.go`).

/// Entity extracted from revision string scanning (go-git unexported `token`).
pub const Token = enum(u8) {
    eof = 0,
    aslash,
    asterisk,
    at,
    caret,
    cbrace,
    colon,
    control,
    dot,
    emark,
    minus,
    number,
    obrace,
    obracket,
    qmark,
    slash,
    space,
    tilde,
    token_error,
    word,
};
