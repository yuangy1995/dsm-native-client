package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

/** 合成后端复用正式请求编码与工作区授权；不替换仓储、任务模型或持久化阶段。 */
internal class VmmTaskFixture(val fixture: VmmFixture = VmmFixture()) {
    val file = FileItem("/synthetic/source.img", "source.img", false, 1_024, 123, canRead = true)
    val storage = ManagedResource("storage-1", "Synthetic storage", "", ResourceState.RUNNING, mapOf("status" to "online"))
    var fileSize = file.size; var storageName = storage.name; var storageStatus = "online"; var storageTotal: Int? = null
    var finished = true; var missingReceipt = false; var taskId = "import-task"; var imageId = "new-image"
    var returnedImageId: String? = null; var imageVisible = true; var createImageName: String? = null; var createImageType: String? = null
    var taskListOverride: JsonObject? = null
    var tasks = linkedMapOf<String, JsonObject>()
    fun target(name: String = "Imported image") = VirtualMachineImageImport(name, VirtualMachineImageType.DISK, file, storage)
    init { fixture.extraCapabilities = listOf("SYNO.FileStation.List"); fixture.responseOverride = ::response }
    fun repository(generation: String = "generation", identity: String = "identity") = fixture.repository(generation, identity)
    private fun response(call: VmmFixture.Call): JsonObject? = when {
        call.api == "SYNO.FileStation.List" && call.method == "list_share" -> buildJsonObject {
            put("shares", buildJsonArray { add(buildJsonObject { put("path", "/synthetic"); put("name", "Synthetic files"); put("isdir", true)
                put("additional", buildJsonObject { put("perm", buildJsonObject { put("share_right", "RO") }) })
            }) }); put("total", 1); put("offset", 0)
        }
        call.api == "SYNO.FileStation.List" && call.method in setOf("getinfo", "list") -> buildJsonObject {
            put("files", buildJsonArray { add(buildJsonObject {
                put("path", file.path); put("name", file.name); put("isdir", false); put("size", fileSize)
                put("additional", buildJsonObject { put("time", buildJsonObject { put("mtime", 123) }); put("perm", buildJsonObject { put("read", true); put("write", false); put("delete", false) }) })
            }) }); put("total", 1); put("offset", 0)
        }
        call.api == "SYNO.Virtualization.API.Storage" -> buildJsonObject {
            put("storages", buildJsonArray { add(buildJsonObject { put("storage_id", "storage-1"); put("storage_name", storageName); put("status", storageStatus) }) })
            storageTotal?.let { put("total", it) }
        }
        call.api == "SYNO.Virtualization.API.Guest.Image" && call.method == "create" -> {
            if (fixture.applyWrite) {
                val name = call.fields.getValue("image_name").jsonPrimitive.content; val type = call.fields.getValue("type").jsonPrimitive.content
                tasks[taskId] = task(finished, returnedImageId ?: imageId)
                if (imageVisible) fixture.images = fixture.images + VmmFixture.image(imageId, createImageName ?: name, createImageType ?: type)
            }
            buildJsonObject { if (!missingReceipt) put("task_id", taskId) }
        }
        call.api == "SYNO.Virtualization.API.Task.Info" -> when (call.method) {
            "list" -> taskListOverride ?: buildJsonObject { put("task_ids", JsonArray(tasks.keys.map(::JsonPrimitive))) }
            "get" -> tasks.getValue(call.fields.getValue("task_id").jsonPrimitive.content)
            "clear" -> { if (fixture.applyWrite) tasks.remove(call.fields.getValue("task_id").jsonPrimitive.content); buildJsonObject {} }
            else -> error("Unexpected synthetic task request")
        }
        else -> null
    }
    companion object {
        fun task(finished: Boolean = true, image: String? = null, progress: JsonElement = JsonPrimitive(if (finished) 100 else 30)) = buildJsonObject {
            put("finish", finished); put("task_info", buildJsonObject { put("progress", progress); image?.let { put("image_id", it) } })
        }
    }
}
