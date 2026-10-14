package io.github.qwertyuiop1995.dsmnativeclient.domain

/** 日志仅供当前页显示，不进入恢复记录或诊断输出。 */
internal data class NasLogItem(val id: String, val time: String?, val source: String?, val level: LogLevel,
    val account: String?, val message: String) { override fun toString() = "NasLogItem" }
internal data class NasLogPage(val offset: Int, val limit: Int, val entries: List<NasLogItem>, val total: Int?,
    val infoCount: Int?, val warningCount: Int?, val errorCount: Int?) {
    val hasNext get() = entries.isNotEmpty() && if (total != null) offset + entries.size < total else entries.size == limit
    override fun toString() = "NasLogPage($offset)"
}
/** 只保留进程编号和末级名称，不保存命令行、账号、目录或环境变量。 */
internal data class NasSystemProcess(val id: String, val name: String, val status: String?, val groupId: String?)
internal data class NasProcessGroup(val id: String, val name: String, val status: String?, val count: Int?)
internal data class NasProcessDirectory(val processes: List<NasSystemProcess>, val groups: List<NasProcessGroup>,
    val total: Int, val truncated: Boolean, val groupsUnavailable: Boolean)
