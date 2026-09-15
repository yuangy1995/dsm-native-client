package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient

interface SynologyPhotosProvider {
    val synologyPhotos: SynologyPhotosRepository
}

/** 在组合根之外持有独立 Photos 适配；File Station 只继续为文件管理和设备备份服务。 */
internal class DefaultSynologyPhotosProvider(
    profile: NasProfile,
    session: DsmSession,
    api: DsmApiClient,
    capabilities: Map<String, ApiCapability>,
) : SynologyPhotosProvider {
    override val synologyPhotos: SynologyPhotosRepository by lazy {
        SynologyPhotosRepository(profile, session, api, capabilities)
    }
}
