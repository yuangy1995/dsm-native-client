package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.*
import org.junit.Assert.*
import org.junit.rules.TemporaryFolder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@OptIn(ExperimentalCoroutinesApi::class)
class SharedInputModelTest {
    @get:Rule val temporary = TemporaryFolder()
    private val fixture = SystemFileFixture()
    private val profiles = SecureProfileStore(MemoryPreferences())
    private val preferences = MemoryPreferences()
    private val transferPrefs = MemoryPreferences()
    private val transfers = TransferStore(transferPrefs)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val submitted = java.util.Collections.synchronizedList(mutableListOf<PersistedUpload>())
    private lateinit var store: SharedInputStore
    private lateinit var owner: WorkspaceOwner
    private lateinit var repository: DsmRepository
    private lateinit var model: SharedInputModel
    private var connected = true
    private var requestedConnection: String? = null
    @Before fun prepare() {
        Dispatchers.setMain(Dispatchers.Unconfined)
        store = SharedInputStore(preferences, temporary.root, "synthetic.app")
        owner = profiles.commitConnection(profiles.connectionAttempt(fixture.profile.id), fixture.profile, fixture.session, null, false, persistSession = true)
        repository = fixture.repository(owner) { profiles.requireCurrentOwner(owner) }
        model = create()
    }
    @After fun cleanup() { scope.cancel(); Dispatchers.resetMain() }
    private fun create() = SharedInputModel(scope, store, transfers, profiles,
        { id -> repository.takeIf { id == fixture.profile.id && connected && runCatching { it.requireCurrentOwner() }.isSuccess } },
        { requestedConnection = it; true }, { profile, records -> assertEquals(fixture.profile.id, profile); submitted += records })
    private suspend fun await(predicate: () -> Boolean) { withTimeout(8_000) { while (!predicate()) delay(10) } }
    private suspend fun ready(path: String) { await { model.state.value.path == path && model.state.value.locations is Loadable.Ready && !model.state.value.loadingMore } }
    private suspend fun receive() {
        assertTrue(model.receive { listOf(SharedSource("file.txt", "text/plain", 3) { "abc".byteInputStream() }) })
        await { !model.state.value.copying && model.state.value.batch != null }
    }
    private suspend fun browse() {
        model.selectConnection(fixture.profile.id); ready("")
        model.enter((model.state.value.locations as Loadable.Ready).value.items.single()); ready("/share")
    }
    @Test fun `接收不触发网络显式目标后一次创建原账号任务并保留副本`() = runBlocking {
        receive(); assertTrue(fixture.calls.isEmpty()); browse(); val batch = model.state.value.batch!!
        model.send(); model.send(); await { !model.state.value.busy }
        assertNull(model.state.value.failure); assertNull(model.state.value.batch); assertEquals(1, submitted.size)
        val task = submitted.single(); assertEquals("/share", task.destinationPath); assertFalse(task.overwrite)
        assertEquals(owner, profiles.recordOwner(WorkspaceRecordKind.UPLOAD, task.id))
        assertEquals("abc", store.file(batch.files.single().id).readText()); assertTrue(transfers.sharedUploadBatchExists(batch.id))
        create(); delay(40); model.send(); assertEquals(1, submitted.size)
        assertTrue(fixture.calls.all { it["method"] in setOf("list_share", "list", "getinfo") })
    }
    @Test fun `同名需确认取消零任务确认后只覆盖已确认名字`() = runBlocking {
        fixture.entries["/share/file.txt"] = SystemFileFixture.item("/share/file.txt")
        receive(); browse(); model.send(); await { !model.state.value.busy }
        assertEquals(setOf("file.txt"), model.state.value.conflicts); assertTrue(submitted.isEmpty())
        model.dismissConflict(); model.send(replace = true); assertTrue(submitted.isEmpty())
        model.send(); await { !model.state.value.busy }; model.send(replace = true); await { !model.state.value.busy }
        assertNull(model.state.value.failure); assertTrue(submitted.single().overwrite)
    }
    @Test fun `目录读完后撤销写权限仍在入队前重新阻止`() = runBlocking {
        receive(); browse(); fixture.entries["/share"] = SystemFileFixture.folder("/share", writable = false)
        model.send(); await { !model.state.value.busy }
        assertNotNull(model.state.value.failure); assertTrue(submitted.isEmpty()); assertNotNull(model.state.value.batch)
    }
    @Test fun `已退出或改账号不复用旧目录分享副本仍可重新选择连接`() = runBlocking {
        receive(); browse(); profiles.signOut(owner); model.connectionChanged()
        assertNull(model.state.value.owner); assertNull(model.state.value.folder); assertEquals("", model.state.value.path)
        model.send(); assertTrue(submitted.isEmpty()); assertNotNull(model.state.value.batch)
        model.selectConnection(fixture.profile.id); assertEquals(fixture.profile.id, requestedConnection); assertTrue(model.state.value.waitingForLogin)
    }
    @Test fun `模块撤销立即隐藏目录并拒绝提交`() = runBlocking {
        receive(); browse(); fixture.allowed = false; repository.refreshAccess(); model.connectionChanged()
        assertNull(model.state.value.folder); assertTrue(model.state.value.locations is Loadable.Idle)
        model.send(); assertTrue(submitted.isEmpty())
    }
    @Test fun `断开的连接先登录返回原连接后重读目录`() = runBlocking {
        receive(); connected = false; model.selectConnection(fixture.profile.id)
        assertFalse(model.state.value.visible); assertEquals(fixture.profile.id, requestedConnection)
        connected = true; model.connectionChanged(); ready("")
        assertTrue(model.state.value.visible); assertEquals(owner, model.state.value.owner); assertTrue(submitted.isEmpty())
    }
    @Test fun `目录分页完整追加且空缺页变为可恢复失败`() = runBlocking {
        for (index in 0..100) fixture.entries["/share/folder/child$index"] = SystemFileFixture.folder("/share/folder/child$index")
        receive(); browse(); model.enter((model.state.value.locations as Loadable.Ready).value.items.single()); ready("/share/folder")
        assertEquals(100, (model.state.value.locations as Loadable.Ready).value.items.size)
        model.more(); await { (model.state.value.locations as? Loadable.Ready)?.value?.items?.size == 101 }
        fixture.incomplete = true; model.retry(); await { model.state.value.locations is Loadable.Failed }
        model.send(); assertTrue(submitted.isEmpty())
    }
    @Test fun `目标读取中换连接拒绝迟到列表不覆盖新页面`() = runBlocking {
        receive(); browse(); val started = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it["method"] == "getinfo") { started.countDown(); check(release.await(5, TimeUnit.SECONDS)) } }
        model.retry(); assertTrue(started.await(5, TimeUnit.SECONDS)); connected = false; model.connectionChanged(); release.countDown()
        delay(100); assertNull(model.state.value.folder); assertNull(model.state.value.owner); assertTrue(model.state.value.locations is Loadable.Idle)
    }
    @Test fun `任务批次保存失败不调度恢复只接手已有记录不再次上传`() = runBlocking {
        receive(); browse(); val batch = model.state.value.batch!!; transferPrefs.commitSucceeds = false
        model.send(); await { !model.state.value.busy }; assertNotNull(model.state.value.failure); assertTrue(submitted.isEmpty())
        transferPrefs.commitSucceeds = true; model = create(); await { store.batches().isEmpty() }
        model.send(); assertTrue(submitted.isEmpty()); assertEquals(1, transfers.uploads(fixture.profile.id).size)
        assertTrue(store.file(batch.files.single().id).exists())
    }
    @Test fun `目录请求权限失败保留草稿且取消草稿没有NAS写入`() = runBlocking {
        receive(); fixture.allowed = false; model.selectConnection(fixture.profile.id)
        await { model.state.value.locations is Loadable.Failed }; assertNotNull(model.state.value.batch)
        model.discard(); await { !model.state.value.busy }; assertNull(model.state.value.batch)
        assertTrue(temporary.root.listFiles().isNullOrEmpty()); assertTrue(submitted.isEmpty())
    }
}
