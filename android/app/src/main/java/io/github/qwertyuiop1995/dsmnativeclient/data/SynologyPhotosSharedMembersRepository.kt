package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.array
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.boolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.obj
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.optionalBoolean
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.positive
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 成员与目录组合保存共用管理互斥。目录草稿不临时授予NAS权限，恢复从不补发。 */
internal class SynologyPhotosSharedMembersRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val capability: (String, Int, SynologyPhotoSpace?) -> ApiCapability,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val refreshOwnSettings: suspend () -> Unit,
) {
    private val shared = SynologyPhotoSpace.SHARED
    private suspend fun check(owner: SynologyPhotosMutationAccess) {
        currentCoroutineContext().ensureActive(); checkAccess(owner, null)
    }
    private suspend fun administrator(owner: SynologyPhotosMutationAccess, enabled: Boolean = false): Boolean {
        check(owner); capability("UserInfo", 1, null); capability("Setting.TeamSpace", 1, null)
        val me = read("UserInfo", 1, "me", emptyMap(), null)
        if (!me.boolean("enabled") || me.optionalBoolean("is_admin") != true || me.positive("id") != owner.userId) denied()
        val active = read("Setting.TeamSpace", 1, "get", emptyMap(), null).boolean("enabled")
        check(owner); if (enabled && !active) denied()
        return active
    }
    suspend fun state(): SynologyPhotoSharedMembers = state(identity())
    private suspend fun state(owner: SynologyPhotosMutationAccess): SynologyPhotoSharedMembers {
        val enabled = administrator(owner)
        // 网络层已将直接数组data规范为_array，此处不能猜成普通list容器。
        val raw = read("Setting.TeamSpace", 1, "list_permission", emptyMap(), null)["_array"] as? JsonArray ?: invalid()
        val members = raw.map { SynologyPhotoSharedMembersCodec.member(it.obj()) }
        if (members.map { it.grant.id }.distinct().size != members.size) invalid()
        check(owner)
        return SynologyPhotoSharedMembers(SynologyPhotoSharedMembersSnapshot(owner.profileId, owner.userId, enabled, members.map { it.grant }), members)
    }
    suspend fun candidates(): List<SynologyPhotoShareRecipient> = candidates(identity())
    private suspend fun candidates(owner: SynologyPhotosMutationAccess): List<SynologyPhotoShareRecipient> {
        administrator(owner, enabled = true); capability("Sharing.Misc", 1, null)
        val values = read("Sharing.Misc", 1, "list_user_group", emptyMap(), null).list().map(SynologyPhotoSharingCodec::recipient)
        if (values.map { it.id }.distinct().size != values.size) invalid()
        check(owner); return values
    }
    suspend fun folders(member: SynologyPhotoShareMemberId): List<SynologyPhotoMemberFolder> = folders(member, identity())
    private suspend fun folders(member: SynologyPhotoShareMemberId, owner: SynologyPhotosMutationAccess): List<SynologyPhotoMemberFolder> {
        if (!SynologyPhotoSharedMembersCodec.valid(member)) invalid()
        administrator(owner, enabled = true); capability("Browse.Folder", 2, shared)
        val root = read("Browse.Folder", 2, "get", emptyMap(), shared).obj("folder").positive("id")
        val result = mutableListOf<SynologyPhotoMemberFolder>(); val seen = mutableSetOf<Long>()
        suspend fun pages(parent: SynologyPhotoMemberFolder?) {
            val parentId = parent?.snapshot?.id ?: root; val depth = if (parent == null) 0 else 1
            var offset = 0
            while (true) {
                check(owner)
                if (parent != null) {
                    val raw = read("Browse.Folder", 2, "get", json("id" to parentId, "additional" to array("sharing_info")), shared).obj("folder")
                    if (SynologyPhotoSharedMembersCodec.folder(raw, root, root, 0, member) != parent) changed()
                }
                val values = read("Browse.Folder", 2, "list", json("id" to parentId, "offset" to offset, "limit" to 200,
                    "sort_by" to "filename", "sort_direction" to "asc", "additional" to array("sharing_info")), shared).list()
                if (values.size > 200) invalid()
                for (raw in values) {
                    val folder = SynologyPhotoSharedMembersCodec.folder(raw, root, parentId, depth, member)
                    if (!seen.add(folder.snapshot.id) || parent != null && folder.path.substringBeforeLast('/') != parent.path) changed()
                    result += folder
                }
                check(owner)
                if (values.size < 200) break
                offset = Math.addExact(offset, values.size)
            }
        }
        pages(null)
        result.toList().forEach { pages(it) }
        check(owner); return result
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val value = row.sharedMembers ?: invalid(); SynologyPhotoSharedMembersCodec.validate(value)
        if (!state(owner).snapshot.sameMembers(value.original)) changed()
        val before = value.original.members.mapTo(mutableSetOf()) { it.id }
        val added = value.desired.filter { it.id !in before }
        if (added.isNotEmpty()) {
            val available = candidates(owner).associateBy { it.id }
            if (added.any { grant -> available[grant.id]?.let { it.id.type != "group" || it.name != "administrators" } != true }) denied()
        }
        value.folders.forEach { edit ->
            if (folders(edit.member, owner).associate { it.snapshot.id to it.snapshot } != edit.original.associateBy { it.id }) changed()
        }
        SynologyPhotoSharedMembersCodec.steps(value).forEach { capability(it.api, 1, it.space) }
        // 候选或完整目录扫描可能较慢，最后再次确认原成员条件仍成立。
        if ((added.isNotEmpty() || value.folders.isNotEmpty()) && !state(owner).snapshot.sameMembers(value.original)) changed()
        check(owner)
    }
    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        prepare(input, owner)
        var row = input
        SynologyPhotoSharedMembersCodec.steps(input.sharedMembers!!).forEachIndexed { index, step ->
            administrator(owner, enabled = true); check(owner)
            var value = row.sharedMembers!!
            row = row.copy(sharedMembers = value.copy(attempted = value.attempted + index)); persist(row)
            try { write(step.api, 1, step.method, step.fields, step.space) }
            catch (error: DsmFailure) {
                // 结构化失败也可能部分写入；仅记录事实，review仍按实际权限读取。
                value = row.sharedMembers!!
                row = row.copy(sharedMembers = value.copy(rejected = value.rejected + index)); persist(row)
                throw error
            }
            value = row.sharedMembers!!
            row = row.copy(sharedMembers = value.copy(acknowledged = value.acknowledged + index)); persist(row)
        }
        return row
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumCheckpoint {
        val value = row.sharedMembers!!; val steps = SynologyPhotoSharedMembersCodec.steps(value)
        val actual = state(owner).snapshot
        val before = value.original.members.associateBy { it.id }; val desired = value.desired.associateBy { it.id }
        val current = actual.members.associateBy { it.id }
        val changedMembers = (before.keys + desired.keys).filter { before[it] != desired[it] }
        val matched = mutableSetOf<Int>(); val loaded = mutableMapOf<Int, Map<Long, SynologyPhotoMemberFolderSnapshot>>()
        for (index in value.attempted.sorted()) {
            val step = steps[index]
            if (step.kind == SynologyPhotoSharedMembersCodec.Kind.MEMBERS) {
                if (actual.enabled && changedMembers.all { current[it] == desired[it] }) matched += index
                continue
            }
            val edit = value.folders[step.editIndex]
            val folders = loaded[step.editIndex] ?: folders(edit.member, owner).associate { it.snapshot.id to it.snapshot }.also { loaded[step.editIndex] = it }
            fun matches(folder: SynologyPhotoMemberFolderSnapshot, expected: String?): Boolean {
                val now = folders[folder.id] ?: return false
                return now.identity == folder.identity && now.privacy == folder.privacy && now.known && now.effectiveLevel() == folder.effectiveLevel(expected)
            }
            if (step.kind == SynologyPhotoSharedMembersCodec.Kind.ALL_FOLDERS) {
                val following = steps.indices.firstOrNull { steps[it].editIndex == step.editIndex && steps[it].kind == SynologyPhotoSharedMembersCodec.Kind.FOLDERS }
                if (folders.keys == edit.original.mapTo(mutableSetOf()) { it.id } && edit.original.all {
                    matches(it, edit.expectedRole(it, false)) || following in value.attempted && matches(it, edit.expectedRole(it))
                }) matched += index
            } else {
                val direct = edit.changes.mapTo(mutableSetOf()) { it.folderId }
                val affected = edit.original.filter { it.id in direct || it.depth == 1 && it.parentId in direct && edit.expectedRole(it) != edit.expectedRole(it, false) }
                if (affected.all { matches(it, edit.expectedRole(it)) }) matched += index
            }
        }
        val phase = when {
            matched == steps.indices.toSet() -> SynologyPhotoAlbumPhase.COMPLETED
            value.attempted.all { it in matched || it in value.rejected } -> SynologyPhotoAlbumPhase.PARTIAL
            else -> SynologyPhotoAlbumPhase.PENDING
        }
        check(owner)
        if (phase != SynologyPhotoAlbumPhase.PENDING) refreshOwnSettings()
        // 设置读取已经核对身份；应用本人新角色后不能再拿旧角色快照否定正常权限变化。
        currentCoroutineContext().ensureActive()
        return row.copy(phase = phase, sharedMembers = value.copy(completed = value.completed + matched))
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
