# eco-native Zig 移植：模块清单与 A/B 验证方案

> 状态：**P0~P4 已完成**（2026-10-05，见 §8 实施记录）；Zig 实现已并入模组仓库构建，C++ 原版与其工具链已从仓库移除。
> 落地位置：源码 `EntityCollisionOptimizer/native/src-zig/`，构建脚本 `EntityCollisionOptimizer/native/build.zig` 与根目录 `native-build.gradle`；
> 本文件里的 `eco-native/...` 路径指同一份代码在独立副本目录中的位置（未并入仓库前的工作副本）。
> 结论依据：Zig 0.16.0 在本机 Windows 上以 `zig c++` **零源码改动**交叉编译出 windows-x64 / linux-x64 /
> macos-x64 三平台库，导出符号与 FFM 侧一致（详见 §6 P0）。因此"换语言"与"换构建"可以解耦推进。

本文回答两件事：

1. **移植什么**——`eco-native` 24 个文件、1775 行 C++20 的完整模块清单，含依赖序、风险与 Zig 映射要点；
2. **凭什么说移植后是对的**——复用仓库既有三层测试基建的 A/B 方案，以及各级判定标准。

---

## 1. 不可变契约（ABI 冻结清单）

换实现语言不改变这一层。**任何改动都必须与 Java 侧同步**，因此这一节也是 A/B 的比对基准。

### 1.1 导出符号（17 个）

符号名、签名、可见性由 [collision_api.h](../../native/include/eco/collision_api.h)（独立副本
见 `eco-native/include/eco/collision_api.h`）与 `native/version-script` 共同钉死；Java 侧逐个
`SymbolLookup.find` 绑定，缺一个就初始化失败（`FFMBackend.loadNativeLibrary`）。

| 分组 | 符号 | Java 调用点 |
|---|---|---|
| 错误边界 | `lastNativeException` | `FFMBackend.nativeFailure` |
| 生命周期 | `createCollisionContext` / `destroyCollisionContext` | `FFMBackend.createContext` / `Context.close` |
| 成员管理 | `insertCollisionEntity` / `removeCollisionEntity` | `FFMBackend.insertEntity` / `removeEntity` |
| 状态发布 | `updateCollisionEntityState` / `updateCollisionEntityBounds` / `updateCollisionEntitySection` | 同名包装方法 |
| 缓存失效 | `invalidateEntityPushEligibilityCache` / `invalidatePushEligibilityCacheFields` | 同名包装方法 |
| 查询 | `queryHardCollisionEntities` / `queryEntitiesInBox` / `queryPushableEntities` | `queryHard` / `queryEntities` / `queryPushable` |
| 推挤 | `executePushRun` | `PushBatch.applyNativeRun` |
| 移动 | `prepareMovement` / `solveMovement` | `NativeMovement` 构造 / `solve` |
| 方块扫描 | `scanCollisionBlocks` | `NativeBlockScan.next` |

### 1.2 共享内存布局（逐字节冻结）

| 结构 | 大小 | 偏移 | Java 侧 |
|---|---|---|---|
| `CollisionBody` | 80 B | x=0, z=8, vx=16, vy=24, vz=32, velocityVersion=40, state=48, root=52, needsSync=56, reserved=60, y=64, positionVersion=72 | `CollisionStateTable.STRIDE_BYTES` 及同名偏移常量 |
| `CollisionBounds` 行 | 56 B | minXYZ=0/8/16, maxXYZ=24/32/40, version=48 | `CollisionBounds.STRIDE` / `VERSION` |
| movement packet | 34 × f64 = 272 B | BOX=0(6), REQUEST=6(3), POSITION=9(3), RESULT=12(3), TARGET=15(3), STEP_BASE=18(6), STEP_SCAN=24(6), MAX_STEP=30, GROUNDED=31, NEEDS_STEP=32, ENTITY_QUERY=33 | `NativeMovement` 下标字面量 |
| `VoxelRef` | 32 B | geometryTag(u64)=0, offset[3]=8/16/24 | `NativeShapeBatch.STRIDE = 32` |
| `VoxelGeometry` | 16 B 头 + 变长 | size[3]=0/4/8(i32), flags=12(i32)；随后 axis0/1/2 各 size[i]+1 个 f64；再随后 64 位占用位图 | `NativeVoxelGeometry.create` / `createCube` |
| 方块扫描 queryState | int[10] = 40 B | minXYZ=0..2, maxXYZ=3..5, cursorXYZ=6..8, done=9 | `NativeBlockScan`（`query` 段） |
| 方块扫描输出记录 | int[4] = 16 B | x, y, z, descriptorIndex | `NativeBlockScan.coordinate/section` |
| 推挤查询 outputBuffer | int[3 + 2·cap] | [0]=metadataRequired, [1]=pushableCount, [2]=nonPassengerCount, [3..]=ids, [3+cap..]=bodySlots；`nativePushFlags` 独立 int[cap] | `FFMBackend.Context.ensureOutputCapacity` |

`EntityMetadata`（32 B，`alignas(32)`，含 2 位 collisionRule + 7 个 1 位标志）**不进 Java**，属原生内部
结构；Zig 侧可用 `packed struct(u32)` 表达标志位，但仍建议保持 32 B / 32 对齐以维持既有 cache 假设。

### 1.3 语义契约（行为，非布局）

- **返回码**：`0` 成功；`-1` 参数非法；`-2` 查询硬碰撞容量耗尽 / 推挤查询 metadata miss 或容量耗尽；
  `-3` 推挤查询未完成；`-4` `queryEntitiesInBox` 未完成；`-100` 原生异常（随后
  `lastNativeException()` 返回线程局部描述）。`scanCollisionBlocks` 的分页返回是**正常**路径而非错误。
- **遍历顺序**：section 按 x → z → y 嵌套遍历；负 section 坐标在 `visitPackedRange` 里分两段（先 ≥0 升序、
  后负值升序）；段内按插入序，8/4/1 三档尾部处理。
- **分页语义**：方块扫描只发布"已消费"的游标；`capacity` 只分页、绝不截断候选。
- **浮点语义**：禁止收缩（contraction）与 fast-math；`pushImpulse` 的除法/乘法顺序、
  `vy + 0.0` 的符号零、`result - 0.0` 必须逐条保留。
- **线程模型**：所有可变状态在 `CollisionContext` 里（每 level 一个），模块级可变全局仅
  `thread_local char lastError[256]`。这一点决定了 A/B 可以**在同进程同时加载两个库**。

---

## 2. 模块清单

依赖为自底向上；"批次"列见 §6 P2 的移植顺序。

| # | 模块 | 文件 | 行数 | 职责 | 对外符号 | 依赖 | 风险 | 批次 |
|---|---|---|---|---|---|---|---|---|
| 1 | 错误边界 | `src/native_error.{h,cpp}` | 63 | 线程局部错误串、异常→`-100` | `lastNativeException` | — | 低 | 1 |
| 2 | 几何原语 | `src/geometry/aabb.h` | 12 | 6×f64 POD | — | — | 极低 | 1 |
| 3 | 元数据 | `src/state/entity_metadata.h` | 29 | 32 B/32 对齐记录、规则与标志常量 | — | — | 中（布局/位域） | 1 |
| 4 | 空间 SoA | `src/spatial/cell_bounds_soa.h` | 61 | 6 条平行 f64 列、顺序删除 | — | 2 | 低 | 1 |
| 5 | 空间哈希 | `src/spatial/cell_map.h` | 120 | 开放寻址 + 线性探测 + 回移删除 | — | 4 | 中 | 2 |
| 6 | 空间索引 | `src/spatial/spatial_index.{h,cpp}` | 93 | splitmix64 CellHash、`isIndexable`、bounds/queryable 更新 | — | 2,4,3 | 中（哈希、isfinite） | 2 |
| 7 | 上下文与池 | `src/state/collision_context.h` | 52 | level 上下文、CellMembers 稳定池 + 空闲链 | `create/destroyCollisionContext` | 5,4,3 | 中（指针稳定性） | 3 |
| 8 | section 索引 | `src/spatial/section_index.{h,cpp}` | 101 | 插入/删除/迁移、空 section 回收、slot.index 回填 | — | 5,6,7,3 | 中 | 3 |
| 9 | 实体 API | `src/state/{context_api,metadata_api,persistent_index}.cpp` | 210 | 成员增删改、状态/边界/缓存失效、hard 计数 | 7 个成员管理/状态/失效符号 | 7,8,4 | 中（校验分支与计数） | 3 |
| 10 | 查询规则 | `src/query/collision_rules.{h,cpp}` | 54 | section 范围推导（floor→>>4）、队伍位掩码 | — | 2,3 | 中（非对称外扩） | 4 |
| 11 | 查询 API | `src/query/query_api.cpp` | 366 | 三条查询、SIMD 掩码、顺序遍历、状态码 | `queryHardCollisionEntities`/`queryEntitiesInBox`/`queryPushableEntities` | 4,5,8,10,3 | **高** | 4 |
| 12 | 推挤 | `src/motion/{collision_body.h,push_run.cpp}` | 104 | `CollisionBody` 布局、脉冲累加 | `executePushRun` | 2 | 中（FP 顺序） | 5 |
| 13 | 移动求解 | `src/motion/movement_solver.cpp` | 105 | 34-double packet、台阶扫描、结果发布 | `prepareMovement`/`solveMovement` | 1,2,3 | **高** | 5 |
| 14 | 体素几何 | `src/geometry/voxel_geometry.{h,cpp}` | 155 | 变长几何体、tag pointer、`clipVoxel`/`clipMovement` | — | 2 | **高**（FP + 指针技巧） | 5 |
| 15 | 方块扫描 | `src/blocks/block_scan.cpp` | 136 | 8 行批处理、游标分页、行掩码 | `scanCollisionBlocks` | — | 中 | 6 |
| 16 | ABI 门面 | `include/eco/collision_api.h` + `version-script` | 114 | 导出声明与可见性 | 全部 17 个 | 全部 | 冻结，不改 | — |

合计 1775 行。**风险最高的三处**：#11（AVX2 掩码 + 顺序/状态机）、#14（tag pointer + 逐位 FP 比较）、
#13（packet 布局 + 排序去重）。

### 2.1 各模块 Zig 映射要点

| # | 要点 |
|---|---|
| 1 | `threadlocal var last_error: [256]u8`；Zig 无异常，内部函数用 error union，导出包装把 error 名写入缓冲并返回 `-100`。保持"不分配"与"同线程"两条性质。 |
| 3 | 位域 → `packed struct(u32)` 或裸 `u32` + 掩码常量；`comptime` 断言 `@sizeOf == 32`、`@alignOf == 32`。 |
| 4 | 6 × `ArrayListUnmanaged(f64)`；C++ `vector::erase` 保序 ⇒ Zig 用 `orderedRemove`，不可用 `swapRemove`。 |
| 5 | 结构照搬：2 的幂容量、负载因子 `(used+1)*10 >= size*7`、回移删除；`findOrInsertValueSlot` 返回 `*?*CellMembers`（指向槽位的指针）。 |
| 6 | splitmix64 常量和移位照抄（不参与输出顺序，但抄下来省推理）；`std.math.isFinite` 替代 `std::isfinite`。 |
| 7 | C++ 用 `std::deque` 换取指针稳定性；Zig 等价做法是 `allocator.create(CellMembers)` 逐对象分配 + `pool_next: ?*CellMembers` 空闲链，retire 时清空 ids/queryable/bounds 与计数。**不要**用 `ArrayList(CellMembers)`（扩容会让 `CellSlot.members` 悬空）。 |
| 8 | 三条平行数组（ids/queryable/bounds）必须同步；删除后按 `sectionSlots[ids[i]].index = i` 回填。 |
| 9 | 校验分支与返回码逐条对齐；`hardEntityCount` / `hardCount` / `queryableCount` 三处计数增减的时机是 A/B 最容易暴露差异的地方。 |
| 10 | `sectionCoordinate = @floor(v) >> 4`（先 floor 后移位，防 -0.0 下溢）；外扩量 `(-2,-4,-2)` / `(+2,0,+2)` 非对称，逐字抄。 |
| 11 | `@Vector(4, f64)` + `<`/`>`/`&` 替代 `_mm256_cmp_pd`/`_mm256_and_pd`，`@bitCast` 出 `u4`/`u8`，`@ctz` 取 lane；8/4/1 三档尾部与负区间两段遍历按原结构保留。 |
| 12 | `CollisionBody` 用 `extern struct` + `comptime` 断言 80 B 与各偏移；`PUSH_EPSILON = @as(f64, 0.01)` 的 f32 加宽值要写死成同一常量。 |
| 13 | packet 用 `[*]f64` + 下标常量；`std::sort` + `std::unique` ⇒ Zig `std.mem.sort`（对 f32 需显式全序比较，注意 NaN 与 -0.0/+0.0）；`- 0.0` 保号写法保留。 |
| 14 | tag pointer → `@intFromPtr`/`@ptrFromInt` + `@alignCast`；`this + 1` 变长布局 → 头部 `extern struct` + 尾部 `[*]f64` 指针算术。`clipSingleCell` 的 `1e-7` 比较与 `fmin/fmax` 逐条保留。 |
| 15 | `@ctz` 处理行掩码；`0xffffu >> (15 - (maxX & 15))` 与 `0xffffu << (cursor.x & 15)` 的移位边界保持原样；游标发布语义不变。 |
| — | 构建：`zig build -Dtarget=... -Doptimize=ReleaseFast`；严格浮点（Zig 默认不收缩，已实测无 `vfmadd`）；`export fn` 即精确符号名 + 默认可见性。 |

---

## 3. Zig 工程结构（建议）

```text
native/                      # 模组仓库内的位置
  build.zig                  # 六个目标：{windows,linux,macos} × {x86_64,aarch64}
  src-zig/
    root.zig                 # 17 个 export fn（ABI 门面）+ comptime 布局断言
    native_error.zig         # 线程局部错误串
    geometry/{aabb,voxel_geometry}.zig
    spatial/{cell_bounds_soa,cell_map,spatial_index,section_index}.zig
    state/{entity_metadata,collision_context,entity_api}.zig
    query/{collision_rules,query_api}.zig
    motion/{collision_body,push_run,movement_solver}.zig
    blocks/block_scan.zig
```

- 产物文件名与资源路径**不变**（`EntityCollisionOptimizer.dll` / `libEntityCollisionOptimizer.so` /
  `libEntityCollisionOptimizer.dylib`），`native-build.gradle` 的 `prepareNativeResources` 把它们按
  `natives/<平台>/` 整理进 jar，与 Java 侧 `platformNativePath()` 的查找规则一致。
- Zig 版本**锁定**（当前实测 0.16.0），在 CI 与本地用同一版本；pre-1.0 的破坏性改动不允许漂进来。
- 分配器策略需先定（见 §8）：`std.heap.c_allocator` 最贴近现状（`new`/`delete` ↔ `malloc`/`free`），
  自建 arena 则更可控但要重写 `-100` 的触发条件。

---

## 4. A/B 验证方案

### 4.1 先看清既有基建能证明什么

仓库已有三层测试（见 [TESTING.md](../../TESTING.md)），**A/B 应当复用它们，而不是另造 oracle**：

| 层 | 入口 | 现有证据 | 对 A/B 的价值 |
|---|---|---|---|
| 契约/单元 | `gradlew runGameTestUnit -PskipNative` | 32 个 GameTest（`gametest-index.json`，`unit_*`），含 `natives/*Checks` 直接验证 FFM 内存契约 | 换库后原样跑一遍 ⇒ 行为回归网 |
| 跨进程集成 | `vanilla-gametest` 录基线 → `runGameTestIntegration` | 无模组基线与有模组**逐字节**相同的 trace | **最强等价性判据**：C++≡vanilla 且 Zig≡vanilla ⇒ Zig≡C++，无需新 oracle |
| 基准 | `runGameTestBenchmark -Pbenchmark` | MSPT 采样 | 性能 A/B 的现成场地 |

缺口是：这三层都在 Minecraft 进程里，跑得慢、覆盖的是模组使用路径，**够不到 C ABI 的边界输入**
（空指针、非法容量、NaN/±0/次正规、section 坐标极值、分页游标续跑等）。这正是 §4.3 要补的一层。

### 4.2 L0 — 静态契约（秒级，三平台 CI 必备）

1. **符号表 diff**：`llvm-nm --dynamic --defined-only`（Linux）/ `llvm-objdump --macho --exports-trie`（macOS）/
   `llvm-readobj --coff-exports`（Windows）分别导出 C++ 与 Zig 的符号集，要求**集合相等且仅含 17 个导出**。
2. **comptime 布局断言**：Zig 侧对 `CollisionBody`/`VoxelRef`/`CollisionBounds`/`EntityMetadata` 断言
   `@sizeOf` 与 `@offsetOf`，与 C++ 的 `static_assert` 一一对应；不一致直接编译失败。
3. **Java 侧布局断言**：在 `natives` 检查类里加一条测试，把 `CollisionStateTable` 的偏移常量与
   `MemoryLayout` 计算值比对，防止"改了 C++/Zig 忘了改 Java"。
4. **浮点收缩门禁**：对产物反汇编 grep `vfmadd`/`vfmsub`，出现即失败（约束见 §1.3）。

### 4.3 L1 — 单进程双后端差分 harness（核心新增）

因为原生侧没有模块级可变全局（只有 thread_local 错误串），**两个库可以在同一个 JVM 里同时加载、
各自建 context，互不干扰**。

- **形态**：纯 JDK 工程（不依赖 Minecraft），`SymbolLookup.libraryLookup(<绝对路径>)` 加载两个产物，
  用同一个接口包装 17 个导出，逐调用比对。适合放进 `src/gametest/java/.../natives/` 之外的独立
  source set 或独立 Gradle 子工程，任何 JDK 21+ 环境可跑。
- **比对口径**：返回码；输出数组（长度与每个元素）；被写内存的**原始字节**——
  `CollisionBody` 80 B 行、movement packet 272 B、输出缓冲分页区，double 用
  `Double.doubleToRawLongBits` 比较（不是 `==`，-0.0/NaN 必须逐位一致）。
- **驱动器**：
  - 确定性脚本：固定种子，随机 `insert/updateState/updateBounds/updateSection/remove/invalidate` 序列，
    每步后跑三条查询，比对返回码与输出；
  - 边界值矩阵：`NaN`、`±Inf`、`±0.0`、次正规数、恰好 `±1e-7`、`min==max`、非有限 bounds、
    section 坐标 `INT32_MIN/MAX` 附近、`x & 15 == 0/15`、空 section、单实体、跨 section 迁移；
  - 各导出独立用例：`executePushRun`（随机 bodies + slots，比整块内存）、`prepareMovement/solveMovement`（随机
    geometry 批 + packet）、`scanCollisionBlocks`（多轮分页直到 `done`，比记录序列与游标）。
- **规模**：每模块 ≥ 10^5 步随机操作 + 全量边界矩阵；不一致时打印最小复现序列（shrink）。
- **自校验**：先用**同一份 C++ 源码**分别用 clang（现有工具链）与 `zig c++` 编译成两个库跑一遍，
  必须零差异——否则说明 harness 自身有假阳性（例如未初始化内存被纳入比对）。

### 4.4 L2 — 复用 GameTest 三层

- `runGameTestUnit`（32 例）在 C++ 后端与 Zig 后端下都必须全绿；
- `runGameTestIntegration` 的 trace 在两种后端下都必须与 vanilla 基线**逐字节**一致；
- 一次跑两个后端的落地方式：由新的 Gradle 属性选择打包哪一个库（见 §5），CI 里对同一编译产物跑两遍。

### 4.5 L3 — 性能 A/B

- **微基准**：在 L1 的 harness 里对热路径计时——`queryPushable`（1k/5k 实体、不同 cell 密度）、
  `executePushRun`、`solveMovement`、`scanCollisionBlocks`；C++ 与 Zig 交替测、取中位数。
- **整机**：`runGameTestBenchmark -Pbenchmark` 两种后端各跑一次，比 MSPT 分布。
- **门槛（建议，可调）**：查询/推挤/移动的 Zig 中位数不劣于 C++ **3%**，方块扫描不劣于 **5%**；
  且两者都不得劣于 vanilla 基线。基准只作回归门禁，不作正确性判据（与 TESTING.md 的既有立场一致）。

### 4.6 L4 — 平台矩阵与 CI

| 平台 | L0 符号/布局 | L1 差分 | L2 契约/集成 | L3 基准 |
|---|---|---|---|---|
| windows-x64 | ✅ | ✅ | ✅ | ✅ |
| linux-x64 | ✅ | ✅ | ✅ | 可选 |
| macos-x64 | ✅ | ✅ | 可选（有 runner 时） | 可选 |
| aarch64（若启用） | ✅（仅编译+符号） | ❌ | ❌ | ❌ |

L0/L1 不需要 Minecraft，可在任意 runner 上秒级跑完，是换语言期间的主力门禁；L2/L3 只在有完整
运行环境时跑。

### 4.7 判定标准汇总

| 级别 | 通过条件 |
|---|---|
| L0 | 17 个符号集合相等；布局断言全过；反汇编无 FMA |
| L1 | 每模块 ≥10^5 步随机差分 + 边界矩阵零分歧；**double 逐位一致** |
| L2 | 32 个 unit GameTest 全绿；集成 trace 与基线逐字节一致 |
| L3 | 性能门槛达标（建议 3%/5%） |
| 发布 | 三平台 L0+L1+L2 全过；Zig 后端默认前先随一个版本双后端并行观察 |

---

## 5. 切换与回退

1. **切换方式**：原计划的双后端开关没有实现，改成一次性切换——`native-build.gradle` 是唯一的原生构建路径，
   构建产物只含 Zig 库。理由：Zig 库已在 L0/L1 上与 C++ 基线逐字节对齐（§8），双后端的额外复杂度换不来
   相应的信息量；真要并行观察，用 `git revert` 出一个 C++ 分支更简单。
2. **回退**：C++ 源码已从工作树删除，但仍完整留在 git 历史里（删除前是提交 `90e5208`）。
   回退 = `git revert` 本次提交，或从历史里取回 `native/{src,include,CMakeLists.txt,version-script}` 与
   `cpp-build.gradle`。回退后需要重新带上 AcceleratedRecoiling 工具链依赖。
3. **对照基线**：差分验证需要一份 C++ 库时，不必恢复整个构建——按 §4 的方法用 `zig c++` 编一份即可。

---

## 6. 分阶段执行计划

| 阶段 | 内容 | 产物 | 退出条件 |
|---|---|---|---|
| **P0** | 只换构建：用 `zig c++` 编现有 C++（零源码改动） | 三平台库 + `cpp-build.gradle` 的 Zig 分支 | L0 符号一致；32 unit GameTest 全绿；集成 trace 逐字节一致 |
| **P1** | L0/L1 harness 落地 | 符号 diff 脚本、comptime 断言、差分 harness | 同源两次编译（clang vs zig cc）零差异（harness 自证） |
| **P2** | 按批次移植（§2 批次列：1→2→3→4→5→6→7）| `native-zig/src/**` | 每批次完成即过 L1 对应用例，L2 保持全绿 |
| **P3** | 切换默认后端（改为一次性切换，见 §5） | `native-build.gradle` + Zig 产物进 jar | L0/L1 对齐、32 个 unit GameTest 全绿 |
| **P4** | 删除 C++ 源码与第三方工具链依赖 | 删除 `native/{src,include,CMakeLists.txt,version-script}`、`cpp-build.gradle`、`native/prebuilt` | 构建与 CI 都不再接触 C++ 工具链 |

P0 之所以能独立成立：实测 `zig c++` 在 Windows 上直接编出三平台库、符号与导入表都正确，
**不需要下载 AcceleratedRecoiling 工具链**（详见对话记录与本目录验证脚本）。

---

## 7. 风险登记

| 风险 | 影响 | 缓解 |
|---|---|---|
| 浮点结果不一致（顺序/收缩/fmin-fmax） | 与 vanilla 行为分叉 | 严格浮点模式；L1 逐位比对；反汇编门禁；`-ffp-contract=off` 语义对齐 |
| `EntityMetadata` 位域/对齐 | 内部性能假设被破坏 | comptime 断言 32 B/32 对齐；标志用掩码常量 |
| `CellMembers` 指针稳定性 | 悬空指针 → 崩溃/错乱 | 逐对象分配 + 空闲链，禁用 `ArrayList` 承载 |
| `std::sort` 与 Zig 排序对等元素/NaN 行为不同 | 台阶扫描结果差异 | f32 用显式全序比较；L1 用含 NaN/±0 的 geometry 用例覆盖 |
| Zig pre-1.0 破坏性改动 | 构建随时可能坏 | 锁版本；CI 固定下载;升级单独提交 |
| MinGW DLL vs MSVC DLL | 与 MSVC 产物混用时 ABI 不同 | 该库只被 JVM `dlopen`，已核实仅依赖 UCRT/KERNEL32 |
| LLVM 版本差异导致指令选择不同 | 理论存在 | 语义由 L1 逐位比对兜住；性能由 L3 看住 |
| 两份源码手工同步（`native/` 与 `eco-native/`） | 改错边 | 已消除：C++ 版删除，Zig 版并入 `native/src-zig`；`eco-native/` 只剩未并入仓库前的副本 |

---

## 8. 已定决策与实施记录

### 决策（2026-09-30）

| 项 | 决定 |
| --- | --- |
| 主源码 | 在 `eco-native/` 里实现；`EntityCollisionOptimizer/native/` 仅作参考与差分基线 |
| 分配器 | `std.heap.c_allocator`（对应 C++ `new`/`delete`） |
| CPU 基线 | ~~去掉 AVX2 硬要求，按各架构基线编译~~ → **x64 要求 AVX2（x86-64-v3）**，aarch64 用基线 NEON；向量用 `@Vector(4, f64)` 表达。见下方「CPU 基线反转」 |
| 目标平台 | windows/linux × x64/aarch64；**暂不支持 macOS** |
| 过渡方式 | 暂不合并进模组构建，先在 eco-native 内验证 |

#### CPU 基线反转（2026-10-04）

初版按各架构**基线**编译（x64 落到 SSE2），当时的依据只是「能编译、不要求 AVX2」，
**没有测代价**。补齐测量后反转为要求 AVX2：

| 每 section 实体数 | 基线(SSE2) | x86-64-v3(AVX2) | 收益 |
| --- | --- | --- | --- |
| 8 | 2.40 | 2.03 | **1.18x** |
| 64 | 5.96 | 4.94 | **1.21x** |
| 512 | 39.04 | 31.99 | **1.22x** |
| 4096 | 598.44 | 556.04 | 1.08x |

单位 ticks/query，取 5 轮最优；两版本 checksum 逐密度一致（比的是同一份工作量）。
`x86_64_v2`（SSE4.2+popcnt）实测与基线**无差异**（1.001x）——收益全部来自 256 位向量。

代价与依据：JDK 25 在 x64 上的最低要求其实只有 SSE2（HotSpot `vm_version_x86.cpp`：
`if (!VM_Version::supports_sse2()) vm_exit_during_initialization(...)`），因此要求 AVX2
会造出「JVM 能起、本库崩」的组合（2013 年前的 Nehalem 等）。这是**有意接受**的取舍，
且与 C++ 原版同级（原版 `-march=x86-64-v2 -mavx2`，同样要求 AVX2）。
未选运行时 CPUID 分派：需两份产物 + 加载器改造，成本超出收益。

`x86_64_v3` 含 FMA3，而 FMA 会改变浮点结果，故改后逐项复验：导出体内 FMA = 0、
差分 4 种子仍逐字节一致、aarch64 产物 SHA256 未变。

#### Zig vs C++ 性能实测（2026-10-04）

两版同 ABI、同 17 导出的库在同一进程内交替调用，负载取自 `tests/DifferentialHarness.java` 的四个场景。
公平性处理：C++ 侧按 `CMakeLists.txt` 的 Release 分支重建（`-O3` + `-mavx2 -msse4.2 -mpopcnt`），
不用早先那个 `-O2` 无优化的参考库；Zig 侧即当前 `x86_64_v3` 产物。

| 场景 | cpp/zig 中位 | p25 | p75 | 结论 |
| --- | --- | --- | --- | --- |
| entities（512 实体 + 900 变更 + 400 轮×3 查询） | 1.050 | 1.041 | 1.143 | Zig 快 5% |
| pushRun（2000 轮 × 96 body） | 1.047 | 0.936 | 1.218 | 持平，离散大 |
| movement（20000 轮 × 2 阶段） | 1.100 | 1.017 | 1.181 | Zig 快 10% |
| blockScan（600 轮 × 分页） | 1.059 | 1.025 | 1.089 | Zig 快 6% |

比值 >1 表示 Zig 更快。方法：A/B 顺序交替、各起 5 个独立进程、每进程内配对取比值，再对 10 个比值取中位数 ——
进程间系统偏差达 30%，只跑单进程会得出方向相反的结论（早期单进程结果从 0.62x 飘到 1.23x，已作废）。

**成因**：Zig 把整个库作为单一编译单元，跨模块内联天然发生；C++ 需要显式 `-flto` 才能等价。
Zig 产物 137 KB vs C++ 499 KB（C++ 静态链入 libc++），且 Zig 无 C++ 那套 RTTI/异常表开销。

> **可信度**：本机为 i5-12500H，单机、单负载形态，**不能外推到其他机器或其他访问模式**。
> 结论只支持「Zig 移植未引入性能回归」，不足以宣称普遍更快。

### 实施记录

| 阶段 | 状态 | 证据 |
| --- | --- | --- |
| P0 构建切换 | 完成 | `zig c++` 编现有 C++ 可产出三平台库；Zig 自身构建 4 目标 65 秒 |
| P1 差分 harness | 完成 | `eco-native/tests/DifferentialHarness.java`（纯 JDK，FFM 双库同进程） |
| P2 模块移植 | 完成 | `eco-native/src-zig/**`，15 个模块，与 C++ 目录一一对应 |
| P3 并入模组构建 | 完成（2026-10-05） | `native-build.gradle` 的 `zigBuildNative`/`prepareNativeResources`，jar 内 `natives/` 五个平台全部来自 Zig |
| P4 清理 C++ 与工具链 | 完成（2026-10-05） | `cpp-build.gradle` 与 `native/{src,include,CMakeLists.txt,version-script,prebuilt}` 已删除；CI 由 MSVC 改为装 Zig |
| 交接门禁 | 完成（2026-10-05） | 六平台导出符号 17/17、导出体内 FMA=0（`tools/verify-native.ps1`）；windows-x64 与 C++ 基线差分 4 个种子逐字节一致、硬化探针 11 项全过（`tools/differential-check.ps1`）；`runGameTestUnit` 32 例全绿 |

### 验证结果

| 级别 | 结果 |
| --- | --- |
| 导出符号 | 四目标各 **17/17**；linux 动态符号总数**恰为 17**（无符号泄漏） |
| 布局断言 | `root.zig` 的 comptime 断言与 C++ `static_assert` 一一对应，编译期校验 |
| CPU 基线 | x64 目标按 **x86-64-v3** 编译（`vcmpltpd`=54、`ymm` 引用 1114~1235、SSE `cmpltpd`=0）→ **要求 AVX2**；aarch64 不指定 cpu（NEON 属基线，`fcmgt`=108） |
| 浮点收缩 | **导出函数体内 FMA = 0**（四平台，含 AVX2 的 x64）→ 未发生收缩；`x86_64_v3` 虽含 FMA3，Zig 严格浮点模式仍不生成融合乘加（等价于 C++ 的 `-ffp-contract=off`）。口径必须按导出函数体地址区间统计：windows-arm64 尾部另有 7 条 `fmadd/fmsub`，位于末个导出起点 `0xB62C` 之后的运行时数学例程内（`fsqrt`+多项式修正），不在 FPI 路径上，全文计数会误报 |
| **差分（L1）** | **transcript 逐字节一致**：4 个种子（0/1/12345/987654321），每个约 1.1 MB，覆盖实体索引与三类查询、推挤、移动求解（含 cube/单格/网格/空形状与平移引用）、方块扫描分页 |
| harness 自检 | 同一份 C++ 用 `-O2` 与 `-O3` 各编一次 → 逐字节一致（排除假阳性） |
| 硬化回归 | `tests/HardeningProbe.java` 11 项断言全过；同一探针让 C++ 参考库崩溃，确证分歧方向正确 |
| 发布产物 | Release 已开启 `strip`（对应 C++ 的 `-s`）：linux 356,712 → **56,144**、arm64 332,920 → **49,328**、windows-x64 244,736 → **128,512**、windows-arm64 216,064 → **57,344**；不再产出 PDB。strip 后导出符号与差分回归均未变化 |
| 构建系统缺口 | `zig build` **无 `compile_commands.json` 支持**（Zig 0.16 标准库 0 命中）；**Windows 无法收紧导出表**（`export_symbol_names` 仅 WASM 生效、`.def` 被 `export fn` 的 dllexport 压制），多出的仅是 CRT 固有的 `_DllMainCRTStartup`；**无公开的任意链接参数入口**（`-Wl,--icf=all` 等无法直接搬）。三者均不影响 ABI，必要时各自有绕过手段 |

### 上游缺陷与 Zig 侧修复（唯一的有意分歧）

**缺陷**：`updateCollisionEntitySection` 作用在**已退役但 ID 仍存在**的实体上时——即
`sectionSlots[id].members` 为空——`updateSectionEntity`（`section_index.cpp:67`）直接解引用它，
空指针崩溃。`spatial/section_index.zig` 原本为保持可比而镜像了该行为。

**可及性**：Java 侧 `PersistentEntityIds.getNativeId()` 对正常移除的实体会因
`removeInt` 返回 `-1`，`LevelCollisionFrame.updateSection` 的守卫因此能拦住这条路。但
`LevelCollisionFrame.addEntity` 是**先登记 ID 映射、再调用原生插入**：一旦原生插入失败
（返回 `-1`，随后被 `FFMBackend.checkStatus` 转成异常），映射不会回滚，该 ID 就停在
"有映射、无成员槽"的状态上，后续 `sectionChanged` 回调即可命中崩溃。属防御纵深缺口而非当前线上必现。

**Zig 侧修复**：成员槽为空（或槽内下标越界）时视为"无需搬迁索引"，只同步元数据坐标并返回 `0`。
对非成员而言这些坐标是惰性的——下一次 `insertCollisionEntity` 会按入参覆盖。
越界 ID / 负 ID 仍按非法参数返回 `-1`，行为不变。

**这是 Zig 与 C++ 参考实现之间唯一已知的有意分歧**，因此该调用组合不进差分语料，
改由 `eco-native/tests/HardeningProbe.java` 单独回归。

| 验证 | 结果 |
| --- | --- |
| 对 C++ 参考库跑探针 | 进程在触发点崩溃（exit≠0）→ 证明缺陷真实 |
| 对 Zig 库跑探针 | 11 项断言全过，含"退役 ID 的 section 更新安全返回 0"、"新 section 不出现幽灵成员"、"退役 ID 复用后可重新查询" |
| 差分回归 | 4 个种子仍逐字节一致 → 修复未影响正常路径 |

**C++ 侧未修**：`EntityCollisionOptimizer/native/` 属参考副本，本次未改动。若要修，应同样改为
"非成员不搬迁"，并同步 `eco-native/src/` 与上游。
