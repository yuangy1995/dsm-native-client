package io.github.qwertyuiop1995.dsmnativeclient

import android.app.Application
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.LruCache
import androidx.test.core.app.ApplicationProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.flow.MutableStateFlow
import java.time.Instant

/** 仅用于隔离模拟器的合成数据。没有 Repository、真实账号或可发送的请求。 */
internal object ApprovedUiFixture {
    val profile = NasProfile("approved-ui-fixture", "Demo NAS", "https://nas.example.invalid", "fixture-user")
    val files = listOf(
        FileItem("/synthetic/work", "Work", true, canRead = true, canWrite = true, canDelete = true),
        FileItem("/synthetic/family", "Family", true, canRead = true, canWrite = true, canDelete = true),
        FileItem("/synthetic/media", "Media", true, canRead = true, canWrite = true, canDelete = true),
        FileItem("/synthetic/notes.txt", "Notes.txt", false, size = 4096, canRead = true, canWrite = true, canDelete = true),
    )
    val photos = (0..11).map { index ->
        PhotoItem("/synthetic/photo-$index.jpg", FileItem("/synthetic/photo-$index.jpg", "Photo $index.jpg", false, size = 65536, canRead = true),
            PhotoItemKind.IMAGE, Instant.parse(if (index < 6) "2026-09-08T12:00:00Z" else "2026-09-07T12:00:00Z").epochSecond)
    }
    fun state(module: Module = Module.FILES) = WorkspaceState(
        profile = profile, selectedModule = module,
        availability = Module.entries.map { ModuleAvailability(it, true) },
        files = Loadable.Ready(FilePage(files, files.size, 0)),
        favoritePaths = setOf("/synthetic/work", "/synthetic/family"),
        supportsFavorites = true, supportsUploads = true, supportsThumbnails = true,
        supportsSharing = true, supportsCopyMove = true, supportsCompression = true,
        photos = Loadable.Ready(PhotoPage("/synthetic", photos, 0, photos.size, photos.size, false)),
        photoBrowser = PhotoBrowserState(mode = PhotoBrowseMode.TIMELINE),
        photoTimeline = Loadable.Ready(PhotoTimelineProgress(items = photos, scannedFolderCount = 2, isComplete = true)),
        conversations = Loadable.Ready(listOf(
            ChatConversation("family", "Family", ConversationKind.GROUP, unreadCount = 3, latestPreview = "Weekend photos", isPinnedLocally = true),
            ChatConversation("team", "Project team", ConversationKind.GROUP, latestPreview = "The draft is ready"),
        )),
        downloads = Loadable.Ready(listOf(DownloadTask("fixture-download", "http", "Example archive.zip", ResourceState.RUNNING,
            209715200, 104857600, 1048576, 0, "/synthetic", null))),
        transfers = listOf(TransferTask("fixture-transfer", "Example photo.jpg", "", TransferDirection.UPLOAD,
            TransferState.RUNNING, completedBytes = 4194304, totalBytes = 8388608)),
        nasSettings = Loadable.Ready(NasSettingsSnapshot(
            SystemSummary("Demo NAS", "Demo device", null, "7.2", 86400, null),
            volumes = listOf(CapacitySummary("volume", "Demo volume", 8000000000000, 2400000000000, ResourceState.HEALTHY)),
            pools = emptyList(), disks = emptyList(), storageDisks = emptyList(), packages = emptyList(),
            scheduledTasks = emptyList(), accounts = emptyList(), groups = emptyList(), logs = emptyList(),
            connections = emptyList(), connectionsAvailable = true, networkInterfaces = emptyList(), networkInterfacesAvailable = true,
            ddnsDirectory = null, ddnsDirectoryAvailable = true, fileServiceSettings = null, terminalSettings = null,
            proxySettings = null, regionSettings = null, securitySettings = null, hardwareSettings = null, security = emptyList(),
        )),
    )

    fun model(state: WorkspaceState = state()): AppViewModel = AppViewModel(ApplicationProvider.getApplicationContext<Application>()).also {
        setState(it, state)
    }

    @Suppress("UNCHECKED_CAST")
    fun setState(model: AppViewModel, state: WorkspaceState) {
        val field = AppViewModel::class.java.getDeclaredField("_workspace").apply { isAccessible = true }
        (field.get(model) as MutableStateFlow<WorkspaceState?>).value = state
    }

    @Suppress("UNCHECKED_CAST")
    fun resetNavigation(model: AppViewModel) {
        val field = AppViewModel::class.java.getDeclaredField("_moduleNavigation").apply { isAccessible = true }
        (field.get(model) as MutableStateFlow<ModuleNavigationSignal?>).value = null
    }

    @Suppress("UNCHECKED_CAST")
    fun seedThumbnails(model: AppViewModel) {
        val field = AppViewModel::class.java.getDeclaredField("thumbnailCache").apply { isAccessible = true }
        val cache = field.get(model) as LruCache<String, Bitmap>
        photos.forEachIndexed { index, item ->
            val bitmap = Bitmap.createBitmap(192, 192, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG)
            canvas.drawColor(Color.rgb(150 + index * 5, 190, 220 - index * 5))
            paint.color = Color.rgb(55 + index * 8, 110, 110 + index * 5)
            canvas.drawCircle(60f + index * 4, 180f, 110f, paint)
            paint.color = Color.rgb(235, 215, 160)
            canvas.drawCircle(140f, 44f, 18f, paint)
            cache.put("${profile.id}\u0000${item.file.path}", bitmap)
        }
    }
}
