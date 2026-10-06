import DsmCore
import DsmLocalization
import SwiftUI

struct MobileHardwareSettingsSummary: View {
    let value: NasHardwareSettings
    var steps: [NasServiceStep] = [.powerRecovery, .ledBrightness, .fanMode, .beep, .hibernation, .ups]
    var body: some View {
        if steps.contains(.powerRecovery) { flag(.powerRecovery, value.restartsAfterPowerFailure) }
        if steps.contains(.ledBrightness) || steps.contains(.ledUpdate), let brightness = value.ledBrightness { row(.brightness, number(brightness)) }
        if steps.contains(.fanMode), let mode = value.fanMode { row(.fan, hardwareFanTitle(mode)) }
        if steps.contains(.beep) {
            flag(.fanFailure, value.isFanFailureAlertEnabled); flag(.volumeFailure, value.isVolumeFailureAlertEnabled)
            flag(.powerOnSound, value.isPowerOnSoundEnabled); flag(.powerOffSound, value.isPowerOffSoundEnabled); flag(.resetSound, value.isResetSoundEnabled)
        }
        if steps.contains(.hibernation) {
            flag(.externalSleep, value.isExternalDriveDeepSleepEnabled); flag(.wakeLog, value.isWakeUpLogEnabled)
            flag(.sataSleep, value.isSATASleepEnabled); flag(.ignoreDiscovery, value.ignoresNetworkDiscoveryDuringSleep)
            flag(.automaticPowerOff, value.isAutomaticPowerOffEnabled)
        }
        if steps.contains(.ups), let ups = value.ups {
            Text(L10n.string("mobile.nas.hardware.ups")).font(.headline)
            flag(.upsEnabled, ups.isEnabled); row(.upsMode, hardwareUPSTitle(ups.mode))
            if let delay = ups.safeModeDelaySeconds { row(.upsDelay, number(delay)) }
            flag(.upsLowBattery, ups.waitsUntilLowBattery); flag(.upsShutdown, ups.shutsDownUPSAfterSafeMode)
            if let address = ups.networkServerAddress { row(.upsNetwork, address.isEmpty ? L10n.string("mobile.nas.hardware.notSet") : address) }
            if let address = ups.snmpServerAddress { row(.upsSNMP, address.isEmpty ? L10n.string("mobile.nas.hardware.notSet") : address) }
        }
    }
    private func row(_ field: MobileHardwareField, _ text: String) -> some View {
        LabeledContent(field.title, value: text).accessibilityIdentifier("mobile.nas.hardware.summary." + field.rawValue)
    }
    @ViewBuilder private func flag(_ field: MobileHardwareField, _ enabled: Bool?) -> some View {
        if let enabled { row(field, L10n.string(enabled ? "mobile.nas.service.enabled" : "mobile.nas.service.disabled")) }
    }
    private func number(_ value: Int) -> String { value.formatted(.number.grouping(.never).locale(L10n.locale)) }
}

struct MobileHardwareSettingsFields: View {
    @Binding var value: NasHardwareSettings
    let focused: FocusState<String?>.Binding
    @State private var delay: String
    init(value: Binding<NasHardwareSettings>, focused: FocusState<String?>.Binding) {
        _value = value; self.focused = focused
        _delay = State(initialValue: value.wrappedValue.ups?.safeModeDelaySeconds.map(String.init) ?? "")
    }
    var body: some View {
        if value.restartsAfterPowerFailure != nil || value.ledBrightness != nil {
            Section {
                toggle(.powerRecovery, $value.restartsAfterPowerFailure)
                if let brightness = value.ledBrightness, let range = value.ledBrightnessRange {
                    Stepper(value: Binding(get: { value.ledBrightness ?? brightness }, set: { value.ledBrightness = $0 }), in: range) {
                        LabeledContent(MobileHardwareField.brightness.title, value: brightness.formatted(.number.grouping(.never).locale(L10n.locale)))
                    }.accessibilityIdentifier("mobile.nas.hardware.brightness")
                } else if value.ledBrightness != nil {
                    MobileHardwareSettingsSummary(value: value, steps: [.ledBrightness])
                    Text(L10n.string("mobile.nas.hardware.brightnessUnavailable")).foregroundStyle(.secondary)
                }
            }
        }
        if let current = value.fanMode {
            Section {
                if let supported = value.supportedFanModes, !supported.isEmpty {
                    Picker(MobileHardwareField.fan.title, selection: Binding(get: { value.fanMode ?? current }, set: { value.fanMode = $0 })) {
                        ForEach(supported, id: \.self) { mode in Text(hardwareFanTitle(mode)).tag(mode) }
                        if !supported.contains(current) { Text(hardwareFanTitle(current)).tag(current) }
                    }.accessibilityIdentifier("mobile.nas.hardware.fan")
                } else {
                    MobileHardwareSettingsSummary(value: value, steps: [.fanMode])
                    Text(L10n.string("mobile.nas.hardware.fanUnavailable")).foregroundStyle(.secondary)
                }
            }
        }
        if hasValues(.beep) {
            Section(L10n.string("mobile.nas.hardware.sounds")) {
                toggle(.fanFailure, $value.isFanFailureAlertEnabled); toggle(.volumeFailure, $value.isVolumeFailureAlertEnabled)
                toggle(.powerOnSound, $value.isPowerOnSoundEnabled); toggle(.powerOffSound, $value.isPowerOffSoundEnabled); toggle(.resetSound, $value.isResetSoundEnabled)
            }
        }
        if hasValues(.hibernation) {
            Section(L10n.string("mobile.nas.hardware.sleep")) {
                toggle(.externalSleep, $value.isExternalDriveDeepSleepEnabled); toggle(.wakeLog, $value.isWakeUpLogEnabled)
                toggle(.sataSleep, $value.isSATASleepEnabled); toggle(.ignoreDiscovery, $value.ignoresNetworkDiscoveryDuringSleep)
                toggle(.automaticPowerOff, $value.isAutomaticPowerOffEnabled)
            }
        }
        if let ups = value.ups {
            Section(L10n.string("mobile.nas.hardware.ups")) {
                Toggle(MobileHardwareField.upsEnabled.title, isOn: Binding(get: { value.ups?.isEnabled == true }, set: { value.ups?.isEnabled = $0 }))
                    .accessibilityIdentifier("mobile.nas.hardware.upsEnabled")
                Picker(MobileHardwareField.upsMode.title, selection: Binding(get: { value.ups?.mode ?? ups.mode }, set: { value.ups?.mode = $0 })) {
                    ForEach(["USB", "SLAVE", "SNMP"], id: \.self) { mode in Text(hardwareUPSTitle(mode)).tag(mode) }
                }.accessibilityIdentifier("mobile.nas.hardware.upsMode")
                if ups.safeModeDelaySeconds != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MobileHardwareField.upsDelay.title)
                        TextField(MobileHardwareField.upsDelay.title, text: $delay).keyboardType(.numberPad)
                            .focused(focused, equals: "upsDelay")
                            .accessibilityIdentifier("mobile.nas.hardware.upsDelay")
                    }.onChange(of: delay) { _, next in value.ups?.safeModeDelaySeconds = Int(next) ?? -1 }
                }
                toggle(.upsLowBattery, Binding(get: { value.ups?.waitsUntilLowBattery }, set: { value.ups?.waitsUntilLowBattery = $0 }))
                toggle(.upsShutdown, Binding(get: { value.ups?.shutsDownUPSAfterSafeMode }, set: { value.ups?.shutsDownUPSAfterSafeMode = $0 }))
                if ups.networkServerAddress != nil {
                    address(.upsNetwork, Binding(get: { value.ups?.networkServerAddress ?? "" }, set: { value.ups?.networkServerAddress = $0 }))
                }
                if ups.snmpServerAddress != nil {
                    address(.upsSNMP, Binding(get: { value.ups?.snmpServerAddress ?? "" }, set: { value.ups?.snmpServerAddress = $0 }))
                }
            }
        }
    }
    private func hasValues(_ step: NasServiceStep) -> Bool { NasServiceSettings.hardware(value).fields(for: step).contains { $0 != nil } }
    @ViewBuilder private func toggle(_ field: MobileHardwareField, _ binding: Binding<Bool?>) -> some View {
        if binding.wrappedValue != nil {
            Toggle(field.title, isOn: Binding(get: { binding.wrappedValue == true }, set: { binding.wrappedValue = $0 }))
                .accessibilityIdentifier("mobile.nas.hardware." + field.rawValue)
        }
    }
    private func address(_ field: MobileHardwareField, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(field.title)
            TextField(field.title, text: binding).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .focused(focused, equals: field.rawValue).accessibilityIdentifier("mobile.nas.hardware." + field.rawValue)
        }
    }
}

struct MobileHardwareSettingsWarning: View {
    let steps: [NasServiceStep]
    var body: some View {
        if steps.contains(.powerRecovery) { Section { Text(L10n.string("mobile.nas.hardware.powerWarning")) } }
        if steps.contains(.fanMode) { Section { Text(L10n.string("mobile.nas.hardware.fanWarning")) } }
        if steps.contains(.beep) { Section { Text(L10n.string("mobile.nas.hardware.soundWarning")) } }
        if steps.contains(.hibernation) { Section { Text(L10n.string("mobile.nas.hardware.sleepWarning")) } }
        if steps.contains(.ups) { Section { Text(L10n.string("mobile.nas.hardware.upsWarning")) } }
    }
}

private enum MobileHardwareField: String {
    case powerRecovery, brightness, fan, fanFailure, volumeFailure, powerOnSound, powerOffSound, resetSound
    case externalSleep, wakeLog, sataSleep, ignoreDiscovery, automaticPowerOff
    case upsEnabled, upsMode, upsDelay, upsLowBattery, upsShutdown, upsNetwork, upsSNMP
    var title: String {
        let key = switch self {
        case .powerRecovery: "mobile.nas.hardware.powerRecovery"; case .brightness: "mobile.nas.hardware.brightness"; case .fan: "mobile.nas.hardware.fan"
        case .fanFailure: "mobile.nas.hardware.fanFailure"; case .volumeFailure: "mobile.nas.hardware.volumeFailure"
        case .powerOnSound: "mobile.nas.hardware.powerOnSound"; case .powerOffSound: "mobile.nas.hardware.powerOffSound"; case .resetSound: "mobile.nas.hardware.resetSound"
        case .externalSleep: "mobile.nas.hardware.externalSleep"; case .wakeLog: "mobile.nas.hardware.wakeLog"; case .sataSleep: "mobile.nas.hardware.sataSleep"
        case .ignoreDiscovery: "mobile.nas.hardware.ignoreDiscovery"; case .automaticPowerOff: "mobile.nas.hardware.automaticPowerOff"
        case .upsEnabled: "mobile.nas.hardware.upsEnabled"; case .upsMode: "mobile.nas.hardware.upsMode"; case .upsDelay: "mobile.nas.hardware.upsDelay"
        case .upsLowBattery: "mobile.nas.hardware.upsLowBattery"; case .upsShutdown: "mobile.nas.hardware.upsShutdown"
        case .upsNetwork: "mobile.nas.hardware.upsNetwork"; case .upsSNMP: "mobile.nas.hardware.upsSNMP"
        }
        return L10n.string(key)
    }
}

private func hardwareFanTitle(_ mode: String) -> String {
    let key: String
    switch mode {
    case "highfan": key = "ui.390ea09574f38da3"; case "lowfan": key = "ui.0949910fb8c4e07f"
    case "fullfan": key = "ui.f327f82035eeb44c"; case "coolfan": key = "ui.844749143a0da5a0"
    case "quietfan": key = "ui.5b31e21cdb562f6a"; case "quietstopfan": key = "ui.1b3589f9dbf18de9"
    default: return mode
    }
    return L10n.string(key)
}
private func hardwareUPSTitle(_ mode: String) -> String {
    let key: String
    switch mode { case "USB": key = "mobile.nas.hardware.usb"; case "SLAVE": key = "mobile.nas.hardware.networkUPS"; case "SNMP": key = "mobile.nas.hardware.snmp"; default: return mode }
    return L10n.string(key)
}
