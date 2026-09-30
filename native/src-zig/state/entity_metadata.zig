//! 与 C++ `eco::EntityMetadata` 对位：32 字节、字段偏移 0/4/8/12/16/20，
//! 尾部 8 字节填充。该结构只在原生内部使用，不参与 Java FFM 布局。
//!
//! C++ 位域顺序（低到高）：collisionRule:2、selectable、passenger、
//! vanillaEntityPush、allowsDeferredVelocityWrites、hardCollidable、
//! selectableValid、teamValid。

const std = @import("std");

pub const EntityMetadata = extern struct {
    section_x: i32,
    section_y: i32,
    section_z: i32,
    team_id: i32,
    body_slot: i32,
    flags: u32,
    padding: [8]u8,
};

pub const COLLISION_RULE_MASK: u32 = 0b11;
pub const SELECTABLE: u32 = 1 << 2;
pub const PASSENGER: u32 = 1 << 3;
pub const VANILLA_ENTITY_PUSH: u32 = 1 << 4;
pub const ALLOWS_DEFERRED_VELOCITY_WRITES: u32 = 1 << 5;
pub const HARD_COLLIDABLE: u32 = 1 << 6;
pub const SELECTABLE_VALID: u32 = 1 << 7;
pub const TEAM_VALID: u32 = 1 << 8;

pub const METADATA_SELECTABLE: c_int = 1;
pub const METADATA_TEAM: c_int = 2;

pub const COLLISION_ALWAYS: c_int = 0;
pub const COLLISION_NEVER: c_int = 1;
pub const COLLISION_PUSH_OWN_TEAM: c_int = 2;
pub const COLLISION_PUSH_OTHER_TEAMS: c_int = 3;

/// 等价于 C++ 的值初始化 `EntityMetadata{}`（NSDMI：teamId=-1、bodySlot=-1）。
pub fn defaultMetadata() EntityMetadata {
    return .{
        .section_x = 0,
        .section_y = 0,
        .section_z = 0,
        .team_id = -1,
        .body_slot = -1,
        .flags = 0,
        .padding = [_]u8{0} ** 8,
    };
}

pub fn reset(metadata: *EntityMetadata) void {
    metadata.* = defaultMetadata();
}

pub inline fn collisionRule(metadata: EntityMetadata) u32 {
    return metadata.flags & COLLISION_RULE_MASK;
}

pub inline fn setCollisionRule(metadata: *EntityMetadata, rule: u32) void {
    metadata.flags = (metadata.flags & ~COLLISION_RULE_MASK) | (rule & COLLISION_RULE_MASK);
}

pub inline fn has(metadata: EntityMetadata, flag: u32) bool {
    return (metadata.flags & flag) != 0;
}

pub inline fn set(metadata: *EntityMetadata, flag: u32, value: bool) void {
    if (value) metadata.flags |= flag else metadata.flags &= ~flag;
}

pub inline fn selectable(metadata: EntityMetadata) bool {
    return has(metadata, SELECTABLE);
}
pub inline fn selectableValid(metadata: EntityMetadata) bool {
    return has(metadata, SELECTABLE_VALID);
}
pub inline fn hardCollidable(metadata: EntityMetadata) bool {
    return has(metadata, HARD_COLLIDABLE);
}
pub inline fn passenger(metadata: EntityMetadata) bool {
    return has(metadata, PASSENGER);
}
pub inline fn teamValid(metadata: EntityMetadata) bool {
    return has(metadata, TEAM_VALID);
}
pub inline fn vanillaEntityPush(metadata: EntityMetadata) bool {
    return has(metadata, VANILLA_ENTITY_PUSH);
}
pub inline fn allowsDeferredVelocityWrites(metadata: EntityMetadata) bool {
    return has(metadata, ALLOWS_DEFERRED_VELOCITY_WRITES);
}

comptime {
    if (@sizeOf(EntityMetadata) != 32) @compileError("EntityMetadata must stay 32 bytes");
    if (@offsetOf(EntityMetadata, "flags") != 20) @compileError("EntityMetadata.flags must be at offset 20");
}
