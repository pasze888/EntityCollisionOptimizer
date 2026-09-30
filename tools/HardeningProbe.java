import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.invoke.MethodHandle;
import java.nio.file.Path;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_DOUBLE;
import static java.lang.foreign.ValueLayout.JAVA_INT;

/**
 * 硬化探针：回归 Zig 侧对"上游缺陷"的修复。
 *
 * 缺陷：updateCollisionEntitySection 作用在已退役（或从未入索引）的实体上时，
 * 成员槽的 members 为空，C++ 参考实现在 section_index.cpp:67 直接解引用它并崩溃。
 * Zig 侧改为只同步元数据坐标并返回 0（见 docs/design/eco-native-zig-port.md §8）。
 *
 * 用法：
 *   java --enable-native-access=ALL-UNNAMED HardeningProbe.java <zigLib>
 *   java --enable-native-access=ALL-UNNAMED HardeningProbe.java <zigLib> --expect-crash   # 对 C++ 参考库
 *
 * 退出码 0 = 符合预期。
 */
public final class HardeningProbe {

    public static void main(String[] arguments) throws Throwable {
        if (arguments.length < 1) {
            System.err.println("usage: java HardeningProbe.java <library> [--expect-crash]");
            System.exit(2);
        }
        boolean expectCrash = arguments.length > 1 && arguments[1].equals("--expect-crash");
        Linker linker = Linker.nativeLinker();
        SymbolLookup library = SymbolLookup.libraryLookup(Path.of(arguments[0]), Arena.global());

        MethodHandle createContext = down(linker, library, "createCollisionContext", FunctionDescriptor.of(ADDRESS));
        MethodHandle destroyContext = down(linker, library, "destroyCollisionContext", FunctionDescriptor.ofVoid(ADDRESS));
        MethodHandle insert = down(linker, library, "insertCollisionEntity",
                FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT, JAVA_INT));
        MethodHandle updateSection = down(linker, library, "updateCollisionEntitySection",
                FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT));
        MethodHandle updateBounds = down(linker, library, "updateCollisionEntityBounds",
                FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS));
        MethodHandle remove = down(linker, library, "removeCollisionEntity",
                FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT));
        MethodHandle queryHard = down(linker, library, "queryHardCollisionEntities",
                FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_DOUBLE, JAVA_DOUBLE, JAVA_DOUBLE,
                        JAVA_DOUBLE, JAVA_DOUBLE, JAVA_DOUBLE, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT));

        int failures = 0;
        try (Arena arena = Arena.ofShared()) {
            MemorySegment context = (MemorySegment) createContext.invokeWithArguments();
            if (context.equals(MemorySegment.NULL)) {
                System.out.println("FAIL: createCollisionContext 返回空");
                System.exit(1);
            }
            MemorySegment bounds = arena.allocate(48, 8);
            writeBounds(bounds, 0.0, 0.0, 0.0);
            MemorySegment moved = arena.allocate(48, 8);
            writeBounds(moved, 64.0, 0.0, 64.0);
            MemorySegment output = arena.allocate(64L * JAVA_INT.byteSize(), JAVA_INT.byteSize());

            // 用例 1：已在索引中的实体跨 section 搬迁，行为必须保持正常。
            failures += expect(insert.invokeWithArguments(context, 0, bounds, 0, 0, 0), 0, "插入实体 0");
            failures += expect(updateSection.invokeWithArguments(context, 0, 4, 0, 4), 0, "在世实体跨 section 搬迁");
            failures += expect(updateBounds.invokeWithArguments(context, 0, moved), 0, "在世实体更新 bounds");

            // 用例 2：移除后对退役 ID 发 section 更新 —— 缺陷触发点。
            failures += expect(remove.invokeWithArguments(context, 0), 0, "移除实体 0");
            if (expectCrash) {
                // 真正发起致命调用：进程若在此崩溃，即证明上游缺陷存在。
                System.out.println("即将对退役 ID 发 section 更新；含缺陷的实现应在此崩溃");
                System.out.flush();
                updateSection.invokeWithArguments(context, 0, 8, 0, 8);
                System.out.println("UNEXPECTED: 未崩溃，该库不含此缺陷");
                System.exit(1);
            }
            int status = ((Number) updateSection.invokeWithArguments(context, 0, 8, 0, 8)).intValue();
            failures += expect(status, 0, "退役 ID 的 section 更新必须安全返回 0");
            // 搬迁后索引里不应留下幽灵成员。
            int ghosts = ((Number) queryHard.invokeWithArguments(context,
                    56.0, -16.0, 56.0, 120.0, 16.0, 120.0, -1, 0, output, 16)).intValue();
            failures += expect(ghosts, 0, "退役实体的新 section 不应出现成员");

            // 用例 3：从未入索引的 ID（out of range）仍按非法参数拒绝。
            failures += expect(updateSection.invokeWithArguments(context, 9999, 1, 1, 1), -1, "越界 ID 仍返回 -1");
            failures += expect(updateSection.invokeWithArguments(context, -3, 1, 1, 1), -1, "负 ID 仍返回 -1");

            // 用例 4：退役 ID 复用后必须能重新入索引。
            // 查询框同时覆盖该实体的 bounds(64..66) 与它被登记的 section(5,0,5 = 方块 80..95)，
            // 因此无论查询是按 section 还是按 bounds 过滤都应当命中；hardOnly 传 0，
            // 因为本探针不发布硬化元数据。
            failures += expect(insert.invokeWithArguments(context, 0, moved, 4, 0, 4), 0, "退役 ID 复用");
            failures += expect(updateSection.invokeWithArguments(context, 0, 5, 0, 5), 0, "复用实体跨 section 搬迁");
            int found = ((Number) queryHard.invokeWithArguments(context,
                    56.0, -16.0, 56.0, 120.0, 16.0, 120.0, -1, 0, output, 16)).intValue();
            failures += expect(found, 1, "复用实体应重新可查询");

            destroyContext.invokeWithArguments(context);
        }

        if (failures == 0) {
            System.out.println("PASS: 硬化行为全部符合预期");
            System.exit(0);
        }
        System.out.println("FAIL: " + failures + " 项不符合预期");
        System.exit(1);
    }

    private static int expect(Object actual, int wanted, String what) {
        int value = ((Number) actual).intValue();
        if (value == wanted) {
            System.out.println("  ok   " + what + " -> " + value);
            return 0;
        }
        System.out.println("  FAIL " + what + ": 期望 " + wanted + "，实际 " + value);
        return 1;
    }

    private static MethodHandle down(Linker linker, SymbolLookup library, String symbol, FunctionDescriptor descriptor) {
        return linker.downcallHandle(
                library.find(symbol).orElseThrow(() -> new IllegalStateException("missing symbol: " + symbol)),
                descriptor);
    }

    private static void writeBounds(MemorySegment bounds, double baseX, double baseY, double baseZ) {
        bounds.set(JAVA_DOUBLE, 0, baseX);
        bounds.set(JAVA_DOUBLE, 8, baseY);
        bounds.set(JAVA_DOUBLE, 16, baseZ);
        bounds.set(JAVA_DOUBLE, 24, baseX + 2.0);
        bounds.set(JAVA_DOUBLE, 32, baseY + 2.0);
        bounds.set(JAVA_DOUBLE, 40, baseZ + 2.0);
    }
}
