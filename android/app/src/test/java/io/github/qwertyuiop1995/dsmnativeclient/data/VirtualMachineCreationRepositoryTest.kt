package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.io.IOException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VirtualMachineCreationRepositoryTest {
    @Test
    fun `公开 VMM 创建发送多磁盘多网卡并核对可公开观察的硬件结果`() = runBlocking {
        val scenario = creationScenario()
        val plan = creationPlan().copy(disks = listOf(VmmCreationDisk(32), VmmCreationDisk(8),
            VmmCreationDisk(image = VmmCreationRef("image-1", "Synthetic image"))),
            networks = listOf(networkRef, null, networkRef))
        val result = createProbe(scenario, plan)
        assertCreationComplete(scenario, result)
        val create = scenario.fixture.requests.single { it.vmmCreationFields()["method"] == "create" }
        RequestFixtureAssertions.assertRequest(create, "vmm/create-guest/synthetic-multi-hardware/request.json")
        val fields = create.vmmCreationFields()
        val disks = Json.parseToJsonElement(fields.getValue("vdisks")).jsonArray
        assertEquals(3, disks.size)
        assertEquals(32768, disks[0].jsonObject.getValue("vdisk_size").jsonPrimitive.int)
        assertEquals(8192, disks[1].jsonObject.getValue("vdisk_size").jsonPrimitive.int)
        assertEquals("image-1", disks[2].jsonObject.getValue("image_id").jsonPrimitive.content)
        assertFalse(disks[2].jsonObject.containsKey("vdisk_size"))
        assertEquals(listOf("network-1", "", "network-1"), Json.parseToJsonElement(fields.getValue("vnics")).jsonArray.map { it.jsonObject.getValue("network_id").jsonPrimitive.content })
    }

    @Test
    fun `超过官方八磁盘上限时零请求拒绝`() = runBlocking {
        val scenario = creationScenario()
        val result = createProbe(scenario, creationPlan().copy(disks = List(9) { VmmCreationDisk(8) }))
        assertTrue(result.failure is VmmFailure)
        assertTrue(result.steps.isEmpty()); assertEquals(null, result.snapshot)
        assertTrue(scenario.fixture.calls.isEmpty())
    }

    @Test
    fun `全空附加磁盘与断开网卡可严格回读成功并保留任务记录`() = runBlocking {
        val scenario = creationScenario()
        assertCreationComplete(scenario, createProbe(scenario, multiPlan()))
    }

    @Test
    fun `多硬件回读断线保留未知结果且不清任务`() = runBlocking {
        assertHardwareReadFailure(IOException("synthetic hardware read"))
    }

    @Test
    fun `多硬件回读取消保留未知结果且不清任务`() = runBlocking {
        assertHardwareReadFailure(kotlinx.coroutines.CancellationException("synthetic hardware cancellation"))
    }

    @Test
    fun `多硬件空盘容量错配不确认且不清任务`() = runBlocking {
        val scenario = creationScenario()
        scenario.fixture.after = { call -> if (call.method == "create") changeCreated(scenario) { row ->
            JsonObject(row + ("vdisks" to JsonArray(row.getValue("vdisks").jsonArray.mapIndexed { i, disk ->
                if (i == 1) JsonObject(disk.jsonObject + ("vdisk_size" to JsonPrimitive(7168))) else disk
            })))
        } }
        val result = createProbe(scenario, multiPlan())
        assertCreationIncomplete(scenario, result, VmmCreationStage.CREATING)
        assertTrue(result.failure is VmmFailure)
    }

    @Test
    fun `多硬件NIC多重集错配不确认且不清任务`() = runBlocking {
        val scenario = creationScenario()
        scenario.fixture.after = { call -> if (call.method == "create") changeCreated(scenario) { row ->
            JsonObject(row + ("vnics" to JsonArray(row.getValue("vnics").jsonArray.mapIndexed { i, nic ->
                if (i == 1) JsonObject(nic.jsonObject + ("network_id" to JsonPrimitive("unexpected-network"))) else nic
            })))
        } }
        val result = createProbe(scenario, multiPlan())
        assertCreationIncomplete(scenario, result, VmmCreationStage.CREATING)
        assertTrue(result.failure is VmmFailure)
    }

    @Test
    fun `创建后设置回读失败保留未知结果且不清理任务`() = runBlocking {
        assertCreationSettingsReadFailure(IOException("synthetic settings read"))
    }

    @Test
    fun `创建后设置回读取消保留未知结果且不清理任务`() = runBlocking {
        assertCreationSettingsReadFailure(kotlinx.coroutines.CancellationException("synthetic settings cancellation"))
    }

    @Test
    fun `公开 VMM 创建轮询任务应用配置并完整回读`() = runBlocking {
        val scenario = creationScenario()
        val result = createProbe(scenario)
        assertCreationComplete(scenario, result)
        assertEquals(listOf(VmmCreationStage.CREATE_SENT, VmmCreationStage.CREATING, VmmCreationStage.CREATING,
            VmmCreationStage.CREATED, VmmCreationStage.CONFIGURE_SENT, VmmCreationStage.CONFIGURING,
            VmmCreationStage.CONFIGURED, VmmCreationStage.COMPLETE), result.steps.map { it.stage })
        val create = scenario.fixture.requests.single { it.vmmCreationFields()["method"] == "create" }.vmmCreationFields()
        assertEquals("1", create["version"]); assertEquals("false", create["auto_clean_task"])
        assertEquals("storage-1", create["storage_id"]); assertEquals("Synthetic VM", create["guest_name"])
        val disk = Json.parseToJsonElement(create.getValue("vdisks")).jsonArray.single().jsonObject
        assertEquals(0, disk.getValue("create_type").jsonPrimitive.int)
        assertEquals(32768, disk.getValue("vdisk_size").jsonPrimitive.int)
        assertEquals("network-1", Json.parseToJsonElement(create.getValue("vnics")).jsonArray.single().jsonObject.getValue("network_id").jsonPrimitive.content)
        val set = scenario.fixture.requests.single { it.vmmCreationFields()["method"] == "set" }.vmmCreationFields()
        assertEquals("4", set["vcpu_num"]); assertEquals("4096", set["vram_size"]); assertEquals("2", set["autorun"])
        assertEquals("synthetic-task", result.current.task); assertEquals("guest-1", result.current.guest)
        assertTrue(scenario.fixture.calls.any { it.api.endsWith("Task.Info") && it.fields["task_id"]?.jsonPrimitive?.content == "synthetic-task" })
    }

    @Test
    fun `公开 VMM 创建无网络时按官方契约发送空网络标识`() = runBlocking {
        val scenario = creationScenario()
        assertCreationComplete(scenario, createProbe(scenario, creationPlan().copy(networks = listOf(null))))
        val fields = requireNotNull(scenario.submitted)
        assertEquals("", fields.getValue("vnics").jsonArray.single().jsonObject.getValue("network_id").jsonPrimitive.content)
    }

    @Test
    fun `创建成功但常规配置被拒绝时保留部分完成且不重放创建`() = runBlocking {
        val scenario = creationScenario()
        scenario.fixture.errors = mapOf(VmmSource.PUBLIC.guestApi to "set" to 402)
        val result = createProbe(scenario)
        assertCreationIncomplete(scenario, result, VmmCreationStage.PARTIAL)
        assertTrue(result.failure is DsmFailure); assertEquals("guest-1", result.current.guest)
        assertEquals(listOf("create", "set"), scenario.fixture.writes.map { it.method })
    }

    @Test
    fun `同名虚拟机预检冲突时零创建请求`() = runBlocking {
        val scenario = creationScenario(); scenario.fixture.guests = listOf(VmmFixture.guest("existing", "synthetic vm"))
        val result = createProbe(scenario)
        assertTrue(result.failure is VmmFailure); assertTrue(result.steps.isEmpty())
        assertEquals(listOf("list"), scenario.fixture.calls.map { it.method }); assertTrue(scenario.fixture.writes.isEmpty())
    }

    @Test fun `名称预检取消按提交前取消且零写返回`() = runBlocking { assertCreationPreflightCancelled(VmmSource.PUBLIC.guestApi) }
    @Test fun `存储预检取消按提交前取消且零写返回`() = runBlocking { assertCreationPreflightCancelled("SYNO.Virtualization.API.Storage") }
    @Test fun `网络预检取消按提交前取消且零写返回`() = runBlocking { assertCreationPreflightCancelled("SYNO.Virtualization.API.Network") }
    @Test fun `映像预检取消按提交前取消且零写返回`() = runBlocking { assertCreationPreflightCancelled("SYNO.Virtualization.API.Guest.Image") }

    @Test
    fun `缺少公开任务能力时创建入口关闭`() {
        val repo = repository(VirtualMachineCreationInterceptor(), includeTaskApi = false)
        assertFalse(VmmSource.PUBLIC in repo.virtualMachineManagement.creationSources())
        assertFalse(repo.supportsOfficialVirtualMachineCreation())
    }

    @Test
    fun `缺少公开 Guest 能力时设置入口零请求关闭`() = runBlocking {
        val transport = VirtualMachineCreationInterceptor()
        val result = repository(transport, includeGuestApi = false).settingsProbe(oldConfiguration, newConfiguration)
        assertEquals(listOf(VmmStage.CANCELLED), result.stages)
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, (result.failure as DsmFailure).kind)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `公开 VMM 常规设置提交后完整回读`() = runBlocking {
        val transport = settingsTransport()
        val result = repository(transport).settingsProbe(oldConfiguration, newConfiguration)
        assertEquals(null, result.failure)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED, VmmStage.VERIFIED), result.stages)
        assertEquals(listOf("get", "list", "set", "list", "get"), transport.methods())
        val request = transport.requests[2].vmmCreationFields()
        assertEquals("1", request["version"])
        assertEquals("guest-1", request["guest_id"])
        assertEquals("2", request["vcpu_num"])
        assertEquals("2048", request["vram_size"])
        assertEquals("2", request["autorun"])
        assertEquals("Updated", request["description"])
    }

    @Test
    fun `常规设置名称冲突时不提交`() = runBlocking {
        val transport = VirtualMachineCreationInterceptor(oldDetails(), guestList(
            """{"guest_id":"guest-1","guest_name":"Old name","status":"shutdown"}""",
            """{"guest_id":"guest-2","guest_name":"Synthetic VM","status":"shutdown"}"""))
        assertSettingsChanged(repository(transport).settingsProbe(oldConfiguration, newConfiguration))
        assertEquals(listOf("get", "list"), transport.methods())
    }

    @Test
    fun `常规设置只发送发生变化的字段`() = runBlocking {
        val original = newConfiguration.copy(name = "Old name")
        val transport = VirtualMachineCreationInterceptor(
            guestDetails(name = "Old name", cpu = 2, memory = 2048, autorun = 2, description = "Updated"),
            settingsList("Old name"), """{"success":true,"data":{}}""", settingsList(), newDetails())
        val result = repository(transport).settingsProbe(original, newConfiguration)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED, VmmStage.VERIFIED), result.stages)
        assertEquals(null, result.failure)
        val set = transport.requests.single { it.vmmCreationFields()["method"] == "set" }.vmmCreationFields()
        assertEquals(setOf("guest_id", "new_guest_name"), set.keys - setOf("api", "method", "version", "_sid", "SynoToken"))
    }

    @Test
    fun `常规设置无变化时不发送 set 或认领写入`() = runBlocking {
        val transport = VirtualMachineCreationInterceptor()
        assertSettingsChanged(repository(transport).settingsProbe(oldConfiguration, oldConfiguration))
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun `常规设置锁内发现用户所见基线漂移时零写拒绝`() = runBlocking {
        val transport = VirtualMachineCreationInterceptor(guestDetails(name = "Changed elsewhere", cpu = 1, memory = 1024, autorun = 0, description = ""))
        assertSettingsChanged(repository(transport).settingsProbe(oldConfiguration, newConfiguration))
        assertEquals(listOf("get"), transport.methods())
    }

    @Test
    fun `常规设置回执丢失不以随后相同配置认领成功`() = runBlocking {
        val transport = settingsTransport(reply = "not-json")
        val repo = repository(transport)
        val result = repo.settingsProbe(oldConfiguration, newConfiguration)
        assertEquals(listOf(VmmStage.SUBMITTED), result.stages)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (result.failure as DsmFailure).kind)
        assertEquals(listOf("get", "list", "set"), transport.methods())
        assertEquals("Synthetic VM", repo.virtualMachineManagement.controlTargets().single().name)
        assertEquals(newConfiguration, repo.virtualMachineManagement.settings("guest-1").configuration)
        assertEquals(listOf(VmmStage.SUBMITTED), result.stages)
        assertEquals(1, transport.methods().count { it == "set" })
    }

    @Test
    fun `常规设置写后回读结构失败保持接受而未完成`() = runBlocking {
        val transport = settingsTransport(readback = """{"success":true,"data":{"guest_id":"guest-1"}}""")
        val result = repository(transport).settingsProbe(oldConfiguration, newConfiguration)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED), result.stages)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (result.failure as DsmFailure).kind)
        assertEquals(1, transport.methods().count { it == "set" })
    }

    @Test
    fun `常规设置写请求在途取消保留提交且不重放`() = runBlocking {
        val transport = settingsTransport(reply = CANCEL_RESPONSE)
        val repo = repository(transport)
        val captured = CompletableDeferred<SettingsProbe>()
        val job = launch(Dispatchers.Default) { captured.complete(repo.settingsProbe(oldConfiguration, newConfiguration)) }
        assertTrue(transport.cancellationRequestEntered.await(5, TimeUnit.SECONDS))
        job.cancel(); transport.releaseCancellationRequest.countDown(); job.join()
        val result = captured.await()
        assertEquals(listOf(VmmStage.SUBMITTED), result.stages)
        assertTrue("实际失败：${result.failure}", result.failure is kotlinx.coroutines.CancellationException)
        assertEquals(listOf("get", "list", "set"), transport.methods())
    }

    @Test
    fun `缺少用户所见名称基线时零写拒绝`() = runBlocking {
        val transport = VirtualMachineCreationInterceptor(oldDetails())
        assertSettingsChanged(repository(transport).settingsProbe(oldConfiguration.copy(name = ""), newConfiguration))
        assertEquals(listOf("get"), transport.methods())
    }

    private data class SettingsProbe(val stages: List<VmmStage>, val failure: Throwable?)
    private suspend fun DsmRepository.settingsProbe(original: VmmConfiguration, desired: VmmConfiguration): SettingsProbe {
        val stages = mutableListOf<VmmStage>()
        val result = runCatching { virtualMachineManagement.saveSettings(VmmSettings("guest-1", "shutdown", VmmSource.PUBLIC, original), desired, stages::add) }
        return SettingsProbe(stages.toList(), result.exceptionOrNull())
    }
    private fun assertSettingsChanged(result: SettingsProbe) {
        assertEquals(listOf(VmmStage.CANCELLED), result.stages)
        assertEquals(VmmProblem.CHANGED, (result.failure as VmmFailure).problem)
    }
    private val oldConfiguration = VmmConfiguration("Old name", "", 1, 1024, null, 0)
    private val newConfiguration = VmmConfiguration("Synthetic VM", "Updated", 2, 2048, null, 2)
    private fun oldDetails() = guestDetails(name = "Old name", cpu = 1, memory = 1024, autorun = 0, description = "")
    private fun newDetails() = guestDetails(cpu = 2, memory = 2048, autorun = 2, description = "Updated")
    private fun settingsList(name: String = "Synthetic VM") = guestList("""{"guest_id":"guest-1","guest_name":"$name","status":"shutdown"}""")
    private fun settingsTransport(reply: String = """{"success":true,"data":{}}""", readback: String = newDetails()) =
        VirtualMachineCreationInterceptor(oldDetails(), settingsList("Old name"), reply, settingsList(), readback)

    @Test
    fun `创建响应缺任务标识时同名回读也绝不认领或设置`() = runBlocking {
        val scenario = creationScenario(); scenario.missingReceipt = true
        val result = createProbe(scenario)
        assertCreationIncomplete(scenario, result, VmmCreationStage.CREATE_SENT)
        assertTrue(result.failure is DsmFailure)
        assertUnknownCreationCannotResume(scenario, result)
    }

    @Test
    fun `创建提交响应模糊时同名回读也不重放或设置`() = runBlocking {
        val scenario = creationScenario()
        scenario.fixture.after = { if (it.method == "create") throw IOException("synthetic create receipt") }
        val result = createProbe(scenario)
        assertCreationIncomplete(scenario, result, VmmCreationStage.CREATE_SENT)
        assertTrue(result.failure is DsmFailure)
        scenario.fixture.after = {}
        assertUnknownCreationCannotResume(scenario, result)
    }

    @Test
    fun `任务终态结构无效时只做任务回读且不按名称设置`() = runBlocking {
        val scenario = creationScenario(); scenario.taskOverride = VmmFixture.obj("""{"finish":"true","task_info":{"guest_id":"guest-1","status":"create","progress":100}}""")
        val result = createProbe(scenario)
        assertCreationIncomplete(scenario, result, VmmCreationStage.CREATING)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (result.failure as DsmFailure).kind)
        assertEquals(null, result.current.guest); assertEquals(listOf("create"), scenario.fixture.writes.map { it.method })
    }

    @Test
    fun `任务终态缺 guest 标识时不设置且保留任务证据`() = runBlocking {
        val scenario = creationScenario(); scenario.taskOverride = VmmFixture.obj("""{"finish":true,"task_info":{"status":"create","progress":100}}""")
        val result = createProbe(scenario)
        assertCreationIncomplete(scenario, result, VmmCreationStage.CREATING)
        assertEquals("synthetic-task", result.current.task); assertEquals(null, result.current.guest)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (result.failure as DsmFailure).kind)
        assertEquals(listOf("create"), scenario.fixture.writes.map { it.method })
    }

    @Test
    fun `任务轮询取消保留任务证据且不设置或清理`() = runBlocking {
        val scenario = creationScenario()
        val result = cancelledCreateProbe(scenario) { it.api.endsWith("Task.Info") }
        assertCreationIncomplete(scenario, result, VmmCreationStage.CREATING)
        assertTrue("实际失败：${result.failure}", result.failure is kotlinx.coroutines.CancellationException)
        assertEquals("synthetic-task", result.current.task); assertEquals(listOf("create"), scenario.fixture.writes.map { it.method })
    }

    @Test
    fun `创建配置提交未知且回读不匹配时保留任务证据`() = runBlocking {
        val scenario = creationScenario()
        scenario.fixture.before = { if (it.method == "set") scenario.fixture.applyWrite = false }
        scenario.fixture.after = { if (it.method == "set") throw IOException("synthetic settings receipt") }
        val result = createProbe(scenario)
        assertCreationIncomplete(scenario, result, VmmCreationStage.CONFIGURE_SENT)
        assertTrue(result.failure is DsmFailure); assertEquals("guest-1", result.current.guest)
        scenario.fixture.before = {}; scenario.fixture.after = {}
        val steps = mutableListOf<VmmCreationProgress>()
        scenario.repository().virtualMachineManagement.resumeCreation(requireNotNull(result.snapshot), result.current, true, 1, steps::add)
        assertTrue(steps.isEmpty()); assertEquals(listOf("create", "set"), scenario.fixture.writes.map { it.method })
    }

    @Test
    fun `创建配置回读 guest 标识错配时不确认且保留任务证据`() = runBlocking {
        assertStrictCreationReadbackRejected { JsonObject(it + ("guest_id" to JsonPrimitive("other-guest"))) }
    }
    @Test
    fun `创建配置回读缺字段时不确认且保留任务证据`() = runBlocking {
        assertStrictCreationReadbackRejected { JsonObject(it - "vcpu_num") }
    }
    @Test
    fun `创建配置回读字段类型畸形时不确认且保留任务证据`() = runBlocking {
        assertStrictCreationReadbackRejected { JsonObject(it + ("vram_size" to JsonPrimitive("4096"))) }
    }

    private data class CreationProbe(val snapshot: VmmCreationSnapshot?, val steps: List<VmmCreationProgress>, val failure: Throwable?) {
        val current get() = steps.lastOrNull() ?: VmmCreationProgress()
    }
    private val networkRef = VmmCreationRef("network-1", "Synthetic network")
    private fun creationPlan() = VmmCreationPlan(VmmCreationPreset.GENERAL,
        VmmConfiguration("Synthetic VM", "Synthetic description", 4, 4096, null, 2),
        VmmCreationStorage(VmmCreationRef("storage-1", "Synthetic storage")), listOf(VmmCreationDisk(32)), listOf(networkRef))
    private fun multiPlan() = creationPlan().copy(disks = listOf(VmmCreationDisk(32), VmmCreationDisk(8)), networks = listOf(null, null))
    private fun creationScenario() = VmmCreationFixture().also {
        it.fixture.format = "FORM"; it.fixture.internal = false; it.fixture.guests = emptyList()
        it.createdId = "guest-1"; it.taskId = "synthetic-task"
    }
    private suspend fun createProbe(scenario: VmmCreationFixture, plan: VmmCreationPlan = creationPlan()): CreationProbe {
        var snapshot: VmmCreationSnapshot? = null; val steps = mutableListOf<VmmCreationProgress>()
        val result = runCatching { scenario.repository().virtualMachineManagement.createGuest(plan, "synthetic-request", { snapshot = it }, steps::add, pollAttempts = 1) }
        return CreationProbe(snapshot, steps.toList(), result.exceptionOrNull())
    }
    private suspend fun cancelledCreateProbe(scenario: VmmCreationFixture, plan: VmmCreationPlan = creationPlan(),
        matches: (VmmFixture.Call) -> Boolean): CreationProbe = coroutineScope {
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val captured = CompletableDeferred<CreationProbe>()
        scenario.fixture.before = { if (matches(it)) { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        val job = launch(Dispatchers.Default) { captured.complete(createProbe(scenario, plan)) }
        assertTrue(entered.await(5, TimeUnit.SECONDS)); job.cancel(); release.countDown(); job.join()
        captured.await().also { assertTrue(it.failure is kotlinx.coroutines.CancellationException) }
    }
    private fun assertCreationComplete(scenario: VmmCreationFixture, result: CreationProbe) {
        assertEquals(null, result.failure); assertEquals(VmmCreationStage.COMPLETE, result.current.stage)
        assertEquals(1, scenario.fixture.writes.count { it.method == "create" })
        assertTrue(scenario.fixture.writes.all { it.oneShot && it.api == VmmSource.PUBLIC.guestApi })
        assertFalse(scenario.fixture.calls.any { it.method == "clear" })
        assertTrue(result.current.hardware != null)
    }
    private fun assertCreationIncomplete(scenario: VmmCreationFixture, result: CreationProbe, stage: VmmCreationStage) {
        assertEquals(stage, result.current.stage); assertTrue(result.steps.none { it.stage == VmmCreationStage.COMPLETE })
        assertEquals(1, scenario.fixture.writes.count { it.method == "create" })
        assertFalse(scenario.fixture.calls.any { it.method == "clear" })
    }
    private suspend fun assertUnknownCreationCannotResume(scenario: VmmCreationFixture, result: CreationProbe) {
        val repo = scenario.repository().virtualMachineManagement
        assertEquals("Synthetic VM", repo.controlTargets().single().name)
        val steps = mutableListOf<VmmCreationProgress>()
        repo.resumeCreation(requireNotNull(result.snapshot), result.current, true, 1, steps::add)
        assertTrue(steps.isEmpty()); assertEquals(listOf("create"), scenario.fixture.writes.map { it.method })
    }
    private suspend fun assertCreationPreflightCancelled(api: String) {
        val scenario = creationScenario()
        val result = cancelledCreateProbe(scenario) { it.api == api }
        assertTrue("实际失败：${result.failure}", result.failure is kotlinx.coroutines.CancellationException); assertEquals(null, result.snapshot)
        assertTrue(result.steps.isEmpty()); assertTrue(scenario.fixture.writes.isEmpty())
    }
    private suspend fun assertHardwareReadFailure(error: Exception) {
        val scenario = creationScenario()
        val matches: (VmmFixture.Call) -> Boolean = { it.api == VmmSource.PUBLIC.guestApi && it.method == "get" }
        val result = if (error is kotlinx.coroutines.CancellationException) cancelledCreateProbe(scenario, multiPlan(), matches)
            else { scenario.fixture.before = { if (matches(it)) throw error }; createProbe(scenario, multiPlan()) }
        assertCreationIncomplete(scenario, result, VmmCreationStage.CREATING)
        assertTrue(result.failure != null); assertEquals("guest-1", result.current.guest)
        assertEquals(listOf("create"), scenario.fixture.writes.map { it.method })
    }
    private suspend fun assertCreationSettingsReadFailure(error: Exception) {
        val scenario = creationScenario()
        val matches: (VmmFixture.Call) -> Boolean = { it.api == VmmSource.PUBLIC.guestApi && it.method == "get" && scenario.fixture.writes.any { w -> w.method == "set" } }
        val result = if (error is kotlinx.coroutines.CancellationException) cancelledCreateProbe(scenario, matches = matches)
            else { scenario.fixture.before = { if (matches(it)) throw error }; createProbe(scenario) }
        assertCreationIncomplete(scenario, result, VmmCreationStage.CONFIGURING)
        assertTrue(result.failure != null); assertEquals("guest-1", result.current.guest)
        assertEquals(listOf("create", "set"), scenario.fixture.writes.map { it.method })
    }
    private fun changeCreated(scenario: VmmCreationFixture, change: (JsonObject) -> JsonObject) {
        scenario.fixture.guests = scenario.fixture.guests.map { if (it["guest_id"]?.jsonPrimitive?.content == scenario.createdId) change(it) else it }
    }
    private suspend fun assertStrictCreationReadbackRejected(change: (JsonObject) -> JsonObject) {
        val scenario = creationScenario()
        scenario.fixture.after = { if (it.method == "set") scenario.fixture.getOverride = change(scenario.fixture.guests.single()) }
        val result = createProbe(scenario)
        assertCreationIncomplete(scenario, result, VmmCreationStage.CONFIGURING)
        assertEquals("guest-1", result.current.guest); assertEquals(listOf("create", "set"), scenario.fixture.writes.map { it.method })
    }

    private fun repository(
        interceptor: Interceptor,
        includeTaskApi: Boolean = true,
        includeGuestApi: Boolean = true,
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "synthetic-session", "synthetic-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        buildList {
            if (includeGuestApi) {
                add(ApiCapability("SYNO.Virtualization.API.Guest", "entry.cgi", 1, 1))
            }
            add(ApiCapability("SYNO.Virtualization.API.Storage", "entry.cgi", 1, 1))
            add(ApiCapability("SYNO.Virtualization.API.Network", "entry.cgi", 1, 1))
            add(ApiCapability("SYNO.Virtualization.API.Guest.Image", "entry.cgi", 1, 1))
            if (includeTaskApi) {
                add(ApiCapability("SYNO.Virtualization.API.Task.Info", "entry.cgi", 1, 1))
            }
        }.associateBy(ApiCapability::name),
    )

    private fun guestList(vararg guests: String) =
        """{"success":true,"data":{"guests":[${guests.joinToString(",")}]}}"""

    private fun guestDetails(
        name: String = "Synthetic VM",
        cpu: Int,
        memory: Int,
        autorun: Int,
        description: String,
    ) = """{"success":true,"data":{"guest_id":"guest-1","guest_name":"$name","status":"shutdown","vcpu_num":$cpu,"vram_size":$memory,"autorun":$autorun,"description":"$description"}}"""
}

private class VirtualMachineCreationInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()
    fun methods() = requests.map { it.vmmCreationFields()["method"] }
    val cancellationRequestEntered = CountDownLatch(1)
    val releaseCancellationRequest = CountDownLatch(1)

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val response = pending.removeFirstOrNull() ?: error("缺少合成 VMM 创建响应")
        if (response == ERROR_RESPONSE) throw IOException("synthetic readback disconnect")
        if (response == CANCEL_RESPONSE) {
            cancellationRequestEntered.countDown()
            check(releaseCancellationRequest.await(5, TimeUnit.SECONDS)) { "合成取消请求未释放" }
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                (if (response == CANCEL_RESPONSE) """{"success":true,"data":{}}""" else response)
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}

private const val CANCEL_RESPONSE = "__synthetic_cancellation__"
private const val ERROR_RESPONSE = "__synthetic_error__"

private fun Request.vmmCreationFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
