package io.github.qwertyuiop1995.dsmnativeclient.testing

import io.github.qwertyuiop1995.dsmnativeclient.data.DesktopApplication
import io.github.qwertyuiop1995.dsmnativeclient.data.DesktopAppPrivileges
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.WorkspaceAccessReader
import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import kotlinx.coroutines.runBlocking

/** 领域回归的明确前置条件：账号已获应用授权；动作能力、对象权限与请求断言仍用原 fixture。 */
internal fun authorizedRepository(
    profile: NasProfile,
    session: DsmSession,
    api: DsmApiClient,
    capabilities: Map<String, ApiCapability>,
): DsmRepository {
    val moduleCapabilities = listOf("SYNO.FileStation.List", "SYNO.Chat.Channel", "SYNO.Chat.User",
        "SYNO.DownloadStation.Task", "SYNO.Docker.Container", "SYNO.Virtualization.API.Guest", "SYNO.Core.System",
        "SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.TeamSpace")
        .associateWith { ApiCapability(it, "entry.cgi", 1, 1, "JSON") }
    val reader = WorkspaceAccessReader(moduleCapabilities,
        readPrivileges = { DesktopAppPrivileges(DesktopApplication.entries.associateWith { true }, true) },
        readFileSession = { error("明确摘要不应探测文件") }, readPhotoAccess = {})
    return DsmRepository(profile, session, api, capabilities, reader).also { runBlocking { it.refreshAccess() } }
}
