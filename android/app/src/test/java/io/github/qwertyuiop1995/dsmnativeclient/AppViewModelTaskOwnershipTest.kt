package io.github.qwertyuiop1995.dsmnativeclient

import kotlinx.coroutines.Job
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

        owner.register("transfer", first)
        owner.register("transfer", second)
        first.complete()

        assertSame(second, owner.job("transfer"))
        second.complete()
        assertNull(owner.job("transfer"))
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
        val owner = PhotoBackupScanObservationOwner()
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
        val owner = PhotoBackupScanObservationOwner()
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
        val owner = PhotoBackupScanObservationOwner()
        val first = owner.nextScheduleGeneration()
        val second = owner.nextScheduleGeneration()

        assertFalse(owner.isCurrentScheduleGeneration(first))
        assertTrue(owner.isCurrentScheduleGeneration(second))
    }
}
