const std = @import("std");

comptime {
    @setFloatMode(.Optimized);
}

const Self = @This();

init_time: std.time.Instant,

under_damped: UnderDampedSpringBatches,
// total amount of indiviual springs (not batches)
under_damped_len: usize,

over_damped: OverDampedSpringBatches,
// total amount of indiviual springs (not batches)
over_damped_len: usize,

const BATCH_SIZE = 16;

// TODO: use separate batch index and offset fields with sizes based on
// BATCH_SIZE.
// TODO: rename to SpringRef
pub const SpringIdx = packed struct(u32) {
    is_underdamped: bool,
    idx: u31,
};

const BatchVec = @Vector(BATCH_SIZE, f32);
const UnderDampedSpringBatches = std.MultiArrayList(UnderDampedSpring(BatchVec));
const OverDampedSpringBatches = std.MultiArrayList(OverDampedSpring(BatchVec));

fn MergeFields(comptime T1: type, comptime T2: type) type {
    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = std.meta.fields(T1) ++ std.meta.fields(T2),
            .decls = &.{},
            .is_tuple = false,
        },
    });
}

fn BaseSpring(comptime T: type) type {
    return struct {
        // equilibrium is always at 0 but we then add target_value to the result
        target_value: T,
        // current distance from equilibrium + target_value
        current_value: T,

        // time of initial_value/velocity
        t0: T,

        // initial distance from equilibrium
        x0: T,
        // initial velocity (units/s)
        v0: T,
        // natural oscillation frequency (equilibrium/pi*s)
        w: T,
        // damping ratio
        z: T,

        // Cache for performance
        // w * sqrt(abs(1 - z^2))
        a: T,
    };
}
fn UnderDampedSpring(comptime T: type) type {
    return MergeFields(
        BaseSpring(T),
        struct {
            // velocity at latest refresh time
            v: T,
        },
    );
}
fn OverDampedSpring(comptime T: type) type {
    return BaseSpring(T);
}

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

fn calcSpringProperties(cfg: struct {}) union(enum) {
    under_damped: struct {
        w: f32,
        z: f32,
        a: f32,
    },
    over_damped: struct {
        w: f32,
        z: f32,
        a: f32,
    },
} {
    _ = cfg;
}

pub const Config = struct {
    // FIXME: make these not optional. The PartialConfig.toConfig should be
    //        the only place where the defaults are described.
    target_value: ?f32 = null,
    initial_value: ?f32 = null,
    initial_velocity: ?f32 = null,

    mass: f32,
    stiffness: f32,
    damping: f32,

    pub fn toSpring(conf: *const Config) union(enum) {
        under_damped: UnderDampedSpring(f32),
        over_damped: OverDampedSpring(f32),
    } {
        const k = conf.stiffness;
        const m = conf.mass;
        const c = conf.damping;

        const w = std.math.sqrt(k / m);
        const z = c / (2 * m * w);

        const initial_value = conf.initial_value orelse 0;
        const target_value = conf.target_value orelse initial_value;
        const x0 = initial_value - target_value;

        if (z < 1.0) {
            return .{
                .under_damped = .{
                    .target_value = target_value,
                    .current_value = initial_value,
                    // SPONGE
                    // BUG: FIXME: this should be the current time!!!!
                    .t0 = 0,
                    .x0 = x0,
                    .v0 = conf.initial_velocity orelse 0,
                    .w = w,
                    .z = z,
                    .a = w * std.math.sqrt(1 - z * z),
                    .v = conf.initial_velocity orelse 0,
                },
            };
        } else if (z > 1.0) {
            return .{
                .over_damped = .{
                    .target_value = target_value,
                    .current_value = initial_value,
                    // BUG: FIXME: this should be the current time!!!!
                    .t0 = 0,
                    .x0 = x0,
                    .v0 = conf.initial_velocity orelse 0,
                    .w = w,
                    .z = z,
                    .a = w * std.math.sqrt(z * z - 1),
                },
            };
        } else {
            // TODO: Critical damping
            @panic("Critical damping is not supported");
        }
    }
};

pub const PartialConfig = struct {
    target_value: ?f32 = null,
    initial_value: ?f32 = null,
    initial_velocity: ?f32 = null,

    mass: ?f32 = null,
    stiffness: ?f32 = null,
    damping: ?f32 = null,

    /// Convert this partial config into a full config by filling in
    /// missing fields with defaults.
    pub fn toConfig(self: @This()) Config {
        const current_value =
            self.target_value orelse
            self.initial_value orelse 0.0;
        return .{
            .target_value = self.target_value orelse current_value,
            .initial_value = self.initial_value orelse current_value,
            .initial_velocity = self.initial_velocity orelse 0.0,

            .mass = self.mass orelse 1.0,
            .stiffness = self.stiffness orelse 95.0,
            .damping = self.damping orelse 16.0,
        };
    }
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
    switch (conf.toSpring()) {
        .under_damped => |ud| return self.appendUnderDamped(alloc, ud),
        .over_damped => |od| return self.appendOverDamped(alloc, od),
    }
}

pub fn freeSpring(
    self: *Self,
    idx: SpringIdx,
) void {
    _ = self;
    _ = idx;
    @panic("Unimplemented");
}

pub inline fn getSpringField(
    self: *Self,
    idx: SpringIdx,
    field: anytype,
) f32 {
    if (idx.is_underdamped) {
        // underdamped //
        const batch_idx = idx.idx / BATCH_SIZE;
        const batch_ofs = idx.idx % BATCH_SIZE;
        const slice = self.under_damped.slice();
        return slice.items(field)[batch_idx][batch_ofs];
    } else {
        // overdamped //
        const batch_idx = idx.idx / BATCH_SIZE;
        const batch_ofs = idx.idx % BATCH_SIZE;
        const slice = self.over_damped.slice();
        return slice.items(field)[batch_idx][batch_ofs];
    }
}

pub fn getTargetValue(self: *Self, idx: SpringIdx) f32 {
    return self.getSpringField(idx, .target_value);
}

pub fn getPosition(self: *Self, idx: SpringIdx) f32 {
    return self.getSpringField(idx, .current_value);
}

pub fn isDone(self: *Self, idx: SpringIdx) bool {
    // TODO: fine-tune these. They are mostly arbitrary for now.
    const resting_v = 0.1; // units/s
    const resting_x = 0.05; // units away from target

    if (idx.is_underdamped) {
        // underdamped //
        const batch_idx = idx.idx / BATCH_SIZE;
        const batch_ofs = idx.idx % BATCH_SIZE;
        const slice = self.under_damped.slice();

        const v = slice.items(.v)[batch_idx][batch_ofs];
        const current_value = slice.items(.current_value)[batch_idx][batch_ofs];
        const target_value = slice.items(.target_value)[batch_idx][batch_ofs];

        return @abs(v) < resting_v and
            @abs(current_value - target_value) < resting_x;
    } else {
        // overdamped //
        const batch_idx = idx.idx / BATCH_SIZE;
        const batch_ofs = idx.idx % BATCH_SIZE;
        const slice = self.over_damped.slice();

        // overdamped springs give a monotonically decreasing x, so we don't
        // need to check velocity.
        const current_value = slice.items(.current_value)[batch_idx][batch_ofs];
        const target_value = slice.items(.target_value)[batch_idx][batch_ofs];

        return @abs(current_value - target_value) < resting_x;
    }
}

// Update all springs
pub fn update(self: *Self) void {
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
        ud_slice.items(.v),
    ) |target_value, *current_value, t0, x0, v0, w, z, a, *v| {
        const t = global_t - t0;

        // const a = w * std.math.sqrt(1 - z * z);
        const q = @as(BatchVec, @splat(-1)) * w * z;
        const p1 = (v0 - x0 * q) / a;
        const new_value = @exp(t * q) * ( //
            x0 * @cos(t * a) +
            p1 * @sin(t * a) //
        ) + target_value;

        const new_velocity = @exp(t * q) * ( //
            (q * x0 + a * p1) * @cos(t * a) +
            (q * p1 - a * x0) * @sin(t * a) //
        );

        current_value.* = new_value;
        v.* = new_velocity;
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
        return ud_slice.items(.v)[batch_idx][batch_ofs];

        // const t0 = ud_slice.items(.t0)[batch_idx][batch_ofs];
        // const t = global_t - t0;

        // const w = ud_slice.items(.w)[batch_idx][batch_ofs];
        // const z = ud_slice.items(.z)[batch_idx][batch_ofs];
        // const x0 = ud_slice.items(.x0)[batch_idx][batch_ofs];
        // const v0 = ud_slice.items(.v0)[batch_idx][batch_ofs];

        // // const a = w * std.math.sqrt(1 - z * z);
        // const a = ud_slice.items(.a)[batch_idx][batch_ofs];
        // const q = -1 * w * z;

        // const p1 = (v0 - x0 * q) / a;

        // return @exp(t * q) * ( //
        //     (q * x0 + a * p1) * @cos(t * a) +
        //     (q * p1 - a * x0) * @sin(t * a) //
        // );
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

// Update the configuration of a spring while preserving it's velocity and
// position.
pub fn updateSpring(
    self: *Self,
    idx: SpringIdx,
    changeset: PartialConfig,
) void {
    const batch_idx = idx.idx / BATCH_SIZE;
    const batch_ofs = idx.idx % BATCH_SIZE;

    const properties_changed =
        changeset.mass != null or
        changeset.stiffness != null or
        changeset.damping != null;
    const state_changed =
        changeset.target_value != null or
        changeset.initial_value != null or
        changeset.initial_velocity != null;

    if (state_changed) {
        // Capture current state, modify it, and start from current time as t0.

        if (idx.is_underdamped) {
            const slice = self.under_damped.slice();

            const new_target_value = changeset.target_value orelse
                slice.items(.target_value)[batch_idx][batch_ofs];
            const new_initial_value = changeset.initial_value orelse
                slice.items(.current_value)[batch_idx][batch_ofs];
            const new_initial_velocity = changeset.initial_velocity orelse
                slice.items(.v)[batch_idx][batch_ofs];

            const x0 = new_initial_value - new_target_value;
            const v0 = new_initial_velocity;

            slice.items(.x0)[batch_idx][batch_ofs] = x0;
            slice.items(.v0)[batch_idx][batch_ofs] = v0;
            slice.items(.v)[batch_idx][batch_ofs] = v0;
            slice.items(.target_value)[batch_idx][batch_ofs] = new_target_value;
            slice.items(.t0)[batch_idx][batch_ofs] = self.getTimeOffset();
        } else {
            const slice = self.over_damped.slice();

            const new_target_value = changeset.target_value orelse
                slice.items(.target_value)[batch_idx][batch_ofs];
            const new_initial_value = changeset.initial_value orelse
                slice.items(.current_value)[batch_idx][batch_ofs];
            const new_initial_velocity = changeset.initial_velocity orelse
                self.getVelocity(idx);

            const x0 = new_initial_value - new_target_value;
            const v0 = new_initial_velocity;

            slice.items(.x0)[batch_idx][batch_ofs] = x0;
            slice.items(.v0)[batch_idx][batch_ofs] = v0;
            slice.items(.target_value)[batch_idx][batch_ofs] = new_target_value;
            slice.items(.t0)[batch_idx][batch_ofs] = self.getTimeOffset();
        }
    }

    if (properties_changed) {
        if (changeset.stiffness != null and
            changeset.mass != null and
            changeset.damping != null)
        {
            const k = changeset.stiffness.?;
            const m = changeset.mass.?;
            const c = changeset.damping.?;

            // TODO: dedup this and Config.toSpring
            const w = std.math.sqrt(k / m);
            const z = c / (2 * m * w);
            const a = w * std.math.sqrt(1 - @abs(z * z));

            if (idx.is_underdamped) {
                const slice = self.under_damped.slice();
                slice.items(.w)[batch_idx][batch_ofs] = w;
                slice.items(.z)[batch_idx][batch_ofs] = z;
                slice.items(.a)[batch_idx][batch_ofs] = a;
            } else {
                const slice = self.over_damped.slice();
                slice.items(.w)[batch_idx][batch_ofs] = w;
                slice.items(.z)[batch_idx][batch_ofs] = z;
                slice.items(.a)[batch_idx][batch_ofs] = a;
            }
        } else {
            @panic("Unimplemented. All properties must be specified at the same time.");
        }
    }
}

// Update the target value of a spring "mid-flight" by maintaining it's
// current position and velocity.
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

// Get the current time in seconds since the start of the engine.
fn getTimeOffset(self: *const Self) f32 {
    const now = std.time.Instant.now() catch unreachable;
    const duration_nanos = now.since(self.init_time);
    const duration_secs: f32 = @as(f32, @floatFromInt(duration_nanos)) / 1_000_000_000;
    return duration_secs;
}

fn batchFromSlice(slice: []f32) BatchVec {
    return slice[0..BATCH_SIZE].*;
}
