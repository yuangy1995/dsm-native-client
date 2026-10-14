package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.serialization.json.*

/** 沿用当前工作区授权、会话及证书策略；不访问目录返回的第三方下载地址。 */
internal class DsmNasPackageGateway(
    private val profile: NasProfile, private val session: DsmSession, private val api: DsmApiClient,
    private val capabilities: Map<String, ApiCapability>, private val refreshAccess: suspend () -> Unit,
) : NasPackageGateway {
    private fun capability(name: String, version: Int) = capabilities[name]?.takeIf { version in it.minVersion..it.maxVersion }
        ?: throw DsmFailure(103, "Feature unsupported", "Open Package Center in DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
    override suspend fun requireWriteAccess() {
        refreshAccess()
    }
    override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
        val cap = capability(api, version)
        val json = cap.requestFormat.equals("JSON", ignoreCase = true)
        return this.api.call(profile, session, cap.copy(maxVersion = version), method,
            parameters.mapValues { (_, value) -> if (json || value !is JsonPrimitive) value.toString() else value.content }, oneShot = write)
    }
    override suspend fun upload(source: UploadSource): JsonObject = api.uploadPackage(profile, session, capability(PACKAGE_INSTALL, 1), source)
}
