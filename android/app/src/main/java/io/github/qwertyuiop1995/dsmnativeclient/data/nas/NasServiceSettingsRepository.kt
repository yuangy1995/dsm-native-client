package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.packageDigest
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.serialization.json.*

internal data class NasServicePlan(val original: NasServiceValue, val desired: NasServiceValue, val steps: List<NasServiceStep>, val continuation: NasServiceStep? = null)

/** 服务保存的实际请求入口：原快照、逐组检查点、单次传输与整体回读。 */
internal class NasServiceSettingsRepository(private val gateway: NasManagementGateway,
    private val supports: (String, Int) -> Boolean,
    private val remoteContext: suspend () -> Pair<Boolean, Boolean> = { false to false },
    private val ethernetReader: suspend (String) -> NasEthernetInterface = { serviceUnsupported() },
    private val securityReader: suspend () -> NasSecuritySettings = { serviceUnsupported() },
    private val hardwareReader: suspend () -> NasHardwareSettings = { serviceUnsupported() },
    private val taskDelay: suspend () -> Unit = { delay(1_000) }) {
    private val lock = Mutex()
    private fun version(step: NasServiceStep): Int? = when (step) {
        NasServiceStep.SMB, NasServiceStep.NFS, NasServiceStep.TERMINAL -> (3 downTo 1).firstOrNull { supports(step.api, it) }
        NasServiceStep.WEB_DISCOVERY, NasServiceStep.DOS -> 2.takeIf { supports(step.api, it) }
        NasServiceStep.RELAY -> 3.takeIf { supports(step.api, it) }
        else -> 1.takeIf { supports(step.api, it) }
    }
    private suspend fun read(step: NasServiceStep): JsonObject? = version(step)?.let {
        gateway.call(step.api, when (step) { NasServiceStep.RELAY -> "get_misc_config"; NasServiceStep.POWER_SCHEDULE -> "load"; else -> "get" }, it)
    }
    suspend fun load(kind: NasServiceKind, targetId: String? = null): NasServiceValue = when (kind) {
        NasServiceKind.MEMORY_COMPRESSION -> NasServiceValue.MemoryCompression(readMemoryCompression(::read))
        NasServiceKind.POWER_SCHEDULE -> NasServiceValue.PowerSchedule(readPowerSchedule(read(NasServiceStep.POWER_SCHEDULE) ?: serviceUnsupported()))
        NasServiceKind.HARDWARE -> NasServiceValue.Hardware(hardwareReader())
        NasServiceKind.SECURITY -> NasServiceValue.Security(securityReader().also { if (!it.validSecurity()) serviceInvalid() })
        NasServiceKind.ETHERNET -> {
            if (!supports(NasServiceStep.ETHERNET.api, 1) || !supports(NasServiceStep.ETHERNET.api, 2)) serviceUnsupported()
            val id = targetId?.takeIf(::isSafeEthernetId) ?: serviceInvalid()
            val value = ethernetReader(id)
            if (value.id != id || !isValidEthernetInterface(value)) serviceInvalid()
            NasServiceValue.Ethernet(value)
        }
        NasServiceKind.FILES -> {
            val smb = read(NasServiceStep.SMB); val nfs = read(NasServiceStep.NFS); val ftp = read(NasServiceStep.FTP)
            val sftp = read(NasServiceStep.SFTP); val web = read(NasServiceStep.WEB_DISCOVERY); val discovery = read(NasServiceStep.TIME_MACHINE)
            if (listOf(smb, nfs, ftp, sftp, web, discovery).all { it == null }) serviceUnsupported()
            NasServiceValue.Files(NasFileServiceSettings(smb.serviceBoolean("enable_samba"), nfs.serviceBoolean("enable_nfs"),
                ftp.serviceBoolean("enable_ftp"), ftp.serviceBoolean("enable_ftps"), ftp.servicePort("portnum"),
                sftp.serviceBoolean("enable"), sftp.servicePort("portnum", "sftp_portnum"), web.serviceBoolean("enable_ssdp"),
                web.serviceBoolean("enable_avahi"), discovery.serviceBoolean("enable_smb_time_machine")))
        }
        NasServiceKind.TERMINAL -> {
            val data = read(NasServiceStep.TERMINAL) ?: serviceUnsupported()
            NasServiceValue.Terminal(NasTerminalSettings(data.serviceBoolean("enable_ssh") ?: serviceInvalid(),
                data.serviceBoolean("enable_telnet") ?: serviceInvalid(), data.servicePort("ssh_port")))
        }
        NasServiceKind.PROXY -> {
            val data = read(NasServiceStep.PROXY) ?: serviceUnsupported()
            val host = data["http_host"]?.takeUnless { it is JsonNull }?.let {
                (it as? JsonPrimitive)?.takeIf { it.isString }?.content ?: serviceInvalid()
            }.orEmpty()
            val settings = NasProxySettings(data.serviceBoolean("enable") ?: serviceInvalid(), host, data.servicePort("http_port"))
            if (settings.isEnabled && !settings.valid()) serviceInvalid()
            NasServiceValue.Proxy(settings)
        }
        NasServiceKind.REMOTE_ACCESS -> {
            suspend fun field(step: NasServiceStep, key: String): Result<Boolean> = try {
                val data = read(step) ?: serviceUnsupported()
                Result.success((data[key] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: serviceInvalid())
            } catch (error: Exception) {
                if (error is CancellationException || error.serviceTrustFailure() || error is DsmFailure &&
                    error.kind in setOf(DsmErrorKind.AUTHENTICATION_FAILED, DsmErrorKind.SESSION_EXPIRED)) throw error
                Result.failure(error)
            }
            val relay = field(NasServiceStep.RELAY, "relay_enabled"); val router = field(NasServiceStep.ROUTER, "enabled")
            if (relay.isFailure && router.isFailure) throw requireNotNull(relay.exceptionOrNull())
            val (trustedRelay, manageable) = remoteContext()
            NasServiceValue.RemoteAccess(NasRemoteAccessSettings(relay.getOrNull(), router.getOrNull(), trustedRelay, manageable))
        }
    }
    fun plan(original: NasServiceValue, desired: NasServiceValue, continuation: NasServiceStep? = null): NasServicePlan {
        if (original.kind != desired.kind) serviceConflict()
        val normalized = if (desired is NasServiceValue.Proxy && original is NasServiceValue.Proxy) {
            desired.copy(settings = if (desired.settings.isEnabled) desired.settings.copy(host = desired.settings.host.trim())
                else desired.settings.copy(host = original.settings.host, port = original.settings.port))
        } else if (desired is NasServiceValue.MemoryCompression) desired.copy(settings = desired.settings.copy(rebootRequired = true))
        else if (desired is NasServiceValue.Hardware) desired.copy(settings = normalizeHardwareSettings(desired.settings))
        else if (desired is NasServiceValue.Ethernet) desired.copy(settings = desired.settings.normalizedEthernetInput()) else desired
        if (original is NasServiceValue.Ethernet && normalized is NasServiceValue.Ethernet) {
            if (original.settings.id != normalized.settings.id || !isValidEthernetInterface(original.settings)) serviceConflict()
            if (!supports(NasServiceStep.ETHERNET.api, 2)) serviceUnsupported()
        }
        if (original is NasServiceValue.RemoteAccess && normalized is NasServiceValue.RemoteAccess) {
            if (original.settings.isConnectedThroughTrustedRelay != normalized.settings.isConnectedThroughTrustedRelay ||
                original.settings.canManage != normalized.settings.canManage) serviceConflict()
            requireRemoteChange(original, normalized)
        }
        if (original is NasServiceValue.Security && normalized is NasServiceValue.Security) {
            if (original.settings.firewallProfileName != normalized.settings.firewallProfileName ||
                original.settings.dosProtection.map { it.id }.toSet() != normalized.settings.dosProtection.map { it.id }.toSet()) serviceConflict()
            if (original.settings.isFirewallEnabled != true && normalized.settings.isFirewallEnabled == true &&
                (original.settings.firewallProfileName.isNullOrBlank() || !supports(firewallApplyApi, 1))) serviceUnsupported()
            if (original.settings.dosProtection != normalized.settings.dosProtection && !supports(NasServiceStep.ETHERNET.api, 2)) serviceUnsupported()
        }
        if (original is NasServiceValue.Hardware && normalized is NasServiceValue.Hardware) {
            val before = original.settings; val after = normalized.settings
            if (before.ledBrightnessMinimum != after.ledBrightnessMinimum || before.ledBrightnessMaximum != after.ledBrightnessMaximum ||
                before.supportedFanModes != after.supportedFanModes || before.beepVolumeFieldName != after.beepVolumeFieldName) serviceConflict()
            if (!isValidHardwareSettings(after, before) || before.fanMode != after.fanMode && before.supportedFanModes?.contains(after.fanMode) != true) serviceValidation()
        }
        if (original is NasServiceValue.MemoryCompression && normalized is NasServiceValue.MemoryCompression) {
            if (!original.settings.editable || original.settings.algorithm != normalized.settings.algorithm ||
                original.settings.configuredBytes != normalized.settings.configuredBytes) serviceConflict()
            if (continuation == null && original.settings.enabled == normalized.settings.enabled) serviceConflict()
        }
        if (original is NasServiceValue.PowerSchedule && normalized is NasServiceValue.PowerSchedule &&
            (!original.settings.editable || original.settings.timezone != normalized.settings.timezone)) serviceConflict()
        if (!normalized.valid()) serviceValidation()
        val before = original.groups(); val after = normalized.groups()
        if (before.keys != after.keys) serviceConflict()
        for (step in before.keys) {
            // 停用代理只改变开关，地址和端口继续由 DSM 保留。
            if (step !in setOf(NasServiceStep.PROXY, NasServiceStep.ETHERNET) && before.getValue(step).keys != after.getValue(step).keys) serviceConflict()
        }
        val remaining = before.keys.filter { before[it] != after[it] }.toMutableList()
        if (original is NasServiceValue.MemoryCompression && continuation == null && NasServiceStep.REBOOT_REQUIRED !in remaining) remaining += NasServiceStep.REBOOT_REQUIRED
        if (continuation != null) {
            when (continuation) {
                NasServiceStep.LED_UPDATE -> if (original !is NasServiceValue.Hardware || normalized != original || original.settings.ledBrightness == null ||
                    original.settings.ledBrightnessMinimum == null || original.settings.ledBrightnessMaximum == null) serviceConflict()
                NasServiceStep.REBOOT_REQUIRED -> if (original !is NasServiceValue.MemoryCompression ||
                    (normalized as? NasServiceValue.MemoryCompression)?.settings != original.settings.copy(rebootRequired = true)) serviceConflict()
                else -> serviceConflict()
            }
            remaining.clear(); remaining += continuation
        }
        if (remaining.isEmpty()) serviceConflict()
        if (remaining.any { version(it) == null }) serviceUnsupported()
        val ordered = mutableListOf<NasServiceStep>(); val intermediate = before.toMutableMap()
        while (remaining.isNotEmpty()) {
            val next = remaining.firstOrNull { step -> (intermediate + (step to after.getValue(step))).validFileGroups() } ?: serviceValidation()
            ordered += next; remaining.remove(next); intermediate[next] = after.getValue(next)
        }
        return NasServicePlan(original, normalized, ordered, continuation)
    }
    suspend fun save(plan: NasServicePlan, observer: NasServiceObserver): MutationResult {
        if (!lock.tryLock()) serviceConflict()
        val stages = plan.steps.associateWith { NasServiceStage.PREPARED }.toMutableMap()
        var expected = plan.original.groups(); val desired = plan.desired.groups()
        var failure: Exception? = null; var cancelled = false
        val taskRequired = plan.requiresFirewallTask
        var task: NasFirewallTask? = null
        var taskReady = false
        val acceptedSteps = mutableSetOf<NasServiceStep>()
        suspend fun checkpoint(step: NasServiceStep, stage: NasServiceStage) {
            observer(NasServiceCheckpoint(step, stage)); stages[step] = stage
            if (stage == NasServiceStage.ACCEPTED) acceptedSteps += step
        }
        try {
            // 在所有检查点之前验证计划，避免外部构造绕过完整预检。
            if (plan(plan.original, plan.desired, plan.continuation) != plan) serviceConflict()
            for (step in plan.steps) {
                try {
                    currentCoroutineContext().ensureActive()
                    gateway.requireWriteAccess()
                    val current = load(plan.original.kind, (plan.original as? NasServiceValue.Ethernet)?.settings?.id)
                    val actual = current.groups()
                    if (current is NasServiceValue.MemoryCompression) {
                        if (!current.settings.editable || actual[NasServiceStep.ZRAM] != expected[NasServiceStep.ZRAM]) serviceConflict()
                    } else if (actual != expected) serviceConflict()
                    if (current is NasServiceValue.RemoteAccess && plan.desired is NasServiceValue.RemoteAccess) requireRemoteChange(current, plan.desired)
                } catch (error: Exception) { failure = error; cancelled = error is CancellationException; break }
                checkpoint(step, NasServiceStage.SUBMITTED)
                var accepted = false
                if (step == NasServiceStep.FIREWALL && taskRequired) {
                    val started = try {
                        currentCoroutineContext().ensureActive()
                        gateway.call(firewallApplyApi, "start", 1, serviceSavedGroup(step, desired.getValue(step)), write = true)
                    } catch (error: Exception) {
                        if (error.serviceTrustFailure()) throw error
                        failure = error; cancelled = error is CancellationException
                        if (error.serviceExplicitRejection()) checkpoint(step, NasServiceStage.REJECTED)
                        null
                    }
                    if (started == null) break
                    try {
                        val id = (started["task_id"] as? JsonPrimitive)?.takeIf { it.isString }?.content?.takeIf { it.isNotBlank() } ?: serviceInvalid()
                        suspend fun remember(value: NasFirewallTask) {
                            observer(NasServiceCheckpoint(step, NasServiceStage.ACCEPTED, value))
                            task = value; stages[step] = NasServiceStage.ACCEPTED
                        }
                        remember(NasFirewallTask(id))
                        for (attempt in 0 until 30) {
                            if (attempt > 0) taskDelay()
                            val outcome = firewallTaskStatus(id)
                            if (outcome != null) { remember(requireNotNull(task).copy(outcome = outcome)); break }
                        }
                        if (task?.outcome == null) break
                        currentCoroutineContext().ensureActive(); gateway.requireWriteAccess()
                        remember(requireNotNull(task).copy(cleanupAttempted = true))
                        currentCoroutineContext().ensureActive()
                        gateway.call(firewallApplyApi, "stop", 1, write = true)
                        remember(requireNotNull(task).copy(cleanupAccepted = true))
                        if (task?.outcome == false) { checkpoint(step, NasServiceStage.REJECTED); break }
                        taskReady = true; accepted = true
                    } catch (error: Exception) {
                        if (error.serviceTrustFailure() || error is DsmFailure && error.kind == DsmErrorKind.LOCAL_STORAGE_FAILED) throw error
                        failure = error; cancelled = error is CancellationException
                        if (task?.outcome == false) checkpoint(step, NasServiceStage.REJECTED)
                        break
                    }
                } else try {
                    currentCoroutineContext().ensureActive()
                    gateway.call(step.api, step.saveMethod,
                        version(step) ?: serviceUnsupported(), serviceWriteParameters(step, desired.getValue(step), expected.getValue(step)), write = true)
                    accepted = true
                } catch (error: Exception) {
                    failure = error; cancelled = error is CancellationException
                    if (error.serviceTrustFailure()) throw error
                    if (error.serviceExplicitRejection()) { checkpoint(step, NasServiceStage.REJECTED); break }
                }
                // 记录失败直接中止，不能吞掉并继续下一组写请求。
                if (accepted && !(step == NasServiceStep.FIREWALL && taskRequired)) checkpoint(step, NasServiceStage.ACCEPTED)
                if (cancelled) break
                val actual = try { load(plan.original.kind, (plan.original as? NasServiceValue.Ethernet)?.settings?.id).groups() } catch (error: Exception) {
                    if (error.serviceTrustFailure()) throw error
                    failure = error; break
                }
                if (step.requiresAcceptance && !accepted || !serviceGroupMatches(step, desired.getValue(step), actual[step])) break
                checkpoint(step, NasServiceStage.VERIFIED)
                expected = expected + (step to actual.getValue(step))
                // 设置亮度会更新暂存值；应用步骤仍未提交，必须单独取得接受回执。
                if (step == NasServiceStep.LED_BRIGHTNESS) expected = expected + (NasServiceStep.LED_UPDATE to actual.getValue(NasServiceStep.LED_UPDATE))
                if (step == NasServiceStep.ZRAM) expected = expected + (NasServiceStep.REBOOT_REQUIRED to actual.getValue(NasServiceStep.REBOOT_REQUIRED))
                // 回执丢失后即使已读到目标，也结束本次写链，后组不自动补交。
                if (!accepted || actual != expected) break
            }
            for ((step, stage) in stages.toMap()) if (stage == NasServiceStage.PREPARED) checkpoint(step, NasServiceStage.CANCELLED)
            // 最终读取覆盖全部已提交组；后续操作不能使先前成功证据失效而仍报告完整成功。
            if (!cancelled && stages.values.any { it in submittedStages }) {
                val actual = try { load(plan.original.kind, (plan.original as? NasServiceValue.Ethernet)?.settings?.id).groups() } catch (error: Exception) {
                    if (error.serviceTrustFailure()) throw error
                    failure = error; null
                }
                if (actual != null) for (step in plan.steps) {
                    if (stages[step] in setOf(NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED, NasServiceStage.VERIFIED)) {
                        val stage = if ((!step.requiresAcceptance || step in acceptedSteps) && (step != NasServiceStep.FIREWALL || !taskRequired || taskReady) && serviceGroupMatches(step, desired.getValue(step), actual[step])) NasServiceStage.VERIFIED else NasServiceStage.SUBMITTED
                        if (stages[step] != stage) checkpoint(step, stage)
                    }
                } else for (step in plan.steps) if (stages[step] == NasServiceStage.VERIFIED) checkpoint(step, NasServiceStage.SUBMITTED)
            }
            return serviceResult(plan.original.kind, stages.values, failure, cancelled)
        } finally { lock.unlock() }
    }
    /** 恢复入口只读原任务；没有全局清理或重新提交。 */
    suspend fun firewallTaskStatus(id: String): Boolean? {
        if (!supports(firewallApplyApi, 1)) serviceUnsupported()
        if (id.isBlank()) serviceInvalid()
        val value = gateway.call(firewallApplyApi, "status", 1, mapOf("task_id" to JsonPrimitive(id)))["success"] ?: return null
        return (value as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: serviceInvalid()
    }
}

internal const val firewallApplyApi = "SYNO.Core.Security.Firewall.Profile.Apply"
internal val NasServicePlan.requiresFirewallTask get() = NasServiceStep.FIREWALL in steps && (desired as? NasServiceValue.Security)?.settings?.isFirewallEnabled == true
internal val NasServiceStep.api: String get() = when (this) {
    NasServiceStep.SMB -> "SYNO.Core.FileServ.SMB"
    NasServiceStep.NFS -> "SYNO.Core.FileServ.NFS"
    NasServiceStep.FTP -> "SYNO.Core.FileServ.FTP"
    NasServiceStep.SFTP -> "SYNO.Core.FileServ.FTP.SFTP"
    NasServiceStep.WEB_DISCOVERY -> "SYNO.Core.Web.DSM"
    NasServiceStep.TIME_MACHINE -> "SYNO.Core.FileServ.ServiceDiscovery"
    NasServiceStep.TERMINAL -> "SYNO.Core.Terminal"
    NasServiceStep.PROXY -> "SYNO.Core.Network.Proxy"
    NasServiceStep.RELAY -> "SYNO.Core.QuickConnect"
    NasServiceStep.ROUTER -> "SYNO.Core.QuickConnect.Upnp"
    NasServiceStep.ETHERNET -> "SYNO.Core.Network.Ethernet"
    NasServiceStep.AUTO_BLOCK -> "SYNO.Core.Security.AutoBlock"
    NasServiceStep.DOS -> "SYNO.Core.Security.DoS"
    NasServiceStep.FIREWALL_NOTIFICATIONS -> "SYNO.Core.Security.Firewall.Conf"
    NasServiceStep.FIREWALL -> "SYNO.Core.Security.Firewall"
    NasServiceStep.POWER_RECOVERY -> "SYNO.Core.Hardware.PowerRecovery"
    NasServiceStep.LED_BRIGHTNESS, NasServiceStep.LED_UPDATE -> "SYNO.Core.Hardware.Led.Brightness"
    NasServiceStep.FAN -> "SYNO.Core.Hardware.FanSpeed"
    NasServiceStep.BEEP -> "SYNO.Core.Hardware.BeepControl"
    NasServiceStep.HIBERNATION -> "SYNO.Core.Hardware.Hibernation"
    NasServiceStep.UPS -> "SYNO.Core.ExternalDevice.UPS"
    NasServiceStep.ZRAM -> "SYNO.Core.Hardware.ZRAM"
    NasServiceStep.REBOOT_REQUIRED -> "SYNO.Core.Hardware.NeedReboot"
    NasServiceStep.POWER_SCHEDULE -> "SYNO.Core.Hardware.PowerSchedule"
}
internal fun NasServiceValue.groups(): Map<NasServiceStep, JsonObject> = buildMap {
    fun group(step: NasServiceStep, vararg fields: Pair<String, Any?>) {
        val value = buildJsonObject { fields.forEach { (key, value) -> when (value) {
            is Boolean -> put(key, value); is Int -> put(key, value); is String -> put(key, value); null -> Unit; else -> serviceInvalid()
        } } }; if (value.isNotEmpty()) put(step, value)
    }
    when (val value = this@groups) {
        is NasServiceValue.Files -> with(value.settings) {
            group(NasServiceStep.SMB, "enable_samba" to isSmbEnabled); group(NasServiceStep.NFS, "enable_nfs" to isNfsEnabled)
            group(NasServiceStep.FTP, "enable_ftp" to isFtpEnabled, "enable_ftps" to isFtpsEnabled, "portnum" to ftpPort)
            group(NasServiceStep.SFTP, "enable" to isSftpEnabled, "portnum" to sftpPort)
            group(NasServiceStep.WEB_DISCOVERY, "enable_ssdp" to isSsdpEnabled, "enable_avahi" to isBonjourEnabled)
            group(NasServiceStep.TIME_MACHINE, "enable_smb_time_machine" to isSmbTimeMachineEnabled)
        }
        is NasServiceValue.Terminal -> with(value.settings) { group(NasServiceStep.TERMINAL,
            "enable_ssh" to isSshEnabled, "enable_telnet" to isTelnetEnabled, "ssh_port" to sshPort) }
        is NasServiceValue.Proxy -> with(value.settings) { group(NasServiceStep.PROXY, "enable" to isEnabled,
            "http_host" to host, "http_port" to port) }
        is NasServiceValue.MemoryCompression -> putAll(value.settings.memoryGroups())
        is NasServiceValue.PowerSchedule -> put(NasServiceStep.POWER_SCHEDULE, value.settings.powerScheduleGroup())
        is NasServiceValue.Hardware -> putAll(value.settings.hardwareGroups())
        is NasServiceValue.Security -> with(value.settings) {
            group(NasServiceStep.AUTO_BLOCK, "enable" to isAutoBlockEnabled, "attempts" to failedAttempts, "within_mins" to withinMinutes, "expire_day" to (expirationDays ?: 0))
            if (dosProtection.isNotEmpty()) put(NasServiceStep.DOS, buildJsonObject { put("configs", JsonArray(dosProtection.sortedBy { it.id }.map { row ->
                buildJsonObject { put("adapter", row.id); put("dos_protect_enable", row.isEnabled) }
            })) })
            group(NasServiceStep.FIREWALL_NOTIFICATIONS, "enable_port_check" to isPortScanProtectionEnabled)
            if (isFirewallEnabled != null) group(NasServiceStep.FIREWALL, "enable_firewall" to isFirewallEnabled, "profile_name" to firewallProfileName)
        }
        is NasServiceValue.Ethernet -> put(NasServiceStep.ETHERNET, ethernetConfiguration(value.settings).single().jsonObject)
        is NasServiceValue.RemoteAccess -> with(value.settings) {
            group(NasServiceStep.RELAY, "relay_enabled" to isRelayEnabled); group(NasServiceStep.ROUTER, "enabled" to isRouterConfigurationEnabled)
        }
    }
}
private fun NasServiceValue.valid(): Boolean = when (this) {
    is NasServiceValue.Files -> groups().validFileGroups() && listOf(settings.ftpPort, settings.sftpPort).all { it == null || it in 1..65535 }
    is NasServiceValue.Terminal -> settings.sshPort == null || settings.sshPort in 1..65535
    is NasServiceValue.Proxy -> settings.valid()
    is NasServiceValue.RemoteAccess -> true
    is NasServiceValue.MemoryCompression -> settings.editable
    is NasServiceValue.PowerSchedule -> settings.validSchedule()
    is NasServiceValue.Hardware -> isValidHardwareSettings(settings, settings)
    is NasServiceValue.Security -> settings.validSecurity()
    is NasServiceValue.Ethernet -> isValidEthernetInterface(settings)
}
private fun requireRemoteChange(original: NasServiceValue.RemoteAccess, desired: NasServiceValue.RemoteAccess) {
    if (!original.settings.canManage) serviceUnsupported()
    if (original.settings.isConnectedThroughTrustedRelay && original.settings.isRelayEnabled == true && desired.settings.isRelayEnabled == false)
        throw DsmFailure(null, "The current connection needs the relay", "Connect directly before turning off the relay.", kind = DsmErrorKind.NAS_RELAY_PROTECTED)
}
private fun NasProxySettings.valid() = !isEnabled || port in 1..65535 && host.isNotBlank() &&
    host.none { it.isWhitespace() || it.isISOControl() || it in "/?#@" } && !host.contains("://")
private fun Map<NasServiceStep, JsonObject>.validFileGroups(): Boolean {
    if (get(NasServiceStep.SMB)?.serviceBoolean("enable_samba") == false && get(NasServiceStep.TIME_MACHINE)?.serviceBoolean("enable_smb_time_machine") == true) return false
    val ftp = get(NasServiceStep.FTP); val sftp = get(NasServiceStep.SFTP)
    val ftpOn = ftp?.serviceBoolean("enable_ftp") == true || ftp?.serviceBoolean("enable_ftps") == true
    return !(ftpOn && sftp?.serviceBoolean("enable") == true && ftp?.get("portnum") != null && ftp["portnum"] == sftp["portnum"])
}
internal fun serviceGroupMatches(step: NasServiceStep, expected: JsonObject, actual: JsonObject?): Boolean =
    if (step == NasServiceStep.PROXY && expected.serviceBoolean("enable") == false) actual?.serviceBoolean("enable") == false else actual == expected
internal fun serviceSavedGroup(step: NasServiceStep, value: JsonObject) =
    if (step == NasServiceStep.FIREWALL) buildJsonObject {
        if (value.serviceBoolean("enable_firewall") == true) { put("name", value.getValue("profile_name")); put("profile_applying", false) }
        else put("set_type", "disable")
    } else if (step == NasServiceStep.PROXY && value.serviceBoolean("enable") == false) JsonObject(value.filterKeys { it == "enable" }) else if (step == NasServiceStep.ETHERNET) buildJsonObject { put("configs", JsonArray(listOf(value))) } else value
internal fun serviceDigest(step: NasServiceStep, value: JsonObject) = packageDigest(JsonObject((if (step == NasServiceStep.FIREWALL || step in hardwareSteps) value else serviceSavedGroup(step, value)).toSortedMap()).toString())
private fun JsonObject?.serviceBoolean(key: String): Boolean? {
    val value = this?.get(key)?.takeUnless { it is JsonNull } ?: return null
    val text = (value as? JsonPrimitive)?.content?.lowercase() ?: serviceInvalid()
    return when (text) { "true", "yes", "1", "enabled" -> true; "false", "no", "0", "disabled" -> false; else -> serviceInvalid() }
}
private fun JsonObject?.servicePort(vararg keys: String): Int? {
    for (key in keys) {
        val value = this?.get(key)?.takeUnless { it is JsonNull } ?: continue
        val number = (value as? JsonPrimitive)?.content?.toDoubleOrNull() ?: serviceInvalid()
        if (!number.isFinite() || number % 1 != 0.0 || number !in 1.0..65535.0) serviceInvalid()
        return number.toInt()
    }; return null
}
internal val submittedStages = setOf(NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED, NasServiceStage.VERIFIED, NasServiceStage.REJECTED)
internal fun serviceResult(kind: NasServiceKind, stages: Collection<NasServiceStage>, error: Exception? = null, cancelled: Boolean = false): MutationResult {
    val success = stages.count { it == NasServiceStage.VERIFIED }; val unknown = stages.count { it in setOf(NasServiceStage.SUBMITTED, NasServiceStage.ACCEPTED) }
    val submitted = stages.any { it in submittedStages }
    val category = when ((error as? DsmFailure)?.kind) {
        DsmErrorKind.PERMISSION_DENIED -> MutationErrorCategory.PERMISSION
        DsmErrorKind.AUTHENTICATION_FAILED, DsmErrorKind.SESSION_EXPIRED -> MutationErrorCategory.AUTHENTICATION
        DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED -> MutationErrorCategory.UNSUPPORTED
        DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.INVALID_RESPONSE -> MutationErrorCategory.NETWORK
        DsmErrorKind.NAS_SERVICE_CHANGED -> MutationErrorCategory.CONFLICT
        DsmErrorKind.NAS_RELAY_PROTECTED -> MutationErrorCategory.CONFLICT
        DsmErrorKind.NAS_SERVICE_INVALID, DsmErrorKind.NAS_DDNS_INVALID -> MutationErrorCategory.VALIDATION
        else -> if (error != null) MutationErrorCategory.UNKNOWN else null
    }
    val status = when {
        cancelled -> if (submitted) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION else MutationResultStatus.CANCELLED_BEFORE_SUBMISSION
        success == stages.size && success > 0 -> MutationResultStatus.CONFIRMED_SUCCESS
        success > 0 -> MutationResultStatus.PARTIAL_SUCCESS
        unknown > 0 -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
        category == MutationErrorCategory.PERMISSION || category == MutationErrorCategory.AUTHENTICATION -> MutationResultStatus.PERMISSION_DENIED
        category == MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
        else -> MutationResultStatus.CONFIRMED_FAILURE
    }
    return MutationResult(1, status, when (kind) { NasServiceKind.FILES -> "fileServiceSettingsUpdate"; NasServiceKind.TERMINAL -> "terminalSettingsUpdate"; NasServiceKind.PROXY -> "proxySettingsUpdate"; NasServiceKind.REMOTE_ACCESS -> "remoteAccessSettingsUpdate"; NasServiceKind.ETHERNET -> "ethernetSettingsUpdate"; NasServiceKind.SECURITY -> "securitySettingsUpdate"; NasServiceKind.HARDWARE -> "hardwareSettingsUpdate"; NasServiceKind.MEMORY_COMPRESSION -> "zramSettingsUpdate"; NasServiceKind.POWER_SCHEDULE -> "powerScheduleUpdate" },
        submitted, unknown > 0 || cancelled && submitted,
        MutationResultCounts(success, if (cancelled && !submitted) 0 else stages.size - success - unknown, unknown), category)
}
internal fun Exception.serviceTrustFailure() = this is DsmFailure && kind in setOf(DsmErrorKind.TLS_UNTRUSTED, DsmErrorKind.QUICK_CONNECT_IDENTITY_MISMATCH, DsmErrorKind.WORKSPACE_CHANGED)
private fun Exception.serviceExplicitRejection() = directoryExplicitRejection(this)
internal fun serviceInvalid(): Nothing = throw DsmFailure(null, "Service settings are incomplete", "Refresh settings and try again.", kind = DsmErrorKind.INVALID_RESPONSE)
internal fun serviceConflict(): Nothing = throw DsmFailure(null, "Service settings changed", "Refresh settings and try again.", kind = DsmErrorKind.NAS_SERVICE_CHANGED)
private fun serviceValidation(): Nothing = throw DsmFailure(null, "Service settings are invalid", "Check the service ports and dependencies.", kind = DsmErrorKind.NAS_SERVICE_INVALID)
private fun serviceUnsupported(): Nothing = throw DsmFailure(null, "Service settings are unavailable", "Open these settings in DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)

private fun NasSecuritySettings.validSecurity(): Boolean = failedAttempts in 1..9_999 && withinMinutes in 1..9_999_999 &&
    (expirationDays == null || expirationDays in 1..999) && dosProtection.map { it.id }.distinct().size == dosProtection.size &&
    dosProtection.all { row -> row.id.isNotEmpty() && row.id.all { it.isLetterOrDigit() || it == '_' || it == '-' } }

internal val NasServiceStep.requiresAcceptance get() = this in setOf(NasServiceStep.LED_BRIGHTNESS, NasServiceStep.LED_UPDATE, NasServiceStep.ZRAM, NasServiceStep.REBOOT_REQUIRED)
private val NasServiceStep.saveMethod get() = when (this) {
    NasServiceStep.RELAY -> "set_misc_config"
    NasServiceStep.LED_BRIGHTNESS -> "set_current_brightness"
    NasServiceStep.LED_UPDATE -> "update"
    NasServiceStep.POWER_SCHEDULE -> "save"
    else -> "set"
}
private fun serviceWriteParameters(step: NasServiceStep, desired: JsonObject, before: JsonObject): JsonObject = when (step) {
    NasServiceStep.LED_UPDATE, NasServiceStep.REBOOT_REQUIRED -> JsonObject(emptyMap())
    NasServiceStep.POWER_SCHEDULE -> JsonObject(desired.filterKeys { !it.startsWith("_") })
    NasServiceStep.BEEP, NasServiceStep.HIBERNATION -> JsonObject(desired.filter { it.value != before[it.key] })
    NasServiceStep.UPS -> JsonObject(desired.filter { it.key in setOf("enable", "mode", "delay_time") || it.value != before[it.key] })
    in hardwareSteps -> JsonObject(desired.filterKeys { !it.startsWith("_") })
    else -> serviceSavedGroup(step, desired)
}
