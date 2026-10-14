package io.github.qwertyuiop1995.dsmnativeclient

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import io.github.qwertyuiop1995.dsmnativeclient.data.files.*
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.background.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import java.util.UUID

internal enum class OfficePickerKind { OPEN, EDIT, EXPORT, IMPORT }
internal data class OfficePickerRequest(val token: String, val id: String, val name: String, val kind: OfficePickerKind)
internal data class OfficeExportResult(val request: OfficePickerRequest, val uri: Uri)
internal data class OfficeDocumentViewState(
    val visible: Boolean = false, val records: Loadable<List<OfficeDocumentRecord>> = Loadable.Idle,
    val selectedId: String? = null, val busy: Boolean = false, val failure: DsmFailure? = null,
    val confirmSave: Boolean = false, val confirmDiscard: Boolean = false,
    val picker: OfficePickerRequest? = null, val exported: OfficeExportResult? = null,
    val notice: Int? = null, val completedBytes: Long = 0, val totalBytes: Long = 0,
    val preparingItem: FileItem? = null,
    val saving: Boolean = false,
) { val selected get() = (records as? Loadable.Ready)?.value?.singleOrNull { it.id == selectedId } }

/** 系统选择器回执绑定当前会话和唯一请求；编辑器关闭或页面恢复都不自动回传。 */
internal class OfficeDocumentFeatureModel(
    private val scope: CoroutineScope, private val store: OfficeDocumentStore, private val resolver: () -> ContentResolver,
    private val source: () -> OfficeDocumentEndpoint?, private val allowed: () -> Boolean,
    private val onBusy: (Boolean) -> Unit, private val onSaved: () -> Unit,
    private val canStart: () -> Boolean = { true },
    private val execution: WorkspaceExecution? = null,
) {
    private val transfer = OfficeDocumentTransfer(store)
    private val _state = MutableStateFlow(OfficeDocumentViewState())
    val state = _state.asStateFlow()
    private var bound: OfficeDocumentEndpoint? = null
    private var job: Job? = null
    private var generation = 0L
    private var executionLease: WorkspaceExecutionLease? = null
    private var copyObserver: Job? = null
    private fun observeCopies() {
        if (copyObserver?.isActive == true) return
        copyObserver = scope.launch {
            officeDocumentChanges.drop(1).collect {
                if (_state.value.visible && !_state.value.busy) current()?.let(::load)
            }
        }
    }
    fun show() {
        activate(); val endpoint = current() ?: return
        if (_state.value.busy || !canStart()) return
        _state.update { it.copy(visible = true, selectedId = null, failure = null, notice = null, preparingItem = null) }
        observeCopies()
        load(endpoint)
    }
    fun open(item: FileItem) {
        activate(); val endpoint = current() ?: return
        if (_state.value.busy || _state.value.picker != null || !canStart()) return
        _state.update { it.copy(visible = true, records = Loadable.Loading, selectedId = null, notice = null, preparingItem = item) }
        observeCopies()
        launch(endpoint, activity = WorkspaceExecutionActivity.OFFICE_PREPARE) { transfer.prepare(endpoint, item).also { row ->
            if (current() === endpoint) _state.update { it.copy(selectedId = row.id, preparingItem = null) }
        } }
    }
    fun select(id: String) {
        if (current() != null && !_state.value.busy && rows().any { it.id == id })
            _state.update { it.copy(selectedId = id, failure = null, notice = null, confirmSave = false, confirmDiscard = false, preparingItem = null) }
    }
    fun back() { if (!_state.value.busy) _state.update { it.copy(selectedId = null, failure = null, notice = null, confirmSave = false, confirmDiscard = false, preparingItem = null) } }
    fun dismiss() { if (!_state.value.busy) {
        copyObserver?.cancel(); copyObserver = null
        _state.update { it.copy(visible = false, picker = null, exported = null, confirmSave = false, confirmDiscard = false, preparingItem = null) }
    } }
    fun requestSave() { if (available() && _state.value.selected?.canSave == true) _state.update { it.copy(confirmSave = true) } }
    fun requestDiscard() { if (available() && _state.value.selected?.uncertain == false) _state.update { it.copy(confirmDiscard = true) } }
    fun dismissConfirmation() { _state.update { it.copy(confirmSave = false, confirmDiscard = false) } }
    fun save() {
        val endpoint = current() ?: return
        val row = _state.value.selected?.takeIf { it.canSave } ?: return
        if (!available() || !_state.value.confirmSave) return
        launch(endpoint, saving = true, activity = WorkspaceExecutionActivity.OFFICE_SAVE) {
            val saved = transfer.save(row.id, endpoint, true) { completed, total ->
                if (current() === endpoint) { executionLease?.update(completed, total); _state.update { it.copy(completedBytes = completed, totalBytes = total) } }
            }
            if (saved.phase == OfficeDocumentPhase.SAVED && current() === endpoint) onSaved()
        }
    }
    fun discard() {
        val endpoint = current() ?: return
        val row = _state.value.selected ?: return
        if (!available() || !_state.value.confirmDiscard || row.uncertain) return
        launch(endpoint) {
            withContext(Dispatchers.IO) { store.discard(row, discardExternal = true) }
            if (current() === endpoint) _state.update { it.copy(selectedId = null) }
        }
    }
    fun receiveExternal() {
        val endpoint = current() ?: return
        val row = _state.value.selected?.takeIf { it.externalId != null } ?: return
        if (!available()) return
        if (store.externalActive(row)) { _state.update { it.copy(notice = R.string.office_external_hint) }; return }
        launch(endpoint) { transfer.receiveExternal(row.id, endpoint.owner) }
    }
    fun refresh() {
        val endpoint = current() ?: return
        if (!available()) return
        _state.value.preparingItem?.let { open(it); return }
        val row = _state.value.selected
        if (row == null) { load(endpoint); return }
        launch(endpoint) {
            if (transfer.refresh(row.id, endpoint).phase == OfficeDocumentPhase.SAVED && current() === endpoint) onSaved()
        }
    }
    fun requestPicker(kind: OfficePickerKind) {
        val row = _state.value.selected ?: return
        if (!available() || row.externalId != null || kind == OfficePickerKind.IMPORT && !row.canImport) return
        _state.update { it.copy(picker = OfficePickerRequest(UUID.randomUUID().toString(), row.id, row.baseline.name, kind), notice = null) }
    }
    fun pickerResult(token: String, uri: Uri?) {
        val request = _state.value.picker?.takeIf { it.token == token } ?: return
        val endpoint = current() ?: return
        _state.update { it.copy(picker = null) }
        if (uri == null) return
        launch(endpoint, activity = WorkspaceExecutionActivity.OFFICE_PREPARE) {
            if (uri.scheme != "content") throw officeLocalFailure()
            if (request.kind == OfficePickerKind.IMPORT) {
                val name = withContext(Dispatchers.IO) {
                    resolver().query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }
                            ?.let(cursor::getString) else null
                    } ?: throw officeLocalFailure()
                }
                transfer.importEdited(request.id, endpoint.owner, name) { resolver().openInputStream(uri) ?: throw officeLocalFailure() }
            } else {
                transfer.export(request.id, endpoint.owner) { resolver().openOutputStream(uri, "wt") ?: throw officeLocalFailure() }
                if (current() === endpoint) _state.update { it.copy(exported = OfficeExportResult(request, uri), notice = R.string.office_exported) }
            }
        }
    }
    fun consumeExport(token: String, opened: Boolean = true) {
        if (_state.value.exported?.request?.token == token)
            _state.update { it.copy(exported = null, notice = if (opened) it.notice else R.string.office_no_app) }
    }
    fun pickerUnavailable(token: String) {
        if (_state.value.picker?.token == token) _state.update { it.copy(picker = null, failure = officeLocalFailure()) }
    }
    fun authorizationChanged() { if (bound != null && current() == null) invalidate() }
    fun cancel() { if (_state.value.busy) { _state.update { it.copy(preparingItem = null) }; job?.cancel() } }
    fun invalidate() {
        copyObserver?.cancel(); copyObserver = null
        generation++; job?.cancel(); job = null; bound = null
        if (_state.value.busy) onBusy(false)
        _state.value = OfficeDocumentViewState()
    }
    private fun activate() {
        val endpoint = source()?.takeIf { allowed() } ?: return
        if (bound?.owner != endpoint.owner) { invalidate(); bound = endpoint }
    }
    private fun current() = bound?.takeIf { allowed() && source()?.owner == it.owner }
    private fun available() = current() != null && !_state.value.busy && _state.value.picker == null && canStart()
    private fun rows() = (_state.value.records as? Loadable.Ready)?.value.orEmpty()
    private fun load(endpoint: OfficeDocumentEndpoint) {
        _state.update { it.copy(records = Loadable.Loading) }
        launch(endpoint) {}
    }
    private fun launch(endpoint: OfficeDocumentEndpoint, saving: Boolean = false, activity: WorkspaceExecutionActivity? = null, operation: suspend () -> Unit) {
        job?.cancel(); val epoch = ++generation
        _state.update { it.copy(busy = true, saving = saving, failure = null, notice = null, confirmSave = false, confirmDiscard = false, completedBytes = 0, totalBytes = 0) }
        onBusy(true)
        job = scope.launch {
            var failure: DsmFailure? = null
            var lease: WorkspaceExecutionLease? = null
            try {
                if (activity != null) { lease = execution?.begin(endpoint.owner, activity); executionLease = lease }
                operation()
            }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (error: Exception) { failure = if (error is java.io.IOException || error is SecurityException) officeLocalFailure() else error.asDsmFailure() }
            finally {
                lease?.finish(); if (executionLease === lease) executionLease = null
                if (generation == epoch && current() !== endpoint) invalidate()
                else if (current() === endpoint && generation == epoch) {
                    val records = withContext(NonCancellable + Dispatchers.IO) {
                        try { Loadable.Ready(store.records(endpoint.owner)) } catch (error: Exception) { Loadable.Failed(error.asDsmFailure()) }
                    }
                    if (generation == epoch) {
                        if (current() === endpoint) { _state.update { it.copy(busy = false, saving = false, records = records, failure = failure) }; onBusy(false) }
                        else invalidate()
                    }
                }
            }
        }
    }
}
