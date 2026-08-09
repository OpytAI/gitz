//! Type-erased ConfigStorer contract.
//!
//! The config value type is a parameter because high-level `config.Config`
//! and storage's compact persisted config are intentionally distinct models.

pub fn ConfigStorer(comptime ConfigType: type) type {
    return struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        const Self = @This();
        const VTable = struct {
            config: *const fn (*anyopaque) anyerror!*ConfigType,
            set_config: *const fn (*anyopaque, *ConfigType) anyerror!void,
        };

        pub fn from(comptime Store: type, store: *Store) Self {
            return .{ .ptr = store, .vtable = &.{
                .config = struct {
                    fn call(ptr: *anyopaque) anyerror!*ConfigType {
                        return (@as(*Store, @ptrCast(@alignCast(ptr)))).config();
                    }
                }.call,
                .set_config = struct {
                    fn call(ptr: *anyopaque, value: *ConfigType) anyerror!void {
                        return (@as(*Store, @ptrCast(@alignCast(ptr)))).setConfig(value);
                    }
                }.call,
            } };
        }

        pub fn config(self: Self) anyerror!*ConfigType {
            return self.vtable.config(self.ptr);
        }

        /// Ownership follows the concrete backend contract. Callers must use
        /// one adapter consistently rather than assume interface ownership.
        pub fn setConfig(self: Self, value: *ConfigType) anyerror!void {
            return self.vtable.set_config(self.ptr, value);
        }
    };
}
