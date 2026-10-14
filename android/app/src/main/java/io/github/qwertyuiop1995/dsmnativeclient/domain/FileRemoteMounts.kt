package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable
import java.net.URI

@Serializable
internal enum class RemoteMountStage {
    CHECK_CONNECTION, CHECK_DISCONNECTION, READY_TO_CONNECT, READY_TO_DISCONNECT;
    val canContinue get() = this == READY_TO_CONNECT || this == READY_TO_DISCONNECT
}

/** 非密码配置可用于分步恢复；目录名称保留用户选择的原始空白。 */
@Serializable
internal data class FileRemoteMountSetup(
    val kind: FileMountKind = FileMountKind.CIFS, val server: String = "", val remotePath: String = "",
    val mountPoint: String = "", val username: String = "", val domain: String = "",
    val nfsVersion: String = "3", val nfsTransport: String = "tcp", val automatic: Boolean = false,
) {
    val source get() = if (kind == FileMountKind.CIFS) "//$server/$remotePath" else "$server:/$remotePath"
    val connection get() = FileMountConnection(kind, source, mountPoint, automatic)
    override fun toString() = "FileRemoteMountSetup"

    fun normalized(): FileRemoteMountSetup {
        val server = server.trim(' ').lowercase(java.util.Locale.ROOT)
        val path = (if (kind == FileMountKind.CIFS) remotePath.replace('\\', '/') else remotePath).trim('/')
        val username = username.trim(' '); val domain = domain.trim(' ')
        val address = runCatching { URI("https://$server") }.getOrNull()
        require(kind != FileMountKind.ISO && server.isNotEmpty() && server.toByteArray().size <= 256 && address?.host != null &&
            address.port == -1 && server.none { it.isWhitespace() || it.isISOControl() || it in "/\\@?#" } &&
            server.trim('[', ']') !in setOf("localhost", "127.0.0.1", "::1"))
        require(path.isNotEmpty() && path.toByteArray().size <= 4096 && !remotePath.startsWith("//") && !remotePath.startsWith("\\\\") &&
            path.none { it.isISOControl() || it == '\\' } && path.split('/').all { it.isNotEmpty() && it != "." && it != ".." })
        require(username.toByteArray().size <= 256 && domain.toByteArray().size <= 128 &&
            username.none(Char::isISOControl) && domain.none { it.isISOControl() || it in "\\/@" } &&
            (domain.isEmpty() || username.isNotEmpty() && username.none { it in "\\@" }))
        require(kind == FileMountKind.CIFS || username.isEmpty() && domain.isEmpty())
        require(nfsVersion in setOf("3", "4") && nfsTransport in setOf("tcp", "udp") &&
            (kind != FileMountKind.NFS || nfsVersion != "4" || nfsTransport == "tcp"))
        return copy(server = server, remotePath = path, username = username, domain = domain)
    }

    companion object {
        fun from(connection: FileMountConnection): FileRemoteMountSetup {
            val source = canonicalRemoteMountSource(connection.kind, connection.source)
            val (server, path) = if (connection.kind == FileMountKind.CIFS) source.removePrefix("//").let {
                it.substringBefore('/') to it.substringAfter('/')
            } else source.substringBefore(":/") to source.substringAfter(":/")
            return FileRemoteMountSetup(connection.kind, server, path, connection.mountPoint, automatic = connection.automatic == true)
        }
    }
}

/** 清单中服务器名称忽略大小写；共享路径大小写与空白保持身份含义。 */
internal fun canonicalRemoteMountSource(kind: FileMountKind, source: String): String {
    val normalized = if (kind == FileMountKind.CIFS) source.replace('\\', '/') else source
    val pair = when (kind) {
        FileMountKind.CIFS -> {
            require(normalized.startsWith("//"))
            val value = normalized.removePrefix("//")
            require('/' in value)
            value.substringBefore('/') to value.substringAfter('/')
        }
        FileMountKind.NFS -> { require(":/" in normalized); normalized.substringBefore(":/") to normalized.substringAfter(":/") }
        else -> error("Not a remote connection")
    }
    val server = pair.first; val path = pair.second
    val address = runCatching { URI("https://$server") }.getOrNull()
    require(server.isNotEmpty() && server.toByteArray().size <= 256 && address?.host != null && address.port == -1 &&
        server.none { it.isWhitespace() || it.isISOControl() || it in "/\\@?#" })
    require(path.isNotEmpty() && path.toByteArray().size <= 4096 && !path.startsWith('/') && !path.contains("//") &&
        path.none { it.isISOControl() || it == '\\' } && path.split('/').none { it == "." || it == ".." })
    return if (kind == FileMountKind.CIFS) "//${server.lowercase(java.util.Locale.ROOT)}/$path"
        else "${server.lowercase(java.util.Locale.ROOT)}:/$path"
}
