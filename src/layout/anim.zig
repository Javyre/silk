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

        pub fn set(self: *const @This(), spec: ValueSpec) !void {
            for (self.values) |val| {
                try val.set(self.alloc, self.engines, spec);
            }
        }

        pub fn getValue(self: *const @This()) if (n == 1) f32 else [n]f32 {
            var result: [n]f32 = undefined;
            for (&result, 0..) |*val, i| {
                val.* = self.values[i].getValue(self.engines);
            }
            if (n == 1) return result[0];
            return result;
        }

        pub fn isDone(self: *const @This()) bool {
            for (self.values) |val| {
                if (!val.isDone(self.engines)) return false;
            }
            return true;
        }
    };
}

const ValueConfig = union(enum) {
    immediate: f32,
    spring: SpringEngine.Config,
};

const PartialValueConfig = union(enum) {
    none: struct {
        initial_value: ?f32,
        target_value: ?f32,
    },
    immediate: ?f32,
    spring: SpringEngine.PartialConfig,
};

/// Encodes initialization/mutation commands for a Value.
///
/// It's through the facade of ValueSpecs that you control Values
/// as an end-user.
pub const ValueSpec = struct {
    from_value: ?f32 = null,
    target_value: ?f32 = null,

    // params unique to spring that we don't want leaking to other anim
    // types during resolution.
    spring_params: SpringParams = .{},

    anim_type: enum {
        none,
        immediate,
        spring,
    } = .none,

    const SpringParams = struct {
        initial_velocity: ?f32 = null,
        mass: ?f32 = null,
        stiffness: ?f32 = null,
        damping: ?f32 = null,
    };

    /// Set the target value of the Value.
    pub fn value(self: @This(), new_value: f32) @This() {
        var ret = self;
        ret.target_value = new_value;
        return ret;
    }

    /// Set the starting value of the Value.
    pub fn from(self: @This(), new_value: f32) @This() {
        var ret = self;
        ret.from_value = new_value;
        return ret;
    }

    /// Override fields in the spring config of this value.
    ///
    /// Implicitly converts immediate to spring animated Value.
    pub fn spring(self: @This(), new_cfg: SpringEngine.PartialConfig) @This() {
        var ret = self;
        ret.anim_type = .spring;
        if (new_cfg.target_value) |val|
            ret.target_value = val;
        if (new_cfg.initial_value) |val|
            ret.from_value = val;
        // non-shared params
        inline for (comptime std.meta.fieldNames(SpringParams)) |fname|
            @field(ret.spring_params, fname) = @field(new_cfg, fname);
        return ret;
    }

    /// Set the value to be immediate.
    pub fn immediate(Self: @This()) @This() {
        var ret = Self;
        ret.anim_type = .immediate;
        return ret;
    }

    /// Resolve this spec into a final config for initializing a Value.
    fn resolveInit(self: @This()) ValueConfig {
        const current_value =
            self.target_value orelse
            self.from_value orelse 0.0;

        return switch (self.resolveDelta()) {
            .none => .{
                .immediate = current_value,
            },
            .immediate => |val| .{
                .immediate = val orelse current_value,
            },
            .spring => |cfg| .{
                .spring = .{
                    .target_value = cfg.target_value orelse current_value,
                    .initial_value = cfg.initial_value orelse current_value,
                    .initial_velocity = cfg.initial_velocity orelse 0.0,
                    .mass = cfg.mass orelse 1.0,
                    .stiffness = cfg.stiffness orelse 95.0,
                    .damping = cfg.damping orelse 16.0,
                },
            },
        };
    }

    /// Resolve this spec into a final delta-config for mutating a Value.
    fn resolveDelta(self: @This()) PartialValueConfig {
        const sp = self.spring_params;
        return switch (self.anim_type) {
            .none => .{
                .none = .{
                    .initial_value = self.from_value,
                    .target_value = self.target_value,
                },
            },
            .immediate => .{ .immediate = self.target_value },
            .spring => .{
                .spring = .{
                    .target_value = self.target_value,
                    .initial_value = self.from_value,
                    .initial_velocity = sp.initial_velocity,
                    .mass = sp.mass,
                    .stiffness = sp.stiffness,
                    .damping = sp.damping,
                },
            },
        };
    }
};

/// Set the target value of the Value.
pub fn value(val: f32) ValueSpec {
    return (ValueSpec{}).value(val);
}

/// Set the starting value of the Value.
pub fn from(val: f32) ValueSpec {
    return (ValueSpec{}).from(val);
}

/// Override fields in the spring config of this value.
pub fn spring(new_cfg: SpringEngine.PartialConfig) ValueSpec {
    return (ValueSpec{}).spring(new_cfg);
}

/// Set the value to be immediate.
pub fn immediate() ValueSpec {
    return (ValueSpec{}).immediate();
}

test "ValueSpec common fields equivalent result" {
    // All equivalent
    const specs = .{
        value(50.0).spring(.{}).from(0),
        spring(.{}).value(50.0).from(0),
        from(0).value(50.0).spring(.{}),
        spring(.{ .target_value = 50.0 }).from(0),
        spring(.{ .initial_value = 0 }).value(50),
        spring(.{ .target_value = 50.0, .initial_value = 0 }),
        spring(.{ .target_value = 50.0, .initial_value = 0 }),
    };

    inline for (specs) |spec| {
        try std.testing.expectEqual(PartialValueConfig{
            .spring = .{
                .target_value = 50.0,
                .initial_value = 0,
            },
        }, spec.resolveDelta());
        try std.testing.expectEqual(PartialValueConfig{
            .immediate = 50.0,
        }, spec.immediate().resolveDelta());
    }
}

pub const Value = union(enum) {
    immediate: f32,
    spring: SpringEngine.SpringIdx,

    pub const zero = .{ .immediate = 0.0 };

    pub fn init(
        alloc: std.mem.Allocator,
        engines: *Engines,
        valueSpec: ValueSpec,
    ) !@This() {
        return switch (valueSpec.resolveInit()) {
            .immediate => |val| .{ .immediate = val },
            .spring => |cfg| .{
                .spring = try engines.spring.newSpring(alloc, cfg),
            },
        };
    }

    /// Update the value according to the given spec.
    pub fn set(
        self: *Value,
        alloc: std.mem.Allocator,
        engines: *Engines,
        value_spec: ValueSpec,
    ) !void {
        var delta = value_spec.resolveDelta();
        switch (self.*) {
            .immediate => |*val| switch (delta) {
                .none => |new_cfg| {
                    if (new_cfg.initial_value orelse
                        new_cfg.target_value) |new_val|
                        val.* = new_val;
                },
                .immediate => |new_val| if (new_val) |nv| {
                    val.* = nv;
                },
                .spring => |*new_cfg| {
                    if (new_cfg.initial_value == null)
                        new_cfg.initial_value = val.*;

                    self.* = .{
                        .spring = try engines.spring.newSpring(
                            alloc,
                            new_cfg.toConfig(),
                        ),
                    };
                },
            },
            .spring => |spring_ref| switch (delta) {
                .none => |new_cfg| {
                    if (new_cfg.initial_value orelse
                        new_cfg.target_value == null)
                        engines.spring.updateSpring(spring_ref, .{
                            .initial_value = new_cfg.initial_value,
                            .target_value = new_cfg.target_value,
                        });
                },
                .immediate => |new_val| {
                    const nv = new_val orelse
                        engines.spring.getPosition(spring_ref);
                    engines.spring.freeSpring(spring_ref);
                    self.* = .{ .immediate = nv };
                },

                .spring => |new_cfg| {
                    engines.spring.updateSpring(spring_ref, new_cfg);
                },
            },
        }
    }

    /// Get the current value of the Value.
    pub fn getValue(self: *const Value, engines: *Engines) f32 {
        switch (self.*) {
            .immediate => |val| {
                return val;
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

pub const ColorSpec = struct {
    r: ValueSpec,
    g: ValueSpec,
    b: ValueSpec,
    a: ValueSpec = value(1.0),
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

    pub fn init(
        alloc: std.mem.Allocator,
        engines: *Engines,
        spec: ColorSpec,
    ) !Color {
        var ret: Color = undefined;
        inline for (comptime std.meta.fieldNames(Color)) |fname| {
            @field(ret, fname) = try Value.init(alloc, engines, @field(spec, fname));
        }
        return ret;
    }

    pub fn set(
        self: *Color,
        alloc: std.mem.Allocator,
        engines: *Engines,
        spec: ColorSpec,
    ) !void {
        inline for (comptime std.meta.fieldNames(Color)) |fname| {
            try @field(self, fname).set(alloc, engines, spec.*);
        }
    }
};

// NOTE: does nothing now but can be more "smart" later?
pub fn color(spec: ColorSpec) ColorSpec {
    return spec;
}

pub fn transparent() ColorSpec {
    return color(.{
        .r = value(0.0),
        .g = value(0.0),
        .b = value(0.0),
        .a = value(0.0),
    });
}
