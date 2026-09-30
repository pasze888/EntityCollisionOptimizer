//! 与 C++ `spatial/section_index.cpp` 对应：成员增删与 section 迁移。
//! 三条平行数组（ids / queryable / bounds）必须始终同步。

const std = @import("std");
const Aabb = @import("../geometry/aabb.zig").Aabb;
const cell_map = @import("cell_map.zig");
const Cell = cell_map.Cell;
const CollisionContext = @import("../state/collision_context.zig").CollisionContext;
const metadata_mod = @import("../state/entity_metadata.zig");

fn metadataIsQueryable(metadata: metadata_mod.EntityMetadata) bool {
    return !metadata_mod.selectableValid(metadata) or metadata_mod.selectable(metadata);
}

fn sectionOf(metadata: metadata_mod.EntityMetadata) Cell {
    return .{ .x = metadata.section_x, .y = metadata.section_y, .z = metadata.section_z };
}

pub fn insertSectionEntity(context: *CollisionContext, native_id: i32, bounds: Aabb) !void {
    const allocator = context.allocator;
    while (context.section_slots.items.len < context.metadata.items.len) {
        try context.section_slots.append(allocator, .{});
    }
    const index: usize = @intCast(native_id);
    const section = sectionOf(context.metadata.items[index]);
    const members_slot = try context.sections.findOrInsertValueSlot(allocator, section);
    // 空槽位代表新登记的 section 键，等待成员对象填充。
    if (members_slot.* == null) members_slot.* = try context.acquireSectionMembers();
    const members = members_slot.*.?;
    try members.ids.append(allocator, native_id);
    const queryable = metadataIsQueryable(context.metadata.items[index]);
    try members.queryable.append(allocator, if (queryable) 1 else 0);
    if (queryable) members.queryable_count += 1;
    try members.bounds.push(allocator, bounds);
    if (metadata_mod.hardCollidable(context.metadata.items[index])) members.hard_count += 1;
    context.section_slots.items[index] = .{ .members = members, .index = members.ids.items.len - 1 };
}

pub fn removeSectionEntity(context: *CollisionContext, native_id: i32) void {
    if (native_id < 0) return;
    const index: usize = @intCast(native_id);
    if (index >= context.section_slots.items.len) return;
    const slot = context.section_slots.items[index];
    const members = slot.members orelse return;
    if (slot.index >= members.ids.items.len) return;

    if (members.queryable.items[slot.index] != 0) members.queryable_count -= 1;
    if (metadata_mod.hardCollidable(context.metadata.items[index])) members.hard_count -= 1;
    _ = members.ids.orderedRemove(slot.index);
    _ = members.queryable.orderedRemove(slot.index);
    members.bounds.erase(slot.index);
    var cursor = slot.index;
    while (cursor < members.ids.items.len) : (cursor += 1) {
        const member_index: usize = @intCast(members.ids.items[cursor]);
        context.section_slots.items[member_index].index = cursor;
    }
    context.section_slots.items[index] = .{};
    if (members.ids.items.len == 0) {
        context.sections.erase(sectionOf(context.metadata.items[index]));
        context.retireSectionMembers(members);
    }
}

pub fn updateSectionEntity(
    context: *CollisionContext,
    native_id: i32,
    section_x: i32,
    section_y: i32,
    section_z: i32,
) !void {
    const index: usize = @intCast(native_id);
    const metadata = &context.metadata.items[index];
    const moved = metadata.section_x != section_x
        or metadata.section_y != section_y
        or metadata.section_z != section_z;
    var bounds: Aabb = .{ .min_x = 0, .min_y = 0, .min_z = 0, .max_x = 0, .max_y = 0, .max_z = 0 };
    var reindex = false;
    if (moved) {
        // 有意分歧（见 docs/design/eco-native-zig-port.md §8）：已退役或从未入索引的实体没有
        // 成员槽，C++ 参考实现在这里解引用空的 members 并崩溃（section_index.cpp:67）。
        // 非成员本来就没有可搬迁的成员槽，只同步元数据坐标即可——对非成员而言这些坐标是惰性的，
        // 下一次 insertCollisionEntity 会按入参覆盖它们。slot.index 越界同属陈旧槽位状态，
        // 一并按“无需搬迁”处理，避免读到不属于该实体的 bounds。
        const slot = context.section_slots.items[index];
        if (slot.members) |members| {
            if (slot.index < members.ids.items.len) {
                bounds = members.bounds.get(slot.index);
                removeSectionEntity(context, native_id);
                reindex = true;
            }
        }
    }
    metadata.section_x = section_x;
    metadata.section_y = section_y;
    metadata.section_z = section_z;
    if (reindex) try insertSectionEntity(context, native_id, bounds);
}

pub fn sectionEntities(context: *const CollisionContext, section: Cell) ?*cell_map.CellMembers {
    return context.sections.find(section);
}
