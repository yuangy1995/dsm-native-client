package io.github.qwertyuiop1995.dsmnativeclient.data.files

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import io.github.qwertyuiop1995.dsmnativeclient.storage.workspaceStorageFailure
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.*

/** 各设置目标独立保存；未知结果只读恢复，失败不影响文件浏览或其他设置。 */
internal class DsmFileSettingsRepository(
    private val supports: (String, Int) -> Boolean,
    private val call: suspend (String, String, Map<String, String>, Int) -> JsonObject,
    private val access: () -> FilePermissionAccess, private val refreshAccess: suspend () -> Unit,
    private val owner: () -> WorkspaceOwner?, private val requireOwner: () -> Unit,
    media: FileImageTransport, fileInfo: suspend (String) -> FileItem?,
) {
    val reader = FileSettingsReader(::request, owner, requireOwner)
    val images = FileThemeImages(::request, media, fileInfo, ::requireCurrentAccess)
    private val mutex = Mutex()
    private var store: FileSettingsRecoveryStore? = null
    fun bindRecovery(value: FileSettingsRecoveryStore) { store = value }
    fun supportsGeneral() = supports(FILE_SETTINGS_API, 1)
    fun supportsMountAccess() = supports(FILE_MOUNT_USER_API, 1)
    fun supportsBandwidth() = supports(FILE_BANDWIDTH_API, 1)
    fun supportsTheme() = supports(FILE_SHARING_THEME_API, 1)
    fun supportsThemeImages() = supports(FILE_THEME_IMAGE_API, 1)
    suspend fun pending(): List<FileSettingsPending> = withContext(Dispatchers.IO) {
        requireOwner(); (store ?: throw workspaceStorageFailure()).pending(owner() ?: throw workspaceStorageFailure())
    }

    suspend fun changeSettingsResult(change: FileSettingsChange, confirmed: Boolean, riskAccepted: Boolean = false): FileSettingsOutcome = locked {
        if (!confirmed || change.risks().isNotEmpty() && !riskAccepted) throw settingsInvalid()
        if (change.owner != owner()) throw settingsChanged()
        val fields = change.parameters()
        requireWrite(change.api)
        if (pending().any { it.kind == change.kind && it.target == change.target }) throw settingsPending()
        if (!baselineMatches(change)) throw settingsChanged()
        if (change is FileSettingsChange.General) requirePolicyAccounts(change)
        if (change is FileSettingsChange.Theme) {
            change.updated.logoImage?.let { images.validate(it) }; change.updated.backgroundImage?.let { images.validate(it) }
        }
        requireWrite(change.api)
        // 名单可能跨多页；提交前重读原快照，避免期间其他管理员的修改被覆盖。
        if (!baselineMatches(change)) throw settingsChanged()
        currentCoroutineContext().ensureActive(); requireCurrentAccess()
        val theme = change as? FileSettingsChange.Theme
        var record = FileSettingsPending(owner = change.owner, kind = change.kind, target = change.target, desired = change.desiredDigest(),
            logoBefore = if (theme?.updated?.logoImage != null) themeSequenceDigest(theme.baseline.logoSequence) else null,
            backgroundBefore = if (theme?.updated?.backgroundImage != null) themeSequenceDigest(theme.baseline.backgroundSequence) else null)
        persist { it.begin(record) }
        var sent = false
        try {
            currentCoroutineContext().ensureActive(); requireCurrentAccess()
            sent = true
            request(change.api, "set", fields, 1)
        } catch (error: Exception) {
            if (!sent) withContext(NonCancellable) { persist { it.replace(record, null) } }
            if (error is CancellationException) throw error
            if (!sent || error is DsmFailure && definiteRejection(error)) {
                if (sent) persist { it.replace(record, null) }
                return@locked FileSettingsOutcome(FileSettingsOutcomeStatus.REJECTED, failure = error as? DsmFailure ?: settingsChanged())
            }
            return@locked reviewCore(record, change)
        }
        val acknowledged = record.copy(acknowledged = true)
        persist { it.replace(record, acknowledged) }; record = acknowledged
        reviewCore(record, change)
    }

    /** change 仅用来定位原目标；期望值来自已保存摘要，不能由新草稿替换。 */
    suspend fun review(change: FileSettingsChange): FileSettingsOutcome = locked {
        if (owner()?.hasSameIdentity(change.owner) != true) throw settingsChanged()
        val record = pending().singleOrNull { it.kind == change.kind && it.target == change.target } ?: throw settingsChanged()
        reviewCore(record, change)
    }
    private suspend fun reviewCore(record: FileSettingsPending, change: FileSettingsChange): FileSettingsOutcome {
        val completed = try {
            if (pending().singleOrNull { it.id == record.id } != record) throw settingsChanged()
            if (change is FileSettingsChange.Theme) {
                val current = reader.theme()
                settingsDigest(current.settingsValue()) == record.desired && record.themeImagesMatch(current)
            } else settingsDigest(currentValue(change)) == record.desired
        } catch (error: Exception) {
            if (error is CancellationException) throw error
            false
        }
        requireOwner()
        if (completed) persist { it.replace(record, null) }
        return FileSettingsOutcome(if (completed) FileSettingsOutcomeStatus.COMPLETED else FileSettingsOutcomeStatus.UNKNOWN, if (completed) null else record)
    }
    private suspend fun baselineMatches(change: FileSettingsChange) = settingsDigest(currentValue(change)) == settingsDigest(when (change) {
        is FileSettingsChange.General -> change.baseline.settingsValue()
        is FileSettingsChange.MountScope -> JsonPrimitive(change.baseline.value)
        is FileSettingsChange.MountAccount -> change.baseline.settingsValue()
        is FileSettingsChange.Bandwidth -> change.baseline.settingsValue()
        is FileSettingsChange.Theme -> change.baseline.settingsValue(includeSequences = true)
    })
    private suspend fun currentValue(change: FileSettingsChange): JsonElement = when (change) {
        is FileSettingsChange.General -> reader.general().settingsValue()
        is FileSettingsChange.MountScope -> JsonPrimitive(reader.mountScope().value)
        is FileSettingsChange.Theme -> reader.theme().settingsValue(includeSequences = true)
        is FileSettingsChange.MountAccount -> {
            val baseline = change.baseline
            if (baseline.source.kind != FileMountSourceKind.LOCAL && reader.directories().items.none { it.source == baseline.source }) throw settingsChanged()
            allPages({ offset -> reader.mountAccounts(baseline.source, baseline.id.kind, baseline.name, offset) }, { it.id })
                .singleOrNull { it.id == baseline.id }?.settingsValue() ?: throw settingsChanged()
        }
        is FileSettingsChange.Bandwidth -> allPages({ offset -> reader.bandwidth(change.baseline.ownerType, offset) }, { it.name })
            .singleOrNull { it.name == change.baseline.name }?.settingsValue() ?: throw settingsChanged()
    }
    private suspend fun requirePolicyAccounts(change: FileSettingsChange.General) {
        val old = change.baseline; val new = change.updated
        val affected = (old.sharingAccounts - new.sharingAccounts) + (new.sharingAccounts - old.sharingAccounts) +
            (old.requestAccounts - new.requestAccounts) + (new.requestAccounts - old.requestAccounts)
        for (kind in FileSharePrincipalKind.entries) {
            val selected = affected.filter { it.kind == kind }.toSet()
            if (selected.isEmpty()) continue
            val accounts = allPages({ offset -> reader.policyAccounts(kind, "", offset) }, { it.id }).filter { it.id in selected }
            if (accounts.map { it.id }.toSet() != selected) throw settingsChanged()
            if (accounts.any { it.administrator }) throw permissionDenied()
        }
    }

    /** 上传只增加图片历史，独立于页面保存；未知上传仅锁定同类相同内容，不锁住其他图片。 */
    suspend fun uploadThemeImageResult(input: FileThemeUpload, kind: FileThemeImageKind, confirmed: Boolean): FileThemeUploadOutcome = locked {
        if (!confirmed || !FileThemeImage.supportsFilename(input.filename) || input.filename.any { it in "\r\n\u0000\"/\\" } ||
            input.bytes <= 0 || !input.unchanged()) throw settingsInvalid()
        requireWrite(FILE_THEME_IMAGE_API)
        val targetKind = if (kind == FileThemeImageKind.LOGO) FileSettingsTargetKind.THEME_UPLOAD_LOGO else FileSettingsTargetKind.THEME_UPLOAD_BACKGROUND
        if (pending().any { it.kind == targetKind && it.target == input.digest }) throw settingsPending()
        var record = FileSettingsPending(owner = owner() ?: throw workspaceStorageFailure(), kind = targetKind, target = input.digest, desired = input.digest)
        persist { it.begin(record) }
        var sent = false
        val path: String
        try {
            currentCoroutineContext().ensureActive(); requireCurrentAccess()
            sent = true; path = images.upload(input, kind)
        } catch (error: Exception) {
            if (!sent) withContext(NonCancellable) { persist { it.replace(record, null) } }
            if (error is CancellationException) throw error
            if (!sent || error is DsmFailure && definiteRejection(error)) {
                if (sent) persist { it.replace(record, null) }
                return@locked FileThemeUploadOutcome(FileSettingsOutcomeStatus.REJECTED, failure = error as? DsmFailure ?: settingsChanged())
            }
            return@locked FileThemeUploadOutcome(FileSettingsOutcomeStatus.UNKNOWN)
        }
        val acknowledged = record.copy(acknowledged = true); persist { it.replace(record, acknowledged) }; record = acknowledged
        val image = try { images.history(kind).singleOrNull { it.path == path } }
        catch (error: Exception) { if (error is CancellationException) throw error; null }
        requireOwner()
        if (image != null) persist { it.replace(record, null) }
        FileThemeUploadOutcome(if (image != null) FileSettingsOutcomeStatus.COMPLETED else FileSettingsOutcomeStatus.UNKNOWN, image)
    }
    private suspend fun <T, K> allPages(fetch: suspend (Int) -> FileSettingsPage<T>, key: (T) -> K): List<T> {
        var offset = 0; var total: Int? = null; val ids = mutableSetOf<K>(); val rows = mutableListOf<T>()
        do {
            currentCoroutineContext().ensureActive(); requireCurrentAccess()
            val page = fetch(offset)
            if (total != null && page.total != total || page.items.any { !ids.add(key(it)) }) throw settingsChanged()
            rows += page.items; total = page.total; offset = page.nextOffset
        } while (offset < total!!)
        return rows
    }
    private suspend fun request(api: String, method: String, fields: Map<String, String>, version: Int): JsonObject {
        requireCurrentAccess()
        if (!supports(api, version)) throw DsmFailure(null, "These settings are unavailable", "Check File Station and try again.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        val result = call(api, method, fields, version)
        if (method != "set") requireCurrentAccess()
        return result
    }
    private suspend fun requireWrite(api: String) {
        requireOwner(); refreshAccess(); requireCurrentAccess()
        if (!supports(api, 1)) throw DsmFailure(null, "These settings are unavailable", "Check File Station and try again.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
    }
    private fun requireCurrentAccess() { requireOwner(); if (!access().granted || !access().administrator) throw permissionDenied() }
    private suspend fun persist(action: (FileSettingsRecoveryStore) -> Unit) = withContext(Dispatchers.IO) {
        action(store ?: throw workspaceStorageFailure())
    }
    private suspend fun <T> locked(block: suspend () -> T): T {
        requireOwner(); if (!mutex.tryLock()) throw settingsPending()
        try { return block() } finally { mutex.unlock() }
    }
    private fun definiteRejection(error: DsmFailure) = error.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.AUTHENTICATION_FAILED,
        DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED)
}
