package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.FileVFSCloudAuthorization
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileVFSCloudRequest
import kotlinx.serialization.json.*
import java.net.URI
import java.net.URLDecoder
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.Locale

/** 一次浏览器回调的有界解析；不转发 HTTP，也不记录正文或任意响应字段。 */
internal object FileVFSCloudCallbackHTTP {
    class Request(val host: String, val path: String, private val query: String?, private val contentType: String?, private val body: ByteArray) {
        fun authorization(request: FileVFSCloudRequest, expectedHost: String, expectedPath: String): FileVFSCloudAuthorization {
            require(host == expectedHost && (path == expectedPath || path.startsWith("$expectedPath/")))
            val fields = form(query.orEmpty()).toMutableMap()
            if (body.isNotEmpty()) {
                val incoming = when (contentType?.substringBefore(';')?.trim()?.lowercase(Locale.ROOT)) {
                    "application/json" -> jsonFields(utf8(body))
                    "application/x-www-form-urlencoded" -> form(utf8(body))
                    else -> throw IllegalArgumentException("Unsupported callback body")
                }
                merge(fields, incoming)
            }
            fields.remove("data")?.let { merge(fields, jsonFields(it)) }
            require(fields["callback"] == request.callbackName)
            val value = buildJsonObject {
                for (key in listOf("callback", "account", "client_id", "access_token", "refresh_token")) fields[key]?.let { put(key, it) }
                fields["expires_in"]?.let { value -> put("expires_in", value.toIntOrNull()?.takeIf { it >= 0 }
                    ?: throw IllegalArgumentException("Invalid callback expiry")) }
            }
            return FileVFSCloudAuthorization.decode(value, request)
        }
        override fun toString() = "FileVFSCloudCallbackHTTP.Request([redacted])"
    }

    fun decode(bytes: ByteArray): Request? {
        require(bytes.size <= 131_072)
        val split = (0..bytes.size - 4).firstOrNull { i -> bytes[i] == 13.toByte() && bytes[i + 1] == 10.toByte() &&
            bytes[i + 2] == 13.toByte() && bytes[i + 3] == 10.toByte() }
        if (split == null) { require(bytes.size <= 16_384); return null }
        require(split <= 16_384)
        val lines = utf8(bytes.copyOfRange(0, split)).split("\r\n")
        val start = lines.first().split(' ')
        require(start.size == 3 && start[0] in setOf("GET", "POST") && start[1].startsWith('/') && start[2] in setOf("HTTP/1.1", "HTTP/1.0"))
        val uri = URI(start[1]); require(uri.host == null && uri.rawFragment == null)
        val headers = mutableMapOf<String, String>()
        lines.drop(1).forEach { line ->
            val colon = line.indexOf(':'); require(colon > 0)
            val key = line.substring(0, colon).lowercase(Locale.ROOT)
            require(key.none { it.isWhitespace() || it.isISOControl() } && key !in headers)
            headers[key] = line.substring(colon + 1).trim()
        }
        val host = headers["host"] ?: throw IllegalArgumentException("Missing callback host")
        require("transfer-encoding" !in headers && (start[0] != "POST" || "content-length" in headers))
        val lengthText = headers["content-length"] ?: "0"
        require(lengthText.isNotEmpty() && lengthText.all { it in '0'..'9' })
        val length = lengthText.toIntOrNull()?.takeIf { it in 0..114_688 } ?: throw IllegalArgumentException("Invalid callback length")
        if (bytes.size < split + 4 + length) return null
        require(bytes.size == split + 4 + length)
        return Request(host, uri.rawPath, uri.rawQuery, headers["content-type"], bytes.copyOfRange(split + 4, bytes.size))
    }
    private fun utf8(value: ByteArray) = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(value)).toString()
    private fun form(value: String): Map<String, String> {
        if (value.isEmpty()) return emptyMap()
        val result = mutableMapOf<String, String>()
        value.split('&').forEach { pair ->
            val equals = pair.indexOf('='); require(equals >= 0)
            val key = URLDecoder.decode(pair.substring(0, equals), "UTF-8")
            require(key !in result)
            result[key] = URLDecoder.decode(pair.substring(equals + 1), "UTF-8")
        }
        return result
    }
    private fun jsonFields(value: String): Map<String, String> {
        val objectValue = Json.parseToJsonElement(value) as? JsonObject ?: throw IllegalArgumentException("Invalid callback object")
        return buildMap {
            objectValue.forEach { (key, value) ->
                val primitive = value as? JsonPrimitive
                when {
                    primitive?.isString == true -> put(key, primitive.content)
                    key == "expires_in" && primitive != null && primitive != JsonNull -> put(key, primitive.intOrNull?.toString()
                        ?: throw IllegalArgumentException("Invalid callback expiry"))
                }
            }
        }
    }
    private fun merge(target: MutableMap<String, String>, incoming: Map<String, String>) {
        incoming.forEach { (key, value) -> require(key !in target || target[key] == value); target[key] = value }
    }
}
