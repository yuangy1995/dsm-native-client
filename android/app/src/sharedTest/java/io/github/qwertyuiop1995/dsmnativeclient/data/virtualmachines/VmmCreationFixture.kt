package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import kotlinx.serialization.json.*

/** 创建合成后端复用正式 VMM HTTP 夹具；包含独立任务、全部硬件和模板设置。 */
internal class VmmCreationFixture(val fixture: VmmFixture = VmmFixture()) {
    var finished = true; var succeeded = true; var progress: JsonElement = JsonPrimitive(100)
    var taskStatus = "create"; var createdId = "created-guest"; var taskId = "created-task"; var missingReceipt = false
    var taskVisible = true; var duplicateTask = false; var mutateEcho: (JsonObject) -> JsonObject = { it }
    var taskGuestOverride: String? = null; var taskOverride: JsonObject? = null; var settingsOverride: JsonObject? = null
    var selectedStorageName = "Synthetic storage"; var storageHealthy = true; var storageFrozen: JsonElement = JsonPrimitive(false)
    var publicStoragesOverride: JsonObject? = null
    var submitted: JsonObject? = null; var internalSettings: JsonObject? = null
    init { fixture.responseOverride = ::reply }
    fun repository() = fixture.repository()
    suspend fun plan(repo: VmmManagementRepository, preset: VmmCreationPreset = VmmCreationPreset.GENERAL, power: Boolean = false): VmmCreationPlan {
        val source = if (preset == VmmCreationPreset.GENERAL) VmmSource.PUBLIC else VmmSource.INTERNAL
        val resources = repo.creationResources(source)
        return VmmCreationPlan(preset, VmmConfiguration("Synthetic created", "Synthetic description", 2, 512, if (source == VmmSource.INTERNAL) 256 else null, 1),
            resources.storages.single(), listOf(VmmCreationDisk(10)), listOf(null), powerOn = power)
    }
    private fun reply(call: VmmFixture.Call): JsonObject? = when {
        call.api == "SYNO.Virtualization.API.Storage" -> publicStoragesOverride ?: buildJsonObject {
            put("storages", buildJsonArray { add(buildJsonObject { put("storage_id", "storage-1"); put("storage_name", selectedStorageName); put("status", if (storageHealthy) "normal" else "offline") }) })
        }
        call.api == "SYNO.Virtualization.Repo" -> buildJsonObject {
            put("is_freeze", storageFrozen); put("repos", buildJsonArray { add(buildJsonObject {
                put("repo_id", "storage-1"); put("name", selectedStorageName); put("host_id", "host-1"); put("host_name", "Synthetic host")
                put("allocated_size", 123L); put("size", "1099511627776"); put("used", "123"); put("status", if (storageHealthy) "online" else "offline"); put("status_type", "healthy")
            }) })
        }
        call.api == "SYNO.Virtualization.API.Network" -> buildJsonObject { put("networks", buildJsonArray { add(buildJsonObject { put("network_id", "network-1"); put("network_name", "Synthetic network") }) }) }
        call.api.endsWith("Guest") && call.method == "create" -> {
            val fields = JsonObject(call.fields.mapValues { (key, value) ->
                if (fixture.format == "JSON") value else when (key) {
                    "guest_name", "storage_id", "name", "desc", "bios", "boot_from", "kb_layout", "video_card", "repo_id", "repo_name", "host_id", "repo_host_name", "size", "synovmm_ui_id" -> value
                    else -> Json.parseToJsonElement(value.jsonPrimitive.content)
                }
            })
            submitted = fields
            val internal = !call.api.contains(".API.")
            if (fixture.applyWrite) {
                val disks = fields["vdisks"]!!.jsonArray; val nics = fields["vnics"]!!.jsonArray
                val guest = buildJsonObject {
                    VmmFixture.guest(createdId, fields[if (internal) "name" else "guest_name"]!!.jsonPrimitive.content, "shutdown").forEach { (key, value) -> put(key, value) }
                    put("storage_id", "storage-1"); put("vcpu_num", if (internal) fields.getValue("vcpu_num") else JsonPrimitive(1))
                    put("vram_size", if (internal) fields.getValue("vram_size") else JsonPrimitive(256)); put("autorun", if (internal) fields.getValue("autorun") else JsonPrimitive(0))
                    put("description", if (internal) fields.getValue("desc") else JsonPrimitive("")); put("desc", if (internal) fields.getValue("desc") else JsonPrimitive(""))
                    put("vdisks", JsonArray(disks.mapIndexed { index, raw -> val disk = raw.jsonObject; buildJsonObject {
                        put("vdisk_id", "disk-$index"); put("vdisk_size", if (internal) disk.vmmInt("vdisk_size").toLong() * 1024 else disk["vdisk_size"]?.jsonPrimitive?.longOrNull ?: 4096L)
                    } }))
                    put("vnics", JsonArray(nics.mapIndexed { index, raw -> buildJsonObject {
                        put("vnic_id", "nic-$index"); put("network_id", raw.jsonObject.getValue("network_id")); put("mac", raw.jsonObject["mac"] ?: JsonPrimitive("02:00:00:00:00:%02X".format(index)))
                    } }))
                }
                fixture.guests = fixture.guests + guest
                if (internal) internalSettings = buildJsonObject {
                    fields.forEach { (key, value) -> put(key, value) }; put("vram_size", fields.vmmInt("vram_size").toLong() * 1024)
                    put("vdisks", JsonArray(disks.mapIndexed { index, raw -> buildJsonObject {
                        raw.jsonObject.forEach { (key, value) -> put(key, value) }; put("vdisk_id", "disk-$index"); put("size", (raw.jsonObject.vmmInt("vdisk_size").toLong() * 1024 * 1024 * 1024).toString())
                    } }))
                    put("vnics", JsonArray(nics.mapIndexed { index, raw -> JsonObject(raw.jsonObject + ("vnic_id" to JsonPrimitive("nic-$index"))) }))
                }
            }
            if (missingReceipt) buildJsonObject {} else buildJsonObject { put("task_id", taskId) }
        }
        call.api == "SYNO.Virtualization.API.Task.Info" -> taskOverride ?: buildJsonObject {
            put("finish", finished); put("task_info", buildJsonObject { put("status", taskStatus); put("progress", progress); if (finished) put("guest_id", taskGuestOverride ?: createdId) })
        }
        call.api == "SYNO.Virtualization.Cluster" -> buildJsonObject {
            put("has_fail", false)
            put("host-1", buildJsonObject { if (taskVisible && submitted != null) {
                val row = taskOverride ?: buildJsonObject {
                    put("finish", finished); put("success", succeeded); put("data", buildJsonObject { put("progress", progress); if (finished) put("guest_id", taskGuestOverride ?: createdId) })
                    put("info", buildJsonObject { put("api", VmmSource.INTERNAL.guestApi); put("method", "create"); put("prefix", "virtualization_guest_create"); put("version", 1); put("param", mutateEcho(submitted!!)) })
                }
                put(taskId, row); if (duplicateTask) put("other-task", row)
            } })
        }
        call.method == "get_setting" && call.fields["guest_id"]?.jsonPrimitive?.content == createdId -> settingsOverride ?: internalSettings
        else -> null
    }
}
