package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasScheduledTaskRepositoryTest {
    private val fixture = NasScheduledTaskFixture()
    private val repository = NasScheduledTaskRepository(fixture, "Current") { it in 3..4 }
    private val stages = mutableListOf<NasTaskStage>()
    private suspend fun change(value: NasTaskChange) = repository.change(value) { stages += it.stage }
    private suspend fun task() = repository.tasks().single()
    private suspend fun rejected(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: Exception) { } }
    @Test fun `列表不预取脚本新建本地草稿不发模板请求`() = runBlocking {
        assertEquals(10L, task().id); assertEquals(listOf("list"), fixture.requests.map { it.method })
        assertEquals(3, fixture.requests.single().version); assertEquals(JsonPrimitive(1000), fixture.requests.single().fields["limit"])
        val draft = repository.newDraft(); assertNull(draft.id); assertEquals("Current", draft.owner); assertTrue(draft.script.isEmpty())
        assertEquals(1, fixture.requests.size)
    }
    @Test fun `创建保存启停运行删除使用固定版本与类型并完整回读`() = runBlocking {
        val original = repository.newDraft(); val desired = original.copy(name = "Created task", script = "echo synthetic create")
        assertTrue(change(NasTaskChange(NasTaskAction.CREATE, original = original, desired = desired)))
        assertEquals(listOf(NasTaskStage.SUBMITTED, NasTaskStage.ACCEPTED, NasTaskStage.COMPLETED), stages)
        var selected = repository.tasks().single { it.id == 20L }; var detail = repository.inspect(selected)!!
        assertTrue(change(NasTaskChange(NasTaskAction.SAVE, selected, detail, detail.copy(script = "echo synthetic changed", schedule = detail.schedule.copy(hour = 9)))))
        selected = repository.tasks().single { it.id == 20L }
        assertTrue(change(NasTaskChange(NasTaskAction.DISABLE, selected)))
        selected = repository.tasks().single { it.id == 20L }; detail = repository.inspect(selected)!!
        assertTrue(change(NasTaskChange(NasTaskAction.ENABLE, selected, detail)))
        selected = repository.tasks().single { it.id == 20L }; detail = repository.inspect(selected)!!
        assertTrue(change(NasTaskChange(NasTaskAction.RUN, selected, detail)))
        assertTrue(change(NasTaskChange(NasTaskAction.DELETE, selected)))
        val writes = fixture.requests.filter { it.write }
        assertEquals(listOf("create", "set", "set_enable", "set_enable", "run", "delete"), writes.map { it.method })
        assertEquals(listOf(4, 4, 3, 3, 3, 3), writes.map { it.version })
        assertFalse(writes[0].fields.containsKey("id")); assertFalse(writes[0].fields.containsKey("real_owner"))
        assertEquals(JsonPrimitive(20L), writes[1].fields["id"]); assertEquals(JsonPrimitive("Synthetic selector"), writes[1].fields["real_owner"])
        assertTrue(writes[1].fields["schedule"] is JsonObject); assertTrue(writes[1].fields["extra"] is JsonObject)
        assertEquals(JsonPrimitive(false), writes[2].fields["enable"]); assertTrue(repository.tasks().none { it.id == 20L })
    }
    @Test fun `脚本已变化列表未变时保存启用运行均不提交`() = runBlocking {
        val selected = task(); val original = repository.inspect(selected)!!
        fixture.details[10] = JsonObject(fixture.details.getValue(10) + ("extra" to buildJsonObject { put("script", "different synthetic command"); put("notify_if_error", false); put("notify_mail", "") }))
        rejected { change(NasTaskChange(NasTaskAction.SAVE, selected, original, original.copy(name = "Edited"))) }
        rejected { change(NasTaskChange(NasTaskAction.RUN, selected, original)) }
        fixture.rows = listOf(JsonObject(fixture.rows.single() + ("enable" to JsonPrimitive(false))))
        fixture.details[10] = JsonObject(fixture.details.getValue(10) + ("enable" to JsonPrimitive(false)))
        rejected { change(NasTaskChange(NasTaskAction.ENABLE, task(), original.copy(enabled = false))) }
        assertTrue(stages.isEmpty()); assertTrue(fixture.requests.none { it.write })
    }
    @Test fun `停用无需v4且缺失realowner不使用owner替代`() = runBlocking {
        fixture.rows = listOf(JsonObject(fixture.rows.single() - "real_owner"))
        val v3 = NasScheduledTaskRepository(fixture, "Current") { it == 3 }
        assertFalse(v3.canCreate)
        assertTrue(v3.change(NasTaskChange(NasTaskAction.DISABLE, v3.tasks().single())) { })
        assertTrue(fixture.requests.none { it.method == "get" }); assertFalse(fixture.requests.single { it.write }.fields.containsKey("real_owner"))
    }
    @Test fun `明确拒绝不被巧合状态覆盖证书身份错误不继续读`() = runBlocking {
        val selected = task()
        fixture.responseFailure = DsmFailure(105, "Synthetic denied", "", kind = DsmErrorKind.PERMISSION_DENIED)
        rejected { change(NasTaskChange(NasTaskAction.DISABLE, selected)) }
        assertEquals(listOf(NasTaskStage.SUBMITTED, NasTaskStage.REJECTED), stages)
        assertEquals(2, fixture.requests.count { it.method == "list" })
        fixture.rows = listOf(NasScheduledTaskFixture.row()); fixture.responseFailure = DsmFailure(null, "Synthetic owner changed", "", kind = DsmErrorKind.WORKSPACE_CHANGED)
        val reads = fixture.requests.count { !it.write }; stages.clear()
        rejected { change(NasTaskChange(NasTaskAction.DISABLE, selected)) }
        assertEquals(reads + 1, fixture.requests.count { !it.write }); assertEquals(listOf(NasTaskStage.SUBMITTED), stages)
    }
    @Test fun `未知创建运行不认领旧记录但状态变更允许严格读取完成`() = runBlocking {
        fixture.responseFailure = IOException("Synthetic dropped receipt")
        val original = repository.newDraft()
        assertFalse(change(NasTaskChange(NasTaskAction.CREATE, original = original, desired = original.copy(name = "Created", script = "echo synthetic"))))
        val selected = repository.tasks().first { it.id == 10L }; val detail = repository.inspect(selected)!!
        stages.clear(); assertFalse(change(NasTaskChange(NasTaskAction.RUN, selected, detail)))
        assertEquals(listOf(NasTaskStage.SUBMITTED), stages); assertTrue(fixture.requests.none { it.method == "result_list" })
        assertTrue(change(NasTaskChange(NasTaskAction.DISABLE, selected)))
        assertEquals(3, fixture.requests.count { it.write })
    }
    @Test fun `接受回执必须先保存保存失败不继续读取`() = runBlocking {
        val selected = task(); val before = fixture.requests.size
        rejected { repository.change(NasTaskChange(NasTaskAction.DISABLE, selected)) { if (it.stage == NasTaskStage.SUBMITTED) throw IOException("Synthetic disk") } }
        assertTrue(fixture.requests.none { it.write })
        rejected { repository.change(NasTaskChange(NasTaskAction.DISABLE, selected)) { if (it.stage == NasTaskStage.ACCEPTED) throw IOException("Synthetic disk") } }
        assertEquals(1, fixture.requests.count { it.write }); assertEquals(before + 3, fixture.requests.size)
    }
    @Test fun `创建须唯一新id完整配置删除不把新所有者当消失`() = runBlocking {
        val original = repository.newDraft(); fixture.afterWrite = { fixture.details[20] = JsonObject(fixture.details.getValue(20) + ("extra" to buildJsonObject { put("script", "different"); put("notify_if_error", false); put("notify_mail", "") })) }
        assertFalse(change(NasTaskChange(NasTaskAction.CREATE, original = original, desired = original.copy(name = "Created", script = "echo synthetic"))))
        fixture.afterWrite = { fixture.rows = listOf(JsonObject(NasScheduledTaskFixture.row() + ("real_owner" to JsonPrimitive("Different selector")))) }
        assertFalse(change(NasTaskChange(NasTaskAction.DELETE, repository.tasks().first { it.id == 10L })))
    }
    @Test fun `保留日期重复未知星期且禁止编辑隐藏字段`() = runBlocking {
        val schedule = fixture.details.getValue(10).getValue("schedule").jsonObject
        fixture.details[10] = JsonObject(fixture.details.getValue(10) + ("schedule" to JsonObject(schedule + mapOf("week_day" to JsonPrimitive("special"), "date" to JsonPrimitive("2026-12-01"), "repeat_min" to JsonPrimitive(20)))))
        val selected = task(); val original = repository.inspect(selected)!!; assertNull(original.schedule.selectedDays)
        rejected { change(NasTaskChange(NasTaskAction.SAVE, selected, original, original.copy(schedule = original.schedule.copy(repeatMinute = 10)))) }
        assertTrue(change(NasTaskChange(NasTaskAction.SAVE, selected, original, original.copy(script = "echo updated"))))
        val sent = fixture.requests.single { it.write }.fields.getValue("schedule").jsonObject
        assertEquals(JsonPrimitive("special"), sent["week_day"]); assertEquals(JsonPrimitive("2026-12-01"), sent["date"]); assertEquals(JsonPrimitive(20), sent["repeat_min"])
    }
    @Test fun `完整列表拒绝畸形类型重复身份和截断未知开关不当停用`() = runBlocking {
        fixture.rows = listOf(JsonObject(NasScheduledTaskFixture.row() - "enable")); assertNull(task().enabled); assertFalse(task().canEdit)
        for (rows in listOf(listOf(JsonObject(NasScheduledTaskFixture.row() + ("id" to JsonPrimitive("10")))), listOf(NasScheduledTaskFixture.row(), NasScheduledTaskFixture.row()), List(1000) { NasScheduledTaskFixture.row(it.toLong()) })) {
            fixture.rows = rows; rejected { repository.tasks() }
        }
        rejected { decodeScheduledTasks(buildJsonObject { put("tasks", JsonArray(emptyList())); put("total", 1) }) }
        assertTrue(fixture.requests.none { it.write })
    }
    @Test fun `结果按所选任务原身份读取重复名和过期记录停止输出`() = runBlocking {
        val selected = task(); val results = repository.results(selected)
        assertEquals(0, results.single().exitCode); assertEquals("synthetic output", repository.output(selected, results.single()).output)
        assertEquals(listOf(1, 1, 1), fixture.requests.filter { it.api == TASK_RESULTS }.map { it.version })
        fixture.history = emptyList(); rejected { repository.output(selected, results.single()) }
        fixture.rows += NasScheduledTaskFixture.row(11); rejected { repository.results(selected) }
        assertEquals(1, fixture.requests.count { it.method == "result_get_file" })
    }
    @Test fun `结果支持数组包装且保留空输出拒绝冲突`() = runBlocking {
        val row = NasScheduledTaskFixture.result()
        assertEquals(1, decodeTaskResults(buildJsonObject { put("_array", JsonArray(listOf(row))) }, "Synthetic task").size)
        rejected { decodeTaskResults(buildJsonObject { put("results", JsonArray(listOf(row, row))) }, "Synthetic task") }
        rejected { decodeTaskResults(buildJsonObject { put("results", JsonArray(listOf(JsonObject(row + ("id" to JsonPrimitive("different")))))) }, "Synthetic task") }
        fixture.output = buildJsonObject { put("script_out", "") }; val selected = task()
        val output = repository.output(selected, repository.results(selected).single()); assertEquals("", output.output); assertNull(output.command)
    }
    @Test fun `待恢复权限撤销取消均不提交系统任务仅明确许可运行`() = runBlocking {
        val selected = task(); repository.recoveryPending = { true }; rejected { change(NasTaskChange(NasTaskAction.DELETE, selected)) }
        repository.recoveryPending = { false }; fixture.accessFailure = IOException("Synthetic access")
        rejected { change(NasTaskChange(NasTaskAction.DELETE, selected)) }; assertTrue(fixture.requests.none { it.write })
        fixture.accessFailure = null; rejected { repository.change(NasTaskChange(NasTaskAction.DELETE, selected)) { throw CancellationException() } }; assertTrue(fixture.requests.none { it.write })
        fixture.rows = listOf(JsonObject(NasScheduledTaskFixture.row() + ("type" to JsonPrimitive("system"))))
        val system = task(); assertNull(repository.inspect(system)); assertTrue(change(NasTaskChange(NasTaskAction.RUN, system)))
        assertTrue(fixture.requests.none { it.method == "get" }); assertEquals(1, fixture.requests.count { it.write })
    }
}
