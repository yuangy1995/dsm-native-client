package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import org.junit.Assert.*
import org.junit.Test

class ContainerImageStoreTest {
    private val preferences = MemoryPreferences(); private val store = ContainerImageStore(preferences)
    private val owner = WorkspaceOwner("synthetic-profile", "identity", "generation")
    private val image = ContainerImageIdentity(containerDigest("selection"), containerDigest("source"), containerDigest("reference"), false)
    private fun pull() = ContainerImageActivity("pull", owner, ContainerImageOperation.PULL, reference = image.reference, baselineIds = setOf(image.image))
    private fun deletion(target: ContainerImageIdentity = image) = ContainerImageActivity("delete", owner, ContainerImageOperation.DELETE, targets = listOf(target))
    @Test fun `同标签和裸映像跨操作阻止重复无关目标可独立`() {
        store.begin(pull()); assertTrue(runCatching { store.begin(deletion()) }.isFailure)
        val bare = image.copy(selection = containerDigest("bare"), reference = containerDigest("other"), untagged = true)
        assertTrue(runCatching { store.begin(deletion(bare)) }.isFailure)
        store.begin(deletion(image.copy(selection = containerDigest("second"), reference = containerDigest("second"), image = containerDigest("second"))))
        assertEquals(2, store.records(owner).size)
    }
    @Test fun `新会话不能补造回执但可据原任务完成`() {
        store.begin(pull()); store.checkpoint(owner, "pull", ContainerStage.SUBMITTED)
        val fresh = owner.copy(sessionGeneration = "fresh")
        assertTrue(runCatching { store.checkpoint(fresh, "pull", ContainerStage.ACCEPTED, ContainerImageTaskId("synthetic-task", false)) }.isFailure)
        store.checkpoint(owner, "pull", ContainerStage.ACCEPTED, ContainerImageTaskId("synthetic-task", false)); store.checkpoint(fresh, "pull", ContainerStage.VERIFIED)
        assertFalse(store.records(fresh).single().pending)
    }
    @Test fun `部分删除保存结果未知不得清理拒绝不可外部变化覆盖`() {
        val target2 = image.copy(selection = containerDigest("other"), reference = containerDigest("other"))
        store.begin(deletion().copy(targets = listOf(image, target2))); store.checkpoint(owner, "delete", ContainerStage.SUBMITTED)
        store.reviewDelete(owner, "delete", setOf(image.selection)); assertTrue(store.records(owner).single().pending)
        assertTrue(runCatching { store.dismiss(owner, "delete") }.isFailure)
        store.reviewDelete(owner, "delete", setOf(target2.selection)); store.dismiss(owner, "delete")
        store.begin(pull()); store.checkpoint(owner, "pull", ContainerStage.SUBMITTED); store.checkpoint(owner, "pull", ContainerStage.REJECTED)
        assertTrue(runCatching { store.checkpoint(owner, "pull", ContainerStage.VERIFIED) }.isFailure)
    }
    @Test fun `损坏记录不覆盖为新的下载`() {
        preferences.edit().putString("image:broken", "bad-json").commit()
        assertTrue(runCatching { store.records(owner) }.isFailure); assertTrue(runCatching { store.begin(pull()) }.isFailure)
    }
}
