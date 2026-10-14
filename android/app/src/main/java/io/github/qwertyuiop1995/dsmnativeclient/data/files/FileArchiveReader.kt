package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

/** 公开 Extract v2 的分页读取与提交前清单，不保留密码或跨归档缓存。 */
internal class FileArchiveReader(private val read: suspend (Map<String, String>) -> JsonObject) {
    suspend fun page(filePath: String, parentId: Int = -1, offset: Int = 0, limit: Int = 200,
                     codepage: String? = null, password: String? = null): ArchiveItemPage {
        if (!isFileMutationPath(filePath) || parentId < -1 || offset < 0 || limit !in 1..500) throw invalidArchiveSelection()
        currentCoroutineContext().ensureActive()
        val data = try {
            read(buildMap {
                put("file_path", filePath); put("item_id", parentId.toString()); put("offset", offset.toString())
                put("limit", limit.toString()); put("sort_by", "name"); put("sort_direction", "asc")
                codepage?.takeIf(String::isNotEmpty)?.let { put("codepage", it) }
                password?.takeIf(String::isNotEmpty)?.let { put("password", it) }
            })
        } catch (failure: DsmFailure) {
            if (failure.code == 1403) throw failure.copy(kind = DsmErrorKind.ARCHIVE_PASSWORD_REQUIRED)
            throw failure
        }
        val rows = data["items"] as? JsonArray ?: throw archiveListFailure()
        val total = data["total"]?.let { (it as? JsonPrimitive)?.intOrNull ?: throw archiveListFailure() }
        if (rows.size > limit || total != null && (total < offset + rows.size || rows.isEmpty() && offset < total)) throw archiveListFailure()
        val items = rows.map { element ->
            val row = element as? JsonObject ?: throw archiveListFailure()
            // 官方字段表为 itemid，同页示例为 item_id。
            val id = ((row["itemid"] ?: row["item_id"]) as? JsonPrimitive)?.intOrNull ?: throw archiveListFailure()
            fun text(key: String) = (row[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: throw archiveListFailure()
            val path = text("path")
            val name = text("name")
            val directory = (row["is_dir"] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: throw archiveListFailure()
            val size = row["size"]?.let { (it as? JsonPrimitive)?.longOrNull ?: throw archiveListFailure() }
            if (id < 0 || !isArchiveRelativePath(path) || path.substringAfterLast('/') != name || size != null && size < 0) throw archiveListFailure()
            ArchiveItem(id, name, path, directory, size)
        }
        if (items.map(ArchiveItem::id).distinct().size != items.size || items.map(ArchiveItem::path).distinct().size != items.size) throw archiveListFailure()
        return ArchiveItemPage(items, offset, total, total?.let { offset + items.size < it } ?: (items.size == limit))
    }

    suspend fun children(filePath: String, parentId: Int = -1, codepage: String? = null, password: String? = null): List<ArchiveItem> {
        val result = mutableListOf<ArchiveItem>()
        val ids = mutableSetOf<Int>()
        val paths = mutableSetOf<String>()
        var total: Int? = null
        do {
            val page = page(filePath, parentId, result.size, codepage = codepage, password = password)
            if (total != null && page.total != total || page.hasMore && page.items.isEmpty()) throw archiveListFailure()
            if (page.items.any { !ids.add(it.id) || !paths.add(it.path) }) throw archiveListFailure()
            result += page.items
            total = page.total
        } while (page.hasMore)
        return result
    }

    suspend fun inventory(filePath: String, options: FileExtractionOptions): List<ArchiveItem> {
        if (!options.isValid) throw invalidArchiveSelection()
        val result = mutableListOf<ArchiveItem>()
        val ids = mutableSetOf<Int>()
        val paths = mutableSetOf<String>()
        val pending = ArrayDeque<Pair<Int, String>>().apply { add(-1 to "") }
        while (pending.isNotEmpty()) {
            currentCoroutineContext().ensureActive()
            val (parentId, parentPath) = pending.removeFirst()
            for (item in children(filePath, parentId, options.codepage, options.password)) {
                if (item.path.substringBeforeLast('/', "") != parentPath || !ids.add(item.id) || !paths.add(item.path)) throw archiveListFailure()
                result += item
                if (item.isDirectory) pending.add(item.id to item.path)
            }
        }
        val selected = when (val selection = options.selection) {
            FileArchiveSelection.All -> result
            is FileArchiveSelection.Items -> {
                if (selection.items.any { it !in result }) throw invalidArchiveSelection()
                result.filter { entry -> selection.items.any { it.id == entry.id || it.isDirectory && entry.path.startsWith(it.path + "/") } }
            }
        }
        if (selected.isEmpty()) throw invalidArchiveSelection()
        return selected
    }
}

internal fun extractionOutputs(filePath: String, destinationPath: String, options: FileExtractionOptions,
                               inventory: List<ArchiveItem>): List<FileServerMutationExpectedOutput> {
    val folderName = filePath.substringAfterLast('/').substringBeforeLast('.')
    if (options.createSubfolder && !isArchiveRelativePath(folderName)) throw invalidArchiveSelection()
    val root = destinationPath.trimEnd('/') + if (options.createSubfolder) "/$folderName" else ""
    val output = inventory.filter { options.keepDirectories || !it.isDirectory }.map { entry ->
        val path = root + "/" + if (options.keepDirectories) entry.path else entry.name
        if (!isFileMutationPath(path) || path == filePath || filePath.startsWith(path + "/")) throw invalidArchiveSelection()
        FileServerMutationExpectedOutput(path, entry.isDirectory, expectedBytes = entry.size.takeUnless { entry.isDirectory },
            requiresTaskCompletion = options.overwrite)
    }
    if (output.isEmpty() || output.map { it.path }.distinct().size != output.size) throw invalidArchiveSelection()
    return output
}

internal fun archiveListFailure() = DsmFailure(null, "Invalid archive listing", "Read the archive again.", kind = DsmErrorKind.ARCHIVE_CONTENT_UNAVAILABLE)
internal fun invalidArchiveSelection() = DsmFailure(null, "Invalid archive selection", "Choose the archive contents again.", kind = DsmErrorKind.ARCHIVE_INVALID_SELECTION)
