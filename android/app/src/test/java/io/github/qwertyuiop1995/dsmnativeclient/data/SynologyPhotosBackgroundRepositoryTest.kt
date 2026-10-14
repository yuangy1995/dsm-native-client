package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class SynologyPhotosBackgroundRepositoryTest {
    private data class Call(val api: String, val method: String, val fields: Map<String, JsonElement>, val space: SynologyPhotoSpace?)
    private class Fixture {
        var owner = SynologyPhotosMutationAccess("background-profile", 41, 1, false)
        var spaces = SynologyPhotoSpace.entries.toSet()
        var tasks = listOf(task()); var details = emptyList<JsonObject>(); var items = emptyList<JsonObject>()
        val folders = mutableMapOf(1L to folder(1, "/", 0), 20L to folder(20, "/Target", 1))
        val reads = mutableListOf<Call>(); val writes = mutableListOf<Call>(); val saved = mutableListOf<SynologyPhotoAlbumCheckpoint>()
        var apply = true; var writeError: Exception? = null; var namesFail = false
        var onRead: (Call) -> Unit = {}; var onWrite: (Call) -> Unit = {}
        fun repository() = SynologyPhotosAlbumRepository(identity = { owner },
            checkAccess = { expected, space -> if (expected != owner || space != null && space !in spaces) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION) },
            capability = { api, version, _ -> ApiCapability(api, "entry.cgi", version, version) },
            read = { api, _, method, fields, space ->
                val call = Call(api, method, fields, space); reads += call; onRead(call)
                when (api to method) {
                    "BackgroundTask.Info" to "list_user_task" -> { assertNull(space); assertTrue(fields.isEmpty()); list(tasks) }
                    "BackgroundTask.Info" to "get_error_detail" -> { assertNull(space); assertEquals(JsonPrimitive(91), fields["id"]); list(details) }
                    "Browse.Item" to "get" -> { assertEquals(SynologyPhotoSpace.SHARED, space); if (namesFail) throw IOException("Synthetic name lookup"); list(items) }
                    "Browse.Folder" to "get" -> {
                        if (namesFail) throw IOException("Synthetic folder lookup")
                        JsonObject(mapOf("folder" to folders.getValue(fields.getValue("id").jsonPrimitive.long)))
                    }
                    else -> error("Unexpected synthetic read")
                }
            }, write = { api, version, method, fields, space ->
                assertEquals("BackgroundTask.Info", api); assertEquals(1, version); assertNull(space)
                val id = if (method == "abort_task") fields.getValue("id").jsonArray.single().jsonPrimitive.long else fields.getValue("id").jsonPrimitive.long
                assertTrue(id in saved.last().background!!.attempted)
                val call = Call(api, method, fields, space); writes += call
                if (apply) tasks = if (method == "clear_completed_task") tasks.filterNot { it["id"] == JsonPrimitive(id) }
                    else tasks.map { if (it["id"] == JsonPrimitive(id)) JsonObject(it + ("status" to JsonPrimitive("done"))) else it }
                onWrite(call); writeError?.let { throw it }; JsonObject(emptyMap())
            }, details = { error("No media details") }, photos = { _, _, _, _ -> error("No album pages") },
            photoPending = { false }, requestSpaces = { spaces })
        fun save(row: SynologyPhotoAlbumCheckpoint) { validatePhotoAlbumCheckpoint(row); saved += row }
        fun row(action: SynologyPhotoAlbumAction = SynologyPhotoAlbumAction.STOP_TASK) = SynologyPhotoAlbumCheckpoint(
            profileId = owner.profileId, userId = owner.userId, action = action,
            background = SynologyPhotoBackgroundCheckpoint(SynologyPhotoBackgroundCodec.tasks(list(tasks), owner.profileId, owner.userId).map { it.snapshot }))
    }

    @Test fun `统一用户任务无需个人图库且处理数包含失败未知状态只读`() = runBlocking {
        val f = Fixture(); f.spaces = emptySet()
        f.tasks = listOf(task(), task(92, "done", completion = 10, errors = 10), task(93, "future", operation = "other"))
        val tasks = f.repository().backgroundTasks()
        assertEquals(1L, tasks[0].successful); assertEquals(SynologyPhotoSpace.SHARED, tasks[0].targetSpace)
        assertEquals(0L, tasks[1].successful); assertFalse(tasks[1].stopped); assertFalse(tasks[1].canOpenTarget)
        assertEquals(SynologyPhotoBackgroundStatus.UNKNOWN, tasks[2].snapshot.status)
        assertFalse(tasks[2].snapshot.canStop); assertFalse(tasks[2].snapshot.canClear)
        assertTrue(f.reads.all { it.api == "BackgroundTask.Info" && it.space == null }); assertTrue(f.writes.isEmpty())
    }

    @Test fun `缺字段重复编号非法计数和目标不能被解码为空或成功`() = runBlocking {
        val original = task()
        val bad = listOf(JsonObject(original - "completion"), JsonObject(original + ("completion" to JsonPrimitive(11))),
            JsonObject(original + ("error" to JsonPrimitive(3))), JsonObject(original + ("skip" to JsonPrimitive(-1))),
            JsonObject(original + ("overwrite" to JsonPrimitive(11))), JsonObject(original + ("create_time" to JsonPrimitive(-1))),
            JsonObject(original + ("total" to JsonPrimitive("10"))),
            JsonObject(original + ("target_folder" to obj("""{"id":20}"""))))
        for (value in bad) { val f = Fixture(); f.tasks = listOf(value); reject { f.repository().backgroundTasks() } }
        val f = Fixture(); f.tasks = listOf(original, original); reject { f.repository().backgroundTasks() }
    }

    @Test fun `停止先保存尝试范围使用数组且允许进度变化不重复发送`() = runBlocking {
        val f = Fixture(); val repo = f.repository(); val row = f.row()
        repo.prepare(row); f.tasks = listOf(task(completion = 4, errors = 1))
        val result = repo.perform(row, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, result.phase); assertEquals(setOf(91L), result.background!!.completed)
        assertEquals(JsonArray(listOf(JsonPrimitive(91))), f.writes.single().fields["id"])
        assertEquals("abort_task", f.writes.single().method)
        assertTrue(repo.backgroundTasks().single().stopped)
        repo.perform(row, save = f::save); assertEquals(1, f.writes.size)
    }

    @Test fun `目标身份创建时间和账号变更拒绝写入`() = runBlocking {
        for (field in listOf("id", "create_time", "total", "operation", "target_folder")) {
            val f = Fixture(); val repo = f.repository(); val row = f.row(); repo.prepare(row)
            val changed = when (field) {
                "operation" -> JsonPrimitive("move")
                "target_folder" -> obj("""{"id":21,"owner_user_id":0}""")
                else -> JsonPrimitive(101)
            }
            f.tasks = listOf(JsonObject(f.tasks.single() + (field to changed)))
            reject { repo.perform(row, save = f::save) }; assertTrue(f.writes.isEmpty())
        }
        val f = Fixture(); val repo = f.repository(); val row = f.row(); f.owner = f.owner.copy(userId = 42)
        reject { repo.perform(row, save = f::save) }; assertTrue(f.writes.isEmpty())
    }

    @Test fun `清理固定结束范围使用逐项标量新增结束任务保留`() = runBlocking {
        val f = Fixture(); f.tasks = listOf(task(91, "done", 10), task(92, "done", 10)); val row = f.row(SynologyPhotoAlbumAction.CLEAR_TASKS)
        f.onWrite = { if (f.writes.size == 1) f.tasks += task(93, "done", 10) }
        val done = f.repository().perform(row, save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.COMPLETED, done.phase); assertEquals(setOf(91L, 92L), done.background!!.completed)
        assertEquals(listOf(JsonPrimitive(91), JsonPrimitive(92)), f.writes.map { it.fields["id"] })
        assertTrue(f.writes.all { it.method == "clear_completed_task" && it.fields.keys == setOf("id") })
        assertEquals(JsonPrimitive(93), f.tasks.single()["id"])
    }

    @Test fun `清理丢回执只读取已尝试部分冷恢复不碰剩余任务`() = runBlocking {
        val f = Fixture(); f.tasks = listOf(task(91, "done", 10), task(92, "done", 10))
        f.writeError = IOException("Synthetic receipt loss")
        val first = f.repository().perform(f.row(SynologyPhotoAlbumAction.CLEAR_TASKS), save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PARTIAL, first.phase); assertEquals(setOf(91L), first.background!!.completed)
        val restored = Json.decodeFromString<SynologyPhotoAlbumCheckpoint>(Json.encodeToString(first))
        assertEquals(first, f.repository().review(restored, f::save)); assertEquals(1, f.writes.size)
        assertEquals(JsonPrimitive(92), f.tasks.single()["id"])
    }

    @Test fun `未知停止只读等待明确拒绝不能被后来终态冒认成功`() = runBlocking {
        val f = Fixture(); f.apply = false; f.writeError = IOException("Synthetic offline")
        val pending = f.repository().perform(f.row(), save = f::save)
        assertEquals(SynologyPhotoAlbumPhase.PENDING, pending.phase)
        val restored = f.repository(); assertFalse(restored.review(pending, f::save).finished)
        f.tasks = emptyList(); assertEquals(SynologyPhotoAlbumPhase.COMPLETED, restored.review(pending, f::save).phase)
        assertEquals(1, f.writes.size)
        for (code in listOf(105, 106, 107, 119)) {
            val denied = Fixture(); denied.apply = false; denied.writeError = DsmFailure(code, "Synthetic refusal", "Synthetic recovery")
            val result = denied.repository().perform(denied.row(), save = denied::save)
            assertEquals(SynologyPhotoAlbumPhase.PARTIAL, result.phase); assertTrue(result.background!!.completed.isEmpty())
            assertEquals(setOf(91L), result.background.rejected)
            denied.tasks = emptyList(); assertEquals(result, denied.repository().review(result, denied::save))
        }
    }

    @Test fun `详情按目标来源和编号补名称失败保留原因未知类型不猜路由`() = runBlocking {
        val f = Fixture(); f.details = listOf(obj("""{"id":11,"type":"item","reason":"quota_full"}"""),
            obj("""{"id":12,"type":"item","reason":"space_full"}"""), obj("""{"id":20,"type":"folder","reason":"not_existed"}"""),
            obj("""{"id":21,"type":"future","reason":"new_reason"}"""))
        f.items = listOf(obj("""{"id":12,"filename":"Second.jpg","additional":{"folder":"/Target"}}"""),
            obj("""{"id":11,"filename":"First.jpg"}"""))
        val repo = f.repository(); val task = repo.backgroundTasks().single(); val errors = repo.backgroundTaskErrors(task)
        assertEquals(listOf("First.jpg", "Second.jpg", "Target", null), errors.map { it.name })
        assertEquals(SynologyPhotoBackgroundError.Reason.UNKNOWN, errors.last().reason)
        assertEquals(JsonArray(listOf(JsonPrimitive(11), JsonPrimitive(12))), f.reads.single { it.api == "Browse.Item" }.fields["id"])
        f.namesFail = true; assertTrue(repo.backgroundTaskErrors(task).all { it.name == null })
        f.spaces = emptySet(); val count = f.reads.size; assertEquals(4, repo.backgroundTaskErrors(task).size)
        assertTrue(f.reads.drop(count).all { it.api == "BackgroundTask.Info" })
    }

    @Test fun `目标跳转重新读取任务和完整父链权限撤回与父循环失败`() = runBlocking {
        val f = Fixture(); f.tasks = listOf(task(status = "done", completion = 10, errors = 0)); val repo = f.repository(); val task = repo.backgroundTasks().single()
        val path = repo.backgroundTaskTarget(task)
        assertEquals(listOf(1L, 20L), path.map { it.id }); assertTrue(path.all { it.space == SynologyPhotoSpace.SHARED })
        f.folders[20] = folder(20, "/Target", 20); reject { repo.backgroundTaskTarget(task) }
        f.folders[20] = folder(20, "/Target", 1, false); reject { repo.backgroundTaskTarget(task) }
        f.folders[20] = folder(20, "/Target", 1); f.spaces = setOf(SynologyPhotoSpace.PERSONAL); reject { repo.backgroundTaskTarget(task) }
        assertTrue(f.writes.isEmpty())
    }

    @Test fun `读取期间撤权不能发布旧账号任务或详情`() = runBlocking {
        val f = Fixture(); val repo = f.repository()
        f.onRead = { if (it.method == "list_user_task") f.owner = f.owner.copy(generation = f.owner.generation + 1) }
        reject { repo.backgroundTasks() }; assertTrue(f.writes.isEmpty())
    }

    companion object {
        private fun obj(value: String) = Json.parseToJsonElement(value).jsonObject
        private fun list(value: List<JsonObject>) = JsonObject(mapOf("list" to JsonArray(value)))
        private fun task(id: Long = 91, status: String = "processing", completion: Long = 2, errors: Long = 1, operation: String = "copy") = obj(
            """{"id":$id,"operation":"$operation","status":"$status","total":10,"completion":$completion,"error":$errors,"skip":0,"overwrite":0,"create_time":100.5,"target_folder":{"id":20,"owner_user_id":0}}""")
        private fun folder(id: Long, path: String, parent: Long, view: Boolean = true) = obj(
            """{"id":$id,"name":"$path","parent":$parent,"additional":{"access_permission":{"view":$view}}}""")
        private suspend fun reject(block: suspend () -> Unit) { try { block(); fail("Expected target or permission rejection") } catch (_: SynologyPhotoFailure) {} }
    }
}
