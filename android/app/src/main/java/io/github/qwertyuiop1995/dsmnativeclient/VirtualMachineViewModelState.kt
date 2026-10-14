package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.*

enum class VirtualMachineImageImportSource {
    NAS,
    LOCAL,
}

/** 本地文件选择器只把非敏感元数据交给表单；URI 由上层短期持有，不进入界面状态。 */
data class VirtualMachineLocalImageSelection(
    val displayName: String,
    val sizeBytes: Long?,
) {
    override fun toString(): String =
        "VirtualMachineLocalImageSelection(sizeKnown=${sizeBytes != null})"
}

/** 上层开始持久化上传流程所需的纯表单结果，不包含本地 URI。 */
data class VirtualMachineLocalImageImportSubmission(
    val imageName: String,
    val image: ValidatedVirtualMachineLocalImage,
    val storage: ManagedResource,
    val stagingDirectory: FileItem,
) {
    override fun toString(): String =
        "VirtualMachineLocalImageImportSubmission(imageType=${image.imageType})"
}

data class VirtualMachineImageImportDraftState(
    val imageName: String = "",
    val imageType: VirtualMachineImageType = VirtualMachineImageType.DISK,
    val source: VirtualMachineImageImportSource = VirtualMachineImageImportSource.NAS,
    val storage: ManagedResource? = null,
    val sourceFile: FileItem? = null,
    val localFile: VirtualMachineLocalImageSelection? = null,
    val localStagingDirectory: FileItem? = null,
    val browserPath: String = "",
    val browserHistory: List<String> = emptyList(),
    val browserItems: Loadable<FilePage> = Loadable.Idle,
) {
    fun toImportOrNull(): VirtualMachineImageImport? {
        if (source != VirtualMachineImageImportSource.NAS) return null
        val name = imageName.trim()
        val file = sourceFile ?: return null
        val targetStorage = storage ?: return null
        if (name.isEmpty() || name.any(Char::isISOControl) || file.path.isBlank() ||
            !file.path.startsWith('/') || file.isDirectory || !file.canRead ||
            !targetStorage.isEligibleForVirtualMachineImageImport()
        ) return null
        return VirtualMachineImageImport(name, imageType, file, targetStorage)
    }

    fun localValidation(): VirtualMachineLocalImageValidation? = localFile?.let {
        validateVirtualMachineLocalImage(it.displayName, it.sizeBytes)
    }

    fun toLocalSubmissionOrNull(): VirtualMachineLocalImageImportSubmission? {
        if (source != VirtualMachineImageImportSource.LOCAL) return null
        val name = imageName.trim()
        val targetStorage = storage ?: return null
        val staging = localStagingDirectory ?: return null
        val validated = (localValidation() as? VirtualMachineLocalImageValidation.Accepted)?.value
            ?: return null
        if (name.isEmpty() || name.any(Char::isISOControl) ||
            !targetStorage.isEligibleForVirtualMachineImageImport() ||
            staging.path.isBlank() || !staging.path.startsWith('/') ||
            !staging.isDirectory || !staging.canWrite
        ) return null
        return VirtualMachineLocalImageImportSubmission(name, validated, targetStorage, staging)
    }
}

data class VirtualMachineMutationWorkspaceState(
    /** VMM 固定分区仅驻留内存，用于任务页可见性与无载荷路由投影。 */
    val selectedTab: VirtualMachineTab = VirtualMachineTab.MACHINES,
    /** 独立只读 Guest 详情只驻留当前 Workspace，不恢复任何写操作状态。 */
    val guestDetailsTargetId: String? = null,
    val guestDetails: Loadable<VirtualMachineGuestDetails> = Loadable.Idle,
    /** 只投影已发现的公开 Task.Info v1 能力，不保存能力原始响应。 */
    val supportsOfficialTasks: Boolean = false,
    val imageImportEditorVisible: Boolean = false,
    val imageImportDraft: VirtualMachineImageImportDraftState? = null,
    /** Task.Info 独立刷新保留上一次成功总览，不把局部失败升级为整页错误。 */
    val taskPolling: VirtualMachineTaskPollingState = VirtualMachineTaskPollingState(),
)

data class VirtualMachineTaskPollingState(
    val refreshing: Boolean = false,
    val failure: DsmFailure? = null,
)

internal fun shouldPollVirtualMachineTasks(
    selectedModule: Module,
    selectedTab: VirtualMachineTab,
    overview: VirtualMachineOverview?,
): Boolean = selectedModule == Module.VIRTUAL_MACHINES &&
    selectedTab == VirtualMachineTab.TASKS &&
    overview?.taskCenterState == VirtualMachineTaskCenterState.AVAILABLE &&
    overview.tasks.any { !it.isFinished }

internal fun WorkspaceState.withVirtualMachineTaskPollingFailure(
    failure: DsmFailure,
): WorkspaceState = copy(
    virtualMachineMutationState = virtualMachineMutationState.copy(
        taskPolling = VirtualMachineTaskPollingState(failure = failure),
    ),
)

internal fun WorkspaceState.withVirtualMachineTaskPollingResult(
    tasks: List<VirtualMachineTask>,
): WorkspaceState {
    val overview = (virtualMachines as? Loadable.Ready)?.value ?: return this
    return copy(
        virtualMachines = Loadable.Ready(
            overview.copy(
                tasks = tasks,
                taskCenterState = VirtualMachineTaskCenterState.AVAILABLE,
                unavailableSections = overview.unavailableSections - VirtualMachineSection.TASKS,
            ),
        ),
        virtualMachineMutationState = virtualMachineMutationState.copy(
            taskPolling = VirtualMachineTaskPollingState(),
        ),
    )
}

internal data class VirtualMachineOverviewRequestToken(
    val profileId: String,
    val generation: Long,
)

internal fun virtualMachineMutationBlocksWorkspaceExit(state: VirtualMachineMutationWorkspaceState): Boolean =
    state.imageImportEditorVisible

internal fun virtualMachineGuestExternalNavigationBlocked(state: VirtualMachineMutationWorkspaceState): Boolean =
    state.imageImportEditorVisible

internal fun virtualMachineOverviewCallbackMatches(
    repositoryMatches: Boolean,
    selectedModule: Module,
    currentProfileId: String,
    token: VirtualMachineOverviewRequestToken,
    globalGeneration: Long,
): Boolean = repositoryMatches && selectedModule == Module.VIRTUAL_MACHINES &&
    currentProfileId == token.profileId && token.generation == globalGeneration

internal fun virtualMachineOrdinaryLoadBlocked(state: VirtualMachineMutationWorkspaceState): Boolean =
    state.imageImportEditorVisible
