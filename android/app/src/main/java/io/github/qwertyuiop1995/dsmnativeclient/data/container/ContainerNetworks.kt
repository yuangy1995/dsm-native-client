package io.github.qwertyuiop1995.dsmnativeclient.data.container

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.isValidIpv4
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*
import java.net.InetAddress

internal enum class ContainerNetworkIssue { NAME, IPV4, IPV6, OUTSIDE_SUBNET }
internal data class ContainerNetworkDraft(val name: String = "", val manualIpv4: Boolean = false,
    val subnet: String = "", val range: String = "", val gateway: String = "", val ipv6: Boolean = false,
    val ipv6Subnet: String = "", val ipv6Range: String = "", val ipv6Gateway: String = "", val disableMasquerade: Boolean = false) {
    val issue: ContainerNetworkIssue? get() {
        if (!name.matches(Regex("[A-Za-z0-9][A-Za-z0-9_.-]*"))) return ContainerNetworkIssue.NAME
        if (manualIpv4) networkAddressIssue(subnet, range, gateway, false)?.let { return it }
        if (ipv6) networkAddressIssue(ipv6Subnet, ipv6Range, ipv6Gateway, true)?.let { return it }
        return null
    }
    fun parameters(): Map<String, JsonElement> = buildMap {
        put("name", JsonPrimitive(name)); put("enable_ipv6", JsonPrimitive(ipv6)); put("disable_masquerade", JsonPrimitive(disableMasquerade))
        if (manualIpv4) { put("subnet", JsonPrimitive(subnet)); put("iprange", JsonPrimitive(range)); put("gateway", JsonPrimitive(gateway)) }
        if (ipv6) { put("ipv6_subnet", JsonPrimitive(ipv6Subnet)); put("ipv6_iprange", JsonPrimitive(ipv6Range)); put("ipv6_gateway", JsonPrimitive(ipv6Gateway)) }
    }
}
private fun networkAddress(value: String, ipv6: Boolean): ByteArray? {
    if (!ipv6) return if (isValidIpv4(value)) value.split('.').map { it.toInt().toByte() }.toByteArray() else null
    if (':' !in value || !value.matches(Regex("[0-9a-fA-F:.]+"))) return null
    // 只交给 Java 解析已限定字符的 IPv6 字面量，不触发主机名查询。
    return runCatching { InetAddress.getByName(value).address }.getOrNull()?.let { bytes ->
        if (bytes.size == 16) bytes else if (bytes.size == 4 && value.contains("ffff", true)) ByteArray(10) + byteArrayOf(-1, -1) + bytes else null
    }
}
private fun networkCidr(value: String, ipv6: Boolean): Pair<ByteArray, Int>? {
    val parts = value.split('/'); if (parts.size != 2) return null
    val prefix = parts[1].toIntOrNull()?.takeIf { it.toString() == parts[1] && it in 0..if (ipv6) 128 else 32 } ?: return null
    return (networkAddress(parts[0], ipv6) ?: return null) to prefix
}
private fun withinNetwork(bytes: ByteArray, network: Pair<ByteArray, Int>) = bytes.indices.all { index ->
    val bits = (network.second - index * 8).coerceIn(0, 8)
    val mask = if (bits == 0) 0 else (255 shl (8 - bits)) and 255
    (bytes[index].toInt() and mask) == (network.first[index].toInt() and mask)
}
private fun networkAddressIssue(subnet: String, range: String, gateway: String, ipv6: Boolean): ContainerNetworkIssue? {
    val invalid = if (ipv6) ContainerNetworkIssue.IPV6 else ContainerNetworkIssue.IPV4
    val network = networkCidr(subnet, ipv6) ?: return invalid
    val router = networkAddress(gateway, ipv6) ?: return invalid
    if (!ipv6 && (router[0].toInt() and 255) !in 1..223) return invalid
    if (!withinNetwork(router, network)) return ContainerNetworkIssue.OUTSIDE_SUBNET
    if (range.isNotEmpty()) {
        val pool = networkCidr(range, ipv6) ?: return invalid
        if (pool.second < network.second || !withinNetwork(pool.first, network)) return ContainerNetworkIssue.OUTSIDE_SUBNET
    }
    return null
}

internal data class ContainerNetworkEntry(val id: String, val name: String, val driver: String, val containerCount: Int,
    val containers: List<String>?, val ipv6: Boolean?, val subnet: String?, val range: String?, val gateway: String?, val deletion: JsonObject) {
    val canDelete get() = name !in setOf("bridge", "host", "none") && containerCount == 0
}
@Serializable internal data class ContainerNetworkIdentity(val id: String?, val name: String, val configuration: String,
    val ipv4: String? = null, val ipv6: Boolean? = null) {
    fun overlaps(other: ContainerNetworkIdentity) = name == other.name || id != null && id == other.id
}
private fun networkFields(values: List<String>) = containerDigest(JsonArray(values.map(::JsonPrimitive)).toString())
internal fun ContainerNetworkDraft.identity() = ContainerNetworkIdentity(null, containerDigest(name), containerDigest(JsonObject(parameters()).toString()),
    if (manualIpv4) networkFields(listOf(subnet, range, gateway)) else null, ipv6)
internal fun ContainerNetworkEntry.identity() = ContainerNetworkIdentity(containerDigest(id), containerDigest(name), containerDigest(deletion.toString()))
internal fun ContainerNetworkIdentity.matches(entry: ContainerNetworkEntry) = name == containerDigest(entry.name) && entry.driver == "bridge" &&
    entry.ipv6 == ipv6 && (ipv4 == null || ipv4 == networkFields(listOf(entry.subnet.orEmpty(), entry.range.orEmpty(), entry.gateway.orEmpty())))

internal suspend fun ContainerRepository.networkDefinitions(): List<ContainerNetworkEntry> {
    val data = managementCall("SYNO.Docker.Network", "list")
    val roots = listOf("network", "networks").mapNotNull { data[it] }
    if (roots.isEmpty() || roots.distinct().size != 1) containerInvalid()
    val rows = containerRows(JsonObject(data + ("network" to roots.first())), "network")
    val entries = rows.map { row ->
        fun text(vararg keys: String): String? {
            val values = keys.mapNotNull { row[it] }; if (values.isEmpty()) return null
            val parsed = values.map { value -> (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: containerInvalid() }.distinct()
            if (parsed.size != 1) containerInvalid(); return parsed.single()
        }
        val id = text("id", "network_id", "Id")?.takeIf { it.isNotBlank() } ?: containerInvalid()
        val name = text("name", "Name")?.takeIf { it.isNotBlank() } ?: containerInvalid()
        val driver = text("driver", "Driver", "type")?.takeIf { it.isNotBlank() } ?: containerInvalid()
        val containers = row["containers"]?.let { value -> (value as? JsonArray)?.map { it.containerString() ?: containerInvalid() } ?: containerInvalid() }
        val counts = listOf("container_count", "containers_count", "using").mapNotNull { row[it] }.map { raw ->
            val primitive = raw as? JsonPrimitive ?: containerInvalid()
            primitive.content.takeIf { !primitive.isString || it.all(Char::isDigit) }?.toIntOrNull()?.takeIf { it >= 0 } ?: containerInvalid()
        }
        val count = containers?.size ?: counts.firstOrNull() ?: containerInvalid()
        if (counts.any { it != count } || containers?.distinct()?.size?.let { it != count } == true) containerInvalid()
        val ipv6 = row["enable_ipv6"].containerBool()
        val deletion = buildJsonObject {
            put("id", id); put("_key", id); put("name", name); put("driver", driver); put("containers", JsonArray(containers.orEmpty().map(::JsonPrimitive)))
            put("enable_ipv6", ipv6 ?: false); put("disable_masquerade", row["disable_masquerade"].containerBool() ?: false)
            listOf("subnet", "gateway", "iprange", "ipv6_subnet", "ipv6_gateway", "ipv6_iprange").forEach { put(it, text(it).orEmpty()) }
        }
        ContainerNetworkEntry(id, name, driver, count, containers, ipv6,
            text("subnet")?.takeIf { networkCidr(it, false) != null }, text("iprange")?.takeIf { networkCidr(it, false) != null },
            text("gateway")?.takeIf { networkAddress(it, false) != null }, deletion)
    }
    if (entries.map { it.id }.distinct().size != entries.size || entries.map { it.name }.distinct().size != entries.size) containerInvalid()
    return entries
}

internal suspend fun ContainerRepository.createNetwork(draft: ContainerNetworkDraft, checkpoint: (ContainerStage) -> Unit) {
    if (!managementLock.tryLock()) containerConflict()
    var submitted = false
    try {
        if (draft.issue != null || networkDefinitions().any { it.name == draft.name }) containerConflict()
        requireManagementWrite(); currentCoroutineContext().ensureActive()
        checkpoint(ContainerStage.SUBMITTED); submitted = true
        try { managementCall("SYNO.Docker.Network", "create", draft.parameters(), write = true) }
        catch (error: Exception) { if (containerExplicitRejection(error)) checkpoint(ContainerStage.REJECTED); throw error }
        checkpoint(ContainerStage.ACCEPTED)
        if (networkDefinitions().any(draft.identity()::matches)) checkpoint(ContainerStage.VERIFIED)
    } catch (error: Exception) { if (!submitted) checkpoint(ContainerStage.CANCELLED); throw error }
    finally { managementLock.unlock() }
}
internal suspend fun ContainerRepository.deleteNetwork(target: ContainerNetworkEntry, checkpoint: (ContainerStage) -> Unit) {
    if (!managementLock.tryLock()) containerConflict()
    var submitted = false
    try {
        val current = networkDefinitions().singleOrNull { it.id == target.id } ?: containerConflict()
        if (current != target || !current.canDelete) containerConflict()
        requireManagementWrite(); currentCoroutineContext().ensureActive()
        checkpoint(ContainerStage.SUBMITTED); submitted = true
        val response = try { managementCall("SYNO.Docker.Network", "remove", mapOf("networks" to JsonArray(listOf(current.deletion))), write = true) }
        catch (error: Exception) { if (containerExplicitRejection(error)) checkpoint(ContainerStage.REJECTED); throw error }
        val failed = response["failed"] as? JsonArray ?: containerInvalid()
        if (failed.isNotEmpty()) { checkpoint(ContainerStage.REJECTED); containerConflict() }
        checkpoint(ContainerStage.ACCEPTED)
        if (networkDefinitions().none { it.id == target.id }) checkpoint(ContainerStage.VERIFIED)
    } catch (error: Exception) { if (!submitted) checkpoint(ContainerStage.CANCELLED); throw error }
    finally { managementLock.unlock() }
}
