package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

internal class NasDirectoryFixture : NasManagementGateway {
    data class Request(val api: String, val method: String, val version: Int, val fields: Map<String, JsonElement>, val write: Boolean)
    val requests = mutableListOf<Request>()
    var users = listOf(user()); var groupRows = listOf(group())
    var accessFailure: Exception? = null; var responseFailure: Exception? = null; var readFailure: Exception? = null
    var afterWrite: (() -> Unit)? = null
    var onList: ((String) -> Unit)? = null
    var mutate = true
    var nextId = 200L
    var reads = 0
    override suspend fun requireWriteAccess() { accessFailure?.let { throw it } }
    override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
        requests += Request(api, method, version, parameters, write)
        check(version == 1)
        val account = api == "SYNO.Core.User"
        if (method == "list") {
            reads++; onList?.invoke(api); readFailure?.let { throw it }
            return buildJsonObject { put(if (account) "users" else "groups", JsonArray(if (account) users else groupRows)) }
        }
        check(write)
        if (mutate) {
            val name = if (method == "delete") parameters.getValue("name").jsonArray.single().jsonPrimitive.content else parameters.getValue("name").jsonPrimitive.content
            val old = if (account) users else groupRows
            val rows = if (method == "delete") old.filterNot { it.getValue("name").jsonPrimitive.content == name }
                else {
                    val previous = old.singleOrNull { it.getValue("name").jsonPrimitive.content == name }
                    val fields = (previous ?: if (account) user(name, nextId++) else group(name, nextId++)).toMutableMap()
                    fields.putAll(parameters.filterKeys { it !in setOf("password", "password_confirm") })
                    old.filterNot { it.getValue("name").jsonPrimitive.content == name } + JsonObject(fields)
                }
            if (account) users = rows else groupRows = rows
        }
        afterWrite?.invoke(); responseFailure?.let { throw it }
        return buildJsonObject { }
    }
    companion object {
        fun user(name: String = "Synthetic", id: Long = 100) = buildJsonObject {
            put("name", name); put("uid", id); put("description", "Synthetic account"); put("email", "synthetic@example.invalid")
            put("expired", "normal"); put("groups", JsonArray(listOf(JsonPrimitive("SyntheticGroup")))); put("can_edit", true); put("can_delete", true)
        }
        fun group(name: String = "SyntheticGroup", id: Long = 100) = buildJsonObject {
            put("name", name); put("gid", id); put("description", "Synthetic group"); put("can_edit", true); put("can_delete", true)
        }
    }
}
