package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.runBlocking
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDateTime

class ContainerOverviewRepositoryTest {
    @Test fun `空项目对象非空摘要与未知数量正确区分`() = runBlocking {
        val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement
        assertTrue(repo.projectDefinitions().isEmpty())
        fixture.projects = ContainerFixture.obj("""{"project-one":{"name":"Synthetic project","status":"running","containerIds":["first","second"]},"project-two":{"name":"Other project","status":"stopped"}}""")
        val values = repo.projectDefinitions(); assertEquals(2, values.single { it.id == "project-one" }.containerCount)
        assertNull(values.single { it.id == "project-two" }.containerCount); assertEquals(ResourceState.RUNNING, values.single { it.id == "project-one" }.state)
        fixture.projects = ContainerFixture.obj("""{"invalid":false}"""); assertTrue(runCatching { repo.projectDefinitions() }.isFailure)
    }
    @Test fun `日志读取后续页且保留NAS墙上时间不假设时区`() = runBlocking {
        val fixture = logs(listOf(logPage(0, 2), logPage(1, 2)))
        val rows = fixture.first.containerManagement.containerEvents()
        assertEquals(2, rows.size); assertEquals(listOf("0", "1"), fixture.second.map { it["offset"] })
        assertTrue(rows.all { it.localTime == LocalDateTime.of(2026, 10, 14, 12, 30, 45) && it.timeEpochSeconds == null })
        assertEquals(2, rows.map { it.id }.distinct().size)
        assertTrue(fixture.second.all { it["action"] == "load" && it["sort_dir"] == "DESC" && it["limit"] == "1000" })
    }
    @Test fun `日志中间空页偏移变化畸形总数与日期不能冒充完整`() = runBlocking {
        for (page in listOf("""{"logs":[],"offset":1,"total":2}""", logPage(0, 2), logPage(1, 3),
            logPage(1, 2).replace("2026/10/14", "2026/02/30"), logPage(1, 2).replace("\"total\":2", "\"total\":\"2\""))) {
            assertTrue(runCatching { logs(listOf(logPage(0, 2), page)).first.containerManagement.containerEvents() }.isFailure)
        }
    }
    private fun logPage(offset: Int, total: Int) = """{"logs":[{"event":"Synthetic event","level":"info","log_type":"container","user":"Synthetic user","time":"2026/10/14 12:30:45"}],"offset":$offset,"total":$total}"""
    private fun logs(pages: List<String>): Pair<io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository, MutableList<Map<String, String>>> {
        val calls = mutableListOf<Map<String, String>>(); val pending = ArrayDeque(pages)
        val http = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request(); val body = request.body as FormBody
            calls += (0 until body.size).associate { body.name(it) to body.value(it) }
            Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                .body(("{\"success\":true,\"data\":" + pending.removeFirst() + "}").toResponseBody("application/json".toMediaType())).build()
        }.build()
        val profile = NasProfile("synthetic", "Synthetic", "https://synthetic.invalid", "Synthetic user")
        val repo = authorizedRepository(profile, DsmSession(profile.id, "synthetic-session"), DsmApiClient(http),
            mapOf("SYNO.Docker.Log" to ApiCapability("SYNO.Docker.Log", "entry.cgi", 1, 2)))
        return repo to calls
    }
}
