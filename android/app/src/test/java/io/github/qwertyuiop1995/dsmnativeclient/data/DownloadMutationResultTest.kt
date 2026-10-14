package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationAction
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationBaseline
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.IOException
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DownloadMutationResultTest {
    @Test
    fun `修改保存位置仅发送一次官方v2写请求并按回读确认`() = runTest {
        val destination = directory("/volume1/downloads/new")
        val transport = DownloadMutationInterceptor(
            ok(fileInfo(destination)),
            ok(taskList(task("task-1", "downloading", destination = "/volume1/downloads/old"))),
            ok(),
            ok(taskList(task("task-1", "downloading", destination = destination.path))),
        )

        val result = repository(transport).editDownloadDestinationResult(
            baseline("task-1", ResourceState.RUNNING, destination = "/volume1/downloads/old"),
            destination,
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals(listOf("getinfo", "list", "edit", "list"), transport.methods())
        assertEquals(1, transport.methods().count { it == "edit" })
        RequestFixtureAssertions.assertRequest(
            transport.requests[2],
            "download-station/edit-destination/synthetic-task-v2/request.json",
        )
    }

    @Test
    fun `目标目录或任务基线漂移时保存位置写请求为零`() = runTest {
        val destination = directory("/volume1/downloads/new")
        val directoryDrift = DownloadMutationInterceptor(
            ok(fileInfo(destination.copy(owner = "changed"))),
            ok(taskList(task("task-1", "downloading", destination = "/volume1/downloads/old"))),
        )
        val directoryResult = repository(directoryDrift).editDownloadDestinationResult(
            baseline("task-1", ResourceState.RUNNING, destination = "/volume1/downloads/old"),
            destination,
        )
        assertEquals(MutationErrorCategory.CONFLICT, directoryResult.errorCategory)
        assertFalse(directoryResult.submitted)
        assertEquals(listOf("getinfo", "list"), directoryDrift.methods())

        val taskDrift = DownloadMutationInterceptor(
            ok(fileInfo(destination)),
            ok(taskList(task("task-1", "paused", destination = "/volume1/downloads/old"))),
        )
        val taskResult = repository(taskDrift).editDownloadDestinationResult(
            baseline("task-1", ResourceState.RUNNING, destination = "/volume1/downloads/old"),
            destination,
        )
        assertEquals(MutationErrorCategory.CONFLICT, taskResult.errorCategory)
        assertFalse(taskResult.submitted)
        assertEquals(listOf("getinfo", "list"), taskDrift.methods())
    }

    @Test
    fun `写请求丢失回执时保留未知且不重放`() = runTest {
        val destination = directory("/volume1/downloads/new")
        val transport = DownloadMutationInterceptor(
            ok(fileInfo(destination)),
            ok(taskList(task("task-1", "downloading", destination = "/volume1/downloads/old"))),
            fail(IOException("synthetic disconnected after submit")),
            ok(taskList(task("task-1", "downloading", destination = destination.path))),
        )

        val result = repository(transport).editDownloadDestinationResult(
            baseline("task-1", ResourceState.RUNNING, destination = "/volume1/downloads/old"),
            destination,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, transport.methods().count { it == "edit" })
    }

    @Test
    fun `修改保存位置写后回读失败保持未确认且不重放`() = runTest {
        val destination = directory("/volume1/downloads/new")
        val transport = DownloadMutationInterceptor(
            ok(fileInfo(destination)),
            ok(taskList(task("task-1", "downloading", destination = "/volume1/downloads/old"))),
            ok(),
            fail(IOException("synthetic readback failure")),
        )

        val result = repository(transport).editDownloadDestinationResult(
            baseline("task-1", ResourceState.RUNNING, destination = "/volume1/downloads/old"),
            destination,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "edit" })
    }

    @Test
    fun `修改保存位置提交阶段取消只回读且不重放`() = runBlocking {
        val destination = directory("/volume1/downloads/new")
        val entered = CountDownLatch(1)
        val transport = DownloadMutationInterceptor(
            ok(fileInfo(destination)),
            ok(taskList(task("task-1", "downloading", destination = "/volume1/downloads/old"))),
            cancelWhenCallCancelled(entered),
            ok(taskList(task("task-1", "downloading", destination = destination.path))),
        )
        val captured = AtomicReference<io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult>()
        val repo = repository(transport)

        val cancelled = launch(Dispatchers.IO) {
            captured.set(
                repo.editDownloadDestinationResult(
                    baseline("task-1", ResourceState.RUNNING, destination = "/volume1/downloads/old"),
                    destination,
                ),
            )
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        cancelled.cancel()
        cancelled.join()

        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, checkNotNull(captured.get()).status)
        assertEquals(1, transport.methods().count { it == "edit" })
        assertEquals(listOf("getinfo", "list", "edit", "list"), transport.methods())
    }

    @Test
    fun `只有DownloadStation2或目录未变化时不发送请求`() = runTest {
        val destination = directory("/volume1/downloads/new")
        val unsupported = repository(
            DownloadMutationInterceptor(),
            capabilities = mapOf(
                "SYNO.DownloadStation2.Task" to ApiCapability(
                    "SYNO.DownloadStation2.Task", "entry.cgi", 1, 2,
                ),
                "SYNO.FileStation.List" to ApiCapability(
                    "SYNO.FileStation.List", "entry.cgi", 1, 2,
                ),
            ),
        ).editDownloadDestinationResult(
            baseline("task-1", ResourceState.RUNNING, destination = "/volume1/downloads/old"),
            destination,
        )
        assertEquals(MutationResultStatus.UNSUPPORTED, unsupported.status)

        val noOpTransport = DownloadMutationInterceptor()
        val noOp = repository(noOpTransport).editDownloadDestinationResult(
            baseline("task-1", ResourceState.RUNNING, destination = destination.path),
            destination,
        )
        assertEquals(MutationErrorCategory.VALIDATION, noOp.errorCategory)
        assertTrue(noOpTransport.requests.isEmpty())
    }

    @Test
    fun `写后专项刷新只接受严格任务数组且可信空列表可用`() = runTest {
        val valid = repository(DownloadMutationInterceptor(ok(taskList())))
            .activeDownloadTasksForMutation()
        assertTrue(valid.isEmpty())

        listOf(
            "{}",
            taskList("""{"title":"Missing id"}"""),
            """{"tasks":[${task("task-1", "downloading")}],"total":0}""",
        ).forEach { malformed ->
            val failure = runCatching {
                repository(DownloadMutationInterceptor(ok(malformed)))
                    .activeDownloadTasksForMutation()
            }.exceptionOrNull()
            assertTrue(failure is DsmFailure)
            assertEquals(DsmErrorKind.INVALID_RESPONSE, (failure as DsmFailure).kind)
        }
    }

    @Test
    fun `严格任务列表按稳定total完整分页`() = runTest {
        val firstPage = (0 until 500).map { task("task-$it", "downloading") }
        val transport = DownloadMutationInterceptor(
            ok(taskListWithTotal(501, *firstPage.toTypedArray())),
            ok(taskListWithTotal(501, task("task-500", "waiting"))),
        )

        val tasks = repository(transport).activeDownloadTasksForMutation()

        assertEquals(501, tasks.size)
        assertEquals("task-500", tasks.last().id)
        assertEquals(listOf("0", "500"), transport.requests.map { it.formFields()["offset"] })
        assertTrue(transport.requests.all { it.formFields()["limit"] == "500" })
    }

    @Test
    fun `对象外链任务会读取后续分页而不误判为不存在`() = runTest {
        val firstPage = (0 until 500).map { task("task-$it", "downloading") }
        val transport = DownloadMutationInterceptor(
            ok(taskListWithTotal(501, *firstPage.toTypedArray())),
            ok(taskListWithTotal(501, task("target-task", "waiting"))),
        )

        val target = repository(transport).downloadTask("target-task")

        assertEquals("target-task", target?.id)
        assertEquals(listOf("0", "500"), transport.requests.map { it.formFields()["offset"] })
    }

    @Test
    fun `严格任务列表拒绝分页期间total变化`() = runTest {
        val firstPage = (0 until 500).map { task("task-$it", "downloading") }
        val failure = runCatching {
            repository(
                DownloadMutationInterceptor(
                    ok(taskListWithTotal(501, *firstPage.toTypedArray())),
                    ok(taskListWithTotal(502, task("task-500", "waiting"))),
                ),
            ).activeDownloadTasksForMutation()
        }.exceptionOrNull()

        assertTrue(failure is DsmFailure)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (failure as DsmFailure).kind)
    }

    @Test
    fun `严格任务列表无total满页继续读取到空页`() = runTest {
        val fullPage = (0 until 500).map { task("task-$it", "downloading") }
        val transport = DownloadMutationInterceptor(ok(taskList(*fullPage.toTypedArray())), ok(taskList()))
        val tasks = repository(transport).activeDownloadTasksForMutation()
        assertEquals(500, tasks.size)
        assertEquals(listOf("0", "500"), transport.requests.map { it.formFields()["offset"] })
    }

    @Test
    fun `严格任务列表拒绝跨页重复ID`() = runTest {
        val firstPage = (0 until 500).map { task("task-$it", "downloading") }
        val failure = runCatching {
            repository(
                DownloadMutationInterceptor(
                    ok(taskListWithTotal(501, *firstPage.toTypedArray())),
                    ok(taskListWithTotal(501, task("task-499", "waiting"))),
                ),
            ).activeDownloadTasksForMutation()
        }.exceptionOrNull()

        assertTrue(failure is DsmFailure)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (failure as DsmFailure).kind)
    }

    @Test
    fun `严格任务列表未达到total时拒绝空页停滞`() = runTest {
        val failure = runCatching {
            repository(
                DownloadMutationInterceptor(
                    ok(taskListWithTotal(2, task("task-1", "downloading"))),
                    ok(taskListWithTotal(2)),
                ),
            ).activeDownloadTasksForMutation()
        }.exceptionOrNull()

        assertTrue(failure is DsmFailure)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (failure as DsmFailure).kind)
    }

    @Test
    fun `结束并移出未完成文件使用确认基线且不声称删除文件`() = runTest {
        val transport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "downloading"))),
            ok(),
            ok(taskList()),
        )

        val result = repository(transport).controlDownloadsResult(
            baseline = listOf(baseline("task-1", ResourceState.RUNNING)),
            action = DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES,
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals("downloadEndAndMove", result.operation)
        assertEquals(1, result.counts.succeeded)
        assertEquals(0, result.counts.unknown)
        assertEquals(0, result.counts.failed)
        assertFalse(result.requiresRefresh)
        assertEquals(listOf("list", "delete", "list"), transport.methods())
        RequestFixtureAssertions.assertRequest(
            transport.requests[1],
            "download-station/delete/synthetic-task/request.json",
        )
    }

    @Test
    fun `仅移除任务在严格列表确认消失后成功`() = runTest {
        val transport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "downloading"))),
            ok(),
            ok(taskList()),
        )

        val result = repository(transport).controlDownloadsResult(
            listOf(baseline("task-1", ResourceState.RUNNING)),
            DownloadTaskMutationAction.REMOVE_TASK,
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals("downloadDelete", result.operation)
        assertEquals(1, result.counts.succeeded)
        assertFalse(result.requiresRefresh)
        assertEquals("false", transport.requests[1].formFields()["force_complete"])
    }

    @Test
    fun `暂停和继续按最终状态逐项确认`() = runTest {
        val pauseTransport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "downloading"))),
            ok(),
            ok(taskList(task("task-1", "paused"))),
        )
        val paused = repository(pauseTransport).controlDownloadsResult(
            listOf(baseline("task-1", ResourceState.RUNNING)),
            DownloadTaskMutationAction.PAUSE,
        )
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, paused.status)
        assertFalse(pauseTransport.requests[1].formFields().containsKey("force_complete"))

        val resumeTransport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "paused"))),
            ok(),
            ok(taskList(task("task-1", "waiting"))),
        )
        val resumed = repository(resumeTransport).controlDownloadsResult(
            listOf(baseline("task-1", ResourceState.PAUSED)),
            DownloadTaskMutationAction.RESUME,
        )
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, resumed.status)
        assertEquals(1, resumed.counts.succeeded)
    }

    @Test
    fun `批量暂停只把已确认项计成功其余保持未知`() = runTest {
        val partial = taskList(task("a", "paused"), task("b", "downloading"))
        val transport = DownloadMutationInterceptor(
            ok(taskList(task("b", "downloading"), task("a", "downloading"))),
            ok(receipt("a", "b")),
            *Array(8) { ok(partial) },
        )

        val result = repository(transport).controlDownloadsResult(
            listOf(
                baseline("a", ResourceState.RUNNING),
                baseline("b", ResourceState.RUNNING),
            ),
            DownloadTaskMutationAction.PAUSE,
        )

        assertEquals(MutationResultStatus.PARTIAL_SUCCESS, result.status)
        assertEquals(1, result.counts.succeeded)
        assertEquals(0, result.counts.failed)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
    }

    @Test
    fun `顺序变化不构成漂移且请求ID固定排序`() = runTest {
        val transport = DownloadMutationInterceptor(
            ok(taskList(task("b", "downloading"), task("a", "downloading"))),
            ok(receipt("a", "b")),
            ok(taskList(task("a", "paused"), task("b", "paused"))),
        )

        val result = repository(transport).controlDownloadsResult(
            listOf(
                baseline("b", ResourceState.RUNNING),
                baseline("a", ResourceState.RUNNING),
            ),
            DownloadTaskMutationAction.PAUSE,
        )

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, result.status)
        assertEquals("a,b", transport.requests[1].formFields()["id"])
    }

    @Test
    fun `稳定基线或适用状态漂移时写请求为零`() = runTest {
        val driftTransport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "paused", title = "Changed"))),
        )
        val drift = repository(driftTransport).controlDownloadsResult(
            listOf(baseline("task-1", ResourceState.RUNNING)),
            DownloadTaskMutationAction.PAUSE,
        )
        assertEquals(MutationErrorCategory.CONFLICT, drift.errorCategory)
        assertFalse(drift.submitted)
        assertEquals(listOf("list"), driftTransport.methods())

        val invalidStateTransport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "stopped"))),
        )
        val invalidState = repository(invalidStateTransport).controlDownloadsResult(
            listOf(baseline("task-1", ResourceState.STOPPED)),
            DownloadTaskMutationAction.PAUSE,
        )
        assertEquals(MutationErrorCategory.CONFLICT, invalidState.errorCategory)
        assertFalse(invalidState.submitted)
    }

    @Test
    fun `缺tasks非数组非法ID和重复ID均严格失败且零写入`() = runTest {
        val malformed = listOf(
            "{}",
            """{"tasks":{}}""",
            taskList("""{"title":"Synthetic","status":"downloading"}"""),
            taskList(task("dup", "downloading"), task("dup", "paused")),
        )
        malformed.forEach { data ->
            val transport = DownloadMutationInterceptor(ok(data))
            val result = repository(transport).controlDownloadsResult(
                listOf(baseline("task-1", ResourceState.RUNNING)),
                DownloadTaskMutationAction.PAUSE,
            )
            assertEquals(MutationResultStatus.CONFIRMED_FAILURE, result.status)
            assertFalse(result.submitted)
            assertEquals(MutationErrorCategory.NETWORK, result.errorCategory)
            assertEquals(listOf("list"), transport.methods())
        }
    }

    @Test
    fun `删除提交后的畸形成功列表保持未确认而非删除成功`() = runTest {
        val transport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "downloading"))),
            ok(),
            ok("{}"),
        )

        val result = repository(transport).controlDownloadsResult(
            listOf(baseline("task-1", ResourceState.RUNNING)),
            DownloadTaskMutationAction.REMOVE_TASK,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
    }

    @Test
    fun `提交断线回读不替代逐项回执且不重放`() = runTest {
        val transport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "paused"))),
            fail(IOException("synthetic disconnect")),
            ok(taskList(task("task-1", "downloading"))),
        )

        val result = repository(transport).controlDownloadsResult(
            listOf(baseline("task-1", ResourceState.PAUSED)),
            DownloadTaskMutationAction.RESUME,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(listOf("list", "resume", "list"), transport.methods())
    }

    @Test
    fun `提交断线且严格回读失败时全部保持未知`() = runTest {
        val transport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "paused"))),
            fail(IOException("synthetic submission disconnect")),
            fail(IOException("synthetic readback disconnect")),
        )

        val result = repository(transport).controlDownloadsResult(
            listOf(baseline("task-1", ResourceState.PAUSED)),
            DownloadTaskMutationAction.RESUME,
        )

        assertEquals(MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(1, transport.methods().count { it == "resume" })
    }

    @Test
    fun `权限拒绝也执行严格回读且稳定未变时明确失败`() = runTest {
        val unchanged = taskList(task("task-1", "paused"))
        val transport = DownloadMutationInterceptor(
            ok(unchanged),
            ok("{}", success = false, errorCode = 105),
            *Array(8) { ok(unchanged) },
        )

        val result = repository(transport).controlDownloadsResult(
            listOf(baseline("task-1", ResourceState.PAUSED)),
            DownloadTaskMutationAction.RESUME,
        )

        assertEquals(MutationResultStatus.PERMISSION_DENIED, result.status)
        assertEquals(1, result.counts.failed)
        assertEquals(MutationErrorCategory.PERMISSION, result.errorCategory)
        assertTrue(transport.methods().count { it == "list" } >= 2)
    }

    @Test
    fun `重叠目标并发写被拒绝且首个写只发送一次`() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val transport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "downloading"))),
            block(entered, release, ok()),
            ok(taskList(task("task-1", "paused"))),
        )
        val repo = repository(transport)
        val expected = listOf(baseline("task-1", ResourceState.RUNNING))

        val first = async(Dispatchers.IO) {
            repo.controlDownloadsResult(expected, DownloadTaskMutationAction.PAUSE)
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        val duplicate = repo.controlDownloadsResult(expected, DownloadTaskMutationAction.PAUSE)
        assertEquals(MutationErrorCategory.CONFLICT, duplicate.errorCategory)
        assertFalse(duplicate.submitted)
        release.countDown()
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, first.await().status)
        assertEquals(1, transport.methods().count { it == "pause" })
    }

    @Test
    fun `预检取消结构化返回且锁释放后允许重试`() = runBlocking {
        val entered = CountDownLatch(1)
        val transport = DownloadMutationInterceptor(
            cancelWhenCallCancelled(entered),
            ok(taskList(task("task-1", "downloading"))),
            ok(),
            ok(taskList(task("task-1", "paused"))),
        )
        val repo = repository(transport)
        val expected = listOf(baseline("task-1", ResourceState.RUNNING))
        val captured = AtomicReference<io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult?>()

        val cancelled = launch(Dispatchers.IO) {
            captured.set(repo.controlDownloadsResult(expected, DownloadTaskMutationAction.PAUSE))
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        cancelled.cancel()
        cancelled.join()

        assertEquals(MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, captured.get()?.status)
        assertEquals(0, transport.methods().count { it == "pause" })
        val retried = repo.controlDownloadsResult(expected, DownloadTaskMutationAction.PAUSE)
        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, retried.status)
    }

    @Test
    fun `提交阶段取消仍执行不可取消严格回读且绝不重放`() = runBlocking {
        val entered = CountDownLatch(1)
        val transport = DownloadMutationInterceptor(
            ok(taskList(task("task-1", "downloading"))),
            cancelWhenCallCancelled(entered),
            fail(IOException("synthetic cancelled readback failure")),
        )
        val repo = repository(transport)
        val expected = listOf(baseline("task-1", ResourceState.RUNNING))
        val captured = AtomicReference<io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult?>()

        val cancelled = launch(Dispatchers.IO) {
            captured.set(repo.controlDownloadsResult(expected, DownloadTaskMutationAction.PAUSE))
        }
        assertTrue(entered.await(5, TimeUnit.SECONDS))
        cancelled.cancel()
        cancelled.join()

        val result = checkNotNull(captured.get())
        assertEquals(MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, result.status)
        assertEquals(1, result.counts.unknown)
        assertTrue(result.requiresRefresh)
        assertEquals(listOf("list", "pause", "list"), transport.methods())
        assertEquals(1, transport.methods().count { it == "pause" })
    }

    @Test
    fun `预检失败后锁在不可取消清理路径释放`() = runTest {
        val transport = DownloadMutationInterceptor(
            ok("{}"),
            ok(taskList(task("task-1", "downloading"))),
            ok(),
            ok(taskList(task("task-1", "paused"))),
        )
        val repo = repository(transport)
        val expected = listOf(baseline("task-1", ResourceState.RUNNING))

        val failed = repo.controlDownloadsResult(expected, DownloadTaskMutationAction.PAUSE)
        assertFalse(failed.submitted)
        val retried = repo.controlDownloadsResult(expected, DownloadTaskMutationAction.PAUSE)

        assertEquals(MutationResultStatus.CONFIRMED_SUCCESS, retried.status)
        assertEquals(1, transport.methods().count { it == "pause" })
    }

    @Test
    fun `无正式或降级能力时返回不支持且零请求`() = runTest {
        val result = repository(DownloadMutationInterceptor(), capabilities = emptyMap())
            .controlDownloadsResult(
                listOf(baseline("task-1", ResourceState.RUNNING)),
                DownloadTaskMutationAction.PAUSE,
            )

        assertEquals(MutationResultStatus.UNSUPPORTED, result.status)
        assertFalse(result.submitted)
    }

    private fun repository(
        interceptor: Interceptor,
        capabilities: Map<String, ApiCapability> = mapOf(
            "SYNO.DownloadStation.Task" to ApiCapability(
                "SYNO.DownloadStation.Task",
                "entry.cgi",
                1,
                3,
            ),
            "SYNO.FileStation.List" to ApiCapability(
                "SYNO.FileStation.List",
                "entry.cgi",
                1,
                2,
            ),
        ),
    ) = authorizedRepository(
        NasProfile("test", "Test", "https://nas.example.invalid", "tester"),
        DsmSession("test", "test-session", "test-token"),
        DsmApiClient(OkHttpClient.Builder().addInterceptor(interceptor).build()),
        capabilities,
    )

    private fun baseline(
        id: String,
        status: ResourceState,
        title: String = "Synthetic",
        destination: String? = null,
    ) = DownloadTaskMutationBaseline(
        id = id,
        type = "http",
        title = title,
        status = status,
        size = 10,
        destination = destination,
        createdAtEpochSeconds = null,
    )
}

private sealed interface DownloadReply

private data class DownloadBody(val body: String) : DownloadReply

private data class DownloadFailure(val failure: IOException) : DownloadReply

private data class DownloadBlock(
    val entered: CountDownLatch,
    val release: CountDownLatch,
    val reply: DownloadReply,
) : DownloadReply

private data class DownloadCancelBlock(val entered: CountDownLatch) : DownloadReply

private fun ok(data: String = receipt("task-1"), success: Boolean = true, errorCode: Int? = null): DownloadReply =
    if (success) {
        DownloadBody("""{"success":true,"data":$data}""")
    } else {
        DownloadBody("""{"success":false,"error":{"code":${checkNotNull(errorCode)}}}""")
    }

private fun fail(failure: IOException): DownloadReply = DownloadFailure(failure)

private fun block(
    entered: CountDownLatch,
    release: CountDownLatch,
    reply: DownloadReply,
): DownloadReply = DownloadBlock(entered, release, reply)

private fun cancelWhenCallCancelled(entered: CountDownLatch): DownloadReply =
    DownloadCancelBlock(entered)

private fun taskList(vararg tasks: String): String = """{"tasks":[${tasks.joinToString(",")}]}"""

private fun taskListWithTotal(total: Int, vararg tasks: String): String =
    """{"tasks":[${tasks.joinToString(",")}],"total":$total}"""

private fun task(
    id: String,
    status: String,
    title: String = "Synthetic",
    destination: String? = null,
): String {
    val additional = destination?.let { ",\"additional\":{\"detail\":{\"destination\":\"$it\"}}" }.orEmpty()
    return """{"id":"$id","type":"http","title":"$title","status":"$status","size":10$additional}"""
}

private fun directory(path: String) = FileItem(
    path = path,
    name = path.substringAfterLast('/'),
    isDirectory = true,
    owner = "tester",
    canRead = true,
    canWrite = true,
)

private fun fileInfo(item: FileItem): String =
    """{"files":[{"name":"${item.name}","path":"${item.path}","isdir":true,"size":${item.size},"additional":{"owner":"${item.owner}","perm":{"read":${item.canRead},"write":${item.canWrite},"delete":${item.canDelete}}}}]}"""

private class DownloadMutationInterceptor(vararg replies: DownloadReply) : Interceptor {
    private val pending = ArrayDeque(replies.toList())
    val requests = CopyOnWriteArrayList<Request>()

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        requests += request
        val reply = synchronized(pending) {
            pending.removeFirstOrNull() ?: error("缺少合成下载任务响应")
        }
        return response(request, when (reply) {
            is DownloadBody -> reply
            is DownloadFailure -> throw reply.failure
            is DownloadBlock -> {
                reply.entered.countDown()
                check(reply.release.await(5, TimeUnit.SECONDS)) { "等待释放合成写请求超时" }
                when (val released = reply.reply) {
                    is DownloadBody -> released
                    is DownloadFailure -> throw released.failure
                    is DownloadBlock -> error("不支持嵌套阻塞响应")
                    is DownloadCancelBlock -> error("不支持嵌套取消响应")
                }
            }
            is DownloadCancelBlock -> {
                reply.entered.countDown()
                repeat(500) {
                    if (chain.call().isCanceled()) throw IOException("synthetic cancelled call")
                    Thread.sleep(5)
                }
                error("等待取消合成请求超时")
            }
        })
    }

    fun methods(): List<String?> = requests.map { it.formFields()["method"] }

    private fun response(request: Request, body: DownloadBody): Response = Response.Builder()
        .request(request)
        .protocol(Protocol.HTTP_1_1)
        .code(200)
        .message("OK")
        .body(body.body.toResponseBody("application/json".toMediaType()))
        .build()
}

private fun Request.formFields(): Map<String, String> {
    val form = fixtureBody() as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { form.name(it) to form.value(it) }
}

private fun receipt(vararg ids: String): String =
    """{"_array":[${ids.joinToString(",") { """{"id":"$it","error":0}""" }}]}"""
