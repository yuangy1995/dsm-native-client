package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*

@Serializable internal data class VmmNetworkInterface(val host: String, val id: String)
@Serializable internal data class VmmNetworkGuest(val id: String, val name: String, val running: Boolean,
    val prefersSriov: Boolean, val usesVf: Boolean, val mac: String, val interfaces: String)
@Serializable internal data class VmmNetwork(val id: String, val name: String, val type: String, val host: String, val vlan: Int,
    val interfaces: List<VmmNetworkInterface>, val guests: List<VmmNetworkGuest>) {
    val identity get() = vmmDigest(Json.encodeToString(this))
    val topology get() = vmmDigest(Json.encodeToString(copy(name = "")))
}
internal data class VmmNetworkInventory(val frozen: Boolean, val networks: List<VmmNetwork>)
internal fun validVmmNetworkName(name: String) = name.isNotEmpty() && name == name.trim() && name.length <= 127 && name.none(Char::isISOControl)
internal fun JsonObject.vmmString(key: String) = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content ?: vmmInvalid()
internal fun JsonObject.vmmRequiredText(key: String) = get(key).vmmText() ?: vmmInvalid()
internal fun JsonObject.vmmBool(key: String) = (get(key) as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull ?: vmmInvalid()
internal fun JsonObject.vmmInt(key: String) = (get(key) as? JsonPrimitive)?.takeIf { !it.isString }?.intOrNull?.takeIf { it >= 0 } ?: vmmInvalid()

/** list 绑定唯一身份和数量，get 仅补关联关系；瞬时吞吐指标不参与身份。 */
internal suspend fun VmmManagementRepository.networkInventory(): VmmNetworkInventory {
    val data = call("SYNO.Virtualization.Network", "list", 2)
    val frozen = data.vmmBool("is_freeze")
    val rows = vmmRows(data, "networks")
    val ids = mutableSetOf<String>(); val names = mutableSetOf<String>()
    val networks = rows.map { row ->
        val id = row.vmmRequiredText("network_id"); val name = row.vmmRequiredText("name")
        val type = row.vmmRequiredText("type"); val host = row.vmmString("host_id"); val vlan = row.vmmInt("vlan_id")
        if (!validVmmId(id) || !validVmmNetworkName(name) || !ids.add(id) || !names.add(name.lowercase(java.util.Locale.ROOT)) ||
            type !in setOf("external", "private") || type == "private" && !validVmmId(host) || vlan > 4094) vmmInvalid()
        val interfaces = vmmRows(row, "interfaces").map { value ->
            val hostId = value.vmmRequiredText("host_id"); val interfaceId = value.vmmRequiredText("interface_id")
            if (!validVmmId(hostId) || !validVmmId(interfaceId)) vmmInvalid()
            VmmNetworkInterface(hostId, interfaceId)
        }.sortedWith(compareBy({ it.host }, { it.id }))
        if (type == "external" && interfaces.isEmpty() || interfaces.distinct().size != interfaces.size || row.vmmInt("num_interfaces") != interfaces.size) vmmInvalid()
        row.vmmInt("num_hosts"); row.vmmInt("num_vinterfaces")
        val guestCount = row.vmmInt("num_guests")
        val detail = call("SYNO.Virtualization.Network", "get", 2, mapOf("network_id" to JsonPrimitive(id)))
        if (detail.vmmRequiredText("name") != name) vmmInvalid()
        vmmRows(detail, "interfaces")
        val guests = vmmRows(detail, "guests").map { guest ->
            VmmNetworkGuest(guest.vmmRequiredText("guest_id").also { if (!validVmmId(it)) vmmInvalid() }, guest.vmmRequiredText("name"),
                guest.vmmBool("running"), guest.vmmBool("prefer_sriov"), guest.vmmBool("use_vf"), guest.vmmString("mac_addr"), guest.vmmString("vinterface_names"))
        }.sortedBy { it.id }
        if (guests.size != guestCount || guests.map { it.id }.distinct().size != guests.size) vmmInvalid()
        VmmNetwork(id, name, type, host, vlan, interfaces, guests)
    }
    return VmmNetworkInventory(frozen, networks)
}

internal suspend fun VmmManagementRepository.mutateNetwork(expected: VmmNetwork, name: String?, checkpoint: (VmmStage) -> Unit) {
    if (!mutationLock.tryLock()) vmmConflict()
    var submitted = false
    try {
        if (name != null && (!validVmmNetworkName(name) || name == expected.name)) vmmConflict()
        requireWrite(VmmSource.INTERNAL)
        val inventory = networkInventory()
        if (inventory.frozen || inventory.networks.singleOrNull { it.id == expected.id } != expected ||
            name != null && inventory.networks.any { it.id != expected.id && it.name.equals(name, ignoreCase = true) }) vmmConflict()
        val fields = mutableMapOf<String, JsonElement>("network_id" to JsonPrimitive(expected.id))
        if (name != null) {
            fields["name"] = JsonPrimitive(name)
            if (expected.type == "external") { fields["interfaces_add"] = JsonArray(emptyList()); fields["interfaces_remove"] = JsonArray(emptyList()) }
            else fields["host_id"] = JsonPrimitive(expected.host)
        }
        currentCoroutineContext().ensureActive(); checkpoint(VmmStage.SUBMITTED); submitted = true
        try { call("SYNO.Virtualization.Network", if (name == null) "delete" else "set", 1, fields, write = true) }
        catch (error: Exception) { if (vmmExplicitRejection(error)) checkpoint(VmmStage.REJECTED); throw error }
        checkpoint(VmmStage.ACCEPTED)
        if (recoverNetwork(vmmDigest(expected.id), expected.topology, name?.let(::vmmDigest))) checkpoint(VmmStage.VERIFIED)
    } catch (error: Exception) { if (!submitted) checkpoint(VmmStage.CANCELLED); throw error }
    finally { mutationLock.unlock() }
}
internal suspend fun VmmManagementRepository.recoverNetwork(id: String, topology: String, name: String?): Boolean {
    val inventory = networkInventory(); if (inventory.frozen) return false
    val current = inventory.networks.singleOrNull { vmmDigest(it.id) == id }
    return if (name == null) current == null else current != null && vmmDigest(current.name) == name && current.topology == topology
}
