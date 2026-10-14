package io.github.qwertyuiop1995.dsmnativeclient.domain

internal enum class FileACLRight(val key: String) {
    READ_DATA("read_data"), WRITE_DATA("write_data"), EXECUTE("exe_file"), APPEND("append_data"),
    DELETE("delete"), DELETE_CHILDREN("delete_sub"), READ_ATTRIBUTES("read_attr"), WRITE_ATTRIBUTES("write_attr"),
    READ_EXTENDED_ATTRIBUTES("read_ext_attr"), WRITE_EXTENDED_ATTRIBUTES("write_ext_attr"),
    READ_PERMISSIONS("read_perm"), CHANGE_PERMISSIONS("change_perm"), TAKE_OWNERSHIP("take_ownership"),
}
internal enum class FileACLInheritance(val key: String) {
    CHILD_FILES("child_files"), CHILD_FOLDERS("child_folders"), THIS_FOLDER("this_folder"), ALL_DESCENDANTS("all_descendants"),
}
internal enum class FileACLEffect(val key: String) { ALLOW("allow"), DENY("deny") }

internal data class FileACLRule(
    val ownerType: String, val ownerName: String, val ownerId: Long? = null, val isInternal: Boolean? = null,
    val effect: FileACLEffect, val rights: Set<FileACLRight>, val inheritance: Set<FileACLInheritance>, val level: Int = 0,
)
internal data class FilePermissionOwner(val name: String, val type: String, val value: String, val canChange: Boolean)
internal data class FilePermissionAccess(val granted: Boolean = false, val administrator: Boolean = false)

/** 内部路径和完整快照只留在当前会话内，不写入恢复记录或诊断。 */
internal data class FilePermissionSnapshot(
    val target: FileItem, val resolvedPath: String, val isACL: Boolean, val canChangePermissions: Boolean,
    val isInherited: Boolean, val rules: List<FileACLRule>, val owner: FilePermissionOwner?,
    val posixMode: String?, val posixOwner: String?, val posixGroup: String?,
) {
    val explicitRules get() = rules.filter { it.level == 0 }
    val inheritedRules get() = rules.filter { it.level > 0 }
}

internal data class FilePermissionChange(
    val baseline: FilePermissionSnapshot, val explicitRules: List<FileACLRule>? = null,
    val posixMode: String? = null, val owner: FileSharePrincipal? = null, val group: FileSharePrincipal? = null,
    val recursive: Boolean = false,
) {
    val hasChanges get() = explicitRules != null || posixMode != null || owner != null || group != null
}

internal fun validFilePermissionMode(mode: String) = mode.length == 3 && mode.all { it in '0'..'7' }

/** 逐项消费相同规则，保留重复条目的数量差异。 */
internal fun changedFilePermissionRules(before: List<FileACLRule>, after: List<FileACLRule>): Pair<List<FileACLRule>, List<FileACLRule>> {
    val remaining = after.toMutableList()
    val removed = before.filter { rule -> !remaining.remove(rule) }
    return removed to remaining
}
