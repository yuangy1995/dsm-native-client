package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * 保留既有 DSM 请求契约的构造器。
 *
 * 版本显式指定时仍按能力范围校验；未指定版本时仍委托既有客户端选择其记录的版本。
 */
internal class DsmRepositoryRequestBuilder(
    private val profile: NasProfile,
    private val session: DsmSession,
    private val api: DsmApiClient,
    private val capabilities: DsmRepositoryCapabilityResolver,
) {
    suspend fun call(
        apiName: String,
        method: String,
        parameters: Map<String, String> = emptyMap(),
        version: Int? = null,
    ): JsonObject {
        val capability = capabilities.requireCapability(apiName)
        if (version == null) return api.call(profile, session, capability, method, parameters)
        if (version !in capability.minVersion..capability.maxVersion) {
            throw DsmFailure(
                103,
                "Feature unsupported",
                "Update DSM or the related package.",
                kind = DsmErrorKind.FEATURE_UNSUPPORTED,
            )
        }
        val path = if (capability.path.startsWith('/')) capability.path else "/webapi/${capability.path}"
        return api.call(
            profile = profile,
            session = session,
            api = capability.name,
            version = version,
            method = method,
            parameters = parameters,
            path = path,
        )
    }

    fun jsonStrings(values: List<String>): String = JsonArray(values.map(::JsonPrimitive)).toString()

    fun jsonStringArray(values: List<String>): String = jsonStrings(values)

    fun join(parent: String, child: String): String =
        if (parent.endsWith('/')) "$parent$child" else "$parent/$child"
}
