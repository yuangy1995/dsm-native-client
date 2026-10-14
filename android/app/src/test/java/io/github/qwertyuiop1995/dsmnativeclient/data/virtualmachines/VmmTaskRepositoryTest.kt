package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class VmmTaskRepositoryTest {
    private val scenario = VmmTaskFixture(); private val fixture get() = scenario.fixture
    private val events = mutableListOf<VmmImportProgress>(); private var snapshot: VmmImportSnapshot? = null
    private suspend fun send(repo: io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository) {
        repo.importNasVmmImage(scenario.target(), { snapshot = it }, { events += it })
    }
    @Test fun `NAS文件导入使用公开固定版本与一次写任务回读且不自动清理`() = runBlocking {
        val repo = scenario.repository(); send(repo)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED), events.map { it.stage })
        val call = fixture.writes.single(); assertTrue(call.oneShot); assertEquals(1, call.version)
        assertEquals(JsonPrimitive(false), call.fields["auto_clean_task"]); assertEquals(JsonArray(listOf(JsonPrimitive("storage-1"))), call.fields["storage_ids"])
        assertEquals(JsonPrimitive(scenario.file.path), call.fields["ds_file_path"])
        val result = repo.virtualMachineManagement.recoverImport(snapshot!!, events.last())
        assertEquals(VmmStage.VERIFIED, result.stage); assertEquals(vmmDigest("new-image"), result.image)
        assertTrue(scenario.tasks.containsKey(scenario.taskId)); assertEquals(1, fixture.writes.size)
    }
    @Test fun `权限文件存储同名或不完整列表变化都在发送前停止`() = runBlocking {
        val repo = scenario.repository()
        scenario.fileSize++; assertTrue(runCatching { send(repo) }.isFailure); scenario.fileSize--
        scenario.storageName = "Changed"; assertTrue(runCatching { send(repo) }.isFailure); scenario.storageName = scenario.storage.name
        scenario.storageStatus = "offline"; assertTrue(runCatching { send(repo) }.isFailure); scenario.storageStatus = "online"
        scenario.storageTotal = 2; assertTrue(runCatching { send(repo) }.isFailure); scenario.storageTotal = null
        fixture.images = listOf(VmmFixture.image(name = "IMPORTED IMAGE")); assertTrue(runCatching { send(repo) }.isFailure)
        fixture.images = emptyList(); fixture.allowed = false; assertTrue(runCatching { send(repo) }.isFailure)
        assertTrue(fixture.writes.isEmpty()); assertTrue(events.isEmpty()); assertNull(snapshot)
    }
    @Test fun `未知创建回执不允许追认同名映像明确拒绝才记录拒绝`() = runBlocking {
        val repo = scenario.repository(); scenario.missingReceipt = true
        assertTrue(runCatching { send(repo) }.isFailure); assertEquals(VmmStage.SUBMITTED, events.single().stage)
        assertEquals(1, fixture.writes.size); assertTrue(runCatching { repo.virtualMachineManagement.recoverImport(snapshot!!, events.single()) }.isFailure)
        fixture.images = emptyList(); events.clear(); scenario.missingReceipt = false; fixture.rejection = 105
        assertTrue(runCatching { send(repo) }.isFailure); assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.REJECTED), events.map { it.stage })
    }
    @Test fun `原任务必须严格布尔结束和新映像身份名称类型`() = runBlocking {
        val repo = scenario.repository(); send(repo); val progress = events.last()
        scenario.tasks[scenario.taskId] = VmmTaskFixture.task(false, scenario.imageId)
        assertEquals(progress, repo.virtualMachineManagement.recoverImport(snapshot!!, progress))
        scenario.tasks[scenario.taskId] = buildJsonObject { put("finish", "true") }
        assertTrue(runCatching { repo.virtualMachineManagement.recoverImport(snapshot!!, progress) }.isFailure)
        scenario.tasks[scenario.taskId] = VmmTaskFixture.task(true, "image-1")
        assertTrue(runCatching { repo.virtualMachineManagement.recoverImport(snapshot!!, progress) }.isFailure)
        scenario.tasks[scenario.taskId] = VmmTaskFixture.task(true, scenario.imageId)
        fixture.images = listOf(VmmFixture.image(scenario.imageId, "Another name"))
        assertTrue(runCatching { repo.virtualMachineManagement.recoverImport(snapshot!!, progress) }.isFailure)
        fixture.images = listOf(VmmFixture.image(scenario.imageId, "Imported image", "iso"))
        assertTrue(runCatching { repo.virtualMachineManagement.recoverImport(snapshot!!, progress) }.isFailure)
        fixture.images = emptyList(); val missing = repo.virtualMachineManagement.recoverImport(snapshot!!, progress)
        assertEquals(VmmStage.ACCEPTED, missing.stage); assertEquals(vmmDigest(scenario.imageId), missing.image)
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `任务清理仅清除用户看到的结束记录接受后严格读取不存在`() = runBlocking {
        scenario.tasks["finished"] = VmmTaskFixture.task(); scenario.tasks["running"] = VmmTaskFixture.task(false)
        val repo = scenario.repository().virtualMachineManagement; val targets = repo.taskTargets(); val stages = mutableListOf<VmmStage>()
        repo.clearTask(targets.single { it.finished }) { stages += it }
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED, VmmStage.VERIFIED), stages)
        assertEquals(setOf("running"), scenario.tasks.keys); assertEquals("clear", fixture.writes.single().method); assertTrue(fixture.writes.single().oneShot)
        assertTrue(runCatching { repo.clearTask(targets.single { !it.finished }) {} }.isFailure); assertEquals(1, fixture.writes.size)
    }
    @Test fun `清理拒绝漂移且丢失回执即使任务消失仍保留已发送`() = runBlocking {
        scenario.tasks["finished"] = VmmTaskFixture.task(); val repo = scenario.repository().virtualMachineManagement
        val target = repo.taskTargets().single(); val stages = mutableListOf<VmmStage>()
        scenario.tasks["finished"] = VmmTaskFixture.task(image = "changed")
        assertTrue(runCatching { repo.clearTask(target) { stages += it } }.isFailure); assertEquals(listOf(VmmStage.CANCELLED), stages); assertTrue(fixture.writes.isEmpty())
        scenario.tasks["finished"] = VmmTaskFixture.task(); stages.clear()
        fixture.after = { if (it.method == "clear") throw IOException("Lost synthetic receipt") }
        assertTrue(runCatching { repo.clearTask(target) { stages += it } }.isFailure)
        assertEquals(listOf(VmmStage.SUBMITTED), stages); assertTrue(scenario.tasks.isEmpty()); assertEquals(1, fixture.writes.size)
    }
    @Test fun `任务列表拒绝重复非文本越界及任务信息弱类型`() = runBlocking {
        val repo = scenario.repository().virtualMachineManagement
        for (data in listOf("{\"task_ids\":[\"x\",\"x\"]}", "{\"task_ids\":[1]}", "{}")) {
            scenario.taskListOverride = VmmFixture.obj(data); assertTrue(runCatching { repo.taskTargets() }.isFailure)
        }
        scenario.taskListOverride = buildJsonObject { put("task_ids", JsonArray((0..100).map { JsonPrimitive("task-$it") })) }
        assertTrue(runCatching { repo.taskTargets() }.isFailure); scenario.taskListOverride = null
        scenario.tasks["x"] = VmmTaskFixture.task(progress = JsonPrimitive("100")); assertTrue(runCatching { repo.taskTargets() }.isFailure)
        scenario.tasks["x"] = VmmTaskFixture.task(progress = JsonPrimitive(101)); assertTrue(runCatching { repo.taskTargets() }.isFailure)
        assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `落盘失败与过期归属在导入写前停止`() = runBlocking {
        val repo = scenario.repository()
        assertTrue(runCatching { repo.importNasVmmImage(scenario.target(), { throw IOException("Synthetic storage failure") }, {}) }.isFailure)
        fixture.ownerValid = false; assertTrue(runCatching { send(repo) }.isFailure); assertTrue(fixture.writes.isEmpty())
    }
}
