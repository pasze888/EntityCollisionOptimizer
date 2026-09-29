package org.edtp.entitycollisionoptimizer.collision.bytecode;

import org.edtp.entitycollisionoptimizer.EntityCollisionOptimizer;
import org.objectweb.asm.ClassReader;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;

import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

/** Uniform field access boundary; consumer mixins declare coverage, not per-consumer behavior. */
public final class BodyFieldAccess {
    private static final String ENTITY = "net/minecraft/world/entity/Entity";
    private static final String OBJECT = "java/lang/Object";
    private static final String VECTOR = "Lnet/minecraft/world/phys/Vec3;";
    private static final String ACCESS = "org/edtp/entitycollisionoptimizer/collision/CollisionBodyAccess";
    /** internal name -> 是否 Entity 子类；同一条父类链上的节点答案相同。 */
    private static final Map<String, Boolean> ENTITY_SUBTYPES = new ConcurrentHashMap<>();
    /** 无法解析父类链的类型，每个只报告一次。 */
    private static final Set<String> UNRESOLVED_HIERARCHIES = ConcurrentHashMap.newKeySet();

    public static void rewrite(ClassNode node) {
        boolean entityClass = node.name.equals(ENTITY);
        for (var method : node.methods) {
            // Only these storage primitives may physically touch the unbound field.
            if (entityClass && (method.name.equals("eco$readVelocity") || method.name.equals("eco$writeVelocity")
                    || method.name.equals("eco$readNeedsSync") || method.name.equals("eco$writeNeedsSync")
                    || method.name.equals("eco$writeNoPhysics") || method.name.equals("eco$writePosition")
                    || method.name.equals("eco$readPosition")
                    || method.name.equals("eco$readBounds") || method.name.equals("eco$writeBounds")
                    || method.name.equals("eco$detachBody"))) continue;
            for (var instruction : method.instructions.toArray()) {
                if (!(instruction instanceof FieldInsnNode field)) continue;
                boolean read = field.getOpcode() == Opcodes.GETFIELD;
                boolean velocity = field.owner.equals(ENTITY) && field.name.equals("deltaMovement") && field.desc.equals(VECTOR);
                boolean position = field.owner.equals(ENTITY) && field.name.equals("position") && field.desc.equals(VECTOR);
                boolean bounds = field.owner.equals(ENTITY) && field.name.equals("bb")
                        && field.desc.equals("Lnet/minecraft/world/phys/AABB;");
                boolean sync = field.name.equals("needsSync") && field.desc.equals("Z")
                        && ownsEntityField(field, node);
                boolean physics = !read && field.name.equals("noPhysics") && field.desc.equals("Z")
                        && ownsEntityField(field, node);
                if (!velocity && !position && !bounds && !sync && !physics) continue;
                if (!read && field.getOpcode() != Opcodes.PUTFIELD) {
                    throw new IllegalStateException("Unexpected collision body field opcode");
                }
                String name = velocity ? (read ? "eco$readVelocity" : "eco$writeVelocity")
                        : position ? (read ? "eco$readPosition" : "eco$writePosition")
                        : bounds ? (read ? "eco$readBounds" : "eco$writeBounds")
                        : sync ? (read ? "eco$readNeedsSync" : "eco$writeNeedsSync") : "eco$writeNoPhysics";
                method.instructions.set(field, new MethodInsnNode(Opcodes.INVOKEINTERFACE, ACCESS,
                        name, read ? "()" + field.desc : "(" + field.desc + ")V", true));
            }
        }
    }

    /**
     * {@code needsSync}/{@code noPhysics} 没有类型限制，必须先确认归属类继承自 Entity。
     *
     * <p>两条可快速判定的路径：字段声明类 {@code Entity} 本身；以及当前被变换的类自身（javac 对
     * {@code this.field} 用当前类作 owner），此时若该类自己声明了同名字段就说明与该字段无关。
     * 其余（例如 {@code Guardian$GuardianAttackGoal} 里的 {@code Guardian.needsSync}）走父类链判定。
     */
    private static boolean ownsEntityField(FieldInsnNode field, ClassNode node) {
        if (field.owner.equals(ENTITY)) return true;
        if (field.owner.equals(node.name)) {
            for (var declared : node.fields) {
                if (declared.name.equals(field.name) && declared.desc.equals(field.desc)) return false;
            }
            return true;
        }
        return isEntitySubtype(field.owner);
    }

    /**
     * 判断 internal name 是否为 Entity 子类。
     *
     * <p>NeoForge 的 mixin 服务不提供未变换字节码
     * （{@code getBytecodeProvider().getClassNode} 抛 {@code IllegalArgumentException:
     * FML service does not currently support retrieval of untransformed bytecode}），
     * 而 {@code Class.forName} 会在 mixin 变换期间提前加载目标类、副作用不可控；
     * 因此这里只读 class 资源的 superName 链（不加载类），用 ASM 解析。
     * 父类链上的每个节点答案相同，故可整体缓存。
     */
    private static boolean isEntitySubtype(String internalName) {
        Boolean cached = ENTITY_SUBTYPES.get(internalName);
        if (cached != null) return cached;

        List<String> chain = new ArrayList<>();
        String current = internalName;
        Boolean result = null;
        for (int guard = 0; current != null && guard < 128; guard++) {
            if (current.equals(ENTITY)) {
                result = Boolean.TRUE;
                break;
            }
            Boolean known = ENTITY_SUBTYPES.get(current);
            if (known != null) {
                result = known;
                break;
            }
            if (current.equals(OBJECT)) {
                result = Boolean.FALSE;
                break;
            }
            chain.add(current);
            current = readSuperName(current);
        }
        if (result == null) {
            // 读不到 class 资源时保守跳过：宁可少重写（最多退回原版字段语义）也不要误写非实体字段。
            if (UNRESOLVED_HIERARCHIES.add(internalName)) {
                EntityCollisionOptimizer.LOGGER.warn(
                        "Cannot resolve the class hierarchy of {}; its collision body field access is left untouched",
                        internalName);
            }
            return false;
        }
        for (String name : chain) {
            ENTITY_SUBTYPES.put(name, result);
        }
        return result;
    }

    private static String readSuperName(String internalName) {
        String resource = internalName + ".class";
        for (ClassLoader loader : new ClassLoader[] {
                BodyFieldAccess.class.getClassLoader(),
                Thread.currentThread().getContextClassLoader()}) {
            if (loader == null) continue;
            try (InputStream stream = loader.getResourceAsStream(resource)) {
                if (stream == null) continue;
                return new ClassReader(stream).getSuperName();
            } catch (IOException | RuntimeException failure) {
                // 换下一个 ClassLoader 继续尝试。
            }
        }
        return null;
    }

    private BodyFieldAccess() {}
}
