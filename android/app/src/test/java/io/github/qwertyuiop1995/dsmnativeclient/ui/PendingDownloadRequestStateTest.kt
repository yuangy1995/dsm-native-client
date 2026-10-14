package io.github.qwertyuiop1995.dsmnativeclient.ui

import io.github.qwertyuiop1995.dsmnativeclient.DownloadEnqueueResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner

class PendingDownloadRequestStateTest {
    @Test
    fun `保存状态重建后保留最小稳定字段`() {
        val original = PendingDownloadRequestState(
            pendingDownloadRequest(owner("profile-a"), listOf(FileItem(
                path = "/synthetic/photo.jpg",
                name = "photo.jpg",
                isDirectory = false,
                size = 42,
                canRead = true,
                canWrite = true,
                canDelete = true,
                mimeType = "image/jpeg",
            )), "photo.jpg"),
        )

        val restored = pendingDownloadRequestStateFrom(original.toSaveableValues())

        assertEquals(original, restored)
        assertEquals(
            FileItem(
                path = "/synthetic/photo.jpg",
                name = "photo.jpg",
                isDirectory = false,
                size = 42,
                canRead = true,
            ),
            restored.request?.items?.single(),
        )
        assertFalse(restored.toSaveableValues().any { value ->
            value.toString().contains("token", ignoreCase = true) ||
                value.toString().contains("password", ignoreCase = true)
        })
    }

    @Test
    fun `无待处理请求的保存状态可重建`() {
        val restored = pendingDownloadRequestStateFrom(
            PendingDownloadRequestState().toSaveableValues(),
        )

        assertNull(restored.request)
    }

    @Test
    fun `用户取消时只消费待处理请求且不丢弃目标`() {
        val pending = requestState(profileId = "profile-a")

        val cancelled = resolveDownloadDestination(
            pending = pending,
            activeOwner = owner("profile-a"),
            destinationSelected = false,
        )

        assertEquals(DownloadDestinationDecision.CANCELLED, cancelled.decision)
        assertNull(cancelled.request)
        assertNull(cancelled.nextPending.request)

        val repeated = resolveDownloadDestination(
            pending = cancelled.nextPending,
            activeOwner = owner("profile-a"),
            destinationSelected = true,
        )
        assertEquals(DownloadDestinationDecision.DISCARD_ORPHAN, repeated.decision)
    }

    @Test
    fun `资料不匹配或请求丢失时丢弃新建目标`() {
        val mismatch = resolveDownloadDestination(
            pending = requestState(profileId = "profile-a"),
            activeOwner = owner("profile-b"),
            destinationSelected = true,
        )
        val orphan = resolveDownloadDestination(
            pending = PendingDownloadRequestState(),
            activeOwner = owner("profile-a"),
            destinationSelected = true,
        )

        assertEquals(DownloadDestinationDecision.DISCARD_ORPHAN, mismatch.decision)
        assertEquals(DownloadDestinationDecision.DISCARD_ORPHAN, orphan.decision)
        assertNull(mismatch.nextPending.request)
        assertNull(orphan.nextPending.request)
    }

    @Test
    fun `仅真实后台下载需要请求通知权限`() {
        assertTrue(
            shouldRequestDownloadNotificationPermission(
                DownloadEnqueueResult.BACKGROUND,
                sdkInt = 35,
                notificationPermissionGranted = false,
            ),
        )
        assertFalse(
            shouldRequestDownloadNotificationPermission(
                DownloadEnqueueResult.FOREGROUND,
                sdkInt = 35,
                notificationPermissionGranted = false,
            ),
        )
        assertFalse(
            shouldRequestDownloadNotificationPermission(
                DownloadEnqueueResult.REJECTED,
                sdkInt = 35,
                notificationPermissionGranted = false,
            ),
        )
        assertFalse(
            shouldRequestDownloadNotificationPermission(
                DownloadEnqueueResult.BACKGROUND,
                sdkInt = 32,
                notificationPermissionGranted = false,
            ),
        )
        assertFalse(
            shouldRequestDownloadNotificationPermission(
                DownloadEnqueueResult.BACKGROUND,
                sdkInt = 35,
                notificationPermissionGranted = true,
            ),
        )
    }

    @Test fun `相同资料更换账号或会话后拒绝选择器旧结果`() {
        val original = owner("profile-a")
        listOf(original.copy(identityRevision = "changed"), original.copy(sessionGeneration = "renewed"), null).forEach {
            assertEquals(DownloadDestinationDecision.DISCARD_ORPHAN,
                resolveDownloadDestination(requestState("profile-a"), it, true).decision)
        }
        assertEquals(DownloadDestinationDecision.ENQUEUE,
            resolveDownloadDestination(requestState("profile-a"), original, true).decision)
    }

    @Test fun `多选重建保留原始路径和顺序并消费一次`() {
        val items = listOf(FileItem("/synthetic/a.txt ", "a.txt ", false, 8), FileItem("/synthetic/folder", "folder", true))
        val expected = PendingDownloadRequestState(pendingDownloadRequest(owner("profile-a"), items, "Selection.zip"))
        val restored = pendingDownloadRequestStateFrom(expected.toSaveableValues())
        assertEquals(expected, restored)
        assertTrue(restored.request!!.isArchive)
        val result = resolveDownloadDestination(restored, owner("profile-a"), true)
        assertEquals(expected.request, result.request)
        assertNull(result.nextPending.request)
    }

    @Test fun `旧格式缺少归属和损坏清单不猜测恢复`() {
        assertNull(pendingDownloadRequestStateFrom(listOf(true, "profile-a", "/a", "a", false, 7L, true)).request)
        assertNull(pendingDownloadRequestStateFrom(requestState("profile-a").toSaveableValues().dropLast(1)).request)
    }

    private fun owner(profileId: String) = WorkspaceOwner(profileId, "identity", "session")
    private fun requestState(profileId: String) = PendingDownloadRequestState(pendingDownloadRequest(
        owner(profileId), listOf(FileItem("/synthetic/file.bin", "file.bin", false, 7, canRead = true)), "file.bin"))
}
