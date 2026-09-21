package io.github.qwertyuiop1995.dsmnativeclient.data.downloads

import java.security.MessageDigest

/** 活动集合只保留不可逆的摘要，不留存 URI、密码或目标路径。 */
internal fun downloadCreationKey(kind: String, vararg values: String): String {
    val digest = MessageDigest.getInstance("SHA-256")
    sequenceOf(kind, *values).forEach { value ->
        val bytes = value.encodeToByteArray()
        digest.update(
            byteArrayOf(
                (bytes.size ushr 24).toByte(),
                (bytes.size ushr 16).toByte(),
                (bytes.size ushr 8).toByte(),
                bytes.size.toByte(),
            ),
        )
        digest.update(bytes)
    }
    return digest.digest().joinToString(separator = "") { byte ->
        (byte.toInt() and 0xff).toString(16).padStart(2, '0')
    }
}
