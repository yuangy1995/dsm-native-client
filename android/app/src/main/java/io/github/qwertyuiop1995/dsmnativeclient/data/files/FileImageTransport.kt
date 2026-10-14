package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import java.io.File

/** 文件缩略图与分享页图片共用当前工作区的受控传输，不把鉴权地址交给图片组件。 */
internal class FileImageTransport(private val profile: NasProfile, private val session: DsmSession,
    private val api: DsmApiClient, private val capability: (String) -> ApiCapability) {
    suspend fun thumbnail(path: String): ByteArray = api.readBinary(profile, session, capability("SYNO.FileStation.Thumb"), 2, "get",
        mapOf("path" to path, "size" to "small", "rotate" to "0"), maximumBytes = 8L * 1024L * 1024L)

    suspend fun download(image: FileThemeImage, destination: File) {
        when (image.source) {
            FileThemeImageSource.DEFAULT -> api.downloadThemeBackground(profile, image.path, destination)
            FileThemeImageSource.NAS -> destination.outputStream().buffered().use { output ->
                api.downloadBinaryToOutput(profile, session, capability("SYNO.FileStation.Thumb"), 2, "get",
                    mapOf("path" to image.path, "size" to "large", "rotate" to "0"), output, expectedBytes = null)
            }
            FileThemeImageSource.HISTORY -> destination.outputStream().buffered().use { output ->
                api.downloadBinaryToOutput(profile, session, capability(FILE_THEME_IMAGE_API), 1, "get",
                    mapOf("type" to image.kind.requestType, "index" to (image.historyIndex ?: throw settingsChanged()).toString(), "is_thumbnail" to "true"),
                    output, expectedBytes = null)
            }
        }
    }
    suspend fun upload(input: FileThemeUpload, kind: FileThemeImageKind): kotlinx.serialization.json.JsonObject {
        return api.uploadThemeImage(profile, session, capability(FILE_THEME_IMAGE_API), kind.requestType, input.filename, input.file, input.digest)
    }
}
