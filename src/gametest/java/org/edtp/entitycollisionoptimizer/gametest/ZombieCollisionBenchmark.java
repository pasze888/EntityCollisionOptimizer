package org.edtp.entitycollisionoptimizer.gametest;

import org.edtp.entitycollisionoptimizer.gametest.harness.GameTestSpec;
import net.minecraft.gametest.framework.GameTestHelper;

public final class ZombieCollisionBenchmark {
    static final int DURATION_TICKS = CollisionBenchmarkRunner.DURATION_TICKS;

    @GameTestSpec(maxTicks = 500, padding = 96)
    public static void fallingZombies(GameTestHelper helper) {
        CollisionBenchmarkRunner.run(helper, new ZombieBenchmarkChamber(helper));
    }
}