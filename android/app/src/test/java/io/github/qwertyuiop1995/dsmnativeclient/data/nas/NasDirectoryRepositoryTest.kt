package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class NasDirectoryRepositoryTest {
    private val fixture = NasDirectoryFixture()
    private val repo = NasDirectoryRepository(fixture, "Current")
    private val stages = mutableListOf<NasDirectoryStage>()
    private suspend fun change() = repo.accounts().single().let { NasDirectoryChange(NasDirectoryKind.ACCOUNT, NasDirectoryAction.EDIT,
        it.name, "Updated", it.email.orEmpty(), it.disabled, account = it) }
    private suspend fun execute(value: NasDirectoryChange) = repo.change(value) { stages += it }
    @Test fun `账号创建只发一次v1与密码双字段并取得真实目录`() = runBlocking {
        val value = NasDirectoryChange(NasDirectoryKind.ACCOUNT, NasDirectoryAction.CREATE, "NewSynthetic", password = "synthetic-password", passwordConfirmation = "synthetic-password")
        assertTrue(execute(value)); val request = fixture.requests.single { it.write }
        assertEquals("create", request.method); assertEquals(JsonPrimitive("synthetic-password"), request.fields["password_confirm"])
        assertFalse(request.fields.containsKey("groups")); assertEquals(listOf(NasDirectoryStage.SUBMITTED, NasDirectoryStage.ACCEPTED, NasDirectoryStage.COMPLETED), stages)
        assertEquals(2, repo.accounts().size)
    }
    @Test fun `编辑空密码和未知群组省略且原名固定`() = runBlocking {
        fixture.users = fixture.users.map { JsonObject(it - "groups") }
        val value = change(); assertTrue(execute(value)); val request = fixture.requests.single { it.write }
        assertEquals("set", request.method); assertFalse(request.fields.containsKey("password")); assertFalse(request.fields.containsKey("groups"))
        assertEquals(value.name, request.fields.getValue("name").jsonPrimitive.content)
    }
    @Test fun `成员变更比较整个原群组目录并发送明确选择`() = runBlocking {
        val original = change(); val groups = repo.groups()
        val value = original.copy(groups = emptyList(), groupsBaseline = groups)
        assertTrue(execute(value)); assertEquals(JsonArray(emptyList()), fixture.requests.single { it.write }.fields["groups"])
    }
    @Test fun `原账号和群组目录漂移零写入`() = runBlocking {
        val value = change().copy(groups = emptyList(), groupsBaseline = repo.groups())
        fixture.groupRows = fixture.groupRows.map { JsonObject(it + ("description" to JsonPrimitive("Changed"))) }
        rejected { execute(value) }; assertTrue(fixture.requests.none { it.write })
        fixture.groupRows = listOf(NasDirectoryFixture.group()); fixture.users = listOf(NasDirectoryFixture.user(id = 101))
        rejected { execute(value.copy(groups = null)) }; assertTrue(fixture.requests.none { it.write })
    }
    @Test fun `群组只保存名称说明且支持删除数组参数`() = runBlocking {
        val old = repo.groups().single(); val value = NasDirectoryChange(NasDirectoryKind.GROUP, NasDirectoryAction.EDIT, old.name, "Updated", group = old)
        assertTrue(execute(value)); assertEquals(setOf("name", "description"), fixture.requests.single { it.write }.fields.keys)
        assertTrue(execute(value.copy(action = NasDirectoryAction.DELETE, group = repo.groups().single())))
        assertTrue(fixture.requests.last { it.write }.fields.getValue("name") is JsonArray)
    }
    @Test fun `当前账号不能停用改组删除且保护内建目录`() = runBlocking {
        for (name in listOf("Current", "admin", "guest")) {
            fixture.users = listOf(NasDirectoryFixture.user(name)); val old = repo.accounts().single()
            rejected { execute(NasDirectoryChange(NasDirectoryKind.ACCOUNT, NasDirectoryAction.DELETE, name, account = old)) }
            if (name == "Current") {
                val value = change(); rejected { execute(value.copy(disabled = true)) }
                rejected { execute(value.copy(groups = emptyList(), groupsBaseline = repo.groups())) }
            }
        }
        fixture.groupRows = listOf(NasDirectoryFixture.group("administrators")); val old = repo.groups().single()
        rejected { execute(NasDirectoryChange(NasDirectoryKind.GROUP, NasDirectoryAction.DELETE, old.name, group = old)) }
        assertTrue(fixture.requests.none { it.write })
    }
    @Test fun `无对象许可无原组关系和权限撤销均零写入`() = runBlocking {
        val value = change()
        fixture.accessFailure = DsmFailure(105, "synthetic", "", kind = DsmErrorKind.PERMISSION_DENIED)
        rejected { execute(value) }; fixture.accessFailure = null
        fixture.users = fixture.users.map { JsonObject(it + ("can_edit" to JsonPrimitive(false))) }
        rejected { execute(change()) }
        fixture.users = fixture.users.map { JsonObject((it - "groups") + ("can_edit" to JsonPrimitive(true))) }
        rejected { execute(change().copy(groups = emptyList(), groupsBaseline = repo.groups())) }
        assertTrue(fixture.requests.none { it.write })
    }
    @Test fun `回执丢失的改密和创建保持未知且不重放`() = runBlocking {
        fixture.responseFailure = IOException("synthetic disconnect")
        val value = change().copy(password = "synthetic", passwordConfirmation = "synthetic")
        assertFalse(execute(value)); assertEquals(listOf(NasDirectoryStage.SUBMITTED), stages)
        stages.clear()
        assertFalse(execute(NasDirectoryChange(NasDirectoryKind.ACCOUNT, NasDirectoryAction.CREATE, "New", password = "synthetic", passwordConfirmation = "synthetic")))
        assertEquals(2, fixture.requests.count { it.write }); assertEquals(listOf(NasDirectoryStage.SUBMITTED), stages)
    }
    @Test fun `非密码字段回执丢失可以仅回读完成`() = runBlocking {
        fixture.responseFailure = IOException("synthetic disconnect")
        assertTrue(execute(change())); assertEquals(listOf(NasDirectoryStage.SUBMITTED, NasDirectoryStage.COMPLETED), stages)
        assertEquals(1, fixture.requests.count { it.write })
    }
    @Test fun `明确拒绝不以恰好匹配的字段覆盖`() = runBlocking {
        fixture.responseFailure = DsmFailure(105, "synthetic", "", kind = DsmErrorKind.PERMISSION_DENIED)
        rejected { execute(change()) }; assertEquals(listOf(NasDirectoryStage.SUBMITTED, NasDirectoryStage.REJECTED), stages)
    }
    @Test fun `写前记录失败零请求且接受记录失败不读取结果`() = runBlocking {
        val value = change(); rejected { repo.change(value) { throw IOException("synthetic storage") } }
        assertTrue(fixture.requests.none { it.write })
        val reads = fixture.reads
        rejected { repo.change(value) { if (it == NasDirectoryStage.ACCEPTED) throw IOException("synthetic storage") } }
        assertEquals(1, fixture.requests.count { it.write }); assertEquals(reads + 1, fixture.reads)
    }
    @Test fun `删除回读畸形不能确认消失`() = runBlocking {
        val value = change().copy(action = NasDirectoryAction.DELETE)
        fixture.afterWrite = { fixture.users = listOf(buildJsonObject { put("name", "") }) }
        assertFalse(execute(value)); assertFalse(stages.contains(NasDirectoryStage.COMPLETED))
    }
    @Test fun `未知记录锁住新写入并且提交取消不补发`() = runBlocking {
        val value = change(); repo.recoveryPending = { true }; rejected { execute(value) }; assertTrue(fixture.requests.none { it.write })
        repo.recoveryPending = { false }; fixture.responseFailure = CancellationException("synthetic")
        try { execute(value); fail() } catch (_: CancellationException) { }
        assertEquals(listOf(NasDirectoryStage.SUBMITTED), stages); assertEquals(1, fixture.requests.count { it.write })
    }
    @Test fun `读取保留normal now与缺字段状态且显式编辑拒绝生效`() = runBlocking {
        fixture.users = fixture.users.map { JsonObject(it - "can_edit") }; assertTrue(repo.accounts().single().canEdit)
        fixture.users = fixture.users.map { JsonObject(it + ("expired" to JsonPrimitive("now"))) }; assertTrue(repo.accounts().single().disabled)
        fixture.users = fixture.users.map { JsonObject(it - "expired") }; val value = repo.accounts().single(); assertFalse(value.disabledKnown); assertFalse(value.canEdit)
        fixture.users = listOf(NasDirectoryFixture.user()).map { JsonObject(it + ("can_edit" to JsonPrimitive(false))) }; assertFalse(repo.accounts().single().canEdit)
    }
    @Test fun `截断重复身份根额外字段冲突和畸形类型拒绝`() = runBlocking {
        val base = NasDirectoryFixture.user()
        val invalid = listOf(List(1000) { base }, listOf(base, base), listOf(base, NasDirectoryFixture.user("Other")),
            listOf(JsonObject(base + ("additional" to buildJsonObject { put("email", "other@example.invalid") }))),
            listOf(JsonObject(base + ("uid" to JsonPrimitive("100")))), listOf(JsonObject(base + ("can_edit" to JsonPrimitive("true")))))
        for (rows in invalid) { fixture.users = rows; rejected { repo.accounts() } }
        fixture.users = listOf(JsonObject(base + ("description" to JsonPrimitive("")))); assertEquals("", repo.accounts().single().description)
    }
    @Test fun `提交前确认基线不能被改名绕过且密码不进入诊断文本`() = runBlocking {
        val value = change().copy(password = "synthetic-secret", passwordConfirmation = "synthetic-secret")
        assertFalse(value.toString().contains("synthetic-secret")); rejected { execute(value.copy(name = "Other")) }; assertTrue(fixture.requests.none { it.write })
    }
    @Test fun `证书身份异常立即停止后续读取并保留提交记录`() = runBlocking {
        val value = change(); val reads = fixture.reads
        fixture.responseFailure = DsmFailure(null, "synthetic identity", "", kind = DsmErrorKind.TLS_UNTRUSTED)
        rejected { execute(value) }
        assertEquals(reads + 1, fixture.reads); assertEquals(listOf(NasDirectoryStage.SUBMITTED), stages)
    }
    private suspend fun rejected(block: suspend () -> Unit) { try { block(); fail("Expected rejection") } catch (error: Exception) { if (error is CancellationException) throw error } }
}
