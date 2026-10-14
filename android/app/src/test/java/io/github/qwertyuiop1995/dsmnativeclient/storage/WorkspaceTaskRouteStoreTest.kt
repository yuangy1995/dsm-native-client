package io.github.qwertyuiop1995.dsmnativeclient.storage

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import io.github.qwertyuiop1995.dsmnativeclient.opaqueObjectExternalWorkspaceUri
import org.junit.Assert.*
import org.junit.Test

class WorkspaceTaskRouteStoreTest {
    private val store = SecureProfileStore(MemoryPreferences())
    private val profile = NasProfile("connection-a", "NAS", "https://nas.example.invalid", "account-a")
    private fun connect(value: NasProfile = profile): WorkspaceOwner = store.commitConnection(
        store.connectionAttempt(value.id), value, DsmSession(value.id, "synthetic-session"), null, false)

    @Test fun `任务通知绑定原账号且不同任务不共用令牌`() {
        val owner = connect()
        store.bindRecord(WorkspaceRecordKind.DOWNLOAD, "synthetic-a", owner)
        store.bindRecord(WorkspaceRecordKind.DOWNLOAD, "synthetic-b", owner)
        val a = requireNotNull(store.issueLocalTransferTarget(WorkspaceRecordKind.DOWNLOAD, "synthetic-a"))
        val b = requireNotNull(store.issueLocalTransferTarget(WorkspaceRecordKind.DOWNLOAD, "synthetic-b"))
        assertNotEquals(a, b)
        assertEquals(a, store.issueLocalTransferTarget(WorkspaceRecordKind.DOWNLOAD, "synthetic-a"))
        assertEquals(OpaqueWorkspaceTarget.LocalTransfer(LocalTransferKind.DOWNLOAD, "synthetic-a"), store.opaqueWorkspaceRoute(a)?.target)
        val uri = requireNotNull(opaqueObjectExternalWorkspaceUri(a))
        listOf(profile.id, profile.address, profile.username, "synthetic-a").forEach { assertFalse(uri.contains(it)) }
    }

    @Test fun `退出后仍可签发历史任务通知但不能签发新的业务页`() {
        val owner = connect()
        store.bindRecord(WorkspaceRecordKind.UPLOAD, "upload", owner)
        store.clearSession(profile.id)
        assertNotNull(store.profileForOwner(owner))
        assertNotNull(store.issueLocalTransferTarget(WorkspaceRecordKind.UPLOAD, "upload"))
        assertNull(store.issueOpaqueWorkspaceTarget(profile.id, OpaqueWorkspaceTarget.Page(WorkspacePage.FILES), owner))
        assertNull(store.issueLocalTransferTarget(WorkspaceRecordKind.UPLOAD, "unbound"))
        assertNull(store.issueLocalTransferTarget(WorkspaceRecordKind.PHOTO_SOURCE, "upload"))
    }

    @Test fun `新账号不能继承旧任务通知或固定页面`() {
        val owner = connect()
        store.bindRecord(WorkspaceRecordKind.DOWNLOAD, "old-task", owner)
        val task = requireNotNull(store.issueLocalTransferTarget(WorkspaceRecordKind.DOWNLOAD, "old-task"))
        val page = requireNotNull(store.issueOpaqueWorkspaceTarget(profile.id, OpaqueWorkspaceTarget.Page(WorkspacePage.CHAT), owner))
        connect(profile.copy(username = "account-b"))
        assertNull(store.profileForOwner(owner))
        assertNull(store.opaqueWorkspaceRoute(task)); assertNull(store.opaqueWorkspaceRoute(page))
        assertNull(store.issueLocalTransferTarget(WorkspaceRecordKind.DOWNLOAD, "old-task"))
    }

    @Test fun `重命名和同账号重新登录保留页面与任务归属`() {
        val owner = connect()
        store.bindRecord(WorkspaceRecordKind.VMM_IMPORT, "image", owner)
        val token = requireNotNull(store.issueLocalTransferTarget(WorkspaceRecordKind.VMM_IMPORT, "image"))
        assertTrue(store.renameProfile(profile, "Renamed NAS"))
        assertEquals("Renamed NAS", store.profileForOwner(owner)?.name)
        store.clearSession(profile.id)
        connect(profile.copy(name = "Renamed NAS"))
        assertNotNull(store.opaqueWorkspaceRoute(token))
        assertEquals(token, store.issueLocalTransferTarget(WorkspaceRecordKind.VMM_IMPORT, "image"))
    }
    @Test fun `大批备份任务的通知不会淘汰已复制的页面链接`() {
        val owner = connect()
        val page = requireNotNull(store.issueOpaqueWorkspaceTarget(profile.id, OpaqueWorkspaceTarget.Page(WorkspacePage.FILES), owner))
        var firstTask: String? = null
        repeat(MAX_OPAQUE_WORKSPACE_ROUTES_PER_PROFILE + 1) { index ->
            val id = "backup-$index"
            store.bindRecord(WorkspaceRecordKind.UPLOAD, id, owner)
            val token = store.issueLocalTransferTarget(WorkspaceRecordKind.UPLOAD, id)
            assertNotNull(token)
            if (index == 0) firstTask = token
        }
        assertNotNull(store.opaqueWorkspaceRoute(page))
        assertNull(store.opaqueWorkspaceRoute(requireNotNull(firstTask)))
    }

}
