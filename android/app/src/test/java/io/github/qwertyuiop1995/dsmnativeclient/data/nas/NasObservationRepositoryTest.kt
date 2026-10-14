package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.NasObservationProtocolFixture
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasObservationRepositoryTest {
    private val fixture = NasObservationProtocolFixture()
    private suspend fun rejected(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (_: Exception) { } }
    @Test fun `日志FORM与JSON固定系统源和v1按真实偏移分页`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            fixture.requestFormat = format; val repo = fixture.repository().nasObservation
            val page = repo.logs(100, 50); assertEquals(100, page.offset); assertEquals(250, page.total); assertTrue(page.hasNext)
            assertEquals("Synthetic entry 100", page.entries.single().message); assertEquals(LogLevel.INFO, page.entries.single().level)
            val sent = fixture.requests.last(); assertEquals(SYSTEM_LOG, sent.api); assertEquals("list", sent.method); assertEquals(1, sent.version)
            assertEquals("100", sent.fields["offset"]); assertEquals("50", sent.fields["limit"]); assertFalse(sent.write)
        }
    }
    @Test fun `日志未知总数满页继续不足停止真实空与畸形分开`() = runBlocking {
        val repo = fixture.repository().nasObservation
        fixture.logs = { offset, limit -> NasObservationProtocolFixture.logPage(offset, limit, null) }
        assertNull(repo.logs(0, 50).total); assertTrue(repo.logs(0, 50).hasNext)
        fixture.logs = { offset, _ -> NasObservationProtocolFixture.logPage(offset, 2, null) }; assertFalse(repo.logs(50, 50).hasNext)
        fixture.logs = { offset, _ -> NasObservationProtocolFixture.logPage(offset, 0, 20) }; assertFalse(repo.logs(100, 50).hasNext)
        fixture.logs = { _, _ -> buildJsonObject { } }; rejected { repo.logs(0, 50) }
        fixture.logs = { _, _ -> JsonObject(NasObservationProtocolFixture.logPage() + ("total" to JsonPrimitive("250"))) }; rejected { repo.logs(0, 50) }
        fixture.logs = { _, _ -> buildJsonObject { put("items", JsonArray(listOf(buildJsonObject { put("descr", 10) }))) } }; rejected { repo.logs(0, 50) }
        fixture.logs = { _, limit -> NasObservationProtocolFixture.logPage(0, limit + 1) }; rejected { repo.logs(0, 50) }
    }
    @Test fun `进程白名单移除命令参数路径账号环境变量且读取服务组`() = runBlocking {
        val directory = fixture.repository().nasObservation.processes()
        assertEquals("10", directory.processes.single().id); assertEquals("worker", directory.processes.single().name)
        assertEquals("synthetic.service", directory.groups.single().id); assertEquals(1, directory.groups.single().count)
        val text = directory.toString(); assertFalse(text.contains("synthetic-secret")); assertFalse(text.contains("synthetic-account")); assertFalse(text.contains("/synthetic"))
        assertEquals(listOf(SYSTEM_PROCESS, SYSTEM_PROCESS_GROUP), fixture.requests.map { it.api })
        assertTrue(fixture.requests.all { it.version == 1 && it.fields["limit"] == "500" && it.fields["start"] == "0" && !it.write })
    }
    @Test fun `进程服务组缺失或失败不影响快照并明确截断`() = runBlocking {
        fixture.groupsSupported = false
        assertTrue(fixture.repository().nasObservation.processes().groupsUnavailable); assertTrue(fixture.requests.none { it.api == SYSTEM_PROCESS_GROUP })
        fixture.groupsSupported = true; fixture.failingApi = SYSTEM_PROCESS_GROUP
        assertEquals(1, fixture.repository().nasObservation.processes().processes.size)
        fixture.failingApi = null; fixture.processes = buildJsonObject { put("process", JsonArray((0..500).map { buildJsonObject { put("pid", it); put("name", "Synthetic") } })) }
        val directory = fixture.repository().nasObservation.processes(); assertEquals(500, directory.processes.size); assertTrue(directory.truncated)
    }
    @Test fun `进程拒绝缺容器去重编号并略去非法身份`() = runBlocking {
        val repo = fixture.repository().nasObservation
        fixture.processes = buildJsonObject { }; rejected { repo.processes() }
        fixture.processes = Json.parseToJsonElement("""{"items":[{"pid":1,"name":"one"},{"pid":1,"name":"duplicate"},{"pid":1.2,"name":"bad"},{"pid":2,"name":"two","group_id":"/private/path"}]}""").jsonObject
        val rows = repo.processes(); assertEquals(listOf("1", "2"), rows.processes.map { it.id }); assertNull(rows.processes.last().groupId); assertTrue(rows.truncated)
    }
    @Test fun `版本不支持或旧账号零请求服务组取消不能转部分成功`() = runBlocking {
        fixture.minimumVersion = 2; val repo = fixture.repository().nasObservation; rejected { repo.processes() }; rejected { repo.logs(0, 50) }; assertTrue(fixture.requests.isEmpty())
        fixture.minimumVersion = 1; val valid = fixture.repository().nasObservation; fixture.ownerValid = false; rejected { valid.logs(0, 50) }; assertTrue(fixture.requests.isEmpty())
        val cancellation = CancellationException("Synthetic cancel")
        val gateway = object : NasManagementGateway {
            override suspend fun requireWriteAccess() = error("Read only")
            override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
                if (api == SYSTEM_PROCESS_GROUP) throw cancellation
                return NasObservationProtocolFixture().processes
            }
        }
        try { NasObservationRepository(gateway) { _, _ -> true }.processes(); fail() } catch (actual: CancellationException) { assertSame(cancellation, actual) }
    }
    @Test fun `只有服务组权限不足时保留进程但身份异常停止显示`() = runBlocking {
        var failure = DsmFailure(105, "Synthetic group denied", "", kind = DsmErrorKind.PERMISSION_DENIED)
        val gateway = object : NasManagementGateway {
            override suspend fun requireWriteAccess() = error("Read only")
            override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
                if (api == SYSTEM_PROCESS_GROUP) throw failure
                return fixture.processes
            }
        }
        val repo = NasObservationRepository(gateway) { _, _ -> true }; val directory = repo.processes()
        assertTrue(directory.groupsUnavailable); assertEquals(1, directory.processes.size)
        failure = DsmFailure(null, "Synthetic identity changed", "", kind = DsmErrorKind.WORKSPACE_CHANGED)
        rejected { repo.processes() }
    }
}
