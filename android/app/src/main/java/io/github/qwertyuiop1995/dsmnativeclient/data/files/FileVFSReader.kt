package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.parseFilePageFixture
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.serialization.json.*

/** 只解码已记录的连接字段；Profile.get 中的密码永远不进入模型。 */
internal class FileVFSReader(
    private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
    private val owner: () -> WorkspaceOwner?, private val requireOwner: () -> Unit,
) {
    suspend fun protocols(): List<FileVFSProtocol> {
        requireOwner()
        val data = call(VFS_PROTOCOL_API, "list", emptyMap(), 1)
        val rows = data.vfsRows("protocols").map { row ->
            val id = row.vfsText("protocol")!!; val name = row.vfsText("name")!!
            if (id.isEmpty() || name.isEmpty()) throw vfsReadFailure()
            FileVFSProtocol(id, name, row.vfsInt("default_port", true), row.vfsBoolean("has_server"))
        }
        if (rows.map { it.id }.distinct().size != rows.size) throw vfsReadFailure()
        requireOwner(); return rows
    }

    suspend fun profiles(): List<FileVFSProfile> {
        requireOwner(); val identity = owner() ?: throw workspaceStorageFailure()
        val data = call(VFS_PROFILE_API, "list", emptyMap(), 1)
        val rows = data.vfsRows("profiles").map { row ->
            val id = row.vfsText("id")!!; val protocol = row.vfsText("protocol")!!
            if (id.isEmpty() || protocol.isEmpty()) throw vfsReadFailure()
            FileVFSProfile(identity, id, protocol, row.vfsText("protocol_name")!!, row.vfsText("uri")!!,
                row.vfsText("hostname", true), row.vfsInt("port", true), row.vfsText("alias")!!,
                row.vfsText("account", true), row.vfsText("codepage", true), when (row.vfsInt("connect_status")) {
                    1 -> FileVFSConnectionState.CONNECTED; 0 -> FileVFSConnectionState.DISCONNECTED; else -> FileVFSConnectionState.UNKNOWN
                })
        }
        if (rows.map { it.id }.distinct().size != rows.size || "total" in data && data.vfsInt("total") != rows.size) throw vfsReadFailure()
        requireOwner(); return rows
    }

    suspend fun requireProfile(profile: FileVFSProfile): FileVFSProfile {
        requireOwner()
        if (owner()?.hasSameIdentity(profile.owner) != true) throw vfsChanged()
        return profiles().singleOrNull { it.sameSnapshot(profile) } ?: throw vfsChanged()
    }

    suspend fun detail(profile: FileVFSProfile): FileVFSDetail {
        requireProfile(profile)
        if (profile.protocolId !in setOf("ftp", "sftp", "dav", "davs")) throw vfsChanged()
        val data = call(VFS_PROFILE_API, "get", mapOf("id" to profile.id), 1)
        val single = data.vfsInt("max_connection")
        if (single !in 0..1) throw vfsReadFailure()
        val configuration = FileVFSConfiguration(profile.protocolId, data.vfsText("hostname")!!,
            data.vfsInt("port")!!, data.vfsText("alias")!!, data.vfsText("account")!!, data.vfsText("codepage")!!,
            data.vfsText("uri_path")!!, single == 1)
        if (!profile.matches(configuration)) throw vfsChanged()
        requireOwner()
        return FileVFSDetail(profile, configuration.copy(hostname = configuration.hostname.trim(),
            folder = if (profile.protocolId in setOf("dav", "davs")) configuration.folder.trimStart('/') else configuration.folder))
    }

    suspend fun folder(profile: FileVFSProfile, path: String, offset: Int, limit: Int = 200): FilePage {
        if (profile.state != FileVFSConnectionState.CONNECTED || offset < 0 || limit !in 1..500 || !fileVFSPathBelongsTo(path, profile))
            throw vfsChanged()
        requireProfile(profile)
        val data = call("SYNO.FileStation.List", "list", mapOf("folder_path" to path, "offset" to offset.toString(), "limit" to limit.toString(),
            "sort_by" to "name", "sort_direction" to "asc", "additional" to mountStrings(listOf("size", "time", "perm"))), 2)
        val rows = data.vfsRows("files")
        val total = data.vfsInt("total")!!
        if (data.vfsInt("offset") != offset || total < offset + rows.size || rows.size > limit || rows.isEmpty() && total > offset)
            throw vfsReadFailure()
        rows.forEach { row ->
            val itemPath = row.vfsText("path")!!
            if (row.vfsText("name")!!.isEmpty() || itemPath == path || !fileVFSPathBelongsTo(itemPath, profile)) throw vfsReadFailure()
            row.vfsBoolean("isdir")
        }
        val page = parseFilePageFixture(data)
        if (page.items.map { it.path }.distinct().size != rows.size) throw vfsReadFailure()
        requireOwner(); return page
    }
}

internal const val VFS_PROTOCOL_API = "SYNO.FileStation.VFS.Protocol"
internal const val VFS_PROFILE_API = "SYNO.FileStation.VFS.Profile"
internal const val VFS_CONNECTION_API = "SYNO.FileStation.VFS.Connection"
internal fun vfsReadFailure() = DsmFailure(null, "Connections could not be read", "Refresh and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
internal fun vfsChanged() = DsmFailure(null, "The saved connection changed", "Refresh and choose it again.", kind = DsmErrorKind.FILE_VFS_CHANGED)

private fun JsonObject.vfsRows(key: String) = (this[key] as? JsonArray)?.map { it as? JsonObject ?: throw vfsReadFailure() } ?: throw vfsReadFailure()
private fun JsonObject.vfsText(key: String, optional: Boolean = false): String? {
    val value = this[key]
    if (optional && (value == null || value == JsonNull)) return null
    return (value as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw vfsReadFailure()
}
private fun JsonObject.vfsInt(key: String, optional: Boolean = false): Int? {
    val value = this[key]
    if (optional && (value == null || value == JsonNull)) return null
    return (value as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull ?: throw vfsReadFailure()
}
private fun JsonObject.vfsBoolean(key: String) = (this[key] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: throw vfsReadFailure()
