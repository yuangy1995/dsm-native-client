package io.github.qwertyuiop1995.dsmnativeclient.background

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class WorkspaceExecutionRegistryTest {
    @Test fun `取消只影响本次执行旧通知与进度不能触碰新任务`() {
        val registry = WorkspaceExecutionRegistry()
        val old = WorkspaceExecutionEntry(activity = WorkspaceExecutionActivity.PHOTO_UPLOAD, route = "opaque", caller = Job())
        val next = WorkspaceExecutionEntry(activity = WorkspaceExecutionActivity.PHOTO_UPLOAD, route = "opaque", caller = Job())
        registry.add(old); registry.add(next); registry.started(old.id)
        assertTrue(old.ready.isCompleted); assertFalse(next.ready.isCompleted)
        registry.cancel(old.id); assertTrue(old.caller.isCancelled); assertFalse(next.caller.isCancelled)
        registry.finish(old.id); registry.update(old.id, 500, 500); registry.cancel(old.id)
        assertEquals(listOf(next), registry.entries.value); assertFalse(next.caller.isCancelled)
        registry.cancel(next.id); registry.finish(next.id); assertTrue(registry.entries.value.isEmpty())
    }
    @Test fun `系统启动拒绝不执行调用方业务就移除租约且冷启动为空`() = runBlocking {
        val registry = WorkspaceExecutionRegistry()
        val row = WorkspaceExecutionEntry(activity = WorkspaceExecutionActivity.OFFICE_SAVE, route = "opaque", caller = Job())
        registry.add(row); registry.failed(row.id, unavailableExecution())
        assertTrue(runCatching { row.ready.await() }.isFailure); assertTrue(registry.entries.value.isEmpty())
        assertTrue(WorkspaceExecutionRegistry().entries.value.isEmpty())
    }
}
