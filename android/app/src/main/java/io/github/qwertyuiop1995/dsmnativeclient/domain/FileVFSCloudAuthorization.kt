package io.github.qwertyuiop1995.dsmnativeclient.domain

import io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner
import kotlinx.serialization.json.*
import java.util.UUID

internal data class FileVFSCloudRequest(
    val id: String = UUID.randomUUID().toString(), val owner: WorkspaceOwner, val protocolId: String,
    val loginUrl: String, val createdAtMillis: Long, val callbackName: String = "_lanstash_" + UUID.randomUUID().toString().replace("-", ""),
) {
    override fun toString() = "FileVFSCloudRequest"
}

/** 授权仅在本次请求内存中使用，不参与序列化、日志或保存状态。 */
internal data class FileVFSCloudAuthorization(
    val requestId: String, val owner: WorkspaceOwner, val protocolId: String, val account: String,
    val accessToken: String, val clientId: String?, val refreshToken: String?, val expiresIn: Int?,
) {
    override fun toString() = "FileVFSCloudAuthorization([redacted])"

    companion object {
        fun decode(value: JsonObject, request: FileVFSCloudRequest): FileVFSCloudAuthorization {
            fun text(key: String, optional: Boolean = false): String? {
                val field = value[key]
                if (optional && (field == null || field == JsonNull)) return null
                return (field as? JsonPrimitive)?.takeIf { it.isString }?.content
                    ?: throw IllegalArgumentException("Invalid authorization field")
            }
            require(text("callback") == request.callbackName)
            val account = text("account")!!; val access = text("access_token")!!
            require(account.isNotEmpty() && access.isNotEmpty())
            val expiry = value["expires_in"]?.takeUnless { it == JsonNull }?.let {
                (it as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull?.takeIf { it >= 0 }
                    ?: throw IllegalArgumentException("Invalid authorization expiry")
            }
            return FileVFSCloudAuthorization(request.id, request.owner, request.protocolId, account, access,
                text("client_id", true), text("refresh_token", true), expiry)
        }
    }
}
