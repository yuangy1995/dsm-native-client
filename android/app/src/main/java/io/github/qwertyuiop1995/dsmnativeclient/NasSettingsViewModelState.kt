package io.github.qwertyuiop1995.dsmnativeclient

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.Locale

@kotlinx.serialization.Serializable
enum class DdnsMutationOperation { TEST, SAVE, DELETE, ADDRESS_REFRESH }

enum class PackageMutationOperation { START, STOP, UNINSTALL }

enum class DirectoryEntryKind { ACCOUNT, GROUP }

data class DirectoryEntryMutationTarget(
    val kind: DirectoryEntryKind,
    val account: io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount? = null,
    val group: io.github.qwertyuiop1995.dsmnativeclient.domain.NasGroup? = null,
) {
    init {
        require(
            kind == DirectoryEntryKind.ACCOUNT && account != null && group == null ||
                kind == DirectoryEntryKind.GROUP && group != null && account == null,
        ) { "directory.invalid_target" }
    }

    val name: String get() = account?.name ?: checkNotNull(group).name
}

data class RemoteAccessWorkspaceState(
    val settingsBaseline: NasRemoteAccessSettings? = null,
    val settingsDraft: NasRemoteAccessSettings? = null,
    val editorVisible: Boolean = false,
    val confirmationRequested: Boolean = false,
    val mutationInProgress: Boolean = false,
    val mutationResult: MutationResult? = null,
    val mutationFailure: DsmFailure? = null,
    val mutationRefreshFailure: DsmFailure? = null,
    val mutationRefreshInProgress: Boolean = false,
    val mutationRefreshCompleted: Boolean = false,
    val mutationGeneration: Long = 0L,
)


internal fun confirmedProxySettingsFallback(
    snapshot: NasSettingsSnapshot,
    expected: io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings,
): NasSettingsSnapshot? {
    val verifiedProxy = if (expected.isEnabled) {
        expected
    } else {
        snapshot.proxySettings?.copy(isEnabled = false)
    }
    return verifiedProxy?.let { snapshot.copy(proxySettings = it) }
}

internal fun confirmedRegionSettingsFallback(
    snapshot: NasSettingsSnapshot,
    expected: io.github.qwertyuiop1995.dsmnativeclient.domain.NasRegionSettings,
): NasSettingsSnapshot? {
    val cached = snapshot.regionSettings ?: return null
    return snapshot.copy(
        regionSettings = cached.copy(
            dateFormat = expected.dateFormat.trim(),
            timeFormat = expected.timeFormat.trim(),
            timeZone = expected.timeZone,
            isNetworkTimeEnabled = expected.isNetworkTimeEnabled,
            timeServers = expected.timeServers.map(String::trim).filter(String::isNotEmpty),
            manualDateTime = expected.manualDateTime ?: cached.manualDateTime,
            timeZones = cached.timeZones,
        ),
    )
}

internal fun normalizedRemoteAccessSettingsDraft(
    baseline: NasRemoteAccessSettings,
    proposed: NasRemoteAccessSettings,
): NasRemoteAccessSettings? {
    if (!baseline.canManage || proposed.canManage != baseline.canManage ||
        proposed.isConnectedThroughTrustedRelay != baseline.isConnectedThroughTrustedRelay ||
        (baseline.isRelayEnabled == null) != (proposed.isRelayEnabled == null) ||
        (baseline.isRouterConfigurationEnabled == null) !=
            (proposed.isRouterConfigurationEnabled == null)
    ) return null
    return proposed
}

internal fun canRequestRemoteAccessEditing(
    snapshot: NasSettingsSnapshot,
    value: NasRemoteAccessSettings,
): Boolean = snapshot.remoteAccessSettingsAvailable &&
    snapshot.remoteAccessSettings == value && value.canManage &&
    (value.isRelayEnabled != null || value.isRouterConfigurationEnabled != null)

internal fun canRequestRemoteAccessConfirmation(
    snapshot: NasSettingsSnapshot,
    baseline: NasRemoteAccessSettings,
    draft: NasRemoteAccessSettings,
): Boolean {
    val canonical = snapshot.remoteAccessSettings
    val normalized = normalizedRemoteAccessSettingsDraft(baseline, draft) ?: return false
    if (!snapshot.remoteAccessSettingsAvailable || canonical != baseline || normalized == baseline) return false
    return !(baseline.isConnectedThroughTrustedRelay &&
        baseline.isRelayEnabled == true && normalized.isRelayEnabled == false)
}

internal fun remoteAccessCanonicalHasDrifted(
    snapshot: NasSettingsSnapshot,
    baseline: NasRemoteAccessSettings,
): Boolean = !snapshot.remoteAccessSettingsAvailable || snapshot.remoteAccessSettings != baseline

internal fun remoteAccessMutationRefreshIsComplete(
    baseline: NasRemoteAccessSettings?,
    expected: NasRemoteAccessSettings?,
    current: NasRemoteAccessSettings?,
): Boolean {
    if (baseline == null || expected == null || current == null) return false
    val relayChanged = baseline.isRelayEnabled != expected.isRelayEnabled
    val routerChanged = baseline.isRouterConfigurationEnabled != expected.isRouterConfigurationEnabled
    if (!relayChanged && !routerChanged) return false
    return (!relayChanged || current.isRelayEnabled != null) &&
        (!routerChanged || current.isRouterConfigurationEnabled != null)
}

internal fun remoteAccessMutationTargetReached(
    baseline: NasRemoteAccessSettings,
    current: NasRemoteAccessSettings,
    expected: NasRemoteAccessSettings,
): Boolean {
    if (!remoteAccessMutationRefreshIsComplete(baseline, expected, current)) return false
    return (baseline.isRelayEnabled == expected.isRelayEnabled ||
        current.isRelayEnabled == expected.isRelayEnabled) &&
        (baseline.isRouterConfigurationEnabled == expected.isRouterConfigurationEnabled ||
            current.isRouterConfigurationEnabled == expected.isRouterConfigurationEnabled)
}

internal fun confirmedRemoteAccessSettingsFallback(
    snapshot: NasSettingsSnapshot,
    baseline: NasRemoteAccessSettings,
    expected: NasRemoteAccessSettings,
): NasSettingsSnapshot? {
    if (!snapshot.remoteAccessSettingsAvailable || snapshot.remoteAccessSettings != baseline ||
        normalizedRemoteAccessSettingsDraft(baseline, expected) == null
    ) return null
    return snapshot.copy(remoteAccessSettings = expected)
}

internal fun rebasedRemoteAccessSettingsDraft(
    snapshot: NasSettingsSnapshot,
    draft: NasRemoteAccessSettings,
): Pair<NasRemoteAccessSettings, NasRemoteAccessSettings>? {
    val current = snapshot.remoteAccessSettings
        ?.takeIf { snapshot.remoteAccessSettingsAvailable && it.canManage }
        ?: return null
    val rebased = current.copy(
        isRelayEnabled = when {
            current.isRelayEnabled == null || draft.isRelayEnabled == null -> current.isRelayEnabled
            current.isConnectedThroughTrustedRelay && current.isRelayEnabled -> current.isRelayEnabled
            else -> draft.isRelayEnabled
        },
        isRouterConfigurationEnabled = if (
            current.isRouterConfigurationEnabled != null && draft.isRouterConfigurationEnabled != null
        ) draft.isRouterConfigurationEnabled else current.isRouterConfigurationEnabled,
    )
    return current to rebased
}

internal fun remoteAccessMutationResultAfterStateCheck(
    result: MutationResult,
    targetStateConfirmed: Boolean,
): MutationResult = if (
    result.status == MutationResultStatus.CONFIRMED_SUCCESS && !targetStateConfirmed
) {
    val total = (result.counts.succeeded + result.counts.failed + result.counts.unknown).coerceAtLeast(1)
    result.copy(
        status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        requiresRefresh = true,
        counts = MutationResultCounts(succeeded = 0, failed = 0, unknown = total),
        errorCategory = MutationErrorCategory.UNKNOWN,
        localizationKey = null,
        diagnosticTag = "network.remote-access.state-unverified",
    )
} else result

internal fun remoteAccessCallbackMatches(
    repositoryMatches: Boolean,
    profileMatches: Boolean,
    stateGeneration: Long,
    callbackGeneration: Long,
    globalGeneration: Long,
): Boolean = scopedMutationCallbackMatches(
    repositoryMatches,
    profileMatches,
    stateGeneration,
    callbackGeneration,
    globalGeneration,
)

internal fun connectionMutationRequiresRefreshBeforeDismiss(result: MutationResult): Boolean =
    when (result.status) {
        MutationResultStatus.PARTIAL_SUCCESS,
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> true
        MutationResultStatus.PERMISSION_DENIED,
        MutationResultStatus.UNSUPPORTED,
        MutationResultStatus.CONFIRMED_FAILURE,
        -> result.submitted || result.requiresRefresh ||
            result.errorCategory == MutationErrorCategory.CONFLICT
        MutationResultStatus.CONFIRMED_SUCCESS,
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        -> false
    }

internal fun ethernetMutationRequiresRefreshBeforeDismiss(result: MutationResult): Boolean =
    when (result.status) {
        MutationResultStatus.PARTIAL_SUCCESS,
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> true
        MutationResultStatus.PERMISSION_DENIED,
        MutationResultStatus.UNSUPPORTED,
        MutationResultStatus.CONFIRMED_FAILURE,
        -> result.submitted || result.requiresRefresh ||
            result.errorCategory == MutationErrorCategory.CONFLICT
        MutationResultStatus.CONFIRMED_SUCCESS,
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        -> false
    }

internal fun confirmedEthernetSettingsFallback(
    snapshot: NasSettingsSnapshot,
    expected: io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface,
): NasSettingsSnapshot? {
    val cachedIndex = snapshot.networkInterfaces.indexOfFirst { it.id == expected.id }
    if (cachedIndex < 0) return null
    val cached = snapshot.networkInterfaces[cachedIndex]
    val verified = cached.copy(
        usesDhcp = expected.usesDhcp,
        address = if (expected.usesDhcp) cached.address else expected.address.trim(),
        subnetMask = if (expected.usesDhcp) cached.subnetMask else expected.subnetMask.trim(),
        gateway = if (expected.usesDhcp) cached.gateway else expected.gateway.trim(),
        dnsServers = if (expected.usesDhcp) cached.dnsServers else expected.dnsServers.trim(),
        isDefaultGateway = expected.isDefaultGateway,
        mtu = expected.mtu,
        isVlanEnabled = expected.isVlanEnabled,
        vlanId = if (expected.isVlanEnabled) expected.vlanId else cached.vlanId,
    )
    return snapshot.copy(
        networkInterfaces = snapshot.networkInterfaces.toMutableList().apply {
            this[cachedIndex] = verified
        },
    )
}

internal fun rebasedEthernetSettingsDraft(
    snapshot: NasSettingsSnapshot,
    draft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface,
): Pair<
    io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface,
    io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface,
>? {
    val current = snapshot.networkInterfaces.firstOrNull { it.id == draft.id } ?: return null
    return current to draft.copy(
        id = current.id,
        displayName = current.displayName,
        status = current.status,
    )
}

internal data class RebasedDdnsSettings(
    val baseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord?,
    val draft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft,
)

internal fun scrubDdnsPassword(
    draft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft,
) = draft.copy(password = "")

internal fun ddnsMutationRequiresRefreshBeforeDismiss(
    operation: DdnsMutationOperation,
    result: MutationResult,
): Boolean {
    if (operation == DdnsMutationOperation.TEST) return false
    return when (result.status) {
        MutationResultStatus.PARTIAL_SUCCESS,
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> true
        MutationResultStatus.PERMISSION_DENIED,
        MutationResultStatus.UNSUPPORTED,
        MutationResultStatus.CONFIRMED_FAILURE,
        -> result.submitted || result.requiresRefresh ||
            result.errorCategory == MutationErrorCategory.CONFLICT
        MutationResultStatus.CONFIRMED_SUCCESS,
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        -> false
    }
}

internal fun confirmedDdnsSaveFallback(
    snapshot: NasSettingsSnapshot,
    expected: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft,
): NasSettingsSnapshot? {
    val directory = snapshot.ddnsDirectory ?: return null
    val index = directory.records.indexOfFirst { it.providerId == expected.providerId }
    if (index < 0) return null
    val cached = directory.records[index]
    val verified = cached.copy(
        hostname = expected.hostname.trim().lowercase(Locale.ROOT),
        username = expected.username.trim(),
        isEnabled = expected.isEnabled,
        heartbeat = expected.heartbeat,
    )
    return snapshot.copy(
        ddnsDirectory = directory.copy(
            records = directory.records.toMutableList().apply { this[index] = verified },
        ),
    )
}

internal fun confirmedDdnsDeleteFallback(
    snapshot: NasSettingsSnapshot,
    providerId: String,
): NasSettingsSnapshot? {
    val directory = snapshot.ddnsDirectory ?: return null
    if (directory.records.none { it.providerId == providerId }) return null
    return snapshot.copy(
        ddnsDirectory = directory.copy(
            records = directory.records.filterNot { it.providerId == providerId },
        ),
    )
}

internal fun rebasedDdnsSettingsDraft(
    snapshot: NasSettingsSnapshot,
    draft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft,
    adoptExistingRecord: Boolean,
): RebasedDdnsSettings? {
    val directory = snapshot.ddnsDirectory ?: return null
    if (directory.providers.none { it.id == draft.providerId }) return null
    val current = directory.records.firstOrNull { it.providerId == draft.providerId }
    return when {
        draft.originalProviderId != null && current != null -> RebasedDdnsSettings(
            current,
            scrubDdnsPassword(draft).copy(originalProviderId = current.providerId),
        )
        draft.originalProviderId == null && current == null -> RebasedDdnsSettings(
            null,
            scrubDdnsPassword(draft),
        )
        draft.originalProviderId == null && current != null && adoptExistingRecord ->
            RebasedDdnsSettings(
                current,
                scrubDdnsPassword(draft).copy(originalProviderId = current.providerId),
            )
        else -> null
    }
}

internal fun structuredSettingsMutationRequiresRefreshBeforeDismiss(result: MutationResult): Boolean =
    when (result.status) {
        MutationResultStatus.PARTIAL_SUCCESS,
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> true
        MutationResultStatus.PERMISSION_DENIED,
        MutationResultStatus.UNSUPPORTED,
        MutationResultStatus.CONFIRMED_FAILURE,
        -> result.submitted || result.requiresRefresh ||
            result.errorCategory == MutationErrorCategory.CONFLICT
        MutationResultStatus.CONFIRMED_SUCCESS,
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        -> false
    }

/**
 * 电源动作没有可靠的即时状态回读；只有结果已经明确收敛时才能释放同一 NAS 的再次写入入口。
 */
internal fun canDismissPowerMutationResult(result: MutationResult): Boolean {
    if (result.requiresRefresh || result.counts.unknown > 0) return false
    return when (result.status) {
        MutationResultStatus.CONFIRMED_SUCCESS -> true
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION -> !result.submitted
        MutationResultStatus.PERMISSION_DENIED,
        MutationResultStatus.UNSUPPORTED,
        MutationResultStatus.CONFIRMED_FAILURE,
        -> true
        MutationResultStatus.PARTIAL_SUCCESS,
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> false
    }
}

internal fun destructiveServiceMutationRequiresRefreshBeforeDismiss(result: MutationResult): Boolean =
    when (result.status) {
        MutationResultStatus.PARTIAL_SUCCESS,
        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        -> true
        MutationResultStatus.PERMISSION_DENIED,
        MutationResultStatus.UNSUPPORTED,
        MutationResultStatus.CONFIRMED_FAILURE,
        -> result.submitted || result.requiresRefresh ||
            result.errorCategory == MutationErrorCategory.CONFLICT
        MutationResultStatus.CONFIRMED_SUCCESS,
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        -> false
    }

/** 危险写操作仍在进行，或其结果尚未完成可信专项回读时，不得离开当前 NAS 会话。 */
internal fun structuredMutationBlocksWorkspaceExit(
    mutationInProgress: Boolean,
    refreshInProgress: Boolean,
    result: MutationResult?,
    failure: DsmFailure?,
    refreshCompleted: Boolean,
): Boolean {
    if (mutationInProgress || refreshInProgress) return true
    if (refreshCompleted) return false
    return failure != null ||
        result?.let(::destructiveServiceMutationRequiresRefreshBeforeDismiss) == true
}

internal fun WorkspaceState.hasBlockingStructuredNasMutation(): Boolean =
    structuredMutationBlocksWorkspaceExit(
        mutationInProgress = remoteAccessMutationInProgress,
        refreshInProgress = remoteAccessMutationRefreshInProgress,
        result = remoteAccessMutationResult,
        failure = remoteAccessMutationFailure ?: remoteAccessMutationRefreshFailure,
        refreshCompleted = remoteAccessMutationRefreshCompleted,
    ) || structuredMutationBlocksWorkspaceExit(
        mutationInProgress = packageMutationInProgress,
        refreshInProgress = packageMutationRefreshInProgress,
        result = packageMutationResult,
        failure = packageMutationFailure,
        refreshCompleted = packageMutationRefreshCompleted,
    ) || structuredMutationBlocksWorkspaceExit(
        mutationInProgress = directoryMutationInProgress,
        refreshInProgress = directoryMutationRefreshInProgress,
        result = directoryMutationResult,
        failure = directoryMutationFailure,
        refreshCompleted = directoryMutationRefreshCompleted,
    ) || structuredMutationBlocksWorkspaceExit(
        mutationInProgress = diskTestMutationInProgress,
        refreshInProgress = diskTestMutationRefreshInProgress,
        result = diskTestMutationResult,
        failure = diskTestMutationFailure,
        refreshCompleted = diskTestMutationRefreshCompleted,
    )

/** 保留既有状态策略测试和旧调用方；语义已扩展到 S.M.A.R.T. 检测。 */
internal fun WorkspaceState.hasBlockingDirectoryOrPackageMutation(): Boolean =
    hasBlockingStructuredNasMutation()

internal fun isTrustedDiskTestStatus(
    disk: NasStorageDisk,
    status: NasDiskTestStatus,
): Boolean = status.diskId == disk.id && when {
    status.isRunning -> !status.isBusyWithOtherTest && status.runningType != null
    else -> status.runningType == null
}

/** 硬盘检测写目标只由稳定磁盘标识、设备标识和能力组成；温度与健康状态均可正常变化。 */
internal fun sameDiskTestTarget(
    expected: NasStorageDisk,
    current: NasStorageDisk?,
): Boolean = current != null && expected.id == current.id &&
    expected.deviceId == current.deviceId &&
    expected.supportsSmartTest == current.supportsSmartTest

internal fun canRequestDiskTestMutation(
    snapshot: NasSettingsSnapshot,
    statuses: Map<String, Loadable<NasDiskTestStatus>>,
    disk: NasStorageDisk,
    baseline: NasDiskTestStatus,
    operation: NasDiskTestType?,
): Boolean {
    val canonical = snapshot.storageDisks.firstOrNull { it.id == disk.id }
    if (!sameDiskTestTarget(disk, canonical) || canonical?.supportsSmartTest != true) return false
    if ((statuses[disk.id] as? Loadable.Ready)?.value != baseline || !isTrustedDiskTestStatus(disk, baseline)) {
        return false
    }
    return if (operation == null) baseline.isRunning
    else !baseline.isRunning && !baseline.isBusyWithOtherTest
}

internal fun diskTestMutationTargetReached(
    disk: NasStorageDisk,
    status: NasDiskTestStatus,
    operation: NasDiskTestType?,
): Boolean {
    if (!isTrustedDiskTestStatus(disk, status)) return false
    return if (operation == null) {
        !status.isRunning && !status.isBusyWithOtherTest && status.runningType == null
    } else {
        status.isRunning && status.runningType == operation
    }
}

/** 专项状态读取不请求历史；仅在响应明确不含历史时保留同一硬盘的既有历史字段。 */
internal fun mergeDiskTestStatusHistory(
    active: NasDiskTestStatus,
    previous: NasDiskTestStatus?,
): NasDiskTestStatus {
    if (active.isHistoryAvailable || previous?.diskId != active.diskId) return active
    return active.copy(
        lastQuickTest = previous.lastQuickTest,
        lastExtendedTest = previous.lastExtendedTest,
        lastResult = previous.lastResult,
        isHistoryAvailable = previous.isHistoryAvailable,
    )
}

internal fun confirmedDiskTestMutationFallback(
    snapshot: NasSettingsSnapshot,
    statuses: Map<String, Loadable<NasDiskTestStatus>>,
    disk: NasStorageDisk,
    baseline: NasDiskTestStatus,
    operation: NasDiskTestType?,
): Map<String, Loadable<NasDiskTestStatus>>? {
    if (!sameDiskTestTarget(disk, snapshot.storageDisks.firstOrNull { it.id == disk.id })) return null
    if ((statuses[disk.id] as? Loadable.Ready)?.value != baseline || !isTrustedDiskTestStatus(disk, baseline)) {
        return null
    }
    val updated = if (operation == null) {
        baseline.copy(
            isRunning = false,
            isBusyWithOtherTest = false,
            runningType = null,
            progressDescription = null,
        )
    } else {
        baseline.copy(
            isRunning = true,
            isBusyWithOtherTest = false,
            runningType = operation,
            progressDescription = null,
        )
    }
    return statuses + (disk.id to Loadable.Ready(updated))
}

internal fun diskTestMutationResultAfterStateCheck(
    result: MutationResult,
    targetStateConfirmed: Boolean,
): MutationResult = if (
    result.status == MutationResultStatus.CONFIRMED_SUCCESS && !targetStateConfirmed
) {
    result.copy(
        status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        requiresRefresh = true,
        counts = MutationResultCounts(succeeded = 0, failed = 0, unknown = 1),
        errorCategory = MutationErrorCategory.UNKNOWN,
        localizationKey = null,
        diagnosticTag = "storage.disk-test.state-unverified",
    )
} else result

internal fun scopedMutationCallbackMatches(
    repositoryMatches: Boolean,
    profileMatches: Boolean,
    stateGeneration: Long,
    callbackGeneration: Long,
    globalGeneration: Long,
): Boolean = repositoryMatches && profileMatches &&
    stateGeneration == callbackGeneration && globalGeneration == callbackGeneration

internal fun diskTestStatusLoadCallbackMatches(
    repositoryMatches: Boolean,
    profileMatches: Boolean,
    requestGeneration: Long,
    currentGeneration: Long?,
    settingsGeneration: Long,
    currentSettingsGeneration: Long,
    requestedDisk: NasStorageDisk,
    currentDisk: NasStorageDisk?,
): Boolean = repositoryMatches && profileMatches && requestGeneration == currentGeneration &&
    settingsGeneration == currentSettingsGeneration &&
    sameDiskTestTarget(requestedDisk, currentDisk)

/** NAS 设置开始刷新时，旧逐盘请求已失效，不能把对应条目永久留在加载状态。 */
internal fun diskTestStatusesWithoutPendingLoads(
    statuses: Map<String, Loadable<NasDiskTestStatus>>,
): Map<String, Loadable<NasDiskTestStatus>> = statuses.filterValues { it !is Loadable.Loading }

/** NAS 设置刷新成功后，仅保留稳定硬盘身份未变化的既有状态。 */
internal fun reconciledDiskTestStatusesAfterSettingsRefresh(
    previousSnapshot: NasSettingsSnapshot?,
    refreshedSnapshot: NasSettingsSnapshot,
    statuses: Map<String, Loadable<NasDiskTestStatus>>,
): Map<String, Loadable<NasDiskTestStatus>> {
    if (previousSnapshot == null) return emptyMap()
    return diskTestStatusesWithoutPendingLoads(statuses).filter { (diskId, _) ->
        val previousDisk = previousSnapshot.storageDisks.firstOrNull { it.id == diskId }
        val refreshedDisk = refreshedSnapshot.storageDisks.firstOrNull { it.id == diskId }
        previousDisk != null && sameDiskTestTarget(previousDisk, refreshedDisk)
    }
}

internal fun packageMutationTargetReached(
    packages: List<PackageInfo>,
    target: PackageInfo,
    operation: PackageMutationOperation,
): Boolean = when (operation) {
    PackageMutationOperation.START -> packages.any {
        it.id == target.id && it.status == io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState.RUNNING
    }
    PackageMutationOperation.STOP -> packages.any {
        it.id == target.id && it.status == io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState.STOPPED
    }
    PackageMutationOperation.UNINSTALL -> packages.none { it.id == target.id }
}

internal fun canRequestPackageMutation(
    snapshot: NasSettingsSnapshot,
    target: PackageInfo,
    operation: PackageMutationOperation,
): Boolean {
    if (!snapshot.packagesAvailable) return false
    val canonical = snapshot.packages.firstOrNull { it.id == target.id }
    if (canonical != target) return false
    return when (operation) {
        PackageMutationOperation.START -> canonical.canStart
        PackageMutationOperation.STOP -> canonical.canStop
        PackageMutationOperation.UNINSTALL -> canonical.canUninstall
    }
}

internal fun confirmedPackageMutationFallback(
    snapshot: NasSettingsSnapshot,
    target: PackageInfo,
    operation: PackageMutationOperation,
): NasSettingsSnapshot? {
    if (!snapshot.packagesAvailable) return null
    val index = snapshot.packages.indexOfFirst { it.id == target.id }
    return when (operation) {
        PackageMutationOperation.START,
        PackageMutationOperation.STOP,
        -> {
            if (index < 0 || snapshot.packages[index] != target) return null
            val status = if (operation == PackageMutationOperation.START) {
                io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState.RUNNING
            } else {
                io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState.STOPPED
            }
            snapshot.copy(
                packages = snapshot.packages.toMutableList().apply {
                    this[index] = target.copy(status = status)
                },
                packagesAvailable = true,
            )
        }
        PackageMutationOperation.UNINSTALL -> {
            if (index < 0 || snapshot.packages[index] != target) return null
            snapshot.copy(
                packages = snapshot.packages.filterNot { it.id == target.id },
                packagesAvailable = true,
            )
        }
    }
}

internal fun directoryMutationTargetAbsent(
    target: DirectoryEntryMutationTarget,
    accounts: List<io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount>,
    groups: List<io.github.qwertyuiop1995.dsmnativeclient.domain.NasGroup>,
): Boolean = when (target.kind) {
    DirectoryEntryKind.ACCOUNT -> accounts.none { candidate ->
        val original = checkNotNull(target.account)
        if (original.id != null) candidate.id == original.id
        else candidate.name.equals(original.name, ignoreCase = true)
    }
    DirectoryEntryKind.GROUP -> groups.none { candidate ->
        val original = checkNotNull(target.group)
        if (original.id != null) candidate.id == original.id
        else candidate.name.equals(original.name, ignoreCase = true)
    }
}

internal fun canRequestDirectoryDeletion(
    snapshot: NasSettingsSnapshot,
    target: DirectoryEntryMutationTarget,
): Boolean = when (target.kind) {
    DirectoryEntryKind.ACCOUNT -> snapshot.accountsAvailable &&
        snapshot.accounts.any { it == target.account && it.canDelete }
    DirectoryEntryKind.GROUP -> snapshot.groupsAvailable &&
        snapshot.groups.any { it == target.group && it.canDelete }
}

internal fun confirmedDirectoryDeletionFallback(
    snapshot: NasSettingsSnapshot,
    target: DirectoryEntryMutationTarget,
): NasSettingsSnapshot? {
    return when (target.kind) {
        DirectoryEntryKind.ACCOUNT -> {
            val original = checkNotNull(target.account)
            if (!snapshot.accountsAvailable || snapshot.accounts.none { it == original }) null else {
                snapshot.copy(
                    accounts = snapshot.accounts.filterNot { it == original },
                    accountsAvailable = true,
                )
            }
        }
        DirectoryEntryKind.GROUP -> {
            val original = checkNotNull(target.group)
            if (!snapshot.groupsAvailable || snapshot.groups.none { it == original }) null else {
                snapshot.copy(
                    groups = snapshot.groups.filterNot { it == original },
                    groupsAvailable = true,
                )
            }
        }
    }
}

internal fun confirmedSecuritySettingsFallback(
    snapshot: NasSettingsSnapshot,
    baseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings,
    expected: io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings,
): NasSettingsSnapshot? {
    if (!snapshot.securitySettingsAvailable || snapshot.securitySettings != baseline) return null
    val expectedDosById = expected.dosProtection.associateBy { it.id }
    if (
        expectedDosById.size != expected.dosProtection.size ||
        expectedDosById.keys != baseline.dosProtection.map { it.id }.toSet()
    ) return null
    val verified = expected.copy(
        dosProtection = baseline.dosProtection.map { original ->
            original.copy(isEnabled = expectedDosById.getValue(original.id).isEnabled)
        },
        firewallProfileName = baseline.firewallProfileName,
    )
    return snapshot.copy(securitySettings = verified, securitySettingsAvailable = true)
}

internal fun confirmedHardwareSettingsFallback(
    snapshot: NasSettingsSnapshot,
    baseline: io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings,
    expected: io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings,
): NasSettingsSnapshot? {
    if (!snapshot.hardwareSettingsAvailable || snapshot.hardwareSettings != baseline) return null
    val normalized = normalizedHardwareSettingsDraft(expected)
    return snapshot.copy(
        hardwareSettings = normalized.copy(
            ledBrightnessMinimum = baseline.ledBrightnessMinimum,
            ledBrightnessMaximum = baseline.ledBrightnessMaximum,
        ),
        hardwareSettingsAvailable = true,
    )
}

internal fun normalizedHardwareSettingsDraft(
    value: io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings,
) = value.copy(
    ups = value.ups?.copy(
        networkServerAddress = value.ups.networkServerAddress?.trim(),
        snmpServerAddress = value.ups.snmpServerAddress?.trim(),
    ),
)

internal fun rebasedSecuritySettingsDraft(
    snapshot: NasSettingsSnapshot,
    draft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings,
): Pair<
    io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings,
    io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings,
>? {
    val current = snapshot.securitySettings?.takeIf { snapshot.securitySettingsAvailable } ?: return null
    return current to draft
}

internal fun rebasedHardwareSettingsDraft(
    snapshot: NasSettingsSnapshot,
    draft: io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings,
): Pair<
    io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings,
    io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings,
>? {
    val current = snapshot.hardwareSettings?.takeIf { snapshot.hardwareSettingsAvailable } ?: return null
    return current to draft
}
