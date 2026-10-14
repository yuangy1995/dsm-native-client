package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
import kotlinx.serialization.json.*

/** 仅保存所选物理网卡的配置；租约、连接状态与显示名不参与比较。 */
internal fun ethernetConfiguration(value: NasEthernetInterface): JsonArray {
    val config = buildMap<String, JsonElement> {
        put("ifname", JsonPrimitive(value.id))
        put("use_dhcp", JsonPrimitive(value.usesDhcp))
        put("is_default_gateway", JsonPrimitive(value.isDefaultGateway))
        put("mtu", JsonPrimitive(value.mtu))
        put("enable_vlan", JsonPrimitive(value.isVlanEnabled))
        if (!value.usesDhcp) {
            put("ip", JsonPrimitive(value.address))
            put("mask", JsonPrimitive(value.subnetMask))
            put("gateway", JsonPrimitive(value.gateway))
            put("dns", JsonPrimitive(value.dnsServers))
        }
        if (value.isVlanEnabled) put("vlan_id", JsonPrimitive(checkNotNull(value.vlanId)))
    }
    return JsonArray(listOf(JsonObject(config)))
}

internal fun isValidEthernetInterface(value: NasEthernetInterface): Boolean =
    isSafeEthernetId(value.id) &&
        value.mtu in 576..9_000 &&
        (!value.isVlanEnabled || value.vlanId?.let { it in 1..4_094 } == true) &&
        (value.usesDhcp || (
            isValidIpv4(value.address) &&
                isValidIpv4SubnetMask(value.subnetMask) &&
                (value.gateway.isEmpty() || isValidIpv4(value.gateway)) &&
                isValidEthernetDns(value.dnsServers)
            ))

internal fun NasEthernetInterface.normalizedEthernetInput(): NasEthernetInterface = copy(
    address = address.trim(),
    subnetMask = subnetMask.trim(),
    gateway = gateway.trim(),
    dnsServers = dnsServers.trim(),
)

internal fun isSafeEthernetId(value: String): Boolean =
    value.startsWith("eth") && value.matches(Regex("[A-Za-z0-9_-]+"))

internal fun isValidIpv4(value: String): Boolean {
    val parts = value.split('.', limit = 5)
    return parts.size == 4 && parts.all { part ->
        part.isNotEmpty() && part.length <= 3 && part.all(Char::isDigit) &&
            part.toIntOrNull()?.let { it in 0..255 } == true &&
            (part == "0" || !part.startsWith('0'))
    }
}

internal fun isValidIpv4SubnetMask(value: String): Boolean {
    if (!isValidIpv4(value)) return false
    val mask = value.split('.').fold(0L) { result, part ->
        (result shl 8) or checkNotNull(part.toLongOrNull())
    }
    val inverse = mask xor 0xFFFF_FFFFL
    return inverse and (inverse + 1L) == 0L
}

/** 当前证据仅确认空值或单个 IPv4；未知分隔格式不猜测、不提交。 */
internal fun isValidEthernetDns(value: String): Boolean =
    value.isEmpty() || (value.length <= 15 && isValidIpv4(value))
