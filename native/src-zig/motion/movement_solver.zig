//! 与 C++ `motion/movement_solver.cpp` 对应。
//! packet 布局与 Java `NativeMovement` 共享：34 个 double。
//! 原生借用 body 期间不会有 Java 回调执行。

const std = @import("std");
const native_error = @import("../native_error.zig");
const body_mod = @import("collision_body.zig");
const voxel = @import("../geometry/voxel_geometry.zig");

const BOX = 0;
const REQUEST = 6;
const POSITION = 9;
const RESULT = 12;
const TARGET = 15;
const STEP_BASE = 18;
const STEP_SCAN = 24;
const MAX_STEP = 30;
const GROUNDED = 31;
const NEEDS_STEP = 32;
const ENTITY_QUERY = 33;

fn horizontal(vector: [*]const f64) f64 {
    return vector[0] * vector[0] + vector[2] * vector[2];
}

fn lengthSquared(vector: [*]const f64) f64 {
    return vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2];
}

fn initial(movement: [*]f64, shapes: [*]const voxel.VoxelRef, shape_count: usize) void {
    const request = movement + REQUEST;
    const clipped = movement + RESULT;
    if (movement[ENTITY_QUERY] != 0 and lengthSquared(request) == 0.0) {
        clipped[0] = request[0];
        clipped[1] = request[1];
        clipped[2] = request[2];
    } else {
        voxel.clipMovement(request, movement + BOX, shapes, shape_count, clipped);
    }
    const landed = request[1] != clipped[1] and request[1] < 0.0;
    movement[NEEDS_STEP] = if (movement[MAX_STEP] > 0
        and (landed or movement[GROUNDED] != 0)
        and (request[0] != clipped[0] or request[2] != clipped[2])) 1.0 else 0.0;
    if (movement[NEEDS_STEP] == 0.0) return;
    var index: usize = 0;
    while (index < 6) : (index += 1) movement[STEP_BASE + index] = movement[BOX + index];
    if (landed) {
        // AABB.move 会把三个分量都加上，含正零。
        index = 0;
        while (index < 6) : (index += 1) {
            movement[STEP_BASE + index] += if (index % 3 == 1) clipped[1] else 0.0;
        }
    }
    index = 0;
    while (index < 6) : (index += 1) movement[STEP_SCAN + index] = movement[STEP_BASE + index];
    const expansion = [3]f64{ request[0], movement[MAX_STEP], request[2] };
    var axis: usize = 0;
    while (axis < 3) : (axis += 1) {
        if (expansion[axis] < 0) {
            movement[STEP_SCAN + axis] += expansion[axis];
        } else if (expansion[axis] > 0) {
            movement[STEP_SCAN + axis + 3] += expansion[axis];
        }
    }
    if (!landed) movement[STEP_SCAN + 1] += -9.999999747378752E-6;
}

fn step(movement: [*]f64, shapes: [*]const voxel.VoxelRef, shape_count: usize) !void {
    const allocator = std.heap.c_allocator;
    var heights: std.ArrayList(f32) = .empty;
    defer heights.deinit(allocator);

    var index: usize = 0;
    while (index < shape_count) : (index += 1) {
        const shape = &shapes[index];
        const geometry = shape.geometry();
        var y: i32 = 0;
        while (y <= geometry.size[1]) : (y += 1) {
            const height: f32 = @floatCast(shape.coordinate(1, @intCast(y)) - movement[STEP_BASE + 1]);
            if (height < 0 or height == @as(f32, @floatCast(movement[RESULT + 1]))) continue;
            if (height > @as(f32, @floatCast(movement[MAX_STEP]))) break;
            try heights.append(allocator, height);
        }
    }

    std.mem.sort(f32, heights.items, {}, std.sort.asc(f32));
    // C++ 用 std::unique：仅去除相邻重复值。
    var unique: usize = 0;
    for (heights.items) |height| {
        if (unique == 0 or heights.items[unique - 1] != height) {
            heights.items[unique] = height;
            unique += 1;
        }
    }
    heights.items.len = unique;

    for (heights.items) |height| {
        var request = [3]f64{ movement[REQUEST], height, movement[REQUEST + 2] };
        var result: [3]f64 = undefined;
        voxel.clipMovement(&request, movement + STEP_BASE, shapes, shape_count, &result);
        if (horizontal(&result) > horizontal(movement + RESULT)) {
            movement[RESULT] = result[0] - 0.0;
            movement[RESULT + 1] = result[1] - (movement[BOX + 1] - movement[STEP_BASE + 1]);
            movement[RESULT + 2] = result[2] - 0.0;
            break;
        }
    }
}

pub fn prepare(entity_bounds: ?[*]const f64, movement_data: ?[*]f64) c_int {
    const movement = movement_data orelse return -1;
    if (entity_bounds) |bounds| {
        var index: usize = 0;
        while (index < 6) : (index += 1) movement[BOX + index] = bounds[index];
    }
    var index: usize = 0;
    while (index < 6) : (index += 1) movement[STEP_SCAN + index] = movement[BOX + index];
    var axis: usize = 0;
    while (axis < 3) : (axis += 1) {
        const delta = movement[REQUEST + axis];
        if (delta < 0) {
            movement[STEP_SCAN + axis] += delta;
        } else if (delta > 0) {
            movement[STEP_SCAN + axis + 3] += delta;
        }
    }
    return 0;
}

const empty_shapes: [0]voxel.VoxelRef = .{};

pub fn solve(
    body_pointer: ?*const anyopaque,
    movement_data: ?[*]f64,
    shape_references_pointer: ?*const anyopaque,
    shape_count: c_int,
    movement_phase: c_int,
) c_int {
    const movement = movement_data orelse return -1;
    if (shape_count < 0
        or (shape_count != 0 and shape_references_pointer == null)
        or movement_phase < 0
        or movement_phase > 1) return -1;

    const shapes: [*]const voxel.VoxelRef = if (shape_references_pointer) |raw|
        @ptrCast(@alignCast(raw))
    else
        &empty_shapes;
    const count: usize = @intCast(shape_count);

    if (movement_phase == 0) {
        initial(movement, shapes, count);
    } else {
        step(movement, shapes, count) catch |err| return native_error.recordError(err);
    }

    if (body_pointer) |raw| {
        const body: *const body_mod.CollisionBody = @ptrCast(@alignCast(raw));
        movement[POSITION] = body.x;
        movement[POSITION + 1] = body.y;
        movement[POSITION + 2] = body.z;
    }
    var axis: usize = 0;
    while (axis < 3) : (axis += 1) {
        movement[TARGET + axis] = movement[POSITION + axis] + movement[RESULT + axis];
    }
    return 0;
}
