package io.github.qwertyuiop1995.dsmnativeclient

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch

/** 仅拥有当前连接协程；取消不会退出已有会话或清除用户保存的信息。 */
internal class LoginAttemptOwner {
    private var job: Job? = null
    val isActive: Boolean get() = job?.isActive == true

    fun launch(scope: CoroutineScope, block: suspend CoroutineScope.() -> Unit) {
        job?.cancel()
        val next = scope.launch(start = CoroutineStart.LAZY, block = block)
        job = next
        next.invokeOnCompletion { if (job === next) job = null }
        next.start()
    }

    fun cancel(): Boolean {
        val current = job?.takeIf(Job::isActive) ?: return false
        job = null
        current.cancel()
        return true
    }
}
