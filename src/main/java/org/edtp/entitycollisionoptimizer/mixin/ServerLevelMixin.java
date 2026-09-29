package org.edtp.entitycollisionoptimizer.mixin;

import org.edtp.entitycollisionoptimizer.natives.CollisionFrame;
import net.minecraft.server.level.ServerLevel;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(ServerLevel.class)
public abstract class ServerLevelMixin {
    @Inject(method = "<init>", at = @At("RETURN"))
    /* 把实体存储绑定到它所属的 ServerLevel。NeoForge 无对应事件（ServerStartedEvent 覆盖不了运行期新建的维度），保留 mixin。
       每 tick 的碰撞帧 begin/end 已改由 NeoForge 的 LevelTickEvent.Pre/Post 承担，见 CollisionOptimizerEvents。 */
    private void entityCollisionOptimizer$attachEntityStorage(CallbackInfo ci) {
        CollisionFrame.attach((ServerLevel) (Object) this);
    }
}
