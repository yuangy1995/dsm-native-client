package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/** 照片会话与主模型仓储同生共灭；切换账号先取消请求、播放和临时导出，再发布新仓储。 */
internal class SynologyPhotosSession(private val scope: CoroutineScope) : ReadWriteProperty<Any?, DsmRepository?> {
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
        if (profileId != activeProfileId || profileId != current.synologyPhotos.profileId) return null
        return model ?: SynologyPhotosModel(current.synologyPhotos, scope).also { model = it }
    }
}
