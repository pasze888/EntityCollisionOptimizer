//! 与 C++ `eco::CellBoundsSoa` 对应：六条平行 f64 列，供候选扫描连续读取。
//! C++ 用 `std::vector::erase`（保序），这里对应 `orderedRemove`。

const std = @import("std");
const Aabb = @import("../geometry/aabb.zig").Aabb;

pub const CellBoundsSoa = struct {
    min_x: std.ArrayList(f64) = .empty,
    min_y: std.ArrayList(f64) = .empty,
    min_z: std.ArrayList(f64) = .empty,
    max_x: std.ArrayList(f64) = .empty,
    max_y: std.ArrayList(f64) = .empty,
    max_z: std.ArrayList(f64) = .empty,

    pub fn deinit(self: *CellBoundsSoa, allocator: std.mem.Allocator) void {
        self.min_x.deinit(allocator);
        self.min_y.deinit(allocator);
        self.min_z.deinit(allocator);
        self.max_x.deinit(allocator);
        self.max_y.deinit(allocator);
        self.max_z.deinit(allocator);
    }

    pub fn push(self: *CellBoundsSoa, allocator: std.mem.Allocator, box: Aabb) !void {
        try self.min_x.append(allocator, box.min_x);
        try self.min_y.append(allocator, box.min_y);
        try self.min_z.append(allocator, box.min_z);
        try self.max_x.append(allocator, box.max_x);
        try self.max_y.append(allocator, box.max_y);
        try self.max_z.append(allocator, box.max_z);
    }

    pub fn set(self: *CellBoundsSoa, index: usize, box: Aabb) void {
        self.min_x.items[index] = box.min_x;
        self.min_y.items[index] = box.min_y;
        self.min_z.items[index] = box.min_z;
        self.max_x.items[index] = box.max_x;
        self.max_y.items[index] = box.max_y;
        self.max_z.items[index] = box.max_z;
    }

    pub fn get(self: CellBoundsSoa, index: usize) Aabb {
        return .{
            .min_x = self.min_x.items[index],
            .min_y = self.min_y.items[index],
            .min_z = self.min_z.items[index],
            .max_x = self.max_x.items[index],
            .max_y = self.max_y.items[index],
            .max_z = self.max_z.items[index],
        };
    }

    pub fn erase(self: *CellBoundsSoa, index: usize) void {
        _ = self.min_x.orderedRemove(index);
        _ = self.min_y.orderedRemove(index);
        _ = self.min_z.orderedRemove(index);
        _ = self.max_x.orderedRemove(index);
        _ = self.max_y.orderedRemove(index);
        _ = self.max_z.orderedRemove(index);
    }

    pub fn clear(self: *CellBoundsSoa) void {
        self.min_x.clearRetainingCapacity();
        self.min_y.clearRetainingCapacity();
        self.min_z.clearRetainingCapacity();
        self.max_x.clearRetainingCapacity();
        self.max_y.clearRetainingCapacity();
        self.max_z.clearRetainingCapacity();
    }

    pub fn len(self: CellBoundsSoa) usize {
        return self.min_x.items.len;
    }
};
