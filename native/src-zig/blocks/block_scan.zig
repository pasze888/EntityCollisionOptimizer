//! 与 C++ `blocks/block_scan.cpp` 对应。
//! 查询：minXYZ, maxXYZ, cursorXYZ, done。描述符顺序：section 的 Z/Y/X。
//! 输出记录：世界 XYZ 与描述符下标。容量只分页，绝不截断候选。

const std = @import("std");

const ROW_BATCH: usize = 8;

const Cursor = struct {
    x: i32,
    y: i32,
    z: i32,
    done: i32,

    fn publish(self: Cursor, query_state: [*]c_int) void {
        query_state[6] = self.x;
        query_state[7] = self.y;
        query_state[8] = self.z;
        query_state[9] = self.done;
    }
};

const Bounds = struct {
    min_x: i32,
    min_y: i32,
    min_z: i32,
    max_x: i32,
    max_y: i32,
    max_z: i32,
    min_section_x: i32,
    max_section_x: i32,
    min_section_y: i32,
    min_section_z: i32,
    width: i32,
    height: i32,
    first_boundary: u32,
    last_boundary: u32,
    last_range: u32,

    fn init(query_state: [*]const c_int) Bounds {
        const min_x = query_state[0];
        const min_y = query_state[1];
        const min_z = query_state[2];
        const max_x = query_state[3];
        const max_y = query_state[4];
        const max_z = query_state[5];
        return .{
            .min_x = min_x,
            .min_y = min_y,
            .min_z = min_z,
            .max_x = max_x,
            .max_y = max_y,
            .max_z = max_z,
            .min_section_x = min_x >> 4,
            .max_section_x = max_x >> 4,
            .min_section_y = min_y >> 4,
            .min_section_z = min_z >> 4,
            .width = (max_x >> 4) - (min_x >> 4) + 1,
            .height = (max_y >> 4) - (min_y >> 4) + 1,
            .first_boundary = @as(u32, 1) << @intCast(min_x & 15),
            .last_boundary = @as(u32, 1) << @intCast(max_x & 15),
            .last_range = @as(u32, 0xffff) >> @intCast(15 - (max_x & 15)),
        };
    }

    fn advanceRow(self: Bounds, cursor: *Cursor) void {
        cursor.x = self.min_x;
        if (cursor.y != self.max_y) {
            cursor.y += 1;
        } else {
            cursor.y = self.min_y;
            if (cursor.z == self.max_z) {
                cursor.done = 1;
            } else {
                cursor.z += 1;
            }
        }
    }
};

const Row = struct {
    base_x: i32,
    y: i32,
    z: i32,
    descriptor_index: i32,
    end: i32,
};

const RowBatch = struct {
    rows: [ROW_BATCH]Row = undefined,
    selected: [ROW_BATCH]u32 = [_]u32{0} ** ROW_BATCH,
    outer: [ROW_BATCH]u32 = [_]u32{0} ** ROW_BATCH,
    boundary: [ROW_BATCH]u32 = [_]u32{0} ** ROW_BATCH,
    range: [ROW_BATCH]u32 = [_]u32{0} ** ROW_BATCH,
    masks: [ROW_BATCH]u32 = [_]u32{0} ** ROW_BATCH,

    /// 各 lane 相互独立：没有游标更新、输出压缩或指针追逐。
    /// 未使用的 lane 由 prepare 清零，因此这里恒有八条 lane。
    fn filter(self: *RowBatch) void {
        for (0..ROW_BATCH) |index| {
            self.masks[index] = ((self.selected[index] & ~self.boundary[index])
                | (self.outer[index] & self.boundary[index])) & self.range[index];
        }
    }
};

fn prepare(
    collision_rows: [*]const ?[*]const u16,
    bounds: Bounds,
    cursor: *Cursor,
    batch: *RowBatch,
) i32 {
    var prepared: usize = 0;
    while (cursor.done == 0 and prepared < ROW_BATCH) {
        if (cursor.x > bounds.max_x) {
            bounds.advanceRow(cursor);
            continue;
        }
        const edges: i32 = @as(i32, @intFromBool(cursor.y == bounds.min_y or cursor.y == bounds.max_y))
            + @as(i32, @intFromBool(cursor.z == bounds.min_z or cursor.z == bounds.max_z));
        const offset: usize = @intCast((((cursor.y & 15) << 4) | (cursor.z & 15)) * 3 + edges);
        var section_x = cursor.x >> 4;
        var descriptor_index: i32 = (((cursor.z >> 4) - bounds.min_section_z) * bounds.height
            + (cursor.y >> 4) - bounds.min_section_y) * bounds.width
            + section_x - bounds.min_section_x;
        while (true) {
            const base_x = cursor.x & ~@as(i32, 15);
            const end = @min(bounds.max_x, base_x + 15);
            const planes = collision_rows[@intCast(descriptor_index)];
            batch.rows[prepared] = .{
                .base_x = base_x,
                .y = cursor.y,
                .z = cursor.z,
                .descriptor_index = descriptor_index,
                .end = end,
            };
            batch.selected[prepared] = if (planes) |row| row[offset] else 0;
            batch.outer[prepared] = if (planes != null and edges != 2) planes.?[offset + 1] else 0;
            batch.boundary[prepared] = (if (section_x == bounds.min_section_x) bounds.first_boundary else 0)
                | (if (section_x == bounds.max_section_x) bounds.last_boundary else 0);
            batch.range[prepared] = (@as(u32, 0xffff) << @intCast(cursor.x & 15))
                & (if (section_x == bounds.max_section_x) bounds.last_range else @as(u32, 0xffff));
            cursor.x = end + 1;
            section_x += 1;
            descriptor_index += 1;
            prepared += 1;
            if (!(cursor.x <= bounds.max_x and prepared < ROW_BATCH)) break;
        }
    }
    var index: usize = prepared;
    while (index < ROW_BATCH) : (index += 1) {
        batch.selected[index] = 0;
        batch.outer[index] = 0;
        batch.boundary[index] = 0;
        batch.range[index] = 0;
    }
    batch.filter();
    return @intCast(prepared);
}

pub fn scan(
    collision_rows_pointer: ?[*]const ?[*]const u16,
    query_state_pointer: ?[*]c_int,
    output_records_pointer: ?[*]c_int,
    output_capacity: c_int,
) c_int {
    const collision_rows = collision_rows_pointer orelse return -1;
    const query_state = query_state_pointer orelse return -1;
    const output_records = output_records_pointer orelse return -1;
    if (output_capacity <= 0) return -1;

    var cursor = Cursor{
        .x = query_state[6],
        .y = query_state[7],
        .z = query_state[8],
        .done = query_state[9],
    };
    if (cursor.done != 0) return 0;
    const bounds = Bounds.init(query_state);
    var batch = RowBatch{};
    const capacity: usize = @intCast(output_capacity);
    var record_count: usize = 0;

    while (cursor.done == 0) {
        const prepared: usize = @intCast(prepare(collision_rows, bounds, &cursor, &batch));
        var index: usize = 0;
        while (index < prepared) : (index += 1) {
            const row = batch.rows[index];
            var mask = batch.masks[index];
            while (mask != 0) {
                const lane: i32 = @intCast(@ctz(mask));
                const selected = row.base_x + lane;
                mask &= mask - 1;
                const record = output_records + record_count * 4;
                record[0] = selected;
                record[1] = row.y;
                record[2] = row.z;
                record[3] = row.descriptor_index;
                record_count += 1;
                if (record_count == capacity) {
                    // 只发布已消费的工作。后续调用会重新读取共享的 collisionRows，
                    // 包含两页输出之间发生的调色板变更。
                    const next_x = if (mask != 0) selected + 1 else row.end + 1;
                    const resumed = Cursor{ .x = next_x, .y = row.y, .z = row.z, .done = 0 };
                    resumed.publish(query_state);
                    return @intCast(record_count);
                }
            }
        }
    }
    // 本次 FFM 调用内没有任何 Java 回调能观察到中间进度。
    cursor.publish(query_state);
    return @intCast(record_count);
}
