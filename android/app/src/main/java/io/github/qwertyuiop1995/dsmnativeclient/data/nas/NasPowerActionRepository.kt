package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.Serializable

@Serializable internal enum class NasPowerStage { PREPARED, SUBMITTED, ACCEPTED, REJECTED, CANCELLED }

/** 电源命令无法回读最终状态；回执只表示接受，任何恢复路径均不发送命令。 */
internal class NasPowerActionRepository(private val gateway: NasManagementGateway, private val supports: (String, Int) -> Boolean) {
    private val lock = Mutex()
    private fun capability() {
        if (!supports("SYNO.Core.System", 3)) throw DsmFailure(null, "Power actions unavailable", "Use DSM to restart or shut down the NAS.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
    }
    suspend fun checkConnection() {
        capability()
        gateway.requireWriteAccess()
        gateway.call("SYNO.Core.System", "info", 3)
        currentCoroutineContext().ensureActive()
    }
    suspend fun perform(action: NasPowerAction, checkpoint: (NasPowerStage) -> Unit) {
        if (!lock.tryLock()) serviceConflict()
        var submitted = false
        try {
            checkConnection()
            checkpoint(NasPowerStage.SUBMITTED)
            submitted = true
            try {
                gateway.call("SYNO.Core.System", if (action == NasPowerAction.SHUTDOWN) "shutdown" else "reboot", 3, write = true)
            } catch (error: Exception) {
                if (directoryExplicitRejection(error)) checkpoint(NasPowerStage.REJECTED)
                throw error
            }
            checkpoint(NasPowerStage.ACCEPTED)
        } catch (error: Exception) {
            if (!submitted) checkpoint(NasPowerStage.CANCELLED)
            throw error
        } finally { lock.unlock() }
    }
}
