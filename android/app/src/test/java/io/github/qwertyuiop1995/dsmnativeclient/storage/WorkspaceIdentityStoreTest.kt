package io.github.qwertyuiop1995.dsmnativeclient.storage

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class WorkspaceIdentityStoreTest {
    private val preferences = MemoryPreferences()
    private val store = SecureProfileStore(preferences)
    private val profile = NasProfile("connection-a", "NAS", "https://nas.example.invalid", "account-a")
    private val session = DsmSession(profile.id, "synthetic-session", "synthetic-token", "synthetic-device")
    private fun connect(profile: NasProfile = this.profile, session: DsmSession = this.session) =
        store.commitConnection(store.connectionAttempt(profile.id), profile, session, "synthetic-password", true)
    private fun failure(kind: DsmErrorKind, action: () -> Unit) {
        assertEquals(kind, assertThrows(DsmFailure::class.java, action).kind)
    }

    @Test fun `显示名变更保留会话任务及界面偏好`() {
        val owner = connect()
        store.bindRecord(WorkspaceRecordKind.DOWNLOAD, "download-a", owner)
        store.saveWorkspaceUiState(profile.id, PersistedWorkspaceUiState(filePath = "/synthetic"), owner)
        assertTrue(store.renameProfile(profile, "Renamed"))
        store.requireCurrentOwner(owner)
        assertEquals("Renamed", store.savedConnectionForRecord(WorkspaceRecordKind.DOWNLOAD, "download-a").profile.name)
        assertEquals(session, store.session(profile.id))
        assertEquals("/synthetic", store.workspaceUiState(profile.id)?.filePath)
    }

    @Test fun `旧账号的重命名表单不能覆盖已更改的连接`() {
        connect()
        val changed = profile.copy(username = "account-b")
        connect(changed, session.copy(sid = "synthetic-b"))
        assertFalse(store.renameProfile(profile, "Old dialog name"))
        assertEquals(changed, store.profiles().single())
    }

    @Test fun `同一NAS不同账号不能继承任务或设备确认`() {
        val owner = connect()
        store.bindRecord(WorkspaceRecordKind.UPLOAD, "upload-a", owner)
        val changed = connect(profile.copy(username = "account-b"), session.copy(sid = "synthetic-b"))
        assertFalse(owner.hasSameIdentity(changed))
        failure(DsmErrorKind.WORKSPACE_CHANGED) { store.requireCurrentOwner(owner) }
        failure(DsmErrorKind.WORKSPACE_CHANGED) { store.savedConnectionForRecord(WorkspaceRecordKind.UPLOAD, "upload-a") }
        failure(DsmErrorKind.WORKSPACE_CHANGED) { store.bindRecord(WorkspaceRecordKind.UPLOAD, "upload-a", changed) }
    }

    @Test fun `地址端口改变都创建新身份但不猜测地址别名`() {
        val first = connect()
        val port = connect(profile.copy(port = 5443), session.copy(sid = "synthetic-port"))
        val address = connect(profile.copy(address = "https://other.example.invalid"), session.copy(sid = "synthetic-address"))
        assertFalse(first.hasSameIdentity(port)); assertFalse(port.hasSameIdentity(address))
        assertNotEquals(profile.workspaceIdentityFingerprint(), profile.copy(address = "NAS.EXAMPLE.INVALID").workspaceIdentityFingerprint())
    }

    @Test fun `重新登录同一账号可继续已绑定任务但旧请求失效`() {
        val first = connect()
        store.bindRecord(WorkspaceRecordKind.DOWNLOAD, "download-a", first)
        store.clearSession(profile.id)
        val second = connect(session = session.copy(sid = "synthetic-renewed"))
        assertTrue(first.hasSameIdentity(second)); assertNotEquals(first.sessionGeneration, second.sessionGeneration)
        failure(DsmErrorKind.WORKSPACE_CHANGED) { store.requireCurrentOwner(first) }
        assertEquals(second, store.savedConnectionForRecord(WorkspaceRecordKind.DOWNLOAD, "download-a").owner)
    }

    @Test fun `恢复未更改的会话不废弃既有任务执行器`() {
        val first = connect()
        val second = connect()
        assertEquals(first, second)
        store.requireCurrentOwner(first)
    }

    @Test fun `后完成的旧登录不能覆盖新连接`() {
        connect()
        val oldAttempt = store.connectionAttempt(profile.id)
        val newer = connect(profile.copy(username = "new-account"), session.copy(sid = "synthetic-new"))
        failure(DsmErrorKind.WORKSPACE_CHANGED) {
            store.commitConnection(oldAttempt, profile, session, "synthetic-password", true)
        }
        assertEquals(newer, store.currentOwner(profile.id))
        assertEquals("new-account", store.profiles().single().username)
    }

    @Test fun `退出后迟到的恢复不能重新激活会话`() {
        connect()
        val attempt = store.connectionAttempt(profile.id)
        store.clearSession(profile.id)
        failure(DsmErrorKind.WORKSPACE_CHANGED) { store.commitConnection(attempt, profile, session, "synthetic", true) }
        assertNull(store.session(profile.id)); assertNull(store.currentOwner(profile.id))
    }

    @Test fun `旧会话过期回调不能清除后来登录的会话`() {
        connect()
        val newerSession = session.copy(sid = "synthetic-new")
        connect(session = newerSession)
        assertFalse(store.clearSessionIfCurrent(profile.id, session))
        assertEquals(newerSession, store.session(profile.id))
    }

    @Test fun `不同连接同名账号独立退出`() {
        val first = connect()
        val other = profile.copy(id = "connection-b", address = "https://other.example.invalid")
        val second = connect(other, session.copy(profileId = other.id))
        store.clearSession(profile.id)
        failure(DsmErrorKind.WORKSPACE_CHANGED) { store.requireCurrentOwner(first) }
        store.requireCurrentOwner(second)
        assertNotNull(store.session(other.id))
    }

    @Test fun `删除后即便重复使用连接编号也不能认领旧任务`() {
        val first = connect()
        store.bindRecord(WorkspaceRecordKind.SERVER, "archive-a", first)
        store.removeProfile(profile.id)
        val second = connect()
        assertFalse(first.hasSameIdentity(second))
        failure(DsmErrorKind.WORKSPACE_CHANGED) { store.savedConnectionForRecord(WorkspaceRecordKind.SERVER, "archive-a") }
    }

    @Test fun `旧配置与会话保持可读但未绑定任务不猜归属`() {
        store.saveProfile(profile); store.saveSession(session)
        assertEquals(profile, store.profiles().single()); assertEquals(session, store.session(profile.id))
        connect()
        failure(DsmErrorKind.WORKSPACE_CHANGED) { store.savedConnectionForRecord(WorkspaceRecordKind.DOWNLOAD, "legacy") }
    }

    @Test fun `不保存密码的会话仍有归属但后台不能获得凭据`() {
        val owner = store.commitConnection(store.connectionAttempt(profile.id), profile, session, null, false)
        store.bindRecord(WorkspaceRecordKind.DOWNLOAD, "foreground", owner)
        assertNull(store.password(profile.id)); assertNull(store.session(profile.id))
        store.requireCurrentOwner(owner)
        failure(DsmErrorKind.NO_SAVED_SESSION) { store.savedConnectionForRecord(WorkspaceRecordKind.DOWNLOAD, "foreground") }
    }

    @Test fun `身份变更清除旧浏览记录并拒绝旧页面迟到保存`() {
        val first = connect()
        store.recordRecentDirectory(profile.id, "/synthetic-old", first)
        store.saveWorkspaceUiState(profile.id, PersistedWorkspaceUiState(filePath = "/synthetic-old"), first)
        connect(profile.copy(username = "account-b"), session.copy(sid = "synthetic-b"))
        store.recordRecentDirectory(profile.id, "/synthetic-late", first)
        store.saveWorkspaceUiState(profile.id, PersistedWorkspaceUiState(filePath = "/synthetic-late"), first)
        assertTrue(store.recentDirectories(profile.id).isEmpty()); assertNull(store.workspaceUiState(profile.id))
    }

    @Test fun `外部目标在退出时保留但身份改变后失效`() {
        val owner = connect()
        val target = OpaqueWorkspaceTarget.FileDirectory("/synthetic")
        val token = requireNotNull(store.issueOpaqueWorkspaceTarget(profile.id, target, owner))
        assertEquals(token, store.issueOpaqueWorkspaceTarget(profile.id, target, owner))
        store.clearSession(profile.id)
        assertEquals(profile.id, store.opaqueWorkspaceRoute(token)?.profileId)
        connect(profile.copy(username = "account-b"), session.copy(sid = "synthetic-b"))
        assertNull(store.opaqueWorkspaceRoute(token))
    }

    @Test fun `多个存储实例并发新增不会丢失连接`() {
        val executor = Executors.newFixedThreadPool(4)
        val jobs = (1..40).map { number -> executor.submit {
            val other = SecureProfileStore(preferences)
            other.saveProfile(profile.copy(id = "connection-$number"))
        } }
        jobs.forEach { it.get(5, TimeUnit.SECONDS) }
        executor.shutdownNow()
        assertEquals(40, store.profiles().map { it.id }.distinct().size)
    }

    @Test fun `保存失败不返回可安装到工作区的归属`() {
        preferences.commitSucceeds = false
        failure(DsmErrorKind.LOCAL_STORAGE_FAILED) { connect() }
    }
}
