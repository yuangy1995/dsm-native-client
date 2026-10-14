package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasSmartTestRepositoryTest {
    private suspend fun failure(block: suspend () -> Unit): DsmFailure = try { block(); error("Expected failure") } catch (e: DsmFailure) { e }
    @Test fun `两种编码三动作均固定v1原device与单次写且类型精确回读`() = runBlocking {
        for (format in listOf("FORM", "JSON")) for (action in NasSmartAction.entries) {
            val fixture = NasSmartFixture().apply { this.format = format; status = NasSmartFixture.status(if (action == NasSmartAction.STOP) "extend" else null)
                afterWrite = NasSmartFixture.status(if (action == NasSmartAction.STOP) null else action.parameter) }
            val repo = fixture.repository().nasSmart; val disk = repo.disks().single(); val baseline = repo.read(disk, true)
            assertEquals("2026-10-01", baseline.status.lastQuickTest); assertEquals("2026-09-01", baseline.status.lastExtendedTest)
            val stages = mutableListOf<NasSmartStage>(); val result = repo.perform(disk, baseline.status, action, stages::add)!!
            assertTrue(smartMatches(result.status, action)); assertEquals(listOf(NasSmartStage.SUBMITTED, NasSmartStage.ACCEPTED, NasSmartStage.VERIFIED), stages)
            val write = fixture.writes.single(); assertTrue(write.oneShot); assertEquals(1, write.version)
            assertEquals(if (format == "JSON") "\"synthetic-device\"" else "synthetic-device", write.fields["device"])
            assertEquals(if (format == "JSON") "\"${action.parameter}\"" else action.parameter, write.fields["type"])
            assertEquals(setOf("device", "type"), write.fields.keys)
            assertTrue(fixture.calls.all { it.version == if (it.method == "info") 3 else 1 })
        }
    }
    @Test fun `身份支持状态基线变化与权限环境撤销全部零写温度名称变化不冲突`() = runBlocking {
        for (condition in (0..6).filter { it != 5 }) {
            val fixture = NasSmartFixture(); val root = fixture.repository(); val repo = root.nasSmart; val disk = repo.disks().single(); val baseline = repo.read(disk, false).status
            when (condition) {
                0 -> fixture.directory = NasSmartFixture.directory(NasSmartFixture.row("replacement"))
                1 -> fixture.directory = NasSmartFixture.directory(JsonObject(fixture.row + ("smart_test_support" to JsonPrimitive(false))))
                2 -> fixture.status = NasSmartFixture.status("extend")
                3 -> fixture.status = NasSmartFixture.status(busy = true)
                4 -> fixture.admin = false
                6 -> fixture.ownerValid = false
            }
            val stages = mutableListOf<NasSmartStage>(); failure { repo.perform(disk, baseline, NasSmartAction.QUICK, stages::add) }
            assertTrue(fixture.writes.isEmpty()); assertEquals(listOf(NasSmartStage.CANCELLED), stages)
        }
        val fixture = NasSmartFixture(); val repo = fixture.repository().nasSmart; val disk = repo.disks().single(); val baseline = repo.read(disk, false).status
        fixture.directory = NasSmartFixture.directory(JsonObject(fixture.row + mapOf("temp" to JsonPrimitive(31), "longName" to JsonPrimitive("Changed display"))))
        fixture.afterWrite = NasSmartFixture.status("quick"); repo.perform(disk, baseline, NasSmartAction.QUICK) {}; assertEquals(1, fixture.writes.size)
    }
    @Test fun `严格状态别名设备响应目录重复与版本缺口失败关闭`() = runBlocking {
        val invalid = listOf("""{}""", """{"testing":false,"ihm_testing":false}""", """{"testing":true,"ihm_testing":false,"perf_testing":false,"test_type":"unknown"}""",
            """{"testing":false,"is_testing":true,"ihm_testing":false,"perf_testing":false}""", """{"testing":false,"ihm_testing":false,"perf_testing":false,"device":"different"}""")
        for (item in invalid) {
            val fixture = NasSmartFixture(); val repo = fixture.repository().nasSmart; val disk = repo.disks().single()
            fixture.status = Json.parseToJsonElement("{\"testInfo\":[$item]}") as JsonObject
            assertEquals(DsmErrorKind.INVALID_RESPONSE, failure { repo.read(disk, false) }.kind); assertTrue(fixture.writes.isEmpty())
        }
        val fixture = NasSmartFixture(); fixture.directory = NasSmartFixture.directory(fixture.row, fixture.row)
        assertEquals(DsmErrorKind.INVALID_RESPONSE, failure { fixture.repository().nasSmart.disks() }.kind)
        fixture.minVersion = 2; assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED, failure { fixture.repository().nasSmart.disks() }.kind)
        assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `历史失败保留当前状态权限失败不被折叠成普通历史缺失`() = runBlocking {
        val fixture = NasSmartFixture(); val repo = fixture.repository().nasSmart; val disk = repo.disks().single()
        fixture.history = JsonObject(emptyMap()); val read = repo.read(disk, true)
        assertFalse(read.status.isRunning); assertFalse(read.status.isHistoryAvailable); assertEquals(DsmErrorKind.INVALID_RESPONSE, read.historyFailure?.kind)
        fixture.rejection = 105; fixture.rejectionMethod = "disk_test_log_get"
        assertEquals(DsmErrorKind.PERMISSION_DENIED, failure { repo.read(disk, true) }.kind)
    }
    @Test fun `断线仅回读拒绝不回读写前和接受持久失败保留边界`() = runBlocking {
        for (condition in 0..3) {
            val fixture = NasSmartFixture(); val repo = fixture.repository().nasSmart; val disk = repo.disks().single(); val baseline = repo.read(disk, false).status
            val stages = mutableListOf<NasSmartStage>()
            fixture.before = { if (it.oneShot && condition == 0) { fixture.status = NasSmartFixture.status("quick"); throw IOException("Synthetic lost receipt") } }
            if (condition == 1) fixture.rejection = 105
            val action: suspend () -> Unit = { repo.perform(disk, baseline, NasSmartAction.QUICK) {
                if (condition == 2 && it == NasSmartStage.SUBMITTED || condition == 3 && it == NasSmartStage.ACCEPTED)
                    throw DsmFailure(null, "Synthetic full", "", kind = DsmErrorKind.LOCAL_STORAGE_FAILED)
                stages += it
            }; Unit }
            if (condition == 0) { action(); assertEquals(listOf(NasSmartStage.SUBMITTED, NasSmartStage.VERIFIED), stages) }
            else failure(action)
            assertEquals(if (condition == 2) 0 else 1, fixture.writes.size)
            if (condition in setOf(1, 3)) assertEquals("do_smart_test", fixture.calls.last().method)
        }
    }
    @Test fun `六次有界回读只接受精确类型网络可重试严格错误立即退出取消不重放`() = runBlocking {
        val disk = NasStorageDisk("disk", "device", "Drive", null, null, null, null, true)
        val idle = NasDiskTestStatus("disk", false, false, null, null, null, null, null, false)
        for (condition in listOf(0, 1, 2, 4)) {
            var writes = 0; var reads = 0; var pauses = 0
            val gateway = object : NasManagementGateway {
                override suspend fun requireWriteAccess() {}
                override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
                    assertTrue(write); writes++; if (condition == 4) throw CancellationException(); return JsonObject(emptyMap())
                }
            }
            val repo = NasSmartTestRepository(gateway, { _, _ -> true }, { listOf(disk) }, {
                reads++
                when {
                    writes == 0 -> idle
                    condition == 2 -> throw DsmFailure(null, "Malformed", "", kind = DsmErrorKind.INVALID_RESPONSE)
                    condition == 1 && reads < 7 -> throw DsmFailure(null, "Offline", "", kind = DsmErrorKind.CONNECTION_FAILED)
                    condition == 1 -> idle.copy(isRunning = true, runningType = NasDiskTestType.QUICK)
                    else -> idle.copy(isRunning = true, runningType = NasDiskTestType.EXTENDED)
                }
            }, { NasSmartHistory(null, null, null) }, { pauses++ })
            val stages = mutableListOf<NasSmartStage>()
            if (condition == 4) try { repo.perform(disk, idle, NasSmartAction.QUICK, stages::add); fail() } catch (_: CancellationException) {}
            else if (condition == 2) failure { repo.perform(disk, idle, NasSmartAction.QUICK, stages::add) }
            else repo.perform(disk, idle, NasSmartAction.QUICK, stages::add)
            assertEquals(1, writes); assertEquals(if (condition == 4) 1 else if (condition == 2) 2 else 7, reads)
            assertEquals(condition == 1, NasSmartStage.VERIFIED in stages); assertEquals(if (condition in setOf(2, 4)) 0 else 5, pauses)
        }
    }
}
