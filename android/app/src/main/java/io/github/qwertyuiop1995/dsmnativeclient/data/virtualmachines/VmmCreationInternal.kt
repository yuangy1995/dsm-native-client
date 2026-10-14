package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import java.security.SecureRandom
import kotlinx.serialization.json.*

/** 已记录的内部向导模板：单块空白盘、单网卡；创建后开机另行执行。 */
internal fun VmmCreationPlan.internalParameters(storage: VmmCreationStorage, id: String): JsonObject {
    val linux = preset == VmmCreationPreset.LINUX
    val bytes = ByteArray(6).also { SecureRandom().nextBytes(it) }; bytes[0] = ((bytes[0].toInt() or 2) and 254).toByte()
    val mac = bytes.joinToString(":") { "%02X".format(it.toInt() and 255) }
    return buildJsonObject {
        put("guest_privilege", JsonArray(emptyList())); put("iso_images", JsonArray(listOf(iso?.ref?.id ?: "unmounted", "unmounted").map(::JsonPrimitive)))
        put("autorun", configuration.startup); put("boot_from", "disk"); put("bios", if (uefi) "uefi" else "legacy")
        put("kb_layout", "Default"); put("usb_version", 0); put("usbs", JsonArray(List(4) { JsonPrimitive("unmounted") }))
        put("is_windows_vm", preset == VmmCreationPreset.WINDOWS); put("use_ovmf", uefi)
        put("vnics", buildJsonArray { add(buildJsonObject {
            put("prefer_sriov", false); put("vnic_type", if (linux) 1 else 2); put("type", "add"); put("mac", mac); put("network_id", networks.single()?.id.orEmpty())
        }) })
        put("is_general_vm", true); put("increaseAllocatedSize", disks.single().gib)
        put("vdisks", buildJsonArray { add(buildJsonObject {
            put("type", "add"); put("vdisk_mode", if (linux) 1 else 2); put("name", "disk-1"); put("unmap", false)
            put("iops_enable", false); put("dev_limit", 0); put("dev_reservation", 0); put("dev_weight", 3); put("vdisk_size", disks.single().gib); put("idx", 0)
        }) })
        put("auto_switch", if (preset == VmmCreationPreset.WINDOWS) 1 else 0); put("vdisk_struct", JsonArray(emptyList()))
        put("name", configuration.name); put("desc", configuration.description); put("vcpu_num", configuration.cpu); put("vram_size", configuration.memoryMiB)
        put("video_card", if (linux) "vmvga" else "vga"); put("cpu_weight", 256); put("cpu_passthru", true); put("hyperv_enlighten", true); put("cpu_pin_num", 0)
        put("repo_id", storage.ref.id); put("repo_name", storage.ref.name); put("host_id", storage.host); put("repo_host_name", storage.hostName)
        put("allocated_size", storage.allocated); put("size", storage.size); put("poweron_after_create", false); put("synovmm_ui_id", id)
    }
}
private val resultKeys = setOf("name", "desc", "vcpu_num", "vram_size", "cpu_weight", "autorun", "repo_id", "is_general_vm", "use_ovmf",
    "boot_from", "iso_images", "video_card", "cpu_passthru", "hyperv_enlighten", "cpu_pin_num", "kb_layout", "usb_version", "usbs")
private val nicKeys = setOf("network_id", "mac", "vnic_type", "prefer_sriov")
private fun JsonObject.project(keys: Set<String>) = JsonObject(keys.associateWith { get(it) ?: vmmInvalid() })
private fun normalizedNic(nic: JsonObject) = JsonObject(nic.project(nicKeys) + ("mac" to JsonPrimitive(nic.vmmString("mac").uppercase(java.util.Locale.ROOT))))
internal fun internalCreationExpected(parameters: JsonObject) = vmmJsonDigest(buildJsonObject {
    parameters.project(resultKeys).forEach { (key, value) -> put(key, value) }
    put("vdisks", JsonArray(vmmRows(parameters, "vdisks").map { disk -> buildJsonObject {
        put("size", (disk.vmmInt("vdisk_size").toLong() * 1024 * 1024 * 1024).toString()); put("vdisk_mode", disk.getValue("vdisk_mode")); put("unmap", false)
    } }))
    put("vnics", JsonArray(vmmRows(parameters, "vnics").map(::normalizedNic)))
})

internal data class VmmCreatedGuest(val settings: VmmSettings, val hardware: String)
internal suspend fun VmmManagementRepository.internalCreatedGuest(snapshot: VmmCreationSnapshot, id: String): VmmCreatedGuest {
    val fields = mapOf("guest_id" to JsonPrimitive(id))
    val before = call(VmmSource.INTERNAL.guestApi, "get", 2, fields)
    val settings = call(VmmSource.INTERNAL.guestApi, "get_setting", 1, fields)
    val after = call(VmmSource.INTERNAL.guestApi, "get", 2, fields)
    val basic = parseVmmSettings(before, VmmSource.INTERNAL)
    if (basic.id != id || parseVmmSettings(after, VmmSource.INTERNAL) != basic || basic.configuration != snapshot.plan.configuration) vmmConflict()
    for (key in listOf("name", "desc", "vcpu_num", "vram_size", "cpu_weight", "autorun")) if (before[key] != settings[key]) vmmConflict()
    val disks = vmmRows(settings, "vdisks"); val nics = vmmRows(settings, "vnics")
    fun identifiers(rows: List<JsonObject>, key: String): List<String> = rows.map { row -> row.vmmRequiredText(key).also { if (!validVmmId(it)) vmmInvalid() } }
        .also { if (it.distinct().size != it.size) vmmInvalid() }
    val diskIds = identifiers(disks, "vdisk_id"); val nicIds = identifiers(nics, "vnic_id")
    val observed = buildJsonObject {
        settings.project(resultKeys).forEach { (key, value) -> put(key, value) }
        put("vram_size", basic.configuration.memoryMiB)
        put("vdisks", JsonArray(disks.map { it.project(setOf("size", "vdisk_mode", "unmap")) }))
        put("vnics", JsonArray(nics.map(::normalizedNic)))
    }
    if (vmmJsonDigest(observed) != snapshot.expected) vmmConflict()
    return VmmCreatedGuest(basic, vmmJsonDigest(buildJsonObject {
        put("disks", JsonArray(diskIds.map(::JsonPrimitive))); put("nics", JsonArray(nicIds.map(::JsonPrimitive))); put("configuration", observed)
    }))
}

internal data class VmmCreationTask(val task: String, val guest: String?, val percent: Int?, val failed: Boolean = false)
/** task_id（或丢回执时 UUID）与完整参数共同关联，绝不按名称认领任务。 */
internal suspend fun VmmManagementRepository.internalCreationTask(snapshot: VmmCreationSnapshot, progress: VmmCreationProgress): VmmCreationTask? {
    val data = call("SYNO.Virtualization.Cluster", "get_total_progress", 1, mapOf("prefix" to JsonPrimitive("virtualization_guest")))
    val matches = mutableListOf<Pair<String, JsonObject>>()
    for ((host, group) in data) {
        if (host == "local_host") continue
        if (host == "has_fail") { data.vmmBool(host); continue }
        for ((id, element) in group as? JsonObject ?: vmmInvalid()) {
            val row = element as? JsonObject ?: vmmInvalid()
            val context = (row["info"] as? JsonObject)?.get("param") as? JsonObject
            if (id == progress.task || progress.task == null && context?.get("synovmm_ui_id").vmmText() == snapshot.id) matches += id to row
        }
    }
    if (matches.isEmpty()) return null
    val (id, task) = matches.singleOrNull() ?: vmmConflict()
    val info = task["info"] as? JsonObject ?: vmmInvalid(); val parameters = info["param"] as? JsonObject ?: vmmInvalid()
    if (!validVmmId(id) || info.vmmString("api") != VmmSource.INTERNAL.guestApi || info.vmmString("method") != "create" ||
        info.vmmString("prefix") != "virtualization_guest_create" || info.vmmInt("version") != 1 ||
        parameters["synovmm_ui_id"].vmmText() != snapshot.id || vmmJsonDigest(parameters) != snapshot.parameters) vmmConflict()
    val finished = task.vmmBool("finish"); val success = task.vmmBool("success")
    val result = task["data"] as? JsonObject
    val percent = result?.get("progress")?.let { result.vmmInt("progress").also { if (it > 100) vmmInvalid() } }
    val guest = if (finished && success) result?.vmmRequiredText("guest_id")?.takeIf(::validVmmId) ?: vmmInvalid() else null
    if (guest != null && (vmmDigest(guest) in snapshot.existingIds || progress.guest != null && guest != progress.guest)) vmmConflict()
    return VmmCreationTask(id, guest, percent, finished && !success)
}
