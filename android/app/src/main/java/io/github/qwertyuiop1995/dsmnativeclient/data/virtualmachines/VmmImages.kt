package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*

@Serializable internal data class VmmImageCopy(val storage: String, val host: String, val status: String, val statusType: String)
@Serializable internal data class VmmImage(val id: String, val name: String?, val type: String?, val source: VmmSource,
    val copies: List<VmmImageCopy> = emptyList(), val inUse: Boolean? = null) {
    val canDelete get() = name != null && if (source == VmmSource.PUBLIC) inUse != true else copies.isNotEmpty() &&
        copies.all { it.status == "online" && it.statusType == "healthy" } && (type != "iso" || inUse == false)
    val identity get() = vmmDigest(Json.encodeToString(this))
}
internal data class VmmImageInventory(val source: VmmSource, val frozen: Boolean, val images: List<VmmImage>)
internal fun VmmManagementRepository.imageSource(): VmmSource = if (supports("SYNO.Virtualization.API.Guest.Image", 1)) VmmSource.PUBLIC else VmmSource.INTERNAL

/** 同一映像的全部存储/主机副本合并；内部 ISO 占用包含关机的虚拟机。 */
internal suspend fun VmmManagementRepository.imageInventory(source: VmmSource = imageSource()): VmmImageInventory {
    val data = call("${source.guestApi}.Image", "list", source.readVersion)
    val frozen = if (source == VmmSource.INTERNAL) data.vmmBool("is_freeze") else false
    val images = linkedMapOf<String, VmmImage>()
    for (row in vmmRows(data, "images")) {
        val id = row.vmmRequiredText(if (source == VmmSource.PUBLIC) "image_id" else "id").also { if (!validVmmId(it)) vmmInvalid() }
        if (source == VmmSource.PUBLIC) {
            if (id in images) vmmInvalid()
            images[id] = VmmImage(id, row["image_name"]?.let { it.vmmText() ?: vmmInvalid() }, row["type"]?.let { it.vmmText() ?: vmmInvalid() }, source)
        } else {
            val name = row.vmmRequiredText("name"); val type = row.vmmRequiredText("type")
            val copy = VmmImageCopy(row.vmmRequiredText("repo_id"), row.vmmRequiredText("host_id"), row.vmmRequiredText("status"), row.vmmRequiredText("status_type"))
            val prior = images[id]
            if (prior != null && (prior.name != name || prior.type != type || prior.copies.any { it.storage == copy.storage && it.host == copy.host })) vmmInvalid()
            images[id] = VmmImage(id, name, type, source, (prior?.copies.orEmpty() + copy).sortedWith(compareBy({ it.storage }, { it.host })))
        }
    }
    if (source == VmmSource.INTERNAL && !frozen && images.values.any { it.type == "iso" }) {
        val guests = vmmRows(call(VmmSource.INTERNAL.guestApi, "list", 2), "guests").map { it.vmmRequiredText("guest_id").also { id -> if (!validVmmId(id)) vmmInvalid() } }
        if (guests.distinct().size != guests.size) vmmInvalid()
        val used = mutableSetOf<String>()
        for (id in guests) {
            val settings = call(VmmSource.INTERNAL.guestApi, "get_setting", 1, mapOf("guest_id" to JsonPrimitive(id)))
            val slots = settings["iso_images"] as? JsonArray ?: vmmInvalid()
            for (slot in slots) { val image = slot.vmmText()?.takeIf(::validVmmId) ?: vmmInvalid(); if (image != "unmounted") used += image }
        }
        images.replaceAll { id, image -> if (image.type == "iso") image.copy(inUse = id in used) else image }
    }
    return VmmImageInventory(source, frozen, images.values.toList())
}
internal suspend fun VmmManagementRepository.deleteImage(expected: VmmImage, checkpoint: (VmmStage) -> Unit) {
    if (!mutationLock.tryLock()) vmmConflict()
    var submitted = false
    try {
        if (expected.source != imageSource() || !expected.canDelete) vmmConflict()
        requireWrite(expected.source)
        val inventory = imageInventory(expected.source)
        if (inventory.frozen || inventory.images.singleOrNull { it.id == expected.id } != expected) vmmConflict()
        val fields = mutableMapOf<String, JsonElement>(if (expected.source == VmmSource.PUBLIC) "image_id" to JsonPrimitive(expected.id) else "id" to JsonPrimitive(expected.id))
        if (expected.source == VmmSource.INTERNAL) fields["synovmm_ui_id"] = JsonPrimitive(UUID.randomUUID().toString())
        currentCoroutineContext().ensureActive(); checkpoint(VmmStage.SUBMITTED); submitted = true
        try { call("${expected.source.guestApi}.Image", "delete", expected.source.readVersion, fields, write = true) }
        catch (error: Exception) { if (vmmExplicitRejection(error)) checkpoint(VmmStage.REJECTED); throw error }
        checkpoint(VmmStage.ACCEPTED)
        if (recoverImage(vmmDigest(expected.id), expected.source)) checkpoint(VmmStage.VERIFIED)
    } catch (error: Exception) { if (!submitted) checkpoint(VmmStage.CANCELLED); throw error }
    finally { mutationLock.unlock() }
}
internal suspend fun VmmManagementRepository.recoverImage(id: String, source: VmmSource): Boolean {
    val inventory = imageInventory(source)
    return !inventory.frozen && inventory.images.none { vmmDigest(it.id) == id }
}
