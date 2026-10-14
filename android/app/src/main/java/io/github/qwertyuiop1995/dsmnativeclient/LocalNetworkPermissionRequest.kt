package io.github.qwertyuiop1995.dsmnativeclient

import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/** 只保留随机尝试编号；取消登录时销毁等待，迟到授权不得继续另一个账号的登录。 */
internal class LocalNetworkPermissionRequest {
    private val _pending = MutableStateFlow<String?>(null)
    val pending = _pending.asStateFlow()
    private var response: CompletableDeferred<Boolean>? = null

    suspend fun request(): Boolean {
        check(response == null)
        val id = UUID.randomUUID().toString()
        val result = CompletableDeferred<Boolean>()
        response = result
        _pending.value = id
        return try { result.await() } finally {
            if (_pending.value == id) { _pending.value = null; response = null }
        }
    }

    fun complete(id: String?, granted: Boolean) {
        if (id != null && id == _pending.value) response?.complete(granted)
    }
}
