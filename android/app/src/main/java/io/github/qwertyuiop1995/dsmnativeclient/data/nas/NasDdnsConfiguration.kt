package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.Locale
import java.net.InetAddress
import java.net.Inet6Address

internal fun NasDdnsDraft.normalized() = copy(
    originalProviderId = originalProviderId?.trim()?.takeIf(String::isNotEmpty),
    providerId = providerId.trim(),
    hostname = hostname.trim().lowercase(Locale.ROOT),
    username = username.trim(),
)

internal fun isValidDdnsDraft(value: NasDdnsDraft): Boolean =
    isSafeDdnsProviderId(value.providerId) &&
        isValidDdnsHostname(value.hostname) &&
        isValidDdnsReadableFields(
            value.username,
            value.networkType,
            value.ipv4,
            value.ipv6,
            value.interfaceV4,
            value.interfaceV6,
        ) &&
        value.password.length <= 1_024 && !value.password.hasDdnsControlCharacter() &&
        (value.originalProviderId != null || value.providerId == "Synology" || value.password.isNotEmpty()) &&
        value.originalProviderId?.let(::isSafeDdnsProviderId) != false

internal fun isValidDdnsReadableFields(
    username: String,
    networkType: String,
    ipv4: String,
    ipv6: String,
    interfaceV4: String,
    interfaceV6: String,
): Boolean = username.isNotBlank() && username.length <= 1_024 &&
    !username.hasDdnsControlCharacter() && networkType.isNotBlank() && networkType.length <= 64 &&
    !networkType.hasDdnsControlCharacter() && isValidDdnsIpv4(ipv4) && isValidDdnsIpv6(ipv6) &&
    interfaceV4.length <= 128 && !interfaceV4.hasDdnsControlCharacter() &&
    interfaceV6.length <= 128 && !interfaceV6.hasDdnsControlCharacter()

internal fun String.hasDdnsControlCharacter(): Boolean = any(Char::isISOControl)

internal fun isValidDdnsIpv4(value: String): Boolean = value.length <= 15 &&
    value.split('.').let { parts ->
        parts.size == 4 && parts.all { part ->
            part.isNotEmpty() && part.length <= 3 && part.all(Char::isDigit) &&
                part.toIntOrNull() in 0..255
        }
    }

internal fun isValidDdnsIpv6(value: String): Boolean = value.length in 2..64 &&
    value.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' || it == ':' || it == '.' } &&
    runCatching { InetAddress.getByName(value) is Inet6Address }.getOrDefault(false)

internal fun isSafeDdnsProviderId(value: String): Boolean =
    value.isNotBlank() && value.length <= 128 &&
        value.all { it.isLetterOrDigit() || it in "._- " }

internal fun isValidDdnsHostname(value: String): Boolean {
    if (value.isBlank() || value.length > 253 || value.startsWith('.') || value.endsWith('.') ||
        ".." in value || value.any { it.isWhitespace() || !(it.isLetterOrDigit() || it == '.' || it == '-') }
    ) return false
    return value.split('.').all { label ->
        label.isNotEmpty() && label.length <= 63 && !label.startsWith('-') && !label.endsWith('-')
    }
}
