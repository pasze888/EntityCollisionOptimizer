//! 与 C++ `eco::CollisionContext` 对应。差异只有一处实现手法：
//! C++ 用 `std::deque<CellMembers>` 换取指针稳定性；Zig 改为逐对象分配 +
//! 空闲链，效果相同（map rehash 与池复用都不会移动 CellMembers）。

const std = @import("std");
const cell_map = @import("../spatial/cell_map.zig");
const CellMap = cell_map.CellMap;
const CellMembers = cell_map.CellMembers;
const metadata_mod = @import("entity_metadata.zig");
const EntityMetadata = metadata_mod.EntityMetadata;

pub const CellSlot = struct {
    members: ?*CellMembers = null,
    index: usize = 0,
};

pub const CollisionContext = struct {
    allocator: std.mem.Allocator,
    metadata: std.ArrayList(EntityMetadata) = .empty,
    sections: CellMap,
    free_section_members: ?*CellMembers = null,
    /// 仅用于销毁：记录所有逐对象分配的成员块。
    owned_section_members: std.ArrayList(*CellMembers) = .empty,
    section_slots: std.ArrayList(CellSlot) = .empty,
    metadata_misses: std.ArrayList(i32) = .empty,
    /// 精确的在世硬碰撞实体数；硬碰撞专用查询可在为零时提前退出。
    hard_entity_count: usize = 0,

    pub fn create(allocator: std.mem.Allocator) !*CollisionContext {
        const context = try allocator.create(CollisionContext);
        errdefer allocator.destroy(context);
        context.* = .{
            .allocator = allocator,
            .sections = try CellMap.init(allocator),
        };
        return context;
    }

    pub fn destroy(self: *CollisionContext) void {
        const allocator = self.allocator;
        for (self.owned_section_members.items) |members| {
            members.deinit(allocator);
            allocator.destroy(members);
        }
        self.owned_section_members.deinit(allocator);
        self.metadata.deinit(allocator);
        self.section_slots.deinit(allocator);
        self.metadata_misses.deinit(allocator);
        self.sections.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn acquireSectionMembers(self: *CollisionContext) !*CellMembers {
        if (self.free_section_members) |members| {
            self.free_section_members = members.pool_next;
            members.pool_next = null;
            return members;
        }
        const members = try self.allocator.create(CellMembers);
        errdefer self.allocator.destroy(members);
        members.* = .{};
        try self.owned_section_members.append(self.allocator, members);
        return members;
    }

    pub fn retireSectionMembers(self: *CollisionContext, members: *CellMembers) void {
        members.ids.clearRetainingCapacity();
        members.queryable.clearRetainingCapacity();
        members.bounds.clear();
        members.queryable_count = 0;
        members.hard_count = 0;
        members.pool_next = self.free_section_members;
        self.free_section_members = members;
    }
};
