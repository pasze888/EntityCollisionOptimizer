//! 与 C++ `eco::BasicCellMap` 对应的扁平开放寻址表：线性探测、
//! 容量为 2 的幂、负载因子 0.7、回移删除（无墓碑）。
//! 值与表项分开拥有，因此 rehash 不会移动调用方持有的对象。

const std = @import("std");
const CellBoundsSoa = @import("cell_bounds_soa.zig").CellBoundsSoa;

pub const Cell = extern struct {
    x: i64,
    y: i64,
    z: i64,
};

pub const CellHash = struct {
    pub fn hash(cell: Cell) usize {
        var x: u64 = @bitCast(cell.x);
        var y: u64 = @bitCast(cell.y);
        var z: u64 = @bitCast(cell.z);
        x ^= x >> 30;
        x *%= 0xbf58476d1ce4e5b9;
        x ^= x >> 27;
        x *%= 0x94d049bb133111eb;
        x ^= x >> 31;
        z ^= z >> 30;
        z *%= 0xbf58476d1ce4e5b9;
        z ^= z >> 27;
        z *%= 0x94d049bb133111eb;
        z ^= z >> 31;
        y ^= y >> 30;
        y *%= 0xbf58476d1ce4e5b9;
        y ^= y >> 27;
        y *%= 0x94d049bb133111eb;
        y ^= y >> 31;
        x ^= y +% 0x9e3779b97f4a7c15 +% (x << 6) +% (x >> 2);
        const mixed = x ^ (z +% 0x9e3779b97f4a7c15 +% (x << 6) +% (x >> 2));
        return @truncate(mixed);
    }

    pub fn eql(a: Cell, b: Cell) bool {
        return a.x == b.x and a.y == b.y and a.z == b.z;
    }
};

pub const CellMembers = struct {
    ids: std.ArrayList(i32) = .empty,
    /// 与 ids 平行，使 section 顺序不被打乱的同时，推挤查询可以跳过不合格实体。
    queryable: std.ArrayList(u8) = .empty,
    bounds: CellBoundsSoa = .{},
    queryable_count: usize = 0,
    /// 本 section 内的硬碰撞成员数；硬碰撞专用扫描可跳过空 section。
    hard_count: usize = 0,
    pool_next: ?*CellMembers = null,

    pub fn deinit(self: *CellMembers, allocator: std.mem.Allocator) void {
        self.ids.deinit(allocator);
        self.queryable.deinit(allocator);
        self.bounds.deinit(allocator);
    }
};

pub const CellMap = struct {
    const MIN_CAPACITY: usize = 64;

    const Entry = struct {
        key: Cell = .{ .x = 0, .y = 0, .z = 0 },
        value: ?*CellMembers = null,
    };

    entries: []Entry,
    mask: usize,
    used: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !CellMap {
        const entries = try allocator.alloc(Entry, MIN_CAPACITY);
        @memset(entries, Entry{});
        return .{ .entries = entries, .mask = MIN_CAPACITY - 1 };
    }

    pub fn deinit(self: *CellMap, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
        self.entries = &.{};
        self.mask = 0;
        self.used = 0;
    }

    pub fn find(self: *const CellMap, key: Cell) ?*CellMembers {
        var index = CellHash.hash(key) & self.mask;
        while (true) {
            const probe = &self.entries[index];
            if (probe.value == null) return null;
            if (CellHash.eql(probe.key, key)) return probe.value;
            index = (index + 1) & self.mask;
        }
    }

    /// 返回槽位指针。新键只登记键、指针保持 null，调用方必须立即填充。
    pub fn findOrInsertValueSlot(
        self: *CellMap,
        allocator: std.mem.Allocator,
        key: Cell,
    ) !*?*CellMembers {
        if ((self.used + 1) * 10 >= self.entries.len * 7) {
            try self.rehash(allocator, self.entries.len * 2);
        }
        var index = CellHash.hash(key) & self.mask;
        while (self.entries[index].value != null) {
            if (CellHash.eql(self.entries[index].key, key)) return &self.entries[index].value;
            index = (index + 1) & self.mask;
        }
        self.used += 1;
        self.entries[index].key = key;
        return &self.entries[index].value;
    }

    pub fn erase(self: *CellMap, key: Cell) void {
        var hole = CellHash.hash(key) & self.mask;
        while (true) {
            const probe = &self.entries[hole];
            if (probe.value == null) return;
            if (CellHash.eql(probe.key, key)) break;
            hole = (hole + 1) & self.mask;
        }
        // 回移删除：保持探测链紧密，且不引入墓碑。
        var next = (hole + 1) & self.mask;
        while (self.entries[next].value != null) : (next = (next + 1) & self.mask) {
            const home = CellHash.hash(self.entries[next].key) & self.mask;
            const within = if (hole < next)
                (home > hole and home <= next)
            else
                (home > hole or home <= next);
            if (!within) {
                self.entries[hole] = self.entries[next];
                hole = next;
            }
        }
        self.entries[hole].value = null;
        self.used -= 1;
    }

    fn rehash(self: *CellMap, allocator: std.mem.Allocator, capacity: usize) !void {
        const next_entries = try allocator.alloc(Entry, capacity);
        @memset(next_entries, Entry{});
        const next_mask = capacity - 1;
        for (self.entries) |entry| {
            if (entry.value == null) continue;
            var index = CellHash.hash(entry.key) & next_mask;
            while (next_entries[index].value != null) {
                index = (index + 1) & next_mask;
            }
            next_entries[index] = entry;
        }
        allocator.free(self.entries);
        self.entries = next_entries;
        self.mask = next_mask;
    }
};
