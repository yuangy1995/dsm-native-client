package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.testing.authorizedRepository

import android.app.Application
import android.content.ClipboardManager
import android.content.Context
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.rules.ActivityScenarioRule
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBrowserState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewContent
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.WorkspacePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.OpaqueWorkspaceTarget
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoBrowserState
import io.github.qwertyuiop1995.dsmnativeclient.domain.PhotoBrowseMode
import io.github.qwertyuiop1995.dsmnativeclient.domain.PERSONAL_PHOTO_SPACE
import io.github.qwertyuiop1995.dsmnativeclient.domain.SHARED_PHOTO_SPACE
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import java.util.Collections
import java.util.UUID
import kotlinx.coroutines.flow.MutableStateFlow
import okhttp3.FormBody
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.MediaType.Companion.toMediaType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.Rule

class OpaqueWorkspaceNavigationTest {
    @get:Rule val activity = ActivityScenarioRule(MainActivity::class.java)
    @Test
    fun 未知或跨资料令牌会确定拒绝且不切换资料() {
        val currentProfile = syntheticProfile("current")
        val otherProfile = syntheticProfile("other")
        withProfiles(currentProfile, otherProfile) { store ->
            val model = model()
            val workspace = workspace(model)
            workspace.value = syntheticWorkspace(currentProfile)
            installRepository(model, repository(currentProfile, RecordingFileRepositoryInterceptor()))
            val crossProfileToken = requireNotNull(
                store.issueOpaqueWorkspaceTarget(
                    otherProfile.id,
                    OpaqueWorkspaceTarget.FileDirectory("/synthetic/other"),
                owner = requireNotNull(store.currentOwner(otherProfile.id)),
                ),
            )

            assertEquals(
                WorkspaceNavigationResult.REJECTED,
                model.navigateToOpaqueExternalRoute("A".repeat(43)),
            )
            assertEquals(Module.FILES, workspace.value?.selectedModule)
            assertTrue(workspace.value?.message?.isNotBlank() == true)

            assertEquals(
                WorkspaceNavigationResult.REJECTED,
                model.navigateToOpaqueExternalRoute(crossProfileToken),
            )
            assertEquals(currentProfile.id, workspace.value?.profile?.id)
            assertEquals(Module.FILES, workspace.value?.selectedModule)
        }
    }

    @Test
    fun 最新对象请求会覆盖等待放弃草稿的旧请求() {
        val profile = syntheticProfile("latest")
        val currentItem = syntheticTextItem("/synthetic/current.txt")
        val transport = RecordingFileRepositoryInterceptor(currentItem)
        withProfiles(profile) { store ->
            val model = model()
            val workspace = workspace(model)
            workspace.value = syntheticWorkspace(profile).copy(
                previewItem = currentItem,
                preview = Loadable.Ready(
                    FilePreviewContent.Text(currentItem, "saved", truncated = false),
                ),
                previewOwner = PreviewOwner.FILES,
                textPreviewDraft = "draft",
            )
            installRepository(model, repository(profile, transport))
            val oldToken = requireNotNull(
                store.issueOpaqueWorkspaceTarget(
                    profile.id,
                    OpaqueWorkspaceTarget.FileDirectory("/synthetic/older"),
                owner = requireNotNull(store.currentOwner(profile.id)),
                ),
            )
            val latestToken = requireNotNull(
                store.issueOpaqueWorkspaceTarget(
                    profile.id,
                    OpaqueWorkspaceTarget.FilePreview(currentItem.path),
                owner = requireNotNull(store.currentOwner(profile.id)),
                ),
            )

            assertEquals(
                WorkspaceNavigationResult.DEFERRED,
                model.navigateToOpaqueExternalRoute(oldToken),
            )
            assertTrue(workspace.value?.previewDiscardConfirmationVisible == true)

            assertEquals(
                WorkspaceNavigationResult.DEFERRED,
                model.navigateToOpaqueExternalRoute(latestToken),
            )
            waitForOpaqueNavigationResult(
                model,
                latestToken,
                WorkspaceNavigationResult.APPLIED,
            )

            assertEquals(currentItem, workspace.value?.previewItem)
            assertEquals("draft", workspace.value?.textPreviewDraft)
            assertFalse(workspace.value?.previewDiscardConfirmationVisible == true)
            assertFalse(transport.fileInfoPaths.contains("[\"/synthetic/older\"]"))
            assertTrue(transport.fileInfoPaths.contains("[\"${currentItem.path}\"]"))
        }
    }

    @Test
    fun 放弃脏文本预览的对象导航会保留草稿并终止请求() {
        val profile = syntheticProfile("discard")
        val item = syntheticTextItem("/synthetic/current.txt")
        withProfiles(profile) { store ->
            val model = model()
            val workspace = workspace(model)
            workspace.value = syntheticWorkspace(profile).copy(
                previewItem = item,
                preview = Loadable.Ready(FilePreviewContent.Text(item, "saved", truncated = false)),
                previewOwner = PreviewOwner.FILES,
                textPreviewDraft = "draft",
            )
            installRepository(model, repository(profile, RecordingFileRepositoryInterceptor(item)))
            val token = requireNotNull(
                store.issueOpaqueWorkspaceTarget(
                    profile.id,
                    OpaqueWorkspaceTarget.FileDirectory("/synthetic/other"),
                owner = requireNotNull(store.currentOwner(profile.id)),
                ),
            )

            assertEquals(
                WorkspaceNavigationResult.DEFERRED,
                model.navigateToOpaqueExternalRoute(token),
            )
            assertTrue(workspace.value?.previewDiscardConfirmationVisible == true)

            model.dismissPreviewDiscardConfirmation()

            assertEquals(Module.FILES, workspace.value?.selectedModule)
            assertEquals(item, workspace.value?.previewItem)
            assertEquals("draft", workspace.value?.textPreviewDraft)
            assertFalse(workspace.value?.previewDiscardConfirmationVisible == true)
            assertEquals(
                WorkspaceNavigationResult.REJECTED,
                model.navigateToOpaqueExternalRoute(token),
            )
            assertEquals(item, workspace.value?.previewItem)
            assertEquals("draft", workspace.value?.textPreviewDraft)
        }
    }

    @Test
    fun 固定和对象页面签发以及Bundle恢复只暴露令牌() {
        val profile = syntheticProfile("page-link")
        withProfiles(profile) { store ->
            val model = model()
            installRepository(model, repository(profile, RecordingFileRepositoryInterceptor()))
            val workspace = workspace(model)
            workspace.value = syntheticWorkspace(profile)

            model.copyCurrentPageLink()
            val rootLink = clipboardText()
            val rootToken = (rootLink.externalWorkspaceRoute() as ExternalWorkspaceRoute.OpaqueObject).token
            val rootRecord = requireNotNull(store.opaqueWorkspaceRoute(rootToken))
            assertEquals(profile.id, rootRecord.profileId)
            assertEquals(OpaqueWorkspaceTarget.Page(WorkspacePage.FILES), rootRecord.target)
            assertFalse(rootLink.contains(profile.id))
            assertFalse(rootLink.contains(profile.address))
            assertFalse(rootLink.contains(profile.username))

            val directory = "/synthetic/private-folder"
            workspace.value = workspace.value?.copy(fileBrowser = FileBrowserState(path = directory))
            model.copyCurrentPageLink()

            val route = requireNotNull(clipboardText().externalWorkspaceRoute())
            assertTrue(route is ExternalWorkspaceRoute.OpaqueObject)
            val token = (route as ExternalWorkspaceRoute.OpaqueObject).token
            assertFalse(clipboardText().contains(directory))
            assertEquals(
                OpaqueWorkspaceTarget.FileDirectory(directory),
                store.opaqueWorkspaceRoute(token)?.target,
            )

            val saved = Bundle().apply { putString("pending_opaque_token", token) }
            val restored = saved.pendingInternalNavigationState()
            assertEquals(setOf("pending_opaque_token"), saved.keySet())
            assertEquals(PendingNavigationRequest.OpaqueObject(token), restored.currentRequest)
            assertEquals(token, restored.pendingOpaqueToken)
            assertEquals(null, restored.pendingRequest)
        }
    }

    @Test
    fun 共享照片根目录签发不透明链接并经重读恢复共享空间() {
        val profile = syntheticProfile("shared-photo-root")
        val root = FileItem(
            path = "/photo",
            name = "photo",
            isDirectory = true,
            canRead = true,
        )
        val transport = RecordingFileRepositoryInterceptor(root)
        withProfiles(profile) { store ->
            val model = model()
            val workspace = workspace(model)
            workspace.value = syntheticWorkspace(profile).copy(
                selectedModule = Module.PHOTOS,
                photoBrowser = PhotoBrowserState(
                    selectedSpaceId = SHARED_PHOTO_SPACE.id,
                    folderPath = SHARED_PHOTO_SPACE.rootPath,
                ),
            )
            installRepository(model, repository(profile, transport))

            model.copyCurrentPageLink()

            val uri = clipboardText()
            val route = requireNotNull(uri.externalWorkspaceRoute())
            assertTrue(route is ExternalWorkspaceRoute.OpaqueObject)
            val token = (route as ExternalWorkspaceRoute.OpaqueObject).token
            assertFalse(uri.contains("shared"))
            assertFalse(uri.contains("/photo"))
            assertEquals(
                OpaqueWorkspaceTarget.PhotoFolder(
                    SHARED_PHOTO_SPACE.id,
                    SHARED_PHOTO_SPACE.rootPath,
                ),
                store.opaqueWorkspaceRoute(token)?.target,
            )

            workspace.value = workspace.value?.copy(
                selectedModule = Module.FILES,
                photoBrowser = PhotoBrowserState(),
            )

            waitForOpaqueNavigationResult(model, token, WorkspaceNavigationResult.APPLIED)

            assertEquals(Module.PHOTOS, workspace.value?.selectedModule)
            assertEquals(SHARED_PHOTO_SPACE.id, workspace.value?.photoBrowser?.selectedSpaceId)
            assertEquals(SHARED_PHOTO_SPACE.rootPath, workspace.value?.photoBrowser?.folderPath)
            assertEquals(emptyList<String>(), workspace.value?.photoBrowser?.pathHistory)
            assertEquals(PhotoBrowseMode.FOLDERS, workspace.value?.photoBrowser?.mode)
            assertTrue(transport.fileInfoPaths.contains("[\"/photo\"]"))

            workspace.value = workspace.value?.copy(
                photoBrowser = PhotoBrowserState(),
            )
            model.copyCurrentPageLink()
            val personalToken = (clipboardText().externalWorkspaceRoute() as ExternalWorkspaceRoute.OpaqueObject).token
            val personalRecord = requireNotNull(store.opaqueWorkspaceRoute(personalToken))
            assertEquals(profile.id, personalRecord.profileId)
            assertEquals(OpaqueWorkspaceTarget.Page(WorkspacePage.PHOTOS), personalRecord.target)
        }
    }

    @Test
    fun 共享照片根目录在重读为不可读时拒绝打开() {
        val profile = syntheticProfile("shared-photo-root-unreadable")
        val root = FileItem(
            path = "/photo",
            name = "photo",
            isDirectory = true,
            canRead = false,
        )
        val transport = RecordingFileRepositoryInterceptor(root)
        withProfiles(profile) { store ->
            val model = model()
            val workspace = workspace(model)
            workspace.value = syntheticWorkspace(profile)
            installRepository(model, repository(profile, transport))
            val token = requireNotNull(
                store.issueOpaqueWorkspaceTarget(
                    profile.id,
                    OpaqueWorkspaceTarget.PhotoFolder(
                        SHARED_PHOTO_SPACE.id,
                        SHARED_PHOTO_SPACE.rootPath,
                    ),
                owner = requireNotNull(store.currentOwner(profile.id)),
                ),
            )

            waitForOpaqueNavigationResult(model, token, WorkspaceNavigationResult.REJECTED)

            assertEquals(Module.FILES, workspace.value?.selectedModule)
            assertEquals(PERSONAL_PHOTO_SPACE.id, workspace.value?.photoBrowser?.selectedSpaceId)
            assertTrue(transport.fileInfoPaths.contains("[\"/photo\"]"))
        }
    }

    private fun waitForOpaqueNavigationResult(
        model: AppViewModel,
        token: String,
        expected: WorkspaceNavigationResult,
    ) {
        val deadline = System.currentTimeMillis() + 5_000
        var actual = model.navigateToOpaqueExternalRoute(token)
        while (actual == WorkspaceNavigationResult.DEFERRED && System.currentTimeMillis() < deadline) {
            Thread.sleep(20)
            actual = model.navigateToOpaqueExternalRoute(token)
        }
        assertEquals(expected, actual)
    }

    private fun model(): AppViewModel =
        AppViewModel(ApplicationProvider.getApplicationContext<Application>())

    @Suppress("UNCHECKED_CAST")
    private fun workspace(model: AppViewModel): MutableStateFlow<WorkspaceState?> {
        val field = AppViewModel::class.java.getDeclaredField("_workspace").apply {
            isAccessible = true
        }
        return field.get(model) as MutableStateFlow<WorkspaceState?>
    }

    private fun installRepository(model: AppViewModel, repository: DsmRepository) {
        AppViewModel::class.java.getDeclaredMethod("setRepository", DsmRepository::class.java).apply {
            isAccessible = true
        }.invoke(model, repository)
    }

    private fun syntheticWorkspace(profile: NasProfile) = WorkspaceState(
        profile = profile,
        selectedModule = Module.FILES,
        availability = Module.entries.map { io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability(it, true) },
    )

    private fun syntheticProfile(label: String) = NasProfile(
        id = "opaque-navigation-$label-${UUID.randomUUID()}",
        name = "Synthetic",
        address = "https://nas.example.invalid",
        username = "operator",
    )

    private fun syntheticTextItem(path: String) = FileItem(
        path = path,
        name = path.substringAfterLast('/'),
        isDirectory = false,
        mimeType = "text/plain",
        canRead = true,
        canWrite = true,
    )

    private fun repository(
        profile: NasProfile,
        interceptor: RecordingFileRepositoryInterceptor,
    ) = authorizedRepository(
        profile = profile,
        session = DsmSession(profile.id, "synthetic-session", "synthetic-token"),
        api = DsmApiClient(
            OkHttpClient.Builder()
                .followRedirects(false)
                .followSslRedirects(false)
                .retryOnConnectionFailure(false)
                .addInterceptor(interceptor)
                .build(),
        ),
        capabilities = listOf(
            ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2),
        ).associateBy(ApiCapability::name),
    ).also { repo ->
        val store = SecureProfileStore(ApplicationProvider.getApplicationContext<Application>())
        val owner = requireNotNull(store.currentOwner(profile.id))
        repo.bindOwner(owner) { store.requireCurrentOwner(owner) }
    }

    private fun clipboardText(): String {
        val application = ApplicationProvider.getApplicationContext<Application>()
        val clipboard = application.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        return requireNotNull(clipboard.primaryClip).getItemAt(0).text.toString()
    }

    private inline fun withProfiles(
        vararg profiles: NasProfile,
        block: (SecureProfileStore) -> Unit,
    ) {
        val store = SecureProfileStore(ApplicationProvider.getApplicationContext<Application>())
        profiles.forEach { profile ->
            store.commitConnection(store.connectionAttempt(profile.id), profile,
                DsmSession(profile.id, "synthetic-session", "synthetic-token"), null, false)
        }
        try {
            block(store)
        } finally {
            profiles.forEach { profile -> store.removeProfile(profile.id) }
        }
    }
}

private class RecordingFileRepositoryInterceptor(
    private val fileInfoItem: FileItem? = null,
) : Interceptor {
    val fileInfoPaths: MutableList<String> = Collections.synchronizedList(mutableListOf())

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val fields = request.formFields()
        val body = when (fields["method"]) {
            "getinfo" -> {
                fileInfoPaths += fields["path"].orEmpty()
                fileInfoResponse(fileInfoItem)
            }

            "list" -> "{\"success\":true,\"data\":{\"offset\":0,\"total\":0,\"files\":[]}}"
            "list_share" -> "{\"success\":true,\"data\":{\"offset\":0,\"total\":0,\"shares\":[]}}"
            else -> error("Unexpected synthetic request: ${fields["method"]}")
        }
        return Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(200)
            .message("OK")
            .body(body.toResponseBody("application/json".toMediaType()))
            .build()
    }

    private fun fileInfoResponse(item: FileItem?): String = if (item == null) {
        "{\"success\":true,\"data\":{\"files\":[]}}"
    } else {
        """{"success":true,"data":{"files":[{"name":"${item.name}","path":"${item.path}","isdir":${item.isDirectory},"size":${item.size},"additional":{"perm":{"read":${item.canRead},"write":${item.canWrite},"delete":${item.canDelete}}}}]}}"""
    }
}

private fun Request.formFields(): Map<String, String> {
    val form = body as? FormBody ?: return emptyMap()
    return (0 until form.size).associate { index -> form.name(index) to form.value(index) }
}
