package io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines

import java.net.URI
import java.util.UUID
import okhttp3.HttpUrl.Companion.toHttpUrl

internal enum class VmmConsoleProblem { TARGET, RESOURCE, RESPONSE, CLOSED, QUEUE }
internal class VmmConsoleFailure(val problem: VmmConsoleProblem) : RuntimeException(problem.name)
internal fun consoleFail(problem: VmmConsoleProblem = VmmConsoleProblem.RESOURCE): Nothing = throw VmmConsoleFailure(problem)

/** 每个窗口使用独立的本地来源，只映射已记录的 noVNC 静态资源与单个连接。 */
internal class VmmConsolePolicy(base: String, machine: String, name: String, keyboard: String, val id: UUID = UUID.randomUUID(), port: Int? = null) {
    val document: String
    val socket: String
    val localOrigin = "https://$id.invalid"
    val localDocument: String
    val localSocket: String
    val bridge: String
    private val prefix: String
    private val remoteOrigin: String
    init {
        val origin = uri(base)
        if (origin.scheme != "https" || origin.host.isNullOrEmpty() || origin.rawUserInfo != null || origin.rawQuery != null || origin.rawFragment != null ||
            !segment(machine) || !segment(keyboard) || keyboard == "Default" || name.isEmpty() || name.any(Char::isISOControl)) consoleFail(VmmConsoleProblem.TARGET)
        val alias = origin.rawPath.orEmpty().trim('/')
        if (alias.isNotEmpty() && !segment(alias) || origin.rawPath.orEmpty() !in setOf("", "/", "/$alias", "/$alias/")) consoleFail(VmmConsoleProblem.TARGET)
        prefix = if (alias.isEmpty()) "" else "/$alias"
        if (port != null && port !in 1..65535) consoleFail(VmmConsoleProblem.TARGET)
        val baseUrl = base.toHttpUrl().newBuilder().apply { if (port != null) port(port) }.build()
        remoteOrigin = baseUrl.newBuilder().encodedPath("/").query(null).build().toString().removeSuffix("/")
        document = baseUrl.newBuilder().encodedPath("$prefix/webman/3rdparty/Virtualization/noVNC/vnc.html").query(null)
            .addQueryParameter("autoconnect", "true").addQueryParameter("reconnect", "false")
            .addQueryParameter("path", "synovirtualization/ws/$machine").addQueryParameter("title", name)
            .addQueryParameter("app_id", id.toString()).addQueryParameter("kb_layout", keyboard)
            .addQueryParameter("app_alias", alias).addQueryParameter("v", "").build().toString()
        socket = "$remoteOrigin$prefix/synovirtualization/ws/$machine?app_id=$id".replaceFirst("https:", "wss:")
        localDocument = localOrigin + document.removePrefix(remoteOrigin)
        localSocket = "wss://$id.invalid" + socket.substringAfter(remoteOrigin.replaceFirst("https:", "wss:"))
        bridge = "$localOrigin$prefix/webman/3rdparty/Virtualization/noVNC/lanstash-$id.js"
    }
    override fun toString() = "VmmConsolePolicy"
    fun allowsNavigation(value: String) = value == localDocument
    fun allowsSocket(value: String): Boolean = value == localSocket || value == localSocket.replaceFirst("wss:", "ws:")
    fun resource(local: String): Pair<String, String> {
        val parts = uri(local)
        if (parts.scheme != "https" || parts.host != "$id.invalid" || parts.port != -1 || parts.rawUserInfo != null || parts.rawFragment != null) consoleFail()
        if (local == localDocument) return document to "text/html"
        val path = parts.rawPath.orEmpty()
        if (!Regex("[A-Za-z0-9_./-]+").matches(path) || "//" in path || path.split('/').any { it == "." || it == ".." }) consoleFail()
        if (parts.rawQuery != null && !Regex("v=[A-Za-z0-9._-]{0,128}").matches(parts.rawQuery)) consoleFail()
        val root = "$prefix/webman/3rdparty/Virtualization/noVNC/"
        val icon = "$prefix/webman/3rdparty/Virtualization/images/VirtualManagement_"
        val mime = if (path.startsWith(icon) && path.removePrefix(icon) in setOf("16.png", "24.png", "32.png", "48.png", "64.png", "72.png", "256.png")) "image/png"
            else {
                if (!path.startsWith(root)) consoleFail()
                val relative = path.removePrefix(root)
                when {
                    relative == "app/sounds/bell.oga" -> "audio/ogg"
                    Regex("app/locale/[A-Za-z0-9_-]{1,16}\\.json").matches(relative) -> "application/json"
                    else -> when (relative.substringAfterLast('.').lowercase()) {
                        "js" -> "text/javascript"; "css" -> "text/css"; "png" -> "image/png"; "jpg", "jpeg" -> "image/jpeg"
                        "svg" -> "image/svg+xml"; "gif" -> "image/gif"; "woff" -> "font/woff"; "woff2" -> "font/woff2"; "ttf" -> "font/ttf"
                        else -> consoleFail()
                    }
                }
            }
        return (remoteOrigin + path + (parts.rawQuery?.let { "?$it" } ?: "")) to mime
    }
    fun locale(local: String): Pair<String, String> = resource(local).also { if (it.second != "application/json") consoleFail() }
    companion object {
        private fun uri(value: String): URI = try { URI(value) } catch (_: Exception) { consoleFail(VmmConsoleProblem.TARGET) }
        private fun segment(value: String) = Regex("[A-Za-z0-9_-]+").matches(value)
        const val CONTENT_POLICY = "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; media-src 'self'; connect-src 'none'; frame-src 'none'; object-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'"
    }
}

internal suspend fun VmmManagementRepository.consoleKeyboard(expected: VmmControlTarget): String {
    if (!supports(VmmSource.INTERNAL.guestApi, 2)) vmmUnsupported()
    val target = controlTargets().singleOrNull { it.id == expected.id } ?: vmmConflict()
    if (target.name != expected.name || target.status != "running" || expected.status != "running") vmmConflict()
    val value = call(VmmSource.INTERNAL.guestApi, "get", 2, mapOf("guest_id" to kotlinx.serialization.json.JsonPrimitive(target.id)))
    if (value["guest_id"].vmmText() != target.id || value["name"].vmmText() != target.name || value["is_online"] != kotlinx.serialization.json.JsonPrimitive(true)) vmmInvalid()
    val keyboard = value["kb_layout"].vmmText() ?: vmmInvalid()
    return if (keyboard == "Default") call("SYNO.Virtualization.Setting.General", "get", 1)["kb_layout"].vmmText()?.takeIf { it != "Default" } ?: vmmInvalid() else keyboard
}
