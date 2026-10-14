package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.*
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.net.URLDecoder
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer

internal class PackageProtocolFixture : Interceptor {
    val backend = NasPackageFixture()
    val requests = mutableListOf<Request>()
    var knownEnvironment = true
    var statusCode = 200
    var ownerValid = true
    fun repository(session: String = "session"): DsmRepository {
        val profile = NasProfile("synthetic-package", "Synthetic", "https://synthetic.invalid", "synthetic")
        val capabilities = listOf(PACKAGE_API, PACKAGE_INSTALL, PACKAGE_SETTINGS, PACKAGE_FEED, "SYNO.Core.Package.Server", "SYNO.Core.Package.Info",
            "SYNO.Core.Package.Setting.Volume", "SYNO.Core.Package.Installation.Download", "SYNO.Core.System", "SYNO.Core.Package.Control", "SYNO.Core.Package.Uninstallation")
            .associateWith { ApiCapability(it, "entry.cgi", 1, 2, "JSON") }
        return authorizedRepository(profile, DsmSession("synthetic-sid", "synthetic-token"), DsmApiClient(OkHttpClient.Builder().addInterceptor(this).build()), capabilities).also {
            it.bindOwner(WorkspaceOwner(profile.id, "identity", session)) { if (!ownerValid) throw DsmFailure(null, "synthetic changed", "", kind = DsmErrorKind.WORKSPACE_CHANGED) }
        }
    }
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request(); requests += request
        val body = Buffer().also { request.body?.writeTo(it) }.readUtf8()
        val data = if (request.url.queryParameter("method") == "upload") runBlocking {
            check(request.body?.isOneShot() == true)
            backend.upload(UploadSource("synthetic.spk", null, 3, { "spk".byteInputStream() }))
        } else {
            val fields = body.split('&').associate { field -> val pair = field.split('=', limit = 2); URLDecoder.decode(pair[0], "UTF-8") to URLDecoder.decode(pair.getOrElse(1) { "" }, "UTF-8") }
            val api = fields.getValue("api"); val method = fields.getValue("method")
            if (api == "SYNO.Core.System") Json.parseToJsonElement(if (knownEnvironment)
                """{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":69057,"smallfixnumber":12}"""
                else """{"firmware_ver":"DSM 7.3","buildnumber":99999,"smallfixnumber":1}""").jsonObject
            else runBlocking { backend.call(api, method, fields.getValue("version").toInt(), fields.filterKeys { it !in setOf("api", "method", "version") }.mapValues {
                Json.parseToJsonElement(it.value)
            }, request.body?.isOneShot() == true) }
        }
        return Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(statusCode).message("synthetic")
            .body(buildJsonObject { put("success", true); put("data", data) }.toString().toResponseBody("application/json".toMediaType())).build()
    }
}
