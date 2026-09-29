package org.edtp.entitycollisionoptimizer;

import com.mojang.logging.LogUtils;
import net.neoforged.bus.api.IEventBus;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.common.NeoForge;
import org.edtp.entitycollisionoptimizer.gametest.harness.GameTestRegistration;
import org.slf4j.Logger;

/**
 * NeoForge 入口点。清理与帧切换全部改由 NeoForge 事件承担，
 * 不再需要 Fabric 的 CommandRegistrationCallback / ServerLifecycleEvents。
 */
@Mod(EntityCollisionOptimizer.MODID)
public final class EntityCollisionOptimizer {
    public static final String MODID = "entity_collision_optimizer";
    public static final Logger LOGGER = LogUtils.getLogger();

    /**
     * 选择运行哪一套 GameTest 清单。默认契约/单元套件；跨进程集成套件用
     * {@code -Dentity_collision_optimizer.gametest.suite=integration} 切换。
     * 两套的场地规模与 tick 预算差一个量级，混在一起跑没有意义。
     */
    private static final String SUITE_PROPERTY = "entity_collision_optimizer.gametest.suite";

    public EntityCollisionOptimizer(IEventBus modEventBus) {
        // mod 总线：TEST_FUNCTION 条目 + 数据驱动的测试实例。
        // 测试源集缺席时（发布运行）索引资源不存在，注册器为空，这条链路完全空转。
        GameTestRegistration.reset();
        switch (System.getProperty(SUITE_PROPERTY, "unit")) {
            case "integration" -> GameTestRegistration.configure(
                    MODID,
                    "org.edtp.entitycollisionoptimizer.integration.",
                    "integration_",
                    "entity_collision_optimizer/integration-gametest-index.json");
            case "benchmark" -> GameTestRegistration.configure(
                    MODID,
                    "org.edtp.entitycollisionoptimizer.gametest.",
                    "benchmark_",
                    "entity_collision_optimizer/benchmark-gametest-index.json");
            default -> GameTestRegistration.configure(
                    MODID,
                    "org.edtp.entitycollisionoptimizer.gametest.",
                    "unit_",
                    "entity_collision_optimizer/gametest-index.json");
        }
        GameTestRegistration.createFunctionRegister().register(modEventBus);
        modEventBus.addListener(GameTestRegistration::onRegisterGameTests);

        NeoForge.EVENT_BUS.addListener(CollisionOptimizerEvents::onRegisterCommands);
        NeoForge.EVENT_BUS.addListener(CollisionOptimizerEvents::onServerStopping);
        NeoForge.EVENT_BUS.addListener(CollisionOptimizerEvents::onLevelTickPre);
        NeoForge.EVENT_BUS.addListener(CollisionOptimizerEvents::onLevelTickPost);
        NeoForge.EVENT_BUS.addListener(CollisionOptimizerEvents::onPlayerChangeGameMode);
    }
}
