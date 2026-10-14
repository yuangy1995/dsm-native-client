package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import java.util.UUID
import org.junit.Assert.*
import org.junit.Test

class VmmCreationStoreTest {
    private val preferences = MemoryPreferences(); private val store = VmmCreationStore(preferences)
    private val owner = WorkspaceOwner("profile", "identity", "generation")
    private fun record(preset: VmmCreationPreset = VmmCreationPreset.GENERAL, name: String = "Synthetic created", power: Boolean = false): VmmCreationActivity {
        val internal = preset != VmmCreationPreset.GENERAL
        val plan = VmmCreationPlan(preset, VmmConfiguration(name, "", 1, 512, if (internal) 256 else null, 0),
            VmmCreationStorage(VmmCreationRef("storage", "Synthetic storage"), "host", "Synthetic host"), listOf(VmmCreationDisk(10)), listOf(null), powerOn = power)
        return VmmCreationActivity(owner, VmmCreationSnapshot(UUID.randomUUID().toString(), plan, setOf(vmmDigest("existing")), vmmDigest("parameters"), if (internal) vmmDigest("expected") else null))
    }
    private fun advance(record: VmmCreationActivity, vararg stages: VmmCreationStage): VmmCreationProgress {
        var value = store.records(owner).single { it.id == record.id }.progress
        for (stage in stages) {
            value = when (stage) {
                VmmCreationStage.CREATING -> value.copy(stage = stage, task = "task")
                VmmCreationStage.CREATED -> value.copy(stage = stage, guest = "new-guest", hardware = vmmDigest("hardware"), baseline = record.snapshot.plan.configuration.copy(memoryMiB = 256))
                else -> value.copy(stage = stage)
            }
            store.checkpoint(owner, record.id, value)
        }
        return value
    }
    @Test fun `完整阶段保存独立创建设置开机回执且记录可删除`() {
        val record = record(power = true); store.begin(record)
        advance(record, VmmCreationStage.CREATE_SENT, VmmCreationStage.CREATING, VmmCreationStage.CREATED, VmmCreationStage.CONFIGURE_SENT,
            VmmCreationStage.CONFIGURING, VmmCreationStage.CONFIGURED, VmmCreationStage.POWER_SENT, VmmCreationStage.STARTING, VmmCreationStage.COMPLETE)
        assertFalse(store.records(owner).single().pending); store.dismiss(owner, record.id); assertTrue(preferences.all.isEmpty())
    }
    @Test fun `跳过接受阶段不能完成未知不能关闭`() {
        val record = record(); store.begin(record)
        val sent = advance(record, VmmCreationStage.CREATE_SENT)
        assertTrue(runCatching { store.checkpoint(owner, record.id, sent.copy(stage = VmmCreationStage.COMPLETE)) }.isFailure)
        assertTrue(runCatching { store.dismiss(owner, record.id) }.isFailure)
        val settings = advance(record, VmmCreationStage.CREATING, VmmCreationStage.CREATED, VmmCreationStage.CONFIGURE_SENT)
        assertTrue(runCatching { store.checkpoint(owner, record.id, settings.copy(stage = VmmCreationStage.CONFIGURED)) }.isFailure)
    }
    @Test fun `新会话不能伪补公开回执但可显式继续从未发送步骤`() {
        val record = record(); store.begin(record); val sent = advance(record, VmmCreationStage.CREATE_SENT)
        val renewed = owner.copy(sessionGeneration = "renewed")
        assertTrue(runCatching { store.checkpoint(renewed, record.id, sent.copy(stage = VmmCreationStage.CREATING, task = "task")) }.isFailure)
        val created = advance(record, VmmCreationStage.CREATING, VmmCreationStage.CREATED)
        store.checkpoint(renewed, record.id, created.copy(stage = VmmCreationStage.CONFIGURE_SENT))
        assertTrue(runCatching { store.checkpoint(owner, record.id, created.copy(stage = VmmCreationStage.CONFIGURING)) }.isFailure)
        store.checkpoint(renewed, record.id, created.copy(stage = VmmCreationStage.CONFIGURING))
        assertEquals(VmmCreationStage.CONFIGURING, store.records(renewed).single().progress.stage)
        assertTrue(store.records(owner.copy(identityRevision = "other")).isEmpty())
    }
    @Test fun `内部精确关联回执可跨会话保存原任务身份不可替换`() {
        val record = record(VmmCreationPreset.LINUX); store.begin(record); val sent = advance(record, VmmCreationStage.CREATE_SENT)
        val renewed = owner.copy(sessionGeneration = "renewed")
        val accepted = sent.copy(stage = VmmCreationStage.CREATING, task = "original")
        store.checkpoint(renewed, record.id, accepted)
        assertTrue(runCatching { store.checkpoint(renewed, record.id, accepted.copy(task = "other")) }.isFailure)
    }
    @Test fun `名称不区分大小写保护且其他名称可创建`() {
        val record = record(); store.begin(record)
        assertTrue(runCatching { store.begin(record(name = record.snapshot.plan.configuration.name.uppercase())) }.isFailure)
        store.begin(record(name = "Another synthetic VM")); assertEquals(2, store.records(owner).size)
    }
    @Test fun `落盘失败和损坏文件不会悄悄跳过已有保护`() {
        preferences.commitSucceeds = false; assertTrue(runCatching { store.begin(record()) }.isFailure)
        preferences.commitSucceeds = true; assertTrue(runCatching { store.records(owner) }.isFailure)
        preferences.edit().putString("creation:broken", "{}").commit()
        assertTrue(runCatching { VmmCreationStore(preferences).records(owner) }.isFailure)
    }
    @Test fun `回滚与移除连接只清理本连接且不记录旧VM明文和凭据`() {
        val record = record(); store.begin(record)
        val otherOwner = owner.copy(profileId = "other")
        store.begin(record().copy(owner = otherOwner))
        val saved = preferences.all.values.joinToString()
        assertFalse(saved.contains("\"existing\"")); assertFalse(saved.contains("SynoToken")); assertFalse(saved.contains("synthetic-sid"))
        store.removeProfile(owner.profileId); assertTrue(store.records(owner).isEmpty()); assertEquals(1, store.records(otherOwner).size)
    }
}
