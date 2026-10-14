package io.github.qwertyuiop1995.dsmnativeclient.testing

import io.github.qwertyuiop1995.dsmnativeclient.background.*
import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.coroutines.*

/** 系统授时替身；业务仓储与持久阶段沿正式模型，测试可在精确阶段取消原协程。 */
internal class ExecutionFixture : WorkspaceExecution {
    var denied = false
    val calls = mutableListOf<Pair<WorkspaceOwner, WorkspaceExecutionActivity>>()
    val leases = mutableListOf<Lease>()
    var beforeGrant: suspend () -> Unit = {}
    override suspend fun begin(owner: WorkspaceOwner, activity: WorkspaceExecutionActivity): WorkspaceExecutionLease {
        calls += owner to activity
        if (denied) throw unavailableExecution()
        beforeGrant()
        return Lease(currentCoroutineContext().job).also { leases += it }
    }
    class Lease(private val job: Job) : WorkspaceExecutionLease {
        var finishes = 0
        val progress = mutableListOf<Pair<Long, Long>>()
        fun expire() { job.cancel() }
        override fun update(completed: Long, total: Long) { progress += completed to total }
        override fun finish() { finishes++ }
    }
}
