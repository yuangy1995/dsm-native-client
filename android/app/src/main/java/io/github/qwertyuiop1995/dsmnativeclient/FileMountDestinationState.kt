package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.mountReadFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.*

internal data class FileMountDestinationState(
    val path: String = "", val item: FileItem? = null, val items: Loadable<List<FileItem>> = Loadable.Idle, val filter: String = "",
)

/** ISO 与远程连接使用同一目录读取和分页规则，选择后写前仍会重新核对。 */
internal suspend fun loadMountDestinations(repo: DsmRepository, path: String): Pair<FileItem?, List<FileItem>> {
    val location = if (path.isNotEmpty()) repo.fileMounts.item(path) else null
    val items = mutableListOf<FileItem>()
    do {
        val page = if (path.isEmpty()) repo.listShares(items.size, 200) else repo.listDirectory(path, items.size, 200, fileType = "dir")
        if (page.offset != items.size || page.items.isEmpty() && items.size < page.total ||
            page.items.any { item -> items.any { it.path == item.path } }) throw mountReadFailure()
        items += page.items
    } while (items.size < page.total)
    return location to items.filter(FileItem::isDirectory)
}
