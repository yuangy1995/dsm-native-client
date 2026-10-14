package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class PackageActivityStoreTest {
    private val preferences = MemoryPreferences()
    private val store = PackageActivityStore(preferences)
    private val owner = WorkspaceOwner("synthetic", "identity", "session")
    private val entry = NasPackageEntry("Synthetic", "Synthetic", "2", installedVersion = "1")
    private fun record(id: String = "record", items: List<PackageActivityItem> = listOf(PackageActivityItem(entry.packageId, "1", "2"))) = PackageActivityRecord(id, owner, PackageActivityKind.INSTALL, items)
    private fun event(stage: NasPackageWriteStage, step: NasPackageWriteStep = NasPackageWriteStep.INSTALL) = NasPackageCheckpoint("record", step, stage, entry)
    @Test fun `重登录可读但账号与NAS隔离`() {
        store.begin(record()); store.checkpoint(owner, event(NasPackageWriteStage.WILL_SUBMIT)); store.checkpoint(owner, event(NasPackageWriteStage.ACCEPTED))
        assertTrue(PackageActivityStore(preferences).records(owner.copy(sessionGeneration = "next")).single().items.single().accepted)
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty()); assertTrue(store.records(owner.copy(profileId = "other")).isEmpty())
    }
    @Test fun `提交未知不能删改目标或再次提交`() {
        store.begin(record()); store.checkpoint(owner, event(NasPackageWriteStage.WILL_SUBMIT))
        rejected { store.discard(owner, "record") }
        rejected { store.checkpoint(owner, event(NasPackageWriteStage.WILL_SUBMIT)) }
        rejected { store.checkpoint(owner, event(NasPackageWriteStage.ACCEPTED).copy(entry = entry.copy(packageId = "other"))) }
        rejected { store.begin(record("second")) }
    }
    @Test fun `恢复只结算已提交项且未发依赖终止`() {
        store.begin(record(items = listOf(PackageActivityItem("Synthetic", "1", "2"), PackageActivityItem("Dependency", null, "2"))))
        store.checkpoint(owner, event(NasPackageWriteStage.WILL_SUBMIT).copy(total = 2))
        store.completeRecovered(owner, "record", setOf(0))
        assertEquals(listOf(PackageActivityPhase.COMPLETED, PackageActivityPhase.CANCELLED), store.get(owner, "record").items.map { it.phase })
        store.discard(owner, "record"); assertTrue(store.records(owner).isEmpty())
    }
    @Test fun `纯准备恢复标为中断而非安装成功但正式提交不得清空`() {
        store.begin(record()); store.checkpoint(owner, event(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStep.DOWNLOAD))
        store.interruptPreparation(owner, "record"); assertEquals(PackageActivityPhase.INTERRUPTED, store.get(owner, "record").items.single().phase)
        store.discard(owner, "record"); store.begin(record()); store.checkpoint(owner, event(NasPackageWriteStage.WILL_SUBMIT))
        store.interruptPreparation(owner, "record"); assertFalse(store.get(owner, "record").terminal)
    }
    @Test fun `取消下载完成后清理检查点可以安全结算取消`() {
        store.begin(record()); store.checkpoint(owner, event(NasPackageWriteStage.WILL_SUBMIT, NasPackageWriteStep.DOWNLOAD))
        store.checkpoint(owner, event(NasPackageWriteStage.ACCEPTED, NasPackageWriteStep.DOWNLOAD))
        for (step in listOf(NasPackageWriteStep.CANCEL_DOWNLOAD, NasPackageWriteStep.CLEANUP)) {
            store.checkpoint(owner, event(NasPackageWriteStage.WILL_SUBMIT, step)); store.checkpoint(owner, event(NasPackageWriteStage.ACCEPTED, step))
        }
        store.checkpoint(owner, event(NasPackageWriteStage.VERIFIED, NasPackageWriteStep.CLEANUP))
        store.checkpoint(owner, event(NasPackageWriteStage.VERIFIED, NasPackageWriteStep.CANCEL_DOWNLOAD))
        assertTrue(store.get(owner, "record").terminal)
    }
    @Test fun `损坏和保存失败保留证据关闭后续写入`() {
        preferences.edit().putString("package:bad", "{broken").commit()
        rejected { store.records(owner) }; rejected { store.begin(record()) }; assertEquals("{broken", preferences.getString("package:bad", null))
        preferences.edit().clear().commit(); preferences.commitSucceeds = false
        rejected { store.begin(record()) }; preferences.commitSucceeds = true; rejected { store.records(owner) }
    }
    @Test fun `跨实例互斥且活跃账号不得删除`() = runBlocking {
        store.begin(record())
        store.execute(owner) {
            rejected { store.removeProfile(owner.profileId) }
            try { PackageActivityStore(preferences).execute(owner) { fail() }; fail() } catch (_: DsmFailure) { }
        }
        store.removeProfile(owner.profileId); assertTrue(store.records(owner).isEmpty())
    }
    @Test fun `来源与设置记录只持有摘要`() {
        val secret = "https://example.invalid/private-source"
        store.begin(PackageActivityRecord("source", owner, PackageActivityKind.SOURCE, listOf(PackageActivityItem()),
            expectedDigest = sourceDigest(NasPackageSource("Synthetic", secret)), sourceAddressDigest = packageDigest(secret)))
        assertFalse(preferences.all.values.joinToString().contains(secret))
    }
    @Test fun `控制记录动作阶段和会话不可调换恢复只允许已提交项`() {
        val item = PackageActivityItem("Synthetic", "1", "1", step = NasPackageWriteStep.START.name)
        store.begin(PackageActivityRecord("control", owner, PackageActivityKind.CONTROL, listOf(item), packageDigest("synthetic-install")))
        val checkpoint = NasPackageCheckpoint("control", NasPackageWriteStep.START, NasPackageWriteStage.WILL_SUBMIT)
        rejected { store.checkpoint(owner, checkpoint.copy(step = NasPackageWriteStep.STOP)) }
        rejected { store.checkpoint(owner.copy(sessionGeneration = "next"), checkpoint) }
        rejected { store.checkpoint(owner, checkpoint.copy(stage = NasPackageWriteStage.ACCEPTED)) }
        store.checkpoint(owner, checkpoint)
        rejected { store.checkpoint(owner, checkpoint) }
        rejected { store.checkpoint(owner, checkpoint.copy(stage = NasPackageWriteStage.NOT_SUBMITTED)) }
        store.completeRecovered(owner.copy(sessionGeneration = "next"), "control", setOf(0))
        assertTrue(store.get(owner, "control").terminal)
        rejected { store.checkpoint(owner, checkpoint.copy(stage = NasPackageWriteStage.ACCEPTED)) }
    }
    @Test fun `已记住的控制记录消失不能被当成空活动解除保护`() {
        store.begin(PackageActivityRecord("control", owner, PackageActivityKind.CONTROL,
            listOf(PackageActivityItem("Synthetic", "1", "1", step = "UNINSTALL")), packageDigest("synthetic-install")))
        preferences.edit().clear().commit()
        rejected { store.records(owner) }
        rejected { store.begin(record()) }
    }
    private fun rejected(block: () -> Any?) { try { block(); fail() } catch (_: DsmFailure) { } }
}
