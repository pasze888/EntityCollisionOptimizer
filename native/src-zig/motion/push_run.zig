//! 与 C++ `motion/push_run.cpp` 对应。浮点运算顺序逐条保留：不要合并、
//! 不要重排，也不要把累加改写成归约。

const std = @import("std");
const body_mod = @import("collision_body.zig");
const CollisionBody = body_mod.CollisionBody;

const PUSH_EPSILON: f64 = 0.009999999776482582;

/// Entity.push(Entity)，保留原版每一步除法/乘法的顺序。
fn pushImpulse(
    source_x: f64,
    source_z: f64,
    target_x: f64,
    target_z: f64,
    out_x: *f64,
    out_z: *f64,
) bool {
    var x = source_x - target_x;
    var z = source_z - target_z;
    const maximum = @max(@abs(x), @abs(z));
    if (!(maximum >= PUSH_EPSILON)) return false;
    const root = @sqrt(maximum);
    x /= root;
    z /= root;
    const inverse = @min(1.0, 1.0 / root);
    x *= inverse;
    z *= inverse;
    x *= 0.05000000074505806;
    z *= 0.05000000074505806;
    out_x.* = x;
    out_z.* = z;
    return true;
}

fn push(body: *CollisionBody, x: f64, z: f64) void {
    // Entity.push 先拒绝非有限输入，setDeltaMovement 再拒绝非有限的加和结果；
    // 后者仍然会置 needsSync，且不会部分接受单个分量。
    if (!std.math.isFinite(x) or !std.math.isFinite(z)) return;
    const vx = body.vx + x;
    // 连原版的符号零加法也要保留。
    const vy = body.vy + 0.0;
    const vz = body.vz + z;
    body.needs_sync = 1;
    if (!std.math.isFinite(vx) or !std.math.isFinite(vy) or !std.math.isFinite(vz)) return;
    body.vx = vx;
    body.vy = vy;
    body.vz = vz;
    body.velocity_version +%= 1;
}

fn acceptsImpulse(body: CollisionBody) bool {
    return (body.state & (body_mod.PUSHABLE | body_mod.VEHICLE)) == body_mod.PUSHABLE;
}

pub fn execute(
    source_body_pointer: ?*anyopaque,
    target_bodies_pointer: ?*anyopaque,
    target_capacity: c_int,
    target_slots: ?[*]const c_int,
    target_count: c_int,
) c_int {
    const source_raw = source_body_pointer orelse return -1;
    const targets_raw = target_bodies_pointer orelse return -1;
    const slots = target_slots orelse return -1;
    if (target_count < 0 or target_capacity < 0) return -1;
    // 先整体校验，再改动持久状态。查询去重保证目标唯一；
    // 它们原本的顺序（含源累加）保持不变。
    const count: usize = @intCast(target_count);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (slots[index] < 0 or slots[index] >= target_capacity) return -1;
    }
    const source: *CollisionBody = @ptrCast(@alignCast(source_raw));
    const targets: [*]CollisionBody = @ptrCast(@alignCast(targets_raw));
    const push_source = acceptsImpulse(source.*);
    if ((source.state & body_mod.NO_PHYSICS) != 0) return 0;
    index = 0;
    while (index < count) : (index += 1) {
        const target = &targets[@intCast(slots[index])];
        if ((target.state & (body_mod.NO_PHYSICS | body_mod.SLEEPING)) != 0) continue;
        if (((source.state | target.state) & body_mod.PASSENGER) != 0 and source.root == target.root) continue;
        const push_target = acceptsImpulse(target.*);
        if (!push_source and !push_target) continue;
        var x: f64 = undefined;
        var z: f64 = undefined;
        if (!pushImpulse(source.x, source.z, target.x, target.z, &x, &z)) continue;
        if (push_target) push(target, -x, -z);
        // 源累加严格顺序进行：绝不能先把多个脉冲求和再写回。
        if (push_source) push(source, x, z);
    }
    return 0;
}
