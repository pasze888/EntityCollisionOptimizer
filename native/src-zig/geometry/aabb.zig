//! 与 C++ `eco::Aabb` 逐字段对应；Java 以同一顺序写入 6 个 double。

pub const Aabb = extern struct {
    min_x: f64,
    min_y: f64,
    min_z: f64,
    max_x: f64,
    max_y: f64,
    max_z: f64,
};

comptime {
    if (@sizeOf(Aabb) != 48) @compileError("Aabb must stay 48 bytes");
}
