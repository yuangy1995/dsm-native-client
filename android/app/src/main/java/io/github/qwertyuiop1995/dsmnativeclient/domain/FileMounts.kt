package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable
internal enum class FileMountKind { ISO, CIFS, NFS }

@Serializable
internal data class FileMountConnection(
    val kind: FileMountKind, val source: String, val mountPoint: String, val automatic: Boolean?,
)

internal data class FileMountInventory(
    val isoEnabled: Boolean, val remoteEnabled: Boolean, val connections: List<FileMountConnection>,
) {
    val isoConnections get() = connections.filter { it.kind == FileMountKind.ISO }
    val remoteConnections get() = connections.filter { it.kind != FileMountKind.ISO }
}

/** 来源和目标为用户实际选择的快照；修改前重新读取，不把菜单条目当作授权。 */
internal sealed interface FileISOMountChange {
    val mountPoint: String
    data class Mount(val source: FileItem, val destination: FileItem, val automatic: Boolean = false) : FileISOMountChange {
        override val mountPoint get() = destination.path
    }
    data class Unmount(val connection: FileMountConnection) : FileISOMountChange {
        override val mountPoint get() = connection.mountPoint
    }
}
