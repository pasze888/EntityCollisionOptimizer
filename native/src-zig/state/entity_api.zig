//! 与 C++ `state/context_api.cpp`、`state/metadata_api.cpp`、
//! `state/persistent_index.cpp` 三个门面文件对应。
//! 参数校验返回 -1；只有分配失败才会以 error union 上升为 -100。

const std = @import("std");
const native_error = @import("../native_error.zig");
const CollisionContext = @import("collision_context.zig").CollisionContext;
const metadata_mod = @import("entity_metadata.zig");
const spatial_index = @import("../spatial/spatial_index.zig");
const section_index = @import("../spatial/section_index.zig");

pub fn contextFrom(pointer: ?*anyopaque) ?*CollisionContext {
    const raw = pointer orelse return null;
    return @ptrCast(@alignCast(raw));
}

pub fn create() ?*anyopaque {
    const context = CollisionContext.create(std.heap.c_allocator) catch {
        _ = native_error.recordOutOfMemory();
        return null;
    };
    return @ptrCast(context);
}

pub fn destroy(pointer: ?*anyopaque) void {
    const context = contextFrom(pointer) orelse return;
    context.destroy();
}

pub fn insert(
    context_pointer: ?*anyopaque,
    native_id: c_int,
    entity_bounds: ?[*]const f64,
    section_x: c_int,
    section_y: c_int,
    section_z: c_int,
) !c_int {
    const context = contextFrom(context_pointer) orelse return -1;
    const bounds = entity_bounds orelse return -1;
    if (native_id < 0) return -1;
    const index: usize = @intCast(native_id);
    // nativeId 就是 metadata 下标：新 ID 只能追加，退役的 ID 可以复用。
    if (index > context.metadata.items.len) return -1;
    if (index == context.metadata.items.len) {
        try context.metadata.append(context.allocator, metadata_mod.defaultMetadata());
        try context.section_slots.append(context.allocator, .{});
    } else if (index < context.section_slots.items.len
        and context.section_slots.items[index].members != null)
    {
        return -1;
    }
    const metadata = &context.metadata.items[index];
    metadata_mod.reset(metadata);
    metadata.section_x = section_x;
    metadata.section_y = section_y;
    metadata.section_z = section_z;
    try section_index.insertSectionEntity(context, native_id, spatial_index.makeAabb(
        bounds[0],
        bounds[1],
        bounds[2],
        bounds[3],
        bounds[4],
        bounds[5],
    ));
    return 0;
}

pub fn updateState(
    context_pointer: ?*anyopaque,
    native_id: c_int,
    selectable: c_int,
    passenger: c_int,
    vanilla_entity_push: c_int,
    allows_deferred_velocity_writes: c_int,
    team_id: c_int,
    collision_rule: c_int,
    body_slot: c_int,
    hard_collidable: c_int,
) !c_int {
    const context = contextFrom(context_pointer) orelse return -1;
    if (native_id < 0 or body_slot < 0
        or collision_rule < metadata_mod.COLLISION_ALWAYS
        or collision_rule > metadata_mod.COLLISION_PUSH_OTHER_TEAMS) return -1;
    const index: usize = @intCast(native_id);
    if (index >= context.metadata.items.len) return -1;

    const metadata = &context.metadata.items[index];
    const was_queryable = !metadata_mod.selectableValid(metadata.*)
        or metadata_mod.selectable(metadata.*);
    metadata_mod.set(metadata, metadata_mod.SELECTABLE, selectable != 0);
    metadata_mod.set(metadata, metadata_mod.PASSENGER, passenger != 0);
    metadata_mod.set(metadata, metadata_mod.VANILLA_ENTITY_PUSH, vanilla_entity_push != 0);
    metadata_mod.set(
        metadata,
        metadata_mod.ALLOWS_DEFERRED_VELOCITY_WRITES,
        allows_deferred_velocity_writes != 0,
    );
    const hard = hard_collidable != 0;
    if (metadata_mod.hardCollidable(metadata.*) != hard) {
        if (hard) context.hard_entity_count += 1 else context.hard_entity_count -= 1;
        if (index < context.section_slots.items.len) {
            const slot = context.section_slots.items[index];
            if (slot.members) |members| {
                if (hard) members.hard_count += 1 else members.hard_count -= 1;
            }
        }
    }
    metadata_mod.set(metadata, metadata_mod.HARD_COLLIDABLE, hard);
    metadata.team_id = team_id;
    metadata_mod.setCollisionRule(metadata, @intCast(collision_rule));
    metadata.body_slot = body_slot;
    metadata_mod.set(metadata, metadata_mod.SELECTABLE_VALID, true);
    metadata_mod.set(metadata, metadata_mod.TEAM_VALID, true);
    if (was_queryable != metadata_mod.selectable(metadata.*)) {
        spatial_index.updateEntityQueryability(context, native_id, metadata_mod.selectable(metadata.*));
    }
    return 0;
}

/// 发布几何并让推挤资格失效，不再求值 Java 的实体谓词。
pub fn updateBounds(
    context_pointer: ?*anyopaque,
    native_id: c_int,
    entity_bounds: ?[*]const f64,
) !c_int {
    const context = contextFrom(context_pointer) orelse return -1;
    const bounds = entity_bounds orelse return -1;
    if (native_id < 0) return -1;
    const index: usize = @intCast(native_id);
    if (index >= context.metadata.items.len) return -1;
    spatial_index.updateEntityBounds(context, native_id, spatial_index.makeAabb(
        bounds[0],
        bounds[1],
        bounds[2],
        bounds[3],
        bounds[4],
        bounds[5],
    ));
    const metadata = &context.metadata.items[index];
    if (metadata_mod.selectableValid(metadata.*) and !metadata_mod.selectable(metadata.*)) {
        spatial_index.updateEntityQueryability(context, native_id, true);
    }
    metadata_mod.set(metadata, metadata_mod.SELECTABLE_VALID, false);
    return 0;
}

pub fn remove(context_pointer: ?*anyopaque, native_id: c_int) !c_int {
    const context = contextFrom(context_pointer) orelse return -1;
    if (native_id < 0) return -1;
    const index: usize = @intCast(native_id);
    if (index >= context.metadata.items.len) return -1;
    section_index.removeSectionEntity(context, native_id);
    if (metadata_mod.hardCollidable(context.metadata.items[index])) context.hard_entity_count -= 1;
    metadata_mod.reset(&context.metadata.items[index]);
    return 0;
}

pub fn updateSection(
    context_pointer: ?*anyopaque,
    native_id: c_int,
    section_x: c_int,
    section_y: c_int,
    section_z: c_int,
) !c_int {
    const context = contextFrom(context_pointer) orelse return -1;
    if (native_id < 0) return -1;
    const index: usize = @intCast(native_id);
    if (index >= context.metadata.items.len) return -1;
    try section_index.updateSectionEntity(context, native_id, section_x, section_y, section_z);
    const metadata = &context.metadata.items[index];
    if (metadata_mod.selectableValid(metadata.*) and !metadata_mod.selectable(metadata.*)) {
        spatial_index.updateEntityQueryability(context, native_id, true);
    }
    metadata_mod.set(metadata, metadata_mod.SELECTABLE_VALID, false);
    return 0;
}

pub fn invalidatePushEligibilityCache(context_pointer: ?*anyopaque, native_id: c_int) !c_int {
    const context = contextFrom(context_pointer) orelse return -1;
    if (native_id < 0) return -1;
    const index: usize = @intCast(native_id);
    if (index >= context.metadata.items.len) return -1;
    const metadata = &context.metadata.items[index];
    if (metadata_mod.selectableValid(metadata.*) and !metadata_mod.selectable(metadata.*)) {
        spatial_index.updateEntityQueryability(context, native_id, true);
    }
    metadata_mod.set(metadata, metadata_mod.SELECTABLE_VALID, false);
    return 0;
}

pub fn invalidatePushEligibilityCacheFields(
    context_pointer: ?*anyopaque,
    fields_to_invalidate: c_int,
) !c_int {
    const context = contextFrom(context_pointer) orelse return -1;
    const known = metadata_mod.METADATA_SELECTABLE | metadata_mod.METADATA_TEAM;
    if ((fields_to_invalidate & ~known) != 0) return -1;
    var index: usize = 0;
    while (index < context.metadata.items.len) : (index += 1) {
        const metadata = &context.metadata.items[index];
        if ((fields_to_invalidate & metadata_mod.METADATA_SELECTABLE) != 0) {
            if (metadata_mod.selectableValid(metadata.*) and !metadata_mod.selectable(metadata.*)) {
                spatial_index.updateEntityQueryability(context, @intCast(index), true);
            }
            metadata_mod.set(metadata, metadata_mod.SELECTABLE_VALID, false);
        }
        if ((fields_to_invalidate & metadata_mod.METADATA_TEAM) != 0) {
            metadata_mod.set(metadata, metadata_mod.TEAM_VALID, false);
        }
    }
    return 0;
}
