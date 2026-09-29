package org.edtp.entitycollisionoptimizer.gametest;

import org.edtp.entitycollisionoptimizer.gametest.harness.GameTestSpec;
import net.minecraft.gametest.framework.GameTestHelper;

public final class ElderGuardianBenchmark {
    // The benchmark intentionally runs a 100-tick post-window drain.  Leave
    // headroom for heavily loaded profiling hosts that fall behind wall time.
    @GameTestSpec(maxTicks = 1600, padding = 96)
    public static void voidPipe(GameTestHelper helper) {
        CollisionBenchmarkRunner.run(helper, new ElderGuardianPipe(helper));
    }
}