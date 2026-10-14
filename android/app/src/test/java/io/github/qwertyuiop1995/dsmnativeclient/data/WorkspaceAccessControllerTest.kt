package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class WorkspaceAccessControllerTest {
    @Test fun `并发刷新共用一次读取`() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        var reads = 0
        val controller = controller {
            reads++
            entered.complete(Unit)
            release.await()
            granted()
        }
        val first = async { controller.refresh(false) }
        entered.await()
        val second = async(start = CoroutineStart.UNDISPATCHED) { controller.refresh(true) }
        release.complete(Unit)
        awaitAll(first, second)
        assertEquals(1, reads)
        controller.requireApi("SYNO.FileStation.List")
    }

    @Test fun `退出后迟到的摘要不能重新授权`() = runBlocking {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val controller = controller {
            entered.complete(Unit)
            release.await()
            granted()
        }
        val read = async { runCatching { controller.refresh(false) }.exceptionOrNull() }
        entered.await()
        controller.invalidate()
        release.complete(Unit)
        assertTrue(read.await() is CancellationException)
        assertTrue(runCatching { controller.requireApi("SYNO.FileStation.List") }.exceptionOrNull() is DsmFailure)
        assertFalse(controller.snapshot.availability.single { it.module == Module.FILES }.isAvailable)
    }

    @Test fun `不同账号的相同接口独立授权`() = runBlocking {
        val allowed = controller { granted() }
        val denied = controller { DesktopAppPrivileges(emptyMap(), false) }
        allowed.refresh(false)
        denied.refresh(false)
        allowed.requireApi("SYNO.FileStation.List")
        val error = runCatching { denied.requireApi("SYNO.FileStation.List") }.exceptionOrNull() as DsmFailure
        assertEquals(DsmErrorKind.PERMISSION_DENIED, error.kind)
        denied.invalidate()
        allowed.requireApi("SYNO.FileStation.List")
    }

    @Test fun `未知接口不能继承其他模块授权`() = runBlocking {
        val controller = controller { granted() }
        controller.refresh(false)
        assertEquals(DsmErrorKind.FEATURE_UNSUPPORTED,
            (runCatching { controller.requireApi("SYNO.Unknown.Write") }.exceptionOrNull() as DsmFailure).kind)
    }

    @Test fun `文件访问规则仅采用文件授权其他Core接口仍受管理权限限制`() = runBlocking {
        val allowed = controller { granted() }
        allowed.refresh(false)
        allowed.requireApi("SYNO.Core.ACL")
        assertEquals(DsmErrorKind.PERMISSION_DENIED,
            (runCatching { allowed.requireApi("SYNO.Core.System") }.exceptionOrNull() as DsmFailure).kind)
        val denied = controller { DesktopAppPrivileges(mapOf(DesktopApplication.FILES to false), true) }
        denied.refresh(false)
        assertEquals(DsmErrorKind.PERMISSION_DENIED,
            (runCatching { denied.requireApi("SYNO.Core.ACL") }.exceptionOrNull() as DsmFailure).kind)
    }

    @Test fun `Foto与FotoTeam均使用照片权限且撤权后同时拒绝`() = runBlocking {
        val allowed = controller(photoEnabled = true) { granted() }
        val denied = controller { granted() }
        allowed.refresh(false); denied.refresh(false)
        for (name in listOf("SYNO.Foto.Browse.Item", "SYNO.FotoTeam.Browse.Item", "SYNO.FotoTeam.Download")) {
            allowed.requireApi(name)
            assertEquals(DsmErrorKind.PERMISSION_DENIED, (runCatching { denied.requireApi(name) }.exceptionOrNull() as DsmFailure).kind)
        }
        allowed.invalidate()
        assertTrue(runCatching { allowed.requireApi("SYNO.FotoTeam.Streaming") }.exceptionOrNull() is DsmFailure)
    }

    private fun granted() = DesktopAppPrivileges(mapOf(DesktopApplication.FILES to true), false)
    private fun controller(photoEnabled: Boolean = false, read: suspend () -> DesktopAppPrivileges): WorkspaceAccessController {
        val profile = NasProfile("synthetic", "Synthetic", "https://nas.example.invalid", "synthetic")
        val capabilities = mapOf("SYNO.FileStation.List" to ApiCapability("SYNO.FileStation.List", "entry.cgi", 1, 2)) +
            listOf("UserInfo", "Setting.User", "Setting.Admin", "Setting.TeamSpace").associate {
                val name = "SYNO.Foto.$it"; name to ApiCapability(name, "entry.cgi", 1, 1, "JSON")
            }
        val reader = WorkspaceAccessReader(capabilities, readPrivileges = read,
            readFileSession = { error("不得发出额外文件读取") }, readPhotoAccess = { if (!photoEnabled) throw SynologyPhotoFailure(SynologyPhotoFailureKind.PERMISSION) })
        return WorkspaceAccessController(profile, DsmSession(profile.id, "synthetic"), DsmApiClient(), capabilities, reader)
    }
}
