import java.io.ByteArrayOutputStream;
import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.invoke.MethodHandle;
import java.util.Random;

import static java.lang.foreign.ValueLayout.ADDRESS;
import static java.lang.foreign.ValueLayout.JAVA_BYTE;
import static java.lang.foreign.ValueLayout.JAVA_DOUBLE;
import static java.lang.foreign.ValueLayout.JAVA_INT;
import static java.lang.foreign.ValueLayout.JAVA_LONG;
import static java.lang.foreign.ValueLayout.JAVA_SHORT;

/**
 * L1 差分验证：把 C++ 与 Zig 两个原生库加载进同一个 JVM，跑同一组确定性场景，
 * 逐字节比对"可观察输出"（返回码、输出数组、被改写内存的原始位模式）。
 *
 * 用法：
 *   java --enable-native-access=ALL-UNNAMED DifferentialHarness.java <libA> <libB>
 *
 * 不依赖 Minecraft，也不依赖 Gradle；任何 JDK 22+ 环境可跑。指针地址一律不入 transcript。
 */
public final class DifferentialHarness {

    private static final int BODY_STRIDE = 80;

    /** 可选种子偏移（第三个命令行参数）：让 CI 用不同语料重复验证。 */
    private static long seedBase = 0;

    // ---------------------------------------------------------------- 后端绑定

    private static final class Api {
        final String name;
        final MethodHandle lastError, createContext, destroyContext, insert, updateState, updateBounds,
                updateSection, remove, invalidateId, invalidateFields, queryHard, queryEntities,
                queryPushable, pushRun, prepareMovement, solveMovement, blockScan;

        Api(String name, SymbolLookup library, Linker linker) {
            this.name = name;
            lastError = down(linker, library, "lastNativeException", FunctionDescriptor.of(ADDRESS));
            createContext = down(linker, library, "createCollisionContext", FunctionDescriptor.of(ADDRESS));
            destroyContext = down(linker, library, "destroyCollisionContext", FunctionDescriptor.ofVoid(ADDRESS));
            insert = down(linker, library, "insertCollisionEntity",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT, JAVA_INT));
            updateState = down(linker, library, "updateCollisionEntityState",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT,
                            JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT));
            updateBounds = down(linker, library, "updateCollisionEntityBounds",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS));
            updateSection = down(linker, library, "updateCollisionEntitySection",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT));
            remove = down(linker, library, "removeCollisionEntity",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT));
            invalidateId = down(linker, library, "invalidateEntityPushEligibilityCache",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT));
            invalidateFields = down(linker, library, "invalidatePushEligibilityCacheFields",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT));
            queryHard = down(linker, library, "queryHardCollisionEntities",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_DOUBLE, JAVA_DOUBLE, JAVA_DOUBLE,
                            JAVA_DOUBLE, JAVA_DOUBLE, JAVA_DOUBLE, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT));
            queryEntities = down(linker, library, "queryEntitiesInBox",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_DOUBLE, JAVA_DOUBLE, JAVA_DOUBLE,
                            JAVA_DOUBLE, JAVA_DOUBLE, JAVA_DOUBLE, ADDRESS, JAVA_INT));
            queryPushable = down(linker, library, "queryPushableEntities",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, JAVA_INT, JAVA_INT,
                            JAVA_INT, ADDRESS, ADDRESS, JAVA_INT));
            pushRun = down(linker, library, "executePushRun",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, ADDRESS, JAVA_INT));
            prepareMovement = down(linker, library, "prepareMovement",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS));
            solveMovement = down(linker, library, "solveMovement",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, ADDRESS, JAVA_INT, JAVA_INT));
            blockScan = down(linker, library, "scanCollisionBlocks",
                    FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, ADDRESS, JAVA_INT));
        }
    }

    private static MethodHandle down(Linker linker, SymbolLookup library, String symbol, FunctionDescriptor descriptor) {
        return linker.downcallHandle(
                library.find(symbol).orElseThrow(
                        () -> new IllegalStateException("missing native symbol: " + symbol)),
                descriptor);
    }

    private static Object call(MethodHandle handle, Object... arguments) {
        try {
            return handle.invokeWithArguments(arguments);
        } catch (Throwable failure) {
            throw new IllegalStateException("native call failed", failure);
        }
    }

    private static int callInt(MethodHandle handle, Object... arguments) {
        return ((Number) call(handle, arguments)).intValue();
    }

    // ---------------------------------------------------------------- transcript

    /** 小端、定长编码；double 一律按原始位模式记录，-0.0/NaN 也必须逐位一致。 */
    private static final class Transcript {
        private final ByteArrayOutputStream out = new ByteArrayOutputStream();

        void marker(int value) {
            out.write(0xA5);
            out.write(0x5A);
            i(value);
        }

        void bool(boolean value) {
            out.write(value ? 1 : 0);
        }

        void i(int value) {
            out.write(value & 0xFF);
            out.write((value >>> 8) & 0xFF);
            out.write((value >>> 16) & 0xFF);
            out.write((value >>> 24) & 0xFF);
        }

        void l(long value) {
            i((int) value);
            i((int) (value >>> 32));
        }

        void d(double value) {
            l(Double.doubleToRawLongBits(value));
        }

        void ints(MemorySegment segment, long count) {
            for (long index = 0; index < count; index++) {
                i(segment.get(JAVA_INT, index * JAVA_INT.byteSize()));
            }
        }

        void bytes(MemorySegment segment, long bytes) {
            for (long offset = 0; offset < bytes; offset++) {
                out.write(segment.get(JAVA_BYTE, offset));
            }
        }

        byte[] toByteArray() {
            return out.toByteArray();
        }
    }

    // ---------------------------------------------------------------- 场景

    private static byte[] runAll(Api api) {
        Transcript transcript = new Transcript();
        try (Arena arena = Arena.ofShared()) {
            scenarioEntities(api, transcript, arena);
            scenarioPushRun(api, transcript, arena);
            scenarioMovement(api, transcript, arena);
            scenarioBlockScan(api, transcript, arena);
        }
        return transcript.toByteArray();
    }

    private static void writeBounds(MemorySegment bounds, Random random, int sectionX, int sectionY, int sectionZ) {
        double baseX = sectionX * 16.0 + random.nextInt(16);
        double baseY = sectionY * 16.0 + random.nextInt(16);
        double baseZ = sectionZ * 16.0 + random.nextInt(16);
        double widthX = 0.125 + random.nextInt(32) * 0.125;
        double heightY = 0.125 + random.nextInt(32) * 0.125;
        double widthZ = 0.125 + random.nextInt(32) * 0.125;
        bounds.set(JAVA_DOUBLE, 0, baseX);
        bounds.set(JAVA_DOUBLE, 8, baseY);
        bounds.set(JAVA_DOUBLE, 16, baseZ);
        bounds.set(JAVA_DOUBLE, 24, baseX + widthX);
        bounds.set(JAVA_DOUBLE, 32, baseY + heightY);
        bounds.set(JAVA_DOUBLE, 40, baseZ + widthZ);
    }

    private static void scenarioEntities(Api api, Transcript transcript, Arena arena) {
        transcript.marker(1);
        MemorySegment context = (MemorySegment) call(api.createContext);
        boolean live = !context.equals(MemorySegment.NULL);
        transcript.bool(live);
        if (!live) {
            return;
        }
        try {
            MemorySegment bounds = arena.allocate(48, 8);
            MemorySegment output = arena.allocate(1024L * JAVA_INT.byteSize(), JAVA_INT.byteSize());
            MemorySegment flags = arena.allocate(1024L * JAVA_INT.byteSize(), JAVA_INT.byteSize());
            Random random = new Random(0x5EED0001L + seedBase);
            final int entityCount = 512;

            boolean[] indexed = new boolean[entityCount];
            for (int id = 0; id < entityCount; id++) {
                int sectionX = random.nextInt(9) - 4;
                int sectionY = random.nextInt(5) - 2;
                int sectionZ = random.nextInt(9) - 4;
                writeBounds(bounds, random, sectionX, sectionY, sectionZ);
                int status = callInt(api.insert, context, id, bounds, sectionX, sectionY, sectionZ);
                transcript.i(status);
                indexed[id] = status == 0;
                transcript.i(callInt(api.updateState, context, id,
                        random.nextInt(2), random.nextInt(2), random.nextInt(2), random.nextInt(2),
                        random.nextInt(4) - 1, random.nextInt(4), id, random.nextInt(2)));
            }

            // 只对"当前在索引中"的实体做 bounds/section/remove：这是生产侧的调用语义。
            // 对已退役 ID 只发校验类调用，并覆盖"退役 ID 复用"这条路径。
            // 注意：对已退役实体发 updateSection 会让 C++ 参考库空指针崩溃（上游缺陷），
            // 所以该组合不进差分语料，改由 tests/HardeningProbe.java 作为有意分歧单独回归。
            for (int step = 0; step < 900; step++) {
                int id = random.nextInt(entityCount);
                if (!indexed[id]) {
                    if (random.nextInt(2) == 0) {
                        int sectionX = random.nextInt(9) - 4;
                        int sectionY = random.nextInt(5) - 2;
                        int sectionZ = random.nextInt(9) - 4;
                        writeBounds(bounds, random, sectionX, sectionY, sectionZ);
                        int status = callInt(api.insert, context, id, bounds, sectionX, sectionY, sectionZ);
                        transcript.i(status);
                        indexed[id] = status == 0;
                    } else {
                        int invalidId = random.nextBoolean() ? -1 : entityCount + 5;
                        transcript.i(callInt(api.updateSection, context, invalidId,
                                random.nextInt(9) - 4, random.nextInt(5) - 2, random.nextInt(9) - 4));
                        transcript.i(callInt(api.updateBounds, context, invalidId, bounds));
                        transcript.i(callInt(api.remove, context, invalidId));
                        transcript.i(callInt(api.invalidateId, context, invalidId));
                    }
                    continue;
                }
                switch (random.nextInt(6)) {
                    case 0 -> {
                        writeBounds(bounds, random, random.nextInt(9) - 4, random.nextInt(5) - 2, random.nextInt(9) - 4);
                        transcript.i(callInt(api.updateBounds, context, id, bounds));
                    }
                    case 1 -> transcript.i(callInt(api.updateSection, context, id,
                            random.nextInt(9) - 4, random.nextInt(5) - 2, random.nextInt(9) - 4));
                    case 2 -> transcript.i(callInt(api.invalidateId, context, id));
                    case 3 -> transcript.i(callInt(api.invalidateFields, context, random.nextInt(4)));
                    case 4 -> transcript.i(callInt(api.updateState, context, id,
                            random.nextInt(2), random.nextInt(2), random.nextInt(2), random.nextInt(2),
                            random.nextInt(4) - 1, random.nextInt(4), id, random.nextInt(2)));
                    default -> {
                        transcript.i(callInt(api.remove, context, id));
                        indexed[id] = false;
                    }
                }
            }

            for (int query = 0; query < 400; query++) {
                int sectionX = random.nextInt(11) - 5;
                int sectionY = random.nextInt(7) - 3;
                int sectionZ = random.nextInt(11) - 5;
                double baseX = sectionX * 16.0 + random.nextInt(16);
                double baseY = sectionY * 16.0 + random.nextInt(16);
                double baseZ = sectionZ * 16.0 + random.nextInt(16);
                double sizeX = 0.5 + random.nextInt(64);
                double sizeY = 0.5 + random.nextInt(64);
                double sizeZ = 0.5 + random.nextInt(64);
                int capacity = 1 + random.nextInt(24);
                int excluded = switch (random.nextInt(4)) {
                    case 0 -> -1;
                    case 1 -> random.nextInt(entityCount);
                    default -> entityCount;
                };

                int hardResult = callInt(api.queryHard, context,
                        baseX, baseY, baseZ, baseX + sizeX, baseY + sizeY, baseZ + sizeZ,
                        excluded, random.nextInt(2), output, capacity);
                transcript.i(hardResult);
                if (hardResult >= 0) {
                    transcript.ints(output, hardResult);
                }

                int boxResult = callInt(api.queryEntities, context,
                        baseX, baseY, baseZ, baseX + sizeX, baseY + sizeY, baseZ + sizeZ, output, capacity);
                transcript.i(boxResult);
                if (boxResult >= 0) {
                    transcript.ints(output, boxResult);
                }

                MemorySegment sourceBounds = arena.allocate(48, 8);
                writeBounds(sourceBounds, random, sectionX, sectionY, sectionZ);
                int pushResult = callInt(api.queryPushable, context, sourceBounds,
                        excluded, random.nextInt(4) - 1, random.nextInt(4), random.nextInt(2),
                        output, flags, capacity);
                transcript.i(pushResult);
                transcript.ints(output, 3);
                long resultBytes = (long) Math.max(pushResult, 0) * JAVA_INT.byteSize();
                if (output.get(JAVA_INT, 0) != 0) {
                    if (pushResult > 0) {
                        transcript.ints(output.asSlice(3L * JAVA_INT.byteSize(), resultBytes), pushResult);
                    }
                } else if (pushResult > 0) {
                    transcript.ints(output.asSlice(3L * JAVA_INT.byteSize(), resultBytes), pushResult);
                    transcript.ints(output.asSlice((3L + capacity) * JAVA_INT.byteSize(), resultBytes), pushResult);
                    transcript.ints(flags, pushResult);
                }
            }
        } finally {
            call(api.destroyContext, context);
        }
    }

    private static void scenarioPushRun(Api api, Transcript transcript, Arena arena) {
        transcript.marker(2);
        Random random = new Random(0x5EED0002L + seedBase);
        final int capacity = 96;
        MemorySegment bodies = arena.allocate((long) capacity * BODY_STRIDE, 8);
        for (int index = 0; index < capacity; index++) {
            long base = (long) index * BODY_STRIDE;
            bodies.set(JAVA_DOUBLE, base, random.nextDouble() * 8.0 - 4.0);
            bodies.set(JAVA_DOUBLE, base + 8, random.nextDouble() * 8.0 - 4.0);
            bodies.set(JAVA_DOUBLE, base + 16, random.nextDouble() * 0.2 - 0.1);
            bodies.set(JAVA_DOUBLE, base + 24, random.nextDouble() * 0.2 - 0.1);
            bodies.set(JAVA_DOUBLE, base + 32, random.nextDouble() * 0.2 - 0.1);
            bodies.set(JAVA_LONG, base + 40, random.nextInt(4));
            bodies.set(JAVA_INT, base + 48, random.nextInt(32));
            bodies.set(JAVA_INT, base + 52, random.nextInt(4));
            bodies.set(JAVA_INT, base + 56, random.nextInt(2));
            bodies.set(JAVA_INT, base + 60, 0);
            bodies.set(JAVA_DOUBLE, base + 64, random.nextDouble() * 4.0);
            bodies.set(JAVA_LONG, base + 72, 0L);
        }
        MemorySegment source = arena.allocate(BODY_STRIDE, 8);
        MemorySegment slots = arena.allocate(64L * JAVA_INT.byteSize(), JAVA_INT.byteSize());
        MemorySegment baseline = arena.allocate((long) capacity * BODY_STRIDE, 8);
        MemorySegment.copy(bodies, 0, baseline, 0, (long) capacity * BODY_STRIDE);

        for (int round = 0; round < 40; round++) {
            MemorySegment.copy(baseline, 0, bodies, 0, (long) capacity * BODY_STRIDE);
            int sourceSlot = random.nextInt(capacity);
            MemorySegment.copy(bodies, (long) sourceSlot * BODY_STRIDE, source, 0, BODY_STRIDE);
            int targetCount = 1 + random.nextInt(48);
            for (int index = 0; index < targetCount; index++) {
                slots.set(JAVA_INT, (long) index * JAVA_INT.byteSize(), random.nextInt(capacity));
            }
            transcript.i(callInt(api.pushRun, source, bodies, capacity, slots, targetCount));
            transcript.bytes(source, BODY_STRIDE);
            transcript.bytes(bodies, (long) capacity * BODY_STRIDE);
        }
    }

    private static MemorySegment buildGeometry(
            Arena arena, int[] size, double[][] coordinates, boolean[][][] occupancy, int flags) {
        long coordinateCount = 0;
        for (int axis = 0; axis < 3; axis++) {
            coordinateCount += size[axis] + 1;
        }
        long cells = (long) size[0] * size[1] * size[2];
        long bitsWords = (cells + 63) / 64;
        MemorySegment geometry = arena.allocate(16 + coordinateCount * 8 + bitsWords * 8, 8);
        geometry.set(JAVA_INT, 0, size[0]);
        geometry.set(JAVA_INT, 4, size[1]);
        geometry.set(JAVA_INT, 8, size[2]);
        geometry.set(JAVA_INT, 12, flags);
        long offset = 16;
        for (int axis = 0; axis < 3; axis++) {
            for (int index = 0; index <= size[axis]; index++) {
                geometry.set(JAVA_DOUBLE, offset, coordinates[axis][index]);
                offset += 8;
            }
        }
        long bitsOffset = offset;
        for (int x = 0; x < size[0]; x++) {
            for (int y = 0; y < size[1]; y++) {
                for (int z = 0; z < size[2]; z++) {
                    if (!occupancy[x][y][z]) {
                        continue;
                    }
                    long cellIndex = ((long) x * size[1] + y) * size[2] + z;
                    long address = bitsOffset + (cellIndex >>> 6) * 8;
                    geometry.set(JAVA_LONG, address,
                            geometry.get(JAVA_LONG, address) | (1L << (cellIndex & 63)));
                }
            }
        }
        return geometry;
    }

    private static MemorySegment buildBatch(Arena arena, MemorySegment[] geometries, boolean[] translated,
            double[][] offsets) {
        MemorySegment batch = arena.allocate((long) geometries.length * 32, 8);
        for (int index = 0; index < geometries.length; index++) {
            long base = (long) index * 32;
            batch.set(JAVA_LONG, base, geometries[index].address() | (translated[index] ? 1L : 0L));
            batch.set(JAVA_DOUBLE, base + 8, offsets[index][0]);
            batch.set(JAVA_DOUBLE, base + 16, offsets[index][1]);
            batch.set(JAVA_DOUBLE, base + 24, offsets[index][2]);
        }
        return batch;
    }

    private static void scenarioMovement(Api api, Transcript transcript, Arena arena) {
        transcript.marker(3);
        Random random = new Random(0x5EED0003L + seedBase);

        // 单格立方体：flags = CUBE_INDEX | SINGLE_CELL，走 clipSingleCell 特化路径。
        MemorySegment cube = buildGeometry(arena, new int[] { 1, 1, 1 },
                new double[][] { { 0.0, 1.0 }, { 0.0, 1.0 }, { 0.0, 1.0 } },
                new boolean[][][] { { { true } } }, 2 | 4);
        // 2x2x2 网格：走 full() 与通用扫描路径。
        MemorySegment grid = buildGeometry(arena, new int[] { 2, 2, 2 },
                new double[][] { { 0.0, 0.5, 1.0 }, { 0.0, 0.5, 1.0 }, { 0.0, 0.5, 1.0 } },
                new boolean[][][] {
                        { { true, false }, { true, true } },
                        { { true, true }, { false, true } } },
                0);
        // 空形状：flags = EMPTY。
        MemorySegment empty = buildGeometry(arena, new int[] { 1, 1, 1 },
                new double[][] { { 0.0, 1.0 }, { 0.0, 1.0 }, { 0.0, 1.0 } },
                new boolean[][][] { { { false } } }, 1);

        for (int round = 0; round < 500; round++) {
            int shapeCount = random.nextInt(4);
            MemorySegment[] geometries = new MemorySegment[Math.max(shapeCount, 1)];
            boolean[] translated = new boolean[Math.max(shapeCount, 1)];
            double[][] offsets = new double[Math.max(shapeCount, 1)][3];
            for (int index = 0; index < shapeCount; index++) {
                geometries[index] = switch (random.nextInt(4)) {
                    case 0 -> cube;
                    case 1 -> grid;
                    case 2 -> empty;
                    default -> buildGeometry(arena, new int[] { 3, 1, 2 },
                            new double[][] { { 0.0, 0.25, 0.5, 1.0 }, { 0.0, 1.0 }, { 0.0, 0.5, 1.0 } },
                            new boolean[][][] {
                                    { { true, false }, { true, true } },
                                    { { true, true }, { false, true } },
                                    { { false, true }, { true, true } } },
                            random.nextInt(2) == 0 ? 0 : 2);
                };
                translated[index] = random.nextInt(3) == 0;
                offsets[index][0] = random.nextDouble() * 4.0 - 2.0;
                offsets[index][1] = random.nextDouble() * 4.0 - 2.0;
                offsets[index][2] = random.nextDouble() * 4.0 - 2.0;
            }
            MemorySegment batch = shapeCount == 0 ? MemorySegment.NULL
                    : buildBatch(arena, geometries, translated, offsets);

            MemorySegment bounds = arena.allocate(48, 8);
            writeBounds(bounds, random, random.nextInt(5) - 2, random.nextInt(3) - 1, random.nextInt(5) - 2);
            MemorySegment body = arena.allocate(BODY_STRIDE, 8);
            body.set(JAVA_DOUBLE, 0, random.nextDouble() * 8.0 - 4.0);
            body.set(JAVA_DOUBLE, 8, random.nextDouble() * 8.0 - 4.0);
            body.set(JAVA_DOUBLE, 64, random.nextDouble() * 4.0);
            MemorySegment packet = arena.allocate(34L * 8, 8);
            packet.set(JAVA_DOUBLE, 6L * 8, random.nextDouble() * 1.2 - 0.6);
            packet.set(JAVA_DOUBLE, 7L * 8, random.nextDouble() * 1.6 - 0.8);
            packet.set(JAVA_DOUBLE, 8L * 8, random.nextDouble() * 1.2 - 0.6);
            packet.set(JAVA_DOUBLE, 33L * 8, random.nextInt(2));
            packet.set(JAVA_DOUBLE, 30L * 8, random.nextInt(2) == 0 ? 0.0 : 0.6);
            packet.set(JAVA_DOUBLE, 31L * 8, random.nextInt(2));

            transcript.i(callInt(api.prepareMovement, bounds, packet));
            transcript.i(callInt(api.solveMovement, body, packet, batch, shapeCount, 0));
            transcript.bytes(packet, 34L * 8);
            transcript.i(callInt(api.solveMovement, body, packet, batch, shapeCount, 1));
            transcript.bytes(packet, 34L * 8);
        }
    }

    private static void scenarioBlockScan(Api api, Transcript transcript, Arena arena) {
        transcript.marker(4);
        Random random = new Random(0x5EED0004L + seedBase);
        final int descriptorCount = 32;
        MemorySegment descriptors = arena.allocate((long) descriptorCount * 8, 8);
        final long rowLength = 768;
        MemorySegment[] rows = new MemorySegment[descriptorCount];
        for (int index = 0; index < descriptorCount; index++) {
            if (random.nextInt(4) == 0) {
                descriptors.set(ADDRESS, (long) index * 8, MemorySegment.NULL);
                continue;
            }
            MemorySegment row = arena.allocate(rowLength * JAVA_SHORT.byteSize(), 8);
            for (long cell = 0; cell < rowLength; cell++) {
                row.set(JAVA_SHORT, cell * JAVA_SHORT.byteSize(), (short) random.nextInt(1 << 16));
            }
            rows[index] = row;
            descriptors.set(ADDRESS, (long) index * 8, row);
        }

        MemorySegment queryState = arena.allocate(10L * JAVA_INT.byteSize(), JAVA_INT.byteSize());
        MemorySegment records = arena.allocate(64L * 4 * JAVA_INT.byteSize(), JAVA_INT.byteSize());
        for (int round = 0; round < 60; round++) {
            int minX = random.nextInt(64) - 32;
            int minY = random.nextInt(64) - 32;
            int minZ = random.nextInt(64) - 32;
            int maxX = minX + random.nextInt(48);
            int maxY = minY + random.nextInt(48);
            int maxZ = minZ + random.nextInt(48);
            queryState.set(JAVA_INT, 0, minX);
            queryState.set(JAVA_INT, 4, minY);
            queryState.set(JAVA_INT, 8, minZ);
            queryState.set(JAVA_INT, 12, maxX);
            queryState.set(JAVA_INT, 16, maxY);
            queryState.set(JAVA_INT, 20, maxZ);
            queryState.set(JAVA_INT, 24, minX);
            queryState.set(JAVA_INT, 28, minY);
            queryState.set(JAVA_INT, 32, minZ);
            queryState.set(JAVA_INT, 36, 0);
            int capacity = 1 + random.nextInt(16);
            for (int page = 0; page < 64; page++) {
                int recordCount = callInt(api.blockScan, descriptors, queryState, records, capacity);
                transcript.i(recordCount);
                transcript.ints(queryState.asSlice(6L * JAVA_INT.byteSize(), 4L * JAVA_INT.byteSize()), 4);
                if (recordCount > 0) {
                    transcript.ints(records, (long) recordCount * 4);
                }
                if (recordCount <= 0 || queryState.get(JAVA_INT, 36) != 0) {
                    break;
                }
            }
        }
    }

    // ---------------------------------------------------------------- 入口

    public static void main(String[] arguments) {
        if (arguments.length < 2) {
            System.err.println("usage: java DifferentialHarness.java <libraryA> <libraryB> [seed]");
            System.exit(2);
        }
        if (arguments.length > 2) {
            seedBase = Long.parseLong(arguments[2]);
        }
        Linker linker = Linker.nativeLinker();
        SymbolLookup lookupA = SymbolLookup.libraryLookup(arguments[0], Arena.global());
        SymbolLookup lookupB = SymbolLookup.libraryLookup(arguments[1], Arena.global());
        Api backendA = new Api(arguments[0], lookupA, linker);
        Api backendB = new Api(arguments[1], lookupB, linker);

        byte[] transcriptA = runAll(backendA);
        byte[] transcriptB = runAll(backendB);

        System.out.printf("%-28s transcript = %d bytes%n", backendA.name, transcriptA.length);
        System.out.printf("%-28s transcript = %d bytes%n", backendB.name, transcriptB.length);

        if (transcriptA.length != transcriptB.length) {
            System.out.println("FAIL: transcript 长度不同");
            reportFirstDifference(transcriptA, transcriptB);
            System.exit(1);
        }
        for (int index = 0; index < transcriptA.length; index++) {
            if (transcriptA[index] != transcriptB[index]) {
                System.out.println("FAIL: 首个分歧出现在偏移 " + index);
                reportFirstDifference(transcriptA, transcriptB);
                System.exit(1);
            }
        }
        System.out.println("PASS: " + transcriptA.length + " 字节 transcript 逐字节一致");
    }

    private static void reportFirstDifference(byte[] a, byte[] b) {
        int length = Math.min(a.length, b.length);
        int first = 0;
        while (first < length && a[first] == b[first]) {
            first++;
        }
        StringBuilder line = new StringBuilder("  offset " + first + ": A=");
        for (int index = Math.max(0, first - 8); index < Math.min(length, first + 16); index++) {
            line.append(String.format("%02X", a[index]));
        }
        line.append("  B=");
        for (int index = Math.max(0, first - 8); index < Math.min(length, first + 16); index++) {
            line.append(String.format("%02X", b[index]));
        }
        System.out.println(line);
    }
}
