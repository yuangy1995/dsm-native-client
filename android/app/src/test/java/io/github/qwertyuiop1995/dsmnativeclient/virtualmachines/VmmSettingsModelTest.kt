package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class VmmSettingsModelTest {
    private val fixture = VmmFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private var store = VmmSettingsStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var canStart = true
    private fun model() = VmmSettingsModel(scope, { repository }, { store }, { canStart })
    private suspend fun idle(model: VmmSettingsModel) { withTimeout(8_000) { while (model.state.value.busy) delay(10) } }
    private suspend fun open(model: VmmSettingsModel, id: String = "synthetic-guest") {
        assertTrue(model.open(id)); idle(model); assertNull(model.state.value.failure)
        model.change(model.state.value.draft!!.copy(name = "Updated $id"))
    }
    private suspend fun send(model: VmmSettingsModel) { assertTrue(model.save()); assertFalse(model.save()); idle(model) }
    private suspend fun cold(old: VmmSettingsModel, identity: String = "identity"): VmmSettingsModel {
        old.clear(); repository = fixture.repository("next-generation", identity); store = VmmSettingsStore(preferences)
        return model().also { it.refresh(); idle(it) }
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `原表单取消零写明确保存一次且完成移除草稿`() = runBlocking {
        val model = model(); assertFalse(model.save()); open(model); model.close(); assertTrue(fixture.writes.isEmpty())
        open(model); send(model); assertEquals(1, fixture.writes.size); assertEquals(VmmStage.VERIFIED, model.state.value.records.single().stage)
        assertFalse(model.state.value.editor); assertNull(model.state.value.draft); model.dismiss(); assertTrue(model.state.value.records.isEmpty())
    }
    @Test fun `接受后冷恢复按所有字段匹配不重发其他VM可以编辑`() = runBlocking {
        fixture.guests += VmmFixture.guest("other", "Other"); fixture.applyWrite = false
        val model = model(); open(model); send(model); assertEquals(VmmStage.ACCEPTED, model.state.value.records.single().stage)
        val next = cold(model); assertTrue(next.hasPending("synthetic-guest")); assertFalse(next.hasPending("other"))
        open(next, "other"); next.close(); assertEquals(1, fixture.writes.size)
        fixture.guests = listOf(VmmFixture.guest(name = "Updated synthetic-guest"), VmmFixture.guest("other", "Other"))
        next.refresh(); idle(next); assertEquals(VmmStage.VERIFIED, next.state.value.records.single().stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `丢失回执后相同字段不能认领也不能关闭记录重试`() = runBlocking {
        fixture.after = { if (it.method == "set") throw IOException("lost response") }
        val model = model(); open(model); send(model); assertEquals(VmmStage.SUBMITTED, model.state.value.records.single().stage)
        fixture.after = {}; val next = cold(model); next.dismiss()
        assertTrue(next.hasPending("synthetic-guest")); assertEquals(VmmStage.SUBMITTED, next.state.value.records.single().stage)
        assertTrue(next.open("synthetic-guest")); idle(next); assertNotNull(next.state.value.failure); assertFalse(next.save()); assertEquals(1, fixture.writes.size)
    }
    @Test fun `明确拒绝和接受后字段不匹配不能误报完成`() = runBlocking {
        fixture.rejection = 105; val model = model(); open(model); send(model)
        assertEquals(VmmStage.REJECTED, model.state.value.records.single().stage)
        fixture.rejection = null; fixture.guests = listOf(VmmFixture.guest(name = "Updated synthetic-guest"))
        val next = cold(model); assertEquals(VmmStage.REJECTED, next.state.value.records.single().stage)
        next.dismiss(); fixture.applyWrite = false; open(next); next.change(next.state.value.draft!!.copy(cpu = "4")); send(next)
        next.refresh(); idle(next); assertEquals(VmmStage.ACCEPTED, next.state.value.records.single().stage); assertEquals(2, fixture.writes.size)
    }
    @Test fun `提交前落盘失败零写并保持失败保护`() = runBlocking {
        val model = model(); open(model); preferences.commitSucceeds = false; send(model)
        assertTrue(fixture.writes.isEmpty()); assertTrue(model.state.value.failure is VmmFailure); assertTrue(model.hasPending())
    }
    @Test fun `写前外部互锁变化拒绝双击且保留未修改表单`() = runBlocking {
        val model = model(); canStart = false; assertFalse(model.open("synthetic-guest")); canStart = true; open(model)
        canStart = false; assertFalse(model.save()); assertTrue(model.state.value.editor); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `同身份新会话保留记录不同身份不能读取或修改`() = runBlocking {
        fixture.applyWrite = false; val model = model(); open(model); send(model)
        val other = cold(model, "other-identity"); assertTrue(other.state.value.records.isEmpty())
        val original = cold(other); assertTrue(original.hasPending()); assertEquals(1, fixture.writes.size)
        assertTrue(preferences.all.values.none { it.toString().contains("Synthetic") || it.toString().contains("Updated") || it.toString().contains("synthetic-guest") })
    }
    @Test fun `切换身份后的迟到保存不能回填新工作区`() = runBlocking {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        fixture.before = { if (it.method == "set") { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        val model = model(); open(model); assertTrue(model.save()); assertTrue(entered.await(5, TimeUnit.SECONDS))
        model.clear(); repository = fixture.repository("next", "other"); release.countDown(); delay(100)
        assertFalse(model.state.value.loaded); assertFalse(model.state.value.editor); model.refresh(); idle(model)
        assertTrue(model.state.value.records.isEmpty()); assertEquals(1, fixture.writes.size)
    }
}
