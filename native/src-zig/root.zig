//! FFM C ABI 门面：与 `include/eco/collision_api.h` 的 17 个导出一一对应。
//! 符号名、签名与共享内存布局是兼容边界；内部模块结构可以自由重构。

const std = @import("std");
const native_error = @import("native_error.zig");
const entity_api = @import("state/entity_api.zig");
const query_api = @import("query/query_api.zig");
const push_run = @import("motion/push_run.zig");
const movement_solver = @import("motion/movement_solver.zig");
const block_scan = @import("blocks/block_scan.zig");
const body_mod = @import("motion/collision_body.zig");
const voxel = @import("geometry/voxel_geometry.zig");
const metadata_mod = @import("state/entity_metadata.zig");
const aabb_mod = @import("geometry/aabb.zig");

comptime {
    // 与 C++ 侧 static_assert 严格对应；布局一变就编译失败。
    if (@sizeOf(aabb_mod.Aabb) != 48) @compileError("Aabb must stay 48 bytes");
    if (@sizeOf(metadata_mod.EntityMetadata) != 32) @compileError("EntityMetadata must stay 32 bytes");
    if (@sizeOf(voxel.VoxelGeometry) != 16) @compileError("VoxelGeometry must stay 16 bytes");
    if (@sizeOf(voxel.VoxelRef) != 32) @compileError("VoxelRef must stay 32 bytes");
    if (@sizeOf(body_mod.CollisionBody) != 80) @compileError("CollisionBody must stay 80 bytes");
    if (@offsetOf(body_mod.CollisionBody, "y") != 64) @compileError("CollisionBody.y must stay at 64");
    if (@offsetOf(body_mod.CollisionBody, "position_version") != 72) @compileError("CollisionBody.position_version must stay at 72");
    if (@offsetOf(metadata_mod.EntityMetadata, "team_id") != 12) @compileError("EntityMetadata.team_id must stay at 12");
}

export fn lastNativeException() callconv(.c) [*:0]const u8 {
    return native_error.message();
}

export fn createCollisionContext() callconv(.c) ?*anyopaque {
    return entity_api.create();
}

export fn destroyCollisionContext(context: ?*anyopaque) callconv(.c) void {
    entity_api.destroy(context);
}

export fn insertCollisionEntity(
    context: ?*anyopaque,
    native_id: c_int,
    entity_bounds: ?[*]const f64,
    section_x: c_int,
    section_y: c_int,
    section_z: c_int,
) callconv(.c) c_int {
    return entity_api.insert(context, native_id, entity_bounds, section_x, section_y, section_z) catch |err|
        native_error.recordError(err);
}

export fn updateCollisionEntityState(
    context: ?*anyopaque,
    native_id: c_int,
    selectable: c_int,
    passenger: c_int,
    vanilla_entity_push: c_int,
    allows_deferred_velocity_writes: c_int,
    team_id: c_int,
    collision_rule: c_int,
    body_slot: c_int,
    hard_collidable: c_int,
) callconv(.c) c_int {
    return entity_api.updateState(
        context,
        native_id,
        selectable,
        passenger,
        vanilla_entity_push,
        allows_deferred_velocity_writes,
        team_id,
        collision_rule,
        body_slot,
        hard_collidable,
    ) catch |err| native_error.recordError(err);
}

export fn updateCollisionEntityBounds(
    context: ?*anyopaque,
    native_id: c_int,
    entity_bounds: ?[*]const f64,
) callconv(.c) c_int {
    return entity_api.updateBounds(context, native_id, entity_bounds) catch |err|
        native_error.recordError(err);
}

export fn updateCollisionEntitySection(
    context: ?*anyopaque,
    native_id: c_int,
    section_x: c_int,
    section_y: c_int,
    section_z: c_int,
) callconv(.c) c_int {
    return entity_api.updateSection(context, native_id, section_x, section_y, section_z) catch |err|
        native_error.recordError(err);
}

export fn removeCollisionEntity(context: ?*anyopaque, native_id: c_int) callconv(.c) c_int {
    return entity_api.remove(context, native_id) catch |err| native_error.recordError(err);
}

export fn invalidateEntityPushEligibilityCache(
    context: ?*anyopaque,
    native_id: c_int,
) callconv(.c) c_int {
    return entity_api.invalidatePushEligibilityCache(context, native_id) catch |err|
        native_error.recordError(err);
}

export fn invalidatePushEligibilityCacheFields(
    context: ?*anyopaque,
    fields_to_invalidate: c_int,
) callconv(.c) c_int {
    return entity_api.invalidatePushEligibilityCacheFields(context, fields_to_invalidate) catch |err|
        native_error.recordError(err);
}

export fn queryHardCollisionEntities(
    context: ?*anyopaque,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
    excluded_native_id: c_int,
    hard_only: c_int,
    output_native_ids: ?[*]c_int,
    output_capacity: c_int,
) callconv(.c) c_int {
    return query_api.queryHard(
        context,
        min_x,
        min_y,
        min_z,
        max_x,
        max_y,
        max_z,
        excluded_native_id,
        hard_only,
        output_native_ids,
        output_capacity,
    );
}

export fn queryEntitiesInBox(
    context: ?*anyopaque,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
    output_native_ids: ?[*]c_int,
    output_capacity: c_int,
) callconv(.c) c_int {
    return query_api.queryEntitiesInBox(
        context,
        min_x,
        min_y,
        min_z,
        max_x,
        max_y,
        max_z,
        output_native_ids,
        output_capacity,
    );
}

export fn queryPushableEntities(
    context: ?*anyopaque,
    source_bounds: ?[*]const f64,
    excluded_native_id: c_int,
    source_team_id: c_int,
    source_collision_rule: c_int,
    source_native_push_eligible: c_int,
    output_buffer: ?[*]c_int,
    native_push_flags: ?[*]c_int,
    output_capacity: c_int,
) callconv(.c) c_int {
    return query_api.queryPushable(
        context,
        source_bounds,
        excluded_native_id,
        source_team_id,
        source_collision_rule,
        source_native_push_eligible,
        output_buffer,
        native_push_flags,
        output_capacity,
    ) catch |err| native_error.recordError(err);
}

export fn executePushRun(
    source_body: ?*anyopaque,
    target_bodies: ?*anyopaque,
    target_capacity: c_int,
    target_slots: ?[*]const c_int,
    target_count: c_int,
) callconv(.c) c_int {
    return push_run.execute(source_body, target_bodies, target_capacity, target_slots, target_count);
}

export fn prepareMovement(
    entity_bounds: ?[*]const f64,
    movement_data: ?[*]f64,
) callconv(.c) c_int {
    return movement_solver.prepare(entity_bounds, movement_data);
}

export fn solveMovement(
    body: ?*const anyopaque,
    movement_data: ?[*]f64,
    shape_references: ?*const anyopaque,
    shape_count: c_int,
    movement_phase: c_int,
) callconv(.c) c_int {
    return movement_solver.solve(body, movement_data, shape_references, shape_count, movement_phase);
}

export fn scanCollisionBlocks(
    collision_rows: ?[*]const ?[*]const u16,
    query_state: ?[*]c_int,
    output_records: ?[*]c_int,
    output_capacity: c_int,
) callconv(.c) c_int {
    return block_scan.scan(collision_rows, query_state, output_records, output_capacity);
}
