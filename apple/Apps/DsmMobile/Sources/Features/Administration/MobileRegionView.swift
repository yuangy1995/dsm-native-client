import DsmCore
import DsmLocalization
import SwiftUI

struct MobileRegionScreen: View {
    @Bindable var model: MobileRegionModel
    @State private var editor: MobileRegionEditorSource?
    @State private var synchronization: NasRegionChange?
    @State private var confirmationActivation: UUID?

    var body: some View {
        List {
            Section {
                MobileNasDetailsSectionContent(section: model.settings,
                    loading: L10n.string("mobile.nas.region.loading"),
                    emptyTitle: L10n.string("mobile.nas.region.empty"),
                    emptyMessage: L10n.string("mobile.nas.region.readError"),
                    retry: { Task { await model.refresh() } }) { value in
                    LabeledContent(L10n.string("mobile.nas.region.dateFormat"), value: MobileRegionFormatting.dateFormat(value.dateFormat))
                    LabeledContent(L10n.string("mobile.nas.region.timeFormat"), value: MobileRegionFormatting.timeFormat(value.timeFormat))
                    LabeledContent(L10n.string("mobile.nas.region.timeZone"), value: value.timeZones.first { $0.id == value.timeZone }?.displayName ?? value.timeZone)
                    LabeledContent(L10n.string("mobile.nas.region.mode"), value: L10n.string(value.isNetworkTimeEnabled ? "mobile.nas.region.network" : "mobile.nas.region.manual"))
                    if let clock = value.manualDate {
                        LabeledContent(L10n.string("mobile.nas.region.currentTime"), value: MobileRegionFormatting.date(clock))
                            .accessibilityIdentifier("mobile.nas.region.clock")
                    }
                    if value.isNetworkTimeEnabled {
                        ForEach(Array(value.timeServers.enumerated()), id: \.offset) { _, server in Text(server).textSelection(.enabled) }
                    }
                    Button(L10n.string("mobile.nas.region.edit")) { editor = .init(original: value, activation: model.activation) }
                        .disabled(!model.canEdit).accessibilityIdentifier("mobile.nas.region.edit")
                    if value.isNetworkTimeEnabled {
                        let change = NasRegionChange.synchronize(expected: value)
                        Button(L10n.string("mobile.nas.region.synchronize")) { synchronization = change; confirmationActivation = model.activation }
                            .disabled(!model.canPerform(change)).accessibilityIdentifier("mobile.nas.region.synchronize")
                    }
                }
            }
            if let error = model.error { Section { Text(error.message).accessibilityIdentifier("mobile.nas.region.error") } }
            if !model.entries.isEmpty {
                Section(L10n.string("mobile.nas.region.activity")) {
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string(entry.synchronizationOnly ? "mobile.nas.region.synchronize" : "mobile.nas.region.save")).font(.headline)
                            Text(model.recovery.isExecuting(entry.id) ? L10n.string("mobile.nas.region.working") : entry.message)
                                .accessibilityIdentifier("mobile.nas.region.activity.\(entry.phase.rawValue)")
                            Text(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
                                .font(.caption).foregroundStyle(.secondary)
                            if entry.isUnfinished {
                                Button(L10n.string("mobile.nas.region.refresh")) { Task { await model.refresh() } }
                                    .disabled(model.isOperating || model.settings.isRefreshing)
                                    .accessibilityIdentifier("mobile.nas.region.recover")
                            } else if !model.recovery.isExecuting(entry.id) {
                                Button(L10n.string("mobile.nas.region.removeRecord")) { model.removeRecord(entry.id) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(L10n.string("mobile.nas.region.title"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.activation) { await model.loadIfNeeded() }
        .refreshable { await model.refresh() }
        .onDisappear { model.cancelRead() }
        .onChange(of: model.activation) { _, _ in editor = nil; synchronization = nil }
        .sheet(item: $editor) { source in NavigationStack { MobileRegionEditor(model: model, source: source) } }
        .alert(L10n.string("mobile.nas.region.synchronize"), isPresented: Binding(
            get: { synchronization != nil }, set: { if !$0 { synchronization = nil } }
        )) {
            if let synchronization, let token = confirmationActivation {
                Button(L10n.string("mobile.nas.region.synchronize"), role: .destructive) {
                    model.perform(synchronization, activation: token); self.synchronization = nil
                }.accessibilityIdentifier("mobile.nas.region.confirm")
            }
            Button(L10n.string("mobile.nas.region.cancel"), role: .cancel) { synchronization = nil }
                .accessibilityIdentifier("mobile.nas.region.cancel")
        } message: { Text(L10n.string("mobile.nas.region.syncWarning")) }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
}

private struct MobileRegionEditorSource: Identifiable {
    let id = UUID()
    let original: NasRegionSettings
    let activation: UUID
}

private struct MobileRegionEditor: View {
    @Bindable var model: MobileRegionModel
    let source: MobileRegionEditorSource
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NasRegionSettings
    @State private var servers: String
    @State private var editedManualTime = false
    @State private var confirmation: NasRegionChange?
    @State private var operationID: UUID?
    @FocusState private var editingServers: Bool

    init(model: MobileRegionModel, source: MobileRegionEditorSource) {
        self.model = model; self.source = source
        _draft = State(initialValue: source.original)
        _servers = State(initialValue: source.original.timeServers.joined(separator: ", "))
    }
    private var change: NasRegionChange {
        var desired = draft
        desired.timeServers = servers.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return .save(original: source.original, desired: desired, editsManualTime: editedManualTime)
    }
    var body: some View {
        Form {
            Section {
                Picker(L10n.string("mobile.nas.region.dateFormat"), selection: $draft.dateFormat) {
                    ForEach(MobileRegionFormatting.dateFormats, id: \.value) { option in Text(L10n.string(option.key)).tag(option.value) }
                    if !MobileRegionFormatting.dateFormats.contains(where: { $0.value == source.original.dateFormat }) {
                        Text(L10n.string("region.format.current")).tag(source.original.dateFormat)
                    }
                }.accessibilityIdentifier("mobile.nas.region.dateFormat")
                Picker(L10n.string("mobile.nas.region.timeFormat"), selection: $draft.timeFormat) {
                    Text(L10n.string("region.format.time-12")).tag("h:i a")
                    Text(L10n.string("region.format.time-24")).tag("H:i")
                    if !["h:i a", "H:i"].contains(source.original.timeFormat) {
                        Text(L10n.string("region.format.current")).tag(source.original.timeFormat)
                    }
                }.accessibilityIdentifier("mobile.nas.region.timeFormat")
                NavigationLink {
                    MobileRegionZonePicker(options: draft.timeZones, selection: $draft.timeZone)
                } label: {
                    LabeledContent(L10n.string("mobile.nas.region.timeZone"), value: draft.timeZones.first { $0.id == draft.timeZone }?.displayName ?? draft.timeZone)
                }.accessibilityIdentifier("mobile.nas.region.timeZone")
            }.disabled(!model.canEdit)
            Section {
                Toggle(L10n.string("mobile.nas.region.network"), isOn: $draft.isNetworkTimeEnabled)
                    .accessibilityIdentifier("mobile.nas.region.network")
                if draft.isNetworkTimeEnabled {
                    TextField(L10n.string("mobile.nas.region.servers"), text: $servers)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .focused($editingServers).submitLabel(.done)
                        .accessibilityIdentifier("mobile.nas.region.servers")
                    if !change.isValid && change.hasChanges { Text(L10n.string("region.settings.server-invalid")).foregroundStyle(.red) }
                } else {
                    DatePicker(L10n.string("mobile.nas.region.desiredTime"), selection: Binding(
                        get: { draft.manualDate ?? Date() },
                        set: { draft.manualDate = $0; editedManualTime = true }
                    ), displayedComponents: [.date, .hourAndMinute])
                    .environment(\.locale, L10n.locale)
                    .accessibilityIdentifier("mobile.nas.region.manualTime")
                    if draft.manualDate == nil { Text(L10n.string("mobile.nas.region.missingClock")).foregroundStyle(.secondary) }
                }
            } footer: {
                if draft.isNetworkTimeEnabled { Text(L10n.string("mobile.nas.region.serversHint")) }
            }
            .disabled(!model.canEdit)
            if let id = operationID, let entry = model.recovery.entry(id) {
                Section { Text(model.recovery.isExecuting(id) ? L10n.string("mobile.nas.region.working") : entry.message)
                    .accessibilityIdentifier("mobile.nas.region.saveResult") }
            }
            if let error = model.error { Section { Text(error.message) } }
        }
        .navigationTitle(L10n.string("mobile.nas.region.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("mobile.nas.region.done")) { dismiss() }.accessibilityIdentifier("mobile.nas.region.done")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.string("mobile.nas.region.save")) { editingServers = false; confirmation = change }
                    .disabled(!model.canPerform(change)).accessibilityIdentifier("mobile.nas.region.save")
            }
        }
        .onSubmit { editingServers = false }
        .onChange(of: model.activation) { _, _ in confirmation = nil; dismiss() }
        .onChange(of: model.recovery.entries) { _, _ in
            if let id = operationID, let entry = model.recovery.entry(id), [.succeeded, .partial].contains(entry.phase) { dismiss() }
        }
        .alert(L10n.string("mobile.nas.region.save"), isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        )) {
            if let confirmation {
                Button(L10n.string("mobile.nas.region.save"), role: .destructive) {
                    operationID = model.perform(confirmation, activation: source.activation); self.confirmation = nil
                }.accessibilityIdentifier("mobile.nas.region.confirm")
            }
            Button(L10n.string("mobile.nas.region.cancel"), role: .cancel) { confirmation = nil }
                .accessibilityIdentifier("mobile.nas.region.cancel")
        } message: { Text(L10n.string("mobile.nas.region.saveWarning")) }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
}

private struct MobileRegionZonePicker: View {
    let options: [NasTimeZoneOption]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        List {
            let filtered = options.filter { MobileNasReadFormatting.matches(query, values: [$0.id, $0.displayName]) }
            if filtered.isEmpty {
                ContentUnavailableView(L10n.string("mobile.nas.filter.empty"), systemImage: "magnifyingglass",
                    description: Text(L10n.string("mobile.nas.filter.retry")))
            }
            ForEach(filtered) { zone in
                Button { selection = zone.id; dismiss() } label: {
                    HStack { Text(zone.displayName); Spacer(); if zone.id == selection { Image(systemName: "checkmark") } }
                        .frame(minHeight: 44).contentShape(.rect)
                }
                .accessibilityAddTraits(zone.id == selection ? .isSelected : [])
                .accessibilityIdentifier("mobile.nas.region.zone.\(zone.id)")
            }
        }
        .navigationTitle(L10n.string("mobile.nas.region.timeZone"))
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("mobile.nas.region.searchZone"))
        .fillsAvailableContentArea(alignment: .topLeading)
    }
}

enum MobileRegionFormatting {
    static let dateFormats: [(value: String, key: String)] = [
        ("Y-m-d", "region.format.ymd-dash"), ("Y/m/d", "region.format.ymd-slash"), ("Y.m.d", "region.format.ymd-dot"),
        ("d-m-Y", "region.format.dmy-dash"), ("d/m/Y", "region.format.dmy-slash"), ("d.m.Y", "region.format.dmy-dot"),
        ("m-d-Y", "region.format.mdy-dash"), ("m/d/Y", "region.format.mdy-slash"), ("m.d.Y", "region.format.mdy-dot")
    ]
    static func dateFormat(_ value: String) -> String { dateFormats.first { $0.value == value }.map { L10n.string($0.key) } ?? L10n.string("region.format.current") }
    static func timeFormat(_ value: String) -> String {
        switch value { case "h:i a": L10n.string("region.format.time-12"); case "H:i": L10n.string("region.format.time-24"); default: L10n.string("region.format.current") }
    }
    static func date(_ value: Date) -> String { value.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(L10n.locale)) }
}
extension MobileRegionModel.Failure {
    var message: String {
        switch self {
        case .read: L10n.string("mobile.nas.region.readError")
        case .denied: L10n.string("mobile.nas.region.denied")
        case .unavailable: L10n.string("mobile.nas.region.unavailable")
        case .changed: L10n.string("mobile.nas.region.changed")
        case .storage: L10n.string("mobile.nas.region.storageError")
        }
    }
}
extension MobileRegionOperationStore.Entry {
    var message: String {
        switch phase {
        case .prepared: L10n.string("mobile.nas.region.working")
        case .saving, .saved, .synchronizing: L10n.string("mobile.nas.region.pending")
        case .succeeded: L10n.string(synchronizationOnly ? "mobile.nas.region.syncSucceeded" : needsSynchronization ? "mobile.nas.region.savedAndSynchronized" : "mobile.nas.region.saved")
        case .partial: L10n.string(failure == .denied ? "mobile.nas.region.syncDeniedAfterSave" : synchronizationOnly ? "mobile.nas.region.syncUnknown" : "mobile.nas.region.partial")
        case .cancelled: L10n.string("mobile.nas.region.cancelled")
        case .failed:
            switch failure {
            case .denied: MobileRegionModel.Failure.denied.message
            case .unavailable: MobileRegionModel.Failure.unavailable.message
            case .changed: MobileRegionModel.Failure.changed.message
            default: L10n.string("mobile.nas.region.failed")
            }
        }
    }
}
