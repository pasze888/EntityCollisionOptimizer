package org.edtp.entitycollisionoptimizer.vanillagametest;

import net.neoforged.bus.api.IEventBus;
import net.neoforged.fml.common.Mod;
import org.edtp.entitycollisionoptimizer.gametest.harness.GameTestRegistration;

/**
 * vanilla 对照进程的入口：只做 GameTest 注册，不加载任何优化器代码。
 *
 * <p>它复用主工程 {@code gametest.harness} 包里那套注册逻辑，因此两个进程的"什么算一个测试"
 * 完全一致——差别只剩有没有优化器，这正是逐字节比对要证明的东西。
 */
@Mod(VanillaGameTestMod.MOD_ID)
public final class VanillaGameTestMod {
    /** 与主工程同 id：测试实例 id（{@code entity_collision_optimizer:integration_*}）必须两边相同。 */
    public static final String MOD_ID = "entity_collision_optimizer";

    public VanillaGameTestMod(IEventBus modEventBus) {
        GameTestRegistration.reset();
        GameTestRegistration.configure(
                MOD_ID,
                "org.edtp.entitycollisionoptimizer.integration.",
                "integration_",
                "entity_collision_optimizer/integration-gametest-index.json");
        GameTestRegistration.createFunctionRegister().register(modEventBus);
        modEventBus.addListener(GameTestRegistration::onRegisterGameTests);
    }
}
