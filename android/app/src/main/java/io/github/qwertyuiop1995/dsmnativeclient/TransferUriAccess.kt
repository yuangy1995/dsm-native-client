package io.github.qwertyuiop1995.dsmnativeclient

import android.content.Context
import android.content.Intent
import android.net.Uri
import io.github.qwertyuiop1995.dsmnativeclient.data.TransferStore

/** 统一处理任务结束时的系统文件授权；引用属于整个应用，不能按当前 NAS 直接撤销。 */
internal class TransferUriAccess(context: Context, private val transfers: TransferStore) {
    private val resolver = context.contentResolver

    fun deleteIncomplete(uri: Uri, excludingRecordId: String? = null) {
        if (transfers.hasReadGrantReference(uri.toString()) ||
            transfers.hasDownloadDestinationReference(uri.toString(), excludingRecordId)) return
        runCatching { resolver.delete(uri, null, null) }
    }

    fun releaseRead(uri: Uri, excludingRecordId: String? = null): Boolean {
        if (transfers.hasReadGrantReference(uri.toString(), excludingRecordId) ||
            transfers.hasDownloadDestinationReference(uri.toString())) return true
        if (resolver.persistedUriPermissions.none { it.uri == uri && it.isReadPermission }) return true
        runCatching { resolver.releasePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
        return resolver.persistedUriPermissions.none { it.uri == uri && it.isReadPermission }
    }

    fun releaseDownload(uri: Uri, excludingRecordId: String? = null) {
        if (transfers.hasDownloadDestinationReference(uri.toString(), excludingRecordId)) return
        val flags = Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
            if (transfers.hasReadGrantReference(uri.toString())) 0 else Intent.FLAG_GRANT_READ_URI_PERMISSION
        runCatching { resolver.releasePersistableUriPermission(uri, flags) }
    }
}
