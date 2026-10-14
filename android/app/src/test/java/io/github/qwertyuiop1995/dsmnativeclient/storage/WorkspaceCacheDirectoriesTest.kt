package io.github.qwertyuiop1995.dsmnativeclient.storage

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class WorkspaceCacheDirectoriesTest {
    @Test fun `相同文件名和路径的两个账号不会共享缓存`() = withCache { root ->
        val first = WorkspaceCacheDirectories(root).apply { bind(WorkspaceOwner("same-connection", "account-a", "session-a")) }
        val second = WorkspaceCacheDirectories(root).apply { bind(WorkspaceOwner("same-connection", "account-b", "session-b")) }
        assertNotEquals(first.previews, second.previews)
        assertNotEquals(first.chatPreviews, second.chatPreviews)
        assertNotEquals(first.thumbnails, second.thumbnails)
    }

    @Test fun `重新登录同一身份不与另一连接混用缓存`() = withCache { root ->
        val first = WorkspaceCacheDirectories(root).apply { bind(WorkspaceOwner("a", "identity", "session-one")) }
        val renewed = WorkspaceCacheDirectories(root).apply { bind(WorkspaceOwner("a", "identity", "session-two")) }
        val other = WorkspaceCacheDirectories(root).apply { bind(WorkspaceOwner("b", "identity", "session-one")) }
        assertEquals(first.previews, renewed.previews); assertNotEquals(first.previews, other.previews)
    }

    @Test fun `清理一个账号不删除另一个账号的预览`() = withCache { root ->
        val first = WorkspaceCacheDirectories(root).apply { bind(WorkspaceOwner("a", "identity-a", "session")) }
        val second = WorkspaceCacheDirectories(root).apply { bind(WorkspaceOwner("b", "identity-b", "session")) }
        first.previews.mkdirs(); second.previews.mkdirs(); first.chatPreviews.mkdirs(); second.chatPreviews.mkdirs()
        File(first.previews, "same.pdf").writeText("synthetic-a")
        File(second.previews, "same.pdf").writeText("synthetic-b")
        File(first.chatPreviews, "same.mp4").writeText("synthetic-a")
        File(second.chatPreviews, "same.mp4").writeText("synthetic-b")
        first.clearPreviews()
        assertTrue(first.previews.listFiles().orEmpty().isEmpty())
        assertEquals("synthetic-b", File(second.previews, "same.pdf").readText())
        assertEquals("synthetic-b", File(second.chatPreviews, "same.mp4").readText())
    }

    @Test fun `目录名不包含账号标识也不会越过缓存根目录`() = withCache { root ->
        val cache = WorkspaceCacheDirectories(root).apply { bind(WorkspaceOwner("../synthetic-account", "../synthetic-target", "synthetic-session")) }
        assertEquals(File(root, "preview").canonicalFile, requireNotNull(cache.previews.parentFile).canonicalFile)
        assertFalse(cache.previews.name.contains("synthetic"))
    }

    private fun withCache(block: (File) -> Unit) {
        val root = Files.createTempDirectory("workspace-cache-test-").toFile()
        try { block(root) } finally { root.deleteRecursively() }
    }
}
