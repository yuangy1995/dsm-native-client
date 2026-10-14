package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import java.io.IOException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test

class VmmAssetsRepositoryTest {
    private val fixture = VmmFixture(); private val stages = mutableListOf<VmmStage>()
    @Test fun `网络读取详情关联关机虚拟机且重命名保留原拓扑参数`() = runBlocking {
        for (format in listOf("JSON", "FORM")) for (type in listOf("external", "private")) {
            fixture.format = format; fixture.calls.clear(); stages.clear()
            fixture.networks = listOf(VmmFixture.network(type = type, count = 1)); fixture.networkGuests = listOf(VmmFixture.networkGuest())
            val repo = fixture.repository().virtualMachineManagement; val network = repo.networkInventory().networks.single()
            assertFalse(network.guests.single().running)
            repo.mutateNetwork(network, "Renamed", stages::add)
            assertEquals(VmmStage.VERIFIED, stages.last()); val write = fixture.writes.single()
            assertEquals("set", write.method); assertEquals(1, write.version); assertTrue(write.oneShot)
            assertEquals(JsonPrimitive("Renamed"), write.fields["name"]); assertFalse(write.fields.containsKey("vlan_id"))
            if (type == "external") {
                assertEquals(setOf("network_id", "name", "interfaces_add", "interfaces_remove"), write.fields.keys)
                assertEquals(JsonArray(emptyList()), write.fields["interfaces_add"]); assertEquals(JsonArray(emptyList()), write.fields["interfaces_remove"])
            } else { assertEquals(setOf("network_id", "name", "host_id"), write.fields.keys); assertEquals(JsonPrimitive("host-1"), write.fields["host_id"]) }
        }
    }
    @Test fun `网络删除保留固定单ID和关联信息确认`() = runBlocking {
        fixture.networks = listOf(VmmFixture.network(count = 1)); fixture.networkGuests = listOf(VmmFixture.networkGuest(running = true))
        val repo = fixture.repository().virtualMachineManagement; val target = repo.networkInventory().networks.single()
        repo.mutateNetwork(target, null, stages::add)
        assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.ACCEPTED, VmmStage.VERIFIED), stages)
        assertEquals(mapOf("network_id" to JsonPrimitive("network-1")), fixture.writes.single().fields)
    }
    @Test fun `冻结名称碰撞拓扑或关联变化阻止网络写入`() = runBlocking {
        val repo = fixture.repository().virtualMachineManagement; val target = repo.networkInventory().networks.single()
        fixture.frozen = JsonPrimitive(true)
        assertTrue(runCatching { repo.mutateNetwork(target, "Renamed", stages::add) }.isFailure)
        fixture.frozen = JsonPrimitive(false); fixture.networks += VmmFixture.network("network-2", "Renamed")
        assertTrue(runCatching { repo.mutateNetwork(target, "renamed", stages::add) }.isFailure)
        fixture.networks = listOf(VmmFixture.network(type = "private"))
        assertTrue(runCatching { repo.mutateNetwork(target, null, stages::add) }.isFailure)
        fixture.networks = listOf(VmmFixture.network(count = 1)); fixture.networkGuests = listOf(VmmFixture.networkGuest())
        assertTrue(runCatching { repo.mutateNetwork(target, null, stages::add) }.isFailure); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `错误网络详情重复ID计数与非原生冻结字段拒绝`() = runBlocking {
        val repo = fixture.repository().virtualMachineManagement
        fixture.networkDetailOverride = VmmFixture.obj("""{"name":"Other","interfaces":[],"guests":[]}""")
        assertTrue(runCatching { repo.networkInventory() }.isFailure); fixture.networkDetailOverride = null
        fixture.networks += fixture.networks.single(); assertTrue(runCatching { repo.networkInventory() }.isFailure)
        fixture.networks = listOf(VmmFixture.network(count = 1)); assertTrue(runCatching { repo.networkInventory() }.isFailure)
        fixture.networks = listOf(VmmFixture.network()); fixture.frozen = JsonPrimitive("false")
        assertTrue(runCatching { repo.networkInventory() }.isFailure)
    }
    @Test fun `网络接受后改名同名但关联变化不认领拓扑结果`() = runBlocking {
        val repo = fixture.repository().virtualMachineManagement; val target = repo.networkInventory().networks.single()
        fixture.after = { if (it.method == "set") fixture.networks = listOf(VmmFixture.network(name = "Renamed", type = "private")) }
        repo.mutateNetwork(target, "Renamed", stages::add); assertEquals(VmmStage.ACCEPTED, stages.last())
    }
    @Test fun `公开映像固定v1image_id内部固定v2id及唯一UUID`() = runBlocking {
        for (public in listOf(true, false)) {
            fixture.public = public; fixture.calls.clear(); fixture.images = listOf(VmmFixture.image()); stages.clear()
            val repo = fixture.repository().virtualMachineManagement; val target = repo.imageInventory().images.single()
            repo.deleteImage(target, stages::add); assertEquals(VmmStage.VERIFIED, stages.last())
            val write = fixture.writes.single(); assertTrue(write.oneShot); assertEquals(if (public) 1 else 2, write.version)
            assertEquals(JsonPrimitive("image-1"), write.fields[if (public) "image_id" else "id"])
            if (public) assertEquals(setOf("image_id"), write.fields.keys)
            else { assertEquals(setOf("id", "synovmm_ui_id"), write.fields.keys); assertNotNull(java.util.UUID.fromString(write.fields.getValue("synovmm_ui_id").jsonPrimitive.content)) }
        }
    }
    @Test fun `内部映像合并副本停止虚拟机仍占用ISO`() = runBlocking {
        fixture.public = false; fixture.images = listOf(VmmFixture.image(type = "iso"), VmmFixture.image(type = "iso", host = "host-2"))
        fixture.isoImages = JsonArray(listOf(JsonPrimitive("image-1")))
        val repo = fixture.repository().virtualMachineManagement; val target = repo.imageInventory().images.single()
        assertEquals(2, target.copies.size); assertTrue(target.inUse == true); assertFalse(target.canDelete)
        assertTrue(runCatching { repo.deleteImage(target, stages::add) }.isFailure); assertTrue(fixture.writes.isEmpty())
        fixture.isoImages = JsonArray(listOf(JsonPrimitive("unmounted")))
        assertTrue(repo.imageInventory().images.single().canDelete)
    }
    @Test fun `副本重复身份冲突缺占用和不完整列表拒绝`() = runBlocking {
        fixture.public = false; val repo = fixture.repository().virtualMachineManagement
        fixture.images += fixture.images.single(); assertTrue(runCatching { repo.imageInventory() }.isFailure)
        fixture.images = listOf(VmmFixture.image(), VmmFixture.image(name = "Other", host = "host-2")); assertTrue(runCatching { repo.imageInventory() }.isFailure)
        fixture.images = listOf(VmmFixture.image(type = "iso")); fixture.isoImages = JsonNull; assertTrue(runCatching { repo.imageInventory() }.isFailure)
        fixture.images = emptyList(); fixture.imageTotal = 1; assertTrue(runCatching { repo.imageInventory() }.isFailure)
    }
    @Test fun `公开无名字只读内部冻结及副本故障不允许删除`() = runBlocking {
        fixture.images = listOf(JsonObject(VmmFixture.image() - "image_name")); assertFalse(fixture.repository().virtualMachineManagement.imageInventory().images.single().canDelete)
        fixture.public = false; fixture.images = listOf(JsonObject(VmmFixture.image() + ("status" to JsonPrimitive("offline"))))
        assertFalse(fixture.repository().virtualMachineManagement.imageInventory().images.single().canDelete)
        fixture.images = listOf(VmmFixture.image()); val repo = fixture.repository().virtualMachineManagement; val target = repo.imageInventory().images.single(); fixture.imageFrozen = JsonPrimitive(true)
        assertTrue(runCatching { repo.deleteImage(target, stages::add) }.isFailure); assertTrue(fixture.writes.isEmpty())
    }
    @Test fun `网络及映像断网与拒绝不转为已接受且不读取后续`() = runBlocking {
        val repo = fixture.repository().virtualMachineManagement; val network = repo.networkInventory().networks.single()
        fixture.before = { if (it.method == "delete") throw IOException("lost response") }
        assertTrue(runCatching { repo.mutateNetwork(network, null, stages::add) }.isFailure); assertEquals(listOf(VmmStage.SUBMITTED), stages)
        fixture.before = {}; fixture.rejection = 105; stages.clear(); val image = repo.imageInventory().images.single()
        assertTrue(runCatching { repo.deleteImage(image, stages::add) }.isFailure); assertEquals(listOf(VmmStage.SUBMITTED, VmmStage.REJECTED), stages)
        assertEquals("delete", fixture.calls.last().method)
    }
}
