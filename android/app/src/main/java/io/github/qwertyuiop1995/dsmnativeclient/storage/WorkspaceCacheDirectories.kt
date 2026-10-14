package io.github.qwertyuiop1995.dsmnativeclient.storage

import java.io.File
import java.security.MessageDigest
import java.util.UUID

/** 沿用现有缓存根目录，只在其内按账号身份隔离可再生成的文件。 */
internal class WorkspaceCacheDirectories(private val cache: File) {
    private var namespace = UUID.randomUUID().toString()
    val previews get() = File(cache, "preview/$namespace")
    val chatPreviews get() = File(cache, "chat-preview/$namespace")
    val thumbnails get() = File(cache, "file-thumbnails-v1/$namespace")

    fun bind(owner: WorkspaceOwner) {
        val identity = "${owner.profileId.length}:${owner.profileId}:${owner.identityRevision}"
        namespace = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
    }

    fun clearPreviews() {
        previews.listFiles()?.forEach(File::deleteRecursively)
        chatPreviews.listFiles()?.forEach(File::deleteRecursively)
    }
}
