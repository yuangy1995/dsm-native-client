import DsmCore
import DsmLocalization
import SwiftUI

struct MobileEthernetSummary: View {
    let value: NasEthernetInterface
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value.displayName).font(.headline)
            LabeledContent(L10n.string("mobile.nas.ethernet.mode"), value: L10n.string(value.usesDHCP ? "mobile.nas.ethernet.automatic" : "mobile.nas.ethernet.manual"))
            if !value.address.isEmpty { LabeledContent(L10n.string("mobile.nas.ethernet.address"), value: value.address) }
            if !compact {
                if !value.usesDHCP {
                    LabeledContent(L10n.string("mobile.nas.ethernet.mask"), value: value.subnetMask)
                    LabeledContent(L10n.string("mobile.nas.ethernet.gateway"), value: value.gateway.isEmpty ? L10n.string("mobile.nas.ethernet.none") : value.gateway)
                    LabeledContent(L10n.string("mobile.nas.ethernet.dns"), value: value.dnsServers.isEmpty ? L10n.string("mobile.nas.ethernet.none") : value.dnsServers)
                }
                LabeledContent(L10n.string("mobile.nas.ethernet.defaultGateway"), value: L10n.string(value.isDefaultGateway ? "mobile.nas.service.enabled" : "mobile.nas.service.disabled"))
            }
            LabeledContent(L10n.string("mobile.nas.ethernet.mtu"), value: value.mtu.formatted(.number.grouping(.never).locale(L10n.locale)))
            LabeledContent(L10n.string("mobile.nas.ethernet.vlan"), value: value.isVLANEnabled ? (value.vlanID ?? 0).formatted(.number.grouping(.never).locale(L10n.locale)) : L10n.string("mobile.nas.service.disabled"))
        }
        .accessibilityElement(children: .contain)
    }
}

struct MobileEthernetSettingsFields: View {
    @Binding var value: NasEthernetInterface
    let focused: FocusState<String?>.Binding
    @State private var mtu: String
    @State private var vlan: String
    init(value: Binding<NasEthernetInterface>, focused: FocusState<String?>.Binding) {
        _value = value; self.focused = focused
        _mtu = State(initialValue: String(value.wrappedValue.mtu))
        _vlan = State(initialValue: value.wrappedValue.vlanID.map(String.init) ?? "")
    }
    var body: some View {
        Section(value.displayName) {
            Toggle(L10n.string("mobile.nas.ethernet.automatic"), isOn: $value.usesDHCP)
                .accessibilityIdentifier("mobile.nas.ethernet.dhcp")
            if !value.usesDHCP {
                textField(.address, text: $value.address)
                textField(.mask, text: $value.subnetMask)
                textField(.gateway, text: $value.gateway)
                textField(.dns, text: $value.dnsServers)
            }
        }
        Section {
            Toggle(L10n.string("mobile.nas.ethernet.defaultGateway"), isOn: $value.isDefaultGateway)
                .accessibilityIdentifier("mobile.nas.ethernet.defaultGateway")
            textField(.mtu, text: $mtu)
                .onChange(of: mtu) { _, value in self.value.mtu = Int(value) ?? 0 }
            Toggle(L10n.string("mobile.nas.ethernet.vlanEnabled"), isOn: $value.isVLANEnabled)
                .accessibilityIdentifier("mobile.nas.ethernet.vlanEnabled")
            if value.isVLANEnabled {
                textField(.vlan, text: $vlan)
                    .onChange(of: vlan) { _, value in self.value.vlanID = Int(value) }
            }
        }
    }
    private func textField(_ field: EthernetField, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.title)
            TextField(field.title, text: text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(field == .mtu || field == .vlan ? .numberPad : .numbersAndPunctuation).submitLabel(.done)
                .focused(focused, equals: field.rawValue).accessibilityIdentifier("mobile.nas.ethernet.\(field.rawValue)")
        }
    }
}

private enum EthernetField: String {
    case address, mask, gateway, dns, mtu, vlan
    var title: String {
        let key = switch self {
        case .address: "mobile.nas.ethernet.address"; case .mask: "mobile.nas.ethernet.mask"
        case .gateway: "mobile.nas.ethernet.gateway"; case .dns: "mobile.nas.ethernet.dns"
        case .mtu: "mobile.nas.ethernet.mtu"; case .vlan: "mobile.nas.ethernet.vlan"
        }
        return L10n.string(key)
    }
}
