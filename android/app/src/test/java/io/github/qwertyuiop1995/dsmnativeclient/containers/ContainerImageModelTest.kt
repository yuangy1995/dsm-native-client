package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ContainerImageModelTest {
    private val fixture = ContainerFixture(); private var repository = fixture.repository()
    private val preferences = MemoryPreferences(); private var store = ContainerImageStore(preferences)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default); private var canStart = true
    private fun model() = ContainerImageModel(scope, { repository }, { store }, { canStart })
    private suspend fun idle(model: ContainerImageModel) { withTimeout(8_000) { while (model.state.value.busy) delay(10) } }
    private suspend fun load(model: ContainerImageModel) { model.refresh(); idle(model); assertNull(model.state.value.failure) }
    private suspend fun pull(model: ContainerImageModel, tag: String = "stable") {
        assertTrue(model.requestPull("synthetic/image", tag)); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
    }
    private fun cold(old: ContainerImageModel, identity: String = "identity"): ContainerImageModel {
        old.clear(); repository = fixture.repository("new-generation", identity); store = ContainerImageStore(preferences); return model()
    }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `固定下载确认取消重复提交与当前任务完成`() = runBlocking {
        val model = model(); load(model); assertTrue(model.requestPull("synthetic/image", "stable")); val confirmation = model.state.value.confirmation!!
        model.cancel(); assertFalse(model.confirm(confirmation)); assertTrue(fixture.writes.isEmpty())
        canStart = false; assertFalse(model.requestPull("synthetic/image", "stable")); canStart = true
        assertTrue(model.requestPull("synthetic/image", "stable")); assertTrue(model.confirm(model.state.value.confirmation!!)); assertFalse(model.confirm(confirmation)); idle(model)
        assertNull(model.state.value.failure); assertEquals(ContainerStage.VERIFIED, model.state.value.activities.single().stage); assertEquals(1, fixture.writes.size)
        assertFalse(preferences.all.toString().contains("synthetic/image"))
    }
    @Test fun `没有回执重建保留保护不同标签仍可下载`() = runBlocking {
        val model = model(); load(model); fixture.taskId = null; pull(model)
        var next = cold(model); load(next); assertTrue(next.state.value.activities.single().pending)
        assertFalse(next.requestPull("synthetic/image", "stable")); assertTrue(next.state.value.failure is ContainerFailure)
        fixture.taskId = JsonPrimitive("task-two"); fixture.pullTag = "latest"; pull(next, "latest")
        assertEquals(2, fixture.writes.size); assertEquals(1, next.state.value.activities.count { it.pending })
        next = cold(next); load(next); assertEquals(2, fixture.writes.size)
    }
    @Test fun `下载与同标签删除互斥重建只读完成原任务`() = runBlocking {
        val model = model(); load(model); fixture.pullFinished = JsonPrimitive(false); pull(model)
        assertFalse(model.requestDelete(model.state.value.images)); assertEquals(1, fixture.writes.size)
        fixture.pullFinished = JsonPrimitive(true); val next = cold(model); load(next)
        assertEquals(ContainerStage.VERIFIED, next.state.value.activities.single().stage); assertEquals(1, fixture.writes.size)
        assertTrue(next.requestDelete(next.state.value.images)); assertTrue(next.confirm(next.state.value.confirmation!!)); idle(next)
        assertNull(next.state.value.failure); assertTrue(next.state.value.images.isEmpty()); assertEquals(2, fixture.writes.size)
    }
    @Test fun `删除未知按原标签恢复不自动重发且未结束不能清理`() = runBlocking {
        val model = model(); load(model); fixture.before = { if (it.api == "SYNO.Docker.Image" && it.method == "delete") throw IOException("Synthetic lost response") }
        assertTrue(model.requestDelete(model.state.value.images)); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
        val record = model.state.value.activities.single(); assertEquals(ContainerStage.SUBMITTED, record.stage); model.dismiss(record.id); assertTrue(model.state.value.activities.single().pending)
        fixture.before = {}; fixture.images = listOf(ContainerFixture.image(id = "replacement")); var next = cold(model); load(next)
        assertTrue(next.state.value.activities.single().pending); assertFalse(next.requestDelete(next.state.value.images))
        fixture.images = emptyList(); next = cold(next); load(next); assertEquals(ContainerStage.VERIFIED, next.state.value.activities.single().stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `删除确认取消零写在途取消保留记录且冷恢复不重发`() = runBlocking {
        val model = model(); load(model)
        assertTrue(model.requestDelete(model.state.value.images)); val cancelled = model.state.value.confirmation!!
        model.cancel(); assertFalse(model.confirm(cancelled)); assertTrue(fixture.writes.isEmpty())
        fixture.before = { if (it.api == "SYNO.Docker.Image" && it.method == "delete") throw CancellationException("Synthetic cancellation") }
        assertTrue(model.requestDelete(model.state.value.images)); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
        assertEquals(ContainerStage.SUBMITTED, model.state.value.activities.single().stage)
        assertEquals("delete", fixture.calls.last().method); assertEquals(1, fixture.writes.size)
        fixture.before = {}; val next = cold(model); load(next)
        assertTrue(next.state.value.activities.single().pending); assertFalse(next.requestDelete(next.state.value.images))
        fixture.images = emptyList(); load(next)
        assertEquals(ContainerStage.VERIFIED, next.state.value.activities.single().stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `批量映像只删除部分时保留逐项结果并仅只读恢复剩余项`() = runBlocking {
        fixture.images = listOf(ContainerFixture.image(tags = listOf("stable", "other"))); fixture.applyWrite = false
        fixture.after = { if (it.api == "SYNO.Docker.Image" && it.method == "delete") fixture.images = listOf(ContainerFixture.image(tags = listOf("other"))) }
        val model = model(); load(model); val targets = model.state.value.images
        assertEquals(2, targets.size); assertTrue(model.requestDelete(targets)); assertTrue(model.confirm(model.state.value.confirmation!!)); idle(model)
        val record = model.state.value.activities.single()
        assertEquals(ContainerStage.ACCEPTED, record.stage); assertEquals(setOf(targets.single { it.tag == "stable" }.identity().selection), record.removed)
        assertEquals(1, fixture.writes.size); model.dismiss(record.id); assertTrue(model.state.value.activities.single().pending)
        fixture.after = {}; val next = cold(model); load(next)
        assertEquals(record.removed, next.state.value.activities.single().removed); assertTrue(next.state.value.activities.single().pending)
        fixture.images = emptyList(); load(next)
        assertEquals(ContainerStage.VERIFIED, next.state.value.activities.single().stage); assertEquals(2, next.state.value.activities.single().removed.size)
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `明确任务失败是终态不会被后来的同名映像改写`() = runBlocking {
        val model = model(); load(model); fixture.errors = mapOf(("SYNO.Docker.Image" to "pull_status") to 1202); pull(model)
        assertEquals(ContainerStage.REJECTED, model.state.value.activities.single().stage)
        fixture.errors = emptyMap(); val next = cold(model); load(next); assertEquals(ContainerStage.REJECTED, next.state.value.activities.single().stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `记录失败零写不同身份不接管旧任务`() = runBlocking {
        val model = model(); load(model); preferences.commitSucceeds = false; pull(model)
        assertTrue(model.state.value.failure is ContainerFailure); assertTrue(fixture.writes.isEmpty())
        preferences.commitSucceeds = true; val next = cold(model, "different-identity"); load(next); assertTrue(next.state.value.activities.isEmpty())
    }
    @Test fun `清单缺占用只可浏览不允许删除`() = runBlocking {
        fixture.controls = listOf(JsonObject(fixture.controls.single() - "image"))
        val model = model(); load(model); assertFalse(model.state.value.usageAvailable); assertEquals(1, model.state.value.images.size)
        assertFalse(model.requestDelete(model.state.value.images)); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `原任务轮询完成仅通知一次总览更新且不重复下载`() = runBlocking {
        val changed = java.util.concurrent.atomic.AtomicInteger()
        val model = ContainerImageModel(scope, { repository }, { store }, { canStart }, { changed.incrementAndGet() })
        fixture.pullFinished = JsonPrimitive(false); load(model); pull(model)
        withTimeout(8_000) { while (changed.get() != 1) delay(10) }
        model.poll(); idle(model); assertEquals(1, changed.get())
        fixture.pullFinished = JsonPrimitive(true); model.poll(); idle(model)
        withTimeout(8_000) { while (changed.get() != 2) delay(10) }
        model.poll(); idle(model); assertEquals(2, changed.get()); assertEquals(1, fixture.writes.size)
    }

}
