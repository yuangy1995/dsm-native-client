package io.github.qwertyuiop1995.dsmnativeclient.virtualmachines

import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmConflict
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.coroutines.sync.Mutex

/** 同一工作区的独立操作文件共用执行锁，完成一项后才允许另一模型重新检查持久保护。 */
internal object VmmExecutionGate {
    private val lock = Any(); private val gates = mutableMapOf<String, Mutex>()
    fun requireIdle(profileId: String) = synchronized(lock) { if (gates[profileId]?.isLocked == true) vmmConflict() }
    suspend fun <T> execute(owner: WorkspaceOwner, wait: Boolean = false, block: suspend () -> T): T {
        val gate = synchronized(lock) { gates.getOrPut(owner.profileId) { Mutex() } }
        if (wait) gate.lock() else if (!gate.tryLock()) vmmConflict()
        try { return block() } finally { gate.unlock() }
    }
}
