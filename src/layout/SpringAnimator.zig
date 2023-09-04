const std = @import("std");

const Self = @This();

const Config = struct {
    target_value: ?f32 = null,
    initial_value: f32,
    initial_velocity: f32 = 0,
    mass: f32,
    stiffness: f32,
    damping: f32,
};

comptime {
    @setFloatMode(.Optimized);
}

// time of initial_value/velocity
start_time: std.time.Instant,

// equilibrium is always at 0 but we then add target_value to the result
target_value: f32,

// initial distance from equilibrium
x0: f32,
// initial velocity
v0: f32,
// natural oscillation frequency squared
w: f32,
// damping ratio
z: f32,

// Cache for performance
// w * sqrt(abs(1 - z^2))
a: f32,

pub fn start(conf: Config) Self {
    const k = conf.stiffness;
    const m = conf.mass;
    const c = conf.damping;

    const w = std.math.sqrt(k / m);
    const z = c / (2 * m * w);

    const target_value = conf.target_value orelse conf.initial_value;
    const x0 = conf.initial_value - target_value;

    return Self{
        .start_time = std.time.Instant.now() catch unreachable,
        .target_value = target_value,

        .x0 = x0,
        .v0 = conf.initial_velocity,
        .w = w,
        .z = z,

        .a = w * std.math.sqrt(std.math.fabs(1 - z * z)),
    };
}

pub fn stretch(self: *Self, new_target: f32) void {
    const x0 = self.eval() - new_target;
    const v0 = self.evalVelocity();

    self.x0 = x0;
    self.v0 = v0;
    self.target_value = new_target;
    self.start_time = std.time.Instant.now() catch unreachable;
}

// velocity at time t (derivative of position)
pub fn evalVelocity(self: Self) f32 {
    const now = std.time.Instant.now() catch unreachable;
    const t_nanos = now.since(self.start_time);
    const t_seconds: f32 = @as(f32, @floatFromInt(t_nanos)) / 1_000_000_000.0;
    const t = t_seconds;

    const w = self.w;
    const z = self.z;
    const x0 = self.x0;
    const v0 = self.v0;

    const a = self.a;
    const q = -w * z;

    // TODO: critically damped
    if (self.z < 1.0) {
        // underdamped //
        // const a = w * std.math.sqrt(1 - z * z);
        const p1 = (v0 - x0 * q) / a;

        return std.math.exp(t * q) * ( //
            (q * x0 + a * p1) * std.math.cos(t * a) +
            (q * p1 - a * x0) * std.math.sin(t * a) //
        );
    } else {
        // overdamped //
        // const a = w * std.math.sqrt(z * z - 1);
        const p2 = (v0 - x0 * (q - a)) / (2 * a);

        return (x0 - p2) * (q - a) * std.math.exp(t * (q - a)) +
            p2 * (q + a) * std.math.exp(t * (q + a));
    }
}

// position at time t
pub fn eval(self: Self) f32 {
    const now = std.time.Instant.now() catch unreachable;
    const t_nanos = now.since(self.start_time);
    const t_seconds: f32 = @as(f32, @floatFromInt(t_nanos)) / 1_000_000_000.0;
    const t = t_seconds;

    const w = self.w;
    const z = self.z;
    const x0 = self.x0;
    const v0 = self.v0;

    const a = self.a;
    const q = -w * z;

    // TODO: critically damped
    if (self.z < 1.0) {
        // underdamped //
        // const a = w * std.math.sqrt(1 - z * z);
        const p1 = (v0 - x0 * q) / a;

        return std.math.exp(t * q) * ( //
            x0 * std.math.cos(t * a) +
            p1 * std.math.sin(t * a) //
        ) + self.target_value;
    } else {
        // overdamped //
        // const a = w * std.math.sqrt(z * z - 1);
        const p2 = (v0 - x0 * (q - a)) / (2 * a);

        return (x0 - p2) * std.math.exp(t * (q - a)) +
            p2 * std.math.exp(t * (q + a)) + self.target_value;
    }
}
