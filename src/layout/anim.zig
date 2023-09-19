const std = @import("std");
const geo = @import("../geo.zig");

const SpringEngine = @import("anim/SpringEngine.zig");

pub const Engines = struct {
    spring: SpringEngine,

    pub fn init(alloc: std.mem.Allocator) !Engines {
        return .{
            .spring = try SpringEngine.init(alloc),
        };
    }

    pub fn deinit(self: *Engines, alloc: std.mem.Allocator) void {
        self.spring.deinit(alloc);
    }

    pub fn update(self: *Engines) void {
        self.spring.update();
    }
};

pub const Box = struct {
    x: Value,
    y: Value,
    width: Value,
    height: Value,

    pub fn initImmediate(box: geo.Box) Box {
        return .{
            .x = .{ .immediate = box.x },
            .y = .{ .immediate = box.y },
            .width = .{ .immediate = box.width },
            .height = .{ .immediate = box.height },
        };
    }

    pub fn getValue(self: *const Box, engines: *Engines) geo.Box {
        return .{
            .x = self.x.getValue(engines),
            .y = self.y.getValue(engines),
            .width = self.width.getValue(engines),
            .height = self.height.getValue(engines),
        };
    }
};

// TODO: better name?
pub fn ValueRef(comptime n: comptime_int) type {
    std.debug.assert(n > 0);

    return struct {
        values: [n]*Value,
        engines: *Engines,
        alloc: std.mem.Allocator,

        pub fn setValue(
            self: *const @This(),
            target: f32,
        ) !void {
            for (self.values) |value| {
                try value.setValue(self.alloc, self.engines, target);
            }
        }

        pub fn setSpring(
            self: *const @This(),
            cfg: PartialSpringConfig,
        ) !void {
            for (self.values) |value| {
                try value.setSpring(self.alloc, self.engines, cfg);
            }
        }

        pub usingnamespace if (n == 1) struct {
            pub fn getValue(self: *const @This()) f32 {
                return self.values[0].getValue(self.engines);
            }
        } else struct {
            pub fn getValue(self: *const @This()) [n]f32 {
                var result: [n]f32 = undefined;
                for (result, 0..) |*value, i| {
                    value.* = self.values[i].getValue(self.engines);
                }
                return result;
            }
        };

        pub fn isDone(self: *const @This()) bool {
            for (self.values) |value| {
                if (!value.isDone(self.engines)) return false;
            }
            return true;
        }
    };
}

const PartialSpringConfig = struct {
    target_value: ?f32 = null,
    initial_value: ?f32 = null,
    initial_velocity: ?f32 = null,

    mass: ?f32 = null,
    stiffness: ?f32 = null,
    damping: ?f32 = null,
};

pub const Value = union(enum) {
    immediate: f32,
    spring: SpringEngine.SpringIdx,

    pub const zero = .{ .immediate = 0.0 };

    pub fn setValue(
        self: *Value,
        alloc: std.mem.Allocator,
        engines: *Engines,
        value: f32,
    ) !void {
        _ = alloc;
        switch (self.*) {
            .immediate => {
                self.* = .{ .immediate = value };
            },
            .spring => |spring_ref| {
                engines.spring.updateSpring(spring_ref, .{
                    .target_value = value,
                });
            },
        }
    }

    pub fn setSpring(
        self: *Value,
        alloc: std.mem.Allocator,
        engines: *Engines,
        cfg_: PartialSpringConfig,
    ) !void {
        var cfg = cfg_;
        cfg.initial_value = cfg_.initial_value orelse self.getValue(engines);

        switch (self.*) {
            .immediate => {
                self.* = .{
                    .spring = try engines.spring.newSpring(alloc, .{
                        .target_value = cfg.target_value,
                        .initial_value = cfg.initial_value,
                        .initial_velocity = cfg.initial_velocity,

                        .mass = cfg.mass orelse 1.0,
                        .stiffness = cfg.stiffness orelse 95.0,
                        .damping = cfg.damping orelse 16.0,
                    }),
                };
            },
            .spring => |spring_ref| {
                engines.spring.updateSpring(spring_ref, .{
                    .target_value = cfg.target_value,
                    .current_value = cfg.initial_value,
                    .current_velocity = cfg.initial_velocity,

                    .mass = cfg.mass,
                    .stiffness = cfg.stiffness,
                    .damping = cfg.damping,
                });
            },
        }
    }

    pub fn getValue(self: *const Value, engines: *Engines) f32 {
        switch (self.*) {
            .immediate => |value| {
                return value;
            },
            .spring => |spring_ref| {
                return engines.spring.getPosition(spring_ref);
            },
        }
    }

    // TODO: use this to turn animated values into immediate values at some
    // point in the lifecycle.
    pub fn isDone(self: *const Value, engines: *Engines) bool {
        switch (self.*) {
            .immediate => return true,
            .spring => |spring_ref| {
                return engines.spring.isDone(spring_ref);
            },
        }
    }
};

pub const Color = struct {
    r: Value,
    g: Value,
    b: Value,
    a: Value,

    pub const transparent = .{
        .r = .{ .immediate = 0.0 },
        .g = .{ .immediate = 0.0 },
        .b = .{ .immediate = 0.0 },
        .a = .{ .immediate = 0.0 },
    };
};
