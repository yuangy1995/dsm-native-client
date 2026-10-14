package io.github.qwertyuiop1995.dsmnativeclient.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class NasDirectoryState(
    val accounts: List<NasAccount>? = null, val groups: List<NasGroup>? = null,
    val accountsFailure: Exception? = null, val groupsFailure: Exception? = null,
    val loading: Boolean = false, val busy: Boolean = false, val failure: Exception? = null,
    val editor: NasDirectoryChange? = null, val deletion: NasDirectoryChange? = null,
    val records: List<NasDirectoryRecord> = emptyList(),
) { val writable get() = !loading && !busy && records.none { !it.terminal } && (failure as? DsmFailure)?.kind != DsmErrorKind.LOCAL_STORAGE_FAILED }

/** 一个账号的一份提交记录；切换连接取消读取并清空含密码表单，恢复永不重放写请求。 */
internal class NasDirectoryModel(
    private val scope: CoroutineScope, private val repository: () -> DsmRepository?,
    private val store: () -> NasDirectoryActivityStore, private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val mutable = MutableStateFlow(NasDirectoryState())
    val state = mutable.asStateFlow()
    private var bound: DsmRepository? = null
    private val jobs = mutableMapOf<String, Job>()
    private val lock = Any()
    private fun source(): DsmRepository? = synchronized(lock) {
        val repo = repository()?.takeIf { it.owner != null } ?: return null
        if (bound !== repo) { clear(); bound = repo; val owner = requireNotNull(repo.owner)
            repo.directory.recoveryPending = { store().records(owner).any { !it.terminal } }
        }
        repo.requireCurrentOwner(); repo
    }
    private fun current(repo: DsmRepository) = bound === repo && repository() === repo
    fun clear() = synchronized(lock) { jobs.values.toList().forEach(Job::cancel); jobs.clear(); bound = null; mutable.value = NasDirectoryState() }
    fun load() {
        val repo = source() ?: return
        if (state.value.busy) return
        mutable.update { it.copy(loading = true) }
        launch("load", repo) { loadData(repo) }
    }
    private suspend fun loadData(repo: DsmRepository) {
        val accounts = read { repo.directory.accounts() }; val groups = read { repo.directory.groups() }
        val records = store().records(requireNotNull(repo.owner))
        if (current(repo)) mutable.update { it.copy(accounts = accounts.getOrNull(), groups = groups.getOrNull(),
            accountsFailure = accounts.exceptionOrNull() as? Exception, groupsFailure = groups.exceptionOrNull() as? Exception,
            loading = false, records = records) }
    }
    fun create(kind: NasDirectoryKind) { if (state.value.writable) mutable.update { it.copy(editor = NasDirectoryChange(kind, NasDirectoryAction.CREATE, ""), failure = null) } }
    fun edit(account: NasAccount) { if (state.value.writable && account.canEdit && state.value.accounts?.contains(account) == true)
        mutable.update { it.copy(editor = NasDirectoryChange(NasDirectoryKind.ACCOUNT, NasDirectoryAction.EDIT, account.name,
            account.description.orEmpty(), account.email.orEmpty(), account.disabled, account = account), failure = null) } }
    fun edit(group: NasGroup) { if (state.value.writable && group.canEdit && state.value.groups?.contains(group) == true)
        mutable.update { it.copy(editor = NasDirectoryChange(NasDirectoryKind.GROUP, NasDirectoryAction.EDIT, group.name, group.description.orEmpty(), group = group), failure = null) } }
    fun delete(account: NasAccount) { if (state.value.writable && state.value.accounts?.contains(account) == true) mutable.update { it.copy(deletion = NasDirectoryChange(
        NasDirectoryKind.ACCOUNT, NasDirectoryAction.DELETE, account.name, account = account)) } }
    fun delete(group: NasGroup) { if (state.value.writable && state.value.groups?.contains(group) == true) mutable.update { it.copy(deletion = NasDirectoryChange(
        NasDirectoryKind.GROUP, NasDirectoryAction.DELETE, group.name, group = group)) } }
    fun leavePage() { mutable.update { it.copy(editor = null, deletion = null) } }
    fun dismissEditor() { if (!state.value.busy) mutable.update { it.copy(editor = null, deletion = null, failure = null) } }
    fun dismissFailure() { mutable.update { it.copy(failure = null) } }
    fun confirmDelete() { state.value.deletion?.let(::submit) }
    fun save(change: NasDirectoryChange) {
        val original = state.value.editor ?: return
        if (change.kind != original.kind || change.action != original.action || change.account != original.account || change.group != original.group) return
        submit(change)
    }
    private fun submit(change: NasDirectoryChange) {
        val expected = bound
        val repo = source() ?: return
        if (repo !== expected || !state.value.writable) return
        mutable.update { it.copy(busy = true, failure = null) }
        launch("action", repo) {
            val owner = requireNotNull(repo.owner); val id = UUID.randomUUID().toString()
            store().execute(owner) {
                repo.directory.change(change) { stage ->
                    if (stage == NasDirectoryStage.SUBMITTED) {
                        repo.requireCurrentOwner(); store().begin(directoryRecord(id, owner, change))
                        if (current(repo)) mutable.update { it.copy(editor = null, deletion = null) }
                    } else store().checkpoint(owner, id, stage)
                }
            }
            loadData(repo)
        }
    }
    fun review(id: String) {
        val repo = source() ?: return
        if (state.value.busy) return
        mutable.update { it.copy(busy = true, failure = null) }
        launch("action", repo) {
            val owner = requireNotNull(repo.owner)
            store().execute(owner) {
                val record = store().records(owner).singleOrNull { it.id == id } ?: return@execute
                if (!record.terminal) {
                    repo.refreshAccess()
                    val matches = if (record.kind == NasDirectoryKind.ACCOUNT) {
                        val item = repo.directory.accounts().singleOrNull { packageDigest(directoryKey(it.name)) == record.targetDigest }
                        if (record.action == NasDirectoryAction.DELETE) item == null
                        else item != null && (record.action == NasDirectoryAction.CREATE || item.id == record.numericId) &&
                            packageDigest(directoryFields(item, record.includeGroups).toString()) == record.fieldsDigest
                    } else {
                        val item = repo.directory.groups().singleOrNull { packageDigest(directoryKey(it.name)) == record.targetDigest }
                        if (record.action == NasDirectoryAction.DELETE) item == null
                        else item != null && (record.action == NasDirectoryAction.CREATE || item.id == record.numericId) &&
                            packageDigest(directoryFields(item).toString()) == record.fieldsDigest
                    }
                    if (matches && (!record.requiresAcknowledgement || record.accepted)) store().checkpoint(owner, id, NasDirectoryStage.COMPLETED)
                }
            }
            loadData(repo)
        }
    }
    fun discard(id: String) {
        val repo = source() ?: return; if (state.value.busy) return
        launch("discard", repo) { store().discard(requireNotNull(repo.owner), id); publish(repo) }
    }
    private fun publish(repo: DsmRepository) { val values = store().records(requireNotNull(repo.owner)); if (current(repo)) mutable.update { it.copy(records = values) } }
    private suspend fun <T> read(block: suspend () -> T): Result<T> = try { Result.success(block()) } catch (error: Exception) { if (error is CancellationException) throw error; Result.failure(error) }
    private fun launch(key: String, repo: DsmRepository, block: suspend () -> Unit) = synchronized(lock) {
        jobs.remove(key)?.cancel()
        val job = scope.launch(dispatcher, start = CoroutineStart.LAZY) {
            try { block() } catch (error: Exception) {
                if (error is CancellationException) throw error
                if (current(repo)) mutable.update { it.copy(failure = error, loading = false) }
            } finally {
                if (current(repo)) {
                    try { publish(repo) } catch (error: Exception) { mutable.update { it.copy(failure = error) } }
                    if (key == "action") mutable.update { it.copy(busy = false) }
                }
            }
        }
        jobs[key] = job; job.invokeOnCompletion { synchronized(lock) { if (jobs[key] === job) jobs.remove(key) } }; job.start()
    }
}
