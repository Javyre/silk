const std = @import("std");

const Self = @This();

init_time: std.time.Instant,

under_damped: UnderDampedSpringBatches,
// total amount of indiviual springs (not batches)
under_damped_len: usize,

over_damped: OverDampedSpringBatches,
// total amount of indiviual springs (not batches)
over_damped_len: usize,

const BATCH_SIZE = 16;

const BatchVec = @Vector(BATCH_SIZE, f32);
const UnderDampedSpringBatches = std.MultiArrayList(UnderDampedSpring(BatchVec));
const OverDampedSpringBatches = std.MultiArrayList(OverDampedSpring(BatchVec));

fn UnderDampedSpring(comptime T: type) type {
    return struct {
        // equilibrium is always at 0 but we then add target_value to the result
        target_value: T,
        // current distance from equilibrium + target_value
        current_value: T,

        // time of initial_value/velocity
        t0: T,

        // initial distance from equilibrium
        x0: T,
        // initial velocity
        v0: T,
        // natural oscillation frequency squared
        w: T,
        // damping ratio
        z: T,

        // Cache for performance
        // w * sqrt(abs(1 - z^2))
        a: T,
    };
}
const OverDampedSpring = UnderDampedSpring;

pub const SpringIdx = packed struct(u32) {
    is_underdamped: bool,
    idx: u31,
};

pub fn init(alloc: std.mem.Allocator) !Self {
    const init_time = try std.time.Instant.now();

    var under_damped = UnderDampedSpringBatches{};
    var over_damped = OverDampedSpringBatches{};

    try under_damped.ensureTotalCapacity(alloc, 256 / BATCH_SIZE);
    try over_damped.ensureTotalCapacity(alloc, 256 / BATCH_SIZE);

    return .{
        .init_time = init_time,
        .under_damped = under_damped,
        .under_damped_len = 0,
        .over_damped = over_damped,
        .over_damped_len = 0,
    };
}

pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
    defer self.under_damped.deinit(alloc);
    defer self.over_damped.deinit(alloc);
}

const Config = struct {
    target_value: ?f32 = null,
    initial_value: f32,
    initial_velocity: f32 = 0,
    mass: f32,
    stiffness: f32,
    damping: f32,
};

fn appendUnderDamped(
    self: *Self,
    alloc: std.mem.Allocator,
    spring: UnderDampedSpring(f32),
) !SpringIdx {
    const batch_ofs = self.under_damped_len % BATCH_SIZE;
    const batch_idx = self.under_damped_len / BATCH_SIZE;

    if (batch_ofs == 0) {
        try self.under_damped.append(alloc, std.mem.zeroes(UnderDampedSpring(BatchVec)));
    }

    // TODO: cast into a simple array of springs instead of array of batches

    const slice = self.under_damped.slice();
    slice.items(.target_value)[batch_idx][batch_ofs] = spring.target_value;
    slice.items(.current_value)[batch_idx][batch_ofs] = spring.current_value;
    slice.items(.t0)[batch_idx][batch_ofs] = spring.t0;
    slice.items(.x0)[batch_idx][batch_ofs] = spring.x0;
    slice.items(.v0)[batch_idx][batch_ofs] = spring.v0;
    slice.items(.w)[batch_idx][batch_ofs] = spring.w;
    slice.items(.z)[batch_idx][batch_ofs] = spring.z;
    slice.items(.a)[batch_idx][batch_ofs] = spring.a;

    const ret = SpringIdx{
        .is_underdamped = true,
        .idx = @intCast(self.under_damped_len),
    };
    self.under_damped_len += 1;

    return ret;
}

fn appendOverDamped(
    self: *Self,
    alloc: std.mem.Allocator,
    spring: OverDampedSpring(f32),
) !SpringIdx {
    const batch_ofs = self.over_damped_len % BATCH_SIZE;
    const batch_idx = self.over_damped_len / BATCH_SIZE;

    if (batch_ofs == 0) {
        try self.over_damped.append(alloc, std.mem.zeroes(OverDampedSpring(BatchVec)));
    }

    // TODO: cast into a simple array of springs instead of array of batches

    const slice = self.over_damped.slice();
    slice.items(.target_value)[batch_idx][batch_ofs] = spring.target_value;
    slice.items(.current_value)[batch_idx][batch_ofs] = spring.current_value;
    slice.items(.t0)[batch_idx][batch_ofs] = spring.t0;
    slice.items(.x0)[batch_idx][batch_ofs] = spring.x0;
    slice.items(.v0)[batch_idx][batch_ofs] = spring.v0;
    slice.items(.w)[batch_idx][batch_ofs] = spring.w;
    slice.items(.z)[batch_idx][batch_ofs] = spring.z;
    slice.items(.a)[batch_idx][batch_ofs] = spring.a;

    const ret = SpringIdx{
        .is_underdamped = false,
        .idx = @intCast(self.over_damped_len),
    };
    self.over_damped_len += 1;

    return ret;
}

pub fn newSpring(
    self: *Self,
    alloc: std.mem.Allocator,
    conf: Config,
) !SpringIdx {
    const k = conf.stiffness;
    const m = conf.mass;
    const c = conf.damping;

    const w = std.math.sqrt(k / m);
    const z = c / (2 * m * w);

    const target_value = conf.target_value orelse conf.initial_value;
    const x0 = conf.initial_value - target_value;

    if (z < 1.0) {
        return try self.appendUnderDamped(alloc, .{
            .target_value = target_value,
            .current_value = conf.initial_value,
            .t0 = 0,
            .x0 = x0,
            .v0 = conf.initial_velocity,
            .w = w,
            .z = z,
            .a = w * std.math.sqrt(1 - z * z),
        });
    } else if (z > 1.0) {
        return try self.appendOverDamped(alloc, .{
            .target_value = target_value,
            .current_value = conf.initial_value,
            .t0 = 0,
            .x0 = x0,
            .v0 = conf.initial_velocity,
            .w = w,
            .z = z,
            .a = w * std.math.sqrt(z * z - 1),
        });
    } else {
        // TODO: Critical damping
        @panic("Critical damping is not supported");
    }
}

pub fn getPosition(self: *Self, idx: SpringIdx) f32 {
    const batch_idx = idx.idx / BATCH_SIZE;
    const batch_ofs = idx.idx % BATCH_SIZE;
    const slice = self.under_damped.slice();
    return slice.items(.current_value)[batch_idx][batch_ofs];
}

pub fn updatePositions(self: *Self) void {
    const global_t = @as(BatchVec, @splat(self.getTimeOffset()));

    const ud_slice = self.under_damped.slice();
    const od_slice = self.over_damped.slice();

    for (
        ud_slice.items(.target_value),
        ud_slice.items(.current_value),
        ud_slice.items(.t0),
        ud_slice.items(.x0),
        ud_slice.items(.v0),
        ud_slice.items(.w),
        ud_slice.items(.z),
        ud_slice.items(.a),
    ) |target_value, *current_value, t0, x0, v0, w, z, a| {
        const t = global_t - t0;

        // const a = w * std.math.sqrt(1 - z * z);
        const q = @as(BatchVec, @splat(-1)) * w * z;
        const p1 = (v0 - x0 * q) / a;
        const new_value = @exp(t * q) * ( //
            x0 * @cos(t * a) +
            p1 * @sin(t * a) //
        ) + target_value;

        current_value.* = new_value;
    }

    for (
        od_slice.items(.target_value),
        od_slice.items(.current_value),
        od_slice.items(.t0),
        od_slice.items(.x0),
        od_slice.items(.v0),
        od_slice.items(.w),
        od_slice.items(.z),
        od_slice.items(.a),
    ) |target_value, *current_value, t0, x0, v0, w, z, a| {
        const t = global_t - t0;

        // const a = w * std.math.sqrt(z * z - 1);
        const q = @as(BatchVec, @splat(-1)) * w * z;
        const p2 = (v0 - x0 * (q - a)) / (@as(BatchVec, @splat(2)) * a);
        const new_value = //
            (x0 - p2) * @exp(t * (q - a)) +
            p2 * @exp(t * (q + a)) + //
            target_value;

        current_value.* = new_value;
    }
}

pub fn getVelocity(self: *Self, idx: SpringIdx) f32 {
    const batch_idx = idx.idx / BATCH_SIZE;
    const batch_ofs = idx.idx % BATCH_SIZE;

    const global_t = self.getTimeOffset();

    if (idx.is_underdamped) {
        // underdamped //
        const ud_slice = self.under_damped.slice();

        const t0 = ud_slice.items(.t0)[batch_idx][batch_ofs];
        const t = global_t - t0;

        const w = ud_slice.items(.w)[batch_idx][batch_ofs];
        const z = ud_slice.items(.z)[batch_idx][batch_ofs];
        const x0 = ud_slice.items(.x0)[batch_idx][batch_ofs];
        const v0 = ud_slice.items(.v0)[batch_idx][batch_ofs];

        // const a = w * std.math.sqrt(1 - z * z);
        const a = ud_slice.items(.a)[batch_idx][batch_ofs];
        const q = -1 * w * z;

        const p1 = (v0 - x0 * q) / a;

        return @exp(t * q) * ( //
            (q * x0 + a * p1) * @cos(t * a) +
            (q * p1 - a * x0) * @sin(t * a) //
        );
    } else {
        // overdamped //
        const od_slice = self.over_damped.slice();

        const t0 = od_slice.items(.t0)[batch_idx][batch_ofs];
        const t = global_t - t0;

        const w = od_slice.items(.w)[batch_idx][batch_ofs];
        const z = od_slice.items(.z)[batch_idx][batch_ofs];
        const x0 = od_slice.items(.x0)[batch_idx][batch_ofs];
        const v0 = od_slice.items(.v0)[batch_idx][batch_ofs];

        // const a = w * std.math.sqrt(z * z - 1);
        const a = od_slice.items(.a)[batch_idx][batch_ofs];
        const q = -1 * w * z;

        const p2 = (v0 - x0 * (q - a)) / (2 * a);

        return (x0 - p2) * (q - a) * @exp(t * (q - a)) +
            p2 * (q + a) * @exp(t * (q + a));
    }
}

pub fn stretchSpring(
    self: *Self,
    idx: SpringIdx,
    new_target_value: f32,
) void {
    const batch_idx = idx.idx / BATCH_SIZE;
    const batch_ofs = idx.idx % BATCH_SIZE;
    const slice = self.under_damped.slice();

    // NOTE: we access a single item of the vector but this might be accessing
    // the whole batch from memory. If that's the case, we should cast the slice
    // of batches into a slice of individual f32s.
    //
    // NOTE: we use x0 from the previous update, not the actual position given
    // the current time. This should hopefully not be a problem if the time
    // since the last update is small enough.
    const old_current_value = slice.items(.current_value)[batch_idx][batch_ofs];

    const x0 = old_current_value - new_target_value;
    const v0 = self.getVelocity(idx);

    slice.items(.x0)[batch_idx][batch_ofs] = x0;
    slice.items(.v0)[batch_idx][batch_ofs] = v0;
    slice.items(.target_value)[batch_idx][batch_ofs] = new_target_value;
    slice.items(.t0)[batch_idx][batch_ofs] = self.getTimeOffset();
}

fn getTimeOffset(self: *const Self) f32 {
    const now = std.time.Instant.now() catch unreachable;
    const duration_nanos = now.since(self.init_time);
    const duration_secs: f32 = @as(f32, @floatFromInt(duration_nanos)) / 1_000_000_000;
    return duration_secs;
}

fn batchFromSlice(slice: []f32) BatchVec {
    return slice[0..BATCH_SIZE].*;
}
