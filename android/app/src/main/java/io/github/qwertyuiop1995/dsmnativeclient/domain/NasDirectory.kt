package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable internal enum class NasDirectoryKind { ACCOUNT, GROUP }
@Serializable internal enum class NasDirectoryAction { CREATE, EDIT, DELETE }
@Serializable internal enum class NasDirectoryStage { SUBMITTED, ACCEPTED, COMPLETED, REJECTED }
internal enum class NasDirectoryProblem { INVALID, INCOMPLETE, CHANGED, PERMISSION, BUSY, UNKNOWN }
internal class NasDirectoryFailure(val problem: NasDirectoryProblem) : Exception(problem.name)

/** 密码仅随当次表单与请求存在，不进入恢复记录。 */
internal data class NasDirectoryChange(
    val kind: NasDirectoryKind, val action: NasDirectoryAction,
    val name: String, val description: String = "", val email: String = "", val disabled: Boolean = false,
    val groups: List<String>? = null, val password: String = "", val passwordConfirmation: String = "",
    val account: NasAccount? = null, val group: NasGroup? = null,
    val groupsBaseline: List<NasGroup>? = null,
) {
    val originalId get() = account?.id ?: group?.id
    val requiresAcknowledgement get() = action == NasDirectoryAction.CREATE || password.isNotEmpty()
    override fun toString() = "NasDirectoryChange($kind, $action)"
}
