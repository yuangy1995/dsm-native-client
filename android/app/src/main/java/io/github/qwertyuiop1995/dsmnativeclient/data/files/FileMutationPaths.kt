package io.github.qwertyuiop1995.dsmnativeclient.data.files

/** 只验证目标，不裁剪文件名空白或解析点路径，避免请求和互斥锁指向不同文件。 */
internal fun isFileMutationPath(path: String, allowRoot: Boolean = false): Boolean =
    if (path == "/") allowRoot else path.startsWith('/') &&
        path.drop(1).split('/').all { it.isNotEmpty() && it != "." && it != ".." }

/** 已观察的精确空串表示普通位置；缺字段仍是未知，不能授予写入。 */
internal fun isNormalFileMountType(type: String?) = type == "normal" || type == ""
