package io.github.qwertyuiop1995.dsmnativeclient.photos

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

internal data class SynologyPhotoDeletionState(
    val candidate: SynologyPhoto? = null,
    val pending: SynologyPhoto? = null,
    val checking: Boolean = false,
    val writing: Boolean = false,
    val error: Throwable? = null,
    val confirmed: Boolean = false,
)

/** 新平台默认只读；即使显式启用，也必须先准备、用户确认、单次提交、结果回读。 */
internal class SynologyPhotoDeletionModel(
    private val repository: SynologyPhotosServing,
    private val scope: CoroutineScope,
    private val onConfirmed: (SynologyPhoto) -> Unit,
) {
    private val mutable = MutableStateFlow(SynologyPhotoDeletionState())
    val state = mutable.asStateFlow()
    val enabled: Boolean get() = repository.canDeleteOriginals
    private var preparation: Job? = null
    private var submission: Job? = null
    private var candidateGeneration = 0L

    fun prepare(photo: SynologyPhoto): Job? {
        if (state.value.writing || state.value.checking || state.value.pending != null) return null
        if (!enabled) {
            mutable.update { it.copy(error = SynologyPhotoFailure(SynologyPhotoFailureKind.DELETION_UNVERIFIED)) }
            return null
        }
        val token = ++candidateGeneration
        mutable.update { it.copy(checking = true, error = null, confirmed = false) }
        preparation = scope.launch {
            try {
                repository.prepareDeletion(photo)
                currentCoroutineContext().ensureActive()
                if (token == candidateGeneration) mutable.update { it.copy(candidate = photo) }
            } catch (error: Exception) {
                if (error !is CancellationException && token == candidateGeneration) mutable.update { it.copy(error = error) }
            } finally { if (token == candidateGeneration) mutable.update { it.copy(checking = false) } }
        }
        return preparation
    }

    fun cancelCandidate() {
        candidateGeneration++; preparation?.cancel(); preparation = null
        mutable.update { it.copy(candidate = null, checking = false) }
    }

    fun confirm(): Job? {
        val photo = state.value.candidate ?: return null
        if (!enabled || state.value.writing || state.value.pending != null) return null
        // 先标记待核对，离开页面或取消协程也不能让可能已提交的删除重新变成可重试。
        mutable.update { it.copy(candidate = null, pending = photo, writing = true, error = null) }
        submission = scope.launch {
            try {
                apply(repository.deletePhoto(photo, UUID.randomUUID()), photo)
            } catch (_: CancellationException) {
                // 是否已上网未知，保留只读核对入口。
            } catch (error: Exception) {
                // Repository 会把提交后的所有传输错误转换为 PendingReview；异常来自写前检查。
                mutable.update { it.copy(pending = null, error = error) }
            } finally { mutable.update { it.copy(writing = false) } }
        }
        return submission
    }

    fun review(): Job? {
        val photo = state.value.pending ?: return null
        if (state.value.writing) return null
        mutable.update { it.copy(writing = true, error = null) }
        submission = scope.launch {
            try { apply(repository.reviewDeletion(photo), photo) }
            catch (error: Exception) { if (error !is CancellationException) mutable.update { it.copy(error = error) } }
            finally { mutable.update { it.copy(writing = false) } }
        }
        return submission
    }

    private fun apply(result: SynologyPhotoDeletionResult, photo: SynologyPhoto) {
        when (result) {
            SynologyPhotoDeletionResult.CONFIRMED -> {
                mutable.update { it.copy(pending = null, confirmed = true, writing = false) }
                onConfirmed(photo)
            }
            SynologyPhotoDeletionResult.PENDING_REVIEW -> mutable.update { it.copy(pending = photo) }
        }
    }
    fun deactivate() { cancelCandidate(); submission?.cancel() }
}
