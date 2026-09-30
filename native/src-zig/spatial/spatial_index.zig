//! 与 C++ `spatial/spatial_index.cpp` 对应。

const std = @import("std");
const Aabb = @import("../geometry/aabb.zig").Aabb;
const CollisionContext = @import("../state/collision_context.zig").CollisionContext;

pub fn makeAabb(min_x: f64, min_y: f64, min_z: f64, max_x: f64, max_y: f64, max_z: f64) Aabb {
    return .{
        .min_x = min_x,
        .min_y = min_y,
        .min_z = min_z,
        .max_x = max_x,
        .max_y = max_y,
        .max_z = max_z,
    };
}

pub fn isIndexable(box: Aabb) bool {
    return std.math.isFinite(box.min_x)
        and std.math.isFinite(box.min_y)
        and std.math.isFinite(box.min_z)
        and std.math.isFinite(box.max_x)
        and std.math.isFinite(box.max_y)
        and std.math.isFinite(box.max_z)
        and box.min_x < box.max_x
        and box.min_y < box.max_y
        and box.min_z < box.max_z;
}

pub fn updateEntityBounds(context: *CollisionContext, native_id: i32, box: Aabb) void {
    if (native_id < 0) return;
    const index: usize = @intCast(native_id);
    if (index >= context.section_slots.items.len) return;
    const slot = context.section_slots.items[index];
    if (slot.members) |members| members.bounds.set(slot.index, box);
}

pub fn updateEntityQueryability(context: *CollisionContext, native_id: i32, queryable: bool) void {
    if (native_id < 0) return;
    const index: usize = @intCast(native_id);
    if (index >= context.section_slots.items.len) return;
    const slot = context.section_slots.items[index];
    const members = slot.members orelse return;
    if (slot.index >= members.queryable.items.len) return;
    const previous = members.queryable.items[slot.index] != 0;
    if (previous != queryable) {
        if (queryable) members.queryable_count += 1 else members.queryable_count -= 1;
        members.queryable.items[slot.index] = if (queryable) 1 else 0;
    }
}
