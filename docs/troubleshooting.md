# 故障排查（NeoForge 26.1.2 移植分支）

本文件只记录 `neoforge/26.1.2` 分支特有的环境、构建与运行坑。上游 Fabric 流程见
[RELEASE.md](../RELEASE.md) 与 [TESTING.md](../TESTING.md)。

## 原生库

### 交叉编译工具链下载卡住

症状：`./gradlew build` 停在配置阶段，控制台停在

```text
> Building task graph of root build > Resolve files of configuration ':cppToolchain' > AcceleratedRecoiling-third-party
```

`native/env/` 始终不出现，`~/.gradle/caches/modules-2/files-2.1` 下也没有 `com.wiyuka.env`。

原因：[cpp-build.gradle](../cpp-build.gradle) 会从 AcceleratedRecoiling 的 GitHub Release 拉取
交叉编译工具链 zip（编译器与 sysroot），该资源在本机下载停滞。

绕法（本机验证可用）：用本机 mingw-w64 编译同一份 C++ 源码——native 层与 Minecraft 版本无关，
导出符号与 ABI 必须保持一致：

```powershell
# 在 native/ 目录执行
g++ -std=c++20 -O3 -DAR_WINDOWS -DAR_X64 -mavx2 -march=x86-64-v2 -ffp-contract=off -fno-rtti `
    -shared -static-libgcc -static-libstdc++ -Isrc -Iinclude `
    -o prebuilt/natives/windows-x64/EntityCollisionOptimizer.dll `
    src/native_error.cpp src/state/context_api.cpp src/state/metadata_api.cpp src/state/persistent_index.cpp `
    src/spatial/spatial_index.cpp src/spatial/section_index.cpp src/query/collision_rules.cpp src/query/query_api.cpp `
    src/motion/push_run.cpp src/motion/movement_solver.cpp src/geometry/voxel_geometry.cpp src/blocks/block_scan.cpp
```

只要 `native/prebuilt/natives/<平台>/<库名>` 存在，构建就直接把它当作 native 资源根目录，
不再触碰工具链；也可以用 `-PnativePrebuiltDir=<目录>` 指向别处，或 `-PskipNative` 只编译 Java。

注意：`native/prebuilt/` 只是本地开发产物，已被 `.gitignore` 覆盖（`/native/*` 除白名单外全部忽略），
发布仍应走官方工具链：`./gradlew prepareNativeResources`。

### native access 警告

症状：启动时出现

```text
WARNING: Use --enable-native-access=entity_collision_optimizer to avoid a warning for callers in this module
```

原因：FML 把每个 mod 作为 JPMS 模块放进子 ModuleLayer，boot 层的
`--enable-native-access`（MDG 已经传了 `ALL-UNNAMED`）对子层模块不生效。
[cpp-build.gradle](../cpp-build.gradle) 之外的运行参数在 [build.gradle](../build.gradle) 的
`neoForge.runs.configureEach` 里追加，仍保留了一条按 mod id 的参数备用。

结论：Java 25 允许该调用，只是警告，模组继续工作；把它写进服务器的 JVM 参数即可消除。

## Mixin 与字节码改写

### FML service does not currently support retrieval of untransformed bytecode

症状：服务器启动直接 FATAL，日志里是

```text
Mixin apply for mod entity_collision_optimizer failed entity_collision_optimizer.mixins.json:BodyFieldConsumersMixin
Caused by: java.lang.IllegalArgumentException: FML service does not currently support retrieval of untransformed bytecode
    at net.neoforged.fml.loading.mixin.FMLClassBytecodeProvider.getClassNode(...)
    at org.edtp.entitycollisionoptimizer.collision.bytecode.BodyFieldAccess.isEntity(BodyFieldAccess.java:...)
```

原因：`BodyFieldAccess` 原先用 `MixinService.getService().getBytecodeProvider().getClassNode()`
沿父类链判断字段归属。Fabric 的 mixin 服务支持取未变换字节码，FML 的实现不支持。

修法：改为只读 class 资源的 `superName` 链（ASM `ClassReader`），并沿链缓存结果；先处理两条
可立即判定的路径（字段声明类 `Entity` 本身、当前被变换的类自身且未自行声明同名字段），其余才走链。
**不要**改用 `Class.forName`：那会在 mixin 变换期间提前加载目标类，副作用不可控。

验证：启动日志里不应出现 `Cannot resolve the class hierarchy of ...`。26.1.2 上已知会走到父类链的
两处是 `Guardian$GuardianAttackGoal` 里的 `Guardian.needsSync` 与 `ProjectileDeflection` 里的
`Projectile.needsSync`。

### 少重写是静默失败

`needsSync`/`noPhysics` 没有被改写成 `CollisionBodyAccess` 访问器时不会报错，只会读到已经过期
的 Java 字段（body 表里才是当前值），表现为难以复现的碰撞行为偏差。因此 `BodyFieldAccess` 在无法
判定归属时留下 WARN 日志，`src/gametest` 里的 `BodyFieldConsumerCoverage` 已在契约套件的
`unit_shared_body_state_parity` 里跑起来，负责完整审计声明的消费者清单。

## GameTest

### 测试源集不会被自动发现

Fabric 靠 `fabric.mod.json` 的 `fabric-gametest` 入口点主动加载测试类；NeoForge 26.x 没有这个机制，
GameTest 是数据驱动的（`TEST_FUNCTION` + `TEST_INSTANCE` 两个注册表）。因此每个套件都有一份
**索引资源**（`entity_collision_optimizer/gametest-index.json` 等）列出"跑哪些方法"，
主源集的 `gametest.harness.GameTestRegistration` 在 mod 构造期按名字反射注册。

删掉索引里的一行 = 那个用例静默消失。索引与方法上的 `@GameTestSpec` 不一致时启动即抛异常，
这是刻意的：宁可起不来，也不要少跑一个契约。

### 测试源集的依赖要自己挂

MDG 只把 Minecraft/NeoForge 依赖加到 `sourceSets.main`。`gametest` / `unitTest` /
`integrationTestShared` / `integrationTest` 这些源集必须各调一次
`neoForge.addModdingDependenciesTo(sourceSets.<名字>)`，否则报
`package net.minecraft.world.level.block.state does not exist`。

测试类要读主模组内部状态，所以再加一条 `<name>CompileOnly sourceSets.main.output`——用
`compileOnly` 而不是 `implementation`，因为开发运行时主模组的类是同一个类加载器提供的，
打进测试源集只会制造重复类。

### Identifier 不允许驼峰

测试实例 id 取自方法名，而 `Identifier` 路径只允许 `[a-z0-9/._-]`。`GameTestRegistration`
把方法名转成 snake_case 并加套件前缀（`unit_` / `integration_` / `benchmark_`），
于是 `--tests entity_collision_optimizer:unit_*` 能按套件选择。

### 同一批测试是并发跑的

NeoForge 会把同一批测试并发放到共享世界里跑，每个实例一个独立的静态状态副本。上游 Fabric 侧
`IntegrationSequence` 用一个全局布尔表示"某个场景跑完了"，在 NeoForge 下第二个场景永远读到
`false`，只能等到超时（日志里是 `Didn't succeed or fail within N ticks`）。已改成按场景名记账。

同一原因导致 `unit_entity_section_query_contract` 偶发失败：它的固定装置放在主世界低位坐标，
参考查询偶尔会看到别的实例放在附近的实体。重跑即可通过，属测试隔离问题而非等价性失败。

### vanilla 对照子工程

`vanilla-gametest/` 是独立的 ModDevGradle 构建（有自己的 `settings.gradle`，用
`gradlew -p vanilla-gametest ...` 调用），它必须真的没有优化器：

- 它自己编译一份 `gametest.harness` 源码。**不要**改成引用主工程的 `build/classes/java/main`：
  那两个类会被系统类加载器先加载，而 `DeferredRegister` 在 NeoForge 的 `TRANSFORMER` 加载器里，
  两边对不上会抛 `LinkageError: loader constraint violation`。
- 主工程的 `src/main/java` 虽然整目录加入，但 `compileJava` 显式排除了 `collision/`、
  `natives/`、`mixin/`、`commands/`、`@Mod` 类与事件类。
- 主工程的 `src/main/resources` 不参与运行期资源：它的 `entity_collision_optimizer.mixins.json`
  会把优化器的 mixin 插件拉起来。

### 注册表未引导（Not bootstrapped）

症状：vanilla 对照进程启动即 FATAL

```text
java.lang.IllegalArgumentException: Not bootstrapped (called from registry minecraft:game_event)
    at net.minecraft.core.registries.BuiltInRegistries.<clinit>(BuiltInRegistries.java:176)
```

`GameTestMainUtil` 的顺序是 `ServerModLoader.load()` → 各 mod 构造 → `Bootstrap.bootStrap()`。
主工程里 NeoForge 自己会在构造期间触发引导，但只加载测试入口的对照工程里，
`BuiltInRegistries` 可能先被这条注册链路拉起来。`GameTestRegistration.createFunctionRegister()`
因此显式先调 `Bootstrap.bootStrap()`（已引导时是空操作）。

## 构建

### Gradle Wrapper 首次下载慢

wrapper 指向 Gradle 9.5.1，首次运行要从 services.gradle.org 拉约 130 MB。本机曾出现下载停滞
（`gradle-9.5.1-bin.zip.part` 长期为 0 字节），重新执行一次即可；本机也已装有 9.5.0，可直接用
`C:\Users\<用户>\.gradle\wrapper\dists\gradle-9.5.0-bin\<hash>\gradle-9.5.0\bin\gradle.bat` 绕过。

### 配置缓存

`gradle.properties` 里 `org.gradle.configuration-cache=false`：`cpp-build.gradle` 在配置期读取
项目属性，暂不支持配置缓存。

## Fabric → NeoForge 的差异清单

| 项目 | Fabric（上游） | 本分支（NeoForge） |
| --- | --- | --- |
| 构建插件 | Fabric Loom | ModDevGradle 2.0.146 |
| 模组元数据 | `src/main/resources/fabric.mod.json` | `src/main/templates/META-INF/neoforge.mods.toml` |
| 入口点 | `ModInitializer` | `@Mod` 构造器 |
| 命令注册 | `CommandRegistrationCallback` | `RegisterCommandsEvent` |
| 服务器停止清理 | `ServerLifecycleEvents.SERVER_STOPPING` | `ServerStoppingEvent` |
| 每 tick 碰撞帧 | `ServerLevelMixin` 注入 `tick` | `LevelTickEvent.Pre/Post` |
| 切换游戏模式失效 | `ServerPlayerMixin` 注入 `setGameMode` | `PlayerEvent.PlayerChangeGameModeEvent` |
| 字段消费者清单 | 含 `carpet.script.*`、`mod.fuji.*` | 已删除（NeoForge 无这两个模组） |
| 单元/集成/压测套件 | `runGameTest -PunitTest/-PintegrationTest/-Pbenchmark` | 三套均已移植：`runGameTestUnit` / `runGameTestIntegration` / `runGameTestBenchmark`，见 [TESTING.md](../TESTING.md) |
| 测试类发现 | `fabric-gametest` 入口点自动加载 | 数据驱动 GameTest + 每套一份索引资源，见下节 |
| 每 tick 服务器事件 | `ServerTickEvents.START/END_SERVER_TICK` | `ServerTickEvent.Pre/Post` |
