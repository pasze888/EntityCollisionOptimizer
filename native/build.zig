//! 六个目标的原生库构建：windows/linux/macos × x64/aarch64。
//!
//! 与 C++ 侧的差异（有意为之）：
//!   * x64 目标统一按 x86-64-v3（AVX2 基线）编译：@Vector(4, f64) 会落到 256 位 AVX2，
//!     实测密集查询负载比 SSE2 基线快 18~22%。代价是要求 2013 年后的 x64 CPU
//!     （Haswell / Excavator 及更新；JDK 自身只要求 SSE2，故老 CPU 上 JVM 能起、本库会崩）。
//!     @Vector 由后端自动降级，不再需要 #if AR_X64 的标量回退。
//!   * aarch64 不指定 cpu：NEON 属 aarch64 基线，无需额外要求。
//!   * 不需要交叉编译工具链；zig build 自带 libc 与链接器。
//!   * 浮点保持严格模式（不收缩、不放宽）：与 C++ 的 -ffp-contract=off 等价。
//!   * Release 剥离符号表（对应 C++ 的 -s）：产物约 356 KB → 56 KB，也不再产出 PDB。
//!     Debug 保留符号，便于调试；导出表不受 strip 影响。

const std = @import("std");

const Target = struct {
    name: []const u8,
    query: std.Target.Query,
};

/// x64 目标统一要求 x86-64-v3（AVX2）。这是有意的硬件门槛，与 C++ 原版的
/// -march=x86-64-v2 -mavx2 同级（v3 额外含 BMI/FMA，向量代码路径不受影响）。
const x64_cpu: std.Target.Query.CpuModel = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 };

const targets = [_]Target{
    .{ .name = "windows-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu, .cpu_model = x64_cpu } },
    .{ .name = "windows-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .windows, .abi = .gnu } },
    .{ .name = "linux-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu, .cpu_model = x64_cpu } },
    .{ .name = "linux-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu } },
    // macOS 目标在 Windows 主机上交叉编译，产物路径与 Java 侧 platformNativePath() 的
    // /natives/macos-<arch>/ 对应。zig 默认的最低系统版本是 11.0。
    .{ .name = "macos-x64", .query = .{ .cpu_arch = .x86_64, .os_tag = .macos, .cpu_model = x64_cpu } },
    .{ .name = "macos-arm64", .query = .{ .cpu_arch = .aarch64, .os_tag = .macos } },
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    // 与 C++ 一致：只在非 Debug 下剥离；Debug 保留符号以便调试。
    const strip = optimize != .Debug;
    for (targets) |target| {
        const resolved = b.resolveTargetQuery(target.query);
        const module = b.createModule(.{
            .root_source_file = b.path("src-zig/root.zig"),
            .target = resolved,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip,
        });
        const library = b.addLibrary(.{
            .linkage = .dynamic,
            .name = "EntityCollisionOptimizer",
            .root_module = module,
        });
        const install = b.addInstallArtifact(library, .{
            .dest_dir = .{ .override = .{ .custom = target.name } },
        });
        b.getInstallStep().dependOn(&install.step);
    }
}
