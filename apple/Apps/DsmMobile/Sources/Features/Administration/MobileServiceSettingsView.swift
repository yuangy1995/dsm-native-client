import DsmCore
import DsmLocalization
import SwiftUI

struct MobileServiceSettingsScreen: View {
    @Bindable var model: MobileServiceSettingsModel
    let kind: NasServiceKind
    @State private var editor: MobileServiceEditorSource?
    @State private var query = ""
    @State private var networkRecovery: UUID?

    var body: some View {
        List {
            if model.section(kind).value?.supportsEditing == true && kind != .ethernet {
                Section {
                    Button(L10n.string(kind == .powerSchedule ? "mobile.nas.power.editSchedules" : "mobile.nas.service.edit")) {
                        if let value = model.section(kind).value { editor = .init(original: value, activation: model.activation) }
                    }.disabled(!model.canEdit(kind)).accessibilityIdentifier("mobile.nas.service.edit")
                    if let continuation = model.rebootContinuation(), kind == .zram {
                        Button(L10n.string("mobile.nas.power.continue")) {
                            editor = .init(original: continuation.original, activation: model.activation, initialDraft: continuation.desired)
                        }.accessibilityIdentifier("mobile.nas.power.continue")
                    }
                    if kind == .fileServices {
                        TextField(L10n.string("mobile.nas.service.search"), text: $query)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                            .accessibilityIdentifier("mobile.nas.service.search")
                    }
                }
            }
            if kind == .ethernet, model.section(kind).value?.isEmpty == false {
                Section {
                    TextField(L10n.string("mobile.nas.ethernet.search"), text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .accessibilityIdentifier("mobile.nas.ethernet.search")
                }
            }
            Section {
                if [.error, .unavailable].contains(model.section(kind).phase), let error = model.errors[kind] {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.string(model.section(kind).phase == .unavailable ? "mobile.nas-details.unavailable.title" : "mobile.nas-details.error.title"), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(error.message).foregroundStyle(.secondary).accessibilityIdentifier("mobile.nas.service.error")
                        Button(L10n.string("mobile.nas-health.action.retry")) { Task { await model.refresh(kind) } }.frame(minHeight: 44)
                    }.frame(maxWidth: .infinity, minHeight: 120, alignment: .leading).padding(.vertical, 8)
                } else {
                    MobileNasDetailsSectionContent(section: model.section(kind), loading: kind == .zram ? MobileNasAdministrationDestination.zram.loadingLabel : (kind == .powerSchedule ? MobileNasAdministrationDestination.powerSchedule.loadingLabel : L10n.string("mobile.nas.service.loading")),
                        emptyTitle: L10n.string(kind == .ethernet ? "mobile.nas.ethernet.empty" : kind == .powerSchedule ? "power-schedule.empty-title" : "mobile.nas.service.empty"), emptyMessage: L10n.string(kind == .ethernet ? "mobile.nas.ethernet.emptyHint" : kind == .powerSchedule ? (model.section(kind).value?.supportsEditing == true ? "mobile.nas.power.empty" : "power-schedule.edit.unavailable") : "mobile.nas.service.emptyHint"),
                        retry: { Task { await model.refresh(kind) } }) { value in
                        if case .ethernet(let interfaces) = value {
                            let matches = interfaces.filter { MobileNasReadFormatting.matches(query, values: [$0.id, $0.displayName, $0.address]) }
                            if matches.isEmpty {
                                ContentUnavailableView(L10n.string("mobile.nas.filter.empty"), systemImage: "magnifyingglass", description: Text(L10n.string("mobile.nas.filter.retry")))
                                    .accessibilityIdentifier("mobile.nas.ethernet.filteredEmpty")
                            }
                            ForEach(matches) { interface in
                                VStack(alignment: .leading, spacing: 12) {
                                    MobileEthernetSummary(value: interface, compact: true)
                                    Button(L10n.string("mobile.nas.service.edit")) { editor = .init(original: value, activation: model.activation, ethernetID: interface.id) }
                                        .disabled(!model.canEdit(.ethernet)).frame(minHeight: 44)
                                        .accessibilityIdentifier("mobile.nas.ethernet.edit.\(interface.id)")
                                }
                            }
                        } else if kind == .zram || kind == .powerSchedule {
                            MobilePowerSettingsSummary(value: value)
                        } else if case .security(let settings) = value {
                            MobileSecuritySettingsSummary(value: settings)
                        } else {
                        // 搜索使用稳定的服务标识，不把翻译后的开关状态用于筛选。
                        let needle = query.filter { !$0.isWhitespace }
                        let rows = value.mobileRows.filter { MobileNasReadFormatting.matches(needle, values: [$0.id.rawValue]) }
                        if rows.isEmpty {
                            ContentUnavailableView(L10n.string("mobile.nas.filter.empty"), systemImage: "magnifyingglass",
                                description: Text(L10n.string("mobile.nas.filter.retry"))).accessibilityIdentifier("mobile.nas.service.filteredEmpty")
                        }
                        if case .remoteAccess(let settings) = value {
                            remoteReadMessages(settings)
                            if !settings.canDisableRelay && settings.isRelayEnabled != nil { Text(L10n.string("mobile.nas.service.relayProtection")).foregroundStyle(.secondary) }
                        }
                        ForEach(rows) { row in
                            LabeledContent(row.title, value: row.value).accessibilityIdentifier("mobile.nas.service.row.\(row.id.rawValue)")
                        }
                        }
                    }
                }
            }
            if let error = model.errors[kind], ![.error, .unavailable].contains(model.section(kind).phase) {
                Section { Text(error.message).accessibilityIdentifier("mobile.nas.service.error") }
            }
            if !model.entries(kind).isEmpty {
                Section(L10n.string("mobile.nas.service.activity")) {
                    ForEach(model.entries(kind)) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.recovery.isExecuting(entry.id) ? L10n.string("mobile.nas.service.working") : entry.message)
                                .accessibilityIdentifier("mobile.nas.service.activity.\(entry.phase.rawValue)")
                            if entry.parts.count > 1 {
                                ForEach(entry.parts, id: \.step) { part in
                                    LabeledContent(part.step.title, value: part.message).font(.subheadline)
                                }
                            }
                            Text(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
                                .font(.caption).foregroundStyle(.secondary)
                            if entry.isUnfinished {
                                if kind == .ethernet { Text(L10n.string("mobile.nas.ethernet.reconnectHint")).foregroundStyle(.secondary) }
                                Button(L10n.string("mobile.nas.service.refresh")) {
                                    if kind == .ethernet, entry.context != model.context { networkRecovery = entry.id }
                                    else { Task { await model.refresh(kind) } }
                                }
                                    .disabled(model.isOperating || model.recovery.isExecuting(entry.id) || model.section(kind).isRefreshing).accessibilityIdentifier("mobile.nas.service.recover")
                            } else if !model.recovery.isExecuting(entry.id) {
                                Button(L10n.string("mobile.nas.service.removeRecord")) { model.removeRecord(entry.id, kind: kind) }
                                    .accessibilityIdentifier("mobile.nas.service.removeRecord")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped).scrollDismissesKeyboard(.interactively)
        .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("mobile.nas.service.list")
        .task(id: model.activation) { await model.loadIfNeeded(kind) }.refreshable { await model.refresh(kind) }
        .onDisappear { model.cancelRead(kind) }
        .onChange(of: model.activation) { _, _ in editor = nil; query = ""; networkRecovery = nil }
        .confirmationDialog(L10n.string("mobile.nas.ethernet.recoveryTitle"), isPresented: Binding(get: { networkRecovery != nil }, set: { if !$0 { networkRecovery = nil } }), titleVisibility: .visible) {
            Button(L10n.string("mobile.nas.ethernet.readResult")) {
                if let id = networkRecovery { let token = model.activation; Task { await model.readNetworkResult(id, activation: token) } }
                networkRecovery = nil
            }
            Button(L10n.string("mobile.nas.service.cancel"), role: .cancel) { networkRecovery = nil }
        } message: { Text(L10n.string("mobile.nas.ethernet.recoveryWarning")) }
        .sheet(item: $editor) { source in NavigationStack { MobileServiceSettingsEditor(model: model, source: source, onClose: { editor = nil }) } }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
}

private struct MobileServiceEditorSource: Identifiable {
    let id = UUID()
    let original: NasServiceSettings
    let activation: UUID
    let initialDraft: NasServiceSettings?
    let ethernetID: String?
    init(original: NasServiceSettings, activation: UUID, initialDraft: NasServiceSettings? = nil, ethernetID: String? = nil) {
        self.original = original; self.activation = activation; self.initialDraft = initialDraft
        self.ethernetID = ethernetID
    }
}

private struct MobileServiceSettingsEditor: View {
    @Bindable var model: MobileServiceSettingsModel
    let source: MobileServiceEditorSource
    let onClose: () -> Void
    @State private var draft: NasServiceSettings
    @State private var ports: [String: String]
    @State private var proxyHost: String
    @State private var confirmation: NasServiceChange?
    @State private var confirmedChange: NasServiceChange?
    @State private var operationID: UUID?
    @State private var editingPowerEntry: NasPowerScheduleEntry?
    @FocusState private var focused: String?

    init(model: MobileServiceSettingsModel, source: MobileServiceEditorSource, onClose: @escaping () -> Void) {
        self.model = model; self.source = source; self.onClose = onClose
        _draft = State(initialValue: source.initialDraft ?? source.original)
        var ports: [String: String] = [:], host = ""
        switch source.original {
        case .fileServices(let value): ports = ["ftpPort": value.ftpPort.map(String.init) ?? "", "sftpPort": value.sftpPort.map(String.init) ?? ""]
        case .terminal(let value): ports = ["sshPort": value.sshPort.map(String.init) ?? ""]
        case .proxy(let value): ports = ["proxyPort": value.port.map(String.init) ?? ""]; host = value.host
        case .remoteAccess, .zram, .powerSchedule, .ethernet, .security: break
        }
        _ports = State(initialValue: ports); _proxyHost = State(initialValue: host)
    }
    private var change: NasServiceChange {
        let desired: NasServiceSettings
        switch draft {
        case .fileServices(var value):
            if value.ftpPort != nil { value.ftpPort = parsedPort("ftpPort") }
            if value.sftpPort != nil { value.sftpPort = parsedPort("sftpPort") }
            desired = .fileServices(value)
        case .terminal(var value): if value.sshPort != nil { value.sshPort = parsedPort("sshPort") }; desired = .terminal(value)
        case .proxy(var value): value.host = proxyHost; value.port = parsedPort("proxyPort"); desired = .proxy(value)
        case .remoteAccess, .ethernet, .security: desired = draft
        case .powerSchedule: desired = draft
        case .zram(let value, _):
            if source.initialDraft == nil, case .zram(let original, _) = source.original, value.isEnabled == original.isEnabled { desired = source.original }
            else { desired = draft }
        }
        return .init(original: source.original, desired: desired)
    }
    private func parsedPort(_ key: String) -> Int { Int((ports[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
    var body: some View {
        Form {
            fields.disabled(!model.canEdit(source.original.kind))
            if !change.changedSteps.isEmpty && change.orderedSteps == nil {
                Section { Text(source.original.kind.invalidMessage).foregroundStyle(.red).accessibilityIdentifier("mobile.nas.service.invalid") }
            }
            if let error = model.errors[source.original.kind] { Section { Text(error.message) } }
            if let operationID, let entry = model.recovery.entry(operationID) {
                Section { Text(model.recovery.isExecuting(operationID) ? L10n.string("mobile.nas.service.working") : entry.message)
                    .accessibilityIdentifier("mobile.nas.service.editorResult") }
            }
        }
        .accessibilityIdentifier("mobile.nas.service.editor")
        .scrollDismissesKeyboard(.interactively).onSubmit { focused = nil }
        .navigationTitle(source.original.kind.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("mobile.nas.service.done")) { onClose() }.accessibilityIdentifier("mobile.nas.service.done")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.string("mobile.nas.service.save")) { focused = nil; confirmation = change }
                    .disabled(!model.canPerform(change)).accessibilityIdentifier("mobile.nas.service.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.string("mobile.nas.service.done")) { focused = nil }.accessibilityIdentifier("mobile.nas.service.keyboardDone")
            }
        }
        .onChange(of: model.activation) { _, _ in confirmation = nil; confirmedChange = nil; onClose() }
        // 条目编辑器由表单根呈现，不能挂在 Form 的惰性 Section 上。
        .sheet(item: $editingPowerEntry) { entry in
            NavigationStack {
                MobilePowerScheduleEntryEditor(entry: entry) { next in
                    guard case .powerSchedule(let value) = draft else { return }
                    var entries = value.entries
                    if let index = entries.firstIndex(where: { $0.id == next.id }) { entries[index] = next } else { entries.append(next) }
                    draft = .powerSchedule(.init(entries: entries, timeZoneIdentifier: value.timeZoneIdentifier,
                                                total: entries.count, isTruncated: false, supportsEditing: true))
                    editingPowerEntry = nil
                }
            }
        }
        .task(id: operationID) {
            guard let operationID else { return }
            await model.waitForOperation(operationID)
            guard !Task.isCancelled, source.activation == model.activation, model.recovery.entry(operationID)?.phase == .succeeded else { return }
            onClose()
        }
        .sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), onDismiss: {
            guard let change = confirmedChange else { return }; confirmedChange = nil
            operationID = model.perform(change, activation: source.activation)
        }) {
            if let confirmation {
                NavigationStack {
                    Form {
                        Section { Text(confirmation.kind.warning) }
                        Section(L10n.string("mobile.nas.service.changes")) {
                            if let target = confirmation.ethernetTarget {
                                MobileEthernetSummary(value: target)
                            } else if confirmation.kind == .zram || confirmation.kind == .powerSchedule {
                                MobilePowerSettingsSummary(value: confirmation.desired, showsFilter: false)
                            } else if case .security(let settings) = confirmation.desired {
                                MobileSecuritySettingsSummary(value: settings, steps: confirmation.changedSteps)
                            } else {
                            ForEach(confirmation.changedSteps, id: \.self) { step in
                                ForEach(confirmation.desired.mobileRows.filter { $0.step == step }) { row in LabeledContent(row.title, value: row.value) }
                            }
                            }
                        }
                    }
                    .navigationTitle(L10n.string("mobile.nas.service.save")).navigationBarTitleDisplayMode(.inline)
                    .accessibilityIdentifier("mobile.nas.service.confirmation")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.string("mobile.nas.service.cancel"), role: .cancel) { self.confirmation = nil }
                                .accessibilityIdentifier("mobile.nas.service.cancel")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.string("mobile.nas.service.save"), role: .destructive) {
                                guard confirmedChange == nil else { return }; confirmedChange = confirmation; self.confirmation = nil
                            }.disabled(!model.canPerform(confirmation) || confirmedChange != nil).accessibilityIdentifier("mobile.nas.service.confirm")
                        }
                    }
                    .fillsAvailableContentArea(alignment: .topLeading)
                }
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    @ViewBuilder private var fields: some View {
        switch draft {
        case .fileServices(let value):
            let binding = Binding<NasFileServiceSettings>(get: { if case .fileServices(let current) = draft { return current }; return value }, set: { draft = .fileServices($0) })
            Section {
                optionalToggle(.smb, binding.isSMBEnabled); optionalToggle(.nfs, binding.isNFSEnabled)
            }
            Section {
                optionalToggle(.ftp, binding.isFTPEnabled); optionalToggle(.ftps, binding.isFTPSEnabled)
                if value.ftpPort != nil { portField(.ftpPort) }
                optionalToggle(.sftp, binding.isSFTPEnabled)
                if value.sftpPort != nil { portField(.sftpPort) }
            }
            Section {
                optionalToggle(.ssdp, binding.isSSDPEnabled); optionalToggle(.bonjour, binding.isBonjourEnabled)
                optionalToggle(.timeMachine, binding.isSMBTimeMachineEnabled)
            }
        case .terminal(let value):
            let binding = Binding<NasTerminalSettings>(get: { if case .terminal(let current) = draft { return current }; return value }, set: { draft = .terminal($0) })
            Section {
                serviceToggle(.ssh, binding.isSSHEnabled); serviceToggle(.telnet, binding.isTelnetEnabled)
                if value.sshPort != nil { portField(.sshPort) }
            }
        case .remoteAccess(let value):
            let binding = Binding<NasRemoteAccessSettings>(get: { if case .remoteAccess(let current) = draft { return current }; return value }, set: { draft = .remoteAccess($0) })
            Section {
                optionalToggle(.relay, binding.isRelayEnabled).disabled(!value.canDisableRelay && value.isRelayEnabled == true)
                if !value.canDisableRelay && value.isRelayEnabled != nil { Text(L10n.string("mobile.nas.service.relayProtection")).foregroundStyle(.secondary) }
                optionalToggle(.routerConfiguration, binding.isRouterConfigurationEnabled)
                remoteReadMessages(value)
            }
        case .proxy(let value):
            let binding = Binding<NasProxySettings>(get: { if case .proxy(let current) = draft { return current }; return value }, set: { draft = .proxy($0) })
            Section {
                serviceToggle(.proxyEnabled, binding.isEnabled)
                LabeledContent(L10n.string("mobile.nas.service.proxyHost")) {
                    TextField(L10n.string("mobile.nas.service.proxyHost"), text: $proxyHost)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).submitLabel(.done)
                        .focused($focused, equals: "proxyHost").disabled(!value.isEnabled).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("mobile.nas.service.proxyHost")
                }
                portField(.proxyPort).disabled(!value.isEnabled)
            }
        case .zram, .powerSchedule:
            MobilePowerSettingsFields(draft: $draft, original: source.original, editing: $editingPowerEntry)
        case .security(let value):
            MobileSecuritySettingsFields(value: Binding(get: { if case .security(let current) = draft { return current }; return value }, set: { draft = .security($0) }), focused: $focused)
        case .ethernet(let values):
            if let value = values.first(where: { $0.id == source.ethernetID }) {
                MobileEthernetSettingsFields(value: Binding(get: {
                    if case .ethernet(let current) = draft { return current.first { $0.id == value.id } ?? value }; return value
                }, set: { next in
                    if case .ethernet(var current) = draft, let index = current.firstIndex(where: { $0.id == next.id }) { current[index] = next; draft = .ethernet(current) }
                }), focused: $focused)
            }
        }
    }
    @ViewBuilder private func optionalToggle(_ key: MobileServiceField, _ value: Binding<Bool?>) -> some View {
        if value.wrappedValue != nil { serviceToggle(key, Binding(get: { value.wrappedValue == true }, set: { value.wrappedValue = $0 })) }
    }
    private func serviceToggle(_ key: MobileServiceField, _ value: Binding<Bool>) -> some View {
        Toggle(key.title, isOn: value).accessibilityIdentifier("mobile.nas.service.\(key.rawValue)")
    }
    private func portField(_ key: MobileServiceField) -> some View {
        LabeledContent(key.title) {
            TextField(key.title, text: Binding(get: { ports[key.rawValue] ?? "" }, set: { ports[key.rawValue] = $0 }))
                .keyboardType(.numberPad).focused($focused, equals: key.rawValue).multilineTextAlignment(.trailing)
                .accessibilityIdentifier("mobile.nas.service.\(key.rawValue)")
        }
    }
}

private struct MobileServiceRow: Identifiable {
    let id: MobileServiceField
    let value: String
    let step: NasServiceStep
    var title: String { id.title }
}
private extension NasServiceSettings {
    var mobileRows: [MobileServiceRow] {
        var rows: [MobileServiceRow] = []
        func boolean(_ key: MobileServiceField, _ value: Bool?, _ step: NasServiceStep) {
            if let value { rows.append(.init(id: key, value: L10n.string(value ? "mobile.nas.service.enabled" : "mobile.nas.service.disabled"), step: step)) }
        }
        func port(_ key: MobileServiceField, _ value: Int?, _ step: NasServiceStep) {
            if let value { rows.append(.init(id: key, value: value.formatted(.number.grouping(.never).locale(L10n.locale)), step: step)) }
        }
        switch self {
        case .fileServices(let value):
            boolean(.smb, value.isSMBEnabled, .smb); boolean(.nfs, value.isNFSEnabled, .nfs)
            boolean(.ftp, value.isFTPEnabled, .ftp); boolean(.ftps, value.isFTPSEnabled, .ftp); port(.ftpPort, value.ftpPort, .ftp)
            boolean(.sftp, value.isSFTPEnabled, .sftp); port(.sftpPort, value.sftpPort, .sftp)
            boolean(.ssdp, value.isSSDPEnabled, .webDiscovery); boolean(.bonjour, value.isBonjourEnabled, .webDiscovery)
            boolean(.timeMachine, value.isSMBTimeMachineEnabled, .fileDiscovery)
        case .terminal(let value): boolean(.ssh, value.isSSHEnabled, .terminal); boolean(.telnet, value.isTelnetEnabled, .terminal); port(.sshPort, value.sshPort, .terminal)
        case .remoteAccess(let value):
            boolean(.relay, value.isRelayEnabled, .relay); boolean(.routerConfiguration, value.isRouterConfigurationEnabled, .routerConfiguration)
        case .proxy(let value):
            boolean(.proxyEnabled, value.isEnabled, .proxy)
            if value.isEnabled {
                if !value.host.isEmpty { rows.append(.init(id: .proxyHost, value: value.host, step: .proxy)) }
                port(.proxyPort, value.port, .proxy)
            }
        case .zram, .powerSchedule, .ethernet, .security: break
        }
        return rows
    }
}

private enum MobileServiceField: String {
    case smb, nfs, ftp, ftps, sftp, ftpPort, sftpPort, ssdp, bonjour, timeMachine, ssh, telnet, sshPort, proxyEnabled, proxyHost, proxyPort, relay, routerConfiguration
    var title: String {
        let key = switch self {
        case .smb: "mobile.nas.service.smb"
        case .nfs: "mobile.nas.service.nfs"
        case .ftp: "mobile.nas.service.ftp"
        case .ftps: "mobile.nas.service.ftps"
        case .sftp: "mobile.nas.service.sftp"
        case .ftpPort: "mobile.nas.service.ftpPort"
        case .sftpPort: "mobile.nas.service.sftpPort"
        case .ssdp: "mobile.nas.service.ssdp"
        case .bonjour: "mobile.nas.service.bonjour"
        case .timeMachine: "mobile.nas.service.timeMachine"
        case .ssh: "mobile.nas.service.ssh"
        case .telnet: "mobile.nas.service.telnet"
        case .sshPort: "mobile.nas.service.sshPort"
        case .proxyEnabled: "mobile.nas.service.proxyEnabled"
        case .proxyHost: "mobile.nas.service.proxyHost"
        case .proxyPort: "mobile.nas.service.proxyPort"
        case .relay: "mobile.nas.service.relay"
        case .routerConfiguration: "mobile.nas.service.routerConfiguration"
        }
        return L10n.string(key)
    }
}

extension NasServiceKind {
    var title: String {
        let key = switch self { case .fileServices: "mobile.nas.service.fileServices"; case .terminal: "mobile.nas.service.terminal"; case .proxy: "mobile.nas.service.proxy"; case .remoteAccess: "mobile.nas.service.remoteAccess"; case .zram: "zram.title"; case .powerSchedule: "power-schedule.title"; case .ethernet: "mobile.nas.ethernet.title"; case .security: "mobile.nas.security.title" }
        return L10n.string(key)
    }
    var warning: String {
        let key = switch self { case .fileServices: "mobile.nas.service.fileServicesWarning"; case .terminal: "mobile.nas.service.terminalWarning"; case .proxy: "mobile.nas.service.proxyWarning"; case .remoteAccess: "mobile.nas.service.remoteAccessWarning"; case .zram: "zram.edit.confirm-message"; case .powerSchedule: "power-schedule.edit.confirm-message"; case .ethernet: "mobile.nas.ethernet.warning"; case .security: "mobile.nas.security.warning" }
        return L10n.string(key)
    }
    var invalidMessage: String {
        let key = switch self { case .fileServices: "mobile.nas.service.fileServicesInvalid"; case .terminal: "mobile.nas.service.terminalInvalid"; case .proxy: "mobile.nas.service.proxyInvalid"; case .remoteAccess: "mobile.nas.service.relayProtection"; case .zram: "mobile.nas.power.compressionUnavailable"; case .powerSchedule: "power-schedule.edit.invalid"; case .ethernet: "mobile.nas.ethernet.invalid"; case .security: "mobile.nas.security.invalid" }
        return L10n.string(key)
    }
}
private extension NasServiceStep {
    var title: String {
        let key: String
        switch self { case .smb: key = "mobile.nas.service.smb"; case .nfs: key = "mobile.nas.service.nfs"; case .ftp: key = "mobile.nas.service.ftpGroup"; case .sftp: key = "mobile.nas.service.sftp"
        case .webDiscovery: key = "mobile.nas.service.discovery"; case .fileDiscovery: key = "mobile.nas.service.timeMachine"; case .terminal: key = "mobile.nas.service.terminal"; case .proxy: key = "mobile.nas.service.proxy"; case .relay: key = "mobile.nas.service.relay"; case .routerConfiguration: key = "mobile.nas.service.routerConfiguration"
        case .zram: key = "zram.title"; case .rebootRequired: key = "mobile.nas.power.restartRequirement"; case .powerSchedule: key = "power-schedule.title"; case .ethernet: key = "mobile.nas.ethernet.title"
        case .autoBlock: key = "mobile.nas.security.autoBlock"; case .denialOfService: key = "mobile.nas.security.dos"; case .firewallNotifications: key = "mobile.nas.security.notifications"; case .firewall: key = "mobile.nas.security.firewall" }
        return L10n.string(key)
    }
}
extension MobileServiceSettingsModel.Failure {
    var message: String {
        let key: String
        switch self { case .read: key = "mobile.nas.service.readError"; case .denied: key = "mobile.nas.service.denied"; case .unavailable: key = "mobile.nas.service.unavailable"; case .changed: key = "mobile.nas.service.changed"; case .storage: key = "mobile.nas.service.storageError"; case .trust: key = "mobile.nas.service.trustError" }
        return L10n.string(key)
    }
}
private extension MobileServiceOperationStore.Entry {
    var message: String {
        if phase == .submitted { return L10n.string(hasSavedChanges ? "mobile.nas.service.partialUnknown" : "mobile.nas.service.unknown") }
        if phase == .partial {
            if failure == .changed { return MobileServiceSettingsModel.Failure.changed.message }
            return L10n.string(failure == .denied ? "mobile.nas.service.partialDenied" : "mobile.nas.service.partial")
        }
        if let failure {
            switch failure { case .denied: return MobileServiceSettingsModel.Failure.denied.message
            case .unavailable: return MobileServiceSettingsModel.Failure.unavailable.message
            case .changed: return MobileServiceSettingsModel.Failure.changed.message
            case .failed: return L10n.string("mobile.nas.service.failed") }
        }
        let key: String
        switch phase { case .prepared: key = "mobile.nas.service.prepared"; case .succeeded: key = "mobile.nas.service.succeeded"
        case .cancelled: key = "mobile.nas.service.cancelled"; case .submitted: key = "mobile.nas.service.unknown"
        case .partial: key = "mobile.nas.service.partial"; case .failed: key = "mobile.nas.service.failed" }
        return L10n.string(key)
    }
}
private extension MobileServiceOperationStore.Part {
    var message: String {
        let key: String
        switch stage { case .prepared: key = "mobile.nas.service.prepared"; case .submitted: key = hasPartialFields ? "mobile.nas.service.partPartial" : "mobile.nas.service.partUnknown"
        case .verified: key = "mobile.nas.service.partSaved"; case .rejected: key = "mobile.nas.service.partRejected"; case .skipped: key = "mobile.nas.service.partSkipped" }
        return L10n.string(key)
    }
}

@ViewBuilder private func remoteReadMessages(_ value: NasRemoteAccessSettings) -> some View {
    if value.relayReadFailed { Text(L10n.string("mobile.nas.service.relayReadFailed")).foregroundStyle(.secondary).accessibilityIdentifier("mobile.nas.service.relayReadFailed") }
    if value.routerConfigurationReadFailed { Text(L10n.string("mobile.nas.service.routerReadFailed")).foregroundStyle(.secondary).accessibilityIdentifier("mobile.nas.service.routerReadFailed") }
}
