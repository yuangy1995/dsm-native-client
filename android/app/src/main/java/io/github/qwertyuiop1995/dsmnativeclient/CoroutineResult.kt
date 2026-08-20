package io.github.qwertyuiop1995.dsmnativeclient

import kotlinx.coroutines.CancellationException

/**
 * 为挂起操作保留协程取消语义，同时将普通失败映射为 [Result]。
 *
 * `runCatching` 会捕获 [CancellationException]；网络读取与可取消的本地操作不能使用它
 * 把取消伪装成业务失败或空结果。
 */
internal suspend fun <T> suspendRunCatching(block: suspend () -> T): Result<T> =
    try {
        Result.success(block())
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        Result.failure(error)
    }

/** 为 AppViewModel 的通用加载状态转换保留取消传播。 */
internal suspend fun <T> captureLoadable(block: suspend () -> T): Loadable<T> =
    suspendRunCatching(block).fold(
        onSuccess = { Loadable.Ready(it) },
        onFailure = { Loadable.Failed(it.asDsmFailure()) },
    )
