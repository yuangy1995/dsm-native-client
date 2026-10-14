package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.data.SynologyPhotoSharingCodec
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoSharingState(
    val original: SynologyPhotoAlbumSharing? = null,
    val access: SynologyPhotoLinkAccess = SynologyPhotoLinkAccess.DISABLED,
    val members: List<SynologyPhotoShareGrant>? = null,
    val names: Map<SynologyPhotoShareMemberId, String> = emptyMap(),
    val passwordMode: SynologyPhotoSharingPassword = SynologyPhotoSharingPassword.UNCHANGED,
    val password: String = "", val expiration: Long? = null,
    val selectingMembers: Boolean = false, val candidates: List<SynologyPhotoShareRecipient>? = null,
    val loading: Boolean = false, val error: Throwable? = null, val search: String = "",
) {
    val change: SynologyPhotoSharingChange? get() = original?.let { SynologyPhotoSharingChange(it.snapshot, access, members, expiration, passwordMode) }
    val valid: Boolean get() = change?.let { runCatching { SynologyPhotoSharingCodec.validate(it, original?.album?.type == "condition") }.isSuccess } == true &&
        (passwordMode != SynologyPhotoSharingPassword.SET || password.isNotEmpty())
    val roles: List<String> get() = if (original?.album?.type == "condition") listOf("view", "download") else listOf("view", "download", "upload")
    override fun toString() = "PhotoSharingState"
}

/** 只保存当前表单；密码不使用 saved state，也不进入相册恢复记录。 */
internal class SynologyPhotoSharingModel(
    private val repository: SynologyPhotosServing, private val scope: CoroutineScope,
    private val requireCurrent: () -> Unit, private val canEdit: () -> Boolean,
) {
    private val mutable = MutableStateFlow(SynologyPhotoSharingState())
    val state = mutable.asStateFlow()
    private var generation = 0L
    private var loader: Job? = null
    fun initialize(value: SynologyPhotoAlbumSharing) {
        reset()
        mutable.value = SynologyPhotoSharingState(original = value, access = value.snapshot.access, members = value.snapshot.members,
            names = value.recipients.associate { it.id to it.name })
    }
    fun reset() { generation++; loader?.cancel(); mutable.value = SynologyPhotoSharingState() }
    fun clearPassword() { mutable.update { it.copy(password = "") } }
    fun access(value: SynologyPhotoLinkAccess) { if (canEdit()) mutable.update { it.copy(access = value) } }
    fun passwordMode(value: SynologyPhotoSharingPassword) { if (canEdit()) mutable.update { it.copy(passwordMode = value, password = "") } }
    fun password(value: String) { if (canEdit() && state.value.passwordMode == SynologyPhotoSharingPassword.SET) mutable.update { it.copy(password = value) } }
    fun expiration(value: Long?) { if (canEdit() && (value == null || value >= 0)) mutable.update { it.copy(expiration = value) } }
    fun role(id: SynologyPhotoShareMemberId, value: String) {
        if (!canEdit() || value !in state.value.roles) return
        mutable.update { it.copy(members = it.members?.map { member -> if (member.id == id) member.copy(role = value) else member }) }
    }
    fun remove(id: SynologyPhotoShareMemberId) { if (canEdit()) mutable.update { it.copy(members = it.members?.filterNot { member -> member.id == id }) } }
    fun add(recipient: SynologyPhotoShareRecipient) {
        val old = state.value; val members = old.members ?: return
        if (!canEdit() || recipient !in old.candidates.orEmpty() || members.any { it.id == recipient.id }) return
        mutable.update { it.copy(members = members + SynologyPhotoShareGrant(recipient.id, "view"), names = it.names + (recipient.id to recipient.name)) }
    }
    fun search(value: String) { if (canEdit()) mutable.update { it.copy(search = value) } }
    fun closeMembers() { mutable.update { it.copy(selectingMembers = false) } }
    fun selectMembers(): Job? {
        if (!canEdit() || state.value.members == null) return null
        mutable.update { it.copy(selectingMembers = true) }
        if (state.value.loading || state.value.candidates != null) return null
        val token = generation
        mutable.update { it.copy(loading = true, error = null) }
        loader = scope.launch {
            try {
                requireCurrent()
                val values = repository.sharingRecipients()
                currentCoroutineContext().ensureActive(); requireCurrent()
                if (token == generation) mutable.update { it.copy(candidates = values) }
            } catch (error: Exception) { if (error !is CancellationException && token == generation) mutable.update { it.copy(error = error) } }
            finally { if (token == generation) mutable.update { it.copy(loading = false) } }
        }
        return loader
    }
}
