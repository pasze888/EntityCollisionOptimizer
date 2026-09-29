package org.edtp.entitycollisionoptimizer.integration;

import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/**
 * 记录"某个场景已经跑完"，让同一批次里的后续场景可以等它腾出的世界状态。
 *
 * <p>上游 Fabric 版本只用一个全局布尔：Fabric 的 fabric-gametest 按入口点顺序串行跑，那个布尔
 * 够用。NeoForge 的数据驱动 runner 会把同一批里的测试并发起跑（各自一个<b>独立的</b>类加载器
 * 上下文），全局布尔在第二个场景里永远是 false，于是 TNT 场景会一直等到超时。因此这里改成按场景名
 * 记账：每个场景只看自己依赖的那个前置场景。
 */
final class IntegrationSequence {
    private static final Set<String> COMPLETE = ConcurrentHashMap.newKeySet();

    static final String ZOMBIE_CRAMMING = "zombie-cramming";

    private IntegrationSequence() {
    }

    static boolean isComplete(String scenario) {
        return COMPLETE.contains(scenario);
    }

    static void complete(String scenario) {
        COMPLETE.add(scenario);
    }
}
