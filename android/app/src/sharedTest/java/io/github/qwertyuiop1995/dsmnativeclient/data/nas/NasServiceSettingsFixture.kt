package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

internal class NasServiceSettingsFixture : NasManagementGateway {
    data class Request(val step: NasServiceStep, val method: String, val version: Int, val fields: Map<String, JsonElement>, val write: Boolean, val api: String = step.api)
    val rows = mutableMapOf(
        NasServiceStep.SMB to row("""{"enable_samba":false}"""), NasServiceStep.NFS to row("""{"enable_nfs":false}"""),
        NasServiceStep.FTP to row("""{"enable_ftp":false,"enable_ftps":false,"portnum":2121}"""),
        NasServiceStep.SFTP to row("""{"enable":false,"portnum":2222}"""), NasServiceStep.WEB_DISCOVERY to row("""{"enable_ssdp":false,"enable_avahi":false}"""),
        NasServiceStep.TIME_MACHINE to row("""{"enable_smb_time_machine":false}"""), NasServiceStep.TERMINAL to row("""{"enable_ssh":false,"enable_telnet":false,"ssh_port":22}"""),
        NasServiceStep.PROXY to row("""{"enable":false,"http_host":"private.example.invalid","http_port":3128}"""))
    var trustedRelay = false; var remoteManageable = true
    init { rows[NasServiceStep.RELAY] = row("""{"relay_enabled":true}"""); rows[NasServiceStep.ROUTER] = row("""{"enabled":false}""") }
    init { rows[NasServiceStep.ETHERNET] = row("""{"ifname":"eth0","use_dhcp":true,"is_default_gateway":false,"mtu":1500,"enable_vlan":false}""") }
    init {
        rows[NasServiceStep.AUTO_BLOCK] = row("""{"enable":false,"attempts":5,"within_mins":10,"expire_day":7}""")
        rows[NasServiceStep.DOS] = row("""{"configs":[{"adapter":"eth0","dos_protect_enable":false}]}""")
        rows[NasServiceStep.FIREWALL_NOTIFICATIONS] = row("""{"enable_port_check":false}""")
        rows[NasServiceStep.FIREWALL] = row("""{"enable_firewall":false,"profile_name":"synthetic-profile"}""")
    }
    init {
        rows[NasServiceStep.POWER_RECOVERY] = row("""{"rc_power_config":false}""")
        rows[NasServiceStep.LED_BRIGHTNESS] = row("""{"led_brightness":3}""")
        rows[NasServiceStep.LED_UPDATE] = row("{}")
        rows[NasServiceStep.FAN] = row("""{"dual_fan_speed":"quietfan","cool_fan":"yes","fan_type":15}""")
        rows[NasServiceStep.BEEP] = row("""{"fan_fail":false,"volume_or_cache_crash":true,"poweron_beep":false,"poweroff_beep":false,"reset_beep":false,"support_fan_fail":true,"support_volume_crash":true,"support_poweron_beep":true,"support_poweroff_beep":true,"support_reset_beep":true}""")
        rows[NasServiceStep.HIBERNATION] = row("""{"eunit_deep_sleep":false,"enable_log":false,"sata_deep_sleep":false,"ignore_netbios_broadcast":false,"auto_poweroff_enable":false}""")
        rows[NasServiceStep.UPS] = row("""{"enable":false,"mode":"USB","delay_time":120,"ups_set_safemode_until_lowbatt":false,"shutdown_device":false,"net_server_ip":"","snmp_server_ip":""}""")
    }
    init {
        rows[NasServiceStep.ZRAM] = row("""{"enable_zram":false}""")
        rows[NasServiceStep.REBOOT_REQUIRED] = row("""{"need_reboot":false}""")
        rows[NasServiceStep.POWER_SCHEDULE] = row("""{"poweron_tasks":[],"poweroff_tasks":[],"timezone":"UTC"}""")
    }
    var ethernetList = row("""{"interfaces":[{"ifname":"eth0","display":"Synthetic LAN"}]}""")
    var ledRange = row("""{"min":0,"max":5}""")
    var taskReceipt = row("""{"task_id":"synthetic-firewall-task"}""")
    var taskStatus = row("""{"success":true}""")
    var applySupported = true
    val requests = mutableListOf<Request>(); val writes get() = requests.filter { it.write }
    var before: suspend (Request) -> Unit = {}; var afterWrite: suspend (Request) -> Unit = {}; var access: suspend () -> Unit = {}
    val versions = NasServiceStep.entries.associateWith { if (it in setOf(NasServiceStep.SMB, NasServiceStep.NFS, NasServiceStep.TERMINAL, NasServiceStep.RELAY)) 1..3 else if (it in setOf(NasServiceStep.WEB_DISCOVERY, NasServiceStep.ETHERNET, NasServiceStep.DOS)) 1..2 else 1..1 }.toMutableMap()
    val repository = NasServiceSettingsRepository(this, supports = { api, version -> versions.any { it.key.api == api && version in it.value } },
        remoteContext = { trustedRelay to remoteManageable })
    override suspend fun requireWriteAccess() { access() }
    override suspend fun call(api: String, method: String, version: Int, parameters: Map<String, JsonElement>, write: Boolean): JsonObject {
        val step = if (api == firewallApplyApi) NasServiceStep.FIREWALL
            else if (api == NasServiceStep.LED_BRIGHTNESS.api) { if (method == "update") NasServiceStep.LED_UPDATE else NasServiceStep.LED_BRIGHTNESS }
            else NasServiceStep.entries.single { it.api == api }; val request = Request(step, method, version, parameters, write, api)
        requests += request; before(request)
        if (step == NasServiceStep.LED_BRIGHTNESS && method == "get_static_data") return ledRange
        if (step == NasServiceStep.LED_UPDATE && write) { afterWrite(request); return JsonObject(emptyMap()) }
        if (api == firewallApplyApi) {
            if (method == "status") {
                if (taskStatus["success"] == JsonPrimitive(true)) rows[step] = JsonObject(rows.getValue(step) + ("enable_firewall" to JsonPrimitive(true)))
                return taskStatus
            }
            afterWrite(request)
            return if (method == "start") taskReceipt else JsonObject(emptyMap())
        }
        if (step == NasServiceStep.ETHERNET && method == "list") return ethernetList
        if (step == NasServiceStep.FIREWALL && write) {
            rows[step] = JsonObject(rows.getValue(step) + ("enable_firewall" to JsonPrimitive(false)))
            afterWrite(request); return JsonObject(emptyMap())
        }
        if (step == NasServiceStep.REBOOT_REQUIRED && write) {
            rows[step] = row("""{"need_reboot":true}"""); afterWrite(request); return JsonObject(emptyMap())
        }
        if (write) { rows[step] = JsonObject(rows.getValue(step) + if (step == NasServiceStep.ETHERNET) parameters.getValue("configs").jsonArray.single().jsonObject else parameters); afterWrite(request); return JsonObject(emptyMap()) }
        return rows.getValue(step)
    }
    companion object { fun row(value: String) = Json.parseToJsonElement(value).jsonObject }
}
