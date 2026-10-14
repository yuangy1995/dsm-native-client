package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasConnectionRepositoryTest {
    @Test fun `网页服务两种编码固定v1只发送完整原目标一次并核对消失`() = runBlocking {
        for (format in listOf("FORM", "JSON")) for (web in listOf(false, true)) {
            val fixture = NasConnectionFixture().also { it.format = format; it.row = NasConnectionFixture.row(web); it.directory = NasConnectionFixture.directory(it.row); it.afterWrite = NasConnectionFixture.directory() }
            val repo = fixture.repository().nasConnections; val target = repo.read().rows.single(); val stages = mutableListOf<NasConnectionStage>()
            assertTrue(repo.disconnect(target, stages::add)!!.rows.isEmpty())
            assertEquals(listOf(NasConnectionStage.SUBMITTED, NasConnectionStage.ACCEPTED, NasConnectionStage.VERIFIED), stages)
            val call = fixture.writes.single(); assertEquals(1, call.version); assertTrue(call.oneShot)
            val array = Json.parseToJsonElement(call.fields.getValue(if (web) "http_conn" else "service_conn")).jsonArray
            assertEquals(1, array.size); assertEquals(if (web) setOf("did", "descr", "who", "from") else setOf("pid", "type", "who", "from"), array.single().jsonObject.keys)
            assertEquals(JsonPrimitive(if (web) "synthetic-device" else "123"), array.single().jsonObject[if (web) "did" else "pid"])
            assertEquals("[]", call.fields.getValue(if (web) "service_conn" else "http_conn"))
            fixture.calls.filter { it.method == "list" }.forEach {
                assertEquals(1, it.version); assertFalse(it.oneShot); assertEquals("0", it.fields["start"]); assertEquals("500", it.fields["limit"])
                assertEquals(if (format == "JSON") "\"time\"" else "time", it.fields["sort_by"])
                assertEquals(if (format == "JSON") "\"DESC\"" else "DESC", it.fields["sort_direction"])
            }
        }
    }
    @Test fun `原目标变化目录截断权限环境归属及不支持均禁止写入`() = runBlocking {
        for (condition in (0..6).filter { it != 4 }) {
            val fixture = NasConnectionFixture(); val repo = fixture.repository().nasConnections; val target = repo.read().rows.single()
            when (condition) {
                0 -> fixture.directory = NasConnectionFixture.directory(JsonObject(fixture.row + ("descr" to JsonPrimitive("changed"))))
                1 -> fixture.directory = JsonObject(fixture.directory + ("total" to JsonPrimitive(2)))
                2 -> fixture.directory = NasConnectionFixture.directory(JsonObject(fixture.row + ("can_be_kicked" to JsonPrimitive(false))))
                3 -> fixture.admin = false
                5 -> fixture.ownerValid = false
                6 -> fixture.directory = NasConnectionFixture.directory(fixture.row, fixture.row)
            }
            val stages = mutableListOf<NasConnectionStage>(); assertTrue(runCatching { repo.disconnect(target, stages::add) }.isFailure)
            assertEquals(listOf(NasConnectionStage.CANCELLED), stages); assertTrue(fixture.writes.isEmpty())
        }
        val unsupported = NasConnectionFixture().also { it.minVersion = 2 }; val repo = unsupported.repository().nasConnections
        assertTrue(runCatching { repo.read() }.isFailure); assertTrue(unsupported.calls.isEmpty())
    }
    @Test fun `明确拒绝不回读而无回执仅只读确认不重放`() = runBlocking {
        for (reject in listOf(false, true)) {
            val fixture = NasConnectionFixture(); val repo = fixture.repository().nasConnections; val target = repo.read().rows.single()
            if (reject) fixture.rejection = 105 else fixture.before = { if (it.oneShot) { fixture.directory = NasConnectionFixture.directory(); throw IOException("Synthetic lost receipt") } }
            val stages = mutableListOf<NasConnectionStage>(); val result = runCatching { repo.disconnect(target, stages::add) }
            assertEquals(reject, result.isFailure); assertEquals(1, fixture.writes.size)
            assertEquals(if (reject) NasConnectionStage.REJECTED else NasConnectionStage.VERIFIED, stages.last())
            assertEquals(if (reject) "kick_connection" else "list", fixture.calls.last().method)
        }
    }
    @Test fun `原始身份仍在相似缺身份与部分列表均不能认领消失`() = runBlocking {
        for (condition in 0..4) {
            val fixture = NasConnectionFixture(); val repo = fixture.repository().nasConnections; val target = repo.read().rows.single()
            fixture.afterWrite = when (condition) {
                0 -> fixture.directory
                1 -> NasConnectionFixture.directory(JsonObject(fixture.row + mapOf("type" to JsonPrimitive("SMB"), "pid" to JsonPrimitive(456))))
                2 -> NasConnectionFixture.directory(JsonObject(fixture.row - "did"))
                3 -> JsonObject(NasConnectionFixture.directory() + ("total" to JsonPrimitive(3)))
                else -> NasConnectionFixture.directory(fixture.row, fixture.row)
            }
            val stages = mutableListOf<NasConnectionStage>(); repo.disconnect(target, stages::add)
            assertEquals(listOf(NasConnectionStage.SUBMITTED, NasConnectionStage.ACCEPTED), stages); assertEquals(1, fixture.writes.size)
        }
    }
    @Test fun `权限撤销与写后读取失败保留接受写前落盘失败零写`() = runBlocking {
        for (condition in 0..3) {
            val fixture = NasConnectionFixture(); val repo = fixture.repository().nasConnections; val target = repo.read().rows.single()
            fixture.afterWrite = NasConnectionFixture.directory()
            fixture.before = { if (it.oneShot && condition == 0) fixture.admin = false
                if (it.method == "list" && fixture.writes.isNotEmpty() && condition == 1) throw IOException("Synthetic offline") }
            val stages = mutableListOf<NasConnectionStage>(); assertTrue(runCatching { repo.disconnect(target) {
                if (condition == 2 && it == NasConnectionStage.SUBMITTED || condition == 3 && it == NasConnectionStage.ACCEPTED)
                    throw DsmFailure(null, "Synthetic disk failure", "", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
                stages += it
            } }.isFailure)
            assertEquals(if (condition == 2) 0 else 1, fixture.writes.size)
            assertFalse(NasConnectionStage.VERIFIED in stages)
            if (condition == 3) assertEquals("kick_connection", fixture.calls.last().method)
        }
    }
    @Test fun `严格字段和页边界可读降级不会扩大可断开目标`() {
        val valid = NasConnectionFixture.row()
        for ((field, value) in listOf("did" to JsonPrimitive(12), "can_be_kicked" to JsonPrimitive("true"), "is_current_connected" to JsonPrimitive(0),
            "who" to JsonPrimitive(true), "pid" to JsonPrimitive(1.5), "pid" to JsonPrimitive(2147483648L), "time" to JsonPrimitive(1.2))) {
            assertTrue(field, runCatching { decodeConnections(NasConnectionFixture.directory(JsonObject(valid + (field to value)))) }.isFailure)
        }
        assertTrue(runCatching { decodeConnections(JsonObject(emptyMap())) }.isFailure)
        assertTrue(runCatching { decodeConnections(buildJsonObject { put("items", JsonArray(listOf(JsonNull))) }) }.isFailure)
        for (missing in listOf("did", "who", "from", "type", "descr")) assertFalse(decodeConnections(NasConnectionFixture.directory(JsonObject(valid - missing))).rows.single().canDisconnect)
        val unknown = decodeConnections(NasConnectionFixture.directory(JsonObject(valid - "is_current_connected"))).rows.single()
        assertFalse(unknown.isCurrentKnown); assertFalse(unknown.isCurrent); assertTrue(unknown.canDisconnect)
        val duplicate = decodeConnections(NasConnectionFixture.directory(valid, valid)); assertTrue(duplicate.rows.none { it.canDisconnect }); assertEquals(2, duplicate.rows.map { it.id }.distinct().size)
        val page = JsonObject(mapOf("items" to JsonArray(List(500) { valid })))
        assertFalse(decodeConnections(page).complete); assertTrue(decodeConnections(JsonObject(page + ("total" to JsonPrimitive(500)))).complete)
        assertTrue(runCatching { decodeConnections(JsonObject(page + ("total" to JsonPrimitive(499)))) }.isFailure)
        val pid = decodeConnections(NasConnectionFixture.directory(NasConnectionFixture.row(false))).rows.single(); assertEquals("123", pid.processId)
        assertFalse(pid.toString().contains("synthetic")); assertFalse(connectionIdentity(unknown).toString().contains("synthetic"))
    }
}
