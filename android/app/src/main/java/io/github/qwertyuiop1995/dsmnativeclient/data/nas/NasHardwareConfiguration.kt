package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

private val FAN_MODES = setOf("highfan", "lowfan", "fullfan", "coolfan", "quietfan", "quietstopfan")
private val UPS_MODES = setOf("USB", "SNMP", "SLAVE")

internal fun normalizeHardwareSettings(value: NasHardwareSettings) = value.copy(
    ups = value.ups?.copy(
        networkServerAddress = value.ups.networkServerAddress?.trim(),
        snmpServerAddress = value.ups.snmpServerAddress?.trim(),
    ),
)

internal fun isValidHardwareSettings(
    expected: NasHardwareSettings,
    current: NasHardwareSettings,
): Boolean {
    val writableValues = listOf(
        expected.restartsAfterPowerFailure to current.restartsAfterPowerFailure,
        expected.ledBrightness to current.ledBrightness,
        expected.fanMode to current.fanMode,
        expected.isFanFailureAlertEnabled to current.isFanFailureAlertEnabled,
        expected.isVolumeFailureAlertEnabled to current.isVolumeFailureAlertEnabled,
        expected.isPowerOnSoundEnabled to current.isPowerOnSoundEnabled,
        expected.isPowerOffSoundEnabled to current.isPowerOffSoundEnabled,
        expected.isResetSoundEnabled to current.isResetSoundEnabled,
        expected.isExternalDriveDeepSleepEnabled to current.isExternalDriveDeepSleepEnabled,
        expected.isWakeUpLogEnabled to current.isWakeUpLogEnabled,
        expected.isSataSleepEnabled to current.isSataSleepEnabled,
        expected.ignoresNetworkDiscoveryDuringSleep to current.ignoresNetworkDiscoveryDuringSleep,
        expected.isAutomaticPowerOffEnabled to current.isAutomaticPowerOffEnabled,
    )
    if (writableValues.any { (desiredValue, originalValue) ->
            desiredValue != originalValue && originalValue == null
        }
    ) return false
    if (expected.ledBrightness != current.ledBrightness && expected.ledBrightness != null) {
        val min = current.ledBrightnessMinimum ?: return false
        val max = current.ledBrightnessMaximum ?: return false
        if (expected.ledBrightness !in min..max) return false
    }
    if (expected.fanMode != current.fanMode && expected.fanMode !in FAN_MODES) return false
    if ((expected.ups == null) != (current.ups == null)) return false
    val ups = expected.ups ?: return true
    val currentUps = current.ups ?: return false
    val writableUpsValues = listOf(
        ups.safeModeDelaySeconds to currentUps.safeModeDelaySeconds,
        ups.waitsUntilLowBattery to currentUps.waitsUntilLowBattery,
        ups.shutsDownUpsAfterSafeMode to currentUps.shutsDownUpsAfterSafeMode,
        ups.networkServerAddress to currentUps.networkServerAddress,
        ups.snmpServerAddress to currentUps.snmpServerAddress,
    )
    if (writableUpsValues.any { (desiredValue, originalValue) ->
            desiredValue != originalValue && originalValue == null
        }
    ) return false
    if (ups.mode !in UPS_MODES || ups.safeModeDelaySeconds?.let { it !in 0..604_800 } == true) {
        return false
    }
    if (ups.isEnabled && ups.mode == "SLAVE" && ups.networkServerAddress.isNullOrBlank()) return false
    if (ups.isEnabled && ups.mode == "SNMP" && ups.snmpServerAddress.isNullOrBlank()) return false
    return listOfNotNull(ups.networkServerAddress, ups.snmpServerAddress).all { address ->
        address.length <= 255 && "://" !in address && address.none { it.isWhitespace() || it in "/?#@" }
    }
}

/** 官方硬件页位标记：高1、低2、低速停转4、全速8；缺失或未知支持信息只读。 */
internal fun supportedHardwareFanModes(value: JsonObject?): List<String>? {
    val kind = (value?.get("cool_fan") as? JsonPrimitive)?.takeIf { it.isString }?.content ?: return null
    if (kind == "no") return listOf("highfan", "lowfan")
    if (kind !in setOf("yes", "single")) return null
    val raw = (value?.get("fan_type") as? JsonPrimitive)?.content?.toDoubleOrNull() ?: return null
    if (!raw.isFinite() || raw % 1 != 0.0 || raw < 0 || raw > Int.MAX_VALUE) return null
    val options = if (kind == "single") listOf(8 to "fullfan", 2 to "quietfan")
        else listOf(8 to "fullfan", 1 to "coolfan", 2 to "quietfan", 4 to "quietstopfan")
    return options.filter { raw.toInt() and it.first != 0 }.map { it.second }
}

internal val hardwareSteps = setOf(NasServiceStep.POWER_RECOVERY, NasServiceStep.LED_BRIGHTNESS, NasServiceStep.LED_UPDATE,
    NasServiceStep.FAN, NasServiceStep.BEEP, NasServiceStep.HIBERNATION, NasServiceStep.UPS)
internal fun NasHardwareSettings.hardwareGroups(): Map<NasServiceStep, JsonObject> = buildMap {
    fun group(step: NasServiceStep, vararg fields: Pair<String, Any?>) {
        val value = buildJsonObject { fields.forEach { (key, value) -> when (value) {
            is Boolean -> put(key, value); is Int -> put(key, value); is String -> put(key, value)
            is List<*> -> put(key, JsonArray(value.map { JsonPrimitive(it as String) })); null -> Unit; else -> serviceInvalid()
        } } }; if (value.isNotEmpty()) put(step, value)
    }
    group(NasServiceStep.POWER_RECOVERY, "rc_power_config" to restartsAfterPowerFailure)
    if (ledBrightness != null) {
        group(NasServiceStep.LED_BRIGHTNESS, "led_brightness" to ledBrightness, "_min" to ledBrightnessMinimum, "_max" to ledBrightnessMaximum)
        group(NasServiceStep.LED_UPDATE, "led_brightness" to ledBrightness, "_min" to ledBrightnessMinimum, "_max" to ledBrightnessMaximum)
    }
    if (fanMode != null) group(NasServiceStep.FAN, "dual_fan_speed" to fanMode, "_modes" to supportedFanModes)
    group(NasServiceStep.BEEP, "fan_fail" to isFanFailureAlertEnabled,
        (if (isVolumeFailureAlertEnabled != null) beepVolumeFieldName ?: serviceInvalid() else "volume_crash") to isVolumeFailureAlertEnabled,
        "poweron_beep" to isPowerOnSoundEnabled, "poweroff_beep" to isPowerOffSoundEnabled, "reset_beep" to isResetSoundEnabled)
    group(NasServiceStep.HIBERNATION, "eunit_deep_sleep" to isExternalDriveDeepSleepEnabled, "enable_log" to isWakeUpLogEnabled,
        "sata_deep_sleep" to isSataSleepEnabled, "ignore_netbios_broadcast" to ignoresNetworkDiscoveryDuringSleep, "auto_poweroff_enable" to isAutomaticPowerOffEnabled)
    ups?.let { group(NasServiceStep.UPS, "enable" to it.isEnabled, "mode" to it.mode, "delay_time" to it.safeModeDelaySeconds,
        "ups_set_safemode_until_lowbatt" to it.waitsUntilLowBattery, "shutdown_device" to it.shutsDownUpsAfterSafeMode,
        "net_server_ip" to it.networkServerAddress, "snmp_server_ip" to it.snmpServerAddress) }
}
