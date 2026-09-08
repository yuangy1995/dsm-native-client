package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import okhttp3.OkHttpClient
import org.junit.Assert.*
import org.junit.Test

class ConnectedWorkspaceTest {
    @Test fun 共用初始化保留能力门导航和置顶顺序且不请求网络() {
        val profile = NasProfile("fixture", "Fixture NAS", "https://nas.example.invalid", "fixture-user")
        val api = DsmApiClient(OkHttpClient.Builder().addInterceptor { throw AssertionError("初始化不能请求网络") }.build())
        val repo = DsmRepository(profile, DsmSession(profile.id, "synthetic-session-not-a-credential"), api, emptyMap())
        val browser = FileBrowserState(path = "/synthetic", pathHistory = listOf(""))
        val availability = repo.availability()
        val state = connectedWorkspace(profile, repo, availability, Module.FILES to browser, null, null, null, listOf("second", "first"))
        assertEquals(profile, state.profile)
        assertEquals(availability, state.availability)
        assertEquals(browser, state.fileBrowser)
        assertEquals(listOf("second", "first"), state.chatPinnedConversationIds)
        assertFalse(state.supportsUploads)
        assertFalse(state.supportsSharing)
        assertFalse(state.supportsOfficialVirtualMachineCreation)
        assertFalse(state.virtualMachineMutationState.supportsOfficialTasks)
        assertEquals(Loadable.Idle, state.fileBackgroundTasks)
    }
}
