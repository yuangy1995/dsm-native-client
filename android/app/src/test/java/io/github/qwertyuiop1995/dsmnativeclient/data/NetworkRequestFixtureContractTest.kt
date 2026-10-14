package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRemoteAccessSettings
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.runBlocking
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Test

class NetworkRequestFixtureContractTest {
    @Test
    fun `正式仓库入口生成的QuickConnect中继与路由请求符合公共Fixture`() = runBlocking {
        val transport = NetworkFixtureInterceptor()
        val repository = authorizedRepository(
            NasProfile("test", "Test", "https://nas.example.invalid", "operator"),
            DsmSession("test", "test-session", "test-token"),
            DsmApiClient(OkHttpClient.Builder().addInterceptor(transport).build()),
            mapOf(
                "SYNO.Core.QuickConnect" to ApiCapability(
                    "SYNO.Core.QuickConnect", "entry.cgi", 1, 5,
                ),
                "SYNO.Core.QuickConnect.Upnp" to ApiCapability(
                    "SYNO.Core.QuickConnect.Upnp", "entry.cgi", 1, 5,
                ),
                "SYNO.Core.System" to ApiCapability("SYNO.Core.System", "entry.cgi", 1, 3),
            ),
        )
        val original = NasRemoteAccessSettings(true, false, false, true)
        val desired = NasRemoteAccessSettings(false, true, false, true)

        val result = repository.nasServices.save(repository.nasServices.plan(NasServiceValue.RemoteAccess(original), NasServiceValue.RemoteAccess(desired))) { }

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        val relayRequest = transport.requests.single {
            it.fixtureFields()["api"] == "SYNO.Core.QuickConnect" &&
                it.fixtureFields()["method"] == "set_misc_config"
        }
        val routerRequest = transport.requests.single {
            it.fixtureFields()["api"] == "SYNO.Core.QuickConnect.Upnp" &&
                it.fixtureFields()["method"] == "set"
        }
        RequestFixtureAssertions.assertRequest(
            relayRequest,
            "network/set-relay/synthetic-setting/request.json",
        )
        RequestFixtureAssertions.assertRequest(
            routerRequest,
            "network/set-router-configuration/synthetic-setting/request.json",
        )
        assertEquals("3", relayRequest.fixtureFields()["version"])
        assertEquals("1", routerRequest.fixtureFields()["version"])
    }
}

private class NetworkFixtureInterceptor : Interceptor {
    val requests = mutableListOf<Request>()
    private var relayEnabled = true
    private var routerEnabled = false

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val fields = request.fixtureFields()
        val data = when (fields["api"] to fields["method"]) {
            "SYNO.Core.QuickConnect" to "get_misc_config" ->
                """{"relay_enabled":$relayEnabled}"""
            "SYNO.Core.QuickConnect.Upnp" to "get" ->
                """{"enabled":$routerEnabled}"""
            "SYNO.Core.System" to "info" ->
                """{"firmware_ver":"DSM 7.2.1-69057 Update 12","buildnumber":"69057","smallfixnumber":"12"}"""
            "SYNO.Core.QuickConnect" to "set_misc_config" -> {
                relayEnabled = checkNotNull(fields["relay_enabled"]).toBooleanStrict()
                "{}"
            }
            "SYNO.Core.QuickConnect.Upnp" to "set" -> {
                routerEnabled = checkNotNull(fields["enabled"]).toBooleanStrict()
                "{}"
            }
            else -> error("未预期的远程访问请求：${fields["api"]}.${fields["method"]}")
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(
                """{"success":true,"data":$data}"""
                    .toResponseBody("application/json".toMediaType()),
            )
            .build()
    }
}

private fun Request.fixtureFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return buildMap { repeat(form.size) { put(form.name(it), form.value(it)) } }
}
