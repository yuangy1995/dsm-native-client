package io.github.qwertyuiop1995.dsmnativeclient.network

import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.*
import java.util.concurrent.atomic.AtomicReference

/** 官方预览通知只报告同一单元的结果；任何断线都不能触发新的生成写请求。 */
internal interface SynologyPhotoPreviewEvents {
    suspend fun subscribe(unitId: Long)
    suspend fun completion(): Boolean
    fun close()
}

internal enum class PhotoPreviewEventFailureKind { INVALID_ENDPOINT, INVALID_STATE, INVALID_FRAME, DISCONNECTED, REJECTED }
internal class PhotoPreviewEventFailure(val kind: PhotoPreviewEventFailureKind) : Exception(kind.name)

internal interface PhotoPreviewSocket {
    suspend fun send(text: String)
    suspend fun receive(): String
    fun close()
}

internal sealed interface PhotoPreviewPacket {
    data object Opened : PhotoPreviewPacket
    data object Connected : PhotoPreviewPacket
    data object Ping : PhotoPreviewPacket
    data object Ignored : PhotoPreviewPacket
    data class Completed(val unitId: Long, val success: Boolean) : PhotoPreviewPacket

    companion object {
        const val MAX_BYTES = 1_048_576
        fun decode(text: String): PhotoPreviewPacket {
            if (text.toByteArray(Charsets.UTF_8).size > MAX_BYTES) invalid()
            if (text == "2") return Ping
            if (text.startsWith("44")) throw PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.REJECTED)
            if (text == "1" || text.startsWith("41")) throw PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.DISCONNECTED)
            if (text.startsWith("0")) {
                val value = parse(text.drop(1)) as? JsonObject ?: invalid()
                if (value.string("sid").isNullOrEmpty() || (value.long("pingInterval") ?: 0) <= 0 ||
                    (value.long("pingTimeout") ?: 0) <= 0) invalid()
                return Opened
            }
            if (text == "40") return Connected
            if (text.startsWith("40")) {
                val value = parse(text.drop(2)) as? JsonObject ?: invalid()
                if (value.string("sid").isNullOrEmpty()) invalid()
                return Connected
            }
            if (!text.startsWith("42")) return Ignored
            val array = parse(text.drop(2)) as? JsonArray ?: invalid()
            val event = (array.firstOrNull() as? JsonPrimitive)?.takeIf { it.isString }?.content ?: invalid()
            if (event != "regenerate-preview") return Ignored
            if (array.size != 2) invalid()
            val value = ((array[1] as? JsonObject)?.get("data") as? JsonObject) ?: invalid()
            val id = value.long("idUnit")?.takeIf { it > 0 } ?: invalid()
            val success = (value["success"] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: invalid()
            return Completed(id, success)
        }

        fun registration(unitId: Long): String {
            if (unitId <= 0) throw PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.INVALID_STATE)
            return "42" + buildJsonArray {
                add("regenerate-preview")
                add(buildJsonObject { put("idUnit", unitId); put("operation", "register") })
            }
        }
        private fun parse(text: String): JsonElement = try { Json.parseToJsonElement(text) } catch (_: Exception) { invalid() }
        private fun JsonObject.string(key: String) = (get(key) as? JsonPrimitive)?.takeIf { it.isString }?.content
        private fun JsonObject.long(key: String) = (get(key) as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull
        private fun invalid(): Nothing = throw PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.INVALID_FRAME)
    }
}

/** 替身只替换收发；正式握手、心跳、重连与总时限仍由本类执行。 */
internal class SynologyPhotosPreviewEvents(
    private val connect: () -> PhotoPreviewSocket,
    private val timeoutMillis: Long = 600_000,
    private val subscriptionMillis: Long = 20_000,
    private val reconnectDelay: suspend (Long) -> Unit = { delay(it) },
) : SynologyPhotoPreviewEvents {
    private enum class Phase { IDLE, CONNECTING, SUBSCRIBED, WAITING, CLOSED }
    private val phase = AtomicReference(Phase.IDLE)
    @Volatile private var socket: PhotoPreviewSocket? = null
    private var unitId = 0L

    override suspend fun subscribe(unitId: Long) {
        if (unitId <= 0 || !phase.compareAndSet(Phase.IDLE, Phase.CONNECTING)) invalidState()
        this.unitId = unitId
        try {
            register(open(), unitId)
            currentCoroutineContext().ensureActive()
            if (!phase.compareAndSet(Phase.CONNECTING, Phase.SUBSCRIBED)) invalidState()
        } catch (error: Throwable) { close(); throw error }
    }

    override suspend fun completion(): Boolean {
        if (!phase.compareAndSet(Phase.SUBSCRIBED, Phase.WAITING)) invalidState()
        try {
            // 一个时限包含收取、重连延时与重新订阅，不因连接重建而延长。
            return withTimeout(timeoutMillis) {
                var attempts = 0
                var needsRegistration = false
                while (true) {
                    currentCoroutineContext().ensureActive()
                    if (phase.get() != Phase.WAITING) invalidState()
                    try {
                        val current = socket ?: invalidState()
                        if (needsRegistration) { register(current, unitId); needsRegistration = false }
                        val packet = PhotoPreviewPacket.decode(current.receive())
                        currentCoroutineContext().ensureActive()
                        if (phase.get() != Phase.WAITING) invalidState()
                        when (packet) {
                            is PhotoPreviewPacket.Completed -> if (packet.unitId == unitId) return@withTimeout packet.success
                            PhotoPreviewPacket.Ping -> current.send("3")
                            PhotoPreviewPacket.Opened, PhotoPreviewPacket.Connected -> throw PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.INVALID_FRAME)
                            PhotoPreviewPacket.Ignored -> Unit
                        }
                    } catch (error: PhotoPreviewEventFailure) {
                        currentCoroutineContext().ensureActive()
                        if (error.kind != PhotoPreviewEventFailureKind.DISCONNECTED || attempts >= 3 || phase.get() != Phase.WAITING) throw error
                        socket?.close()
                        attempts++
                        reconnectDelay(attempts * 1_000L)
                        currentCoroutineContext().ensureActive()
                        open(); needsRegistration = true
                    }
                }
                @Suppress("UNREACHABLE_CODE") false
            }
        } finally { close() }
    }

    private fun open(): PhotoPreviewSocket {
        if (phase.get() == Phase.CLOSED) invalidState()
        val current = connect()
        socket = current
        if (phase.get() == Phase.CLOSED) { current.close(); invalidState() }
        return current
    }

    private suspend fun register(current: PhotoPreviewSocket, unitId: Long) = withTimeout(minOf(timeoutMillis, subscriptionMillis)) {
        var opened = false
        while (true) {
            currentCoroutineContext().ensureActive()
            when (PhotoPreviewPacket.decode(current.receive())) {
                PhotoPreviewPacket.Opened -> {
                    if (opened) throw PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.INVALID_FRAME)
                    opened = true; current.send("40")
                }
                PhotoPreviewPacket.Connected -> {
                    if (!opened) throw PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.INVALID_FRAME)
                    current.send(PhotoPreviewPacket.registration(unitId)); return@withTimeout
                }
                PhotoPreviewPacket.Ping -> current.send("3")
                is PhotoPreviewPacket.Completed -> throw PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.INVALID_FRAME)
                PhotoPreviewPacket.Ignored -> Unit
            }
        }
    }

    override fun close() { phase.set(Phase.CLOSED); socket?.close() }
    private fun invalidState(): Nothing = throw PhotoPreviewEventFailure(PhotoPreviewEventFailureKind.INVALID_STATE)
}
