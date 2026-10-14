package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

private fun VmmCreationPlan.publicParameters() = buildJsonObject {
    put("guest_name", configuration.name); put("storage_id", storage.ref.id); put("auto_clean_task", false)
    put("vdisks", JsonArray(disks.map { disk -> buildJsonObject {
        put("create_type", if (disk.image == null) 0 else 1)
        if (disk.image == null) put("vdisk_size", disk.gib.toLong() * 1024) else put("image_id", disk.image.id)
    } }))
    put("vnics", JsonArray(networks.map { buildJsonObject { put("network_id", it?.id.orEmpty()) } }))
}

/** 持久化 PREPARED / SENT 必须成功后才发送一次请求；异常不发起任何补偿写入。 */
internal suspend fun VmmManagementRepository.createGuest(plan: VmmCreationPlan, requestId: String,
    prepared: (VmmCreationSnapshot) -> Unit, checkpoint: (VmmCreationProgress) -> Unit, pollAttempts: Int = 120) {
    if (!mutationLock.tryLock()) vmmConflict()
    try {
        if (!plan.valid() || plan.source !in creationSources() || plan.powerOn && !creationCanPowerOn(plan.source)) vmmConflict()
        requireWrite(plan.source)
        val targets = controlTargets(plan.source)
        if (targets.any { it.name.equals(plan.configuration.name, ignoreCase = true) }) vmmConflict()
        val storage = validateCreationResources(plan)
        val fields = if (plan.source == VmmSource.PUBLIC) plan.publicParameters() else plan.internalParameters(storage, requestId)
        val snapshot = VmmCreationSnapshot(requestId, plan, targets.map { vmmDigest(it.id) }.toSet(), vmmJsonDigest(fields),
            if (plan.source == VmmSource.INTERNAL) internalCreationExpected(fields) else null)
        prepared(snapshot)
        currentCoroutineContext().ensureActive()
        val sent = VmmCreationProgress(VmmCreationStage.CREATE_SENT)
        checkpoint(sent)
        val reply = try { call(plan.source.guestApi, "create", 1, fields, write = true) }
        catch (error: Exception) { if (vmmExplicitRejection(error)) checkpoint(sent.copy(stage = VmmCreationStage.REJECTED)); throw error }
        val task = reply["task_id"].vmmText()?.takeIf(::validVmmId) ?: vmmInvalid()
        val accepted = sent.copy(stage = VmmCreationStage.CREATING, task = task)
        checkpoint(accepted)
        driveCreation(snapshot, accepted, allowWrite = true, checkpoint, pollAttempts)
    } finally { mutationLock.unlock() }
}

internal suspend fun VmmManagementRepository.resumeCreation(snapshot: VmmCreationSnapshot, progress: VmmCreationProgress,
    allowWrite: Boolean = false, pollAttempts: Int = 120, checkpoint: (VmmCreationProgress) -> Unit) {
    if (!mutationLock.tryLock()) vmmConflict()
    try { driveCreation(snapshot, progress, allowWrite, checkpoint, pollAttempts) } finally { mutationLock.unlock() }
}

/** 延续原创建入口的有限等待；离开本次执行后，刷新不获得后续写授权。 */
private suspend fun VmmManagementRepository.driveCreation(snapshot: VmmCreationSnapshot, initial: VmmCreationProgress,
    allowWrite: Boolean, checkpoint: (VmmCreationProgress) -> Unit, pollAttempts: Int) {
    var current = initial
    val attempts = if (allowWrite) pollAttempts.coerceIn(1, 120) else 1
    repeat(attempts) { attempt ->
        advanceCreation(snapshot, current, allowWrite) { checkpoint(it); current = it }
        if (current.stage !in setOf(VmmCreationStage.CREATING, VmmCreationStage.CONFIGURING, VmmCreationStage.STARTING)) return
        if (attempt + 1 < attempts) delay(500)
    }
}

private suspend fun VmmManagementRepository.advanceCreation(snapshot: VmmCreationSnapshot, initial: VmmCreationProgress,
    allowWrite: Boolean, checkpoint: (VmmCreationProgress) -> Unit) {
    var progress = initial
    fun save(next: VmmCreationProgress) { if (next != progress) { checkpoint(next); progress = next } }
    val plan = snapshot.plan; val source = plan.source
    if (!progress.stage.pending || progress.stage == VmmCreationStage.PREPARED) return
    // 没有确认接受的设置/开机永不由状态相同推断完成，也不会续发。
    if (progress.stage in setOf(VmmCreationStage.CONFIGURE_SENT, VmmCreationStage.POWER_SENT)) return
    if (progress.stage in setOf(VmmCreationStage.CREATE_SENT, VmmCreationStage.CREATING)) {
        if (source == VmmSource.PUBLIC && progress.stage == VmmCreationStage.CREATE_SENT) return
        val task = if (progress.guest != null) VmmCreationTask(requireNotNull(progress.task), progress.guest, progress.percent)
            else if (source == VmmSource.PUBLIC) publicCreationTask(snapshot, progress) else internalCreationTask(snapshot, progress) ?: return
        if (progress.stage == VmmCreationStage.CREATE_SENT) save(progress.copy(stage = VmmCreationStage.CREATING, task = task.task))
        if (task.failed) { save(progress.copy(stage = VmmCreationStage.REJECTED, percent = task.percent)); return }
        if (task.guest == null) { save(progress.copy(percent = task.percent)); return }
        // 先保留任务已经返回的 guest_id；任务被 DSM 清理后仍按固定身份读取，不再认领其他对象。
        save(progress.copy(guest = task.guest, percent = task.percent))
    }
    val id = progress.guest ?: return
    val guest = if (source == VmmSource.PUBLIC) publicCreatedGuest(snapshot, id) else internalCreatedGuest(snapshot, id)
    if (progress.hardware != null && progress.hardware != guest.hardware) vmmConflict()
    if (progress.stage == VmmCreationStage.CREATING) {
        if (guest.settings.status != "shutdown") vmmConflict()
        save(progress.copy(stage = VmmCreationStage.CREATED, hardware = guest.hardware, baseline = guest.settings.configuration))
    }
    if (progress.stage == VmmCreationStage.CREATED) {
        if (guest.settings.status != "shutdown" || guest.settings.configuration != progress.baseline) vmmConflict()
        if (guest.settings.configuration == plan.configuration) save(progress.copy(stage = VmmCreationStage.CONFIGURED))
        else {
            if (source != VmmSource.PUBLIC || !guest.settings.validChange(plan.configuration)) vmmConflict()
            if (!allowWrite) return
            requireWrite(source)
            val fresh = publicCreatedGuest(snapshot, id)
            if (fresh != guest) vmmConflict()
            val fields = buildJsonObject {
                put("guest_id", id)
                val old = guest.settings.configuration; val desired = plan.configuration
                if (old.description != desired.description) put("description", desired.description)
                if (old.cpu != desired.cpu) put("vcpu_num", desired.cpu)
                if (old.memoryMiB != desired.memoryMiB) put("vram_size", desired.memoryMiB)
                if (old.startup != desired.startup) put("autorun", desired.startup)
            }
            currentCoroutineContext().ensureActive(); save(progress.copy(stage = VmmCreationStage.CONFIGURE_SENT))
            try { call(source.guestApi, "set", 1, fields, write = true) }
            catch (error: Exception) { if (vmmExplicitRejection(error)) save(progress.copy(stage = VmmCreationStage.PARTIAL)); throw error }
            save(progress.copy(stage = VmmCreationStage.CONFIGURING))
        }
    }
    if (progress.stage == VmmCreationStage.CONFIGURING) {
        val current = publicCreatedGuest(snapshot, id)
        if (current.hardware != progress.hardware || current.settings.configuration != plan.configuration || current.settings.status != "shutdown") return
        save(progress.copy(stage = VmmCreationStage.CONFIGURED))
    }
    if (progress.stage == VmmCreationStage.CONFIGURED) {
        val configured = if (source == VmmSource.PUBLIC) publicCreatedGuest(snapshot, id) else internalCreatedGuest(snapshot, id)
        if (configured.hardware != progress.hardware || configured.settings.configuration != plan.configuration || configured.settings.status != "shutdown") vmmConflict()
        if (!plan.powerOn) { save(progress.copy(stage = VmmCreationStage.COMPLETE)); return }
        if (!allowWrite) return
        requireWrite(source)
        val current = if (source == VmmSource.PUBLIC) publicCreatedGuest(snapshot, id) else internalCreatedGuest(snapshot, id)
        if (current.hardware != progress.hardware || current.settings.configuration != plan.configuration || current.settings.status != "shutdown") vmmConflict()
        val fields = buildJsonObject { put("guest_id", id); if (source == VmmSource.INTERNAL) put("action", "poweron") }
        currentCoroutineContext().ensureActive(); save(progress.copy(stage = VmmCreationStage.POWER_SENT))
        try { call("${source.guestApi}.Action", if (source == VmmSource.PUBLIC) "poweron" else "pwr_ctl", 1, fields, write = true) }
        catch (error: Exception) { if (vmmExplicitRejection(error)) save(progress.copy(stage = VmmCreationStage.PARTIAL)); throw error }
        save(progress.copy(stage = VmmCreationStage.STARTING))
    }
    if (progress.stage == VmmCreationStage.STARTING) {
        val current = if (source == VmmSource.PUBLIC) publicCreatedGuest(snapshot, id) else internalCreatedGuest(snapshot, id)
        if (current.hardware == progress.hardware && current.settings.configuration == plan.configuration && current.settings.status == "running")
            save(progress.copy(stage = VmmCreationStage.COMPLETE))
    }
}

private suspend fun VmmManagementRepository.publicCreationTask(snapshot: VmmCreationSnapshot, progress: VmmCreationProgress): VmmCreationTask {
    // 固定任务完成身份已落盘后，任务清理不会阻断后续只读核对。
    if (progress.guest != null) return VmmCreationTask(requireNotNull(progress.task), progress.guest, progress.percent)
    val id = progress.task ?: vmmInvalid()
    val task = call("SYNO.Virtualization.API.Task.Info", "get", 1, mapOf("task_id" to JsonPrimitive(id)))
    val finished = task.vmmBool("finish"); val info = task["task_info"] as? JsonObject ?: vmmInvalid()
    val percent = info["progress"]?.let { info.vmmInt("progress").also { if (it > 100) vmmInvalid() } }
    if (!finished) return VmmCreationTask(id, null, percent)
    if (info.vmmRequiredText("status") != "create" || percent != 100) vmmConflict()
    val guest = info.vmmRequiredText("guest_id").takeIf(::validVmmId) ?: vmmInvalid()
    if (vmmDigest(guest) in snapshot.existingIds) vmmConflict()
    return VmmCreationTask(id, guest, percent)
}

private suspend fun VmmManagementRepository.publicCreatedGuest(snapshot: VmmCreationSnapshot, id: String): VmmCreatedGuest {
    val plan = snapshot.plan; val row = call(VmmSource.PUBLIC.guestApi, "get", 1, mapOf("guest_id" to JsonPrimitive(id)))
    val settings = parseVmmSettings(row, VmmSource.PUBLIC)
    if (settings.id != id || settings.configuration.name != plan.configuration.name || row.vmmRequiredText("storage_id") != plan.storage.ref.id) vmmConflict()
    val disks = vmmRows(row, "vdisks"); val nics = vmmRows(row, "vnics")
    if (disks.size != plan.disks.size || nics.size != plan.networks.size) vmmConflict()
    val diskIds = mutableSetOf<String>(); val nicIds = mutableSetOf<String>()
    val hardware = buildJsonObject {
        put("vdisks", JsonArray(disks.mapIndexed { index, disk ->
            val diskId = disk.vmmRequiredText("vdisk_id")
            val raw = disk["vdisk_size"] as? JsonPrimitive ?: vmmInvalid()
            val size = raw.longOrNull?.takeIf { !raw.isString && it > 0 } ?: vmmInvalid()
            if (!validVmmId(diskId) || !diskIds.add(diskId) || plan.disks[index].image == null && size != plan.disks[index].gib.toLong() * 1024) vmmConflict()
            JsonObject(disk.filterKeys { it in setOf("vdisk_id", "vdisk_size", "controller", "unmap") })
        }))
        put("vnics", JsonArray(nics.mapIndexed { index, nic ->
            val nicId = nic.vmmRequiredText("vnic_id"); val mac = nic.vmmString("mac").uppercase(java.util.Locale.ROOT)
            if (!validVmmId(nicId) || !nicIds.add(nicId) || nic.vmmString("network_id") != plan.networks[index]?.id.orEmpty() ||
                !Regex("[0-9A-F]{2}(:[0-9A-F]{2}){5}").matches(mac)) vmmConflict()
            JsonObject(nic.filterKeys { it in setOf("vnic_id", "network_id", "model") } + ("mac" to JsonPrimitive(mac)))
        }))
    }
    return VmmCreatedGuest(settings, vmmJsonDigest(hardware))
}
