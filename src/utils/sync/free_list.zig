//! Intrusive single-threaded free list.
//!
//! Node type `T` must have a field `next: ?*T`. Not thread-safe; document any
//! concurrent use as unsupported (go-git uses `sync.Pool`).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Free list of heap-allocated nodes linked through `T.next`.
pub fn FreeList(comptime T: type) type {
    return struct {
        head: ?*T = null,

        const Self = @This();

        /// Pop a node, or `null` if empty.
        pub fn get(self: *Self) ?*T {
            const node = self.head orelse return null;
            self.head = node.next;
            node.next = null;
            return node;
        }

        /// Push `node` onto the free list.
        pub fn put(self: *Self, node: *T) void {
            node.next = self.head;
            self.head = node;
        }

        /// Destroy every retained node via `destroy_fn`.
        pub fn drain(self: *Self, allocator: Allocator, destroy_fn: *const fn (Allocator, *T) void) void {
            while (self.get()) |node| {
                destroy_fn(allocator, node);
            }
        }
    };
}

test "FreeList get put drain" {
    const Node = struct {
        id: u32,
        next: ?*@This() = null,
    };
    var list: FreeList(Node) = .{};
    var a: Node = .{ .id = 1 };
    var b: Node = .{ .id = 2 };
    list.put(&a);
    list.put(&b);
    try std.testing.expectEqual(@as(u32, 2), list.get().?.id);
    try std.testing.expectEqual(@as(u32, 1), list.get().?.id);
    try std.testing.expect(list.get() == null);

    list.put(&a);
    list.drain(std.testing.allocator, struct {
        fn destroy(_: Allocator, _: *Node) void {}
    }.destroy);
    try std.testing.expect(list.get() == null);
}
