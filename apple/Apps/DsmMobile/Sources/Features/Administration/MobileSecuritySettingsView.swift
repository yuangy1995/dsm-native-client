import DsmCore
import DsmLocalization
import SwiftUI

struct MobileSecuritySettingsSummary: View {
    let value: NasSecuritySettings
    var steps: [NasServiceStep] = [.autoBlock, .denialOfService, .firewallNotifications, .firewall]
    var body: some View {
        if steps.contains(.autoBlock) {
            state(.autoBlock, value.isAutoBlockEnabled)
            number(.attempts, value.failedAttempts)
            number(.withinMinutes, value.withinMinutes)
            if let days = value.expirationDays { number(.expirationDays, days) }
            else { LabeledContent(L10n.string("mobile.nas.security.expiration"), value: L10n.string("mobile.nas.security.never")) }
        }
        if steps.contains(.denialOfService) {
            Text(L10n.string("mobile.nas.security.dos")).font(.headline)
            if value.dosProtection.isEmpty {
                Text(L10n.string("mobile.nas.security.noAdapters")).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mobile.nas.security.noAdapters")
            }
            ForEach(value.dosProtection) { adapter in
                LabeledContent(adapter.displayName, value: L10n.string(adapter.isEnabled ? "mobile.nas.service.enabled" : "mobile.nas.service.disabled"))
                    .accessibilityIdentifier("mobile.nas.security.summary.dos.\(adapter.id)")
            }
        }
        if steps.contains(.firewall), let enabled = value.isFirewallEnabled {
            state(.firewall, enabled)
            if let profile = value.firewallProfileName, !profile.isEmpty {
                LabeledContent(L10n.string("mobile.nas.security.profile"), value: profile)
            }
        }
        if steps.contains(.firewallNotifications), let enabled = value.isPortScanProtectionEnabled { state(.notifications, enabled) }
    }
    private func state(_ key: MobileSecurityField, _ enabled: Bool) -> some View {
        LabeledContent(key.title, value: L10n.string(enabled ? "mobile.nas.service.enabled" : "mobile.nas.service.disabled"))
            .accessibilityIdentifier("mobile.nas.security.summary." + key.rawValue)
    }
    private func number(_ key: MobileSecurityField, _ value: Int) -> some View {
        LabeledContent(key.title, value: value.formatted(.number.grouping(.never).locale(L10n.locale)))
            .accessibilityIdentifier("mobile.nas.security.summary." + key.rawValue)
    }
}

struct MobileSecuritySettingsFields: View {
    @Binding var value: NasSecuritySettings
    let focused: FocusState<String?>.Binding
    @State private var attempts: String
    @State private var within: String
    @State private var days: String
    init(value: Binding<NasSecuritySettings>, focused: FocusState<String?>.Binding) {
        _value = value; self.focused = focused
        _attempts = State(initialValue: String(value.wrappedValue.failedAttempts))
        _within = State(initialValue: String(value.wrappedValue.withinMinutes))
        _days = State(initialValue: String(value.wrappedValue.expirationDays ?? 1))
    }
    var body: some View {
        Section(L10n.string("mobile.nas.security.autoBlock")) {
            Toggle(L10n.string("mobile.nas.security.autoBlock"), isOn: $value.isAutoBlockEnabled)
                .accessibilityIdentifier("mobile.nas.security.autoBlock")
            numeric(.attempts, text: $attempts).disabled(!value.isAutoBlockEnabled)
                .onChange(of: attempts) { _, next in value.failedAttempts = Int(next) ?? 0 }
            numeric(.withinMinutes, text: $within).disabled(!value.isAutoBlockEnabled)
                .onChange(of: within) { _, next in value.withinMinutes = Int(next) ?? 0 }
            Toggle(L10n.string("mobile.nas.security.expiration"), isOn: Binding(get: { value.expirationDays != nil }, set: { value.expirationDays = $0 ? (Int(days) ?? 0) : nil }))
                .disabled(!value.isAutoBlockEnabled).accessibilityIdentifier("mobile.nas.security.expiration")
            if value.expirationDays != nil {
                numeric(.expirationDays, text: $days).disabled(!value.isAutoBlockEnabled)
                    .onChange(of: days) { _, next in value.expirationDays = Int(next) ?? 0 }
            }
        }
        Section(L10n.string("mobile.nas.security.dos")) {
            if value.dosProtection.isEmpty { Text(L10n.string("mobile.nas.security.noAdapters")).foregroundStyle(.secondary) }
            ForEach($value.dosProtection) { $adapter in
                Toggle(adapter.displayName, isOn: $adapter.isEnabled)
                    .accessibilityIdentifier("mobile.nas.security.dos.\(adapter.id)")
            }
        }
        if value.isFirewallEnabled != nil || value.isPortScanProtectionEnabled != nil {
            Section(L10n.string("mobile.nas.security.firewall")) {
                if value.isFirewallEnabled != nil {
                    Toggle(L10n.string("mobile.nas.security.firewall"), isOn: Binding(get: { value.isFirewallEnabled == true }, set: { value.isFirewallEnabled = $0 }))
                        .accessibilityIdentifier("mobile.nas.security.firewall")
                    if let profile = value.firewallProfileName, !profile.isEmpty { LabeledContent(L10n.string("mobile.nas.security.profile"), value: profile) }
                }
                if value.isPortScanProtectionEnabled != nil {
                    Toggle(L10n.string("mobile.nas.security.notifications"), isOn: Binding(get: { value.isPortScanProtectionEnabled == true }, set: { value.isPortScanProtectionEnabled = $0 }))
                        .disabled(value.isFirewallEnabled == false).accessibilityIdentifier("mobile.nas.security.notifications")
                }
            }
        }
    }
    private func numeric(_ key: MobileSecurityField, text: Binding<String>) -> some View {
        LabeledContent(key.title) {
            TextField(key.title, text: text)
                .keyboardType(.numberPad).focused(focused, equals: key.rawValue).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("mobile.nas.security." + key.rawValue)
        }
    }
}

private enum MobileSecurityField: String {
    case autoBlock, attempts, withinMinutes, expirationDays, firewall, notifications
    var title: String {
        let key = switch self {
        case .autoBlock: "mobile.nas.security.autoBlock"
        case .attempts: "mobile.nas.security.attempts"
        case .withinMinutes: "mobile.nas.security.withinMinutes"
        case .expirationDays: "mobile.nas.security.expirationDays"
        case .firewall: "mobile.nas.security.firewall"
        case .notifications: "mobile.nas.security.notifications"
        }
        return L10n.string(key)
    }
}
