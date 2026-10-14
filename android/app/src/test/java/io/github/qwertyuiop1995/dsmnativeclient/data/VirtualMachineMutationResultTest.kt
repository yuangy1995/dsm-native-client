package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineSection
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import kotlinx.coroutines.runBlocking
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.BufferedSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VirtualMachineMutationResultTest {
    @Test
    fun `概览附加网络失败时仍返回虚拟机与主机`() = runBlocking {
        val transport = VmmOverviewInterceptor()
        val overview = repository(
            transport,
            GUEST,
            HOST,
            STORAGE,
            NETWORK,
            IMAGE,
        ).virtualMachineOverview()

        assertEquals(listOf("VM 1"), overview.machines.map { it.name })
        assertEquals(listOf("Host 1"), overview.hosts.map { it.name })
        assertTrue(VirtualMachineSection.NETWORKS in overview.unavailableSections)
        assertFalse(VirtualMachineSection.HOSTS in overview.unavailableSections)
        assertEquals("SYNO.Virtualization.Guest", transport.requests.first().formFields()["api"])
    }

    @Test
    fun `正常关机必须有接受回执和原身份停止终态`() = runBlocking {
        val transport = VmmMutationInterceptor(guestDetail("running"), SUCCESS, guestList("shutdown"))
        val result = repository(transport, API_GUEST, API_GUEST_ACTION).control(VmmAction.SHUTDOWN)
        assertVerified(result)
        assertEquals(listOf("get", "shutdown", "list"), transport.methods())
        assertEquals("guest-1", transport.requests[1].formFields()["guest_id"])
    }

    @Test
    fun `强制关机必须在列表回读为停止后才确认成功`() = runBlocking {
        val transport = VmmMutationInterceptor(guestDetail("running"), SUCCESS, guestList("shutdown"))
        val result = repository(transport, API_GUEST, API_GUEST_ACTION).control(VmmAction.POWER_OFF)
        assertVerified(result)
        assertEquals(listOf("get", "poweroff", "list"), transport.methods())
        assertEquals("guest-1", transport.requests[1].formFields()["guest_id"])
    }

    @Test
    fun `删除虚拟机必须回读消失且发送稳定标识`() = runBlocking {
        val transport = VmmMutationInterceptor(guestList("shutdown"), SUCCESS, EMPTY_GUESTS)
        assertVerified(repository(transport, API_GUEST).control(VmmAction.DELETE, "shutdown"))
        assertEquals(listOf("list", "delete", "list"), transport.methods())
        RequestFixtureAssertions.assertRequest(transport.requests[1], "vmm/delete/synthetic-virtual-machine/request.json")
        assertEquals("guest-1", transport.requests[1].formFields()["guest_id"])
    }

    @Test
    fun `内部网络改名没有版本信息仍读取实际接口且权限拒绝时零写`() = runBlocking {
        val transport = VmmMutationInterceptor("""{"success":false,"error":{"code":105}}""", """{"success":false,"error":{"code":105}}""")
        val result = probe { repository(transport, NETWORK).virtualMachineManagement.mutateNetwork(network, "Existing", it) }
        assertPermissionBlocked(result)
        assertTrue(transport.requests.isNotEmpty()); assertTrue(transport.methods().all { it in setOf("get", "list") })
    }

    @Test
    fun `映像删除提交后回读断线保留接受阶段且不重放`() = runBlocking {
        val transport = VmmImageReadbackFailureInterceptor()
        val result = repository(transport, API_IMAGE).image()
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED), result.stages)
        assertTrue(result.failure is DsmFailure)
        assertEquals(listOf("list", "delete", "list"), transport.methods())
        RequestFixtureAssertions.assertRequest(transport.requests[1], "vmm/delete-image/synthetic-image/request.json")
    }

    @Test
    fun `内部网络删除没有版本信息仍读取实际接口且权限拒绝时零写`() = runBlocking {
        val transport = VmmMutationInterceptor("""{"success":false,"error":{"code":105}}""", """{"success":false,"error":{"code":105}}""")
        val result = probe { repository(transport, NETWORK).virtualMachineManagement.mutateNetwork(network, null, it) }
        assertPermissionBlocked(result)
        assertTrue(transport.requests.isNotEmpty()); assertTrue(transport.methods().all { it in setOf("get", "list") })
    }

    @Test
    fun `内部生命周期与删除没有版本信息仍读取实际接口且权限拒绝时零写`() = runBlocking {
        val transport = VmmMutationInterceptor("""{"success":false,"error":{"code":105}}""", """{"success":false,"error":{"code":105}}""")
        val repo = repository(transport, GUEST, GUEST_ACTION)
        assertPermissionBlocked(repo.control(VmmAction.SHUTDOWN))
        assertPermissionBlocked(repo.control(VmmAction.DELETE, "shutdown"))
        assertTrue(transport.requests.isNotEmpty()); assertTrue(transport.methods().all { it in setOf("get", "list") })
    }

    @Test
    fun `内部映像删除没有版本信息仍读取实际接口且权限拒绝时零写`() = runBlocking {
        val transport = VmmMutationInterceptor("""{"success":false,"error":{"code":105}}""", """{"success":false,"error":{"code":105}}""")
        val result = probe { repository(transport, IMAGE).virtualMachineManagement.deleteImage(
            VmmImage("image-1", "Synthetic", "disk", VmmSource.INTERNAL,
                listOf(VmmImageCopy("storage-1", "host-1", "online", "healthy"))), it) }
        assertPermissionBlocked(result)
        assertTrue(transport.requests.isNotEmpty()); assertTrue(transport.methods().all { it in setOf("get", "list") })
    }

    @Test
    fun `非契约生命周期动作不进入稳定动作集合`() {
        assertEquals(null, VmmAction.entries.singleOrNull { it.command == "pause" })
        assertEquals(setOf("poweron", "shutdown", "poweroff", "reboot", "delete"), VmmAction.entries.map { it.command }.toSet())
    }

    @Test
    fun `缺少用户所见身份基线时零写拒绝`() = runBlocking {
        val transport = VmmMutationInterceptor(guestDetail("running"))
        val result = repository(transport, API_GUEST, API_GUEST_ACTION).control(VmmAction.SHUTDOWN, name = "")
        assertChanged(result)
        assertEquals(listOf("get"), transport.methods())
    }

    @Test
    fun `生命周期锁内状态偏离用户所见基线时零写拒绝`() = runBlocking {
        val transport = VmmMutationInterceptor(guestDetail("shutdown"))
        assertChanged(repository(transport, API_GUEST, API_GUEST_ACTION).control(VmmAction.SHUTDOWN))
        assertEquals(listOf("get"), transport.methods())
    }

    @Test
    fun `强制关机状态偏离用户所见基线时零写拒绝`() = runBlocking {
        val transport = VmmMutationInterceptor(guestDetail("shutdown"))
        assertChanged(repository(transport, API_GUEST, API_GUEST_ACTION).control(VmmAction.POWER_OFF))
        assertEquals(listOf("get"), transport.methods())
    }

    @Test
    fun `生命周期动作与用户所见状态组合非法时零写拒绝`() = runBlocking {
        val transport = VmmMutationInterceptor(guestDetail("paused"))
        assertChanged(repository(transport, API_GUEST, API_GUEST_ACTION).control(VmmAction.SHUTDOWN, "paused"))
        assertEquals(listOf("get"), transport.methods())
    }

    @Test
    fun `VMM 删除预检遇到缺失标识时不发送写请求`() = runBlocking {
        val transport = VmmMutationInterceptor("""{"success":true,"data":{"guests":[{"guest_name":"Synthetic","status":"shutdown"}]}}""")
        val result = repository(transport, API_GUEST).control(VmmAction.DELETE, "shutdown")
        assertEquals(listOf(VmmStage.CANCELLED), result.stages)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (result.failure as DsmFailure).kind)
        assertEquals(listOf("list"), transport.methods())
    }

    @Test
    fun `VMM 删除预检遇到重复标识时不发送写请求`() = runBlocking {
        val duplicate = """{"success":true,"data":{"guests":[{"guest_id":"guest-1","guest_name":"One","status":"shutdown"},{"guest_id":"guest-1","guest_name":"Two","status":"shutdown"}]}}"""
        val transport = VmmMutationInterceptor(duplicate)
        val result = repository(transport, API_GUEST).control(VmmAction.DELETE, "shutdown")
        assertEquals(listOf(VmmStage.CANCELLED), result.stages)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (result.failure as DsmFailure).kind)
        assertEquals(listOf("list"), transport.methods())
    }

    @Test
    fun `生命周期回执丢失不以随后停止认领本次成功`() = runBlocking {
        val transport = ScriptedVmmInterceptor(VmmStep.Json(guestDetail("running")),
            VmmStep.Failure(IOException("synthetic lifecycle disconnect")), VmmStep.Json(guestList("shutdown")))
        val repo = repository(transport, API_GUEST, API_GUEST_ACTION)
        val result = repo.control(VmmAction.SHUTDOWN)
        assertUnknown(result)
        assertEquals(listOf("get", "shutdown"), transport.methods())
        // 独立读取只证明当前状态；缺少接受回执时不能更新本次操作为成功。
        assertEquals("shutdown", repo.virtualMachineManagement.controlTargets().single().status)
        assertUnknown(result)
        assertEquals(1, transport.methods().count { it == "shutdown" })
    }

    @Test
    fun `生命周期写后回读失败保持接受而未完成`() = runBlocking {
        val transport = ScriptedVmmInterceptor(VmmStep.Json(guestDetail("running")), VmmStep.Json(SUCCESS), VmmStep.Json(SUCCESS))
        val result = repository(transport, API_GUEST, API_GUEST_ACTION).control(VmmAction.SHUTDOWN)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED), result.stages)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (result.failure as DsmFailure).kind)
        assertEquals(1, transport.methods().count { it == "shutdown" })
    }

    @Test
    fun `生命周期与删除在途取消均保留提交且不重放`() = runBlocking {
        for (action in listOf(VmmAction.SHUTDOWN, VmmAction.DELETE)) {
            val baseline = if (action == VmmAction.DELETE) guestList("shutdown") else guestDetail("running")
            val transport = ScriptedVmmInterceptor(VmmStep.Json(baseline), VmmStep.Cancellation)
            val repo = repository(transport, API_GUEST, API_GUEST_ACTION)
            val result = repo.control(action, if (action == VmmAction.DELETE) "shutdown" else "running")
            assertEquals(listOf(VmmStage.SUBMITTED), result.stages)
            assertTrue(result.failure is kotlinx.coroutines.CancellationException)
            assertEquals(listOf(if (action == VmmAction.DELETE) "list" else "get", action.command), transport.methods())
        }
    }

    @Test
    fun `虚拟机删除回执丢失不以随后消失认领本次成功`() = runBlocking {
        val transport = ScriptedVmmInterceptor(VmmStep.Json(guestList("shutdown")),
            VmmStep.Failure(IOException("synthetic delete disconnect")), VmmStep.Json(EMPTY_GUESTS))
        val repo = repository(transport, API_GUEST)
        val result = repo.control(VmmAction.DELETE, "shutdown")
        assertUnknown(result)
        assertEquals(listOf("list", "delete"), transport.methods())
        assertTrue(repo.virtualMachineManagement.controlTargets().isEmpty())
        assertUnknown(result)
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `虚拟机删除写后回读失败保持接受而未完成`() = runBlocking {
        val transport = ScriptedVmmInterceptor(VmmStep.Json(guestList("shutdown")), VmmStep.Json(SUCCESS), VmmStep.Json(SUCCESS))
        val result = repository(transport, API_GUEST).control(VmmAction.DELETE, "shutdown")
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED), result.stages)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (result.failure as DsmFailure).kind)
        assertEquals(1, transport.methods().count { it == "delete" })
    }

    @Test
    fun `公开映像删除成功断线与取消均不重放`() = runBlocking {
        val successTransport = ScriptedVmmInterceptor(VmmStep.Json(IMAGE_LIST), VmmStep.Json(SUCCESS), VmmStep.Json(EMPTY_IMAGES))
        assertVerified(repository(successTransport, API_IMAGE).image())
        for (failure in listOf(VmmStep.Failure(IOException("synthetic image delete disconnect")), VmmStep.Cancellation)) {
            val transport = ScriptedVmmInterceptor(VmmStep.Json(IMAGE_LIST), failure, VmmStep.Json(EMPTY_IMAGES))
            val repo = repository(transport, API_IMAGE)
            val result = repo.image()
            assertEquals(listOf(VmmStage.SUBMITTED), result.stages)
            assertTrue(result.failure != null)
            assertEquals(listOf("list", "delete"), transport.methods())
            assertTrue(repo.virtualMachineManagement.imageInventory().images.isEmpty())
            assertEquals(listOf(VmmStage.SUBMITTED), result.stages)
            assertEquals(1, transport.methods().count { it == "delete" })
        }
    }

    private data class Probe(val stages: List<VmmStage>, val failure: Throwable?)
    private suspend fun probe(action: suspend ((VmmStage) -> Unit) -> Unit): Probe {
        val stages = mutableListOf<VmmStage>()
        val result = runCatching { action { stages += it } }
        return Probe(stages.toList(), result.exceptionOrNull())
    }
    private suspend fun DsmRepository.control(action: VmmAction, status: String = "running", name: String = "Synthetic") = probe { checkpoint ->
        val repo = virtualMachineManagement
        val actions = VmmAction.entries.filter { runCatching { repo.controlSource(it) }.isSuccess }.toSet()
        repo.performControl(VmmControlTarget("guest-1", name, status, actions), action, repo.controlSource(action), checkpoint)
    }
    private suspend fun DsmRepository.image() = probe {
        virtualMachineManagement.deleteImage(VmmImage("image-1", "Synthetic", null, VmmSource.PUBLIC), it)
    }
    private fun assertVerified(result: Probe) {
        assertEquals(null, result.failure)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED, VmmStage.VERIFIED), result.stages)
    }
    private fun assertUnknown(result: Probe) {
        assertEquals(listOf(VmmStage.SUBMITTED), result.stages)
        assertTrue(result.failure is DsmFailure)
    }
    private fun assertChanged(result: Probe) {
        assertEquals(listOf(VmmStage.CANCELLED), result.stages)
        assertEquals(VmmProblem.CHANGED, (result.failure as VmmFailure).problem)
    }
    private fun assertPermissionBlocked(result: Probe) {
        assertEquals(listOf(VmmStage.CANCELLED), result.stages)
        assertEquals(DsmErrorKind.PERMISSION_DENIED, (result.failure as DsmFailure).kind)
    }
    private val network = VmmNetwork("network-1", "Synthetic", "private", "host-1", 0, emptyList(), emptyList())

    private fun repository(interceptor: Interceptor, vararg capabilities: String) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        capabilities.associateWith { name ->
            ApiCapability(name, "entry.cgi", 1, if (name in setOf(GUEST, IMAGE, NETWORK)) 2 else 1)
        },
    )

    private fun guestList(status: String) =
        """{"success":true,"data":{"guests":[{"guest_id":"guest-1","guest_name":"Synthetic","status":"$status"}]}}"""

    private fun guestDetail(status: String) =
        """{"success":true,"data":{"guest_id":"guest-1","guest_name":"Synthetic","status":"$status"}}"""

    private companion object {
        const val EMPTY_GUESTS = """{"success":true,"data":{"guests":[]}}"""
        const val EMPTY_IMAGES = """{"success":true,"data":{"images":[]}}"""
        const val IMAGE_LIST = """{"success":true,"data":{"images":[{"image_id":"image-1","image_name":"Synthetic"}]}}"""
        const val GUEST = "SYNO.Virtualization.Guest"
        const val API_GUEST = "SYNO.Virtualization.API.Guest"
        const val API_GUEST_ACTION = "SYNO.Virtualization.API.Guest.Action"
        const val GUEST_ACTION = "SYNO.Virtualization.Guest.Action"
        const val HOST = "SYNO.Virtualization.Host"
        const val STORAGE = "SYNO.Virtualization.Repo"
        const val NETWORK = "SYNO.Virtualization.Network"
        const val IMAGE = "SYNO.Virtualization.Guest.Image"
        const val API_IMAGE = "SYNO.Virtualization.API.Guest.Image"
        const val SUCCESS = """{"success":true,"data":{}}"""
    }
}

private class VmmOverviewInterceptor : Interceptor {
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val body = when (request.formFields()["api"]) {
            "SYNO.Virtualization.Guest" ->
                """{"success":true,"data":{"guests":[{"id":"g1","name":"VM 1","status":"running"}]}}"""
            "SYNO.Virtualization.Host" ->
                """{"success":true,"data":{"hosts":[{"id":"h1","name":"Host 1","status":"normal"}]}}"""
            "SYNO.Virtualization.Repo" -> """{"success":true,"data":{"repos":[]}}"""
            "SYNO.Virtualization.Network" -> """{"success":false,"error":{"code":105}}"""
            "SYNO.Virtualization.Guest.Image" -> """{"success":true,"data":{"images":[]}}"""
            else -> error("未处理的合成 VMM API")
        }
        return vmmResponse(request, body)
    }
}

private class VmmMutationInterceptor(vararg responses: String) : Interceptor {
    private val pending = ArrayDeque(responses.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return vmmResponse(
            request,
            pending.removeFirstOrNull() ?: error("缺少合成 VMM 响应"),
        )
    }

    fun methods(): List<String?> = requests.map { it.formFields()["method"] }
}

private class VmmImageReadbackFailureInterceptor : Interceptor {
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        if (requests.size == 3) throw IOException("synthetic disconnect")
        val body = if (requests.size == 1) {
            """{"success":true,"data":{"images":[{"image_id":"image-1","image_name":"Synthetic"}]}}"""
        } else {
            """{"success":true,"data":{}}"""
        }
        return vmmResponse(request, body)
    }

    fun methods(): List<String?> = requests.map { it.formFields()["method"] }
}

private sealed interface VmmStep {
    data class Json(val body: String) : VmmStep
    data class Failure(val error: IOException) : VmmStep
    data object Cancellation : VmmStep
}

private class ScriptedVmmInterceptor(vararg steps: VmmStep) : Interceptor {
    private val pending = ArrayDeque(steps.toList())
    val requests = mutableListOf<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        return when (val step = pending.removeFirstOrNull()
            ?: VmmStep.Failure(IOException("缺少合成 VMM 响应"))) {
            is VmmStep.Json -> vmmResponse(request, step.body)
            is VmmStep.Failure -> throw step.error
            VmmStep.Cancellation -> Response.Builder()
                .request(request)
                .protocol(Protocol.HTTP_1_1)
                .code(200)
                .message("OK")
                .body(VmmCancellationBody())
                .build()
        }
    }

    fun methods(): List<String?> = requests.map { it.formFields()["method"] }
}

private class VmmCancellationBody : ResponseBody() {
    override fun contentType() = "application/json".toMediaType()
    override fun contentLength() = -1L
    override fun source(): BufferedSource =
        throw kotlinx.coroutines.CancellationException("synthetic VMM cancellation")
}

private fun vmmResponse(request: Request, body: String): Response = Response.Builder()
    .request(request)
    .protocol(Protocol.HTTP_1_1)
    .code(200)
    .message("OK")
    .body(body.toResponseBody("application/json".toMediaType()))
    .build()

private fun Request.formFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}
