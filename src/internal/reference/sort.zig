//! Sort helpers for reference slices (go-git `internal/reference/sort.go`).

const std = @import("std");
const plumbing = @import("plumbing");

const Reference = plumbing.Reference;

/// Sort references by name ascending for a stable order
/// (go-git `reference.Sort` on `[]*plumbing.Reference`).
///
/// Compares `name.raw` with byte-order lexicographic order
/// (`std.mem.order`), matching Go string `<` on UTF-8 ref names.
pub fn sort(refs: []Reference) void {
    std.mem.sort(Reference, refs, {}, struct {
        fn less(_: void, a: Reference, b: Reference) bool {
            return std.mem.order(u8, a.name.raw, b.name.raw) == .lt;
        }
    }.less);
}

/// Sort a slice of reference pointers by name ascending
/// (closer to go-git's `[]*plumbing.Reference` surface).
pub fn sortPtrs(refs: []*const Reference) void {
    std.mem.sort(*const Reference, refs, {}, struct {
        fn less(_: void, a: *const Reference, b: *const Reference) bool {
            return std.mem.order(u8, a.name.raw, b.name.raw) == .lt;
        }
    }.less);
}
