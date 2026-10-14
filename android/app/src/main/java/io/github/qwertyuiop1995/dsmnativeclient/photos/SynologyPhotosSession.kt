package io.github.qwertyuiop1995.dsmnativeclient.photos

import android.content.Context
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.allows
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/** 照片会话与主模型仓储同生共灭；切换账号先取消请求、播放和临时导出，再发布新仓储。 */
internal class SynologyPhotosSession(private val scope: CoroutineScope,
    private val uploadStore: () -> SynologyPhotoUploadStore? = { null },
    private val editStore: () -> SynologyPhotoEditStore? = { null },
    private val albumStore: () -> SynologyPhotoAlbumStore? = { null },
    private val deletionStore: () -> SynologyPhotoDeletionStore? = { null },
    private val automaticPreviewCache: java.io.File? = null,
    private val execution: io.github.qwertyuiop1995.dsmnativeclient.background.WorkspaceExecution? = null,
) : ReadWriteProperty<Any?, DsmRepository?> {
    constructor(scope: CoroutineScope, context: Context, execution: io.github.qwertyuiop1995.dsmnativeclient.background.WorkspaceExecution) : this(scope, { SynologyPhotoUploadStore(context) }, { SynologyPhotoEditStore(context) }, { SynologyPhotoAlbumStore(context) }, { SynologyPhotoDeletionStore(context) }, context.cacheDir, execution)
    private val uploads by lazy(uploadStore)
    private val edits by lazy(editStore)
    private val albums by lazy(albumStore)
    private val deletions by lazy(deletionStore)
    private var repository: DsmRepository? = null
    private var model: SynologyPhotosModel? = null

    init {
        scope.coroutineContext[Job]?.invokeOnCompletion { model?.close() }
    }

    override fun getValue(thisRef: Any?, property: KProperty<*>): DsmRepository? = repository

    override fun setValue(thisRef: Any?, property: KProperty<*>, value: DsmRepository?) {
        if (repository !== value) {
            model?.close()
            model = null
        }
        repository = value
    }

    fun modelFor(profileId: String, activeProfileId: String?): SynologyPhotosModel? {
        val current = repository ?: return null
        if (!current.availability().allows(Module.PHOTOS)) return null
        if (profileId != activeProfileId || profileId != current.synologyPhotos.profileId) return null
        return model ?: SynologyPhotosModel(current.synologyPhotos, scope, uploadStore = uploads, editStore = edits, albumStore = albums, deletionStore = deletions,
            automaticPreviewCache = automaticPreviewCache, execution = execution, uploadOwner = current.owner, requireUploadOwner = current::requireCurrentOwner).also { model = it }
    }

    fun revokeAccess() { model?.revokeAccess() }
    fun removeProfile(profileId: String) { uploads?.removeProfile(profileId); edits?.removeProfile(profileId); albums?.removeProfile(profileId); deletions?.removeProfile(profileId) }
}
