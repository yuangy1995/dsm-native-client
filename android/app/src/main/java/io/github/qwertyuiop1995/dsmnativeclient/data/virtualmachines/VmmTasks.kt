package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.matchesMutationBaseline
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.Locale
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable internal data class VmmImportSnapshot(val name: String, val nameKey: String, val type: String, val existingImages: Set<String>)
@Serializable internal data class VmmImportProgress(val stage: VmmStage = VmmStage.PREPARED, val task: String? = null, val image: String? = null) {
    override fun toString() = "VmmImportProgress($stage)"
}
internal data class VmmTaskTarget(val token: String, val identity: String, val finished: Boolean, val progress: Int?) {
    val id get() = vmmDigest(token)
    override fun toString() = "VmmTaskTarget(finished=$finished)"
}
private const val TASK_API = "SYNO.Virtualization.API.Task.Info"
private const val IMAGE_API = "SYNO.Virtualization.API.Guest.Image"
internal suspend fun VmmManagementRepository.taskIds(): List<String> {
    val data = call(TASK_API, "list", 1)
    val ids = (data["task_ids"] as? JsonArray)?.map { it.vmmText()?.takeIf(::validVmmId) ?: vmmInvalid() } ?: vmmInvalid()
    if (ids.size > 100 || ids.distinct().size != ids.size) vmmInvalid()
    return ids
}
private suspend fun VmmManagementRepository.taskData(token: String): JsonObject {
    if (!validVmmId(token)) vmmInvalid()
    return call(TASK_API, "get", 1, mapOf("task_id" to JsonPrimitive(token)))
}
private fun taskTarget(token: String, data: JsonObject): VmmTaskTarget {
    val finished = data.vmmBool("finish")
    val info = data["task_info"]?.let { it as? JsonObject ?: vmmInvalid() }
    val progress = info?.get("progress")?.let { value ->
        (value as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull?.takeIf { it in 0..100 } ?: vmmInvalid()
    }
    return VmmTaskTarget(token, vmmJsonDigest(data), finished, progress)
}
internal suspend fun VmmManagementRepository.taskTargets(): List<VmmTaskTarget> = taskIds().map { taskTarget(it, taskData(it)) }

/** 清理只发送用户所见、仍已结束的原记录；接受回执与消失回读分别记录。 */
internal suspend fun VmmManagementRepository.clearTask(expected: VmmTaskTarget, checkpoint: (VmmStage) -> Unit) {
    if (!mutationLock.tryLock()) vmmConflict()
    var submitted = false
    try {
        requireWrite(VmmSource.PUBLIC)
        if (!expected.finished || expected.token !in taskIds() || taskTarget(expected.token, taskData(expected.token)) != expected) vmmConflict()
        currentCoroutineContext().ensureActive(); checkpoint(VmmStage.SUBMITTED); submitted = true
        try { call(TASK_API, "clear", 1, mapOf("task_id" to JsonPrimitive(expected.token)), write = true) }
        catch (error: Exception) { if (vmmExplicitRejection(error)) checkpoint(VmmStage.REJECTED); throw error }
        checkpoint(VmmStage.ACCEPTED)
        if (taskIds().none { vmmDigest(it) == expected.id }) checkpoint(VmmStage.VERIFIED)
    } catch (error: Exception) { if (!submitted) checkpoint(VmmStage.CANCELLED); throw error }
    finally { mutationLock.unlock() }
}

/** 文件路径只留在此次内存输入；提交前检查当前文件、原存储与完整映像目录。 */
internal suspend fun DsmRepository.importNasVmmImage(target: VirtualMachineImageImport,
    prepared: (VmmImportSnapshot) -> Unit, checkpoint: (VmmImportProgress) -> Unit) {
    requireCurrentOwner()
    if (!supportsOfficialVirtualMachineImageImport()) vmmUnsupported()
    val manager = virtualMachineManagement
    if (!manager.mutationLock.tryLock()) vmmConflict()
    var progress = VmmImportProgress(); var saved = false
    try {
        val name = target.imageName
        val source = target.sourceFile
        if (name.isBlank() || name != name.trim() || name.any(Char::isISOControl) || source.isDirectory || !source.canRead ||
            !source.path.startsWith('/') || source.path.any(Char::isISOControl) || !target.storage.isEligibleForVirtualMachineImageImport()) vmmConflict()
        manager.requireWrite(VmmSource.PUBLIC)
        if (fileInfo(source.path)?.matchesMutationBaseline(source) != true) vmmConflict()
        val storages = vmmRows(manager.call("SYNO.Virtualization.API.Storage", "list", 1), "storages")
        val ids = storages.map { it.vmmRequiredText("storage_id").also { id -> if (!validVmmId(id)) vmmInvalid() } }
        if (ids.distinct().size != ids.size) vmmInvalid()
        val storage = storages.singleOrNull { it.vmmRequiredText("storage_id") == target.storage.id } ?: vmmConflict()
        if (storage.vmmRequiredText("storage_name") != target.storage.name || storage.vmmRequiredText("status") != target.storage.metadata["status"]) vmmConflict()
        val images = manager.imageInventory(VmmSource.PUBLIC).images
        if (images.any { it.name == null || it.type == null }) vmmInvalid()
        if (images.any { it.name.equals(name, ignoreCase = true) }) vmmConflict()
        val snapshot = VmmImportSnapshot(vmmDigest(name), vmmDigest(name.lowercase(Locale.ROOT)), target.imageType.apiValue, images.map { vmmDigest(it.id) }.toSet())
        currentCoroutineContext().ensureActive(); requireCurrentOwner(); prepared(snapshot); saved = true
        progress = VmmImportProgress(VmmStage.SUBMITTED); checkpoint(progress)
        val response = try { manager.call(IMAGE_API, "create", 1, mapOf(
            "auto_clean_task" to JsonPrimitive(false), "storage_ids" to JsonArray(listOf(JsonPrimitive(target.storage.id))),
            "type" to JsonPrimitive(target.imageType.apiValue), "ds_file_path" to JsonPrimitive(source.path), "image_name" to JsonPrimitive(name)), write = true) }
        catch (error: Exception) { if (vmmExplicitRejection(error)) checkpoint(progress.copy(stage = VmmStage.REJECTED)); throw error }
        val task = response["task_id"].vmmText()?.takeIf(::validVmmId) ?: vmmInvalid()
        checkpoint(VmmImportProgress(VmmStage.ACCEPTED, task))
    } catch (error: Exception) {
        if (saved && progress.stage == VmmStage.PREPARED) checkpoint(progress.copy(stage = VmmStage.CANCELLED))
        throw error
    } finally { manager.mutationLock.unlock() }
}

/** 只有原 task_id 指向创建前不存在的 image_id 才可能完成；本函数不清除任务或源文件。 */
internal suspend fun VmmManagementRepository.recoverImport(snapshot: VmmImportSnapshot, progress: VmmImportProgress): VmmImportProgress {
    if (progress.stage != VmmStage.ACCEPTED || progress.task == null) vmmConflict()
    val data = taskData(progress.task)
    val task = taskTarget(progress.task, data)
    if (!task.finished) return progress
    val info = data["task_info"] as? JsonObject ?: return progress
    val image = info["image_id"]?.let { it.vmmText()?.takeIf(::validVmmId) ?: vmmInvalid() } ?: return progress
    val digest = vmmDigest(image)
    if (digest in snapshot.existingImages || progress.image != null && progress.image != digest) vmmConflict()
    val current = imageInventory(VmmSource.PUBLIC).images.singleOrNull { it.id == image } ?: return progress.copy(image = digest)
    if (current.name?.let(::vmmDigest) != snapshot.name || current.type != snapshot.type) vmmConflict()
    return progress.copy(stage = VmmStage.VERIFIED, image = digest)
}
