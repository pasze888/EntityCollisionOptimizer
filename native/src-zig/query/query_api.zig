//! 与 C++ `query/query_api.cpp` 对应。
//! AVX2 intrinsic 换成 `@Vector`：不再要求 AVX2，基线 CPU 上由后端自动降级，
//! 语义（比较方向、掩码 lane 顺序、8/4/1 三档尾部）保持不变。

const std = @import("std");
const native_error = @import("../native_error.zig");
const Aabb = @import("../geometry/aabb.zig").Aabb;
const cell_map = @import("../spatial/cell_map.zig");
const CellMembers = cell_map.CellMembers;
const CellBoundsSoa = @import("../spatial/cell_bounds_soa.zig").CellBoundsSoa;
const CollisionContext = @import("../state/collision_context.zig").CollisionContext;
const entity_api = @import("../state/entity_api.zig");
const metadata_mod = @import("../state/entity_metadata.zig");
const section_index = @import("../spatial/section_index.zig");
const spatial_index = @import("../spatial/spatial_index.zig");
const rules = @import("collision_rules.zig");

const V4 = @Vector(4, f64);
const V8U8 = @Vector(8, u8);

inline fn load4(pointer: [*]const f64, index: usize) V4 {
    return pointer[index..][0..4].*;
}

/// 低四位对应四个连续 cell 成员槽的相交结果。
inline fn intersectCellBounds4(source: Aabb, bounds: *const CellBoundsSoa, index: usize) u4 {
    const x = (load4(bounds.min_x.items.ptr, index) < @as(V4, @splat(source.max_x)))
        & (load4(bounds.max_x.items.ptr, index) > @as(V4, @splat(source.min_x)));
    const y = (load4(bounds.min_y.items.ptr, index) < @as(V4, @splat(source.max_y)))
        & (load4(bounds.max_y.items.ptr, index) > @as(V4, @splat(source.min_y)));
    const z = (load4(bounds.min_z.items.ptr, index) < @as(V4, @splat(source.max_z)))
        & (load4(bounds.max_z.items.ptr, index) > @as(V4, @splat(source.min_z)));
    const hit: @Vector(4, bool) = x & y & z;
    return @bitCast(hit);
}

inline fn intersectCellBounds8(source: Aabb, bounds: *const CellBoundsSoa, index: usize) u8 {
    const low: u8 = @as(u8, intersectCellBounds4(source, bounds, index));
    const high: u8 = @as(u8, intersectCellBounds4(source, bounds, index + 4));
    return low | (high << 4);
}

inline fn queryableMask8(values: [*]const u8) u8 {
    const zero: V8U8 = @splat(0);
    const non_zero: @Vector(8, bool) = values[0..8].* != zero;
    return @bitCast(non_zero);
}

inline fn scalarIntersects(scan: Aabb, bounds: *const CellBoundsSoa, index: usize) bool {
    return !(scan.min_x >= bounds.max_x.items[index]
        or scan.max_x <= bounds.min_x.items[index]
        or scan.min_y >= bounds.max_y.items[index]
        or scan.max_y <= bounds.min_y.items[index]
        or scan.min_z >= bounds.max_z.items[index]
        or scan.max_z <= bounds.min_z.items[index]);
}

/// 负 section 坐标分两段遍历：先非负升序，再负值升序。
inline fn visitPackedRows(
    range: rules.LookupSections,
    context: anytype,
    comptime visit: fn (@TypeOf(context), i64, i64, i64) bool,
    x: i64,
    z: i64,
) bool {
    if (range.max_y >= 0) {
        var y = @max(range.min_y, 0);
        while (y <= range.max_y) : (y += 1) {
            if (!visit(context, x, y, z)) return false;
        }
    }
    if (range.min_y < 0) {
        var y = range.min_y;
        const last = @min(range.max_y, -1);
        while (y <= last) : (y += 1) {
            if (!visit(context, x, y, z)) return false;
        }
    }
    return true;
}

inline fn visitOrderedSections(
    range: rules.LookupSections,
    context: anytype,
    comptime visit: fn (@TypeOf(context), i64, i64, i64) bool,
) bool {
    var x = range.min_x;
    while (x <= range.max_x) : (x += 1) {
        if (range.max_z >= 0) {
            var z = @max(range.min_z, 0);
            while (z <= range.max_z) : (z += 1) {
                if (!visitPackedRows(range, context, visit, x, z)) return false;
            }
        }
        if (range.min_z < 0) {
            var z = range.min_z;
            const last = @min(range.max_z, -1);
            while (z <= last) : (z += 1) {
                if (!visitPackedRows(range, context, visit, x, z)) return false;
            }
        }
    }
    return true;
}

/// 8/4/1 三档相交扫描；consume 收到候选 native ID。
inline fn visitIntersecting(
    scan: Aabb,
    members: *const CellMembers,
    context: anytype,
    comptime consume: fn (@TypeOf(context), i32) bool,
) bool {
    const count = members.ids.items.len;
    var index: usize = 0;
    while (index + 8 <= count) : (index += 8) {
        var hit = intersectCellBounds8(scan, &members.bounds, index);
        while (hit != 0) {
            const lane: usize = @ctz(hit);
            hit &= hit - 1;
            if (!consume(context, members.ids.items[index + lane])) return false;
        }
    }
    while (index + 4 <= count) : (index += 4) {
        var hit = intersectCellBounds4(scan, &members.bounds, index);
        while (hit != 0) {
            const lane: usize = @ctz(hit);
            hit &= hit - 1;
            if (!consume(context, members.ids.items[index + lane])) return false;
        }
    }
    while (index < count) : (index += 1) {
        if (!scalarIntersects(scan, &members.bounds, index)) continue;
        if (!consume(context, members.ids.items[index])) return false;
    }
    return true;
}

/// 推挤查询版本：额外套上 queryable 掩码；consume 返回 0 或负的状态码。
inline fn visitIntersectingQueryable(
    source: Aabb,
    members: *const CellMembers,
    excluded: i32,
    context: anytype,
    comptime consume: fn (@TypeOf(context), i32) c_int,
) bool {
    const count = members.ids.items.len;
    const all_queryable = members.queryable_count == count;
    var index: usize = 0;
    while (index + 8 <= count) : (index += 8) {
        const active: u8 = if (all_queryable) 0xff else queryableMask8(members.queryable.items.ptr + index);
        var hit: u8 = active & intersectCellBounds8(source, &members.bounds, index);
        while (hit != 0) {
            const lane: usize = @ctz(hit);
            hit &= hit - 1;
            const candidate = members.ids.items[index + lane];
            if (candidate == excluded) continue;
            if (consume(context, candidate) != 0) return false;
        }
    }
    while (index + 4 <= count) : (index += 4) {
        var active: u8 = 0;
        for (0..4) |lane| {
            if (all_queryable or members.queryable.items[index + lane] != 0) {
                active |= @as(u8, 1) << @intCast(lane);
            }
        }
        var hit: u4 = @intCast(active & @as(u8, @as(u4, intersectCellBounds4(source, &members.bounds, index))));
        while (hit != 0) {
            const lane: usize = @ctz(hit);
            hit &= hit - 1;
            const candidate = members.ids.items[index + lane];
            if (candidate == excluded) continue;
            if (consume(context, candidate) != 0) return false;
        }
    }
    while (index < count) : (index += 1) {
        if ((!all_queryable and members.queryable.items[index] == 0)
            or !scalarIntersects(source, &members.bounds, index)) continue;
        const candidate = members.ids.items[index];
        if (candidate == excluded) continue;
        if (consume(context, candidate) != 0) return false;
    }
    return true;
}

const HardQuery = struct {
    context: *CollisionContext,
    scan: Aabb,
    excluded: i32,
    hard_only: bool,
    output: [*]c_int,
    capacity: i32,
    result_size: i32 = 0,

    fn section(self: *HardQuery, x: i64, y: i64, z: i64) bool {
        const members = section_index.sectionEntities(self.context, .{ .x = x, .y = y, .z = z }) orelse return true;
        if (self.hard_only and members.hard_count == 0) return true;
        return visitIntersecting(self.scan, members, self, consume);
    }

    fn consume(self: *HardQuery, candidate: i32) bool {
        if (candidate == self.excluded
            or (self.hard_only and !metadata_mod.hardCollidable(self.context.metadata.items[@intCast(candidate)])))
        {
            return true;
        }
        if (self.result_size >= self.capacity) return false;
        self.output[@intCast(self.result_size)] = candidate;
        self.result_size += 1;
        return true;
    }
};

const BoxQuery = struct {
    context: *CollisionContext,
    scan: Aabb,
    output: [*]c_int,
    capacity: i32,
    result_size: i32 = 0,

    fn section(self: *BoxQuery, x: i64, y: i64, z: i64) bool {
        const members = section_index.sectionEntities(self.context, .{ .x = x, .y = y, .z = z }) orelse return true;
        return visitIntersecting(self.scan, members, self, consume);
    }

    fn consume(self: *BoxQuery, candidate: i32) bool {
        if (self.result_size >= self.capacity) return false;
        self.output[@intCast(self.result_size)] = candidate;
        self.result_size += 1;
        return true;
    }
};

const PushQuery = struct {
    context: *CollisionContext,
    source: Aabb,
    excluded: i32,
    team_filter: rules.TeamFilter,
    native_push_source: bool,
    output: [*]c_int,
    flags: [*]c_int,
    body_slots: [*]c_int,
    capacity: i32,
    non_passenger_count: i32 = 0,
    actionable_count: i32 = 0,
    status: c_int = 0,

    fn section(self: *PushQuery, x: i64, y: i64, z: i64) bool {
        const members = section_index.sectionEntities(self.context, .{ .x = x, .y = y, .z = z }) orelse return true;
        return visitIntersectingQueryable(self.source, members, self.excluded, self, consume);
    }

    fn consume(self: *PushQuery, candidate: i32) c_int {
        const target = self.context.metadata.items[@intCast(candidate)];
        if (!metadata_mod.selectableValid(target)
            or (metadata_mod.selectable(target) and !metadata_mod.teamValid(target)))
        {
            if (self.context.metadata_misses.items.len >= @as(usize, @intCast(self.capacity))) return -2;
            // 记录错误串后再以 -100 上升，等价于 C++ 在 catch 里 recordNativeException()。
            self.context.metadata_misses.append(self.context.allocator, candidate) catch {
                return native_error.recordOutOfMemory();
            };
            return 0;
        }
        if (!metadata_mod.selectable(target)
            or !self.team_filter.accepts(target.team_id, metadata_mod.collisionRule(target)))
        {
            return 0;
        }
        if (!metadata_mod.passenger(target)) self.non_passenger_count += 1;
        if (self.actionable_count >= self.capacity) return -2;
        self.output[@intCast(self.actionable_count + 3)] = candidate;
        self.body_slots[@intCast(self.actionable_count)] = target.body_slot;
        self.flags[@intCast(self.actionable_count)] = if (self.native_push_source
            and metadata_mod.vanillaEntityPush(target)
            and metadata_mod.allowsDeferredVelocityWrites(target)) 1 else 0;
        self.actionable_count += 1;
        return 0;
    }
};

pub fn queryHard(
    context_pointer: ?*anyopaque,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
    excluded: c_int,
    hard_only: c_int,
    output_pointer: ?[*]c_int,
    output_capacity: c_int,
) c_int {
    const context = entity_api.contextFrom(context_pointer) orelse return -1;
    const output = output_pointer orelse return -1;
    if (output_capacity < 0) return -1;
    if (excluded < -1
        or (excluded >= 0 and @as(usize, @intCast(excluded)) >= context.metadata.items.len)) return -1;
    const scan = spatial_index.makeAabb(min_x, min_y, min_z, max_x, max_y, max_z);
    if (!spatial_index.isIndexable(scan) or (hard_only != 0 and context.hard_entity_count == 0)) return 0;
    var query = HardQuery{
        .context = context,
        .scan = scan,
        .excluded = excluded,
        .hard_only = hard_only != 0,
        .output = output,
        .capacity = output_capacity,
    };
    const complete = visitOrderedSections(rules.lookupSections(scan), &query, HardQuery.section);
    return if (complete) query.result_size else -2;
}

pub fn queryEntitiesInBox(
    context_pointer: ?*anyopaque,
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
    output_pointer: ?[*]c_int,
    output_capacity: c_int,
) c_int {
    const context = entity_api.contextFrom(context_pointer) orelse return -1;
    const output = output_pointer orelse return -1;
    if (output_capacity < 0) return -1;
    const scan = spatial_index.makeAabb(min_x, min_y, min_z, max_x, max_y, max_z);
    if (!spatial_index.isIndexable(scan)) return 0;
    var query = BoxQuery{
        .context = context,
        .scan = scan,
        .output = output,
        .capacity = output_capacity,
    };
    const complete = visitOrderedSections(rules.lookupSections(scan), &query, BoxQuery.section);
    return if (complete) query.result_size else -4;
}

pub fn queryPushable(
    context_pointer: ?*anyopaque,
    source_bounds: ?[*]const f64,
    excluded: c_int,
    source_team_id: c_int,
    source_collision_rule: c_int,
    source_native_push_eligible: c_int,
    output_buffer_pointer: ?[*]c_int,
    native_push_flags_pointer: ?[*]c_int,
    output_capacity: c_int,
) !c_int {
    const context = entity_api.contextFrom(context_pointer) orelse return -1;
    const source_bounds_pointer = source_bounds orelse return -1;
    const output_buffer = output_buffer_pointer orelse return -1;
    const native_push_flags = native_push_flags_pointer orelse return -1;
    if (excluded < -1 or output_capacity < 0
        or source_collision_rule < metadata_mod.COLLISION_ALWAYS
        or source_collision_rule > metadata_mod.COLLISION_PUSH_OTHER_TEAMS) return -1;
    if (excluded >= 0 and @as(usize, @intCast(excluded)) >= context.metadata.items.len) return -1;

    const source = spatial_index.makeAabb(
        source_bounds_pointer[0],
        source_bounds_pointer[1],
        source_bounds_pointer[2],
        source_bounds_pointer[3],
        source_bounds_pointer[4],
        source_bounds_pointer[5],
    );
    if (!spatial_index.isIndexable(source)) {
        output_buffer[0] = 0;
        output_buffer[1] = 0;
        output_buffer[2] = 0;
        return 0;
    }

    const capacity: usize = @intCast(output_capacity);
    var query = PushQuery{
        .context = context,
        .source = source,
        .excluded = excluded,
        .team_filter = rules.TeamFilter.init(source_team_id, source_collision_rule),
        .native_push_source = source_native_push_eligible != 0,
        .output = output_buffer,
        .flags = native_push_flags,
        .body_slots = output_buffer + 3 + capacity,
        .capacity = output_capacity,
    };
    context.metadata_misses.clearRetainingCapacity();

    const complete = visitOrderedSections(rules.lookupSections(source), &query, PushQuery.section);
    if (!complete) {
        if (query.status == native_error.NATIVE_EXCEPTION_STATUS) {
            return native_error.NATIVE_EXCEPTION_STATUS;
        }
        return if (query.status == 0) -3 else query.status;
    }

    const misses = context.metadata_misses.items;
    if (misses.len != 0) {
        for (misses, 0..) |candidate, index| output_buffer[3 + index] = candidate;
        output_buffer[0] = 1;
        output_buffer[1] = 0;
        output_buffer[2] = 0;
        return @intCast(misses.len);
    }
    output_buffer[0] = 0;
    output_buffer[1] = query.actionable_count;
    output_buffer[2] = query.non_passenger_count;
    return query.actionable_count;
}
