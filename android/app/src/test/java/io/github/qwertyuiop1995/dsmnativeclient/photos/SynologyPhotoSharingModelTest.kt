package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotoSharingModelTest {
    @Test fun `未知原权限保留条件相册只能选择查看下载且候选失败不清空已有成员`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); val api = Serving()
        val model = SynologyPhotoSharingModel(api, scope, {}, { true })
        try {
            model.initialize(original(conditional = true))
            val id = model.state.value.members!!.single().id
            model.role(id, "upload"); assertEquals("future-role", model.state.value.members!!.single().role)
            api.fail = true; model.selectMembers()!!.join()
            assertNotNull(model.state.value.error); assertEquals(1, model.state.value.members!!.size)
            assertEquals(listOf("view", "download"), model.state.value.roles)
            api.fail = false; model.selectMembers()!!.join(); model.add(api.recipient); model.add(api.recipient)
            assertEquals(2, model.state.value.members!!.size)
            assertEquals("future-role", model.state.value.members!!.first().role)
            model.role(api.recipient.id, "download"); assertEquals("download", model.state.value.members!!.last().role)
            model.remove(id); assertEquals(api.recipient.id, model.state.value.members!!.single().id)
            model.passwordMode(SynologyPhotoSharingPassword.SET); assertFalse(model.state.value.valid)
            model.password(" "); assertTrue(model.state.value.valid)
            model.passwordMode(SynologyPhotoSharingPassword.REMOVE); assertEquals("", model.state.value.password)
        } finally { scope.cancel() }
    }
    @Test fun `重置和权限失效后候选旧响应不能进入新表单`() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); val api = Serving()
        val entered = CompletableDeferred<Unit>(); val release = CompletableDeferred<Unit>()
        api.before = { withContext(NonCancellable) { entered.complete(Unit); release.await() } }
        var allowed = true
        val model = SynologyPhotoSharingModel(api, scope, {}, { allowed })
        try {
            model.initialize(original()); model.passwordMode(SynologyPhotoSharingPassword.SET); model.password("synthetic")
            val job = model.selectMembers()!!; entered.await(); model.reset(); release.complete(Unit); job.join()
            assertNull(model.state.value.original); assertNull(model.state.value.candidates); assertEquals("", model.state.value.password)
            model.initialize(original()); allowed = false
            model.access(SynologyPhotoLinkAccess.VIEW); model.passwordMode(SynologyPhotoSharingPassword.SET); model.expiration(9)
            assertNull(model.selectMembers()); assertEquals(SynologyPhotoLinkAccess.INVITED, model.state.value.access)
            assertEquals(SynologyPhotoSharingPassword.UNCHANGED, model.state.value.passwordMode); assertNull(model.state.value.expiration)
        } finally { release.complete(Unit); scope.cancel() }
    }
    private class Serving : SynologyPhotosServing {
        override val profileId = "synthetic"
        var fail = false; var before: suspend () -> Unit = {}
        val recipient = SynologyPhotoShareRecipient(SynologyPhotoShareMemberId("user", JsonPrimitive(52)), "Synthetic member")
        override suspend fun sharingRecipients(): List<SynologyPhotoShareRecipient> { before(); if (fail) throw IOException("synthetic"); return listOf(recipient) }
        override suspend fun access() = SynologyPhotoAccess(emptyList(), "synthetic")
        override suspend fun timeline(space: SynologyPhotoSpace, query: SynologyPhotoQuery?) = emptyList<SynologyPhotoDay>()
        override suspend fun photos(space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) = SynologyPhotoPage(emptyList(), offset, offset, false)
    }
    private fun original(conditional: Boolean = false): SynologyPhotoAlbumSharing {
        val recipient = SynologyPhotoShareRecipient(SynologyPhotoShareMemberId("group", JsonPrimitive("51")), "Synthetic legacy")
        return SynologyPhotoAlbumSharing(SynologyPhotoAlbumSnapshot(71, "Synthetic album", 41, if (conditional) "condition" else "normal", false, false),
            SynologyPhotoSharingSnapshot("a".repeat(64), SynologyPhotoLinkAccess.INVITED, listOf(SynologyPhotoShareGrant(recipient.id, "future-role")),
                false, null, "b".repeat(64)), listOf(recipient), null, SynologyPhotoLinkAccess.INVITED)
    }
}
