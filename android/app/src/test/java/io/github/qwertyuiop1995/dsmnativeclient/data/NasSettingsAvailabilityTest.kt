package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.runBlocking
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NasSettingsAvailabilityTest {
    @Test
    fun `套件读取失败与账号群组真实空列表必须保留不同可用性`() = runBlocking {
        val transport = SettingsAvailabilityInterceptor()
        val capabilities = listOf(PACKAGE_API, USER_API, GROUP_API).associateWith { api ->
            ApiCapability(api, "entry.cgi", 1, if (api == PACKAGE_API) 2 else 1)
        }
        val repository = authorizedRepository(
            NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
            DsmSession("test", "test-session", "test-token"),
            DsmApiClient(OkHttpClient.Builder().addInterceptor(transport).build()),
            capabilities,
        )

        val snapshot = repository.nasSettings()

        assertTrue(snapshot.packages.isEmpty())
        assertFalse(snapshot.packagesAvailable)
        assertTrue(snapshot.accounts.isEmpty())
        assertTrue(snapshot.accountsAvailable)
        assertTrue(snapshot.groups.isEmpty())
        assertTrue(snapshot.groupsAvailable)
    }

    @Test
    fun `普通快照保留additional数字身份且缺权限字段不会猜测套件可操作`() = runBlocking {
        val transport = CompleteBaselineInterceptor()
        val capabilities = listOf(PACKAGE_API, USER_API, GROUP_API).associateWith { api ->
            ApiCapability(api, "entry.cgi", 1, if (api == PACKAGE_API) 2 else 1)
        }
        val repository = authorizedRepository(
            NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
            DsmSession("test", "test-session", "test-token"),
            DsmApiClient(OkHttpClient.Builder().addInterceptor(transport).build()),
            capabilities,
        )

        val snapshot = repository.nasSettings()

        assertEquals(1001L, snapshot.accounts.single().id)
        assertEquals(2001L, snapshot.groups.single().id)
        assertFalse(snapshot.packages.single().canStart)
        assertFalse(snapshot.packages.single().canStop)
        assertFalse(snapshot.packages.single().canUninstall)
    }

    @Test
    fun `日志请求成功返回空列表时保留可信源空状态`() = runBlocking {
        val snapshot = logRepository(logRequestSucceeds = true).nasSettings()

        assertTrue(snapshot.logsAvailable)
        assertTrue(snapshot.logs.isEmpty())
    }

    @Test
    fun `日志请求失败时空列表必须标记为不可用`() = runBlocking {
        val snapshot = logRepository(logRequestSucceeds = false).nasSettings()

        assertFalse(snapshot.logsAvailable)
        assertTrue(snapshot.logs.isEmpty())
    }

    private fun logRepository(logRequestSucceeds: Boolean) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(
            OkHttpClient.Builder()
                .addInterceptor(LogAvailabilityInterceptor(logRequestSucceeds))
                .build(),
        ),
        mapOf(LOG_API to ApiCapability(LOG_API, "entry.cgi", 1, 1)),
    )

    private companion object {
        const val PACKAGE_API = "SYNO.Core.Package"
        const val USER_API = "SYNO.Core.User"
        const val GROUP_API = "SYNO.Core.Group"
        const val LOG_API = "SYNO.LogCenter.History"
    }
}

private class LogAvailabilityInterceptor(
    private val succeeds: Boolean,
) : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val form = request.body as FormBody
        val fields = (0 until form.size).associate { form.name(it) to form.value(it) }
        val body = if (fields["api"] == "SYNO.LogCenter.History") {
            if (succeeds) {
                """{"success":true,"data":{"logs":[]}}"""
            } else {
                """{"success":false,"error":{"code":105}}"""
            }
        } else {
            error("出现未预期的日志可用性请求")
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }
}

private class CompleteBaselineInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val form = request.body as FormBody
        val fields = (0 until form.size).associate { form.name(it) to form.value(it) }
        val body = when (fields["api"]) {
            "SYNO.Core.Package" ->
                """{"success":true,"data":{"packages":[{"id":"synthetic-package","name":"Synthetic Package","version":"1.0.0","status":"stopped"}]}}"""
            "SYNO.Core.User" ->
                """{"success":true,"data":{"users":[{"name":"synthetic-account","additional":{"uid":1001,"can_delete":true}}]}}"""
            "SYNO.Core.Group" ->
                """{"success":true,"data":{"groups":[{"name":"synthetic-group","additional":{"gid":2001,"can_delete":true}}]}}"""
            else -> error("出现未预期的完整基线请求")
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }
}

private class SettingsAvailabilityInterceptor : Interceptor {
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val form = request.body as FormBody
        val fields = (0 until form.size).associate { form.name(it) to form.value(it) }
        val body = when (fields["api"]) {
            "SYNO.Core.Package" -> """{"success":false,"error":{"code":105}}"""
            "SYNO.Core.User" -> """{"success":true,"data":{"users":[]}}"""
            "SYNO.Core.Group" -> """{"success":true,"data":{"groups":[]}}"""
            else -> error("出现未预期的合成设置请求")
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }
}
