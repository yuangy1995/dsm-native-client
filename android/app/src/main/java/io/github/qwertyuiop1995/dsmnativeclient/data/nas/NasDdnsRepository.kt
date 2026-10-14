package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.DdnsMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.packageDigest
import java.util.Locale
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.*

internal const val DDNS_PROVIDER = "SYNO.Core.DDNS.Provider"
internal const val DDNS_RECORD = "SYNO.Core.DDNS.Record"
internal data class NasDdnsPlan(val operation: DdnsMutationOperation, val original: NasDdnsDirectory,
    val draft: NasDdnsDraft? = null, val target: NasDdnsRecord? = null) {
    val requiresAcceptance get() = operation in setOf(DdnsMutationOperation.TEST, DdnsMutationOperation.ADDRESS_REFRESH) ||
        operation == DdnsMutationOperation.SAVE && target != null && draft != null && ddnsCore(target) == ddnsCore(draft)
    override fun toString() = "NasDdnsPlan($operation)"
}
internal data class NasDdnsOutcome(val result: MutationResult, val current: NasDdnsDirectory?)
internal data class NasDdnsCheckpoint(val stage: NasServiceStage)

/** 四类动作分别提交一次；密码只留在当前调用，恢复只看原记录与接受事实。 */
internal class NasDdnsRepository(private val gateway: NasManagementGateway, private val supports: (String, Int) -> Boolean,
    private val reader: suspend () -> NasDdnsDirectory) {
    private val lock = Mutex()
    suspend fun load(): NasDdnsDirectory { capability(); return reader() }
    private fun capability() { if (!supports(DDNS_PROVIDER, 1) || !supports(DDNS_RECORD, 1))
        throw DsmFailure(null, "DDNS is unavailable", "Open DDNS settings in DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED) }
    fun plan(operation: DdnsMutationOperation, original: NasDdnsDirectory, draft: NasDdnsDraft? = null, target: NasDdnsRecord? = null): NasDdnsPlan {
        capability()
        val normalized = draft?.normalized()
        val found = normalized?.originalProviderId?.let { id -> original.records.singleOrNull { it.providerId == id } }
        when (operation) {
            DdnsMutationOperation.SAVE, DdnsMutationOperation.TEST -> {
                if (normalized == null || !isValidDdnsDraft(normalized)) invalid()
                if (original.providers.none { it.id == normalized.providerId } ||
                    normalized.originalProviderId?.let { it != normalized.providerId || found == null } == true ||
                    normalized.originalProviderId == null && original.records.any { it.providerId == normalized.providerId }) serviceConflict()
                if (operation == DdnsMutationOperation.SAVE && found != null && ddnsCore(found) == ddnsCore(normalized) && normalized.password.isEmpty()) serviceConflict()
            }
            DdnsMutationOperation.DELETE -> if (target == null || original.records.singleOrNull { it.providerId == target.providerId } != target) serviceConflict()
            DdnsMutationOperation.ADDRESS_REFRESH -> if (original.records.isEmpty()) serviceConflict()
        }
        return NasDdnsPlan(operation, original, normalized, if (operation == DdnsMutationOperation.DELETE) target else found)
    }
    suspend fun perform(plan: NasDdnsPlan, observer: suspend (NasDdnsCheckpoint) -> Unit): NasDdnsOutcome {
        if (!lock.tryLock()) serviceConflict()
        var stage = NasServiceStage.PREPARED; var accepted = false; var failure: Exception? = null; var cancelled = false
        suspend fun checkpoint(value: NasServiceStage) { observer(NasDdnsCheckpoint(value)); stage = value }
        try {
            if (plan(plan.operation, plan.original, plan.draft, plan.target) != plan) serviceConflict()
            val fresh = try {
                currentCoroutineContext().ensureActive(); gateway.requireWriteAccess()
                load().also { current ->
                    if (current.providers.map { it.id }.toSet() != plan.original.providers.map { it.id }.toSet()) serviceConflict()
                    when (plan.operation) {
                        DdnsMutationOperation.ADDRESS_REFRESH -> if (current.records.map { it.providerId }.toSet() != plan.original.records.map { it.providerId }.toSet()) serviceConflict()
                        else -> {
                            val id = plan.draft?.providerId ?: requireNotNull(plan.target).providerId
                            val actual = current.records.singleOrNull { it.providerId == id }
                            if (plan.target == null) { if (actual != null) serviceConflict() }
                            else if (actual == null || ddnsBaseline(actual) != ddnsBaseline(plan.target)) serviceConflict()
                        }
                    }
                }
            } catch (error: Exception) {
                checkpoint(NasServiceStage.CANCELLED)
                return NasDdnsOutcome(ddnsResult(plan.operation, stage, error, error is CancellationException), null)
            }
            var actual: NasDdnsDirectory? = fresh.takeIf { plan.operation == DdnsMutationOperation.TEST }
            checkpoint(NasServiceStage.SUBMITTED)
            try {
                currentCoroutineContext().ensureActive()
                val method = when (plan.operation) {
                    DdnsMutationOperation.TEST -> "test"; DdnsMutationOperation.SAVE -> if (plan.target == null) "create" else "set"
                    DdnsMutationOperation.DELETE -> "delete"; DdnsMutationOperation.ADDRESS_REFRESH -> "update_ip_address"
                }
                val fields = when (plan.operation) {
                    DdnsMutationOperation.TEST, DdnsMutationOperation.SAVE -> ddnsWriteFields(requireNotNull(plan.draft), fresh.records.singleOrNull { it.providerId == plan.draft.providerId })
                    DdnsMutationOperation.DELETE -> buildJsonObject { put("id", JsonArray(listOf(JsonPrimitive(requireNotNull(plan.target).providerId)))) }
                    DdnsMutationOperation.ADDRESS_REFRESH -> JsonObject(emptyMap())
                }
                gateway.call(DDNS_RECORD, method, 1, fields, write = true); accepted = true
            } catch (error: Exception) {
                failure = error; cancelled = error is CancellationException
                if (error.serviceTrustFailure()) throw error
                if (directoryExplicitRejection(error)) { checkpoint(NasServiceStage.REJECTED); return NasDdnsOutcome(ddnsResult(plan.operation, stage, error), null) }
            }
            if (accepted) checkpoint(NasServiceStage.ACCEPTED)
            if (!cancelled) {
                if (plan.operation == DdnsMutationOperation.TEST) {
                    if (accepted) checkpoint(NasServiceStage.VERIFIED)
                } else try {
                    val current = load(); actual = current
                    if ((!plan.requiresAcceptance || accepted) && when (plan.operation) {
                        DdnsMutationOperation.SAVE -> current.records.any { ddnsCore(it) == ddnsCore(requireNotNull(plan.draft)) }
                        DdnsMutationOperation.DELETE -> current.records.none { it.providerId == plan.target?.providerId }
                        DdnsMutationOperation.ADDRESS_REFRESH -> current.records.map { it.providerId }.toSet() == plan.original.records.map { it.providerId }.toSet()
                        else -> false
                    }) checkpoint(NasServiceStage.VERIFIED)
                } catch (error: Exception) { if (error.serviceTrustFailure()) throw error; failure = error; cancelled = error is CancellationException }
            }
            return NasDdnsOutcome(ddnsResult(plan.operation, stage, failure, cancelled), actual)
        } finally { lock.unlock() }
    }
    private fun invalid(): Nothing = throw DsmFailure(null, "DDNS fields are invalid", "Check the hostname, account and password.", kind = DsmErrorKind.NAS_DDNS_INVALID)
}

internal fun ddnsCore(value: NasDdnsRecord) = ddnsCore(NasDdnsDraft(providerId = value.providerId, hostname = value.hostname,
    username = value.username, isEnabled = value.isEnabled, heartbeat = value.heartbeat))
internal fun ddnsCore(value: NasDdnsDraft) = buildJsonObject {
    put("provider", value.providerId); put("hostname", value.hostname.lowercase(Locale.ROOT)); put("username", value.username)
    put("enable", value.isEnabled); put("heartbeat", value.heartbeat)
}
internal fun ddnsBaseline(value: NasDdnsRecord) = buildJsonObject {
    ddnsCore(value).forEach { (key, v) -> put(key, v) }
    if ("net" in value.knownNetworkFields) put("net", value.networkType)
    if ("interface_v4" in value.knownNetworkFields) put("interface_v4", value.interfaceV4)
    if ("interface_v6" in value.knownNetworkFields) put("interface_v6", value.interfaceV6)
}
internal fun ddnsWriteFields(draft: NasDdnsDraft, fresh: NasDdnsRecord?) = buildJsonObject {
    ddnsCore(draft).forEach { (key, value) -> put(key, value) }
    if (draft.password.isNotEmpty()) put("passwd", draft.password)
    val known = fresh?.knownNetworkFields ?: setOf("net", "ip", "ipv6", "interface_v4", "interface_v6")
    if ("net" in known) put("net", fresh?.networkType ?: draft.networkType)
    if ("ip" in known) put("ip", fresh?.ipv4 ?: draft.ipv4)
    if ("ipv6" in known) put("ipv6", fresh?.ipv6 ?: draft.ipv6)
    if ("interface_v4" in known) put("interface_v4", fresh?.interfaceV4 ?: draft.interfaceV4)
    if ("interface_v6" in known) put("interface_v6", fresh?.interfaceV6 ?: draft.interfaceV6)
}
internal fun ddnsDigest(value: JsonObject) = packageDigest(JsonObject(value.toSortedMap()).toString())
internal fun ddnsProviderSet(directory: NasDdnsDirectory) = packageDigest(JsonArray(directory.records.map { it.providerId }.sorted().map(::JsonPrimitive)).toString())
internal fun ddnsResult(operation: DdnsMutationOperation, stage: NasServiceStage, failure: Exception? = null, cancelled: Boolean = false): MutationResult =
    serviceResult(NasServiceKind.PROXY, listOf(stage), failure, cancelled).copy(operation = when (operation) {
        DdnsMutationOperation.TEST -> "ddnsProviderTest"; DdnsMutationOperation.SAVE -> "ddnsRecordSave"
        DdnsMutationOperation.DELETE -> "ddnsRecordDelete"; DdnsMutationOperation.ADDRESS_REFRESH -> "ddnsAddressRefresh"
    })
