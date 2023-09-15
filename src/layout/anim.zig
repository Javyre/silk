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
pub const ValueRef = struct {
    value: *Value,
    engines: *Engines,
    alloc: std.mem.Allocator,

    pub fn setSpring(
        self: *const ValueRef,
        cfg: SpringEngine.Config,
    ) !void {
        return self.value.setSpring(self.alloc, self.engines, cfg);
    }

    pub fn getValue(self: *const ValueRef) f32 {
        return self.value.getValue(self.engines);
    }

    pub fn isDone(self: *const ValueRef) bool {
        return self.value.isDone(self.engines);
    }
};

pub const Value = union(enum) {
    immediate: f32,
    spring: SpringEngine.SpringIdx,

    pub const zero = .{ .immediate = 0.0 };

    pub fn setSpring(
        self: *Value,
        alloc: std.mem.Allocator,
        engines: *Engines,
        cfg_: SpringEngine.Config,
    ) !void {
        var cfg = cfg_;
        cfg.initial_value = cfg_.initial_value orelse self.getValue(engines);

        switch (self.*) {
            .immediate => {
                self.* = .{
                    .spring = try engines.spring.newSpring(alloc, cfg),
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
