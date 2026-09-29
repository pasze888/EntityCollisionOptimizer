package org.edtp.entitycollisionoptimizer.gametest.harness;

import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.UncheckedIOException;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.Consumer;
import net.minecraft.core.Holder;
import net.minecraft.core.registries.Registries;
import net.minecraft.gametest.framework.FunctionGameTestInstance;
import net.minecraft.gametest.framework.GameTestHelper;
import net.minecraft.gametest.framework.TestData;
import net.minecraft.gametest.framework.TestEnvironmentDefinition;
import net.minecraft.resources.Identifier;
import net.minecraft.resources.ResourceKey;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.level.block.Rotation;
import net.neoforged.neoforge.event.RegisterGameTestsEvent;
import net.neoforged.neoforge.registries.DeferredRegister;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * NeoForge 26.x 的 GameTest 是数据驱动的：测试实例来自 {@code TEST_INSTANCE} 注册表，方法体通过
 * {@code TEST_FUNCTION} 注册表引用。Fabric 那边"给方法加注解就自动是测试"的机制（fabric-gametest
 * 入口点）在 1.21.5 之后就不存在了，因此这里要把两件事都补上：
 *
 * <ol>
 *   <li>{@code TEST_FUNCTION} 条目在 mod 构造期用 {@link DeferredRegister} 登记，值是
 *       {@link Consumer Consumer&lt;GameTestHelper&gt;}，内部反射调用测试方法；</li>
 *   <li>测试实例在 {@link RegisterGameTestsEvent} 里用 {@link FunctionGameTestInstance} 构造。</li>
 * </ol>
 *
 * <p>方法名来自测试源集随资源发布的 <b>gametest-index.json</b>：测试源集不会像 Fabric 入口点那样
 * 被主动扫描，主源集必须先知道名字才能 {@code Class.forName}。方法上的 {@link GameTestSpec}
 * 与索引必须一致——不一致会在启动期直接抛异常，而不是让某个用例静默消失。
 *
 * <p>主工程与 vanilla 对照子工程各自 {@link #configure} 一次（资源路径、包名、id 前缀不同）。
 * 发布 jar 不含测试源集，索引资源与方法都不存在，{@link #createFunctionRegister()} 返回空注册器，
 * 整条链路不产生任何副作用。
 */
public final class GameTestRegistration {
    private static final Logger LOGGER = LoggerFactory.getLogger("entity_collision_optimizer/gametest");

    private static String namespace = "entity_collision_optimizer";
    private static String testPackage = "org.edtp.entitycollisionoptimizer.gametest.";
    private static String idPrefix = "unit_";
    private static String indexResource = "entity_collision_optimizer/gametest-index.json";

    private static final Map<String, TestFunction> FUNCTIONS = new LinkedHashMap<>();

    private record TestFunction(Method method, GameTestSpec spec) {
    }

    private GameTestRegistration() {
    }

    /**
     * 声明这批测试属于哪套清单。必须在 {@link #createFunctionRegister()} 之前调用一次。
     *
     * @param namespace    注册表命名空间，同时也是 {@code --tests <namespace>:<id>} 里的那个
     * @param testsPackage 测试类所在包（含末尾的点）
     * @param idPrefix     注册 id 前缀，用于把不同套件分开选择（例如 {@code unit_} / {@code integration_}）
     * @param index        索引资源路径
     */
    public static void configure(String namespace, String testsPackage, String idPrefix, String index) {
        GameTestRegistration.namespace = namespace;
        GameTestRegistration.testPackage = testsPackage;
        GameTestRegistration.idPrefix = idPrefix;
        GameTestRegistration.indexResource = index;
    }

    /** 清空上一轮扫描结果；同一进程里只配置一次，重复配置属于编程错误。 */
    public static void reset() {
        FUNCTIONS.clear();
    }

    /**
     * 在 mod 构造期建好 {@code TEST_FUNCTION} 的延迟注册器。必须在 RegisterEvent 触发之前调用
     * （也就是 {@code @Mod} 构造函数里）。
     */
    public static DeferredRegister<Consumer<GameTestHelper>> createFunctionRegister() {
        // 注册表条目必须在 Bootstrap 之后才允许创建。主工程里 NeoForge 自己会在 mod 构造期间
        // 完成引导，但 vanilla 对照工程只加载测试入口，BuiltInRegistries 可能先被这条链路
        // 拉起来，从而撞上"Not bootstrapped"。这里显式保证前置条件；已完成时该调用是空操作。
        Bootstrap.bootStrap();
        DeferredRegister<Consumer<GameTestHelper>> register =
                DeferredRegister.create(Registries.TEST_FUNCTION, namespace);
        for (Map.Entry<String, TestFunction> entry : loadIndex().entrySet()) {
            register.register(entry.getKey(), () -> helper -> invoke(entry.getValue(), helper));
        }
        if (!FUNCTIONS.isEmpty()) {
            LOGGER.info("Registered {} game test functions from {}", FUNCTIONS.size(), indexResource);
        }
        return register;
    }

    /** 把每个函数包装成测试实例；实例 id 即函数 id。 */
    public static void onRegisterGameTests(RegisterGameTestsEvent event) {
        if (FUNCTIONS.isEmpty()) {
            return;
        }
        TestEnvironmentDefinition<?> defaultEnvironment = new TestEnvironmentDefinition.AllOf(List.of());
        for (Map.Entry<String, TestFunction> entry : FUNCTIONS.entrySet()) {
            String name = entry.getKey();
            GameTestSpec spec = entry.getValue().spec();
            ResourceKey<Consumer<GameTestHelper>> functionKey =
                    ResourceKey.create(Registries.TEST_FUNCTION, Identifier.fromNamespaceAndPath(namespace, name));
            TestData<Holder<TestEnvironmentDefinition<?>>> data = new TestData<>(
                    Holder.direct(defaultEnvironment),
                    Identifier.parse(spec.structure()),
                    spec.maxTicks(),
                    spec.setupTicks(),
                    spec.required(),
                    Rotation.NONE,
                    false,
                    1,
                    1,
                    false,
                    spec.padding());
            event.registerTest(
                    Identifier.fromNamespaceAndPath(namespace, name),
                    new FunctionGameTestInstance(functionKey, data));
        }
        LOGGER.info("Registered {} game tests for {}", FUNCTIONS.size(), namespace);
    }

    private static Map<String, TestFunction> loadIndex() {
        InputStream stream = GameTestRegistration.class.getClassLoader().getResourceAsStream(indexResource);
        if (stream == null) {
            // 发布运行时没有测试资源，这是正常状态而非错误。
            return Map.of();
        }
        Map<String, TestFunction> resolved = new LinkedHashMap<>();
        try (InputStreamReader reader = new InputStreamReader(stream, StandardCharsets.UTF_8)) {
            JsonObject root = JsonParser.parseReader(reader).getAsJsonObject();
            JsonArray tests = root.getAsJsonArray("tests");
            for (JsonElement element : tests) {
                JsonObject entry = element.getAsJsonObject();
                String qualified = entry.get("method").getAsString();
                TestFunction function = resolve(qualified, entry);
                String id = identifierFor(function.method());
                if (resolved.putIfAbsent(id, function) != null) {
                    throw new IllegalStateException("Duplicate game test id '" + id + "' in " + indexResource);
                }
            }
        } catch (IOException ex) {
            throw new UncheckedIOException("Cannot read " + indexResource, ex);
        }
        FUNCTIONS.putAll(resolved);
        return resolved;
    }

    /**
     * 方法名 → 注册 id。Vanilla 的 Identifier 路径只允许 {@code [a-z0-9/._-]}，而 Java 方法名是
     * camelCase，因此必须转换；再加上套件前缀，让 {@code --tests <namespace>:unit_*} 能单独选一套。
     */
    private static String identifierFor(Method method) {
        return idPrefix + method.getName().replaceAll("([a-z0-9])([A-Z])", "$1_$2").toLowerCase(Locale.ROOT);
    }

    private static TestFunction resolve(String qualifiedName, JsonObject entry) {
        int separator = qualifiedName.indexOf('.');
        if (separator < 0) {
            throw new IllegalStateException("Game test index entry is not 'Class.method': " + qualifiedName);
        }
        String className = testPackage + qualifiedName.substring(0, separator);
        String methodName = qualifiedName.substring(separator + 1);
        Class<?> testClass;
        Method method;
        try {
            testClass = Class.forName(className);
            method = testClass.getMethod(methodName, GameTestHelper.class);
        } catch (ClassNotFoundException | NoSuchMethodException ex) {
            throw new IllegalStateException("Game test index references a missing test: " + qualifiedName, ex);
        }
        if (!Modifier.isStatic(method.getModifiers())) {
            throw new IllegalStateException("Game test " + qualifiedName + " must be static");
        }
        GameTestSpec spec = method.getAnnotation(GameTestSpec.class);
        if (spec == null) {
            throw new IllegalStateException("Game test " + qualifiedName + " is missing @GameTestSpec");
        }
        int maxTicks = entry.has("maxTicks") ? entry.get("maxTicks").getAsInt() : spec.maxTicks();
        int padding = entry.has("padding") ? entry.get("padding").getAsInt() : spec.padding();
        if (maxTicks != spec.maxTicks() || padding != spec.padding()) {
            throw new IllegalStateException("Game test " + qualifiedName
                    + " disagrees with " + indexResource + ": index maxTicks=" + maxTicks + " padding=" + padding
                    + ", annotation maxTicks=" + spec.maxTicks() + " padding=" + spec.padding());
        }
        return new TestFunction(method, spec);
    }

    private static void invoke(TestFunction function, GameTestHelper helper) {
        try {
            function.method().invoke(null, helper);
        } catch (IllegalAccessException ex) {
            throw new IllegalStateException("Cannot invoke game test " + function.method(), ex);
        } catch (InvocationTargetException ex) {
            throw sneakyThrow(ex.getCause());
        }
    }

    @SuppressWarnings("unchecked")
    private static <T extends Throwable> RuntimeException sneakyThrow(Throwable throwable) throws T {
        throw (T) throwable;
    }
}
