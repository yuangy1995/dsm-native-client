package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import android.content.ClipData
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import androidx.core.content.IntentCompat
import java.io.InputStream

internal const val MAX_SHARED_FILES = 100

/** 外部 URI 只在接收期间使用；不把外部 Intent、路径或提供器权限存进任务。 */
internal data class SharedInput(val uris: List<Uri>, val text: String?) {
    override fun toString() = "SharedInput(${uris.size})"
}

internal fun Intent.sharedInput(ownPackage: String): SharedInput? {
    if (action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return null
    val streams = if (action == Intent.ACTION_SEND_MULTIPLE) {
        IntentCompat.getParcelableArrayListExtra(this, Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
    } else listOfNotNull(IntentCompat.getParcelableExtra(this, Intent.EXTRA_STREAM, Uri::class.java))
    val clipped = clipData?.let { clip -> (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri } }.orEmpty()
    val uris = (streams + clipped).distinct()
    require(uris.size <= MAX_SHARED_FILES)
    if (uris.isNotEmpty()) {
        require(flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
        require(uris.all { it.scheme == "content" && !it.authority.isNullOrBlank() &&
            it.authority != ownPackage && !it.authority!!.startsWith("$ownPackage.") && it.userInfo == null })
        return SharedInput(uris, null)
    }
    val text = getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.takeIf { it.isNotBlank() }
        ?: clipData?.takeIf { it.itemCount == 1 }?.getItemAt(0)?.text?.toString()?.takeIf { it.isNotBlank() }
        ?: throw IllegalArgumentException("No shared content")
    require(text.toByteArray(Charsets.UTF_8).size <= 1_048_576)
    return SharedInput(emptyList(), text)
}

internal fun Intent.clearSharedInput() {
    if (action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) return
    removeExtra(Intent.EXTRA_STREAM); removeExtra(Intent.EXTRA_TEXT); removeExtra(Intent.EXTRA_HTML_TEXT)
    removeExtra(Intent.EXTRA_SUBJECT); clipData = null; data = null; action = Intent.ACTION_MAIN
}

internal class SharedSource(val name: String, val mime: String?, val expectedBytes: Long?, val open: () -> InputStream)

internal fun SharedInput.sources(resolver: ContentResolver, textName: String): List<SharedSource> {
    if (text != null) {
        val bytes = text.toByteArray(Charsets.UTF_8)
        return listOf(SharedSource(textName, "text/plain", bytes.size.toLong()) { bytes.inputStream() })
    }
    return uris.map { uri ->
        var name: String? = null
        var bytes: Long? = null
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 && !cursor.isNull(it) }
                    ?.let { name = cursor.getString(it) }
                cursor.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !cursor.isNull(it) }
                    ?.let { bytes = cursor.getLong(it).takeIf { count -> count >= 0 } }
            }
        }
        val filename = name?.takeIf(::validSharedName) ?: throw sharedInputFailure()
        SharedSource(filename, resolver.getType(uri), bytes) {
            resolver.openInputStream(uri) ?: throw sharedInputFailure()
        }
    }
}

internal fun validSharedName(value: String) = value.isNotBlank() && value !in setOf(".", "..") &&
    value.none { it in "/\\\u0000\r\n" }

internal fun sharedInputFailure() = io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure(null,
    "The shared files could not be read", "Share the files again and keep the source app available until copying finishes.",
    kind = io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind.UPLOAD_FAILED)
