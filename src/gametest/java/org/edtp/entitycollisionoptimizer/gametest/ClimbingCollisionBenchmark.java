package org.edtp.entitycollisionoptimizer.gametest;

import org.edtp.entitycollisionoptimizer.gametest.harness.GameTestSpec;
import net.minecraft.gametest.framework.GameTestHelper;

public final class ClimbingCollisionBenchmark {
    // The shared runner is serial, so this timeout also covers earlier scenarios.
    @GameTestSpec(maxTicks = 1800, padding = 16)
    public static void denseScaffolding(GameTestHelper helper) {
        CollisionBenchmarkRunner.run(helper, new ClimbingCollisionChamber(helper));
    }
}