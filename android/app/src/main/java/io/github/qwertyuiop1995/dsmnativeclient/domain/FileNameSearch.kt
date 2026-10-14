package io.github.qwertyuiop1995.dsmnativeclient.domain

/** 与 Mac 的斜线语法一致；普通名称关键词仍由 NAS 处理。 */
internal data class FileNameSearch(val isRegularExpression: Boolean, val expression: Regex? = null) {
    companion object {
        fun parse(query: String): FileNameSearch {
            if (!query.startsWith('/') || query.length < 2) return FileNameSearch(false)
            for (index in query.lastIndex downTo 1) {
                if (query[index] != '/') continue
                var backslashes = 0
                var cursor = index - 1
                while (cursor >= 1 && query[cursor] == '\\') { backslashes++; cursor-- }
                if (backslashes % 2 != 0) continue
                val flags = query.substring(index + 1)
                if (flags.any { it != 'i' }) return FileNameSearch(false)
                val options = if ('i' in flags) setOf(RegexOption.IGNORE_CASE) else emptySet()
                val expression = try { Regex(query.substring(1, index), options) } catch (_: IllegalArgumentException) { null }
                return FileNameSearch(true, expression)
            }
            return FileNameSearch(false)
        }
    }
}
