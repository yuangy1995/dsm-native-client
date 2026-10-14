package io.github.qwertyuiop1995.dsmnativeclient.data

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationExpectedOutput
import io.github.qwertyuiop1995.dsmnativeclient.domain.TransferState
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

private val transferStoreChanges = MutableStateFlow(0L)
internal val transferChanges = transferStoreChanges.asStateFlow()
private fun notifyTransferChanged() { transferStoreChanges.update { it + 1L } }

internal data class PersistedTransferSnapshot(
    val downloads: List<PersistedDownload>, val uploads: List<PersistedUpload>,
    val servers: List<PersistedServerTransfer>, val imports: List<PersistedVirtualMachineImageImport>,
)

/**
 * 只保存恢复传输所需的非凭据状态；SID、密码和令牌不进入此存储；远程下载仅保留加密的来源身份。
 */
class TransferStore internal constructor(
    private val preferences: android.content.SharedPreferences,
    private val json: Json = Json { ignoreUnknownKeys = true },
) {
    constructor(context: Context, json: Json = Json { ignoreUnknownKeys = true }) : this(
        EncryptedSharedPreferences.create(context, PREFERENCES_NAME,
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM), json)

    internal fun snapshot(): PersistedTransferSnapshot = synchronized(TRANSFER_STORE_LOCK) {
        PersistedTransferSnapshot(all(), allUploads(), allServers(), allVirtualMachineImageImports())
    }

    fun downloads(profileId: String): List<PersistedDownload> = synchronized(TRANSFER_STORE_LOCK) {
        all().filter { it.profileId == profileId }
    }

    fun download(id: String): PersistedDownload? = synchronized(TRANSFER_STORE_LOCK) {
        all().firstOrNull { it.id == id }
    }

    internal fun archiveDownloadPlan(record: PersistedDownload): ArchiveDownloadPlan? = synchronized(TRANSFER_STORE_LOCK) {
        if (!record.isArchiveDownload) return@synchronized null
        val raw = preferences.getString(archiveDownloadKey(record.id), null)
            ?: throw ArchiveDownloadPlanUnavailable()
        val plan = runCatching { json.decodeFromString<ArchiveDownloadPlan>(raw) }.getOrNull()
            ?: throw ArchiveDownloadPlanUnavailable()
        if (!plan.matches(record)) throw ArchiveDownloadPlanUnavailable()
        plan
    }

    /** 清单与任务一次落盘；失败时不入队，不以普通下载覆盖同一编号。 */
    internal fun createArchiveDownloadDurably(record: PersistedDownload, plan: ArchiveDownloadPlan): Boolean =
        synchronized(TRANSFER_STORE_LOCK) {
            require(plan.matches(record))
            val existing = all()
            if (existing.any { it.id == record.id } || preferences.contains(archiveDownloadKey(record.id))) return@synchronized false
            preferences.edit().putString(KEY_DOWNLOADS,
                json.encodeToString(ListSerializer(PersistedDownload.serializer()), existing + record))
                .putString(archiveDownloadKey(record.id), json.encodeToString(plan)).commit()
                .also { if (it) notifyTransferChanged() }
        }

    private fun archiveDownloadKey(id: String) = "archive_download_plan_v1_" +
        java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(id.toByteArray(Charsets.UTF_8))

    internal fun vfsDownloadPlan(record: PersistedDownload): FileVFSDownloadPlan? = synchronized(TRANSFER_STORE_LOCK) {
        if (!record.isVFSDownload) return@synchronized null
        val raw = preferences.getString(vfsDownloadKey(record.id), null) ?: throw FileVFSDownloadPlanUnavailable()
        val plan = runCatching { json.decodeFromString<FileVFSDownloadPlan>(raw) }.getOrNull()
            ?: throw FileVFSDownloadPlanUnavailable()
        if (!plan.matches(record)) throw FileVFSDownloadPlanUnavailable()
        plan
    }

    internal fun createVFSDownloadDurably(record: PersistedDownload, plan: FileVFSDownloadPlan): Boolean =
        synchronized(TRANSFER_STORE_LOCK) {
            require(plan.matches(record))
            val existing = all()
            if (existing.any { it.id == record.id } || preferences.contains(vfsDownloadKey(record.id))) return@synchronized false
            preferences.edit().putString(KEY_DOWNLOADS,
                json.encodeToString(ListSerializer(PersistedDownload.serializer()), existing + record))
                .putString(vfsDownloadKey(record.id), json.encodeToString(plan)).commit()
                .also { if (it) notifyTransferChanged() }
        }

    private fun vfsDownloadKey(id: String) = "vfs_download_plan_v1_" +
        java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(id.toByteArray(Charsets.UTF_8))

    fun uploads(profileId: String): List<PersistedUpload> = synchronized(TRANSFER_STORE_LOCK) {
        allUploads().filter { it.profileId == profileId }
    }

    fun upload(id: String): PersistedUpload? = synchronized(TRANSFER_STORE_LOCK) {
        allUploads().firstOrNull { it.id == id }
    }

    internal fun saveUploadContent(upload: PersistedUpload, executionId: String, fingerprint: UploadContentFingerprint) =
        synchronized(TRANSFER_STORE_LOCK) {
            val current = upload(upload.id) ?: throw java.io.IOException("Upload task is unavailable")
            if (current.profileId != upload.profileId || current.workId != executionId ||
                current.sourceUri != upload.sourceUri || current.expectedBytes != fingerprint.bytes
            ) throw java.io.IOException("Upload execution changed")
            val record = UploadContentRecord(profileId = upload.profileId, executionId = executionId, fingerprint = fingerprint)
            if (!preferences.edit().putString(uploadContentKey(upload.id), json.encodeToString(record)).commit()) {
                throw java.io.IOException("Upload content record could not be saved")
            }
        }

    internal fun uploadContent(upload: PersistedUpload): UploadContentFingerprint? = synchronized(TRANSFER_STORE_LOCK) {
        val value = preferences.getString(uploadContentKey(upload.id), null) ?: return@synchronized null
        val record = runCatching { json.decodeFromString<UploadContentRecord>(value) }.getOrNull()
            ?: throw java.io.IOException("Upload content record is unavailable")
        record.takeIf { it.schemaVersion == 1 && it.profileId == upload.profileId && it.executionId == upload.workId }
            ?.fingerprint?.takeIf { it.bytes == upload.expectedBytes }
    }

    private fun uploadContentKey(id: String) = "upload_content_v1_" +
        java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(id.toByteArray(Charsets.UTF_8))

    internal fun hasFolderUploadPlan(id: String): Boolean = synchronized(TRANSFER_STORE_LOCK) { preferences.contains(folderUploadKey(id)) }

    /** 分享草稿的整批接收与任务事实一次落盘；重建不能从同一草稿再次创建上传。 */
    internal fun createSharedUploadsDurably(batchId: String, uploads: List<PersistedUpload>): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        require(java.util.UUID.fromString(batchId).toString() == batchId && uploads.isNotEmpty())
        require(uploads.map { it.id }.distinct().size == uploads.size && uploads.all {
            it.profileId == uploads.first().profileId && it.destinationPath == uploads.first().destinationPath &&
                it.state == TransferState.WAITING && it.workId == null && !it.backupMode
        })
        if (sharedUploadBatchExists(batchId)) return@synchronized false
        val current = allUploads()
        if (current.any { old -> uploads.any { it.id == old.id } }) throw java.io.IOException("Shared task already exists")
        if (!preferences.edit().putString(KEY_UPLOADS,
                json.encodeToString(ListSerializer(PersistedUpload.serializer()), current + uploads))
                .putBoolean("shared_upload_v1_$batchId", true).commit()) throw java.io.IOException("Shared tasks could not be saved")
        notifyTransferChanged()
        true
    }

    internal fun sharedUploadBatchExists(batchId: String): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        preferences.getBoolean("shared_upload_v1_$batchId", false)
    }

    internal fun folderUploadPlan(id: String): FolderUploadPlan? = synchronized(TRANSFER_STORE_LOCK) {
        val raw = preferences.getString(folderUploadKey(id), null) ?: return@synchronized null
        val plan = runCatching { json.decodeFromString<FolderUploadPlan>(raw) }.getOrNull()
            ?: throw java.io.IOException("Folder upload plan is unavailable")
        val upload = upload(id) ?: throw java.io.IOException("Folder upload task is unavailable")
        if (!plan.matches(upload)) throw java.io.IOException("Folder upload identity changed")
        plan
    }

    /** 来源清单与任务同时保存成功后才允许后台入队。 */
    internal fun createFolderUploadDurably(upload: PersistedUpload, plan: FolderUploadPlan): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        require(plan.matches(upload) && plan.totalBytes == upload.expectedBytes)
        val existing = allUploads()
        if (existing.any { it.id == upload.id || it.profileId == upload.profileId && it.sourceUri == upload.sourceUri &&
                it.destinationPath == upload.destinationPath && !it.canRemoveFinishedUpload() } ||
            preferences.contains(folderUploadKey(upload.id))) return@synchronized false
        val saved = preferences.edit()
            .putString(KEY_UPLOADS, json.encodeToString(ListSerializer(PersistedUpload.serializer()), existing + upload))
            .putString(folderUploadKey(upload.id), json.encodeToString(plan)).commit()
        if (saved) notifyTransferChanged()
        saved
    }

    /** 原执行器可保存迟到的确定事实；换执行器后不能覆盖新阶段或来源。 */
    internal fun updateFolderUploadPlan(
        id: String, executionId: String, transform: (FolderUploadPlan) -> FolderUploadPlan,
    ): FolderUploadPlan? = synchronized(TRANSFER_STORE_LOCK) {
        val upload = upload(id)?.takeIf { it.workId == executionId } ?: return@synchronized null
        val current = folderUploadPlan(id) ?: throw java.io.IOException("Folder upload plan is unavailable")
        val next = transform(current)
        require(next.matches(upload) && next.sameDefinition(current))
        val updated = upload.copy(completedBytes = next.completedBytes, requiresRefresh = next.requiresRefresh)
        if (!preferences.edit()
                .putString(folderUploadKey(id), json.encodeToString(next))
                .putString(KEY_UPLOADS, json.encodeToString(ListSerializer(PersistedUpload.serializer()),
                    allUploads().map { if (it.id == id) updated else it })).commit()
        ) throw java.io.IOException("Folder upload progress could not be saved")
        notifyTransferChanged()
        next
    }

    private fun folderUploadKey(id: String) = "folder_upload_plan_v1_" +
        java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(id.toByteArray(Charsets.UTF_8))

    /** 入队与手动继续共用一个原子执行权；来源和未知项不因继续而改变。 */
    internal fun beginFolderUploadExecution(expected: PersistedUpload, executionId: String): PersistedUpload? = synchronized(TRANSFER_STORE_LOCK) {
        if (upload(expected.id) != expected || expected.state !in setOf(TransferState.WAITING, TransferState.PAUSED, TransferState.FAILED, TransferState.CANCELLED) ||
            expected.state == TransferState.WAITING && expected.workId != null) return@synchronized null
        val plan = folderUploadPlan(expected.id) ?: return@synchronized null
        val nextPlan = plan.recoveringInterruptedEntries().copy(entries = plan.recoveringInterruptedEntries().entries.map {
            if (it.source.sourceIssue == null && it.state in setOf(FolderUploadEntryState.FAILED, FolderUploadEntryState.PAUSED, FolderUploadEntryState.CANCELLED))
                it.copy(state = FolderUploadEntryState.PENDING, errorKind = null) else it
        })
        val next = expected.copy(workId = executionId, state = TransferState.WAITING, errorKind = null,
            completedBytes = nextPlan.completedBytes, requiresRefresh = nextPlan.requiresRefresh)
        if (!preferences.edit().putString(folderUploadKey(expected.id), json.encodeToString(nextPlan))
                .putString(KEY_UPLOADS, json.encodeToString(ListSerializer(PersistedUpload.serializer()),
                    allUploads().map { if (it.id == expected.id) next else it })).commit()) return@synchronized null
        notifyTransferChanged()
        next
    }

    fun virtualMachineImageImports(profileId: String): List<PersistedVirtualMachineImageImport> = synchronized(TRANSFER_STORE_LOCK) {
        synchronized(VMM_IMPORT_LOCK) {
            allVirtualMachineImageImports().filter { it.profileId == profileId }
        }
    }

    fun virtualMachineImageImport(id: String): PersistedVirtualMachineImageImport? = synchronized(TRANSFER_STORE_LOCK) {
        synchronized(VMM_IMPORT_LOCK) {
            allVirtualMachineImageImports().firstOrNull { it.id == id }
        }
    }

    fun servers(profileId: String): List<PersistedServerTransfer> = synchronized(TRANSFER_STORE_LOCK) {
        allServers().filter { it.profileId == profileId }
    }

    fun server(id: String): PersistedServerTransfer? = synchronized(TRANSFER_STORE_LOCK) {
        allServers().firstOrNull { it.id == id }
    }

    internal fun extractionOutputs(record: PersistedServerTransfer): List<FileServerMutationExpectedOutput> = synchronized(TRANSFER_STORE_LOCK) {
        if (!record.isPlannedExtraction) return@synchronized record.expectedOutputs.map { it.toFileServerMutationExpectedOutput() }
        val raw = preferences.getString(fileArchiveVerificationKey(record.id), null) ?: throw FileArchiveVerificationUnavailable()
        val plan = runCatching { json.decodeFromString<FileArchiveVerificationPlan>(raw) }.getOrNull()
            ?.takeIf { it.matches(record) } ?: throw FileArchiveVerificationUnavailable()
        plan.outputs.map { it.toOutput() }
    }

    /** 清单与原任务同时保存，失败时保持零 start；归属仍由原执行代次限制。 */
    internal fun updateExtractionOutputs(id: String, generation: Long, outputs: List<FileServerMutationExpectedOutput>): PersistedServerTransfer? = synchronized(TRANSFER_STORE_LOCK) {
        val record = server(id)?.takeIf { it.isPlannedExtraction && it.executionGeneration == generation && it.submissionPhase == PersistedServerSubmissionPhase.PREPARING }
            ?: return@synchronized null
        val next = record.copy(expectedOutputs = outputs.map { it.toPersistedServerExpectedOutput() })
        val plan = FileArchiveVerificationPlan(taskId = id, profileId = record.profileId,
            sourcePath = record.sourceBaselines.single().path, destinationPath = record.destinationFolderBaseline!!.path,
            outputs = outputs.map { FileArchiveVerificationOutput(it.path, it.isDirectory, it.expectedBytes, it.requiresTaskCompletion) })
        require(plan.matches(next))
        saveServers(allServers().map { if (it.id == id) next else it }, plan)
        next
    }

    fun fileBackgroundTaskSnapshot(profileId: String): PersistedFileBackgroundTaskSnapshot? = synchronized(TRANSFER_STORE_LOCK) {
        allFileBackgroundTaskSnapshots().firstOrNull { it.profileId == profileId }
    }

    fun photoBackupSource(profileId: String): PersistedPhotoBackupSource? = synchronized(TRANSFER_STORE_LOCK) {
        allBackupSources().firstOrNull { it.profileId == profileId }
    }

    /** URI 授权属于整个应用；一个账号结束任务不能撤销另一账号仍在使用的授权。 */
    fun hasReadGrantReference(uri: String, excludingRecordId: String? = null): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        allUploads().any { it.id != excludingRecordId && (!it.canRemoveFinishedUpload()) &&
            (it.sourceUri == uri || it.sourceTreeUri == uri) } ||
            allBackupSources().any { it.treeUri == uri } ||
            allVirtualMachineImageImports().any { it.id != excludingRecordId && it.ownsPersistedReadGrant && it.sourceUri == uri }
    }

    fun hasDownloadDestinationReference(uri: String, excludingRecordId: String? = null): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        all().any { it.id != excludingRecordId && it.destinationUri == uri &&
            (it.state !in TERMINAL_STATES || (it.isArchiveDownload || it.isVFSDownload) && it.state == TransferState.FAILED) }
    }

    fun upsert(download: PersistedDownload) = synchronized(TRANSFER_STORE_LOCK) {
        val next = all().filterNot { it.id == download.id } + download
        save(next)
    }

    /**
     * WorkManager 入队前保存任务事实；只有确认写入成功后调用方才能提交后台任务。
     * 普通状态和进度更新继续使用 [upsert]/[update] 的异步写入，避免阻塞主线程。
     */
    fun upsertDownloadDurably(download: PersistedDownload): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        saveDurably(all().filterNot { it.id == download.id } + download)
    }

    fun update(id: String, transform: (PersistedDownload) -> PersistedDownload): PersistedDownload? = synchronized(TRANSFER_STORE_LOCK) {
        var updated: PersistedDownload? = null
        val next = all().map { current ->
            if (current.id == id) transform(current).also { updated = it } else current
        }
        if (updated != null) save(next)
        return updated
    }

    /**
     * 仅用于入队边界的受保护替换。transform 返回 null 时表示记录已经不属于当前操作，
     * 不写入也不覆盖较新的状态。
     */
    fun updateDownloadDurably(
        id: String,
        transform: (PersistedDownload) -> PersistedDownload?,
    ): PersistedDownload? = synchronized(TRANSFER_STORE_LOCK) {
        var updated: PersistedDownload? = null
        val next = all().map { current ->
            if (current.id != id) {
                current
            } else {
                transform(current)?.also { updated = it } ?: current
            }
        }
        return updated?.takeIf { saveDurably(next) }
    }

    fun upsert(upload: PersistedUpload) = synchronized(TRANSFER_STORE_LOCK) {
        saveUploads(allUploads().filterNot { it.id == upload.id } + upload)
    }

    fun updateUpload(id: String, transform: (PersistedUpload) -> PersistedUpload): PersistedUpload? = synchronized(TRANSFER_STORE_LOCK) {
        var updated: PersistedUpload? = null
        val next = allUploads().map { current ->
            if (current.id == id) transform(current).also { updated = it } else current
        }
        if (updated != null) saveUploads(next)
        return updated
    }

    fun upsertVirtualMachineImageImport(import: PersistedVirtualMachineImageImport) = synchronized(TRANSFER_STORE_LOCK) {
        synchronized(VMM_IMPORT_LOCK) {
            saveVirtualMachineImageImports(allVirtualMachineImageImports().upsert(import))
        }
    }

    fun updateVirtualMachineImageImport(
        id: String,
        transform: (PersistedVirtualMachineImageImport) -> PersistedVirtualMachineImageImport,
    ): PersistedVirtualMachineImageImport? = synchronized(TRANSFER_STORE_LOCK) {
        return synchronized(VMM_IMPORT_LOCK) {
            val (imports, updated) = allVirtualMachineImageImports().updateById(id, transform)
            if (updated != null) saveVirtualMachineImageImports(imports)
            updated
        }
    }

    /** 同一 NAS 资料和映像名称只允许一个非终态后台导入占有执行权。 */
    fun claimVirtualMachineImageImportWork(id: String, workId: String): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        return synchronized(VMM_IMPORT_LOCK) {
            val imports = allVirtualMachineImageImports()
            if (!imports.canClaimWork(id)) return@synchronized false
            saveVirtualMachineImageImports(
                imports.map { if (it.id == id) it.copy(workId = workId) else it },
            )
            true
        }
    }

    /** 首次提交在同一临界区完成同名判重、插入和执行权领取。 */
    fun insertAndClaimVirtualMachineImageImport(
        import: PersistedVirtualMachineImageImport,
        workId: String,
    ): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        synchronized(VMM_IMPORT_LOCK) {
        val current = allVirtualMachineImageImports()
        val (imports, inserted) = current.insertAndClaimWork(import, workId)
        if (!inserted) return@synchronized false
        saveVirtualMachineImageImports(imports)
        true
    }
    }

    /** 仅撤销仍由同一 WorkManager 请求占有的领取，避免异常回滚覆盖后来执行者。 */
    fun releaseVirtualMachineImageImportWork(id: String, workId: String): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        synchronized(VMM_IMPORT_LOCK) {
            val imports = allVirtualMachineImageImports()
            val (releasedImports, released) = imports.releaseWorkClaim(id, workId)
            if (!released) return@synchronized false
            saveVirtualMachineImageImports(releasedImports)
            released
        }
    }

    /** 首次入队同步失败时，仅移除仍处于准备阶段且由该请求拥有的新记录。 */
    fun removeOwnedPreparingVirtualMachineImageImport(id: String, workId: String): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        synchronized(VMM_IMPORT_LOCK) {
            val current = allVirtualMachineImageImports()
            val (imports, removed) = current.removeOwnedPreparingImport(id, workId)
            if (!removed) return@synchronized false
            saveVirtualMachineImageImports(imports)
            true
        }
    }

    fun removeVirtualMachineImageImport(id: String): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        return synchronized(VMM_IMPORT_LOCK) {
            val current = allVirtualMachineImageImports()
            val (imports, removed) = current.removeFinishedById(id)
            if (!removed) return@synchronized false
            saveVirtualMachineImageImports(imports)
            true
        }
    }

    fun upsert(server: PersistedServerTransfer) = synchronized(TRANSFER_STORE_LOCK) {
        saveServers(allServers().filterNot { it.id == server.id } + server)
    }

    fun updateServer(
        id: String,
        transform: (PersistedServerTransfer) -> PersistedServerTransfer,
    ): PersistedServerTransfer? = synchronized(TRANSFER_STORE_LOCK) {
        var updated: PersistedServerTransfer? = null
        val next = allServers().map { current ->
            if (current.id == id) transform(current).also { updated = it } else current
        }
        if (updated != null) saveServers(next)
        return updated
    }

    /** 只有已经安全收敛的终态任务可以从普通清理入口移除。 */
    fun removeServer(id: String): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        val current = allServers()
        val target = current.firstOrNull { it.id == id } ?: return false
        if (!target.canRemoveFinishedServer()) return false
        saveServers(current.filterNot { it.id == id })
        return true
    }

    /** 丢弃无法还原目标的损坏记录；正常任务始终带有完整目标基线。 */
    fun removeInvalidServer(id: String): Boolean = synchronized(TRANSFER_STORE_LOCK) {
        val current = allServers()
        val target = current.firstOrNull { it.id == id } ?: return false
        if (target.toFileServerMutationTarget() != null) return false
        saveServers(current.filterNot { it.id == id })
        return true
    }

    fun replaceFileBackgroundTaskSnapshot(snapshot: PersistedFileBackgroundTaskSnapshot) = synchronized(TRANSFER_STORE_LOCK) {
        saveFileBackgroundTaskSnapshots(
            allFileBackgroundTaskSnapshots().filterNot { it.profileId == snapshot.profileId } + snapshot,
        )
    }

    fun upsertPhotoBackupSource(source: PersistedPhotoBackupSource) = synchronized(TRANSFER_STORE_LOCK) {
        saveBackupSources(allBackupSources().filterNot { it.profileId == source.profileId } + source)
    }

    fun removePhotoBackupSource(profileId: String) = synchronized(TRANSFER_STORE_LOCK) {
        saveBackupSources(allBackupSources().filterNot { it.profileId == profileId })
    }

    fun removeTerminal(profileId: String) = synchronized(TRANSFER_STORE_LOCK) {
        val (removed, retained) = all().partition { it.profileId == profileId && it.state in TERMINAL_STATES }
        save(retained, removed.map(PersistedDownload::id))
        removeFinishedUploads(profileId)
        saveServers(
            allServers().filterNot {
                it.profileId == profileId && it.canRemoveFinishedServer()
            },
        )
        synchronized(VMM_IMPORT_LOCK) {
            saveVirtualMachineImageImports(
                allVirtualMachineImageImports().filterNot {
                    it.profileId == profileId && it.canRemoveFromHistory()
                },
            )
        }
    }

    fun remove(id: String) = synchronized(TRANSFER_STORE_LOCK) {
        save(all().filterNot { it.id == id }, listOf(id))
    }

    fun removeProfile(profileId: String) = synchronized(TRANSFER_STORE_LOCK) {
        val (removed, retained) = all().partition { it.profileId == profileId }
        save(retained, removed.map(PersistedDownload::id))
        removeFinishedUploads(profileId)
        saveServers(allServers().filterNot { it.profileId == profileId && it.canRemoveFinishedServer() })
        synchronized(VMM_IMPORT_LOCK) {
            saveVirtualMachineImageImports(
                allVirtualMachineImageImports().filterNot { it.profileId == profileId && it.canRemoveFromHistory() },
            )
        }
        saveBackupSources(allBackupSources().filterNot { it.profileId == profileId })
        saveFileBackgroundTaskSnapshots(
            allFileBackgroundTaskSnapshots().filterNot { it.profileId == profileId },
        )
    }

    private fun all(): List<PersistedDownload> {
        val value = preferences.getString(KEY_DOWNLOADS, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(PersistedDownload.serializer()), value)
        }.getOrDefault(emptyList())
    }

    private fun save(downloads: List<PersistedDownload>, removedIds: List<String> = emptyList()) {
        preferences.edit()
            .putString(
                KEY_DOWNLOADS,
                json.encodeToString(ListSerializer(PersistedDownload.serializer()), downloads),
            )
            .apply { removedIds.forEach { remove(archiveDownloadKey(it)); remove(vfsDownloadKey(it)) } }
            .apply()
        notifyTransferChanged()
    }

    private fun saveDurably(downloads: List<PersistedDownload>): Boolean =
        preferences.edit()
            .putString(
                KEY_DOWNLOADS,
                json.encodeToString(ListSerializer(PersistedDownload.serializer()), downloads),
            )
            .commit()
            .also { if (it) notifyTransferChanged() }

    private fun allUploads(): List<PersistedUpload> {
        val value = preferences.getString(KEY_UPLOADS, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(PersistedUpload.serializer()), value)
        }.getOrDefault(emptyList())
    }

    private fun removeFinishedUploads(profileId: String) {
        val (removed, retained) = allUploads().partition { it.profileId == profileId && it.canRemoveFinishedUpload() }
        saveUploads(retained, removed.map(PersistedUpload::id))
    }

    private fun saveUploads(uploads: List<PersistedUpload>, removedIds: List<String> = emptyList()) {
        check(
            preferences.edit()
            .putString(KEY_UPLOADS, json.encodeToString(ListSerializer(PersistedUpload.serializer()), uploads))
            .apply { removedIds.forEach { remove(uploadContentKey(it)); remove(folderUploadKey(it)) } }
            .commit(),
        ) { "transfer.upload_state_not_persisted" }
        notifyTransferChanged()
    }

    private fun allVirtualMachineImageImports(): List<PersistedVirtualMachineImageImport> {
        val value = preferences.getString(KEY_VMM_IMAGE_IMPORTS, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString(
                ListSerializer(PersistedVirtualMachineImageImport.serializer()),
                value,
            )
        }.getOrDefault(emptyList())
    }

    private fun saveVirtualMachineImageImports(imports: List<PersistedVirtualMachineImageImport>) {
        check(
            preferences.edit()
                .putString(
                    KEY_VMM_IMAGE_IMPORTS,
                    json.encodeToString(
                        ListSerializer(PersistedVirtualMachineImageImport.serializer()),
                        imports,
                    ),
                )
                .commit(),
        ) { "transfer.vmm_image_import_state_not_persisted" }
        notifyTransferChanged()
    }

    private fun allBackupSources(): List<PersistedPhotoBackupSource> {
        val value = preferences.getString(KEY_BACKUP_SOURCES, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(PersistedPhotoBackupSource.serializer()), value)
        }.getOrDefault(emptyList())
    }

    private fun allServers(): List<PersistedServerTransfer> {
        val value = preferences.getString(KEY_SERVERS, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString(ListSerializer(PersistedServerTransfer.serializer()), value)
        }.getOrDefault(emptyList())
    }

    private fun saveServers(servers: List<PersistedServerTransfer>, verificationPlan: FileArchiveVerificationPlan? = null) {
        val removed = allServers().filter { prior -> servers.none { it.id == prior.id } }
        check(
            preferences.edit()
                .putString(
                    KEY_SERVERS,
                    json.encodeToString(ListSerializer(PersistedServerTransfer.serializer()), servers),
                )
                .also { editor ->
                    removed.forEach { editor.remove(fileArchiveVerificationKey(it.id)) }
                    verificationPlan?.let { editor.putString(fileArchiveVerificationKey(it.taskId), json.encodeToString(it)) }
                }.commit(),
        ) { "transfer.server_state_not_persisted" }
        notifyTransferChanged()
    }

    private fun allFileBackgroundTaskSnapshots(): List<PersistedFileBackgroundTaskSnapshot> {
        val value = preferences.getString(KEY_FILE_BACKGROUND_TASKS, null) ?: return emptyList()
        return runCatching {
            json.decodeFromString(
                ListSerializer(PersistedFileBackgroundTaskSnapshot.serializer()),
                value,
            )
        }.getOrDefault(emptyList())
    }

    private fun saveFileBackgroundTaskSnapshots(snapshots: List<PersistedFileBackgroundTaskSnapshot>) {
        check(
            preferences.edit()
                .putString(
                    KEY_FILE_BACKGROUND_TASKS,
                    json.encodeToString(
                        ListSerializer(PersistedFileBackgroundTaskSnapshot.serializer()),
                        snapshots,
                    ),
                )
                .commit(),
        ) { "transfer.file_background_tasks_not_persisted" }
        notifyTransferChanged()
    }

    private fun saveBackupSources(sources: List<PersistedPhotoBackupSource>) {
        check(
            preferences.edit()
                .putString(
                    KEY_BACKUP_SOURCES,
                    json.encodeToString(ListSerializer(PersistedPhotoBackupSource.serializer()), sources),
                )
                .commit(),
        ) { "transfer.photo_backup_source_not_persisted" }
        notifyTransferChanged()
    }

    private companion object {
        val TRANSFER_STORE_LOCK = Any()
        private val VMM_IMPORT_LOCK = Any()
        const val PREFERENCES_NAME = "lanstash_transfer_tasks"
        const val KEY_DOWNLOADS = "downloads"
        const val KEY_UPLOADS = "uploads"
        const val KEY_VMM_IMAGE_IMPORTS = "vmm_image_imports"
        const val KEY_SERVERS = "servers"
        const val KEY_BACKUP_SOURCES = "photo_backup_sources"
        const val KEY_FILE_BACKGROUND_TASKS = "file_background_tasks"
        val TERMINAL_STATES = setOf(
            TransferState.SUCCEEDED,
            TransferState.FAILED,
            TransferState.CANCELLED,
        )
    }
}
