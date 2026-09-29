# Test suites

The project keeps correctness contracts, cross-process integration scenarios, and performance
benchmarks separate. Each Gradle invocation enables exactly one suite.

## Status on this NeoForge branch

The three Fabric GameTest layers described below are **not ported yet**. Until they are, the
verification steps for the NeoForge port are manual:

```powershell
.\gradlew.bat build          # Java compiles; jar packages metadata, mixins and native binaries
.\gradlew.bat runServer      # start a development server and watch the log
```

A healthy development start logs:

```text
Extracted FFM native library /natives/windows-x64/EntityCollisionOptimizer.dll to ...
FFM collision backend initialized
Done (0.454s)! For help, type "help"
```

and contains no `Mixin apply ... failed` line. That start exercises mixin application, the
collision-field bytecode rewrite and FFM symbol binding. A broken field rewrite either fails the
launch or logs `Cannot resolve the class hierarchy of ...`, in which case the corresponding
`needsSync`/`noPhysics` access stays on the stale Java field — see
[docs/troubleshooting.md](docs/troubleshooting.md).

Behavioural equivalence (same candidates, same order, same publication points) is what the suites
below must prove. It is **not yet proven on this branch** beyond the launch checks.

## Porting map

| Fabric layer | NeoForge equivalent |
| --- | --- |
| `net.fabricmc.fabric.api.gametest.v1.GameTest` + the `fabric-gametest` entrypoint in `fabric.mod.json` | vanilla `@GameTest` / `@GameTestHolder` (or `RegisterGameTestsEvent`) in a test source set, run by MDG's `gameTestServer` run with `neoforge.enabledGameTestNamespaces` |
| Test mod metadata (`src/unitTest/resources/fabric.mod.json`, `src/benchmarkTest/...`, `src/integrationTest/...`) | a test mod's `neoforge.mods.toml` with its own `[[mods]]` and `[[mixins]]` |
| `vanilla-gametest` Loom subproject (records traces without the mod) | an MDG subproject that does not depend on the optimizer, wired as a dependency of the comparison run |
| `FabricLoader.getInstance().isModLoaded(...)` | `ModList.get().isLoaded(...)` (the Fabric-only carpet/Fuji consumer targets were dropped) |

The `-PunitTest`, `-PintegrationTest` and `-Pbenchmark` properties are still validated as
mutually exclusive, but only `-Pbenchmark` is currently forwarded (as
`-Dentity_collision_optimizer.runBenchmark=true`) because the test source sets are not wired up.

## Contract and unit GameTests

```powershell
.\gradlew.bat gameTestServer
```

These tests load Entity Collision Optimizer and exercise focused algorithms, native-memory
contracts, edge cases, and deterministic interaction fixtures. They may call test invokers,
inspect optimizer state, or compare an optimized operation with a small vanilla oracle in the
same process. Failures should identify the violated contract precisely.

Sources live under `src/gametest`; the entrypoint manifest lives under `src/unitTest`.

## Cross-process integration GameTests

The `vanilla-gametest` project first runs the integration scenarios without Entity Collision
Optimizer and records their traces. The root project then runs the same source with the mod and
requires byte-for-byte equality. Integration scenarios use normal server ticks and public
Minecraft APIs; they must not import optimizer code or unit-test mixins.

Each scenario owns a fixed, non-overlapping arena, restores it after completion, and writes a
separate trace through `CrossProcessTrace`. Add its public GameTest class to both integration
manifests.

Sources and the optimized manifest live under `src/integrationTest`; the vanilla manifest still
lives under `vanilla-gametest/src/main/resources` in its Fabric form and has to be rebuilt for
NeoForge before this layer can run.

## Performance benchmarks

Benchmarks measure workloads and validate only the benchmark fixture itself. They are not counted
as correctness tests and use the entrypoint manifest under `src/benchmarkTest`.
