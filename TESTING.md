# Test suites

The project keeps correctness contracts, cross-process integration scenarios, and performance
benchmarks separate. Each Gradle invocation enables exactly one suite.

## Status on this NeoForge branch

All three layers are ported. The suites load Entity Collision Optimizer through NeoForge's
data-driven Game Test system (`runGameTestServer`), not through the Fabric Game Test API.

| Layer | Entry point | Evidence produced |
| --- | --- | --- |
| Native ABI | `pwsh tools/verify-native.ps1 -Library build/zig-native` | 17/17 exported symbols and zero floating-point contraction per platform |
| Contract/unit | `gradlew runGameTestUnit` | 32 focused algorithm, native-memory and interaction contracts |
| Cross-process integration | `gradlew -p vanilla-gametest runGameTestServer` then `gradlew runGameTestIntegration` | Byte-for-byte identical entity traces with and without the optimizer |
| Benchmarks | `gradlew runGameTestBenchmark -Pbenchmark` | MSPT samples; validates the fixture only |

That combination is what proves behavioural equivalence: same candidates, same order, same
publication points.

## Commands

```powershell
# Contract/unit suite (32 tests).
.\gradlew.bat runGameTestUnit -PskipNative

# Cross-process integration suite.
#   1. record the vanilla baseline (no optimizer on the classpath at all)
.\gradlew.bat -p vanilla-gametest runGameTestServer
#   2. require the optimizer to reproduce every byte
.\gradlew.bat runGameTestIntegration -PskipNative

# Benchmarks (numbers only when -Pbenchmark is present).
.\gradlew.bat runGameTestBenchmark -PskipNative -Pbenchmark

# Everything registered, no selection filter.
.\gradlew.bat runGameTestServer -PskipNative
```

`runGameTestServer` accepts an extra selection with `-PgametestArgs='--tests <selector>'`, for
example `-PgametestArgs='--tests entity_collision_optimizer:unit_block_shape_parity'`. Trace
files for the integration layer default to `build/gametest-traces` and can be moved with
`-PintegrationTraceDir=<absolute path>`.

A healthy development start logs:

```text
Extracted FFM native library /natives/windows-x64/EntityCollisionOptimizer.dll to ...
FFM collision backend initialized
Registered 32 game test functions from entity_collision_optimizer/gametest-index.json
Done (0.454s)! For help, type "help"
```

and contains no `Mixin apply ... failed` line. A broken collision-field rewrite either fails the
launch or logs `Cannot resolve the class hierarchy of ...`, in which case the corresponding
`needsSync`/`noPhysics` access stays on the stale Java field — see
[docs/troubleshooting.md](docs/troubleshooting.md).

## Porting map

| Fabric layer | NeoForge equivalent |
| --- | --- |
| `net.fabricmc.fabric.api.gametest.v1.GameTest` + the `fabric-gametest` entrypoint in `fabric.mod.json` | `@GameTestSpec` + a per-suite index resource, registered as vanilla test instances by `org.edtp.entitycollisionoptimizer.gametest.harness.GameTestRegistration` |
| Test mod metadata (`src/unitTest/resources/fabric.mod.json`, `src/benchmarkTest/...`, `src/integrationTest/...`) | the test source sets are declared in the same `neoForge.mods` block as `main`, so they share the one `neoforge.mods.toml` |
| `vanilla-gametest` Loom subproject (records traces without the mod) | `vanilla-gametest/`, an independent ModDevGradle build with no optimizer on its classpath |
| `FabricLoader.getInstance().isModLoaded(...)` | `ModList.get().isLoaded(...)` (the Fabric-only carpet/Fuji consumer targets were dropped) |
| `ServerTickEvents.START/END_SERVER_TICK` | `ServerTickEvent.Pre/Post` |

## How it is wired

A NeoForge Game Test needs three things that Fabric did not:

1. A **test function** in the `TEST_FUNCTION` registry. They are queued from
   `GameTestRegistration.createFunctionRegister()`, called from the `@Mod` constructor, and each
   one reflectively invokes a `public static void (GameTestHelper)` method.
2. A **test instance** in the `TEST_INSTANCE` registry, built in
   `GameTestRegistration.onRegisterGameTests` on `RegisterGameTestsEvent`. It carries the
   tick budget, padding and test environment that Fabric took from the annotation.
3. An **index resource** naming the methods. Test source sets are not scanned the way a
   `fabric-gametest` entrypoint was, so the main source set cannot discover them on its own.
   The index is the single list of what runs; a mismatch between it and the method's
   `@GameTestSpec` fails the launch instead of silently dropping a test.

| Suite | Index | Id prefix |
| --- | --- | --- |
| Contract/unit | `src/gametest/resources/entity_collision_optimizer/gametest-index.json` | `unit_` |
| Integration | `src/integrationTest/resources/entity_collision_optimizer/integration-gametest-index.json` | `integration_` |
| Benchmark | `src/gametest/resources/entity_collision_optimizer/benchmark-gametest-index.json` | `benchmark_` |

Ids are `<mod_id>:<prefix><snake_case_method_name>` because Minecraft identifiers only allow
`[a-z0-9/._-]`. Select suites with `--tests entity_collision_optimizer:unit_*` and friends.

## Contract and unit GameTests

Sources live under `src/gametest`. They exercise focused algorithms, native-memory contracts,
edge cases, and deterministic interaction fixtures. They may call test invokers, inspect optimizer
state, or compare an optimized operation with a small vanilla oracle in the same process.

The suite runs all 32 instances in one batch, concurrently, in a shared world. One known flaky
case is `unit_entity_section_query_contract`: its fixtures live in the overworld at low
coordinates and the reference query occasionally observes an entity another instance placed
nearby. It passes on re-run and the same assertion also guards the optimized path, so it is a
test-isolation weakness rather than a parity failure. Re-run before treating it as a regression.

## Cross-process integration GameTests

`vanilla-gametest/` first runs the two scenarios without Entity Collision Optimizer and records
their traces under `build/gametest-traces`; `runGameTestIntegration` then runs the same compiled
scenarios with the mod and requires byte-for-byte equality. Each scenario owns a fixed,
non-overlapping arena, restores it after completion, and writes a separate trace through
`CrossProcessTrace`.

The vanilla build compiles the shared harness and scenario sources itself rather than reading the
main project's `build/classes` output: mixing the system class loader with NeoForge's
`TRANSFORMER` loader produces a `LinkageError` on `DeferredRegister`. Everything the optimizer
owns (`collision/`, `natives/`, `mixin/`, the `@Mod` class) is excluded from that compilation, so
the baseline process genuinely has no optimizer.

The scenarios gate on each other through `IntegrationSequence`, which is keyed by scenario name.
Fabric ran the entrypoints serially and a single global flag was enough; NeoForge starts each
instance concurrently, so a global flag would leave the TNT scenario waiting forever.

## Performance benchmarks

Benchmarks measure workloads and validate only the benchmark fixture itself; they are not counted
as correctness tests. They are registered under the `benchmark_` prefix and pass immediately
unless `-Dentity_collision_optimizer.runBenchmark=true` is set (the `runGameTestBenchmark` run
adds it when `-Pbenchmark` is present).
