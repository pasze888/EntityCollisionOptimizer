package org.edtp.entitycollisionoptimizer;

import net.minecraft.server.level.ServerLevel;
import net.neoforged.neoforge.event.RegisterCommandsEvent;
import net.neoforged.neoforge.event.entity.player.PlayerEvent;
import net.neoforged.neoforge.event.server.ServerStoppingEvent;
import net.neoforged.neoforge.event.tick.LevelTickEvent;
import org.edtp.entitycollisionoptimizer.collision.CollisionCacheState;
import org.edtp.entitycollisionoptimizer.commands.CollisionOptimizerCommand;
import org.edtp.entitycollisionoptimizer.natives.CollisionFrame;
import org.edtp.entitycollisionoptimizer.natives.FFMBackend;

/**
 * 用 NeoForge 事件替代原先的 mixin 注入点。
 *
 * <ul>
 *   <li>{@code ServerLevelMixin#tick} 的两个注入点 → {@link LevelTickEvent.Pre}/{@link LevelTickEvent.Post}
 *       （NeoForge 在 MinecraftServer.tickChildren 里紧贴 level tick 的 try 块前后触发，语义与原来一致）。</li>
 *   <li>{@code ServerPlayerMixin#setGameMode} → {@link PlayerEvent.PlayerChangeGameModeEvent}
 *       （NeoForge 在变更生效前触发；缓存是读时校验的，提前失效不影响语义）。</li>
 *   <li>命令注册与服务器停止 → {@link RegisterCommandsEvent} / {@link ServerStoppingEvent}。</li>
 * </ul>
 */
public final class CollisionOptimizerEvents {
    private CollisionOptimizerEvents() {
    }

    public static void onRegisterCommands(RegisterCommandsEvent event) {
        CollisionOptimizerCommand.register(event.getDispatcher());
    }

    public static void onServerStopping(ServerStoppingEvent event) {
        CollisionFrame.destroy();
        FFMBackend.destroy();
    }

    public static void onLevelTickPre(LevelTickEvent.Pre event) {
        if (event.getLevel() instanceof ServerLevel level) {
            CollisionFrame.begin(level);
        }
    }

    public static void onLevelTickPost(LevelTickEvent.Post event) {
        if (event.getLevel() instanceof ServerLevel level) {
            CollisionFrame.end(level);
        }
    }

    public static void onPlayerChangeGameMode(PlayerEvent.PlayerChangeGameModeEvent event) {
        ((CollisionCacheState) event.getEntity()).entityCollisionOptimizer$invalidateCollisionCache();
    }
}
