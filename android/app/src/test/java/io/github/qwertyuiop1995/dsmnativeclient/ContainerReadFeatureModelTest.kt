package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import okhttp3.*
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.*
import org.junit.Test

class ContainerReadFeatureModelTest {
    @Test fun `撤销读取任务会取消挂起搜索且迟到响应不写回`() = runBlocking {
        val fixture = Fixture()
        try {
            fixture.model.searchRegistry()
            withTimeout(5_000) { fixture.entered.await() }
            val jobs = fixture.job.children.toList()
            fixture.model.invalidate()
            fixture.state.value = fixture.state.value!!.copy(containerRegistryResults = Loadable.Idle, containerRegistryVisible = false)
            withTimeout(5_000) { jobs.joinAll() }
            assertTrue(jobs.all { it.isCancelled })
            fixture.release.countDown()
            withTimeout(5_000) { fixture.returned.await() }
            assertEquals(Loadable.Idle, fixture.state.value?.containerRegistryResults)
        } finally { fixture.close() }
    }

    @Test fun `修改搜索取消旧任务且只保留新查询结果`() = runBlocking {
        val fixture = Fixture()
        try {
            fixture.model.searchRegistry()
            withTimeout(5_000) { fixture.entered.await() }
            val old = fixture.job.children.toList()
            fixture.model.updateQuery("new")
            fixture.model.searchRegistry()
            val result = withTimeout(5_000) { fixture.state.first { it?.containerRegistryResults is Loadable.Ready } }!!
            assertEquals("new", (result.containerRegistryResults as Loadable.Ready).value.single().name)
            assertTrue(old.all { it.isCancelled })
            fixture.release.countDown()
            withTimeout(5_000) { fixture.returned.await() }
            assertEquals("new", (fixture.state.value!!.containerRegistryResults as Loadable.Ready).value.single().name)
        } finally { fixture.close() }
    }

    private class Fixture {
        val job = SupervisorJob()
        private val scope = CoroutineScope(job + Dispatchers.Default)
        val entered = CompletableDeferred<Unit>()
        val returned = CompletableDeferred<Unit>()
        val release = CountDownLatch(1)
        private val profile = NasProfile("synthetic", "Synthetic", "https://nas.example.invalid", "synthetic")
        private val http = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .addInterceptor { chain ->
                val body = chain.request().body as FormBody
                val query = (0 until body.size).first { body.name(it) == "q" }.let(body::value)
                if (query == "old") {
                    entered.complete(Unit)
                    check(release.await(5, TimeUnit.SECONDS))
                    returned.complete(Unit)
                }
                Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("synthetic")
                    .body("""{"success":true,"data":{"data":[{"name":"$query","registry":"synthetic.invalid"}]}}"""
                        .toResponseBody("application/json".toMediaType())).build()
            }.build()
        private val repository: DsmRepository = authorizedRepository(profile, DsmSession(profile.id, "synthetic"), DsmApiClient(http),
            mapOf("SYNO.Docker.Registry" to ApiCapability("SYNO.Docker.Registry", "entry.cgi", 1, 1)))
        val state = MutableStateFlow<WorkspaceState?>(WorkspaceState(profile, selectedModule = Module.CONTAINERS,
            availability = repository.availability(), supportsContainerRegistry = true,
            containerRegistryVisible = true, containerRegistryQuery = "old"))
        val model = ContainerReadFeatureModel(scope, state) { repository }
        fun close() { release.countDown(); job.cancel(); http.dispatcher.executorService.shutdownNow() }
    }
}
