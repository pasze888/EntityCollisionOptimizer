//! 与 C++ `query/collision_rules.cpp` 对应。

const std = @import("std");
const Aabb = @import("../geometry/aabb.zig").Aabb;
const metadata_mod = @import("../state/entity_metadata.zig");

/// 源包围盒派生的 section 范围，在任何候选访问之前一次性算好。
pub const LookupSections = struct {
    min_x: i64,
    min_y: i64,
    min_z: i64,
    max_x: i64,
    max_y: i64,
    max_z: i64,
};

/// SectionPos.posToSectionCoord：先对块坐标 floor 再移位。
/// 先除后移会把极小的负坐标下溢成 -0.0 并选中 section 0，故顺序不可调换。
fn sectionCoordinate(value: f64) i64 {
    const floored: f64 = @floor(value);
    return (@as(i64, @intFromFloat(floored))) >> 4;
}

pub fn lookupSections(source: Aabb) LookupSections {
    return .{
        .min_x = sectionCoordinate(source.min_x - 2.0),
        .min_y = sectionCoordinate(source.min_y - 4.0),
        .min_z = sectionCoordinate(source.min_z - 2.0),
        .max_x = sectionCoordinate(source.max_x + 2.0),
        .max_y = sectionCoordinate(source.max_y),
        .max_z = sectionCoordinate(source.max_z + 2.0),
    };
}

/// 源相关的规则判定在整次查询内固定。
pub const TeamFilter = struct {
    source_team: i32,
    allied_rules: u32,
    other_rules: u32,

    pub fn init(source_team_id: i32, source_rule: i32) TeamFilter {
        const other: u32 = if (source_rule == metadata_mod.COLLISION_NEVER
            or source_rule == metadata_mod.COLLISION_PUSH_OTHER_TEAMS)
            0
        else
            (@as(u32, 1) << metadata_mod.COLLISION_ALWAYS)
                | (@as(u32, 1) << metadata_mod.COLLISION_PUSH_OWN_TEAM);
        var allied: u32 = if (source_rule == metadata_mod.COLLISION_NEVER
            or source_rule == metadata_mod.COLLISION_PUSH_OWN_TEAM)
            0
        else
            (@as(u32, 1) << metadata_mod.COLLISION_ALWAYS)
                | (@as(u32, 1) << metadata_mod.COLLISION_PUSH_OTHER_TEAMS);
        // 两个都缺席的队伍不算同盟；相等的哨兵 ID 也必须走非同盟规则。
        if (source_team_id < 0) allied = other;
        return .{ .source_team = source_team_id, .allied_rules = allied, .other_rules = other };
    }

    pub fn accepts(self: TeamFilter, target_team_id: i32, target_rule: u32) bool {
        const allowed = if (target_team_id == self.source_team) self.allied_rules else self.other_rules;
        return (allowed & (@as(u32, 1) << @intCast(target_rule))) != 0;
    }
};
