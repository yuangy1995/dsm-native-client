package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.Serializable

@Serializable internal enum class NasServiceKind { FILES, TERMINAL, PROXY, REMOTE_ACCESS, ETHERNET, SECURITY, HARDWARE, MEMORY_COMPRESSION, POWER_SCHEDULE }
@Serializable internal enum class NasServiceStep { SMB, NFS, FTP, SFTP, WEB_DISCOVERY, TIME_MACHINE, TERMINAL, PROXY, RELAY, ROUTER, ETHERNET, AUTO_BLOCK, DOS, FIREWALL_NOTIFICATIONS, FIREWALL, POWER_RECOVERY, LED_BRIGHTNESS, LED_UPDATE, FAN, BEEP, HIBERNATION, UPS, ZRAM, REBOOT_REQUIRED, POWER_SCHEDULE }
@Serializable internal enum class NasServiceStage { PREPARED, SUBMITTED, ACCEPTED, VERIFIED, REJECTED, CANCELLED }

/** 配置正文只存在内存；磁盘恢复记录只保存各组的摘要。 */
internal sealed interface NasServiceValue {
    val kind: NasServiceKind
    data class Files(val settings: NasFileServiceSettings) : NasServiceValue { override val kind = NasServiceKind.FILES }
    data class Terminal(val settings: NasTerminalSettings) : NasServiceValue { override val kind = NasServiceKind.TERMINAL }
    data class Proxy(val settings: NasProxySettings) : NasServiceValue {
        override val kind = NasServiceKind.PROXY
        override fun toString() = "NasServiceValue.Proxy"
    }
    data class Ethernet(val settings: NasEthernetInterface) : NasServiceValue {
        override val kind = NasServiceKind.ETHERNET
        override fun toString() = "NasServiceValue.Ethernet"
    }
    data class Hardware(val settings: NasHardwareSettings) : NasServiceValue { override val kind = NasServiceKind.HARDWARE; override fun toString() = "NasServiceValue.Hardware" }
    data class MemoryCompression(val settings: NasMemoryCompression) : NasServiceValue { override val kind = NasServiceKind.MEMORY_COMPRESSION }
    data class PowerSchedule(val settings: NasPowerSchedule) : NasServiceValue { override val kind = NasServiceKind.POWER_SCHEDULE; override fun toString() = "NasServiceValue.PowerSchedule" }
    data class Security(val settings: NasSecuritySettings) : NasServiceValue { override val kind = NasServiceKind.SECURITY }
    data class RemoteAccess(val settings: NasRemoteAccessSettings) : NasServiceValue { override val kind = NasServiceKind.REMOTE_ACCESS }
}

/** 只保留原任务回执；全局清理只能由未中断的原执行流程调用。 */
@Serializable internal data class NasFirewallTask(val id: String, val outcome: Boolean? = null,
    val cleanupAttempted: Boolean = false, val cleanupAccepted: Boolean = false) {
    override fun toString() = "NasFirewallTask"
}
internal data class NasServiceCheckpoint(val step: NasServiceStep, val stage: NasServiceStage, val task: NasFirewallTask? = null)
internal typealias NasServiceObserver = suspend (NasServiceCheckpoint) -> Unit
