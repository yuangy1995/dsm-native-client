package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class NasObservationModelTest {
    private val fixture = NasObservationProtocolFixture()
    private var repo = fixture.repository()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val model = NasObservationModel(scope, { repo })
    private suspend fun eventually(condition: () -> Boolean) { withTimeout(5_000) { while (!condition()) delay(10) }; delay(20) }
    @org.junit.After fun cleanup() { scope.cancel() }
    @Test fun `翻页失败保持原页重试原目标详情离开即清除`() = runBlocking {
        model.logs(0, 50); eventually { model.state.value.logs != null }; fixture.failingApi = SYSTEM_LOG
        model.logs(50, 50); eventually { model.state.value.logsFailure != null }; assertEquals(0, model.state.value.logs!!.offset)
        fixture.failingApi = null; model.retryLogs(); eventually { model.state.value.logs?.offset == 50 }
        model.inspectLog(model.state.value.logs!!.entries.single()); assertNotNull(model.state.value.selectedLog)
        model.leaveLogs(); assertNull(model.state.value.logs); assertNull(model.state.value.selectedLog)
    }
    @Test fun `切换同配置会话清除正文默认从第一页读取`() = runBlocking {
        model.logs(200, 50); eventually { model.state.value.logs != null }; val old = model.state.value.logs!!.entries.single()
        repo = fixture.repository("next"); model.inspectLog(old); assertNull(model.state.value.logs); assertNull(model.state.value.selectedLog)
        model.logs(); eventually { model.state.value.logs != null }; assertEquals(0, model.state.value.logs!!.offset); assertEquals(100, model.state.value.logs!!.limit)
    }
    @Test fun `日志迟到页不能覆盖新页离开不发布正文`() = runBlocking {
        val entered = java.util.concurrent.CountDownLatch(1); val release = java.util.concurrent.CountDownLatch(1)
        fixture.beforeRead = { if (it.api == SYSTEM_LOG && it.fields["offset"] == "0") { entered.countDown(); check(release.await(5, java.util.concurrent.TimeUnit.SECONDS)) } }
        try {
            model.logs(0, 50); assertTrue(entered.await(5, java.util.concurrent.TimeUnit.SECONDS))
            model.logs(50, 50); eventually { model.state.value.logs?.offset == 50 }; release.countDown(); delay(50)
            assertEquals(50, model.state.value.logs!!.offset); model.leaveLogs(); delay(50); assertNull(model.state.value.logs)
        } finally { release.countDown() }
    }
    @Test fun `进程失败与日志相互独立并清除原连接快照`() = runBlocking {
        model.processes(); eventually { model.state.value.processes != null }; fixture.failingApi = SYSTEM_PROCESS
        model.processes(); model.logs(); eventually { model.state.value.processesFailure != null && model.state.value.logs != null }
        assertNotNull(model.state.value.processes); assertNull(model.state.value.logsFailure)
        model.clear(); assertNull(model.state.value.processes); assertNull(model.state.value.logs)
    }
}
