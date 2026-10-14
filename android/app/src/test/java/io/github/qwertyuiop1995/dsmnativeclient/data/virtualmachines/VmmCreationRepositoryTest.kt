package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class VmmCreationRepositoryTest {
    private val scenario = VmmCreationFixture(); private val fixture get() = scenario.fixture
    private var snapshot: VmmCreationSnapshot? = null; private var progress = VmmCreationProgress()
    private val stages = mutableListOf<VmmCreationStage>()
    private fun checkpoint(value: VmmCreationProgress) { progress = value; stages += value.stage }
    private suspend fun create(repo: VmmManagementRepository, plan: VmmCreationPlan) = repo.createGuest(plan, UUID.randomUUID().toString(), { snapshot = it }, ::checkpoint, pollAttempts = 1)
    private suspend fun resume(repo: VmmManagementRepository, write: Boolean = false) = repo.resumeCreation(snapshot!!, progress, write, pollAttempts = 1, checkpoint = ::checkpoint)

    @Test fun `公开多空白和映像盘多网卡全部保留且设置回执后才完成`() = runBlocking {
        val repo = scenario.repository().virtualMachineManagement; val resources = repo.creationResources(VmmSource.PUBLIC)
        val plan = scenario.plan(repo).copy(disks = listOf(VmmCreationDisk(10), VmmCreationDisk(image = resources.images.single().ref)), networks = listOf(resources.networks.single(), null))
        create(repo, plan)
        assertEquals(VmmCreationStage.COMPLETE, progress.stage); assertEquals(listOf("create", "set"), fixture.writes.map { it.method })
        assertTrue(fixture.writes.all { it.oneShot && it.version == 1 && it.api == VmmSource.PUBLIC.guestApi })
        val fields = fixture.writes.first().fields
        assertEquals(setOf("guest_name", "storage_id", "auto_clean_task", "vdisks", "vnics"), fields.keys)
        assertEquals(JsonPrimitive(false), fields["auto_clean_task"]); assertEquals(JsonPrimitive(10_240L), fields["vdisks"]!!.jsonArray[0].jsonObject["vdisk_size"])
        assertEquals(JsonPrimitive(1), fields["vdisks"]!!.jsonArray[1].jsonObject["create_type"])
        assertEquals("", fields["vnics"]!!.jsonArray[1].jsonObject.vmmString("network_id"))
        assertTrue(VmmCreationStage.CONFIGURING in stages)
    }
    @Test fun `内部三种模板固件ISO和KiB读取完整核对只写一次`() = runBlocking {
        for (preset in listOf(VmmCreationPreset.LINUX, VmmCreationPreset.WINDOWS, VmmCreationPreset.OTHER)) {
            val scenario = VmmCreationFixture(); scenario.fixture.images = listOf(VmmFixture.image(type = "iso"))
            val repo = scenario.repository().virtualMachineManagement
            val resources = repo.creationResources(VmmSource.INTERNAL)
            val plan = scenario.plan(repo, preset).copy(iso = resources.images.single(), uefi = preset != VmmCreationPreset.OTHER)
            create(repo, plan)
            assertEquals(VmmCreationStage.COMPLETE, progress.stage); assertEquals(1, scenario.fixture.writes.size)
            val fields = scenario.fixture.writes.single().fields
            assertEquals(JsonPrimitive(512), fields["vram_size"]); assertEquals(JsonPrimitive(10), fields["increaseAllocatedSize"])
            assertEquals(JsonPrimitive(preset != VmmCreationPreset.OTHER), fields["use_ovmf"]); assertEquals(JsonPrimitive(false), fields["poweron_after_create"])
            assertEquals(JsonPrimitive(if (preset == VmmCreationPreset.LINUX) "vmvga" else "vga"), fields["video_card"])
            assertEquals(JsonPrimitive(true), fields["hyperv_enlighten"]); assertFalse(fields.containsKey("guest_name"))
        }
    }
    @Test fun `仅内部与FORM可创建而不调用公开任务`() = runBlocking {
        fixture.public = false; fixture.format = "FORM"
        val repo = scenario.repository().virtualMachineManagement
        assertEquals(listOf(VmmSource.INTERNAL), repo.creationSources())
        create(repo, scenario.plan(repo, VmmCreationPreset.LINUX))
        assertEquals(VmmCreationStage.COMPLETE, progress.stage); assertTrue(fixture.calls.none { it.api.contains(".API.") })
        assertEquals(JsonPrimitive("512"), fixture.writes.single().fields["vram_size"])
    }
    @Test fun `原名冲突存储改名冻结残缺清单和撤权都不创建`() = runBlocking {
        for (change in 0..4) {
            val scenario = VmmCreationFixture(); val repo = scenario.repository().virtualMachineManagement; val plan = scenario.plan(repo)
            when (change) {
                0 -> scenario.fixture.guests += VmmFixture.guest("other", plan.configuration.name.uppercase())
                1 -> scenario.selectedStorageName = "Changed storage"
                2 -> scenario.storageHealthy = false
                3 -> scenario.fixture.total = 900
                4 -> scenario.fixture.allowed = false
            }
            assertTrue(runCatching { create(repo, plan) }.isFailure); assertTrue(scenario.fixture.writes.isEmpty())
        }
        val repo = scenario.repository().virtualMachineManagement; val plan = scenario.plan(repo, VmmCreationPreset.LINUX)
        scenario.storageFrozen = JsonPrimitive(true); assertTrue(runCatching { create(repo, plan) }.isFailure); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `可选资源普通读取失败降级但认证和证书失败上抛`() = runBlocking {
        fixture.errors = mapOf("SYNO.Virtualization.API.Network" to "list" to 500, "SYNO.Virtualization.API.Guest.Image" to "list" to 500)
        val repo = scenario.repository().virtualMachineManagement; val resources = repo.creationResources(VmmSource.PUBLIC)
        assertFalse(resources.networksAvailable); assertFalse(resources.imagesAvailable); assertTrue(resources.storages.isNotEmpty())
        fixture.errors = mapOf("SYNO.Virtualization.API.Network" to "list" to 106)
        assertTrue(runCatching { repo.creationResources(VmmSource.PUBLIC) }.isFailure)
        fixture.errors = emptyMap(); fixture.before = { if (it.api.endsWith("Network")) throw javax.net.ssl.SSLHandshakeException("synthetic certificate") }
        assertTrue(runCatching { repo.creationResources(VmmSource.PUBLIC) }.isFailure)
    }
    @Test fun `未知版本允许内部创建并保留完整提交阶段`() = runBlocking {
        fixture.known = false; fixture.packageVersion = "future"; val repo = scenario.repository().virtualMachineManagement
        create(repo, scenario.plan(repo, VmmCreationPreset.LINUX)); assertEquals(VmmCreationStage.COMPLETE, progress.stage)
        assertTrue(fixture.writes.isNotEmpty()); assertTrue(fixture.calls.none { it.api in setOf("SYNO.Core.System", "SYNO.Core.Package") })
    }
    @Test fun `公开任务未完成不续写只读刷新完成后显式继续`() = runBlocking {
        scenario.finished = false; scenario.progress = JsonPrimitive(25)
        val repo = scenario.repository().virtualMachineManagement; create(repo, scenario.plan(repo, power = true))
        assertEquals(VmmCreationStage.CREATING, progress.stage); assertEquals(25, progress.percent)
        scenario.finished = true; scenario.progress = JsonPrimitive(100); resume(repo)
        assertEquals(VmmCreationStage.CREATED, progress.stage); assertEquals(1, fixture.writes.size)
        resume(repo, true); assertEquals(VmmCreationStage.COMPLETE, progress.stage)
        assertEquals(listOf("create", "set", "poweron"), fixture.writes.map { it.method })
    }
    @Test fun `原创建执行内有限轮询可以继续已授权设置但只发送一次创建`() = runBlocking {
        scenario.finished = false; scenario.progress = JsonPrimitive(25)
        val repo = scenario.repository().virtualMachineManagement; val plan = scenario.plan(repo)
        fixture.after = { if (it.api == "SYNO.Virtualization.API.Task.Info") { scenario.finished = true; scenario.progress = JsonPrimitive(100) } }
        repo.createGuest(plan, UUID.randomUUID().toString(), { snapshot = it }, ::checkpoint, pollAttempts = 2)
        assertEquals(VmmCreationStage.COMPLETE, progress.stage); assertEquals(listOf("create", "set"), fixture.writes.map { it.method })
        assertEquals(2, fixture.calls.count { it.api == "SYNO.Virtualization.API.Task.Info" })
    }
    @Test fun `缺公开创建回执不按同名机器认领或重试`() = runBlocking {
        fixture.after = { if (it.method == "create") throw IOException("lost receipt") }
        val repo = scenario.repository().virtualMachineManagement; assertTrue(runCatching { create(repo, scenario.plan(repo)) }.isFailure)
        assertEquals(VmmCreationStage.CREATE_SENT, progress.stage); fixture.after = {}; resume(repo, true)
        assertEquals(VmmCreationStage.CREATE_SENT, progress.stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `缺内部回执只可由UUID和全部参数共同恢复不重新创建`() = runBlocking {
        scenario.missingReceipt = true; val repo = scenario.repository().virtualMachineManagement
        assertTrue(runCatching { create(repo, scenario.plan(repo, VmmCreationPreset.LINUX)) }.isFailure)
        scenario.mutateEcho = { JsonObject(it + ("usb_version" to JsonPrimitive(1))) }
        assertTrue(runCatching { resume(repo) }.isFailure); assertEquals(VmmCreationStage.CREATE_SENT, progress.stage)
        scenario.mutateEcho = { it }; scenario.duplicateTask = true
        assertTrue(runCatching { resume(repo) }.isFailure); assertEquals(VmmCreationStage.CREATE_SENT, progress.stage)
        scenario.duplicateTask = false; resume(repo); assertEquals(VmmCreationStage.COMPLETE, progress.stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `错误任务类型字符串进度旧guest身份和硬件漂移不能完成`() = runBlocking {
        for (kind in 0..3) {
            val scenario = VmmCreationFixture(); val repo = scenario.repository().virtualMachineManagement
            when (kind) {
                0 -> scenario.taskStatus = "clone"
                1 -> scenario.progress = JsonPrimitive("100")
                2 -> scenario.taskGuestOverride = "synthetic-guest"
                3 -> scenario.fixture.after = { if (it.method == "create") scenario.fixture.guests = scenario.fixture.guests.map { row ->
                    if (row["guest_id"]?.jsonPrimitive?.content != scenario.createdId) row else JsonObject(row + ("vnics" to JsonArray(emptyList())))
                } }
            }
            assertTrue(runCatching { create(repo, scenario.plan(repo)) }.isFailure)
            assertEquals(VmmCreationStage.CREATING, progress.stage); assertEquals(1, scenario.fixture.writes.size)
        }
    }
    @Test fun `创建任务身份落盘后任务消失仍按原guest恢复不再次创建`() = runBlocking {
        val repo = scenario.repository().virtualMachineManagement
        fixture.after = { if (it.method == "get" && it.fields["guest_id"]?.jsonPrimitive?.content == scenario.createdId) throw IOException("read failed") }
        assertTrue(runCatching { create(repo, scenario.plan(repo, VmmCreationPreset.LINUX)) }.isFailure)
        assertEquals(scenario.createdId, progress.guest); scenario.taskVisible = false; fixture.after = {}; resume(repo)
        assertEquals(VmmCreationStage.COMPLETE, progress.stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `设置与开机分别要求回执缺回执即使真实状态相同也不完成`() = runBlocking {
        for (lost in listOf("set", "poweron")) {
            val scenario = VmmCreationFixture(); val repo = scenario.repository().virtualMachineManagement
            scenario.fixture.after = { if (it.method == lost) throw IOException("lost receipt") }
            assertTrue(runCatching { create(repo, scenario.plan(repo, power = true)) }.isFailure)
            val expected = if (lost == "set") VmmCreationStage.CONFIGURE_SENT else VmmCreationStage.POWER_SENT
            assertEquals(expected, progress.stage); val count = scenario.fixture.writes.size
            scenario.fixture.after = {}; resume(repo, true); assertEquals(expected, progress.stage); assertEquals(count, scenario.fixture.writes.size)
        }
    }
    @Test fun `开机接受后状态迟到只读恢复完成不重发`() = runBlocking {
        val repo = scenario.repository().virtualMachineManagement
        fixture.after = { if (it.method == "set") fixture.applyWrite = false }
        create(repo, scenario.plan(repo, power = true))
        assertEquals(VmmCreationStage.STARTING, progress.stage); val count = fixture.writes.size
        fixture.guests = fixture.guests.map { row -> if (row["guest_id"]?.jsonPrimitive?.content != scenario.createdId) row
            else JsonObject(row + ("status" to JsonPrimitive("running"))) }
        resume(repo); assertEquals(VmmCreationStage.COMPLETE, progress.stage); assertEquals(count, fixture.writes.size)
    }
    @Test fun `公开创建明确拒绝不转内部设置拒绝保留已创建机器`() = runBlocking {
        fixture.rejection = 105; val repo = scenario.repository().virtualMachineManagement
        assertTrue(runCatching { create(repo, scenario.plan(repo)) }.isFailure); assertEquals(VmmCreationStage.REJECTED, progress.stage)
        assertEquals(1, fixture.writes.size); fixture.rejection = null
        fixture.errors = mapOf(VmmSource.PUBLIC.guestApi to "set" to 105)
        createStateReset(); assertTrue(runCatching { create(repo, scenario.plan(repo)) }.isFailure)
        assertEquals(VmmCreationStage.PARTIAL, progress.stage); assertNotNull(progress.guest)
    }
    @Test fun `最终权限检查撤销和持久化失败阻止后续写入`() = runBlocking {
        val repo = scenario.repository().virtualMachineManagement; val plan = scenario.plan(repo)
        assertTrue(runCatching { repo.createGuest(plan, UUID.randomUUID().toString(), { throw VmmFailure(VmmProblem.STORAGE) }, ::checkpoint) }.isFailure)
        assertTrue(fixture.writes.isEmpty())
        fixture.after = { if (it.method == "create") fixture.allowed = false }
        assertTrue(runCatching { create(repo, plan) }.isFailure)
        assertEquals(VmmCreationStage.CREATED, progress.stage); assertEquals(1, fixture.writes.size)
    }
    @Test fun `续写前配置或网卡MAC并发变化拒绝保存`() = runBlocking {
        for (kind in 0..1) {
            val scenario = VmmCreationFixture(); scenario.finished = false
            val repo = scenario.repository().virtualMachineManagement; create(repo, scenario.plan(repo)); scenario.finished = true; resume(repo)
            assertEquals(VmmCreationStage.CREATED, progress.stage)
            scenario.fixture.guests = scenario.fixture.guests.map { row -> if (row["guest_id"]?.jsonPrimitive?.content != scenario.createdId) row else {
                if (kind == 0) JsonObject(row + ("vcpu_num" to JsonPrimitive(4)))
                else JsonObject(row + ("vnics" to JsonArray(row["vnics"]!!.jsonArray.map { JsonObject(it.jsonObject + ("mac" to JsonPrimitive("02:00:00:00:01:00"))) })))
            } }
            assertTrue(runCatching { resume(repo, true) }.isFailure); assertEquals(1, scenario.fixture.writes.size)
        }
    }
    private fun createStateReset() { progress = VmmCreationProgress(); snapshot = null; stages.clear() }
}
