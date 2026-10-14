package io.github.qwertyuiop1995.dsmnativeclient

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.OpaqueWorkspaceTarget
import io.github.qwertyuiop1995.dsmnativeclient.storage.SecureProfileStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SecureProfileStoreTest {
    private val store = SecureProfileStore(ApplicationProvider.getApplicationContext<android.app.Application>())

    @After
    fun cleanup() {
        store.clearAll()
    }

    @Test
    fun passwordAndAutoLoginAreProtectedPerProfile() {
        val profile = NasProfile(
            id = "secure-store-test",
            name = "测试 NAS",
            address = "test-nas",
            username = "tester",
        )

        store.saveProfile(profile)
        store.savePassword(profile.id, "test-password")
        store.setAutoLoginEnabled(profile.id, true)
        store.setLastProfileId(profile.id)

        assertEquals("test-password", store.password(profile.id))
        assertTrue(store.isAutoLoginEnabled(profile.id))
        assertEquals(profile.id, store.lastProfileId())

        store.clearPassword(profile.id)

        assertNull(store.password(profile.id))
        assertFalse(store.isAutoLoginEnabled(profile.id))
    }

    @Test
    fun opaqueWorkspaceRouteIsDurablePerProfileUntilExplicitRemoval() {
        val profile = NasProfile(
            id = "opaque-route-profile",
            name = "测试 NAS",
            address = "test-nas",
            username = "tester",
        )
        val target = OpaqueWorkspaceTarget.FilePreview("/share/Projects/readme.md")

        store.commitConnection(store.connectionAttempt(profile.id), profile, DsmSession(profile.id, "synthetic"), null, false)
        val token = requireNotNull(store.issueOpaqueWorkspaceTarget(profile.id, target, owner = requireNotNull(store.currentOwner(profile.id))))

        assertEquals(43, token.length)
        assertEquals(target, store.opaqueWorkspaceRoute(token)?.target)
        assertEquals(token, store.issueOpaqueWorkspaceTarget(profile.id, target, owner = requireNotNull(store.currentOwner(profile.id))))

        store.clearSession(profile.id)

        assertEquals(target, store.opaqueWorkspaceRoute(token)?.target)
        assertTrue(store.removeOpaqueWorkspaceRoute(token))
        assertNull(store.opaqueWorkspaceRoute(token))
    }

    @Test
    fun removeProfileAndClearAllRevokeOpaqueWorkspaceRoutes() {
        val first = NasProfile(
            id = "opaque-route-first",
            name = "第一个测试 NAS",
            address = "test-nas-first",
            username = "tester",
        )
        val second = NasProfile(
            id = "opaque-route-second",
            name = "第二个测试 NAS",
            address = "test-nas-second",
            username = "tester",
        )
        store.commitConnection(store.connectionAttempt(first.id), first, DsmSession(first.id, "synthetic-first"), null, false)
        store.commitConnection(store.connectionAttempt(second.id), second, DsmSession(second.id, "synthetic-second"), null, false)
        val firstToken = requireNotNull(
            store.issueOpaqueWorkspaceTarget(
                first.id,
                OpaqueWorkspaceTarget.ChatConversation("conversation-a"),
                owner = requireNotNull(store.currentOwner(first.id)),
            ),
        )
        val secondToken = requireNotNull(
            store.issueOpaqueWorkspaceTarget(
                second.id,
                OpaqueWorkspaceTarget.DownloadTask("task-b"),
                owner = requireNotNull(store.currentOwner(second.id)),
            ),
        )

        store.removeProfile(first.id)

        assertNull(store.opaqueWorkspaceRoute(firstToken))
        assertEquals(second.id, store.opaqueWorkspaceRoute(secondToken)?.profileId)

        store.clearAll()

        assertNull(store.opaqueWorkspaceRoute(secondToken))
    }
}
