package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.io.IOException
import java.lang.reflect.Modifier
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.After
import org.junit.Test

/** 旧状态策略的业务断言迁到现行模型、仓储和持久化阶段；不构造旧的结果投影。 */
class VirtualMachineMutationStatePolicyTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    @After fun cleanup() { scope.cancel() }
    private suspend fun idle(busy: () -> Boolean) = withTimeout(8_000) { while (busy()) delay(5) }

    @Test fun `Guest 外链在映像编辑期间拒绝`() {
        assertFalse(virtualMachineGuestExternalNavigationBlocked(VirtualMachineMutationWorkspaceState()))
        assertTrue(virtualMachineGuestExternalNavigationBlocked(VirtualMachineMutationWorkspaceState(imageImportEditorVisible = true)))
    }
    @Test fun `当前创建设置和生命周期模型各自保护编辑与确认`() = runBlocking {
        val scenario = VmmCreationFixture(); val repo = scenario.repository()
        val creation = VmmCreationModel(scope, { repo }, { VmmCreationStore(MemoryPreferences()) }, { true })
        assertTrue(creation.open()); idle { creation.state.value.busy }; assertTrue(creation.hasPending())
        creation.close(); assertFalse(creation.hasPending())
        val settings = VmmSettingsModel(scope, { repo }, { VmmSettingsStore(MemoryPreferences()) }, { true })
        assertTrue(settings.open("synthetic-guest")); idle { settings.state.value.busy }; assertTrue(settings.hasPending())
        settings.close(); assertFalse(settings.hasPending())
        val controls = VmmControlModel(scope, { repo }, { VmmControlStore(MemoryPreferences()) }, { true })
        controls.refresh(); idle { controls.state.value.busy }
        assertTrue(controls.request(controls.state.value.targets, VmmAction.START)); assertTrue(controls.state.value.blocked)
        controls.cancel(); assertFalse(controls.state.value.blocked); assertTrue(scenario.fixture.writes.isEmpty())
    }
    @Test fun `配置摘要和对象身份稳定且不同请求不可混同`() {
        val config = VmmConfiguration("Synthetic", "Description", 2, 2048, 256, 1)
        assertEquals(config.digest(VmmSource.PUBLIC), config.copy().digest(VmmSource.PUBLIC))
        assertNotEquals(config.digest(VmmSource.PUBLIC), config.copy(cpu = 4).digest(VmmSource.PUBLIC))
        assertNotEquals(config.digest(VmmSource.PUBLIC), config.digest(VmmSource.INTERNAL))
        val target = VmmControlTarget("one", "Synthetic", "shutdown", setOf(VmmAction.START))
        assertEquals(vmmIdentity(target), vmmIdentity(target.copy()))
        assertNotEquals(vmmIdentity(target), vmmIdentity(target.copy(id = "two")))
        assertNotEquals(vmmIdentity(target), vmmIdentity(target.copy(name = "Renamed")))
    }
    @Test fun `同步提交先占用模型并阻止重复创建与外部竞争`() = runBlocking {
        val scenario = VmmCreationFixture(); val repo = scenario.repository(); val store = VmmCreationStore(MemoryPreferences())
        var allowed = true
        val model = VmmCreationModel(scope, { repo }, { store }, { allowed }, pollAttempts = 1)
        assertTrue(model.open()); idle { model.state.value.busy }; model.change(model.state.value.draft!!.copy(name = "Synthetic created"))
        allowed = false; assertFalse(model.create()); assertTrue(model.state.value.editor); assertTrue(scenario.fixture.writes.isEmpty())
        allowed = true; assertTrue(model.create()); assertFalse(model.create()); idle { model.state.value.busy }
        assertEquals(VmmCreationStage.COMPLETE, model.state.value.records.single().progress.stage)
        assertEquals(listOf("create", "set"), scenario.fixture.writes.map { it.method })
    }
    @Test fun `映像编辑器阻止工作区退出`() {
        assertFalse(virtualMachineMutationBlocksWorkspaceExit(VirtualMachineMutationWorkspaceState()))
        assertTrue(virtualMachineMutationBlocksWorkspaceExit(VirtualMachineMutationWorkspaceState(imageImportEditorVisible = true)))
    }
    @Test fun `未发送取消与明确拒绝可重新打开设置且不隐式重试`() = runBlocking {
        for (case in 0..3) {
            val f = VmmFixture(); val repo = f.repository(); val store = VmmSettingsStore(MemoryPreferences())
            val model = VmmSettingsModel(scope, { repo }, { store }, { true })
            assertTrue(model.open("synthetic-guest")); idle { model.state.value.busy }; model.change(model.state.value.draft!!.copy(name = "Updated"))
            when (case) { 0 -> f.allowed = false; 1 -> f.rejection = 105; 2 -> f.rejection = 102; else -> f.ownerValid = false }
            if (case == 3) assertFalse(model.save()) else { assertTrue(model.save()); idle { model.state.value.busy } }
            assertEquals(if (case in 1..2) 1 else 0, f.writes.size)
            val stage = store.records(repo.owner!!).singleOrNull()?.stage
            if (case != 3) assertEquals(if (case == 0) VmmStage.CANCELLED else VmmStage.REJECTED, stage)
            f.allowed = true; f.ownerValid = true; f.rejection = null; model.close()
            assertTrue(model.open("synthetic-guest")); idle { model.state.value.busy }; assertTrue(model.state.value.editor)
            assertEquals(if (case in 1..2) 1 else 0, f.writes.size); model.clear()
        }
    }
    @Test fun `已发送未知结果不能关闭记录或再次编辑原目标`() = runBlocking {
        val f = VmmFixture(); val repo = f.repository(); val store = VmmSettingsStore(MemoryPreferences())
        val model = VmmSettingsModel(scope, { repo }, { store }, { true })
        model.open("synthetic-guest"); idle { model.state.value.busy }; model.change(model.state.value.draft!!.copy(name = "Updated"))
        f.after = { if (it.method == "set") throw IOException("Synthetic lost receipt") }
        assertTrue(model.save()); idle { model.state.value.busy }; assertEquals(VmmStage.SUBMITTED, model.state.value.records.single().stage)
        f.after = {}; model.refresh(); idle { model.state.value.busy }; model.dismiss()
        assertTrue(model.hasPending()); assertTrue(model.open("synthetic-guest")); idle { model.state.value.busy }
        assertTrue(model.state.value.failure is VmmFailure); assertNull(model.state.value.draft); assertFalse(model.save()); assertEquals(1, f.writes.size)
    }
    @Test fun `同账号重新绑定仓库后迟到表单不会覆盖新草稿`() = runBlocking {
        val f = VmmFixture(); var repo = f.repository(); val store = VmmSettingsStore(MemoryPreferences())
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        f.before = { if (it.method == "get") { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        val model = VmmSettingsModel(scope, { repo }, { store }, { true })
        try {
            assertTrue(model.open("synthetic-guest")); assertTrue(entered.await(5, TimeUnit.SECONDS))
            model.clear(); repo = f.repository("next"); f.before = {}; release.countDown()
            assertTrue(model.open("synthetic-guest")); idle { model.state.value.busy }
            model.change(model.state.value.draft!!.copy(name = "New draft")); delay(50)
            assertEquals("New draft", model.state.value.draft!!.name); assertTrue(f.writes.isEmpty())
        } finally { release.countDown() }
    }
    @Test fun `跨身份回调和持久记录不能投影到新账号`() = runBlocking {
        val f = VmmFixture(); var repo = f.repository(); val store = VmmControlStore(MemoryPreferences())
        val entered = CountDownLatch(1); val release = CountDownLatch(1)
        val model = VmmControlModel(scope, { repo }, { store }, { true })
        model.refresh(); idle { model.state.value.busy }
        f.before = { if (it.method == "poweron") { entered.countDown(); assertTrue(release.await(5, TimeUnit.SECONDS)) } }
        try {
            model.request(model.state.value.targets, VmmAction.START); assertTrue(model.confirm(model.state.value.confirmation!!)); assertTrue(entered.await(5, TimeUnit.SECONDS))
            model.clear(); repo = f.repository("next", "other"); f.before = {}; release.countDown()
            model.refresh(); idle { model.state.value.busy }; delay(50)
            assertTrue(model.state.value.records.isEmpty()); assertEquals(1, f.writes.size)
        } finally { release.countDown() }
    }
    @Test fun `持久阶段只允许完成或明确拒绝记录被移除`() {
        val owner = io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner("profile", "identity", "session")
        for (stage in VmmStage.entries) {
            val store = VmmSettingsStore(MemoryPreferences())
            val record = VmmSettingsActivity("record", owner, vmmDigest("id"), vmmDigest("name"), vmmDigest("new"), vmmDigest("desired"), VmmSource.PUBLIC)
            store.begin(record)
            if (stage != VmmStage.PREPARED) {
                if (stage != VmmStage.CANCELLED) store.checkpoint(owner, record.id, VmmStage.SUBMITTED)
                if (stage in setOf(VmmStage.ACCEPTED, VmmStage.VERIFIED)) store.checkpoint(owner, record.id, VmmStage.ACCEPTED)
                if (stage in setOf(VmmStage.VERIFIED, VmmStage.REJECTED, VmmStage.CANCELLED)) store.checkpoint(owner, record.id, stage)
            }
            val current = store.records(owner).single(); assertEquals(stage, current.stage)
            val pending = stage in setOf(VmmStage.PREPARED, VmmStage.SUBMITTED, VmmStage.ACCEPTED)
            assertEquals(pending, runCatching { store.dismiss(owner, record.id) }.isFailure)
            assertEquals(pending, store.records(owner).isNotEmpty())
        }
    }
    @Test fun `落盘失败持续阻止写入不能借关闭绕过`() = runBlocking {
        val f = VmmFixture(); val repo = f.repository(); val preferences = MemoryPreferences(); val store = VmmSettingsStore(preferences)
        val model = VmmSettingsModel(scope, { repo }, { store }, { true })
        model.open("synthetic-guest"); idle { model.state.value.busy }; model.change(model.state.value.draft!!.copy(name = "Updated"))
        preferences.commitSucceeds = false; assertTrue(model.save()); idle { model.state.value.busy }
        assertTrue(model.state.value.failure is VmmFailure); model.dismiss(); assertTrue(model.hasPending()); assertTrue(f.writes.isEmpty())
    }
    @Test fun `映像导入任务未完成时保护原任务与原映像`() = runBlocking {
        val scenario = VmmTaskFixture(); scenario.finished = false
        val repo = scenario.repository(); val store = VmmTaskStore(MemoryPreferences())
        val model = VmmTaskModel(scope, { repo }, { store }, { true }, pollAttempts = 1)
        assertTrue(model.startImport(scenario.target())); idle { model.state.value.busy }
        val record = model.state.value.imports.single(); model.dismiss(record.id, VmmTaskAction.IMPORT)
        assertTrue(model.state.value.imports.single().pending); assertTrue(model.protectsImage(scenario.imageId, "Imported image"))
        assertFalse(model.startImport(scenario.target())); assertEquals(1, scenario.fixture.writes.size)
    }
    @Test fun `任务清理只使用用户确认的原始基线`() = runBlocking {
        val scenario = VmmTaskFixture(); scenario.tasks["one"] = VmmTaskFixture.task()
        val repo = scenario.repository(); val store = VmmTaskStore(MemoryPreferences()); val model = VmmTaskModel(scope, { repo }, { store }, { true })
        assertTrue(model.requestCleanup()); idle { model.state.value.busy }; assertTrue(model.state.value.active)
        val original = model.state.value.confirmation!!
        scenario.tasks["new"] = VmmTaskFixture.task()
        assertTrue(model.confirmCleanup(original)); idle { model.state.value.busy }
        assertEquals(setOf("new"), scenario.tasks.keys); assertEquals(VmmStage.VERIFIED, model.state.value.cleanups.single().items.single().stage)
        assertEquals(1, scenario.fixture.writes.size)
    }
    @Test fun `清理取消保留已提交项并停止后续任务`() = runBlocking {
        val scenario = VmmTaskFixture(); scenario.tasks["one"] = VmmTaskFixture.task(); scenario.tasks["two"] = VmmTaskFixture.task()
        val repo = scenario.repository(); val store = VmmTaskStore(MemoryPreferences()); val model = VmmTaskModel(scope, { repo }, { store }, { true })
        model.requestCleanup(); idle { model.state.value.busy }; model.cancelCleanup(); assertTrue(scenario.fixture.writes.isEmpty())
        model.requestCleanup(); idle { model.state.value.busy }
        scenario.fixture.after = { if (it.method == "clear") throw CancellationException("Synthetic cancellation") }
        model.confirmCleanup(model.state.value.confirmation!!); idle { model.state.value.busy }
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.CANCELLED), store.cleanups(repo.owner!!).single().items.map { it.stage })
        assertEquals(1, scenario.fixture.writes.size)
    }
    @Test fun `设置回读区分匹配差异消失与读取失败`() = runBlocking {
        val f = VmmFixture(); val repo = f.repository().virtualMachineManagement
        val baseline = repo.settings("synthetic-guest"); val desired = baseline.configuration.copy(name = "Updated")
        val id = vmmDigest(baseline.id); val digest = desired.digest(VmmSource.PUBLIC)
        assertFalse(repo.recoverSettings(id, digest, VmmSource.PUBLIC))
        f.guests = listOf(VmmFixture.guest(name = "Updated")); assertTrue(repo.recoverSettings(id, digest, VmmSource.PUBLIC))
        f.guests = emptyList(); assertFalse(repo.recoverSettings(id, digest, VmmSource.PUBLIC))
        f.errors = mapOf(VmmSource.PUBLIC.guestApi to "list" to 102)
        assertTrue(runCatching { repo.recoverSettings(id, digest, VmmSource.PUBLIC) }.isFailure); assertTrue(f.writes.isEmpty())
    }
    @Test fun `设置缺失字段禁止补值越界被拒绝并保留启动三态`() {
        val raw = VmmFixture.guest(); val valid = parseVmmSettings(raw, VmmSource.PUBLIC)
        assertEquals(1, valid.configuration.startup)
        val missing = parseVmmSettings(JsonObject(raw - "description" - "vcpu_num" - "vram_size" - "autorun"), VmmSource.PUBLIC)
        assertFalse(missing.validChange(missing.configuration.copy(cpu = 2)))
        assertFalse(missing.validChange(missing.configuration.copy(startup = 0)))
        assertTrue(missing.validChange(missing.configuration.copy(name = "Updated")))
        for ((key, value) in listOf("vcpu_num" to JsonPrimitive(0), "vram_size" to JsonPrimitive("bad"), "autorun" to JsonPrimitive(3)))
            assertTrue(runCatching { parseVmmSettings(JsonObject(raw + (key to value)), VmmSource.PUBLIC) }.isFailure)
    }
    @Test fun `创建丢失回执不能把同名虚拟机归属本次结果`() = runBlocking {
        val scenario = VmmCreationFixture(); scenario.missingReceipt = true
        val repo = scenario.repository(); val store = VmmCreationStore(MemoryPreferences()); val model = VmmCreationModel(scope, { repo }, { store }, { true }, pollAttempts = 1)
        model.open(); idle { model.state.value.busy }; model.change(model.state.value.draft!!.copy(name = "Synthetic created"))
        model.create(); idle { model.state.value.busy }; assertEquals(VmmCreationStage.CREATE_SENT, model.state.value.records.single().progress.stage)
        model.clear(); model.refresh(); idle { model.state.value.busy }
        assertEquals(VmmCreationStage.CREATE_SENT, model.state.value.records.single().progress.stage)
        assertFalse(model.review(model.state.value.records.single().id)); assertEquals(1, scenario.fixture.writes.size)
    }
    @Test fun `创建与设置草稿保留编辑值并严格解析`() {
        val resources = VmmCreationResources(VmmSource.PUBLIC, listOf(VmmCreationStorage(VmmCreationRef("storage", "Storage"))), emptyList(),
            listOf(VmmCreationImage(VmmCreationRef("image", "Image"), "disk")), true, true)
        val draft = VmmCreationDraft(name = "Synthetic", description = " Draft ", storage = "storage")
        assertEquals(" Draft ", draft.plan(resources)!!.configuration.description)
        assertNull(draft.copy(name = " Synthetic ").plan(resources)); assertNull(draft.copy(cpu = "0").plan(resources))
        assertEquals("image", draft.copy(disks = listOf(VmmCreationDiskDraft("not-used", "image"))).plan(resources)!!.disks.single().image!!.id)
        assertNull(draft.copy(disks = List(9) { VmmCreationDiskDraft() }).plan(resources))
        val settings = VmmSettings("id", "shutdown", VmmSource.PUBLIC, VmmConfiguration("Synthetic", "", 2, 2048, null, 1))
        val edit = VmmSettingsDraft.from(settings.configuration).copy(name = "Updated", memory = "bad")
        assertEquals("bad", edit.memory); assertFalse(settings.validChange(edit.configuration()))
    }
    @Test fun `控制外层取消按已保存提交阶段保留未知结果`() = runBlocking {
        val f = VmmFixture(); val repo = f.repository(); val store = VmmControlStore(MemoryPreferences()); val model = VmmControlModel(scope, { repo }, { store }, { true })
        model.refresh(); idle { model.state.value.busy }; model.request(model.state.value.targets, VmmAction.START)
        f.after = { if (it.method == "poweron") throw CancellationException("Synthetic cancelled") }
        model.confirm(model.state.value.confirmation!!); idle { model.state.value.busy }
        assertEquals(VmmStage.SUBMITTED, store.records(repo.owner!!).single().items.single().stage)
        f.after = {}; model.refresh(); idle { model.state.value.busy }; assertTrue(model.hasPending()); assertEquals(1, f.writes.size)
    }
    @Test fun `普通概览请求在映像编辑期间被阻止`() {
        assertFalse(virtualMachineOrdinaryLoadBlocked(VirtualMachineMutationWorkspaceState()))
        assertTrue(virtualMachineOrdinaryLoadBlocked(VirtualMachineMutationWorkspaceState(imageImportEditorVisible = true)))
    }
    @Test fun `生命周期回读仅原身份和目标终态可完成`() = runBlocking {
        val f = VmmFixture(); val repo = f.repository().virtualMachineManagement; val original = repo.controlTargets().single()
        suspend fun recovered() = repo.recoverControl(vmmDigest(original.id), vmmIdentity(original), VmmAction.START, VmmSource.PUBLIC)
        assertFalse(recovered()); f.guests = listOf(VmmFixture.guest(status = "running")); assertTrue(recovered())
        f.guests = listOf(VmmFixture.guest(name = "Other", status = "running")); assertFalse(recovered())
        f.guests = listOf(VmmFixture.guest(id = "other", status = "running")); assertFalse(recovered())
        assertTrue(f.writes.isEmpty())
    }
    @Test fun `控制命令严格遵守状态及支持能力矩阵`() {
        for (status in listOf("shutdown", "running", "suspended", "migrating", "unknown")) for (action in VmmAction.entries) {
            val target = VmmControlTarget("id", "Synthetic", status, VmmAction.entries.toSet())
            val expected = status == if (action in setOf(VmmAction.START, VmmAction.DELETE)) "shutdown" else "running"
            assertEquals("$status/$action", expected, target.supports(action))
            assertFalse(target.copy(actions = emptySet()).supports(action))
        }
    }
    @Test fun `生命周期确认保留基线变化后拒绝写入`() = runBlocking {
        val f = VmmFixture(); val repo = f.repository().virtualMachineManagement; val target = repo.controlTargets().single()
        val confirmation = VmmControlConfirmation(listOf(target), VmmAction.START)
        assertEquals(confirmation, confirmation.copy(targets = confirmation.targets.map { it.copy() }))
        f.guests = listOf(VmmFixture.guest(status = "running"))
        val stages = mutableListOf<VmmStage>()
        assertTrue(runCatching { repo.performControl(target, VmmAction.START, VmmSource.PUBLIC, stages::add) }.isFailure)
        assertEquals(listOf(VmmStage.CANCELLED), stages); assertTrue(f.writes.isEmpty())
    }
    @Test
    fun `本地映像草稿不保存URI且严格校验格式大小存储与暂存目录`() {
        val twoTiB = 2_199_023_255_552L
        val local = VirtualMachineImageImportDraftState(
            imageName = " Local disk ",
            source = VirtualMachineImageImportSource.LOCAL,
            storage = eligibleStorage(),
            localFile = VirtualMachineLocalImageSelection("machine.vhdx", twoTiB),
            localStagingDirectory = stagingDirectory(),
        )

        val submission = local.toLocalSubmissionOrNull()
        assertEquals("Local disk", submission?.imageName)
        assertEquals(VirtualMachineImageType.DISK, submission?.image?.imageType)
        assertEquals(twoTiB, submission?.image?.originalSizeBytes)
        assertEquals(null, local.toImportOrNull())
        assertFalse(local.localFile.toString().contains("machine.vhdx"))
        assertFalse(submission.toString().contains("/share/staging"))
        assertEquals(
            setOf("displayName", "sizeBytes"),
            VirtualMachineLocalImageSelection::class.java.declaredFields
                .filterNot { it.isSynthetic || Modifier.isStatic(it.modifiers) }
                .map { it.name }
                .toSet(),
        )

        val ova = local.copy(localFile = VirtualMachineLocalImageSelection("machine.ova", 1L))
        assertEquals(
            VirtualMachineLocalImageValidation.Rejected(
                VirtualMachineLocalImageRejection.UNSUPPORTED_EXTENSION,
            ),
            ova.localValidation(),
        )
        assertEquals(null, ova.toLocalSubmissionOrNull())
        assertEquals(
            null,
            local.copy(
                localFile = VirtualMachineLocalImageSelection("machine.vhdx", twoTiB + 1L),
            ).toLocalSubmissionOrNull(),
        )
        assertEquals(null, local.copy(localStagingDirectory = null).toLocalSubmissionOrNull())
    }

    @Test
    fun `普通概览旧回调按仓库模块NAS和代次隔离`() {
        val token = VirtualMachineOverviewRequestToken("profile-a", 4)
        assertTrue(
            virtualMachineOverviewCallbackMatches(
                true,
                Module.VIRTUAL_MACHINES,
                "profile-a",
                token,
                4,
            ),
        )
        assertFalse(virtualMachineOverviewCallbackMatches(false, Module.VIRTUAL_MACHINES, "profile-a", token, 4))
        assertFalse(virtualMachineOverviewCallbackMatches(true, Module.FILES, "profile-a", token, 4))
        assertFalse(virtualMachineOverviewCallbackMatches(true, Module.VIRTUAL_MACHINES, "profile-b", token, 4))
        assertFalse(virtualMachineOverviewCallbackMatches(true, Module.VIRTUAL_MACHINES, "profile-a", token, 5))
    }

    private fun eligibleStorage() = ManagedResource(
        id = "storage-1",
        name = "Synthetic storage",
        detail = "online",
        state = ResourceState.RUNNING,
        metadata = mapOf("status" to "online"),
    )

    private fun stagingDirectory() = FileItem(
        path = "/share/staging",
        name = "staging",
        isDirectory = true,
        canRead = true,
        canWrite = true,
    )

}
