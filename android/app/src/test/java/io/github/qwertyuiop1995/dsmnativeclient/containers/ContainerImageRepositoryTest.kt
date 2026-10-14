package io.github.qwertyuiop1995.dsmnativeclient.containers

import io.github.qwertyuiop1995.dsmnativeclient.data.container.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class ContainerImageRepositoryTest {
    @Test fun `映像完整参数原生布尔和按标签展开删除不扩大目标`() = runBlocking {
        for (format in listOf("FORM", "JSON")) {
            val fixture = ContainerFixture().apply { this.format = format; images = listOf(ContainerFixture.image(tags = listOf("stable", "other"))) }
            val repo = fixture.repository().containerManagement; val images = repo.imageDeletionTargets()
            assertEquals(2, images.size); assertEquals(2, images.map { it.id }.distinct().size)
            val target = images.single { it.tag == "stable" }; val stages = mutableListOf<ContainerStage>()
            assertEquals(setOf(target.id), repo.deleteImages(listOf(target), stages::add))
            assertEquals(listOf(ContainerStage.SUBMITTED, ContainerStage.ACCEPTED), stages)
            val write = fixture.writes.single(); assertTrue(write.oneShot); assertEquals(1, write.version)
            assertEquals(ContainerFixture.obj("""{"images":[{"repository":"synthetic/image","tags":["stable"]}]}"""), JsonObject(write.fields))
            assertEquals(listOf("other"), repo.imageDefinitions().map { it.tag })
            val read = fixture.calls.first { it.api == "SYNO.Docker.Image" && it.method == "list" }
            assertEquals(JsonPrimitive(false), read.fields["show_dsm"]); assertEquals(JsonPrimitive(-1), read.fields["limit"])
        }
    }
    @Test fun `停止容器也占用映像缺少占用字段不补空`() = runBlocking {
        val fixture = ContainerFixture(); fixture.controls = listOf(JsonObject(fixture.controls.single() + ("image" to JsonPrimitive("docker.io/synthetic/image:stable"))))
        val repo = fixture.repository().containerManagement
        assertTrue(repo.imageDeletionTargets().single().inUse == true)
        assertTrue(runCatching { repo.deleteImages(repo.imageDeletionTargets()) {} }.isFailure); assertTrue(fixture.writes.isEmpty())
        fixture.controls = listOf(JsonObject(fixture.controls.single() - "image")); assertTrue(runCatching { repo.imageDeletionTargets() }.isFailure)
    }
    @Test fun `裸映像不能带走其他标签标签重新指向不认领旧删除`() = runBlocking {
        val fixture = ContainerFixture(); val bare = JsonObject(ContainerFixture.image(tags = emptyList()) + ("tag" to JsonPrimitive("<none>")))
        fixture.images = listOf(bare, ContainerFixture.image()); val repo = fixture.repository().containerManagement
        val bareTarget = repo.imageDeletionTargets().single { it.tag == "<none>" }
        assertTrue(runCatching { repo.deleteImages(listOf(bareTarget)) {} }.isFailure); assertTrue(fixture.writes.isEmpty())
        fixture.images = listOf(ContainerFixture.image()); val target = repo.imageDeletionTargets().single()
        fixture.images = listOf(ContainerFixture.image(id = "replacement"))
        assertTrue(runCatching { repo.deleteImages(listOf(target)) {} }.isFailure)
        assertTrue(repo.removedImages(listOf(target.identity())).isEmpty())
    }
    @Test fun `畸形分页标签及源标识不冒充空列表`() = runBlocking {
        for (change in listOf<(ContainerFixture) -> Unit>({ it.imageTotal = 2 }, {
            it.images = listOf(JsonObject(it.images.single() + ("tags" to JsonPrimitive(false))))
        }, { it.images = it.images + it.images }, { it.images = listOf(JsonObject(it.images.single() - "id")) })) {
            val fixture = ContainerFixture(); change(fixture); assertTrue(runCatching { fixture.repository().containerManagement.imageDefinitions() }.isFailure)
        }
    }
    @Test fun `标签类型与多根冲突不静默忽略`() = runBlocking {
        for (tags in listOf(JsonPrimitive("stable"), JsonArray(listOf(JsonPrimitive(12))), JsonArray(listOf(ContainerFixture.obj("""{"name":"stable","tag":"other"}"""))))) {
            val fixture = ContainerFixture().apply { registryTags = tags }
            assertTrue(runCatching { fixture.repository().containerManagement.registryTags("synthetic/image") }.isFailure)
        }
    }
    @Test fun `下载回执保留字符串数字类型拒绝不安全数字`() = runBlocking {
        for ((raw, expected) in listOf(JsonPrimitive("007") to ContainerImageTaskId("007", false), JsonPrimitive(7) to ContainerImageTaskId("7", true),
            JsonPrimitive(true) to null, JsonPrimitive(1.2) to null, JsonPrimitive(9_007_199_254_740_992L) to null)) {
            val fixture = ContainerFixture().apply { taskId = raw }; val repo = fixture.repository().containerManagement
            val plan = repo.prepareImagePull("synthetic/image", "stable"); var saved: ContainerImageTaskId? = null
            val returned = repo.startImagePull(plan) { stage, id -> if (stage == ContainerStage.ACCEPTED) saved = id }
            assertEquals(expected, returned); assertEquals(expected, saved); assertEquals(1, fixture.writes.size)
            expected?.let { repo.readImagePull(plan.reference, it); assertEquals(raw, fixture.calls.single { it.method == "pull_status" }.fields["task_id"]) }
        }
    }
    @Test fun `旧标签不证明下载结束结束必须原生布尔回显与完整映像同时匹配`() = runBlocking {
        val fixture = ContainerFixture().apply { pullFinished = JsonPrimitive(false) }; val repo = fixture.repository().containerManagement
        val plan = repo.prepareImagePull("synthetic/image", "stable"); val task = repo.startImagePull(plan) { _, _ -> }!!
        assertFalse(repo.readImagePull(plan.reference, task).finished)
        fixture.pullFinished = JsonPrimitive("true"); assertTrue(runCatching { repo.readImagePull(plan.reference, task) }.isFailure)
        fixture.pullFinished = JsonPrimitive(true); fixture.pullTag = "other"; assertTrue(runCatching { repo.readImagePull(plan.reference, task) }.isFailure)
        fixture.pullTag = "stable"; fixture.applyPullResult = false; fixture.images = emptyList(); assertTrue(runCatching { repo.readImagePull(plan.reference, task) }.isFailure)
        assertEquals(1, fixture.writes.size)
    }
    @Test fun `任务1202为失败但完成清单1202仍是读取失败`() = runBlocking {
        val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement; val plan = repo.prepareImagePull("synthetic/image", "stable"); val task = repo.startImagePull(plan) { _, _ -> }!!
        fixture.errors = mapOf(("SYNO.Docker.Image" to "pull_status") to 1202); assertTrue(repo.readImagePull(plan.reference, task).failed)
        fixture.errors = mapOf(("SYNO.Docker.Image" to "list") to 1202); assertTrue(runCatching { repo.readImagePull(plan.reference, task) }.isFailure)
    }
    @Test fun `删除和下载写前及回执记录失败不继续请求`() = runBlocking {
        for (pull in listOf(true, false)) for (stage in listOf(ContainerStage.SUBMITTED, ContainerStage.ACCEPTED)) {
            val fixture = ContainerFixture(); val repo = fixture.repository().containerManagement
            val failed = runCatching {
                if (pull) repo.startImagePull(repo.prepareImagePull("synthetic/image", "stable")) { current, _ -> if (current == stage) throw IOException("Synthetic storage") }
                else repo.deleteImages(repo.imageDeletionTargets()) { current -> if (current == stage) throw IOException("Synthetic storage") }
            }.isFailure
            assertTrue(failed); assertEquals(if (stage == ContainerStage.SUBMITTED) 0 else 1, fixture.writes.size)
            if (stage == ContainerStage.ACCEPTED) assertEquals(if (pull) "pull_start" else "delete", fixture.calls.last().method)
        }
    }
}
