package io.github.qwertyuiop1995.dsmnativeclient.domain

import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.Serializable
import java.net.URI
import java.util.Locale

internal data class FileVFSProtocol(val id: String, val name: String, val defaultPort: Int?, val hasConnections: Boolean) {
    val supportsServerSetup get() = id in setOf("ftp", "sftp", "dav", "davs")
    val supportsCloudAuthorization get() = id in setOf("google", "dropbox", "baidu", "onedrive", "box")
}

@Serializable internal enum class FileVFSConnectionState { CONNECTED, DISCONNECTED, UNKNOWN }

/** 远程身份保留 NAS 返回的不透明 id 和 URI，不从名称或主机拼接。 */
@Serializable
internal data class FileVFSProfile(
    val owner: WorkspaceOwner, val id: String, val protocolId: String, val protocolName: String, val uri: String,
    val hostname: String?, val port: Int?, val alias: String, val account: String?, val codepage: String?,
    val state: FileVFSConnectionState,
) {
    fun sameIdentity(other: FileVFSProfile) = owner.hasSameIdentity(other.owner) && id == other.id &&
        protocolId == other.protocolId && uri == other.uri && hostname == other.hostname && port == other.port &&
        alias == other.alias && account == other.account && codepage == other.codepage
    fun sameSnapshot(other: FileVFSProfile) = sameIdentity(other) && state == other.state
    fun matches(setup: FileVFSConfiguration) = protocolId == setup.protocolId && hostname == setup.hostname &&
        port == setup.port && alias == setup.alias && account == setup.account && codepage == setup.codepage
    override fun toString() = "FileVFSProfile($state)"
}

/** 非凭据字段才可进入恢复记录；密码和云令牌不属于配置。 */
@Serializable
internal data class FileVFSConfiguration(
    val protocolId: String = "", val hostname: String = "", val port: Int = 0, val alias: String = "",
    val account: String = "", val codepage: String = "UTF-8", val folder: String = "", val usesOneConnection: Boolean = false,
) {
    val usesCleartext get() = protocolId == "ftp" || protocolId == "dav"
    override fun toString() = "FileVFSConfiguration"

    fun resolved(protocols: List<FileVFSProtocol>, editingProtocol: String? = null): FileVFSConfiguration {
        var result = copy(hostname = hostname.trim(), alias = alias.trim())
        if (result.hostname.contains("://")) {
            val uri = URI(result.hostname)
            require(uri.host != null && uri.rawUserInfo == null && uri.rawQuery == null && uri.rawFragment == null)
            val selected = when (uri.scheme?.lowercase(Locale.ROOT)) {
                "ftp" -> "ftp".takeIf { protocolId == "ftp" }
                "sftp" -> "sftp".takeIf { protocolId == "sftp" }
                "http", "dav" -> "dav".takeIf { protocolId in setOf("dav", "davs") }
                "https", "davs" -> "davs".takeIf { protocolId in setOf("dav", "davs") }
                else -> null
            } ?: throw IllegalArgumentException("Address protocol does not match")
            val option = protocols.singleOrNull { it.id == selected && it.supportsServerSetup }
                ?: throw IllegalArgumentException("Protocol is unavailable")
            require(editingProtocol == null || selected == editingProtocol)
            val resolvedPort = when {
                uri.port != -1 -> uri.port
                port == 0 || port == protocols.singleOrNull { it.id == protocolId }?.defaultPort -> option.defaultPort
                    ?: when (selected) { "davs" -> 443; "dav" -> 80; else -> port }
                else -> port
            }
            val path = uri.path.orEmpty().trim('/')
            if (path.isNotEmpty()) {
                require(selected in setOf("dav", "davs") && (folder.isEmpty() || folder.trim('/') == path))
            }
            result = result.copy(protocolId = selected, hostname = uri.host, port = resolvedPort,
                folder = if (path.isEmpty()) result.folder else path)
        }
        require(protocols.any { it.id == result.protocolId && it.supportsServerSetup })
        require(editingProtocol == null || result.protocolId == editingProtocol)
        val address = URI("https://${result.hostname}")
        require(result.hostname.isNotEmpty() && address.host != null && address.port == -1 &&
            result.hostname.none { it.isWhitespace() || it.isISOControl() || it in "/\\@?#" })
        require(result.port in 1..65535 && result.alias.isNotEmpty() && result.alias.length <= 255 && result.codepage.isNotEmpty())
        require(listOf(result.alias, result.account, result.codepage, result.folder).none { value -> value.any(Char::isISOControl) })
        // 隐藏的高级字段仍保留 NAS 已保存的值；不因当前表单未显示而重置它们。
        return result.copy(folder = if (result.protocolId in setOf("dav", "davs")) result.folder.trimStart('/') else result.folder)
    }
}

@Serializable
internal data class FileVFSDetail(val profile: FileVFSProfile, val configuration: FileVFSConfiguration) {
    override fun toString() = "FileVFSDetail"
}

/** 远程 URI 仅在原始连接根下导航，不解码或重写路径。 */
internal fun fileVFSPathBelongsTo(path: String, profile: FileVFSProfile): Boolean {
    val root = profile.uri.removeSuffix("/")
    if (root.isEmpty() || !root.startsWith(profile.protocolId + "://") || path.any(Char::isISOControl) ||
        (path != root && !path.startsWith("$root/"))) return false
    return path.removePrefix(root).split('/').none { it == "." || it == ".." }
}
