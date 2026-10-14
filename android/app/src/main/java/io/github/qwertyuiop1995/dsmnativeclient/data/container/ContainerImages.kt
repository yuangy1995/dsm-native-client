package io.github.qwertyuiop1995.dsmnativeclient.data.container

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

internal data class ContainerImageEntry(val sourceId: String, val repository: String, val tag: String?, val sizeBytes: Long?, val inUse: Boolean? = null) {
    val id get() = containerDigest(JsonArray(listOf(JsonPrimitive(sourceId), JsonPrimitive(repository), tag?.let(::JsonPrimitive) ?: JsonNull)).toString())
    val reference get() = tag?.let { imageReference(repository, it) }
    val canDelete get() = tag != null && inUse == false
}
internal fun imageReference(repository: String, tag: String): String = repository.removePrefix("docker.io/").removePrefix("index.docker.io/") + ":" + tag
internal fun validImageTarget(repository: String, tag: String) = repository.isNotEmpty() && repository.length <= 500 &&
    "://" !in repository && '@' !in repository && repository.none { it.isWhitespace() || it.isISOControl() } &&
    tag.isNotEmpty() && tag != "<none>" && tag.none { it.isWhitespace() || it.isISOControl() || it in "/:@" }
private fun stableImageText(value: JsonElement?): String? = value.containerString()?.takeIf { it == it.trim() && it.none(Char::isISOControl) }

@Serializable internal data class ContainerImageIdentity(val selection: String, val image: String, val reference: String, val untagged: Boolean) {
    fun remains(entry: ContainerImageEntry): Boolean = if (untagged) image == containerDigest(entry.sourceId)
        else entry.reference?.let(::containerDigest) == reference
    fun overlaps(other: ContainerImageIdentity) = reference == other.reference || (untagged || other.untagged) && image == other.image
}
internal fun ContainerImageEntry.identity(): ContainerImageIdentity = ContainerImageIdentity(id, containerDigest(sourceId), containerDigest(reference ?: containerConflict()), tag == "<none>")

@Serializable internal data class ContainerImageTaskId(val value: String, val numeric: Boolean) {
    val valid get() = if (numeric) value.toLongOrNull()?.let { it in 0..9_007_199_254_740_991L && it.toString() == value } == true
        else value.isNotBlank() && value == value.trim() && value.none(Char::isISOControl)
    fun parameter(): JsonPrimitive { if (!valid) containerInvalid(); return if (numeric) JsonPrimitive(value.toLong()) else JsonPrimitive(value) }
}
internal data class ContainerImagePullPlan(val repository: String, val tag: String, val baselineIds: Set<String>) {
    val reference get() = containerDigest(imageReference(repository, tag))
}
internal data class ContainerImagePullReading(val finished: Boolean, val percentage: Float?, val repository: String?, val tag: String?, val failed: Boolean = false)

internal suspend fun ContainerRepository.imageDefinitions(): List<ContainerImageEntry> {
    val data = managementCall("SYNO.Docker.Image", "list", mapOf("offset" to JsonPrimitive(0), "limit" to JsonPrimitive(-1), "show_dsm" to JsonPrimitive(false)))
    val rows = containerRows(data, "images")
    val images = rows.flatMap { row ->
        val id = stableImageText(row["id"]) ?: containerInvalid()
        val repository = stableImageText(row["repository"]) ?: containerInvalid()
        val tags = if (row["tags"] != null) (row["tags"] as? JsonArray)?.map { stableImageText(it) ?: containerInvalid() } ?: containerInvalid() else emptyList()
        val tag = row["tag"]?.let { stableImageText(it) ?: containerInvalid() }
        val size = row["size"]?.let { (it as? JsonPrimitive)?.takeIf { value -> !value.isString }?.longOrNull?.takeIf { value -> value >= 0 } ?: containerInvalid() }
        (tags.takeIf { it.isNotEmpty() } ?: listOf(tag)).map { ContainerImageEntry(id, repository, it, size) }
    }
    val references = images.mapNotNull { if (it.tag != "<none>") it.reference else null }
    if (images.map { it.id }.distinct().size != images.size || references.distinct().size != references.size) containerInvalid()
    return images
}

/** 全量占用包含停止的容器；只依已记录 image/Image/ImageID 字段，不按容器状态猜测。 */
internal suspend fun ContainerRepository.imageDeletionTargets(): List<ContainerImageEntry> {
    return imageUsage(imageDefinitions())
}
internal suspend fun ContainerRepository.imageUsage(images: List<ContainerImageEntry>): List<ContainerImageEntry> {
    val containers = containerRows(managementCall("SYNO.Docker.Container", "list", mapOf("offset" to JsonPrimitive(0), "limit" to JsonPrimitive(-1), "type" to JsonPrimitive("all"))), "containers")
    val used = mutableSetOf<String>()
    for (row in containers) {
        val raw = row["Image"]?.let { stableImageText(it) ?: containerInvalid() }.orEmpty()
        if (raw.startsWith("sha256:") || "@sha256:" in raw) {
            val source = stableImageText(row["ImageID"]) ?: containerInvalid()
            val matches = images.filter { it.sourceId == source }
            if (matches.isEmpty()) containerInvalid()
            used += matches.map { it.id }
        } else {
            val name = stableImageText(row["image"]) ?: containerInvalid()
            val normalized = if (':' in name.substringAfterLast('/')) name else "$name:latest"
            val matches = images.filter { it.reference == normalized.removePrefix("docker.io/").removePrefix("index.docker.io/") }
            used += matches.map { it.id }
            used += images.filter { it.tag == "<none>" && matches.any { match -> match.sourceId == it.sourceId } }.map { it.id }
        }
    }
    return images.map { it.copy(inUse = it.id in used) }
}

internal suspend fun ContainerRepository.deleteImages(targets: List<ContainerImageEntry>, checkpoint: (ContainerStage) -> Unit): Set<String> {
    if (!managementLock.tryLock()) containerConflict()
    var submitted = false
    try {
        if (targets.isEmpty() || targets.map { it.id }.distinct().size != targets.size || targets.any { !it.canDelete }) containerConflict()
        val images = imageDeletionTargets()
        if (targets.any { original -> images.singleOrNull { it.id == original.id }?.let { it.identity() == original.identity() && it.canDelete } != true }) containerConflict()
        if (targets.any { target -> target.tag == "<none>" && images.any { it.sourceId == target.sourceId && it.tag != "<none>" } }) containerConflict()
        requireManagementWrite(); currentCoroutineContext().ensureActive()
        val groups = targets.filter { it.tag != "<none>" }.groupBy { it.repository }
        val objects = groups.toSortedMap().map { (repository, rows) -> buildJsonObject {
            put("repository", repository); put("tags", JsonArray(rows.map { JsonPrimitive(it.tag!!) }))
        } } + targets.filter { it.tag == "<none>" }.map { it.sourceId }.distinct().sorted().map { buildJsonObject { put("identity", it) } }
        checkpoint(ContainerStage.SUBMITTED); submitted = true
        try { managementCall("SYNO.Docker.Image", "delete", mapOf("images" to JsonArray(objects)), write = true) }
        catch (error: Exception) { if (containerExplicitRejection(error)) checkpoint(ContainerStage.REJECTED); throw error }
        checkpoint(ContainerStage.ACCEPTED)
        return removedImages(targets.map { it.identity() })
    } catch (error: Exception) {
        if (!submitted) checkpoint(ContainerStage.CANCELLED)
        throw error
    } finally { managementLock.unlock() }
}
internal suspend fun ContainerRepository.removedImages(targets: List<ContainerImageIdentity>): Set<String> {
    val images = imageDefinitions()
    return targets.filter { target -> images.none(target::remains) }.map { it.selection }.toSet()
}

internal suspend fun ContainerRepository.prepareImagePull(repository: String, tag: String): ContainerImagePullPlan {
    if (!validImageTarget(repository, tag) || tag !in registryTags(repository)) containerConflict()
    val reference = imageReference(repository, tag)
    return ContainerImagePullPlan(repository, tag, imageDefinitions().filter { it.reference == reference }.map { containerDigest(it.sourceId) }.toSet())
}
internal suspend fun ContainerRepository.startImagePull(plan: ContainerImagePullPlan, checkpoint: (ContainerStage, ContainerImageTaskId?) -> Unit): ContainerImageTaskId? {
    if (!managementLock.tryLock()) containerConflict()
    var submitted = false
    try {
        if (prepareImagePull(plan.repository, plan.tag) != plan) containerConflict()
        requireManagementWrite(); currentCoroutineContext().ensureActive()
        checkpoint(ContainerStage.SUBMITTED, null); submitted = true
        val response = try { managementCall("SYNO.Docker.Image", "pull_start", mapOf("repository" to JsonPrimitive(plan.repository), "tag" to JsonPrimitive(plan.tag)), write = true) }
        catch (error: Exception) { if (containerExplicitRejection(error)) checkpoint(ContainerStage.REJECTED, null); throw error }
        val raw = response["task_id"] as? JsonPrimitive
        val task = raw?.let { ContainerImageTaskId(it.content, !it.isString) }?.takeIf { it.valid }
        checkpoint(ContainerStage.ACCEPTED, task)
        return task
    } catch (error: Exception) {
        if (!submitted) checkpoint(ContainerStage.CANCELLED, null)
        throw error
    } finally { managementLock.unlock() }
}
internal suspend fun ContainerRepository.readImagePull(reference: String, task: ContainerImageTaskId): ContainerImagePullReading {
    val response = try { managementCall("SYNO.Docker.Image", "pull_status", mapOf("task_id" to task.parameter())) }
    catch (error: DsmFailure) {
        if (error.code == 1202 && error.isExplicitApiRejection) return ContainerImagePullReading(false, null, null, null, failed = true)
        throw error
    }
    val repository = stableImageText(response["repository"]) ?: containerInvalid()
    val tag = stableImageText(response["tag"]) ?: containerInvalid()
    if (!validImageTarget(repository, tag) || containerDigest(imageReference(repository, tag)) != reference) containerInvalid()
    val finished = response["finished"].containerBool() ?: containerInvalid()
    fun number(key: String) = (response[key] as? JsonPrimitive)?.takeIf { !it.isString }?.doubleOrNull?.takeIf { it.isFinite() }
    val current = number("current"); val total = number("total")
    val progress = if (current != null && total != null && total > 0 && current in 0.0..total) (current / total).toFloat() else null
    if (finished && imageDefinitions().none { it.reference?.let(::containerDigest) == reference }) containerInvalid()
    return ContainerImagePullReading(finished, if (finished) 1f else progress, repository, tag)
}
