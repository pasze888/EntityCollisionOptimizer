//! 与 C++ `geometry/voxel_geometry.{h,cpp}` 对应。
//! 布局由 Java `NativeVoxelGeometry` 决定：16 字节头（size[3] + flags），
//! 随后是三个轴的坐标数组，再随后是 64 位占用位图。

const std = @import("std");

pub const VoxelGeometry = extern struct {
    size: [3]i32,
    flags: i32,
};

pub const FLAG_EMPTY: i32 = 1;
/// unshifted CubeVoxelShape：index 走专用路径。
pub const FLAG_CUBE_INDEX: i32 = 2;
/// 单个占用格：clip 走精确特化路径。
pub const FLAG_SINGLE_CELL: i32 = 4;

comptime {
    if (@sizeOf(VoxelGeometry) != 16) @compileError("VoxelGeometry header must stay 16 bytes");
}

/// 坐标数组起点：紧跟在 16 字节头之后。
inline fn coordinateBase(geometry: *const VoxelGeometry) [*]const f64 {
    const bytes: [*]const u8 = @ptrCast(geometry);
    return @ptrCast(@alignCast(bytes + 16));
}

/// 原始坐标基址（供单格特化读取 axis 的前两个坐标）。
pub inline fn rawCoordinates(geometry: *const VoxelGeometry) [*]const f64 {
    return coordinateBase(geometry);
}

pub fn coordinates(geometry: *const VoxelGeometry, axis: usize) [*]const f64 {
    var data = coordinateBase(geometry);
    var index: usize = 0;
    while (index < axis) : (index += 1) data += @intCast(geometry.size[index] + 1);
    return data;
}

pub fn full(geometry: *const VoxelGeometry, cell: [3]i32) bool {
    var axis: usize = 0;
    while (axis < 3) : (axis += 1) {
        if (cell[axis] < 0 or cell[axis] >= geometry.size[axis]) return false;
    }
    const bit_base = coordinates(geometry, 2) + @as(usize, @intCast(geometry.size[2] + 1));
    const bits: [*]const u64 = @ptrCast(@alignCast(bit_base));
    const index = (@as(u64, @intCast(cell[0])) * @as(u64, @intCast(geometry.size[1]))
        + @as(u64, @intCast(cell[1]))) * @as(u64, @intCast(geometry.size[2]))
        + @as(u64, @intCast(cell[2]));
    return (bits[@intCast(index >> 6)] & (@as(u64, 1) << @intCast(index & 63))) != 0;
}

pub const VoxelRef = extern struct {
    /// 几何体按 8 字节对齐；最低位记录显式平移（含 +0，它不得改变未平移的 -0 坐标）。
    geometry_tag: usize,
    offset: [3]f64,

    pub inline fn geometry(self: *const VoxelRef) *const VoxelGeometry {
        return @ptrFromInt(self.geometry_tag & ~@as(usize, 1));
    }

    pub inline fn translated(self: *const VoxelRef) bool {
        return (self.geometry_tag & 1) != 0;
    }

    pub fn coordinate(self: *const VoxelRef, axis: usize, slot: usize) f64 {
        const value = coordinates(self.geometry(), axis)[slot];
        // 与 OffsetDoubleList 对齐：加到坐标上，而不是从查询值里减（舍入结果不同）。
        return if (self.translated()) value + self.offset[axis] else value;
    }

    pub fn index(self: *const VoxelRef, axis: usize, value: f64) i32 {
        const header = self.geometry();
        const size = header.size[axis];
        if (!self.translated() and (header.flags & FLAG_CUBE_INDEX) != 0) {
            // CubeVoxelShape 的特化、带钳制的 floor；避免越界的浮点转整数。
            const scaled = @floor(value * @as(f64, @floatFromInt(size)));
            if (scaled < -1.0) return -1;
            if (scaled >= @as(f64, @floatFromInt(size))) return size;
            return if (std.math.isNan(scaled)) 0 else @intFromFloat(scaled);
        }
        var first: i32 = 0;
        var length: i32 = size + 1;
        while (length > 0) {
            const half = @divTrunc(length, 2);
            const middle = first + half;
            if (value < self.coordinate(axis, @intCast(middle))) {
                length = half;
            } else {
                first = middle + 1;
                length -= half + 1;
            }
        }
        return first - 1;
    }
};

comptime {
    if (@sizeOf(VoxelRef) != 32) @compileError("VoxelRef must stay 32 bytes");
}

inline fn singleCellCoordinate(shape: *const VoxelRef, base: [*]const f64, axis: usize, end: usize) f64 {
    const value = base[2 * axis + end];
    return if (shape.translated()) value + shape.offset[axis] else value;
}

/// 单个占用格的特化：不要用任意形状的外包围盒——内部网格平面会影响穿透判定。
fn clipSingleCell(shape: *const VoxelRef, axis: usize, box: [*]const f64, distance: f64) f64 {
    const base = rawCoordinates(shape.geometry());

    var gap: f64 = undefined;
    if (distance > 0.0) {
        const face = singleCellCoordinate(shape, base, axis, 0);
        if (!(box[axis + 3] - 1.0e-7 < face)) return distance;
        gap = face - box[axis + 3];
        if (gap < -1.0e-7 or distance < gap) return distance;
    } else if (distance < 0.0) {
        const face = singleCellCoordinate(shape, base, axis, 1);
        if (box[axis] + 1.0e-7 < face) return distance;
        gap = face - box[axis];
        if (gap > 1.0e-7 or distance > gap) return distance;
    } else return distance;

    const b = (axis + 1) % 3;
    const c = (axis + 2) % 3;
    if (box[b + 3] - 1.0e-7 < singleCellCoordinate(shape, base, b, 0)
        or !(box[b] + 1.0e-7 < singleCellCoordinate(shape, base, b, 1))) return distance;
    if (box[c + 3] - 1.0e-7 < singleCellCoordinate(shape, base, c, 0)
        or !(box[c] + 1.0e-7 < singleCellCoordinate(shape, base, c, 1))) return distance;
    return gap;
}

pub fn clipVoxel(shape: *const VoxelRef, axis: usize, box: [*]const f64, distance: f64) f64 {
    const geometry = shape.geometry();
    if ((geometry.flags & FLAG_EMPTY) != 0) return distance;
    if (@abs(distance) < 1.0e-7) return 0.0;
    if ((geometry.flags & FLAG_SINGLE_CELL) != 0) return clipSingleCell(shape, axis, box, distance);
    const b = (axis + 1) % 3;
    const c = (axis + 2) % 3;
    const low_b = @max(0, shape.index(b, box[b] + 1.0e-7));
    const high_b = @min(geometry.size[b], shape.index(b, box[b + 3] - 1.0e-7) + 1);
    const low_c = @max(0, shape.index(c, box[c] + 1.0e-7));
    const high_c = @min(geometry.size[c], shape.index(c, box[c + 3] - 1.0e-7) + 1);
    const positive = distance > 0.0;
    var a: i32 = if (positive)
        shape.index(axis, box[axis + 3] - 1.0e-7) + 1
    else
        shape.index(axis, box[axis] + 1.0e-7) - 1;
    var cell: [3]i32 = .{ 0, 0, 0 };
    while (if (positive) a < geometry.size[axis] else a >= 0) : (a += if (positive) @as(i32, 1) else @as(i32, -1)) {
        cell[axis] = a;
        cell[b] = low_b;
        while (cell[b] < high_b) : (cell[b] += 1) {
            cell[c] = low_c;
            while (cell[c] < high_c) : (cell[c] += 1) {
                if (!full(geometry, cell)) continue;
                const gap = shape.coordinate(axis, @intCast(if (positive) a else a + 1))
                    - box[axis + (if (positive) @as(usize, 3) else 0)];
                if (positive and gap >= -1.0e-7) return @min(distance, gap);
                if (!positive and gap <= 1.0e-7) return @max(distance, gap);
                return distance;
            }
        }
    }
    return distance;
}

pub fn clipMovement(
    requested: [*]const f64,
    box: [*]const f64,
    shapes: [*]const VoxelRef,
    count: usize,
    result: [*]f64,
) void {
    if (count == 0) {
        result[0] = requested[0];
        result[1] = requested[1];
        result[2] = requested[2];
        return;
    }
    result[0] = 0;
    result[1] = 0;
    result[2] = 0;
    var order = [3]usize{ 1, 0, 2 };
    if (@abs(requested[0]) < @abs(requested[2])) {
        const swap = order[1];
        order[1] = order[2];
        order[2] = swap;
    }
    for (order) |axis| {
        var distance = requested[axis];
        if (distance == 0.0) continue;
        var moved: [6]f64 = undefined;
        for (0..6) |i| moved[i] = box[i] + result[i % 3];
        var index: usize = 0;
        while (index < count) : (index += 1) {
            if (@abs(distance) < 1.0e-7) {
                distance = 0.0;
                break;
            }
            distance = clipVoxel(&shapes[index], axis, &moved, distance);
        }
        result[axis] = distance;
    }
}
