package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.data.parseFilePageFixture
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage
import kotlinx.serialization.json.JsonObject

/**
 * File Station 的公开只读列表入口。
 *
 * Gateway 保留 DsmRepository 中的能力版本选择与请求发送；本类只固定已验证的
 * 列表参数和统一的文件页解码，不包含任何创建、移动、删除或上传逻辑。
 */
internal interface DsmFileStationRepositoryGateway {
    suspend fun call(
        apiName: String,
        method: String,
        parameters: Map<String, String>,
    ): JsonObject

    fun jsonStrings(values: List<String>): String
}

internal class DsmFileStationRepository(
    private val gateway: DsmFileStationRepositoryGateway,
) {
    suspend fun listShares(
        offset: Int = 0,
        limit: Int = 200,
        sortBy: String = "name",
        sortAscending: Boolean = true,
    ): FilePage {
        val data = gateway.call(
            "SYNO.FileStation.List",
            "list_share",
            mapOf(
                "offset" to offset.toString(),
                "limit" to limit.toString(),
                "sort_by" to sortBy,
                "sort_direction" to if (sortAscending) "asc" else "desc",
                "additional" to "[\"real_path\",\"owner\",\"time\",\"perm\",\"mount_point_type\",\"volume_status\"]",
            ),
        )
        return parseFilePageFixture(data, "shares")
    }

    suspend fun listDirectory(
        path: String,
        offset: Int = 0,
        limit: Int = 200,
        sortBy: String = "name",
        sortAscending: Boolean = true,
        fileType: String = "all",
    ): FilePage {
        val data = gateway.call(
            "SYNO.FileStation.List",
            "list",
            mapOf(
                "folder_path" to path,
                "offset" to offset.toString(),
                "limit" to limit.toString(),
                "sort_by" to sortBy,
                "sort_direction" to if (sortAscending) "asc" else "desc",
                "filetype" to fileType,
                "additional" to "[\"real_path\",\"size\",\"owner\",\"time\",\"perm\",\"mount_point_type\"]",
            ),
        )
        return parseFilePageFixture(data, "files")
    }

    suspend fun fileInfo(path: String): FileItem? {
        val data = gateway.call(
            "SYNO.FileStation.List",
            "getinfo",
            mapOf(
                "path" to gateway.jsonStrings(listOf(path)),
                "additional" to "[\"real_path\",\"size\",\"owner\",\"time\",\"perm\",\"mount_point_type\"]",
            ),
        )
        return parseFilePageFixture(data, "files").items.firstOrNull { it.path == path }
    }
}
