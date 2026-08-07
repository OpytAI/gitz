//! Package fsnoder — readable merkletrie trees for tests.
//!
//! Port of go-git v5.19.2 `utils/merkletrie/internal/fsnoder`.

const dir_mod = @import("dir.zig");
const file_mod = @import("file.zig");
const new_mod = @import("new.zig");

pub const Dir = dir_mod.Dir;
pub const File = file_mod.File;
pub const Child = dir_mod.Child;
pub const Tree = new_mod.Tree;
pub const New = new_mod.New;
pub const hashEqual = new_mod.hashEqual;
pub const Error = new_mod.Error;

test {
    _ = @import("file.zig");
    _ = @import("dir.zig");
    _ = @import("new.zig");
}
