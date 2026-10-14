package io.github.qwertyuiop1995.dsmnativeclient.data.files

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.security.MessageDigest
import java.util.UUID

/** 保存不可逆的预期结果摘要；记录不能还原权限表或重建 set 请求。 */
@Serializable
internal data class FilePermissionExpectation(
    val identity: String, val metadata: String, val knownRules: List<String>, val newRules: List<String>, val inherited: List<String>,
) {
    fun matches(snapshot: FilePermissionSnapshot): Boolean {
        if (identity != permissionIdentity(snapshot) || metadata != permissionMetadata(snapshot)) return false
        if (inherited != snapshot.inheritedRules.map { permissionRuleHash(it, true, true) }.sorted()) return false
        val remaining = snapshot.explicitRules.toMutableList()
        for (hash in knownRules) {
            val index = remaining.indexOfFirst { permissionRuleHash(it, true) == hash }
            if (index < 0) return false
            remaining.removeAt(index)
        }
        return newRules.sorted() == remaining.map { permissionRuleHash(it, false) }.sorted()
    }
}
internal fun FilePermissionChange.expectation(): FilePermissionExpectation {
    val expected = baseline.copy(rules = (explicitRules ?: baseline.explicitRules) + baseline.inheritedRules,
        posixMode = posixMode ?: baseline.posixMode,
        posixOwner = owner?.name.takeIf { !baseline.isACL } ?: baseline.posixOwner,
        posixGroup = group?.name ?: baseline.posixGroup,
        owner = if (baseline.isACL && owner != null) baseline.owner?.copy(name = owner.name, type = owner.kind.name.lowercase()) else baseline.owner)
    val rules = expected.explicitRules
    return FilePermissionExpectation(permissionIdentity(expected), permissionMetadata(expected),
        rules.filter { it.ownerId != null }.map { permissionRuleHash(it, true) },
        rules.filter { it.ownerId == null }.map { permissionRuleHash(it, false) },
        expected.inheritedRules.map { permissionRuleHash(it, true, true) }.sorted())
}
private fun permissionIdentity(snapshot: FilePermissionSnapshot) = permissionHash(listOf(snapshot.target.path,
    snapshot.resolvedPath, snapshot.target.isDirectory.toString(), snapshot.isACL.toString()))
private fun permissionMetadata(snapshot: FilePermissionSnapshot) = permissionHash(if (snapshot.isACL)
    listOf(snapshot.isInherited.toString(), snapshot.owner?.name.orEmpty(), snapshot.owner?.type.orEmpty())
    else listOf(snapshot.posixMode.orEmpty(), snapshot.posixOwner.orEmpty(), snapshot.posixGroup.orEmpty()))
private fun permissionRuleHash(rule: FileACLRule, includeId: Boolean, inherited: Boolean = false) = permissionHash(listOf(
    rule.ownerType, rule.ownerName, if (includeId) rule.ownerId?.toString().orEmpty() else "",
    rule.effect.key, FileACLRight.entries.filter { it in rule.rights }.joinToString(",") { it.key },
    FileACLInheritance.entries.filter { it in rule.inheritance }.joinToString(",") { it.key },
    rule.level.toString(), if (inherited) rule.isInternal?.toString().orEmpty() else ""))
private fun permissionHash(values: List<String>) = MessageDigest.getInstance("SHA-256")
    .digest(permissionStrings(values).toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

@Serializable
internal data class FilePermissionPending(
    val schemaVersion: Int = 1, val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner,
    val path: String, val isACL: Boolean, val recursive: Boolean, val expected: FilePermissionExpectation,
    val taskId: String? = null, val acknowledged: Boolean = false, val finished: Boolean = false, val partialFailure: Boolean = false,
)

/** 同步写前日志与独立版本键；损坏或写盘失败一律关闭新修改，不清空未知记录。 */
internal class FilePermissionRecoveryStore(private val preferences: SharedPreferences) {
    constructor(context: Context) : this(EncryptedSharedPreferences.create(context, "lanstash_permission_recovery",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM))
    private val json = Json { ignoreUnknownKeys = true }
    fun pending(owner: WorkspaceOwner): List<FilePermissionPending> = synchronized(lock) {
        val raw = preferences.getString(key(owner), null) ?: return@synchronized emptyList()
        val rows = runCatching { json.decodeFromString<List<FilePermissionPending>>(raw) }.getOrElse { throw workspaceStorageFailure() }
        if (rows.any { it.schemaVersion != 1 || !it.owner.hasSameIdentity(owner) || !isFileMutationPath(it.path) ||
                it.taskId?.isBlank() == true } || rows.map { it.path }.distinct().size != rows.size || rows.map { it.id }.distinct().size != rows.size) throw workspaceStorageFailure()
        rows
    }
    fun begin(record: FilePermissionPending) = synchronized(lock) {
        val rows = pending(record.owner)
        if (rows.any { permissionPathsOverlap(it.path, record.path) || it.id == record.id }) throw permissionPending()
        save(record.owner, rows + record)
    }
    fun update(record: FilePermissionPending) = synchronized(lock) {
        val rows = pending(record.owner)
        if (rows.none { it.id == record.id }) throw workspaceStorageFailure()
        save(record.owner, rows.map { if (it.id == record.id) record else it })
    }
    fun finish(record: FilePermissionPending) = synchronized(lock) {
        save(record.owner, pending(record.owner).filterNot { it.id == record.id })
    }
    fun removeProfile(profileId: String) = synchronized(lock) {
        val keys = preferences.all.keys.filter { it.startsWith("permissions_v1_") && runCatching {
            String(java.util.Base64.getUrlDecoder().decode(it.removePrefix("permissions_v1_")), Charsets.UTF_8).substringBefore('\u0000') == profileId
        }.getOrDefault(false) }
        if (keys.isNotEmpty()) {
            val editor = preferences.edit(); keys.forEach(editor::remove)
            if (!editor.commit()) throw workspaceStorageFailure()
        }
    }
    private fun save(owner: WorkspaceOwner, rows: List<FilePermissionPending>) {
        val editor = preferences.edit()
        if (rows.isEmpty()) editor.remove(key(owner)) else editor.putString(key(owner), json.encodeToString(rows))
        if (!editor.commit()) throw workspaceStorageFailure()
    }
    private fun key(owner: WorkspaceOwner) = "permissions_v1_" + java.util.Base64.getUrlEncoder().withoutPadding()
        .encodeToString((owner.profileId + "\u0000" + owner.identityRevision).toByteArray(Charsets.UTF_8))
    private companion object { val lock = Any() }
}
