package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import kotlinx.serialization.json.*

/** 仅用于合成协议测试，不连接真实任务或执行脚本。 */
internal class NasScheduledTaskFixture : NasManagementGateway {
    data class Request(val api: String, val method: String, val version: Int, val fields: Map<String, JsonElement>, val write: Boolean)
    val requests = mutableListOf<Request>()
    var rows = listOf(row())
    val details = mutableMapOf(10L to detail())
    var history = listOf(result())
    var output = buildJsonObject { put("script_in", "synthetic command"); put("script_out", "synthetic output") }
    var accessFailure: Exception? = null; var responseFailure: Exception? = null; var readFailure: Exception? = null
    var afterWrite: (() -> Unit)? = null
    var beforeRead: ((String) -> Unit)? = null
    var mutate = true
    var nextId = 20L
    override suspend fun requireWriteAccess() { accessFailure?.let { throw it } }
    override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
        requests += Request(api, method, version, parameters, write)
        if (!write) {
            beforeRead?.invoke(method)
            readFailure?.let { throw it }
            return when (method) {
                "list" -> buildJsonObject { put("tasks", JsonArray(rows)); put("total", rows.size) }
                "get" -> details.getValue(parameters.getValue("id").jsonPrimitive.long)
                "result_list" -> buildJsonObject { put("results", JsonArray(history)) }
                "result_get_file" -> output
                else -> error("Unexpected synthetic read")
            }
        }
        if (mutate) {
            val id = parameters["id"]?.jsonPrimitive?.long ?: nextId++
            when (method) {
                "delete" -> { rows = rows.filterNot { it.getValue("id").jsonPrimitive.long == id }; details.remove(id) }
                "set_enable" -> {
                    rows = rows.map { if (it.getValue("id").jsonPrimitive.long == id) JsonObject(it + ("enable" to parameters.getValue("enable"))) else it }
                    details[id]?.let { details[id] = JsonObject(it + ("enable" to parameters.getValue("enable"))) }
                }
                "create", "set" -> {
                    val old = rows.singleOrNull { it.getValue("id").jsonPrimitive.long == id } ?: row(id)
                    rows = rows.filterNot { it.getValue("id").jsonPrimitive.long == id } + JsonObject(old + parameters.filterKeys { it in setOf("name", "owner", "real_owner", "enable", "type") })
                    details[id] = JsonObject(parameters + ("id" to JsonPrimitive(id)) + ("real_owner" to (parameters["real_owner"] ?: old.getValue("real_owner"))))
                }
                "run" -> Unit
                else -> error("Unexpected synthetic write")
            }
        }
        afterWrite?.invoke(); responseFailure?.let { throw it }
        return buildJsonObject { }
    }
    companion object {
        fun row(id: Long = 10) = Json.parseToJsonElement("""{"id":$id,"name":"Synthetic task","owner":"Synthetic user","real_owner":"Synthetic selector","type":"script","action":"synthetic","enable":true,"can_edit":true,"can_run":true,"next_trigger_time":"2026-10-14 12:00:00"}""").jsonObject
        fun detail(id: Long = 10) = Json.parseToJsonElement("""{"id":$id,"name":"Synthetic task","owner":"Synthetic user","real_owner":"Synthetic selector","enable":true,"schedule":{"date_type":0,"week_day":"1,3,5","repeat_date":1001,"monthly_week":[],"hour":12,"minute":5,"repeat_hour":0,"repeat_min":0,"last_work_hour":0},"extra":{"script":"echo synthetic","notify_if_error":false,"notify_mail":""}}""").jsonObject
        fun result(id: String = "synthetic-result") = buildJsonObject { put("result_id", id); put("task_name", "Synthetic task"); put("start_time", "2026-10-13 12:00:00"); put("exit_info", buildJsonObject { put("exit_type", "normal"); put("exit_code", 0) }) }
    }
}
