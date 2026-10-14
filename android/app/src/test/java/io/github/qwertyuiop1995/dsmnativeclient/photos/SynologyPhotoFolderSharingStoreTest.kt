package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoFolderSharingStoreTest {
    private val owner = WorkspaceOwner("folder-sharing-store", "identity", "session")
    private val preferences = MemoryPreferences()
    private val store = SynologyPhotoAlbumStore(preferences)
    private fun row() = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41,
        action = SynologyPhotoAlbumAction.SHARE_FOLDER, folderSharing = SynologyPhotoFolderSharingCheckpoint(SynologyPhotoFolderSharingChange(
            SynologyPhotoFolderSharingSnapshot(SynologyPhotoFolderSnapshot(9, 1, "Synthetic", "/Synthetic", SynologyPhotoSpace.SHARED), "a".repeat(64),
                SynologyPhotoFolderLinkAccess.INVITED, listOf(SynologyPhotoShareGrant(SynologyPhotoShareMemberId("group", JsonPrimitive("51")), "view")), false, true, false),
            SynologyPhotoFolderLinkAccess.DOWNLOAD, password = SynologyPhotoSharingPassword.SET, appliesToSubfolders = true))))
    @Test fun `每步事实只前进恢复固定原意图并隔离账号`() {
        val row = row(); store.begin(row)
        val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING)
        store.save(row.id, owner, 41, submitting)
        val bound = submitting.copy(folderSharing = submitting.folderSharing!!.copy(updateAttempted = true, updateAcknowledged = true, configAttempted = true))
        store.save(row.id, owner, 41, bound)
        for (changed in listOf(bound.folderSharing!!.copy(updateAttempted = false), bound.folderSharing.copy(updateAcknowledged = false),
            bound.folderSharing.copy(configAttempted = false), bound.folderSharing.copy(rejected = true),
            bound.folderSharing.copy(change = bound.folderSharing.change.copy(access = SynologyPhotoFolderLinkAccess.VIEW)),
            bound.folderSharing.copy(change = bound.folderSharing.change.copy(original = bound.folderSharing.change.original.copy(revision = "b".repeat(64))))))
            reject { store.save(row.id, owner, 41, bound.copy(folderSharing = changed)) }
        val restored = SynologyPhotoAlbumStore(preferences).records(owner.copy(sessionGeneration = "new"), 41).single().checkpoint
        assertEquals(bound.copy(phase = SynologyPhotoAlbumPhase.PENDING), restored)
        assertTrue(store.records(owner.copy(identityRevision = "other"), 41).isEmpty()); assertTrue(store.records(owner, 42).isEmpty())
        reject { store.discard(store.get(row.id, owner, 41)) }
        val done = restored.copy(phase = SynologyPhotoAlbumPhase.COMPLETED); store.save(row.id, owner, 41, done)
        reject { store.save(row.id, owner, 41, restored) }; store.discard(store.get(row.id, owner, 41)); assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `目录权限未决阻止其他管理操作而明确结束后解除`() {
        val row = row(); store.begin(row)
        val submitting = row.checkpoint.copy(phase = SynologyPhotoAlbumPhase.SUBMITTING); store.save(row.id, owner, 41, submitting)
        val album = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Synthetic album"))
        reject { store.begin(album) }
        store.save(row.id, owner, 41, submitting.copy(phase = SynologyPhotoAlbumPhase.PARTIAL, folderSharing = submitting.folderSharing!!.copy(rejected = true)))
        store.begin(album); assertEquals(2, store.records(owner, 41).size)
    }
    @Test fun `未确认回执不能伪造换密和子目录完成或非法动作字段`() {
        val row = row(); val checkpoint = row.checkpoint
        for (invalid in listOf(checkpoint.copy(phase = SynologyPhotoAlbumPhase.COMPLETED, folderSharing = checkpoint.folderSharing!!.copy(updateAttempted = true)),
            checkpoint.copy(folderSharing = checkpoint.folderSharing!!.copy(updateAcknowledged = true)),
            checkpoint.copy(folderSharing = checkpoint.folderSharing!!.copy(configAttempted = true)),
            checkpoint.copy(folder = SynologyPhotoFolderCheckpoint(checkpoint.folderSharing!!.change.original.folder)),
            checkpoint.copy(targets = listOf(SynologyPhotoEditTarget(SynologyPhoto(SynologyPhotoId(owner.profileId, SynologyPhotoSpace.SHARED, 1), "x", 1, 1.0, 1.0, 9, "photo")))))) {
            reject { store.begin(row.copy(checkpoint = invalid)) }
        }
        assertTrue(store.records(owner, 41).isEmpty())
    }
    @Test fun `序列化只含恢复必要身份与摘要不包含表单密码和显示资料`() {
        val row = row(); store.begin(row)
        val serialized = preferences.all.values.single().toString()
        assertFalse(serialized.contains("password\":\"Synthetic")); assertFalse(serialized.contains("sharing_link")); assertFalse(serialized.contains("recipients"))
        assertEquals(row, SynologyPhotoAlbumStore(preferences).records(owner, 41).single())
        assertFalse(row.toString().contains("Synthetic")); assertFalse(row.checkpoint.folderSharing.toString().contains("51"))
        // 既有记录没有新可选字段仍能读出，不覆盖旧字段结构。
        val old = SynologyPhotoAlbumRecord(owner = owner, checkpoint = SynologyPhotoAlbumCheckpoint(profileId = owner.profileId, userId = 41, action = SynologyPhotoAlbumAction.CREATE, name = "Old"))
        val json = Json { encodeDefaults = true }; val objectValue = Json.parseToJsonElement(json.encodeToString(old)).jsonObject
        val checkpoint = objectValue.getValue("checkpoint").jsonObject
        preferences.edit().clear().putString("photos_album_v1_${old.id}", JsonObject(objectValue + ("checkpoint" to JsonObject(checkpoint - "folderSharing"))).toString()).commit()
        assertEquals(old, store.records(owner, 41).single())
    }
    private fun reject(block: () -> Unit) { try { block(); fail("Expected storage rejection") } catch (_: SynologyPhotoAlbumFailure) {} }
}
