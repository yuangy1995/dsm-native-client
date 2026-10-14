package io.github.qwertyuiop1995.dsmnativeclient.systemfiles

import io.github.qwertyuiop1995.dsmnativeclient.Loadable
import io.github.qwertyuiop1995.dsmnativeclient.R
import io.github.qwertyuiop1995.dsmnativeclient.asDsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.data.DsmRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*

internal data class SystemFileSetting(val profile: NasProfile, val location: SystemFileLocation?, val connected: Boolean)
internal data class SystemFileSettingsState(
    val visible: Boolean = false, val rows: Loadable<List<SystemFileSetting>> = Loadable.Idle,
    val busy: Boolean = false, val failure: DsmFailure? = null, val notice: Int? = null, val filter: String = "",
    val confirmEditing: SystemFileSetting? = null,
)
internal class SystemFileSettingsModel(
    private val scope: CoroutineScope, private val store: SystemDocumentStore, private val profiles: SecureProfileStore,
    private val source: (String) -> DsmRepository?, private val connect: (String) -> Boolean, private val changed: () -> Unit,
) {
    private val _state = MutableStateFlow(SystemFileSettingsState())
    val state = _state.asStateFlow()
    private var generation = 0L
    private var job: Job? = null
    fun show() { _state.update { it.copy(visible = true) }; reload() }
    fun hide() { if (!_state.value.busy) _state.update { it.copy(visible = false, confirmEditing = null) } }
    fun filter(value: String) { _state.update { it.copy(filter = value) } }
    fun connectionChanged() { changed(); if (_state.value.visible && !_state.value.busy) reload() }
    fun signIn(id: String) { if (!_state.value.busy && connect(id)) _state.update { it.copy(visible = false) } }
    fun reload() {
        if (_state.value.busy) return
        _state.update { it.copy(rows = Loadable.Loading, failure = null, notice = null, confirmEditing = null) }
        run { }
    }
    fun requestEditing(id: String, enabled: Boolean) {
        val row = (_state.value.rows as? Loadable.Ready)?.value?.singleOrNull { it.profile.id == id } ?: return
        if (_state.value.busy || row.location?.enabled != true) return
        if (enabled) _state.update { it.copy(confirmEditing = row) }
        else run { store.update(row.location, enabled = true, editing = false); changed() }
    }
    fun dismissEditing() { if (!_state.value.busy) _state.update { it.copy(confirmEditing = null) } }
    fun allowEditing() {
        val row = _state.value.confirmEditing ?: return
        val location = row.location ?: return
        if (_state.value.busy) return
        _state.update { it.copy(confirmEditing = null) }
        val repo = source(row.profile.id) ?: kotlin.run { _state.update { it.copy(notice = R.string.system_files_sign_in) }; return }
        run {
            repo.requireCurrentOwner(); repo.refreshAccess(true); repo.requireCurrentOwner()
            if (repo.owner?.hasSameIdentity(location.owner) != true || !repo.filePermissionAccess.granted) throw workspaceChangedFailure()
            profiles.savedConnectionForRecord(WorkspaceRecordKind.DOCUMENT_PROVIDER, location.id)
            store.update(location, enabled = true, editing = true); changed()
        }
    }
    fun setEnabled(id: String, enabled: Boolean) {
        val row = (_state.value.rows as? Loadable.Ready)?.value?.singleOrNull { it.profile.id == id } ?: return
        if (_state.value.busy) return
        val repo = source(id)
        if (enabled && repo == null) { _state.update { it.copy(notice = R.string.system_files_sign_in) }; return }
        run {
            if (!enabled) row.location?.let { store.update(it, enabled = false); changed() }
            else {
                val endpoint = checkNotNull(repo); endpoint.requireCurrentOwner(); endpoint.refreshAccess(true); endpoint.requireCurrentOwner()
                if (!endpoint.filePermissionAccess.granted) throw DsmFailure(null, "Files are unavailable", "Contact the NAS administrator.", kind = DsmErrorKind.PERMISSION_DENIED)
                val owner = endpoint.owner ?: throw workspaceChangedFailure()
                if (profiles.session(id) == null) throw DsmFailure(null, "Sign in again", "Save the connection to use system files.", kind = DsmErrorKind.NO_SAVED_SESSION)
                val location = store.enable(owner)
                profiles.bindRecord(WorkspaceRecordKind.DOCUMENT_PROVIDER, location.id, owner)
                // 重读原会话和绑定成功后，系统才会返回该根目录。
                profiles.savedConnectionForRecord(WorkspaceRecordKind.DOCUMENT_PROVIDER, location.id)
                changed()
            }
        }
    }
    private fun rows(): List<SystemFileSetting> {
        val locations = store.locations()
        return profiles.profiles().map { profile -> SystemFileSetting(profile,
            locations.singleOrNull { it.owner.profileId == profile.id && profiles.profileForOwner(it.owner) != null },
            source(profile.id) != null) }
    }
    private fun run(action: suspend () -> Unit) {
        val epoch = ++generation; job?.cancel()
        _state.update { it.copy(busy = true, failure = null, notice = null) }
        job = scope.launch(Dispatchers.IO) {
            var failure: DsmFailure? = null
            try { action() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { failure = error.asDsmFailure() }
            finally {
                val rows = withContext(NonCancellable) { try { Loadable.Ready(rows()) } catch (error: Exception) { Loadable.Failed(error.asDsmFailure()) } }
                if (generation == epoch) _state.update { it.copy(rows = rows, busy = false, failure = failure) }
            }
        }
    }
}
