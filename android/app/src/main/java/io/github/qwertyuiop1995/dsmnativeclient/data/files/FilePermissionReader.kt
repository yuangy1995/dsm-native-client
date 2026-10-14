package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.parseFilePageFixture
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

internal class FilePermissionReader(
    private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
    private val access: () -> FilePermissionAccess,
) {
    suspend fun load(path: String): FilePermissionSnapshot {
        if (!isFileMutationPath(path)) throw permissionFailure()
        val data = call("SYNO.FileStation.List", "getinfo", mapOf("path" to permissionStrings(listOf(path)),
            "additional" to permissionStrings(listOf("real_path", "size", "owner", "time", "perm", "mount_point_type"))), 2)
        val row = (data["files"] as? JsonArray)?.singleOrNull() as? JsonObject ?: throw permissionFailure()
        if (row.permissionText("path") != path || row["code"]?.let { it.permissionInteger() != 0L } == true) throw permissionFailure()
        row.permissionBoolean("isdir")
        val additional = row["additional"] as? JsonObject ?: throw permissionFailure()
        val resolved = additional.permissionText("real_path")?.takeIf { isFileMutationPath(it) } ?: throw permissionFailure()
        val perm = additional["perm"] as? JsonObject ?: throw permissionFailure()
        val isACL = perm.permissionBoolean("is_acl_mode")
        val target = parseFilePageFixture(buildJsonObject { putJsonArray("files") { add(row) } }).items.single()
            .copy(accessedAtEpochSeconds = null)
        val editable = permissionTargetEditable(target) && access().granted
        if (isACL) {
            val acl = call(PERMISSION_ACL_API, "get", mapOf("type" to "all", "file_path" to resolved, "include_noname_rules" to "true"), 1)
            if (!acl.permissionBoolean("is_acl")) throw permissionChanged()
            val owner = call("SYNO.FileStation.Property.ACLOwner", "get", mapOf("file" to resolved), 1)
            val rules = (acl["acl"] as? JsonArray)?.map(::parsePermissionRule) ?: throw permissionFailure()
            return FilePermissionSnapshot(target, resolved, true, editable && acl.permissionBoolean("change_permission"),
                acl.permissionBoolean("is_inherited"), rules,
                FilePermissionOwner(owner.requiredPermissionText("name"), owner.requiredPermissionText("type"),
                    owner.requiredPermissionText("value"), editable && access().administrator && owner.permissionBoolean("hasPrivilege")),
                null, null, null)
        }
        val mode = perm["posix"]?.permissionInteger()?.toString()?.padStart(3, '0')
            ?.takeIf(::validFilePermissionMode) ?: throw permissionFailure()
        val owner = additional["owner"] as? JsonObject ?: throw permissionFailure()
        return FilePermissionSnapshot(target, resolved, false, editable && access().administrator, false, emptyList(), null,
            mode, owner.requiredPermissionText("user"), owner.requiredPermissionText("group"))
    }
}

internal const val PERMISSION_ACL_API = "SYNO.Core.ACL"
internal const val PERMISSION_PROPERTY_API = "SYNO.FileStation.Property"
internal fun permissionTargetEditable(target: FileItem) = isFileMutationPath(target.path) &&
    target.path.drop(1).split('/').size >= 2 && isNormalFileMountType(target.mountPointType) && "#recycle" !in target.path.split('/')
internal fun permissionPathsOverlap(left: String, right: String) = left == right || left.startsWith("$right/") || right.startsWith("$left/")

internal fun parsePermissionRule(value: JsonElement): FileACLRule {
    val row = value as? JsonObject ?: throw permissionFailure()
    val rights = row["permission"] as? JsonObject ?: throw permissionFailure()
    val inheritance = row["inherit"] as? JsonObject ?: throw permissionFailure()
    if (rights.keys != FileACLRight.entries.map { it.key }.toSet() ||
        inheritance.keys != FileACLInheritance.entries.map { it.key }.toSet()) throw permissionFailure()
    val level = row["level"]?.permissionInteger()?.takeIf { it in 0..Int.MAX_VALUE }?.toInt() ?: throw permissionFailure()
    return FileACLRule(row.requiredPermissionText("owner_type"), row.requiredPermissionText("owner_name"),
        row["owner_id"]?.takeUnless { it is JsonNull }?.permissionInteger(),
        row["owner_is_internal"]?.takeUnless { it is JsonNull }?.let { row.permissionBoolean("owner_is_internal") },
        FileACLEffect.entries.singleOrNull { it.key == row.permissionText("permission_type") } ?: throw permissionFailure(),
        FileACLRight.entries.filterTo(mutableSetOf()) { rights.permissionBoolean(it.key) },
        FileACLInheritance.entries.filterTo(mutableSetOf()) { inheritance.permissionBoolean(it.key) }, level)
}

internal fun permissionRulePayload(rule: FileACLRule) = buildJsonObject {
    put("owner_type", rule.ownerType); put("owner_name", rule.ownerName)
    rule.ownerId?.let { put("owner_id", it) }; put("permission_type", rule.effect.key)
    putJsonObject("permission") { FileACLRight.entries.forEach { put(it.key, it in rule.rights) } }
    putJsonObject("inherit") { FileACLInheritance.entries.forEach { put(it.key, it in rule.inheritance) } }
}
internal fun JsonObject.permissionBoolean(key: String): Boolean = (this[key] as? JsonPrimitive)
    ?.takeUnless { it.isString }?.booleanOrNull ?: throw permissionFailure()
internal fun JsonElement.permissionInteger(): Long = (this as? JsonPrimitive)
    ?.takeUnless { it.isString }?.longOrNull ?: throw permissionFailure()
internal fun JsonObject.permissionText(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull
internal fun JsonObject.requiredPermissionText(key: String) = permissionText(key) ?: throw permissionFailure()
internal fun permissionStrings(values: List<String>) = JsonArray(values.map(::JsonPrimitive)).toString()
internal fun permissionFailure() = DsmFailure(null, "Permissions could not be read", "Refresh and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
internal fun permissionChanged() = DsmFailure(null, "Permissions changed", "Refresh and make your changes again.", kind = DsmErrorKind.FILE_PERMISSIONS_CHANGED)
internal fun permissionDenied() = DsmFailure(null, "Permissions cannot be changed", "Ask the NAS administrator for access.", kind = DsmErrorKind.PERMISSION_DENIED)
internal fun permissionPending() = DsmFailure(null, "Related permissions are still changing",
    "Open the item from the earlier change and refresh its result.", kind = DsmErrorKind.FILE_PERMISSIONS_PENDING)
