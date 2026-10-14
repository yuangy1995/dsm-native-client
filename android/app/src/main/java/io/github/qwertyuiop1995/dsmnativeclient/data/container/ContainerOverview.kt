package io.github.qwertyuiop1995.dsmnativeclient.data.container

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.parsedLogLevel
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.time.format.ResolverStyle
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 附属分区分别降级；会话、证书与取消停止整个读取，不能用空数据掩盖边界失败。 */
internal suspend fun ContainerRepository.readOverview(): ContainerOverview {
    val containers = controlTargets(resolveProjects = false).map { it.resource }
    val unavailable = mutableSetOf<ContainerSection>()
    suspend fun <T> supplement(section: ContainerSection, read: suspend () -> List<T>): List<T> = try { read() } catch (error: Exception) {
        if (error is CancellationException || error is DsmFailure && error.kind in setOf(DsmErrorKind.TLS_UNTRUSTED,
            DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.AUTHENTICATION_FAILED, DsmErrorKind.WORKSPACE_CHANGED)) throw error
        unavailable += section; emptyList()
    }
    val images = supplement(ContainerSection.IMAGES) { imageDefinitions() }.map { ManagedResource(it.id, it.reference ?: it.repository, "", ResourceState.UNKNOWN) }
    val networks = supplement(ContainerSection.NETWORKS) { networkDefinitions() }.map { ManagedResource(it.id, it.name, "", ResourceState.UNKNOWN) }
    val projects = supplement(ContainerSection.PROJECTS) { projectDefinitions() }
    if (!supportsEvents()) unavailable += ContainerSection.EVENTS
    return ContainerOverview(containers, images, networks, projects.map { ManagedResource(it.id, it.name, "", it.state) }, emptyList(), unavailable, projects)
}
internal suspend fun ContainerRepository.projectDefinitions(): List<ContainerProjectInfo> {
    val data = managementCall("SYNO.Docker.Project", "list")
    val result = data.map { (id, value) ->
        if (id.isBlank()) containerInvalid()
        val row = value as? JsonObject ?: containerInvalid()
        val name = row["name"].containerString() ?: containerInvalid()
        val status = row["status"]?.let { it.containerString() ?: containerInvalid() }
        val count = row["containerIds"]?.let { values ->
            val array = values as? JsonArray ?: containerInvalid()
            val ids = array.map { it.containerString() ?: containerInvalid() }
            if (ids.distinct().size != ids.size) containerInvalid()
            ids.size
        }
        ContainerProjectInfo(id, name, when (status?.lowercase(Locale.ROOT)) {
            "running" -> ResourceState.RUNNING
            "stopped" -> ResourceState.STOPPED
            "building", "starting", "stopping" -> ResourceState.WAITING
            "error", "failed" -> ResourceState.ERROR
            else -> ResourceState.UNKNOWN
        }, count)
    }
    if (result.map { it.name }.distinct().size != result.size) containerInvalid()
    return result.sortedBy { it.name }
}
internal suspend fun ContainerRepository.containerEvents(): List<LogEntry> {
    val entries = mutableListOf<LogEntry>(); var expectedTotal: Long? = null
    val formatter = DateTimeFormatter.ofPattern("uuuu/MM/dd HH:mm:ss", Locale.ROOT).withResolverStyle(ResolverStyle.STRICT)
    while (true) {
        currentCoroutineContext().ensureActive()
        val offset = entries.size
        val data = managementCall("SYNO.Docker.Log", "list", mapOf("action" to JsonPrimitive("load"), "offset" to JsonPrimitive(offset),
            "limit" to JsonPrimitive(1000), "sort_by" to JsonPrimitive("time"), "sort_dir" to JsonPrimitive("DESC"),
            "loglevel" to JsonPrimitive(""), "filter_content" to JsonPrimitive(""), "datefrom" to JsonPrimitive(0), "dateto" to JsonPrimitive(0)))
        fun number(key: String): Long? = data[key]?.let { element ->
            val value = element as? JsonPrimitive ?: containerInvalid()
            value.takeIf { !it.isString }?.longOrNull?.takeIf { it >= 0 } ?: containerInvalid()
        }
        if (number("offset")?.let { it != offset.toLong() } == true) containerInvalid()
        val total = number("total")
        if (expectedTotal != null && total != expectedTotal) containerInvalid()
        expectedTotal = total
        val rows = data["logs"] as? JsonArray ?: containerInvalid()
        for ((index, element) in rows.withIndex()) {
            val row = element as? JsonObject ?: containerInvalid()
            fun text(key: String) = (row[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: containerInvalid()
            val event = text("event"); val user = text("user"); val time = text("time")
            val local = runCatching { LocalDateTime.parse(time, formatter) }.getOrNull() ?: containerInvalid()
            entries += LogEntry("${offset + index}:${containerDigest(time + event + user)}", parsedLogLevel(text("level")), null, user, event, local)
        }
        if (total == null || entries.size.toLong() == total) return entries
        if (entries.size > total || rows.isEmpty()) containerInvalid()
    }
}
