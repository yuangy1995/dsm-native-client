package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.PackageMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasPackageControlModelTest {
    private val fixture = NasPackageControlFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private var store = PackageActivityStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val directory = Files.createTempDirectory("synthetic-control").toFile(); private var canStart = true
    private fun model() = NasPackageCenterModel(scope, { repository }, { store }, { directory }, {}, canStart = { canStart })
    private suspend fun idle(model: NasPackageCenterModel) { delay(30); withTimeout(15_000) { while (model.state.value.busy) delay(10) }; delay(20) }
    private suspend fun load(model: NasPackageCenterModel) { model.loadInstalled(); idle(model); assertNull(model.state.value.failure); assertNull(model.state.value.installedFailure) }
    private fun target(model: NasPackageCenterModel) = model.state.value.installed!!.single()
    private fun record(model: NasPackageCenterModel) = model.state.value.activities.single()
    private fun confirmation(model: NasPackageCenterModel) = model.state.value.controlConfirmation!!
    private fun cold(old: NasPackageCenterModel, identity: String = "identity"): NasPackageCenterModel {
        old.clear(); repository = fixture.repository("next", identity); store = PackageActivityStore(preferences); return model()
    }
    private suspend fun seed(action: PackageMutationOperation = PackageMutationOperation.START, phase: PackageActivityPhase = PackageActivityPhase.SUBMITTED): PackageActivityRecord {
        val target = repository.packageCenter.controlInstalled().single()
        val record = PackageActivityRecord("synthetic-record", repository.owner!!, PackageActivityKind.CONTROL,
            listOf(PackageActivityItem(target.id, target.version, target.version, step = action.controlStep().name)), packageInstallationDigest(target))
        store.begin(record)
        if (phase != PackageActivityPhase.READY) store.checkpoint(record.owner, NasPackageCheckpoint(record.id, action.controlStep(), NasPackageWriteStage.WILL_SUBMIT))
        if (phase == PackageActivityPhase.REJECTED) store.checkpoint(record.owner, NasPackageCheckpoint(record.id, action.controlStep(), NasPackageWriteStage.REJECTED))
        return store.get(record.owner, record.id)
    }
    @org.junit.After fun cleanup() { scope.cancel(); directory.deleteRecursively() }
    @Test fun `实际页面确认绑定原对象旧确认取消外部忙碌和双击不提交`() = runBlocking {
        val model = model(); load(model); val target = target(model)
        canStart = false; assertFalse(model.requestControl(target, PackageMutationOperation.START)); canStart = true
        assertTrue(model.requestControl(target, PackageMutationOperation.START)); val expected = confirmation(model)
        model.cancelControl(); assertFalse(model.confirmControl(expected)); assertTrue(fixture.writes.isEmpty())
        assertTrue(model.requestControl(target, PackageMutationOperation.START)); canStart = false; assertFalse(model.confirmControl(expected)); canStart = true
        fixture.afterWrite = NasPackageControlFixture.directory(NasPackageControlFixture.row("running"))
        assertTrue(model.confirmControl(expected)); assertFalse(model.confirmControl(expected)); idle(model)
        assertEquals(PackageActivityPhase.COMPLETED, record(model).items.single().phase); assertEquals(1, fixture.writes.size)
        assertEquals(ResourceState.RUNNING, target(model).status)
        val raw = preferences.all.values.joinToString()
        for (privateValue in listOf("Synthetic private display", "Synthetic private description", "synthetic-app", "synthetic-sid", "synthetic-token", "synthetic.invalid", "1700000000")) assertFalse(raw.contains(privateValue))
    }
    @Test fun `原安装恢复拒绝同版本重装和消失达到原状态才解除共享锁`() = runBlocking {
        val original = seed(); val model = cold(model())
        for (rows in listOf(NasPackageControlFixture.directory(NasPackageControlFixture.row("running", 1_700_000_001)), NasPackageControlFixture.directory())) {
            fixture.directory = rows; load(model); assertFalse(record(model).terminal)
            model.discard(original.id); idle(model); assertNotNull(model.state.value.failure); model.dismissFailure()
            try { repository.packageCenter.performControl("blocked", PackageInfo("Synthetic", "Synthetic", "1.0", ResourceState.STOPPED, null, true, false), PackageMutationOperation.START) { fail() }; fail() } catch (error: NasPackageFailure) { assertEquals(NasPackageProblem.BUSY, error.problem) }
        }
        fixture.directory = NasPackageControlFixture.directory(NasPackageControlFixture.row("running")); load(model)
        assertEquals(PackageActivityPhase.COMPLETED, record(model).items.single().phase); assertTrue(fixture.writes.isEmpty())
        model.discard(original.id); idle(model); assertTrue(model.state.value.activities.isEmpty())
    }
    @Test fun `卸载未知重启只读完整目录而准备取消与明确拒绝不得升级成功`() = runBlocking {
        seed(PackageMutationOperation.UNINSTALL); var model = cold(model())
        fixture.directory = buildJsonObject { put("packages", JsonArray(emptyList())); put("total", 1) }
        model.loadInstalled(); idle(model); assertNotNull(model.state.value.installedFailure); assertFalse(record(model).terminal)
        fixture.directory = NasPackageControlFixture.directory(); load(model); assertEquals(PackageActivityPhase.COMPLETED, record(model).items.single().phase)
        model.discard(record(model).id); idle(model)
        fixture.directory = NasPackageControlFixture.directory(NasPackageControlFixture.row()); seed(phase = PackageActivityPhase.READY)
        model = cold(model); load(model); assertEquals(PackageActivityPhase.CANCELLED, record(model).items.single().phase)
        model.discard(record(model).id); idle(model); seed(phase = PackageActivityPhase.REJECTED)
        model = cold(model); fixture.directory = NasPackageControlFixture.directory(NasPackageControlFixture.row("running")); load(model)
        model.review(record(model)); idle(model); assertEquals(PackageActivityPhase.REJECTED, record(model).items.single().phase); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `丢回执只发一次接受失败保留阶段供冷恢复`() = runBlocking {
        var model = model(); load(model)
        fixture.before = { if (it.oneShot) throw IOException("Synthetic lost receipt") }
        assertTrue(model.requestControl(target(model), PackageMutationOperation.UNINSTALL)); assertTrue(model.confirmControl(confirmation(model))); idle(model)
        assertEquals(PackageActivityPhase.SUBMITTED, record(model).items.single().phase); assertFalse(record(model).items.single().accepted); assertEquals(1, fixture.writes.size)
        fixture.before = {}; fixture.directory = NasPackageControlFixture.directory(); model = cold(model); load(model)
        assertTrue(record(model).terminal); model.discard(record(model).id); idle(model)
        fixture.directory = NasPackageControlFixture.directory(NasPackageControlFixture.row()); load(model)
        fixture.before = { if (it.oneShot) preferences.commitSucceeds = false }; fixture.afterWrite = NasPackageControlFixture.directory(NasPackageControlFixture.row("running"))
        assertTrue(model.requestControl(target(model), PackageMutationOperation.START)); assertTrue(model.confirmControl(confirmation(model))); idle(model)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, (model.state.value.failure as DsmFailure).kind); assertEquals("start", fixture.calls.last().method)
        preferences.commitSucceeds = true; fixture.before = {}; model = cold(model); load(model); assertTrue(record(model).terminal); assertEquals(2, fixture.writes.size)
    }
    @Test fun `保存损坏或已记住记录消失失败关闭`() = runBlocking {
        var model = model(); load(model); preferences.commitSucceeds = false
        assertTrue(model.requestControl(target(model), PackageMutationOperation.START)); assertTrue(model.confirmControl(confirmation(model))); idle(model)
        assertEquals(DsmErrorKind.LOCAL_STORAGE_FAILED, (model.state.value.failure as DsmFailure).kind); assertTrue(fixture.writes.isEmpty())
        preferences.commitSucceeds = true; preferences.edit().clear().putString("package:bad", "{}").commit(); model = cold(model)
        model.loadInstalled(); idle(model); assertNotNull(model.state.value.failure); assertTrue(fixture.writes.isEmpty())
        preferences.edit().clear().commit(); model = cold(model); seed(); load(model); preferences.edit().clear().commit()
        model.loadInstalled(); idle(model); assertNotNull(model.state.value.failure); assertFalse(model.requestControl(target(model), PackageMutationOperation.START)); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `恢复保留当前权限会话与另一账号隔离不匹配版本`() = runBlocking {
        val original = seed(); var model = cold(model()); fixture.directory = NasPackageControlFixture.directory(NasPackageControlFixture.row("running"))
        for (condition in listOf(0, 2)) {
            fixture.admin = condition != 0; fixture.known = false; fixture.ownerValid = condition != 2
            model.loadInstalled(); idle(model)
            if (condition == 2) assertEquals(DsmErrorKind.WORKSPACE_CHANGED, (model.state.value.failure as DsmFailure).kind)
            else assertNotNull(model.state.value.installedFailure)
            assertFalse(record(model).terminal)
        }
        fixture.ownerValid = true; model = cold(model, "another-account"); load(model); assertTrue(model.state.value.activities.isEmpty())
        assertFalse(store.get(original.owner, original.id).terminal); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `两实例互斥账号切换后的迟到回执仅保存原记录`() = runBlocking {
        val first = model(); val second = model(); load(first); load(second)
        assertTrue(first.requestControl(target(first), PackageMutationOperation.START)); assertTrue(second.requestControl(target(second), PackageMutationOperation.START))
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it.oneShot) { entered.countDown(); check(release.await(3, TimeUnit.SECONDS)) } }
        assertTrue(first.confirmControl(confirmation(first))); assertTrue(entered.await(3, TimeUnit.SECONDS))
        assertTrue(second.confirmControl(confirmation(second))); idle(second); assertEquals(1, fixture.writes.size)
        val owner = repository.owner!!; repository = fixture.repository("other", "another-account"); first.clear(); release.countDown()
        withTimeout(5_000) { scope.coroutineContext[Job]!!.children.toList().joinAll() }
        fixture.before = {}; val next = model(); load(next); assertTrue(next.state.value.activities.isEmpty())
        assertFalse(store.records(owner).single().terminal); assertEquals(1, fixture.writes.size)
    }
}
