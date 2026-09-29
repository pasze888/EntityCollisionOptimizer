package org.edtp.entitycollisionoptimizer.gametest;

import org.edtp.entitycollisionoptimizer.EntityCollisionOptimizer;
import org.edtp.entitycollisionoptimizer.gametest.mixin.ZombieTestInvoker;
import org.edtp.entitycollisionoptimizer.gametest.harness.GameTestSpec;

// GameTestSpec / GameTestRegistration 位于主源集：发布 jar 里没有测试类，主源集按名字反射回去。
import net.minecraft.gametest.framework.GameTestHelper;
import net.minecraft.world.entity.EntityType;
import net.minecraft.world.entity.monster.hoglin.Hoglin;
import net.minecraft.world.entity.monster.piglin.Piglin;
import net.minecraft.world.entity.monster.zombie.Zombie;
import net.minecraft.world.phys.Vec3;

/** Deterministic component and contract checks that may inspect optimizer internals. */
public final class CollisionContractGameTests {
    @GameTestSpec(maxTicks = 100)
    public static void indexPublicationDoesNotLoadChunks(GameTestHelper helper) {
        org.edtp.entitycollisionoptimizer.natives.IndexPublicationChecks.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 20)
    public static void piglinConversionLifecycle(GameTestHelper helper) {
        Piglin piglin = helper.spawn(EntityType.PIGLIN, new Vec3(1.5, 2.0, 1.5));
        piglin.setTimeInOverworld(300);
        helper.runAfterDelay(5, () -> {
            helper.assertTrue(piglin.isRemoved(), "piglin must complete its overworld conversion");
            helper.succeed();
        });
    }

    @GameTestSpec(maxTicks = 20)
    public static void zombieDrownedConversionLifecycle(GameTestHelper helper) {
        Zombie zombie = helper.spawn(EntityType.ZOMBIE, new Vec3(1.5, 2.0, 1.5));
        ((ZombieTestInvoker) zombie).entityCollisionOptimizer$startUnderWaterConversion(0);
        helper.runAfterDelay(5, () -> {
            helper.assertTrue(zombie.isRemoved(), "zombie must complete its drowned conversion");
            helper.succeed();
        });
    }

    @GameTestSpec(maxTicks = 20)
    public static void hoglinConversionLifecycle(GameTestHelper helper) {
        Hoglin hoglin = helper.spawn(EntityType.HOGLIN, new Vec3(1.5, 2.0, 1.5));
        hoglin.setTimeInOverworld(300);
        helper.runAfterDelay(5, () -> {
            helper.assertTrue(hoglin.isRemoved(), "hoglin must complete its overworld conversion");
            helper.succeed();
        });
    }

    @GameTestSpec(maxTicks = 200)
    public static void emptyWorldSpawnQuery(GameTestHelper helper) {
        org.edtp.entitycollisionoptimizer.natives.NativeHardQueryChecks.emptyWorld(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void nativeMovementContract(GameTestHelper helper) {
        NativeVoxelParity.edges(helper);
        SingleCellParity.verify(helper);
        org.edtp.entitycollisionoptimizer.natives.MovementPublicationChecks.verify(helper);
        org.edtp.entitycollisionoptimizer.natives.MovementBoundsChecks.verify(helper);
        org.edtp.entitycollisionoptimizer.natives.NativeRowsChecks.verify(helper);
        org.edtp.entitycollisionoptimizer.natives.MovementLeaseChecks.verify(helper);
        org.edtp.entitycollisionoptimizer.natives.NativeFailureChecks.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void positionWriteParity(GameTestHelper helper) {
        PositionWriteParity.verify(helper);
        org.edtp.entitycollisionoptimizer.natives.PositionMirrorChecks.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void nativeQueryContract(GameTestHelper helper) {
        org.edtp.entitycollisionoptimizer.natives.NativeQueryChecks.verify(helper);
        org.edtp.entitycollisionoptimizer.natives.VerticalIndexChecks.verify(helper);
        org.edtp.entitycollisionoptimizer.natives.NativeHardQueryChecks.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void orderedNativeIndexParity(GameTestHelper helper) {
        OrderedCandidateParity.verify(helper);
        org.edtp.entitycollisionoptimizer.natives.NativeOrderChecks.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void sharedBodyStateParity(GameTestHelper helper) {
        BodyFieldConsumerCoverage.verify();
        SyncStateParity.verify(helper);
        PushStateParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void nativePushRunParity(GameTestHelper helper) {
        NativePushRunParity.verify(helper);
        PushRunBoundaryParity.verify(helper);
        PersistentBodyParity.verify(helper);
        AuthoritativeVelocityParity.verify(helper);
        org.edtp.entitycollisionoptimizer.natives.CollisionStateTableChecks.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void playerInteractions(GameTestHelper helper) {
        PlayerInteractionParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void mixedEntityInteractions(GameTestHelper helper) {
        MixedEntityInteractionParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void thrownProjectiles(GameTestHelper helper) {
        ProjectileInteractionParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void explosionInteractions(GameTestHelper helper) {
        ExplosionInteractionParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void tntCannonInteractions(GameTestHelper helper) {
        TntCannonParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void machineClearances(GameTestHelper helper) {
        MachineClearanceParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void fluidInteractions(GameTestHelper helper) {
        FluidInteractionParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void irregularInteractions(GameTestHelper helper) {
        IrregularMovementParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void surfaceInteractions(GameTestHelper helper) {
        SurfaceInteractionParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void pistonInteractions(GameTestHelper helper) {
        PistonInteractionParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void liveTeamContract(GameTestHelper helper) {
        CollisionContractParity.teams(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void orderedEntityContract(GameTestHelper helper) {
        CollisionContractParity.order(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void entitySectionQueryContract(GameTestHelper helper) {
        EntityQueryParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void canonicalVelocityContract(GameTestHelper helper) {
        CollisionContractParity.visibility(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void orderedBlockShapes(GameTestHelper helper) {
        BlockShapeParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void blockMovementParity(GameTestHelper helper) {
        BlockMovementParity.verify(helper);
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void impulseObservationParity(GameTestHelper helper) {
        CollisionImpulseParity.verify(helper);
        NativeImpulseParity.verify(helper);
        PushBatchParity.verify(helper);
        EntityCollisionOptimizer.LOGGER.info(
                "ECO_PARITY_RESULT velocity_observations=5 kernel_bitwise_pairs=225 arithmetic_sequences=4 nested_batches=2 sleep_phases=3 result=passed"
        );
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void lowDensityVanillaParity(GameTestHelper helper) {
        CollisionParity.verifyLowDensity(helper);
        EntityCollisionOptimizer.LOGGER.info(
                "ECO_PARITY_RESULT density=low dispatch_pairs=32 state_transitions=11 repeated_frames=4 result=passed"
        );
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void mediumDensityVanillaParity(GameTestHelper helper) {
        CollisionParity.verifyMediumDensity(helper);
        EntityCollisionOptimizer.LOGGER.info(
                "ECO_PARITY_RESULT density=medium groups=2 entity_counts=20,24 result=passed"
        );
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 200, padding = 48)
    public static void concurrentLevelIsolation(GameTestHelper helper) {
        CollisionParity.verifyConcurrentLevelIsolation(helper);
        EntityCollisionOptimizer.LOGGER.info(
                "ECO_PARITY_RESULT dimensions=3 concurrent_queries=13500 native_batches=4500 result=passed"
        );
        helper.succeed();
    }

    @GameTestSpec(maxTicks = 800, padding = 48, environment = "entity_collision_optimizer:chunk_load")
    public static void chunkLoadBoundaries(GameTestHelper helper) {
        ChunkLoadParity.verify(helper);
    }
}