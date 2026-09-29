package org.edtp.entitycollisionoptimizer;

import com.mojang.logging.LogUtils;
import net.neoforged.bus.api.IEventBus;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.common.NeoForge;
import org.slf4j.Logger;

/**
 * NeoForge 入口点。清理与帧切换全部改由 NeoForge 事件承担，
 * 不再需要 Fabric 的 CommandRegistrationCallback / ServerLifecycleEvents。
 */
@Mod(EntityCollisionOptimizer.MODID)
public final class EntityCollisionOptimizer {
    public static final String MODID = "entity_collision_optimizer";
    public static final Logger LOGGER = LogUtils.getLogger();

    public EntityCollisionOptimizer(IEventBus modEventBus) {
        // 本模组只监听游戏总线；mod 总线（注册类事件）此处无内容。
        NeoForge.EVENT_BUS.addListener(CollisionOptimizerEvents::onRegisterCommands);
        NeoForge.EVENT_BUS.addListener(CollisionOptimizerEvents::onServerStopping);
        NeoForge.EVENT_BUS.addListener(CollisionOptimizerEvents::onLevelTickPre);
        NeoForge.EVENT_BUS.addListener(CollisionOptimizerEvents::onLevelTickPost);
        NeoForge.EVENT_BUS.addListener(CollisionOptimizerEvents::onPlayerChangeGameMode);
    }
}
