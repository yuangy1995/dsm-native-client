package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.PersistedPhotoBackupSource
import kotlinx.coroutines.Job
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class AppViewModelTaskOwnershipTest {
    @Test
    fun `后注册的同一传输任务不会被旧任务完成回调移除`() {
        val owner = TransferTaskJobOwner()
        val first = Job()
        val second = Job()
        var firstBeforeRemovalCalls = 0
        var firstAfterRemovalCalls = 0
        var secondBeforeRemovalCalls = 0
        var secondAfterRemovalCalls = 0

        owner.register(
            "transfer",
            first,
            beforeRemoval = { firstBeforeRemovalCalls += 1 },
            afterRemoval = { firstAfterRemovalCalls += 1 },
        )
        owner.register(
            "transfer",
            second,
            beforeRemoval = { secondBeforeRemovalCalls += 1 },
            afterRemoval = { secondAfterRemovalCalls += 1 },
        )
        first.complete()

        assertSame(second, owner.job("transfer"))
        assertEquals(0, firstBeforeRemovalCalls)
        assertEquals(0, firstAfterRemovalCalls)
        second.complete()
        assertNull(owner.job("transfer"))
        assertEquals(1, secondBeforeRemovalCalls)
        assertEquals(1, secondAfterRemovalCalls)
    }

    @Test
    fun `注销传输任务后先移除引用再执行附加清理`() {
        val owner = TransferTaskJobOwner()
        val job = Job()
        var removedBeforeCallback = false

        owner.register("transfer", job, afterRemoval = {
            removedBeforeCallback = owner.job("transfer") == null
        })
        job.complete()

        assertTrue(removedBeforeCallback)
    }

    @Test
    fun `照片扫描只接受当前 profile 和代次的取消`() {
        val owner = PhotoBackupCoordinator()
        val first = Job()
        val firstGeneration = owner.beginObservation("profile-a")
        owner.attachObservation("profile-a", firstGeneration, first)

        assertFalse(owner.cancelObservation("profile-b"))
        assertFalse(owner.cancelObservation("profile-a", firstGeneration + 1))
        assertTrue(owner.isCurrentObservation("profile-a", firstGeneration))

        assertTrue(owner.cancelObservation("profile-a", firstGeneration))
        assertTrue(first.isCancelled)
        assertFalse(owner.isCurrentObservation("profile-a", firstGeneration))
    }

    @Test
    fun `新照片扫描替换旧观察且旧回调不清除新观察`() {
        val owner = PhotoBackupCoordinator()
        val first = Job()
        val firstGeneration = owner.beginObservation("profile-a")
        owner.attachObservation("profile-a", firstGeneration, first)

        val second = Job()
        val secondGeneration = owner.beginObservation("profile-b")
        owner.attachObservation("profile-b", secondGeneration, second)
        first.complete()

        assertTrue(first.isCancelled)
        assertTrue(owner.isCurrentObservation("profile-b", secondGeneration))
        second.complete()
        assertFalse(owner.isCurrentObservation("profile-b", secondGeneration))
    }

    @Test
    fun `照片扫描调度代次保持单调并可识别当前调度`() {
        val owner = PhotoBackupCoordinator()
        val first = owner.nextScheduleGeneration()
        val second = owner.nextScheduleGeneration()

        assertFalse(owner.isCurrentScheduleGeneration(first))
        assertTrue(owner.isCurrentScheduleGeneration(second))
    }

    @Test
    fun `切换 Profile 会失效旧照片调度并取消本地观察但不需要操作后台唯一工作`() {
        val owner = PhotoBackupCoordinator()
        val scheduleGeneration = owner.nextScheduleGeneration()
        val observation = Job()
        val observationGeneration = owner.beginObservation("profile-a")
        owner.attachObservation("profile-a", observationGeneration, observation)

        owner.clearForProfileSwitch()

        assertFalse(owner.isCurrentScheduleGeneration(scheduleGeneration))
        assertFalse(owner.isCurrentObservation("profile-a", observationGeneration))
        assertNull(owner.observationJob())
        assertTrue(observation.isCancelled)
    }

    @Test
    fun `照片调度只接受当前代次和同一 Profile 的来源`() {
        val owner = PhotoBackupCoordinator()
        val expected = PersistedPhotoBackupSource(
            profileId = "profile-a",
            treeUri = "content://synthetic/tree",
            destinationPath = "/photos",
        )
        val generation = owner.nextScheduleGeneration()

        assertTrue(owner.isCurrentSourceSchedule(generation = generation, expected = expected, current = expected))
        assertFalse(
            owner.isCurrentSourceSchedule(
                generation = generation,
                expected = expected,
                current = expected.copy(profileId = "profile-b"),
            ),
        )
        assertFalse(
            owner.isCurrentSourceSchedule(
                generation = generation - 1,
                expected = expected,
                current = expected,
            ),
        )
    }

    @Test
    fun `并发旧传输完成与新任务注册不会清理新所有者或执行回调`() {
        val owner = TransferTaskJobOwner()
        val first = Job()
        val second = Job()
        val start = CountDownLatch(1)
        val replacementRegistered = CountDownLatch(1)
        val ready = CountDownLatch(2)
        val finished = CountDownLatch(2)
        var oldBeforeRemovalCalls = 0
        var oldAfterRemovalCalls = 0

        owner.register(
            "transfer",
            first,
            beforeRemoval = { oldBeforeRemovalCalls += 1 },
            afterRemoval = { oldAfterRemovalCalls += 1 },
        )
        val completionThread = Thread {
            ready.countDown()
            start.await()
            replacementRegistered.await()
            first.complete()
            finished.countDown()
        }
        val replacementThread = Thread {
            ready.countDown()
            start.await()
            owner.register("transfer", second)
            replacementRegistered.countDown()
            finished.countDown()
        }

        completionThread.start()
        replacementThread.start()
        assertTrue(ready.await(5, TimeUnit.SECONDS))
        start.countDown()
        assertTrue(finished.await(5, TimeUnit.SECONDS))

        assertSame(second, owner.job("transfer"))
        assertEquals(0, oldBeforeRemovalCalls)
        assertEquals(0, oldAfterRemovalCalls)
        second.complete()
        assertNull(owner.job("transfer"))
    }

    @Test
    fun `并发旧照片观察完成与新观察注册保留新 profile 代次与 Job`() {
        val owner = PhotoBackupCoordinator()
        val first = Job()
        val firstGeneration = owner.beginObservation("profile-a")
        owner.attachObservation("profile-a", firstGeneration, first)
        val second = Job()
        val start = CountDownLatch(1)
        val replacementRegistered = CountDownLatch(1)
        val ready = CountDownLatch(2)
        val finished = CountDownLatch(2)
        val secondGeneration = AtomicLong()

        val completionThread = Thread {
            ready.countDown()
            start.await()
            replacementRegistered.await()
            first.complete()
            finished.countDown()
        }
        val replacementThread = Thread {
            ready.countDown()
            start.await()
            val generation = owner.beginObservation("profile-b")
            owner.attachObservation("profile-b", generation, second)
            secondGeneration.set(generation)
            replacementRegistered.countDown()
            finished.countDown()
        }

        completionThread.start()
        replacementThread.start()
        assertTrue(ready.await(5, TimeUnit.SECONDS))
        start.countDown()
        assertTrue(finished.await(5, TimeUnit.SECONDS))

        assertTrue(first.isCancelled)
        assertTrue(owner.isCurrentObservation("profile-b", secondGeneration.get()))
        assertSame(second, owner.observationJob())
        second.complete()
        assertFalse(owner.isCurrentObservation("profile-b", secondGeneration.get()))
        assertNull(owner.observationJob())
    }

    @Test
    fun `传输协调器替换前台下载时旧完成回调不能删除新 execution`() {
        val coordinator = TransferCoordinator()
        val first = Job()
        val firstExecution = coordinator.beginForegroundDownload("transfer")
        coordinator.registerForegroundTask(
            "transfer",
            first,
            afterRemoval = {
                coordinator.clearForegroundDownloadExecution("transfer", firstExecution)
            },
        )

        val second = Job()
        val secondExecution = coordinator.beginForegroundDownload("transfer")
        coordinator.registerForegroundTask(
            "transfer",
            second,
            afterRemoval = {
                coordinator.clearForegroundDownloadExecution("transfer", secondExecution)
            },
        )
        first.complete()

        assertSame(second, coordinator.foregroundTask("transfer"))
        assertTrue(coordinator.isCurrentForegroundDownloadExecution("transfer", secondExecution))
        assertEquals(secondExecution, coordinator.currentForegroundDownloadExecution("transfer"))

        second.complete()
        assertNull(coordinator.foregroundTask("transfer"))
        assertNull(coordinator.currentForegroundDownloadExecution("transfer"))
    }

    @Test
    fun `传输协调器替换后台观察时旧观察不能移除新观察`() {
        val coordinator = TransferCoordinator()
        val first = Job()
        val second = Job()

        coordinator.replaceWorkObservation("transfer", first)
        coordinator.replaceWorkObservation("transfer", second)

        assertTrue(first.isCancelled)
        assertFalse(coordinator.removeWorkObservation("transfer", first))
        assertSame(second, coordinator.currentWorkObservation("transfer"))
        assertTrue(coordinator.removeWorkObservation("transfer", second))
        assertNull(coordinator.currentWorkObservation("transfer"))
    }

    @Test
    fun `传输协调器切换 Profile 时丢弃旧引用并停止后台观察`() {
        val coordinator = TransferCoordinator()
        val foreground = Job()
        val observer = Job()
        coordinator.beginForegroundDownload("transfer")
        coordinator.registerForegroundTask("transfer", foreground)
        coordinator.replaceWorkObservation("transfer", observer)

        coordinator.clearForProfileSwitch()

        assertNull(coordinator.foregroundTask("transfer"))
        assertNull(coordinator.currentForegroundDownloadExecution("transfer"))
        assertNull(coordinator.currentWorkObservation("transfer"))
        assertTrue(observer.isCancelled)
        assertFalse(foreground.isCancelled)
    }
}
