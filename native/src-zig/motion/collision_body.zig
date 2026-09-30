//! 与 Java `CollisionStateTable` 共享的行布局（80 字节），偏移由两侧常量钉死。

pub const CollisionBody = extern struct {
    x: f64,
    z: f64,
    vx: f64,
    vy: f64,
    vz: f64,
    velocity_version: u64,
    state: i32,
    root: i32,
    needs_sync: i32,
    reserved: i32,
    y: f64,
    position_version: u64,
};

pub const PUSHABLE: i32 = 1;
pub const VEHICLE: i32 = 2;
pub const PASSENGER: i32 = 4;
pub const SLEEPING: i32 = 8;
pub const NO_PHYSICS: i32 = 16;

comptime {
    if (@sizeOf(CollisionBody) != 80) @compileError("CollisionBody must stay 80 bytes");
    if (@offsetOf(CollisionBody, "velocity_version") != 40) @compileError("CollisionBody.velocity_version");
    if (@offsetOf(CollisionBody, "state") != 48) @compileError("CollisionBody.state");
    if (@offsetOf(CollisionBody, "root") != 52) @compileError("CollisionBody.root");
    if (@offsetOf(CollisionBody, "needs_sync") != 56) @compileError("CollisionBody.needs_sync");
    if (@offsetOf(CollisionBody, "y") != 64) @compileError("CollisionBody.y");
    if (@offsetOf(CollisionBody, "position_version") != 72) @compileError("CollisionBody.position_version");
}
