package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import io.github.qwertyuiop1995.dsmnativeclient.testing.MemoryPreferences
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.*
import org.junit.Assert.*
import org.junit.rules.TemporaryFolder
import java.util.UUID

class SystemDocumentRuntimeTest {
    @get:Rule val temporary = TemporaryFolder()
    private val preferences = MemoryPreferences()
    private val store = SystemDocumentStore(preferences)
    private val profiles = SecureProfileStore(MemoryPreferences())
    private val fixture = SystemFileFixture()
    private lateinit var owner: WorkspaceOwner
    private lateinit var location: SystemFileLocation
    private lateinit var repo: DsmRepository
    private lateinit var runtime: SystemDocumentRuntime
    private lateinit var office: OfficeDocumentStore
    @Before fun prepare() {
        owner = profiles.commitConnection(profiles.connectionAttempt(fixture.profile.id), fixture.profile, fixture.session, null, false, persistSession = true)
        repo = fixture.repository(owner) { profiles.requireCurrentOwner(owner) }
        office = OfficeDocumentStore(MemoryPreferences(), java.io.File(temporary.root, "office-copies"))
        runtime = SystemDocumentRuntime(store, profiles, { repo }, office)
        location = store.enable(owner); profiles.bindRecord(WorkspaceRecordKind.DOCUMENT_PROVIDER, location.id, owner)
        fixture.entries["/share/file.txt"] = SystemFileFixture.item("/share/file.txt")
    }
    private suspend fun refused(block: suspend () -> Unit) {
        try { block(); fail("Expected refusal") } catch (_: Exception) { }
    }
    @Test fun `根查询不请求NAS编号冷启动稳定且不含路径`() = runBlocking {
        assertEquals(fixture.profile, runtime.roots().single().second); assertTrue(fixture.calls.isEmpty())
        val share = runtime.children(location.id).single().reference
        assertEquals("/share", share.path); assertFalse(share.id.contains("share"))
        val cold = SystemDocumentStore(preferences)
        assertEquals(share, cold.document(location, "/share", true)); assertEquals(share, cold.document(share.id))
        assertEquals(location, cold.enable(owner.copy(sessionGeneration = UUID.randomUUID().toString())))
    }
    @Test fun `系统路径从指定根或父目录开始且拒绝跨树和失效身份`() = runBlocking {
        val child = store.document(location, "/share/file.txt", false)
        val (root, path) = runtime.path(null, child.id)
        assertEquals(location.id, root); assertEquals(listOf("", "/share", "/share/file.txt"), path.map { store.document(it).path })
        val parent = store.document(location, "/share", true)
        assertEquals(null to listOf(parent.id, child.id), runtime.path(parent.id, child.id))
        assertEquals(location.id to listOf(location.id), runtime.path(null, location.id))
        val sibling = store.document(location, "/share/folder", true)
        refused { runtime.path(sibling.id, child.id) }
        val other = store.enable(owner.copy(identityRevision = "other")); val otherRoot = store.document(other.id)
        refused { runtime.path(otherRoot.id, child.id) }
        profiles.signOut(owner); refused { runtime.path(null, child.id) }
    }
    @Test fun `目录读取完整多页且只返回直接子项`() = runBlocking {
        val share = runtime.children(location.id).single().reference
        for (i in 0..105) fixture.entries["/share/item$i.txt"] = SystemFileFixture.item("/share/item$i.txt")
        val children = runtime.children(share.id)
        assertEquals(108, children.size); assertEquals(108, children.map { it.reference.id }.toSet().size)
        assertEquals(listOf("0", "100"), fixture.calls.filter { it["method"] == "list" }.map { it["offset"] })
        assertTrue(children.all { it.reference.path.substringBeforeLast('/') == "/share" })
    }
    @Test fun `下载是可寻址完整副本实际读取后再比较远端元数据`() = runBlocking {
        val document = store.document(location, "/share/file.txt", false)
        val file = runtime.download(document.id, temporary.root)
        assertEquals("abc", file.readText()); assertEquals(1, fixture.calls.count { it["api"] == "SYNO.FileStation.Download" })
        assertEquals(2, fixture.calls.count { it["method"] == "getinfo" })
    }
    @Test fun `长度或远端版本变化拒绝返回并清除部分副本`() = runBlocking {
        val doc = store.document(location, "/share/file.txt", false)
        fixture.downloadBytes = "abcd".toByteArray(); refused { runtime.download(doc.id, temporary.root) }
        assertTrue(temporary.root.listFiles().isNullOrEmpty())
        fixture.downloadBytes = "abc".toByteArray(); fixture.before = { call -> if (call["api"] == "SYNO.FileStation.Download") {
            val previous = fixture.entries.getValue("/share/file.txt")
            fixture.entries["/share/file.txt"] = JsonObject(previous + ("additional" to JsonObject(previous.getValue("additional").jsonObject +
                ("time" to buildJsonObject { put("mtime", 101) }))))
        } }
        refused { runtime.download(doc.id, temporary.root) }; assertTrue(temporary.root.listFiles().isNullOrEmpty())
    }
    @Test fun `关闭后旧URI立即拒绝重新启用保留编号但不自动编辑`() = runBlocking {
        val doc = store.document(location, "/share/file.txt", false)
        store.update(location, false); assertTrue(runtime.roots().isEmpty())
        refused { runtime.item(doc.id) }; refused { runtime.download(doc.id, temporary.root) }
        assertTrue(fixture.calls.isEmpty()); val enabled = store.enable(owner)
        assertEquals(location.id, enabled.id); assertFalse(enabled.editing); assertNotNull(runtime.item(doc.id).item)
    }
    @Test fun `中途关闭下载不会交付旧副本`() = runBlocking {
        val doc = store.document(location, "/share/file.txt", false)
        fixture.before = { call -> if (call["api"] == "SYNO.FileStation.Download") store.update(location, false) }
        refused { runtime.download(doc.id, temporary.root) }; assertTrue(temporary.root.listFiles().isNullOrEmpty())
    }
    @Test fun `退出拒绝旧入口同身份重登沿用新会话换身份不能接管`() = runBlocking {
        val doc = store.document(location, "/share/file.txt", false)
        profiles.signOut(owner); assertTrue(runtime.roots().isEmpty()); refused { runtime.item(doc.id) }
        owner = profiles.commitConnection(profiles.connectionAttempt(fixture.profile.id), fixture.profile,
            fixture.session.copy(sid = "synthetic-second"), null, false, persistSession = true)
        repo = fixture.repository(owner) { profiles.requireCurrentOwner(owner) }
        assertNotNull(runtime.item(doc.id).item)
        val changed = fixture.profile.copy(username = "synthetic-other")
        owner = profiles.commitConnection(profiles.connectionAttempt(changed.id), changed, fixture.session, null, false, persistSession = true)
        assertTrue(runtime.roots().isEmpty()); refused { runtime.item(doc.id) }
        assertNotEquals(location.id, store.enable(owner).id)
    }
    @Test fun `模块和对象读取权撤销不能返回内容`() = runBlocking {
        val doc = store.document(location, "/share/file.txt", false)
        fixture.allowed = false; refused { runtime.item(doc.id) }; refused { runtime.download(doc.id, temporary.root) }
        fixture.allowed = true
        val previous = fixture.entries.getValue("/share/file.txt")
        fixture.entries["/share/file.txt"] = JsonObject(previous + ("additional" to JsonObject(previous.getValue("additional").jsonObject +
            ("perm" to buildJsonObject { put("write", true) }))))
        refused { runtime.download(doc.id, temporary.root) }
        assertFalse(fixture.calls.any { it["api"] == "SYNO.FileStation.Download" })
    }
    @Test fun `树范围不能跨账号或相似前缀且伪造ID不能寻址`() {
        val parent = store.document(location, "/share", true)
        val child = store.document(location, "/share/file.txt", false)
        assertTrue(store.descendant(parent, child)); assertFalse(store.descendant(child, parent))
        assertFalse(store.descendant(parent, store.document(location, "/share-other/file.txt", false)))
        val other = store.enable(owner.copy(profileId = "other"))
        assertFalse(store.descendant(parent, store.document(other, "/share/file.txt", false)))
        listOf("/share/file.txt", "../etc", UUID.randomUUID().toString()).forEach {
            try { store.document(it); fail("Expected refusal") } catch (_: Exception) { }
        }
    }
    @Test fun `缺页和损坏索引是失败而不是空目录`() = runBlocking {
        fixture.incomplete = true; refused { runtime.children(location.id) }
        preferences.edit().putString("location:${location.id}", "{}").commit()
        refused { runtime.children(location.id) }; refused { runtime.roots() }
    }
    @Test fun `取消下载清除本次副本`() = runBlocking {
        val doc = store.document(location, "/share/file.txt", false)
        val job = launch(Dispatchers.Default, start = CoroutineStart.LAZY) { runtime.download(doc.id, temporary.root) }
        fixture.before = { if (it["api"] == "SYNO.FileStation.Download") job.cancel() }
        job.start(); job.join(); assertTrue(job.isCancelled); assertTrue(temporary.root.listFiles().isNullOrEmpty())
    }
    @Test fun `只有主动允许且可写的Office才开放编辑`() = runBlocking {
        fixture.entries["/share/document.docx"] = SystemFileFixture.item("/share/document.docx")
        val doc = store.document(location, "/share/document.docx", false)
        assertFalse(runtime.item(doc.id).canEdit); refused { runtime.beginEdit(doc.id) }
        assertTrue(office.records(owner).isEmpty())
        location = store.update(location, true, editing = true)
        assertTrue(runtime.item(doc.id).canEdit)
        val text = store.document(location, "/share/file.txt", false)
        assertFalse(runtime.item(text.id).canEdit); refused { runtime.beginEdit(text.id) }
        fixture.entries["/share/document.docx"] = SystemFileFixture.item("/share/document.docx", writable = false)
        assertFalse(runtime.item(doc.id).canEdit); refused { runtime.beginEdit(doc.id) }
    }
    @Test fun `系统编辑正常关闭后读取本机新内容但不上传NAS`() = runBlocking {
        fixture.entries["/share/document.docx"] = SystemFileFixture.item("/share/document.docx")
        location = store.update(location, true, editing = true)
        val doc = store.document(location, "/share/document.docx", false)
        val edit = runtime.beginEdit(doc.id); edit.file.writeText("edited-document")
        assertFalse(runtime.item(doc.id).canEdit)
        val received = runtime.closeEdit(edit, true)
        assertEquals(OfficeDocumentPhase.CHANGED, received.phase)
        val item = runtime.item(doc.id); assertTrue(item.canEdit); assertTrue(item.hasLocalEdits); assertEquals(15L, item.item!!.size)
        assertEquals("edited-document", runtime.download(doc.id, temporary.root).readText())
        assertFalse(fixture.calls.any { it["api"] == "SYNO.FileStation.Upload" })
    }
    @Test fun `关闭位置不丢掉已开放的本机编辑且旧入口不继续读取`() = runBlocking {
        fixture.entries["/share/document.docx"] = SystemFileFixture.item("/share/document.docx")
        location = store.update(location, true, editing = true)
        val doc = store.document(location, "/share/document.docx", false)
        val edit = runtime.beginEdit(doc.id); edit.file.writeText("edited-document")
        store.update(location, false)
        val received = runtime.closeEdit(edit, true)
        assertEquals("edited-document", office.artifact(received.id, received.localId).readText())
        refused { runtime.download(doc.id, temporary.root) }; assertFalse(fixture.calls.any { it["api"] == "SYNO.FileStation.Upload" })
    }
    @Test fun `下载完成前模块撤权不能返回已接收的文件`() = runBlocking {
        val doc = store.document(location, "/share/file.txt", false)
        fixture.before = { if (it["api"] == "SYNO.FileStation.Download") fixture.allowed = false }
        refused { runtime.download(doc.id, temporary.root) }; assertTrue(temporary.root.listFiles().isNullOrEmpty())
    }
}
