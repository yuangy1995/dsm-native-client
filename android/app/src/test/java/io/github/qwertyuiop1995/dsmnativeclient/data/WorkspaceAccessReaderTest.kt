package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.io.IOException
import javax.net.ssl.SSLHandshakeException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.*
import org.junit.Test

class WorkspaceAccessReaderTest {
    @Test fun `只解码白名单且不接受字符串布尔值`() {
        val result = decode("""{"AppPrivilege":{"SYNO.SDS.Chat.Application":true,"unknown":{"secret":"ignored"}},"Session":{"is_admin":false,"isLogined":true,"other":"ignored"},"UserSettings":{"anything":[]}}""")
        assertEquals(mapOf(DesktopApplication.CHAT to true), result.applications)
        assertFalse(result.isAdministrator)
        for (value in listOf("\"true\"", "1", "null", "{}", "[]")) {
            assertInvalid("""{"AppPrivilege":{"SYNO.SDS.Chat.Application":$value}}""")
        }
    }

    @Test fun `空表有效但整表缺失或类型损坏无效`() {
        assertTrue(decode("""{"AppPrivilege":{}}""").applications.isEmpty())
        for (value in listOf("{}", """{"AppPrivilege":null}""", """{"AppPrivilege":[]}""",
            """{"AppPrivilege":{},"Session":{"is_admin":"true"}}""")) assertInvalid(value)
    }

    @Test fun `未登录摘要是读取失败而非会话过期`() {
        val error = runCatching { decode("""{"AppPrivilege":{},"Session":{"isLogined":false}}""") }.exceptionOrNull()!!
        assertFalse(isExpiredWorkspaceSession(error))
        assertEquals(DsmErrorKind.INVALID_RESPONSE, (error as DsmFailure).kind)
    }

    @Test fun `有效空表不读取文件或套件列表且本地功能始终可达`() = runBlocking {
        val result = reader(privileges = DesktopAppPrivileges(emptyMap(), false), file = { error("不应读取文件") }).read()
        assertTrue(result.sessionConfirmed)
        assertFalse(result.lookupFailed)
        DesktopApplication.entries.forEach { assertAccess(result, it.module, ModuleAccessState.DENIED) }
        assertAccess(result, Module.SETTINGS, ModuleAccessState.ALLOWED)
        assertAccess(result, Module.TRANSFERS, ModuleAccessState.ALLOWED)
    }

    @Test fun `普通账号仅明确允许的应用可达且仍须接口能力`() = runBlocking {
        val result = reader(privileges = DesktopAppPrivileges(DesktopApplication.entries.associateWith { true }, false)).read()
        for (module in listOf(Module.FILES, Module.CHAT, Module.DOWNLOADS, Module.VIRTUAL_MACHINES)) {
            assertAccess(result, module, ModuleAccessState.ALLOWED)
        }
        for (module in listOf(Module.NAS_SETTINGS, Module.CONTAINERS)) assertAccess(result, module, ModuleAccessState.DENIED)
        assertAccess(reader(capabilities = emptyMap(), privileges = DesktopAppPrivileges(mapOf(DesktopApplication.FILES to true), false)).read(),
            Module.FILES, ModuleAccessState.UNSUPPORTED)
    }

    @Test fun `管理员缺少管理键可达但明确拒绝不被管理员覆盖`() = runBlocking {
        val missing = reader(privileges = DesktopAppPrivileges(emptyMap(), true)).read()
        assertAccess(missing, Module.CONTAINERS, ModuleAccessState.ALLOWED)
        assertAccess(missing, Module.NAS_SETTINGS, ModuleAccessState.ALLOWED)
        assertAccess(missing, Module.DOWNLOADS, ModuleAccessState.DENIED)
        val denied = reader(privileges = DesktopAppPrivileges(DesktopApplication.entries.associateWith { false }, true)).read()
        DesktopApplication.entries.forEach { assertAccess(denied, it.module, ModuleAccessState.DENIED) }
    }

    @Test fun `权限编辑保留真实角色且最小文件会话不授予私有写授权`() = runBlocking {
        val actual = reader(privileges = DesktopAppPrivileges(mapOf(DesktopApplication.FILES to true,
            DesktopApplication.NAS_SETTINGS to false), true)).read()
        assertEquals(FilePermissionAccess(true, true), actual.filePermissionAccess)
        assertAccess(actual, Module.NAS_SETTINGS, ModuleAccessState.DENIED)
        val missing = reader(privileges = DesktopAppPrivileges(emptyMap(), true)).read()
        assertEquals(FilePermissionAccess(false, true), missing.filePermissionAccess)
        val fallback = reader(summaryFailure = IOException(), file = {}).read()
        assertAccess(fallback, Module.FILES, ModuleAccessState.ALLOWED)
        assertEquals(FilePermissionAccess(), fallback.filePermissionAccess)
        assertEquals(FilePermissionAccess(), WorkspaceAccessSnapshot.failed(IOException()).filePermissionAccess)
    }

    @Test fun `Chat缺少用户接口不能以频道接口代替`() = runBlocking {
        val result = reader(capabilities = capabilities().minus("SYNO.Chat.User"),
            privileges = DesktopAppPrivileges(mapOf(DesktopApplication.CHAT to true), false)).read()
        assertAccess(result, Module.CHAT, ModuleAccessState.UNSUPPORTED)
    }

    @Test fun `摘要失败仅用最小文件和独立照片确认会话`() = runBlocking {
        var files = 0
        val result = reader(summaryFailure = IOException(), file = { files++ }).read()
        assertEquals(1, files)
        assertTrue(result.lookupFailed)
        assertTrue(result.sessionConfirmed)
        assertAccess(result, Module.FILES, ModuleAccessState.ALLOWED)
        assertAccess(result, Module.DOWNLOADS, ModuleAccessState.FAILED)
        assertAccess(result, Module.PHOTOS, ModuleAccessState.UNSUPPORTED)
    }

    @Test fun `仅照片账号可恢复且不继承文件授权`() = runBlocking {
        var photos = 0
        val result = reader(capabilities = capabilities(photos = true), summaryFailure = IOException(),
            file = { throw failure(DsmErrorKind.PERMISSION_DENIED) }, photo = { photos++ }).read()
        assertEquals(1, photos)
        assertTrue(result.sessionConfirmed)
        assertAccess(result, Module.FILES, ModuleAccessState.DENIED)
        assertAccess(result, Module.PHOTOS, ModuleAccessState.ALLOWED)
    }

    @Test fun `文件缺能力时照片仍可独立授权`() = runBlocking {
        val result = reader(capabilities = capabilities(photos = true).minus("SYNO.FileStation.List"),
            summaryFailure = IOException(), file = { error("无文件能力不得请求") }).read()
        assertTrue(result.sessionConfirmed)
        assertAccess(result, Module.FILES, ModuleAccessState.UNSUPPORTED)
        assertAccess(result, Module.PHOTOS, ModuleAccessState.ALLOWED)
    }

    @Test fun `文件授权不能覆盖照片拒绝`() = runBlocking {
        val result = reader(capabilities = capabilities(photos = true),
            privileges = DesktopAppPrivileges(mapOf(DesktopApplication.FILES to true), false),
            photo = { throw failure(DsmErrorKind.PERMISSION_DENIED) }).read()
        assertAccess(result, Module.FILES, ModuleAccessState.ALLOWED)
        assertAccess(result, Module.PHOTOS, ModuleAccessState.DENIED)
    }

    @Test fun `有效空表仍可读取照片但不追加文件读取`() = runBlocking {
        val result = reader(capabilities = capabilities(photos = true),
            file = { error("有效空表不得触发文件降级") }).read()
        assertAccess(result, Module.FILES, ModuleAccessState.DENIED)
        assertAccess(result, Module.PHOTOS, ModuleAccessState.ALLOWED)
    }

    @Test fun `照片必须具有四个JSON的v1能力`() = runBlocking {
        val original = capabilities(photos = true)
        for (name in original.keys.filter { it.startsWith("SYNO.Foto.") }) {
            for (variant in listOf(original.minus(name), original + (name to original.getValue(name).copy(minVersion = 2)),
                original + (name to original.getValue(name).copy(requestFormat = "FORM")))) {
                val result = reader(capabilities = variant, photo = { error("不支持时不得请求") }).read()
                assertAccess(result, Module.PHOTOS, ModuleAccessState.UNSUPPORTED)
            }
        }
        assertTrue(supportsPhotoAccess(original.mapValues { (_, value) -> value.copy(requestFormat = "json") }))
    }

    @Test fun `摘要安全错误认证错误与取消不触发降级请求`() = runBlocking {
        for (error in listOf(SSLHandshakeException("synthetic"), CancellationException(), failure(DsmErrorKind.SESSION_EXPIRED, true),
            failure(DsmErrorKind.INSECURE_ADDRESS), failure(DsmErrorKind.QUICK_CONNECT_IDENTITY_MISMATCH))) {
            val actual = runCatching { reader(capabilities = capabilities(photos = true), summaryFailure = error,
                file = { error("不应读取文件") }, photo = { error("不应读取照片") }).read() }.exceptionOrNull()
            assertSame(error, actual)
        }
    }

    @Test fun `文件降级的认证证书与取消错误停止照片读取`() = runBlocking {
        for (error in listOf(SSLHandshakeException("synthetic"), CancellationException(), failure(DsmErrorKind.SESSION_EXPIRED, true))) {
            val actual = runCatching { reader(capabilities = capabilities(photos = true), summaryFailure = IOException(),
                file = { throw error }, photo = { error("不应读取照片") }).read() }.exceptionOrNull()
            assertSame(error, actual)
        }
    }

    @Test fun `网络失败不确认会话也不冒充登录过期`() = runBlocking {
        val network = IOException()
        val result = reader(summaryFailure = IOException(), file = { throw network }).read()
        assertFalse(result.sessionConfirmed)
        assertSame(network, result.recoveryFailure)
        assertFalse(isExpiredWorkspaceSession(network))
        assertAccess(result, Module.FILES, ModuleAccessState.FAILED)
        for (kind in listOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.FEATURE_UNSUPPORTED,
            DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED, DsmErrorKind.INVALID_RESPONSE, DsmErrorKind.AUTHENTICATION_FAILED)) {
            assertFalse(isExpiredWorkspaceSession(failure(kind)))
        }
        assertTrue(isExpiredWorkspaceSession(failure(DsmErrorKind.SESSION_EXPIRED, true)))
    }

    @Test fun `未读取时仅本地设置和任务可达`() {
        val result = WorkspaceAccessSnapshot.unread()
        assertEquals(setOf(Module.SETTINGS, Module.TRANSFERS), result.availability.filter { it.isAvailable }.map { it.module }.toSet())
        assertFalse(result.sessionConfirmed)
    }

    private fun assertAccess(result: WorkspaceAccessSnapshot, module: Module, expected: ModuleAccessState) {
        val value = result.availability.single { it.module == module }
        assertEquals(expected, value.access)
        assertEquals(expected == ModuleAccessState.ALLOWED, value.isAvailable)
    }
    private fun decode(value: String) = DesktopAppPrivileges.decode(Json.parseToJsonElement(value).jsonObject)
    private fun assertInvalid(value: String) { assertTrue(runCatching { decode(value) }.exceptionOrNull() is DsmFailure) }
    private fun failure(kind: DsmErrorKind, auth: Boolean = false) = DsmFailure(null, "synthetic", "synthetic", auth, kind)
    private fun reader(capabilities: Map<String, ApiCapability> = capabilities(),
        privileges: DesktopAppPrivileges = DesktopAppPrivileges(emptyMap(), false), summaryFailure: Exception? = null,
        file: suspend () -> Unit = {}, photo: suspend () -> Unit = {}) = WorkspaceAccessReader(capabilities,
        readPrivileges = { summaryFailure?.let { throw it }; privileges }, readFileSession = file, readPhotoAccess = photo)
    private fun capabilities(photos: Boolean = false) = buildList {
        addAll(listOf("SYNO.FileStation.List", "SYNO.Chat.Channel", "SYNO.Chat.User", "SYNO.DownloadStation.Task",
            "SYNO.Docker.Container", "SYNO.Virtualization.API.Guest", "SYNO.Core.System"))
        if (photos) addAll(listOf("SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.TeamSpace"))
    }.associateWith { ApiCapability(it, "entry.cgi", 1, 3, "JSON") }
}
