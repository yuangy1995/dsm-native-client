package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ContainerControlRepositoryTest {
    @Test fun `四项操作固定v1名称原生参数及单次请求并验证结果`() = runBlocking {
        for (format in listOf("FORM", "JSON")) for (action in ContainerAction.entries) {
            val fixture = ContainerFixture().apply { this.format = format; controls = listOf(ContainerFixture.control(running = action in setOf(ContainerAction.STOP, ContainerAction.RESTART))) }
            val repo = fixture.repository().containerManagement; val target = repo.controlTargets().single(); val stages = mutableListOf<ContainerStage>()
            repo.performControl(target, action, stages::add)
            assertEquals(listOf(ContainerStage.SUBMITTED, ContainerStage.ACCEPTED, ContainerStage.VERIFIED), stages)
            val request = fixture.writes.single(); assertEquals(1, request.version); assertTrue(request.oneShot)
            assertEquals(JsonPrimitive(target.name), request.fields["name"]); assertFalse(request.fields.containsKey("id"))
            if (action == ContainerAction.DELETE) { assertEquals(JsonPrimitive(false), request.fields["force"]); assertEquals(JsonPrimitive(false), request.fields["preserve_profile"]) }
            assertTrue(fixture.calls.filter { it.api == "SYNO.Docker.Container" }.all { it.version == 1 })
        }
    }
    @Test fun `实际管理员及套件授权撤销仍拒绝发送`() = runBlocking {
        for (change in listOf<(ContainerFixture) -> Unit>({ it.admin = false }, { it.allowed = false })) {
            val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement; val target = repo.controlTargets().single(); change(fixture)
            assertTrue(runCatching { repo.performControl(target, ContainerAction.START) {} }.isFailure); assertTrue(fixture.writes.isEmpty())
        }
    }
    @Test fun `未知系统套件版本不关闭容器控制也不查询版本`() = runBlocking {
        val fixture = ContainerFixture().apply { known = false; packageVersion = "99.0" }
        val repo = fixture.repository().containerManagement; val target = repo.controlTargets().single()
        repo.performControl(target, ContainerAction.START) {}
        assertEquals(1, fixture.writes.size)
        assertTrue(fixture.calls.none { it.api in setOf("SYNO.Core.System", "SYNO.Core.Package") })
    }
    @Test fun `名称身份状态或托管变化拒绝旧确认`() = runBlocking {
        val replacements = listOf(ContainerFixture.control(name = "Changed"), ContainerFixture.control(id = "Changed"), ContainerFixture.control(running = true), ContainerFixture.control(managed = true))
        for (replacement in replacements) {
            val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement; val target = repo.controlTargets().single()
            fixture.controls = listOf(replacement)
            assertTrue(runCatching { repo.performControl(target, ContainerAction.START) {} }.isFailure); assertTrue(fixture.writes.isEmpty())
        }
    }
    @Test fun `项目托管及缺失原生状态不允许操作`() = runBlocking {
        val fixture = ContainerFixture(); val original = fixture.controls.single()
        fixture.controls = listOf(JsonObject(original + ("Labels" to ContainerFixture.obj("""{"com.docker.compose.project":"Synthetic project"}"""))))
        fixture.projects = ContainerFixture.obj("""{"synthetic-project":{"name":"Synthetic project","is_package":true}}""")
        val repo = fixture.repository().containerManagement
        assertTrue(repo.controlTargets().single().managed == true)
        assertTrue(ContainerAction.entries.none(repo.controlTargets().single()::supports))
        fixture.controls = listOf(JsonObject(original + ("State" to ContainerFixture.obj("""{"Running":"false","Paused":false,"Restarting":false}"""))))
        assertTrue(ContainerAction.entries.none(repo.controlTargets().single()::supports))
    }
    @Test fun `部分清单重复身份畸形项目不能证明完成`() = runBlocking {
        for (change in listOf<(ContainerFixture) -> Unit>({ it.total = 2 }, { it.controls = it.controls + it.controls }, {
            it.controls = listOf(JsonObject(it.controls.single() + ("Labels" to ContainerFixture.obj("""{"com.docker.compose.project":"Synthetic project"}""")))); it.projects = ContainerFixture.obj("""{"invalid":true}""")
        })) {
            val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement; change(fixture)
            assertTrue(runCatching { repo.controlTargets() }.isFailure)
        }
    }
    @Test fun `重启不能用原运行状态认领只读刷新不会重发`() = runBlocking {
        val fixture = ContainerFixture().apply { controls = listOf(ContainerFixture.control(running = true)); applyWrite = false }
        val repo = fixture.repository().containerManagement; val target = repo.controlTargets().single(); val stages = mutableListOf<ContainerStage>()
        repo.performControl(target, ContainerAction.RESTART, stages::add)
        assertEquals(listOf(ContainerStage.SUBMITTED, ContainerStage.ACCEPTED), stages)
        assertFalse(repo.recoverControl(containerDigest(target.id), containerIdentity(target), ContainerAction.RESTART, target.startedAt))
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `写前记录失败零写回执记录失败停止后续读取`() = runBlocking {
        for (failedStage in listOf(ContainerStage.SUBMITTED, ContainerStage.ACCEPTED)) {
            val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement; val target = repo.controlTargets().single()
            assertTrue(runCatching { repo.performControl(target, ContainerAction.START) { if (it == failedStage) throw IOException("Synthetic storage") } }.isFailure)
            assertEquals(if (failedStage == ContainerStage.SUBMITTED) 0 else 1, fixture.writes.size)
            if (failedStage == ContainerStage.ACCEPTED) assertEquals("start", fixture.calls.last().method)
        }
    }
    @Test fun `证书错误和断线保留未知而明确拒绝记录终态`() = runBlocking {
        for (error in listOf(IOException("Synthetic lost receipt"), DsmFailure(null, "Synthetic trust", "", kind = DsmErrorKind.TLS_UNTRUSTED))) {
            val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement; val target = repo.controlTargets().single(); val stages = mutableListOf<ContainerStage>()
            fixture.before = { if (it.method == "start") throw error }
            assertTrue(runCatching { repo.performControl(target, ContainerAction.START, stages::add) }.isFailure)
            assertEquals(listOf(ContainerStage.SUBMITTED), stages)
        }
        val fixture = ContainerFixture().apply { rejection = 105 }; val repo = fixture.repository().containerManagement; val stages = mutableListOf<ContainerStage>()
        assertTrue(runCatching { repo.performControl(repo.controlTargets().single(), ContainerAction.START, stages::add) }.isFailure)
        assertEquals(listOf(ContainerStage.SUBMITTED, ContainerStage.REJECTED), stages)
    }
}
