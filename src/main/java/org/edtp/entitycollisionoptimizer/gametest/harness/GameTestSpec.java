package org.edtp.entitycollisionoptimizer.gametest.harness;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Fabric 的 {@code net.fabricmc.fabric.api.gametest.v1.GameTest} 在 NeoForge 上没有对应物：
 * 26.x 的 GameTest 是数据驱动的（{@code data/<ns>/test_instance/*.json} + {@code TEST_FUNCTION}
 * 注册表），不再有"注解即测试"的扫描。这个注解因此只是**测试实例的元数据载体**，
 * 真正的注册发生在 {@link GameTestRegistration}。
 *
 * <p>字段名与语义逐一对应 Fabric 注解，迁移时只替换 import，测试体不用动。
 *
 * <p>这个包（harness）同时被主工程的测试源集与 vanilla 对照子工程复用，
 * 因此这里只能依赖 Minecraft / NeoForge 本身，不能碰模组代码。
 */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface GameTestSpec {
    /** 允许运行的最大 tick 数。 */
    int maxTicks() default 100;

    /** 搭建阶段 tick 数；与 Fabric 一致，默认 0。 */
    int setupTicks() default 0;

    /** 测试实例周围的额外空余方块，用于容纳测试自己搭建的场地。 */
    int padding() default 0;

    /** 测试环境 id；Fabric 侧默认的 batch/环境在此映射到 {@code minecraft:default}。 */
    String environment() default "minecraft:default";

    /** 结构路径；Fabric 不指定模板时用空场地，这里映射到 {@code minecraft:empty}。 */
    String structure() default "minecraft:empty";

    /** 失败时是否让整轮 GameTest 失败。 */
    boolean required() default true;
}
