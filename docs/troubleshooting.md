# 故障排查（NeoForge 26.1.2 移植分支）

本文件只记录 `neoforge/26.1.2` 分支特有的环境、构建与运行坑。上游 Fabric 流程见
[RELEASE.md](../RELEASE.md) 与 [TESTING.md](../TESTING.md)。

## 原生库

### artifact 名称里的分支斜杠

症状：CI 前面全绿，最后一步归档失败：

```text
##[error]The artifact name is not valid: EntityCollisionOptimizer-neoforge/26.1.2-build-1.
Contains the following character: Forward slash /
```

原因：[build.yml](../.github/workflows/build.yml) 的 artifact 名用了 `github.ref_name`，而
`actions/upload-artifact` 不允许名称里出现 `/ \ : * ? " < > |`。上游分支名（`26.1`、`main`）
没有斜杠，所以只有本地的 `neoforge/26.1.2` 这类分支名会踩到。修法：归档前把 ref 名里不允许的
字符替换成短横线。

### 原生库由 Zig 构建，需要 Zig 0.16.0

[native-build.gradle](../native-build.gradle) 的 `zigBuildNative` 任务直接调用 `zig build`，一次编出
windows/linux/macos × x64/arm64 六个目标，不再需要 MSVC、CMake，也不再下载 AcceleratedRecoiling
交叉编译工具链。

症状：构建报 `找不到 zig 可执行文件。请安装 Zig 0.16.0 并确保它在 PATH 上`。
原因：`PATH` 里没有 `zig`。修法：装 Zig 0.16.0，或用 `-PzigExecutable=<zig 可执行文件路径>` 指定。
版本不能将就：`build.zig` 与 `src-zig` 都按 0.16 的 API 写，0.15 / 0.17 会编译不过。

CI 上装 Zig 用 `mlugg/setup-zig@v2`（`version: 0.16.0`），不自己写下载脚本。曾用一段自建的
PowerShell 下载脚本，遇到 ziglang.org 请求挂住时会**静默卡死**：步骤 12 分钟无任何输出，最后被人工取消。
自建脚本没有超时也没有重试，而 action 两者都带，还支持镜像回退。

Zig 的构建缓存被 `native-build.gradle` 固定到 `build/zig-cache/`（`--cache-dir` / `--global-cache-dir`），
`TEMP`/`TMP` 也被改指 `build/zig-tmp/`。zig 默认写用户级缓存，子编译（交叉编译 mingw-w64 的
`libmingw32.lib` 等）还会在 `TEMP` 下建临时文件；受限环境里这两处都可能不可写，固定到工作区内
就与外部环境无关，手工执行 `zig build` 时照抄这四组参数。

症状：构建报

```text
error: sub-compilation of mingw-w64 libmingw32.lib failed
    ...\libc\mingw\misc\mingw_longjmp.S:1:1: note: clang exited with code 1
error: error(compilation): clang failed with stderr: zig: error: unable to make temporary file: Permission denied
```

原因：`TEMP` 指向不可写（或不存在）的目录。报错完全没提 `TEMP`，容易误判成 mingw 汇编器坏了。

手工构建：

```powershell
cd native
zig build --prefix ../build/zig-native --cache-dir ../build/zig-cache/local --global-cache-dir ../build/zig-cache/global -Doptimize=ReleaseFast
```

产物落在 `build/zig-native/<平台>/`，再由 `prepareNativeResources` 整理成 `natives/<平台>/<库名>`。
`-Doptimize=Debug` 保留符号表便于调试；Release 会 strip，导出表不受影响。`-PskipNative` 只编译 Java。

x64 目标统一按 x86-64-v3 编译（`@Vector(4, f64)` 落到 256 位 AVX2），因此要求 CPU 支持 AVX2；
aarch64 不额外指定 cpu。浮点保持严格模式，产物里不应出现 FMA——口径见
[design/eco-native-zig-port.md](design/eco-native-zig-port.md)。

C++ 原版已从本分支删除，只留在 git 历史里（`git show <旧提交>:native/src/...`）。
差分验证需要一份 C++ 基线时，按设计文档「差分验证」一节用 `zig c++` 重新编一份即可。

### native access 警告

症状：启动时出现

```text
WARNING: Use --enable-native-access=entity_collision_optimizer to avoid a warning for callers in this module
```

原因：FML 把每个 mod 作为 JPMS 模块放进子 ModuleLayer，boot 层的
`--enable-native-access`（MDG 已经传了 `ALL-UNNAMED`）对子层模块不生效。
[native-build.gradle](../native-build.gradle) 之外的运行参数在 [build.gradle](../build.gradle) 的
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

`gradle.properties` 里 `org.gradle.configuration-cache=false`：`native-build.gradle` 在配置期读取
项目属性（`skipNative` / `zigExecutable`），暂不支持配置缓存。

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
