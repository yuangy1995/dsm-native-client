package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.packageDigest
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.*

@Serializable internal enum class NasSmartStage { PREPARED, SUBMITTED, ACCEPTED, VERIFIED, REJECTED, CANCELLED }
@Serializable internal enum class NasSmartAction { QUICK, EXTENDED, STOP;
    val type get() = when (this) { QUICK -> NasDiskTestType.QUICK; EXTENDED -> NasDiskTestType.EXTENDED; STOP -> null }
    val parameter get() = when (this) { QUICK -> "quick"; EXTENDED -> "extend"; STOP -> "stop" }
    companion object { fun from(type: NasDiskTestType?) = when (type) { NasDiskTestType.QUICK -> QUICK; NasDiskTestType.EXTENDED -> EXTENDED; null -> STOP } }
}
internal data class NasSmartHistory(val quick: String?, val extended: String?, val result: String?)
internal data class NasSmartReading(val disk: NasStorageDisk, val status: NasDiskTestStatus, val historyFailure: DsmFailure? = null)
internal fun smartIdentity(disk: NasStorageDisk) = packageDigest(JsonArray(listOf(JsonPrimitive(disk.id), JsonPrimitive(disk.deviceId), JsonPrimitive(disk.supportsSmartTest))).toString())
internal fun smartMatches(status: NasDiskTestStatus, action: NasSmartAction) = if (action == NasSmartAction.STOP) !status.isRunning else status.isRunning && status.runningType == action.type
internal fun smartCanStart(status: NasDiskTestStatus, action: NasSmartAction) = !status.isBusyWithOtherTest &&
    (if (status.isRunning) status.runningType != null && action == NasSmartAction.STOP else status.runningType == null && action != NasSmartAction.STOP)
internal fun sameSmartBaseline(a: NasDiskTestStatus, b: NasDiskTestStatus) = a.diskId == b.diskId && a.isRunning == b.isRunning &&
    a.isBusyWithOtherTest == b.isBusyWithOtherTest && a.runningType == b.runningType

/** 固定原盘与原运行状态；只有一次写入，提交后及跨重启均只回读。 */
internal class NasSmartTestRepository(private val gateway: NasManagementGateway, private val supports: (String, Int) -> Boolean,
    private val disksReader: suspend () -> List<NasStorageDisk>, private val statusReader: suspend (NasStorageDisk) -> NasDiskTestStatus,
    private val historyReader: suspend (NasStorageDisk) -> NasSmartHistory, private val pause: suspend () -> Unit = { delay(1_000) }) {
    private val lock = Mutex()
    private fun capability() {
        if (!supports("SYNO.Storage.CGI.Storage", 1) || !supports("SYNO.Core.Storage.Disk", 1)) throw DsmFailure(null,
            "Drive tests unavailable", "Open Storage Manager in DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
    }
    private suspend fun access() {
        capability()
        gateway.requireWriteAccess()
    }
    suspend fun disks(): List<NasStorageDisk> { capability(); return disksReader() }
    private suspend fun target(identity: String) = disks().singleOrNull { smartIdentity(it) == identity && it.supportsSmartTest } ?: smartConflict()
    suspend fun read(original: NasStorageDisk, history: Boolean): NasSmartReading {
        val disk = target(smartIdentity(original))
        val status = statusReader(disk)
        if (!history) return NasSmartReading(disk, status)
        return try {
            val log = historyReader(disk)
            NasSmartReading(disk, status.copy(lastQuickTest = log.quick, lastExtendedTest = log.extended,
                lastResult = status.lastResult ?: log.result, isHistoryAvailable = true))
        } catch (error: Exception) {
            if (error is CancellationException || directoryTrustFailure(error)) throw error
            NasSmartReading(disk, status, error as? DsmFailure ?: DsmFailure(null, "Drive test history unavailable", "Refresh the drive status.", kind = DsmErrorKind.REQUEST_FAILED))
        }
    }
    suspend fun recover(identity: String): NasSmartReading { access(); val disk = target(identity); return NasSmartReading(disk, statusReader(disk)) }
    suspend fun perform(original: NasStorageDisk, baseline: NasDiskTestStatus, action: NasSmartAction, checkpoint: (NasSmartStage) -> Unit): NasSmartReading? {
        if (!lock.tryLock()) smartConflict()
        var submitted = false
        try {
            access()
            if (baseline.diskId != original.id || !original.supportsSmartTest || !smartCanStart(baseline, action)) smartConflict()
            val current = read(original, false)
            if (!sameSmartBaseline(current.status, baseline)) smartConflict()
            currentCoroutineContext().ensureActive()
            checkpoint(NasSmartStage.SUBMITTED); submitted = true
            try {
                gateway.call("SYNO.Core.Storage.Disk", "do_smart_test", 1,
                    mapOf("device" to JsonPrimitive(original.deviceId), "type" to JsonPrimitive(action.parameter)), write = true)
            } catch (error: Exception) {
                if (directoryExplicitRejection(error)) { checkpoint(NasSmartStage.REJECTED); throw error }
                if (error is CancellationException || directoryTrustFailure(error)) throw error
                return verify(smartIdentity(original), action, checkpoint)
            }
            checkpoint(NasSmartStage.ACCEPTED)
            return verify(smartIdentity(original), action, checkpoint)
        } catch (error: Exception) {
            if (!submitted) checkpoint(NasSmartStage.CANCELLED)
            throw error
        } finally { lock.unlock() }
    }
    private suspend fun verify(identity: String, action: NasSmartAction, checkpoint: (NasSmartStage) -> Unit): NasSmartReading? {
        var latest: NasSmartReading? = null
        var failure: DsmFailure? = null
        repeat(6) { attempt ->
            if (attempt > 0) pause()
            try {
                latest = recover(identity); failure = null
                if (smartMatches(requireNotNull(latest).status, action)) { checkpoint(NasSmartStage.VERIFIED); return latest }
            } catch (error: DsmFailure) {
                if (error.kind !in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.UNKNOWN)) throw error
                failure = error
            }
        }
        failure?.let { throw it }
        return latest
    }
}
internal fun smartConflict(): Nothing = throw DsmFailure(null, "Drive test changed", "Refresh the drive and choose the action again.", kind = DsmErrorKind.NAS_SMART_CHANGED)
