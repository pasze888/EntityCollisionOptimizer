//! 线程局部错误描述。C++ 侧异常在 FFM 边界被翻译成 -100 + 描述串；
//! Zig 没有异常，内部函数返回 error union，这里把 error 名写进同一个缓冲。
//! 与 C++ 一致：不分配、仅对同一线程可见。

const std = @import("std");

pub const NATIVE_EXCEPTION_STATUS: c_int = -100;
const CAPACITY = 256;

threadlocal var last_error: [CAPACITY]u8 = [_]u8{0} ** CAPACITY;

fn append(text: []const u8, length: *usize) void {
    for (text) |byte| {
        if (length.* + 1 >= CAPACITY) return;
        last_error[length.*] = byte;
        length.* += 1;
    }
}

fn writeError(kind: []const u8, detail: ?[]const u8) void {
    var length: usize = 0;
    append(kind, &length);
    if (detail) |text| {
        if (text.len != 0) {
            append(": ", &length);
            append(text, &length);
        }
    }
    last_error[length] = 0;
}

pub fn record(kind: []const u8, detail: ?[]const u8) c_int {
    writeError(kind, detail);
    return NATIVE_EXCEPTION_STATUS;
}

/// C++ `std::bad_alloc` 的等价物。
pub fn recordOutOfMemory() c_int {
    return record("std.heap.c_allocator", "OutOfMemory");
}

pub fn recordError(err: anyerror) c_int {
    return record(@errorName(err), null);
}

pub fn message() [*:0]const u8 {
    return @ptrCast(&last_error);
}
