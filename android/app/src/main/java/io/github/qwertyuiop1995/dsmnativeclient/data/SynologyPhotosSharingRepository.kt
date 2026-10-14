package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.invalid
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.json
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.list
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotosCodec.text
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 相册通道内部的分享步骤；互斥、持久化和恢复仍由原相册通道统一管理。 */
internal class SynologyPhotosSharingRepository(
    private val identity: () -> SynologyPhotosMutationAccess,
    private val uid: () -> JsonPrimitive?,
    private val checkAccess: suspend (SynologyPhotosMutationAccess, SynologyPhotoSpace?) -> Unit,
    private val album: suspend (Long) -> Pair<JsonObject, SynologyPhotoAlbumSnapshot>,
    private val read: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
    private val write: suspend (String, Int, String, Map<String, JsonElement>, SynologyPhotoSpace?) -> JsonObject,
) {
    suspend fun state(id: Long): SynologyPhotoAlbumSharing = state(id, identity())
    private suspend fun state(id: Long, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumSharing {
        checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        val (raw, value) = album(id)
        if (value.ownerUserId != owner.userId || !value.ordinary && !value.conditional && !value.recoverable && !value.temporaryShare) denied()
        return SynologyPhotoSharingCodec.decode(raw, value).also { checkAccess(owner, SynologyPhotoSpace.PERSONAL) }
    }
    suspend fun recipients(): List<SynologyPhotoShareRecipient> = recipients(identity())
    private suspend fun recipients(owner: SynologyPhotosMutationAccess): List<SynologyPhotoShareRecipient> {
        checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        val me = uid()?.takeIf(SynologyPhotoSharingCodec::validId) ?: invalid()
        val values = read("Sharing.Misc", 1, "list_user_group", json("team_space_sharable_list" to false), null)
            .list().map(SynologyPhotoSharingCodec::recipient)
        if (values.map { it.id }.distinct().size != values.size) invalid()
        checkAccess(owner, SynologyPhotoSpace.PERSONAL)
        return values.filter { it.id.type != "user" || it.id.value != me }
    }
    suspend fun prepare(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess) {
        val change = row.sharing ?: invalid()
        SynologyPhotoSharingCodec.validate(change, row.album?.type == "condition")
        val current = state(row.album!!.id, owner)
        if (current.album != row.album || current.snapshot != change.original) changed()
        change.members?.let { members ->
            val before = SynologyPhotoSharingCodec.roles(change.original.members ?: invalid())
            val changedUsers = members.filter { before[it.id] != it.role && it.id.type == "user" }
            if (changedUsers.isNotEmpty()) {
                val me = uid()?.takeIf(SynologyPhotoSharingCodec::validId) ?: invalid()
                if (changedUsers.any { it.id.value == me }) denied()
            }
            val added = members.filter { it.id !in before }
            if (added.isNotEmpty()) {
                val candidates = recipients(owner).mapTo(mutableSetOf()) { it.id }
                if (added.any { it.id !in candidates }) denied()
            }
        }
        checkAccess(owner, SynologyPhotoSpace.PERSONAL)
    }
    fun requirePassword(row: SynologyPhotoAlbumCheckpoint, password: String?) {
        when (row.sharing?.password ?: invalid()) {
            SynologyPhotoSharingPassword.SET -> if (password.isNullOrEmpty()) invalid()
            SynologyPhotoSharingPassword.REMOVE -> if (password != null && password.isNotEmpty()) invalid()
            SynologyPhotoSharingPassword.UNCHANGED -> if (password != null) invalid()
        }
    }
    suspend fun execute(input: SynologyPhotoAlbumCheckpoint, password: String?, owner: SynologyPhotosMutationAccess,
        persist: (SynologyPhotoAlbumCheckpoint) -> Unit): SynologyPhotoAlbumCheckpoint {
        var row = input
        val change = row.sharing!!
        val current = state(row.album!!.id, owner)
        if (current.album != row.album || current.snapshot != change.original) changed()
        fun save(next: SynologyPhotoAlbumCheckpoint) { persist(next); row = next }
        val edits = SynologyPhotoSharingCodec.modifiesProtectionOrMembers(change)
        if (change.access == current.snapshot.access && !edits &&
            (change.access == SynologyPhotoLinkAccess.DISABLED || current.url != null)) {
            save(row.copy(sharingNoChanges = true)); return row
        }
        suspend fun shared(enabled: Boolean): JsonObject {
            currentCoroutineContext().ensureActive(); checkAccess(owner, SynologyPhotoSpace.PERSONAL)
            return write("Sharing.Passphrase", 1, "set_shared", json("policy" to "album", "album_id" to row.album!!.id, "enabled" to enabled), null)
        }
        val closed = shared(false)
        if (change.access == SynologyPhotoLinkAccess.DISABLED && !edits) return row
        val passphrase = closed.text("passphrase").takeIf { it.isNotEmpty() } ?: invalid()
        val afterClose = state(row.album!!.id, owner)
        if (afterClose.album != row.album || afterClose.snapshot.access != SynologyPhotoLinkAccess.DISABLED ||
            !protectionsAndMembers(row.copy(sharing = change.copy(members = null, expiration = null,
                password = SynologyPhotoSharingPassword.UNCHANGED)), afterClose)) return row
        val changes = SynologyPhotoSharingCodec.changes(change)
        if (changes.isNotEmpty() || SynologyPhotoSharingCodec.expirationChanged(change) || change.password != SynologyPhotoSharingPassword.UNCHANGED) {
            val fields = json("passphrase" to passphrase).toMutableMap()
            if (changes.isNotEmpty()) fields["permission"] = JsonArray(changes)
            if (SynologyPhotoSharingCodec.expirationChanged(change)) fields["expiration"] = JsonPrimitive(change.expiration!!)
            when (change.password) {
                SynologyPhotoSharingPassword.SET -> fields["password"] = JsonPrimitive(password ?: invalid())
                SynologyPhotoSharingPassword.REMOVE -> fields["password"] = JsonPrimitive("")
                SynologyPhotoSharingPassword.UNCHANGED -> Unit
            }
            currentCoroutineContext().ensureActive(); checkAccess(owner, SynologyPhotoSpace.PERSONAL)
            save(row.copy(sharingUpdateAttempted = true))
            write("Sharing.Passphrase", 1, "update", fields, null)
            checkAccess(owner, SynologyPhotoSpace.PERSONAL)
            save(row.copy(sharingUpdateAcknowledged = true))
        }
        if (change.access != SynologyPhotoLinkAccess.DISABLED) {
            val updated = state(row.album!!.id, owner)
            if (updated.album != row.album || updated.snapshot.access != SynologyPhotoLinkAccess.DISABLED ||
                updated.linkPolicy != change.access || !protectionsAndMembers(row, updated)) return row
            currentCoroutineContext().ensureActive(); checkAccess(owner, SynologyPhotoSpace.PERSONAL)
            // 保存尝试状态后才能开启；任何异常或冷恢复均不继续这一步。
            save(row.copy(sharingEnableAttempted = true))
            shared(true)
        }
        return row
    }
    suspend fun review(row: SynologyPhotoAlbumCheckpoint, owner: SynologyPhotosMutationAccess): SynologyPhotoAlbumPhase {
        val change = row.sharing!!
        val current = state(row.album!!.id, owner)
        if (current.album != row.album) changed()
        val matches = protectionsAndMembers(row, current)
        if (change.access == SynologyPhotoLinkAccess.DISABLED && current.snapshot.access == SynologyPhotoLinkAccess.DISABLED &&
            (!SynologyPhotoSharingCodec.modifiesProtectionOrMembers(change) || matches)) return SynologyPhotoAlbumPhase.COMPLETED
        if (change.access != SynologyPhotoLinkAccess.DISABLED && !row.sharingEnableAttempted && !row.sharingNoChanges &&
            current.snapshot.access == SynologyPhotoLinkAccess.DISABLED) return SynologyPhotoAlbumPhase.PARTIAL
        if ((row.sharingEnableAttempted || row.sharingNoChanges) && current.snapshot.access == change.access && matches &&
            current.url != null) return SynologyPhotoAlbumPhase.COMPLETED
        return SynologyPhotoAlbumPhase.PENDING
    }
    private fun protectionsAndMembers(row: SynologyPhotoAlbumCheckpoint, current: SynologyPhotoAlbumSharing): Boolean {
        val change = row.sharing!!; val before = change.original; val actual = current.snapshot
        val members = change.members ?: before.members
        val matchingMembers = members == null || actual.members?.let { SynologyPhotoSharingCodec.roles(it) == SynologyPhotoSharingCodec.roles(members) } == true
        val expiration = change.expiration?.let { actual.expiration == it } ?: (before.expirationDigest == actual.expirationDigest)
        val password = when (change.password) {
            SynologyPhotoSharingPassword.SET -> row.sharingUpdateAcknowledged && actual.hasPassword == true
            SynologyPhotoSharingPassword.REMOVE -> actual.hasPassword == false
            SynologyPhotoSharingPassword.UNCHANGED -> actual.hasPassword == before.hasPassword
        }
        return matchingMembers && expiration && password
    }
    private fun denied(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION)
    private fun changed(): Nothing = throw SynologyPhotoFailure(SynologyPhotoFailureKind.TARGET_CHANGED)
}
