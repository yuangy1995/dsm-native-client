package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

/** 全部媒体、编号与响应均为合成资料；覆盖提交边界和契约，不代表真实 NAS 已验证。 */
class SynologyPhotosUploadRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, String>, val version: Int)
    private class Fixture(val capabilities: Map<String, ApiCapability> = capabilities()) {
        var home = true
        var userId = 41L
        var shared = "management"
        var rights = "\"view\":true,\"upload\":true,\"manage\":true"
        var folderId = 9L
        var itemFolder = 9L
        var itemSize = 4L
        var provider = 41L
        var albumOwner = 41L
        var albumType = "normal"
        var frozen = false
        var contributor = true
        var defaultPolicy = "rename"
        var uploadReply = """{"id":91,"action":"add"}"""
        var folderReply = """{"folder":{"id":19}}"""
        val calls = mutableListOf<Call>()
        val uploads = mutableListOf<Call>()
        var beforeCall: suspend (Call) -> Unit = {}
        var beforeUpload: suspend () -> Unit = {}
        val repository = SynologyPhotosRepository("profile-a", capabilities, { cap, method, fields ->
            val call = Call(cap.name, method, fields, cap.maxVersion)
            calls += call
            beforeCall(call)
            when {
                cap.name.endsWith("UserInfo") -> obj("""{"enabled":true,"id":$userId}""")
                cap.name.endsWith("Setting.User") -> obj("""{"enable_home_service":$home,"team_space_permission":"$shared","upload_default_action":"$defaultPolicy"}""")
                cap.name.endsWith("Setting.Admin") -> obj("""{"package_version":"synthetic"}""")
                cap.name.endsWith("Setting.TeamSpace") -> obj("""{"enabled":true}""")
                cap.name.endsWith("Browse.Folder") && method == "create" -> obj(folderReply)
                cap.name.endsWith("Browse.Folder") -> {
                    val id = fields["id"]?.toLongOrNull() ?: folderId
                    obj("""{"folder":{"id":$id,"parent":9,"name":"/Imported","additional":{"access_permission":{$rights}}}}""")
                }
                cap.name.endsWith("Browse.Album") -> obj("""{"list":[{"id":71,"name":"Synthetic","owner_user_id":$albumOwner,"type":"$albumType","freeze_album":$frozen,"additional":{"sharing_info":{"passphrase":"synthetic-passphrase"}}}]}""")
                cap.name.endsWith("Sharing.Passphrase") -> obj("""{"permission":{"download":false,"upload":$contributor}}""")
                cap.name.endsWith("Browse.Item") -> obj("""{"list":[{"id":91,"filename":"synthetic.jpg","filesize":$itemSize,"folder_id":$itemFolder,"owner_user_id":42,"additional":{"provider_user_id":$provider}}]}""")
                cap.name.endsWith("Browse.NormalAlbum") -> obj("""{"list":[{"id":71,"name":"Synthetic","type":"normal"}]}""")
                else -> error("Unexpected synthetic call")
            }
        }, uploadTransport = { cap, method, fields, source, progress ->
            uploads += Call(cap.name, method, fields, cap.maxVersion)
            beforeUpload()
            val bytes = source.openInputStream().use { it.readBytes() }
            source.onContentRead(UploadContentFingerprint(bytes.size.toLong(), digest(bytes)))
            progress(bytes.size.toLong(), source.contentLength)
            obj(uploadReply)
        })
        suspend fun ready(): Fixture { repository.access(); calls.clear(); return this }
    }

    @Test fun `个人时间线上传使用JSON业务字段并以编号回读完成`() = runBlocking {
        val f = Fixture().ready()
        withMedia { file, row ->
            val states = mutableListOf<SynologyPhotoUploadPhase>()
            val progress = mutableListOf<Long>()
            f.beforeUpload = { assertEquals(SynologyPhotoUploadPhase.SUBMITTING, states.last()) }
            val result = f.repository.performPhotoUpload(row, file, { states += it.phase }, { done, _ -> progress += done })
            assertEquals(SynologyPhotoUploadPhase.COMPLETED, result.phase)
            assertEquals(listOf(SynologyPhotoUploadPhase.SUBMITTING, SynologyPhotoUploadPhase.PENDING, SynologyPhotoUploadPhase.COMPLETED), states)
            assertEquals(listOf(4L), progress)
            val sent = f.uploads.single()
            assertEquals("SYNO.Foto.Upload.Item", sent.api)
            assertEquals("upload", sent.method)
            assertEquals(1, sent.version)
            assertEquals(mapOf("name" to "\"synthetic.jpg\"", "duplicate" to "\"rename\"", "mtime" to "1000",
                "folder" to "[\"PhotoLibrary\"]", "uploadDestination" to "\"timeline\""), sent.fields)
            val read = f.calls.last()
            assertEquals(5, read.version); assertEquals("[91]", read.fields["id"])
            assertEquals("SYNO.Foto.Browse.Item", read.api)
        }
    }

    @Test fun `共享entry只按共享目录upload权限上传且固定目标`() = runBlocking {
        val f = Fixture().apply { shared = "entry"; rights = "\"view\":true,\"upload\":true,\"manage\":false" }.ready()
        withMedia(SynologyPhotoUploadTarget.Folder(SynologyPhotoSpace.SHARED, 9)) { file, row ->
            val result = f.repository.performPhotoUpload(row, file, {})
            assertEquals(SynologyPhotoUploadPhase.COMPLETED, result.phase)
            val sent = f.uploads.single()
            assertEquals("SYNO.FotoTeam.Upload.Item", sent.api)
            assertEquals("upload_to_folder", sent.method)
            assertEquals("9", sent.fields["target_folder_id"])
            assertFalse(sent.fields.containsKey("folder")); assertFalse(sent.fields.containsKey("uploadDestination"))
            assertEquals("SYNO.FotoTeam.Browse.Item", f.calls.last().api)
        }
    }

    @Test fun `共享管理身份不扩大个人权限且entry需要view`() = runBlocking {
        for ((space, role, rights) in listOf(
            Triple(SynologyPhotoSpace.PERSONAL, "management", "\"view\":true,\"upload\":true"),
            Triple(SynologyPhotoSpace.SHARED, "entry", "\"view\":false,\"upload\":true"),
            Triple(SynologyPhotoSpace.SHARED, "entry", "\"view\":true,\"upload\":false"),
        )) {
            val f = Fixture().apply { shared = role; this.rights = rights }.ready()
            withMedia(SynologyPhotoUploadTarget.Folder(space, 9)) { file, row ->
                failure { f.repository.performPhotoUpload(row, file, {}) }
                assertTrue(f.uploads.isEmpty())
            }
        }
    }

    @Test fun `相册所有者直接上传只传album_id且不重复加入`() = runBlocking {
        val f = Fixture().ready()
        withMedia(SynologyPhotoUploadTarget.Album(71)) { file, row ->
            assertTrue(f.repository.performPhotoUpload(row, file, {}).finished)
            assertEquals(setOf("album_id", "folder", "name", "mtime", "duplicate"), f.uploads.single().fields.keys)
            assertEquals("71", f.uploads.single().fields["album_id"])
            assertTrue(f.calls.none { it.method == "add_item" })
            assertEquals("71", f.calls.last().fields["album_id"])
        }
    }

    @Test fun `无原空间的贡献者以口令直接上传并核对provider`() = runBlocking {
        val f = Fixture().apply { home = false; shared = "none"; albumOwner = 42 }.ready()
        withMedia(SynologyPhotoUploadTarget.Album(71)) { file, row ->
            var stored: SynologyPhotoUploadCheckpoint? = null
            assertTrue(f.repository.performPhotoUpload(row, file, { stored = it }).finished)
            val sent = f.uploads.single()
            assertEquals("\"synthetic-passphrase\"", sent.fields["passphrase"])
            assertEquals(setOf("passphrase", "folder", "name", "mtime", "duplicate"), sent.fields.keys)
            assertEquals("false", f.calls.single { it.method == "get_permission" }.fields["exclude_public"])
            assertFalse(kotlinx.serialization.json.Json.encodeToString(SynologyPhotoUploadCheckpoint.serializer(), stored!!).contains("passphrase"))
        }
    }

    @Test fun `条件冻结和只读相册均拒绝贡献`() = runBlocking {
        for (mode in 0..2) {
            val f = Fixture().apply {
                when (mode) { 0 -> albumType = "condition"; 1 -> frozen = true; else -> { albumOwner = 42; contributor = false } }
            }.ready()
            withMedia(SynologyPhotoUploadTarget.Album(71)) { file, row ->
                failure { f.repository.performPhotoUpload(row, file, {}) }
                assertTrue(f.uploads.isEmpty())
            }
        }
    }

    @Test fun `大小目录和相册提供者不匹配保留结果不明`() = runBlocking {
        for (mode in 0..2) {
            val f = Fixture().apply { when (mode) { 0 -> itemSize = 5; 1 -> itemFolder = 99; else -> provider = 42 } }.ready()
            withMedia(if (mode == 2) SynologyPhotoUploadTarget.Album(71) else SynologyPhotoUploadTarget.Folder(SynologyPhotoSpace.PERSONAL, 9)) { file, row ->
                val result = f.repository.performPhotoUpload(row, file, {})
                assertEquals(SynologyPhotoUploadPhase.PENDING, result.phase)
                assertEquals(91L, result.itemId)
                assertEquals(SynologyPhotoUploadPhase.PENDING, f.repository.performPhotoUpload(row, file, {}).phase)
                assertEquals(1, f.uploads.size)
            }
        }
    }

    @Test fun `丢失与损坏回执绝不以同名照片认领或重传`() = runBlocking {
        for (response in listOf("{}", "{\"id\":0}", "{\"id\":\"91\"}", "{\"id\":91,\"action\":\"ignore\"}")) {
            val f = Fixture().apply { uploadReply = response }.ready()
            withMedia { file, row ->
                val result = f.repository.performPhotoUpload(row, file, {})
                assertNull(result.itemId)
                assertEquals(SynologyPhotoUploadPhase.PENDING, result.phase)
                f.repository.performPhotoUpload(row, file, {})
                assertEquals(1, f.uploads.size)
                assertTrue(f.calls.none { it.api.endsWith("Browse.Item") })
            }
        }
    }

    @Test fun `相同未决操作不能换编号绕过重复保护`() = runBlocking {
        val f = Fixture().apply { beforeUpload = { throw IOException() } }.ready()
        withMedia { file, row ->
            assertEquals(SynologyPhotoUploadPhase.PENDING, f.repository.performPhotoUpload(row, file, {}).phase)
            failure { f.repository.performPhotoUpload(row.copy(operationId = UUID.randomUUID().toString()), file, {}) }
            failure { f.repository.performPhotoUpload(row.copy(operationId = UUID.randomUUID().toString(),
                action = (row.action as SynologyPhotoUploadAction.Upload).copy(duplicate = SynologyPhotoUploadDuplicate.IGNORE, modifiedAtSeconds = 2000)), file, {}) }
            assertEquals(1, f.uploads.size)
        }
    }

    @Test fun `存储失败时不能发送上传且保留内存防重状态`() = runBlocking {
        val f = Fixture().ready()
        withMedia { file, row ->
            try { f.repository.performPhotoUpload(row, file, { throw IOException() }); fail() } catch (_: IOException) { }
            assertTrue(f.uploads.isEmpty())
            assertTrue(f.repository.performPhotoUpload(row, file, {}).submitted)
            assertTrue(f.uploads.isEmpty())
        }
    }

    @Test fun `回执持久化失败后同进程仍能恢复原编号且不重传`() = runBlocking {
        val f = Fixture().ready()
        withMedia { file, row ->
            try {
                f.repository.performPhotoUpload(row, file, { if (it.itemId != null) throw IOException() }); fail()
            } catch (_: IOException) { }
            assertTrue(f.repository.performPhotoUpload(row, file, {}).finished)
            assertEquals(1, f.uploads.size)
        }
    }

    @Test fun `私有副本改动在写前拒绝`() = runBlocking {
        val f = Fixture().ready()
        withMedia { file, row ->
            file.writeBytes(byteArrayOf(9, 8, 7, 6))
            failure { f.repository.performPhotoUpload(row, file, {}) }
            assertTrue(f.uploads.isEmpty())
        }
    }

    @Test fun `恢复只属于原用户原连接且不需要原件即可回读`() = runBlocking {
        withMedia { file, row ->
            val f = Fixture().apply { itemSize = 5 }.ready()
            val pending = f.repository.performPhotoUpload(row, file, {})
            val restored = Fixture().ready()
            assertTrue(restored.repository.reviewPhotoUpload(pending, {}).finished)
            assertTrue(restored.uploads.isEmpty())
            for (wrong in listOf(pending.copy(userId = 42), pending.copy(profileId = "profile-b"))) {
                failure { restored.repository.reviewPhotoUpload(wrong, {}) }
            }
            assertTrue(restored.uploads.isEmpty())
        }
    }

    @Test fun `提交前访问代次变化不写入`() = runBlocking {
        val f = Fixture().ready()
        var changed = false
        withMedia { file, row ->
            f.beforeCall = { call ->
                if (!changed && call.api.endsWith("Browse.Folder")) { changed = true; f.repository.access() }
            }
            try { f.repository.performPhotoUpload(row, file, {}); fail() } catch (_: CancellationException) { }
            assertTrue(f.uploads.isEmpty())
        }
    }

    @Test fun `提交后取消保留回执编号并且恢复不再发送`() = runBlocking {
        val f = Fixture().ready()
        withMedia { file, row ->
            var saved: SynologyPhotoUploadCheckpoint? = null
            f.beforeUpload = { currentCoroutineContext().cancel() }
            val task = launch(Dispatchers.Default) { f.repository.performPhotoUpload(row, file, { saved = it }) }
            task.join()
            assertEquals(SynologyPhotoUploadPhase.PENDING, saved?.phase)
            assertEquals(91L, saved?.itemId)
            assertTrue(f.repository.reviewPhotoUpload(saved!!, {}).finished)
            assertEquals(1, f.uploads.size)
        }
    }

    @Test fun `ignore回执只报告跳过且不是新增完成`() = runBlocking {
        val f = Fixture().apply { uploadReply = """{"id":91,"action":"ignore"}"""; itemSize = 99 }.ready()
        withMedia { file, row ->
            val action = (row.action as SynologyPhotoUploadAction.Upload).copy(duplicate = SynologyPhotoUploadDuplicate.IGNORE)
            assertEquals(SynologyPhotoUploadPhase.SKIPPED, f.repository.performPhotoUpload(row.copy(action = action), file, {}).phase)
        }
    }

    @Test fun `目录创建按父编号和名字回读且未知创建不能再次发送`() = runBlocking {
        val f = Fixture().ready()
        val row = SynologyPhotoUploadCheckpoint(profileId = "profile-a", userId = 41,
            action = SynologyPhotoUploadAction.CreateFolder(SynologyPhotoSpace.SHARED, 9, "Imported"))
        val result = f.repository.performPhotoUpload(row, null, {})
        assertTrue(result.finished); assertEquals(19L, result.folderId)
        val write = f.calls.single { it.method == "create" }
        assertEquals("SYNO.FotoTeam.Browse.Folder", write.api)
        assertEquals(1, write.version)
        assertEquals(mapOf("target_id" to "9", "name" to "\"Imported\""), write.fields)
        f.repository.performPhotoUpload(row, null, {})
        assertEquals(1, f.calls.count { it.method == "create" })
        val unknown = Fixture().apply { folderReply = "{}" }.ready()
        val pending = unknown.repository.performPhotoUpload(row, null, {})
        assertEquals(SynologyPhotoUploadPhase.PENDING, pending.phase)
        unknown.repository.performPhotoUpload(row, null, {})
        assertEquals(1, unknown.calls.count { it.method == "create" })
    }

    @Test fun `缺失共享能力不能借个人接口而相册候选使用addable`() = runBlocking {
        val f = Fixture(capabilities().filterKeys { it != "SYNO.FotoTeam.Upload.Item" }).ready()
        withMedia(SynologyPhotoUploadTarget.Timeline(SynologyPhotoSpace.SHARED)) { file, row ->
            failure { f.repository.performPhotoUpload(row, file, {}) }
            assertTrue(f.uploads.isEmpty())
        }
        assertEquals(listOf(71L), f.repository.addableAlbums(0, 100).map { it.id })
        assertEquals("\"addable\"", f.calls.last().fields["category"])
        assertEquals(SynologyPhotoUploadDuplicate.RENAME, f.repository.uploadDuplicatePolicy())
        f.defaultPolicy = "overwrite"
        failure { f.repository.uploadDuplicatePolicy() }
    }

    private suspend fun withMedia(target: SynologyPhotoUploadTarget = SynologyPhotoUploadTarget.Timeline(SynologyPhotoSpace.PERSONAL),
        block: suspend (File, SynologyPhotoUploadCheckpoint) -> Unit) {
        val file = Files.createTempFile("synthetic-photo-", ".bin").toFile()
        try {
            val bytes = byteArrayOf(1, 2, 3, 4); file.writeBytes(bytes)
            val row = SynologyPhotoUploadCheckpoint(profileId = "profile-a", userId = 41,
                action = SynologyPhotoUploadAction.Upload(target, "synthetic.jpg", 4, 1000, digest(bytes), SynologyPhotoUploadDuplicate.RENAME))
            block(file, row)
        } finally { file.delete() }
    }

    private suspend fun failure(block: suspend () -> Unit) {
        try { block(); fail("应在明确的权限或身份错误处停止") } catch (_: SynologyPhotoFailure) { }
    }

    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        private fun capabilities() = listOf("SYNO.Foto", "SYNO.FotoTeam").flatMap { prefix ->
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace", "Browse.Folder", "Browse.Album", "Browse.Item",
                "Sharing.Passphrase", "Upload.Item", "Browse.NormalAlbum").map { name ->
                val api = "$prefix.$name"; api to ApiCapability(api, "entry.cgi", 1, 7, "JSON")
            }
        }.toMap()
    }
}
