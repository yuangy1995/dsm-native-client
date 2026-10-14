package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class NasPackagePipelineBoundaryTest {
    private enum class Action { START, CONFIGURE, CANCEL, NEXT }
    private suspend fun exercise(action: Action, cancelled: Boolean) {
        val fixture = NasPackageFixture()
        if (action in setOf(Action.CONFIGURE, Action.CANCEL)) fixture.quick = false
        if (action == Action.CANCEL) fixture.finished = false
        if (action == Action.NEXT) fixture.queue = listOf("Dependency", "Synthetic")
        val repository = NasPackageRepository(fixture)
        val events = mutableListOf<NasPackageCheckpoint>()
        val observer: NasPackageObserver = { events += it }
        val plan = repository.prepare(listOf("Synthetic:stable"))
        val progress = if (action != Action.START) repository.start(plan.id, emptyMap(), true, observer) else null
        if (action == Action.CONFIGURE) repository.advance(requireNotNull(progress).id)
        val before = fixture.writes.size
        events.clear()
        fixture.intercept = { if (it.write) {
            if (cancelled) throw CancellationException("synthetic after send") else throw IOException("synthetic receipt lost")
        } else null }
        val failure = runCatching {
            when (action) {
                Action.START -> repository.start(plan.id, emptyMap(), true, observer)
                Action.CONFIGURE -> repository.configure(requireNotNull(progress).id, "/volume1", true, false, emptyMap())
                Action.CANCEL -> repository.cancel(requireNotNull(progress).id)
                Action.NEXT -> repository.advance(requireNotNull(progress).id)
            }
        }.exceptionOrNull()
        if (cancelled) assertTrue(failure is CancellationException) else assertNull(failure)
        assertEquals(before + 1, fixture.writes.size)
        assertEquals(NasPackageWriteStage.WILL_SUBMIT, events.last().stage)
        assertEquals(NasPackageInstallPhase.UNKNOWN, repository.job!!.phase)
        val submitted = events.last()
        assertEquals(1, events.count { it.index == submitted.index && it.stage == NasPackageWriteStage.WILL_SUBMIT })
        fixture.intercept = null
        repeat(2) { repository.advance(repository.job!!.id) }
        if (action == Action.CANCEL) repository.cancel(repository.job!!.id)
        assertEquals(before + 1, fixture.writes.size)
        assertFalse(events.any { it.index == submitted.index && it.stage in setOf(NasPackageWriteStage.ACCEPTED, NasPackageWriteStage.REJECTED, NasPackageWriteStage.VERIFIED) })
    }

    @Test fun `安装配置取消与下一依赖发送中取消均保留检查点且刷新不重放`() = runBlocking {
        for (action in Action.entries) exercise(action, cancelled = true)
    }
    @Test fun `安装配置取消与下一依赖丢回执均保留未知且刷新不重放`() = runBlocking {
        for (action in Action.entries) exercise(action, cancelled = false)
    }
}
