package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import kotlinx.serialization.json.*

internal class NasRegionFixture : NasManagementGateway {
    data class Request(val method: String, val version: Int, val fields: Map<String, JsonElement>, val write: Boolean)
    var settings = row("""{"date_format":"Y-m-d","time_format":"H:i","timezone":"UTC","enable_ntp":"manual","server":"","date":"2026/7/26","hour":18,"minute":30,"second":10}""")
    var zones = row("""{"zonedata":[{"value":"UTC","display":"UTC"},{"value":"Asia/Shanghai","display":"Shanghai"}]}""")
    val requests = mutableListOf<Request>(); val writes get() = requests.filter { it.write }
    var before: suspend (Request) -> Unit = {}; var afterWrite: suspend (Request) -> Unit = {}; var access: suspend () -> Unit = {}
    var versions = setOf(1, 2, 3)
    val repository = NasRegionSettingsRepository(this) { name, version -> name == REGION_SETTINGS_API && version in versions }
    override suspend fun requireWriteAccess() { access() }
    override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
        require(api == REGION_SETTINGS_API)
        val request = Request(method, version, parameters, write); requests += request; before(request)
        if (write) {
            if (method == "set") settings = JsonObject(settings + parameters)
            afterWrite(request); return JsonObject(emptyMap())
        }
        return if (method == "get") settings else zones
    }
    fun field(name: String, value: JsonElement) { settings = JsonObject(settings + (name to value)) }
    companion object { fun row(value: String) = Json.parseToJsonElement(value).jsonObject }
}
