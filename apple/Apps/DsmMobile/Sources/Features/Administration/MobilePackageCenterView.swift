import DsmCore
import DsmLocalization
import SwiftUI

struct MobilePackageCenterScreen: View {
    @Bindable var model: MobilePackageCenterModel
    @State private var query = ""
    @State private var showsSettings = false
    private var filtered: [NasPackage] { model.installed.filter { MobileNasReadFormatting.matches(query, values: [$0.name, $0.id, $0.version ?? ""]) } }
    var body: some View {
        List {
            Section {
                NavigationLink { MobilePackageCatalogScreen(model: model.installation) } label: {
                    Label(L10n.string("mobile.package.browseInstall"), systemImage: "shippingbox")
                }.accessibilityIdentifier("mobile.package.catalog")
            }
            Section { TextField(L10n.string("package.center.search"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("mobile.package.search") }
            MobilePackageReadStatus(model: model, page: .installed)
            if model.section(.installed).phase == .content {
                if filtered.isEmpty { ContentUnavailableView(L10n.string("mobile.nas.filter.empty"), systemImage: "magnifyingglass", description: Text(L10n.string("mobile.nas.filter.retry"))).accessibilityIdentifier("mobile.package.filteredEmpty") }
                ForEach(filtered) { value in
                    NavigationLink { MobilePackageControlScreen(model: model, source: value) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(value.name).font(.headline)
                            if let version = value.version { Text(version).font(.subheadline).foregroundStyle(.secondary) }
                            Text(value.mobilePackageStatus).foregroundStyle(.secondary)
                        }
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("mobile.package.row.\(value.id)")
                }
            }
            MobilePackageActivitySection(model: model)
            MobilePackageInstallationActivity(model: model.installation)
        }
        .accessibilityIdentifier("mobile.package.list").listStyle(.insetGrouped)
        .navigationTitle(L10n.string("mobile.nas-details.section.packages")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { showsSettings = true } label: { Label(L10n.string("package.center.settings"), systemImage: "gearshape") }
                .accessibilityIdentifier("mobile.package.settings")
        } }
        .refreshable { await model.refresh(.installed) }.task(id: model.activation) { await model.loadIfNeeded(.installed) }
        .onDisappear { model.cancelRead(.installed) }
        .onChange(of: model.activation) { _, _ in query = ""; showsSettings = false }
        .sheet(isPresented: $showsSettings) { MobilePackagePreferencesScreen(model: model) { showsSettings = false } }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
}

private struct MobilePackagePreferencesScreen: View {
    @Bindable var model: MobilePackageCenterModel
    let close: () -> Void
    @State private var draft: MobilePackageSettingsDraft?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { MobilePackageSourcesScreen(model: model) } label: { Label(L10n.string("package.center.sources"), systemImage: "shippingbox") }
                        .accessibilityIdentifier("mobile.package.sources")
                }
                MobilePackageReadStatus(model: model, page: .preferences)
                if let snapshot = model.preferences {
                    Section(L10n.string("package.center.general")) {
                        if snapshot.settings.volumes.count > 1 {
                            LabeledContent(L10n.string("package.center.default-volume"), value: snapshot.settings.volumes.first { $0.id == snapshot.settings.defaultVolumeID }?.name ?? L10n.string("package.center.ask-each-time"))
                        }
                        flag("package.center.email-notifications", snapshot.settings.emailNotifications)
                        flag("package.center.desktop-notifications", snapshot.settings.desktopNotifications)
                        flag("package.center.show-beta", snapshot.settings.betaEnabled)
                    }
                    Section(L10n.string("package.center.automatic-updates")) {
                        Text(snapshot.settings.updatePolicy.mobilePackageTitle).accessibilityIdentifier("mobile.package.policy.summary")
                        if !snapshot.unknownUpdateIDs.isEmpty { Text(L10n.string("mobile.package.preferences.unknown")) }
                    }
                    Section {
                        Button(L10n.string("mobile.package.editSettings")) { draft = .init(original: snapshot, activation: model.activation) }
                            .disabled(!model.canEdit(.preferences)).accessibilityIdentifier("mobile.package.editSettings")
                    }
                }
                MobilePackageActivitySection(model: model)
            }
            .accessibilityIdentifier("mobile.package.preferences").listStyle(.insetGrouped)
            .navigationTitle(L10n.string("package.center.settings")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("package.center.close"), action: close).accessibilityIdentifier("mobile.package.close") } }
            .refreshable { await model.refresh(.preferences) }.task(id: model.activation) { await model.loadIfNeeded(.preferences) }
            .onDisappear { model.cancelRead(.preferences) }
            .sheet(item: $draft) { value in MobilePackageSettingsEditor(model: model, source: value) { draft = nil } }
            .onChange(of: model.activation) { _, _ in draft = nil; close() }
        }
    }
    private func flag(_ key: String, _ value: Bool) -> some View {
        LabeledContent(L10n.string(key), value: MobileNasReadFormatting.enabled(value))
            .accessibilityElement(children: .combine).accessibilityLabel(L10n.string(key)).accessibilityValue(MobileNasReadFormatting.enabled(value))
            .accessibilityIdentifier("mobile.package.summary.\(key)")
    }
}

private struct MobilePackageSettingsDraft: Identifiable {
    let id = UUID()
    let original: NasPackagePreferencesSnapshot
    let activation: UUID
}

private struct MobilePackageSettingsEditor: View {
    @Bindable var model: MobilePackageCenterModel
    let source: MobilePackageSettingsDraft
    let close: () -> Void
    @State private var draft: NasPackageCenterSettings
    @State private var prompt: MobilePackageChangePrompt?
    @State private var confirmed: MobilePackageChangePrompt?
    @State private var operationID: UUID?
    init(model: MobilePackageCenterModel, source: MobilePackageSettingsDraft, close: @escaping () -> Void) {
        self.model = model; self.source = source; self.close = close; _draft = State(initialValue: source.original.settings)
    }
    private var change: NasPackagePreferenceChange { .settings(original: source.original, desired: draft) }
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.string("package.center.general")) {
                    if draft.volumes.count > 1 {
                        Picker(L10n.string("package.center.default-volume"), selection: $draft.defaultVolumeID) {
                            Text(L10n.string("package.center.ask-each-time")).tag("")
                            ForEach(draft.volumes) { Text($0.name).tag($0.id) }
                        }.accessibilityIdentifier("mobile.package.volume")
                    }
                    Toggle(L10n.string("package.center.email-notifications"), isOn: $draft.emailNotifications).accessibilityIdentifier("mobile.package.email")
                    Toggle(L10n.string("package.center.desktop-notifications"), isOn: $draft.desktopNotifications).accessibilityIdentifier("mobile.package.desktop")
                    Toggle(L10n.string("package.center.show-beta"), isOn: $draft.betaEnabled).accessibilityIdentifier("mobile.package.beta")
                }.disabled(!model.canEdit(.preferences))
                Section(L10n.string("package.center.automatic-updates")) {
                    Picker(L10n.string("package.center.update-policy"), selection: $draft.updatePolicy) {
                        ForEach(NasPackageCenterSettings.UpdatePolicy.allCases, id: \.self) { Text($0.mobilePackageTitle).tag($0) }
                    }.accessibilityIdentifier("mobile.package.policy")
                    if draft.updatePolicy == .selected {
                        ForEach(draft.packageUpdates) { preference in
                            if source.original.unknownUpdateIDs.contains(preference.id) {
                                LabeledContent(preference.name, value: L10n.string("mobile.nas-health.status.unknown"))
                            } else {
                                Picker(preference.name, selection: Binding(get: { draft.packageUpdates.first { $0.id == preference.id }?.policy ?? preference.policy }, set: { value in
                                    if let index = draft.packageUpdates.firstIndex(where: { $0.id == preference.id }) { draft.packageUpdates[index].policy = value }
                                })) {
                                    ForEach(NasPackageUpdatePreference.Policy.allCases, id: \.self) { Text($0.mobilePackageTitle).tag($0) }
                                }.disabled(!preference.canUpdateAutomatically).accessibilityIdentifier("mobile.package.policy.\(preference.id)")
                            }
                        }
                        if !source.original.unknownUpdateIDs.isEmpty { Text(L10n.string("mobile.package.preferences.unknown")) }
                    }
                }.disabled(!model.canEdit(.preferences))
                if let failure = model.errors[.preferences] { Section { Text(failure.mobilePackageMessage) } }
                if let operationID, let entry = model.recovery.entry(operationID) { Section { MobilePackageRecord(model: model, entry: entry) } }
            }
            .accessibilityIdentifier("mobile.package.settingsEditor")
            .navigationTitle(L10n.string("mobile.package.editSettings")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.string(operationID == nil ? "mobile.nas.service.cancel" : "package.center.close"), action: close).accessibilityIdentifier("mobile.package.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("package.center.save-settings")) {
                        if change.enablesAutomaticUpdates { prompt = .init(change: change, activation: source.activation) }
                        else { operationID = model.perform(change, activation: source.activation) }
                    }.disabled(source.activation != model.activation || !model.canPerform(change)).accessibilityIdentifier("mobile.package.save")
                }
            }
        }
        .sheet(item: $prompt, onDismiss: { if let confirmed { operationID = model.perform(confirmed.change, activation: confirmed.activation); self.confirmed = nil } }) { value in
            MobilePackageChangeConfirmation(model: model, source: value, cancel: { prompt = nil }, confirm: { confirmed = value; prompt = nil })
        }
        .onChange(of: model.activation) { _, _ in prompt = nil; confirmed = nil; close() }
        .onChange(of: model.entries) { _, _ in if let operationID, model.recovery.entry(operationID)?.phase == .succeeded { close() } }
    }
}

private struct MobilePackageSourcesScreen: View {
    @Bindable var model: MobilePackageCenterModel
    @State private var query = ""
    @State private var draft: MobilePackageSourceDraft?
    private var filtered: [NasPackageSource] { model.sources.filter { MobileNasReadFormatting.matches(query, values: [$0.name, $0.url]) } }
    var body: some View {
        List {
            Section { TextField(L10n.string("mobile.package.source.search"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("mobile.package.source.search") }
            MobilePackageReadStatus(model: model, page: .sources)
            if model.section(.sources).phase == .content {
                if filtered.isEmpty { ContentUnavailableView(L10n.string("mobile.nas.filter.empty"), systemImage: "magnifyingglass", description: Text(L10n.string("mobile.nas.filter.retry"))).accessibilityIdentifier("mobile.package.source.filteredEmpty") }
                ForEach(filtered) { source in
                    Button { draft = .init(original: source, activation: model.activation) } label: {
                        VStack(alignment: .leading, spacing: 6) { Text(source.name).font(.headline); Text(source.url).font(.subheadline).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityIdentifier("mobile.package.source.row.\(MobilePackageOperationStore.digest(source.url))")
                }
            }
            MobilePackageActivitySection(model: model)
        }
        .accessibilityIdentifier("mobile.package.source.list").listStyle(.insetGrouped)
        .navigationTitle(L10n.string("package.center.sources")).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { draft = .init(original: nil, activation: model.activation) } label: { Label(L10n.string("package.center.source-add"), systemImage: "plus") }
                .disabled(!model.canEdit(.sources)).accessibilityIdentifier("mobile.package.source.add")
        } }
        .refreshable { await model.refresh(.sources) }.task(id: model.activation) { await model.loadIfNeeded(.sources) }
        .onDisappear { model.cancelRead(.sources) }
        .sheet(item: $draft) { value in MobilePackageSourceEditor(model: model, source: value) { draft = nil } }
        .onChange(of: model.activation) { _, _ in query = ""; draft = nil }
    }
}
private struct MobilePackageSourceDraft: Identifiable { let id = UUID(); let original: NasPackageSource?; let activation: UUID }
private struct MobilePackageSourceEditor: View {
    private enum Field: Hashable { case name, address }
    @Bindable var model: MobilePackageCenterModel
    let source: MobilePackageSourceDraft
    let close: () -> Void
    @State private var draft: NasPackageSource
    @State private var prompt: MobilePackageChangePrompt?
    @State private var confirmed: MobilePackageChangePrompt?
    @State private var operationID: UUID?
    @FocusState private var focusedField: Field?
    init(model: MobilePackageCenterModel, source: MobilePackageSourceDraft, close: @escaping () -> Void) {
        self.model = model; self.source = source; self.close = close; _draft = State(initialValue: source.original ?? .init(name: "", url: ""))
    }
    private var change: NasPackagePreferenceChange { .saveSource(draft, replacing: source.original) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.string("package.center.source-name"), text: $draft.name).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .name).submitLabel(.next).onSubmit { focusedField = .address }.accessibilityIdentifier("mobile.package.source.name")
                    TextField(L10n.string("package.center.source-address"), text: $draft.url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focusedField, equals: .address).submitLabel(.done).onSubmit { focusedField = nil }.accessibilityIdentifier("mobile.package.source.url")
                    if !draft.url.isEmpty, draft.normalizedForEditing == nil { Text(L10n.string("package.center.source-invalid")) }
                    if draft.normalizedForEditing?.url.lowercased().hasPrefix("http:") == true { Text(L10n.string("package.center.source-http-warning")) }
                }.disabled(!model.canEdit(.sources))
                if let original = source.original {
                    Section {
                        Button(L10n.string("package.center.source-remove"), role: .destructive) { prompt = .init(change: .removeSource(original), activation: source.activation) }
                            .disabled(!model.canPerform(.removeSource(original))).accessibilityIdentifier("mobile.package.source.remove")
                    }
                }
                if let failure = model.errors[.sources] { Section { Text(failure.mobilePackageMessage) } }
                if let operationID, let entry = model.recovery.entry(operationID) { Section { MobilePackageRecord(model: model, entry: entry) } }
            }
            .accessibilityIdentifier("mobile.package.source.editor")
            .navigationTitle(L10n.string(source.original == nil ? "package.center.source-add" : "package.center.source-edit")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button(L10n.string("mobile.nas.service.done")) { focusedField = nil }.accessibilityIdentifier("mobile.package.keyboardDone") }
                ToolbarItem(placement: .cancellationAction) { Button(L10n.string(operationID == nil ? "mobile.nas.service.cancel" : "package.center.close"), action: close).accessibilityIdentifier("mobile.package.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("package.center.source-save")) { prompt = .init(change: change, activation: source.activation) }
                        .disabled(source.activation != model.activation || !model.canPerform(change)).accessibilityIdentifier("mobile.package.save")
                }
            }
        }
        .sheet(item: $prompt, onDismiss: { if let confirmed { operationID = model.perform(confirmed.change, activation: confirmed.activation); self.confirmed = nil } }) { value in
            MobilePackageChangeConfirmation(model: model, source: value, cancel: { prompt = nil }, confirm: { confirmed = value; prompt = nil })
        }
        .onChange(of: model.activation) { _, _ in prompt = nil; confirmed = nil; close() }
        .onChange(of: model.entries) { _, _ in if let operationID, model.recovery.entry(operationID)?.phase == .succeeded { close() } }
    }
}

private struct MobilePackageChangePrompt: Identifiable { let id = UUID(); let change: NasPackagePreferenceChange; let activation: UUID }
private struct MobilePackageChangeConfirmation: View {
    @Bindable var model: MobilePackageCenterModel
    let source: MobilePackageChangePrompt
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                switch source.change {
                case .settings(let before, let after):
                    Section { Text(L10n.string("package.center.automatic-warning")) }
                    Section {
                        LabeledContent(L10n.string("package.center.update-policy"), value: after.updatePolicy.mobilePackageTitle)
                        if after.updatePolicy == .selected {
                            ForEach(after.packageUpdates.filter { value in before.settings.packageUpdates.first { $0.id == value.id }?.policy != value.policy }) { value in LabeledContent(value.name, value: value.policy.mobilePackageTitle) }
                        }
                    }
                case .saveSource(let value, _):
                    Section {
                        Text(L10n.string("package.center.source-trust-confirm", value.normalizedForEditing?.url ?? value.url))
                        if value.normalizedForEditing?.url.lowercased().hasPrefix("http:") == true { Text(L10n.string("package.center.source-http-warning")) }
                    }
                    Section { LabeledContent(L10n.string("package.center.source-name"), value: value.name); LabeledContent(L10n.string("package.center.source-address"), value: value.url) }
                case .removeSource(let value):
                    Section { Text(L10n.string("package.center.source-remove-warning", value.name)) }
                    Section { LabeledContent(L10n.string("package.center.source-address"), value: value.url) }
                }
            }
            .accessibilityIdentifier("mobile.package.confirmation")
            .navigationTitle(source.change.kind.mobilePackageTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.nas.service.cancel"), action: cancel).accessibilityIdentifier("mobile.package.confirm.cancel") }
                ToolbarItem(placement: .confirmationAction) {
                    Button(source.change.kind.mobilePackageTitle, role: source.change.kind == .removeSource ? .destructive : nil, action: confirm)
                        .disabled(source.activation != model.activation || !model.canPerform(source.change)).accessibilityIdentifier("mobile.package.confirm")
                }
            }
        }
    }
}

struct MobilePackageReadStatus: View {
    @Bindable var model: MobilePackageCenterModel
    let page: MobilePackageCenterModel.Page
    var body: some View {
        let section = model.section(page)
        switch section.phase {
        case .idle, .loading: Section { ProgressView(L10n.string("mobile.package.loading")).accessibilityIdentifier("mobile.package.loading") }
        case .error, .unavailable:
            Section {
                ContentUnavailableView {
                    Label {
                        Text(L10n.string("package.center.load-failed")).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "exclamationmark.triangle") }
                } description: { Text((model.errors[page] ?? .read).mobilePackageMessage) }
                Button(L10n.string("package.center.refresh")) { Task { await model.refresh(page) } }.accessibilityIdentifier("mobile.package.retry")
            }
        case .empty:
            Section {
                ContentUnavailableView {
                    Label {
                        Text(L10n.string(page == .sources ? "package.center.sources-empty" : "mobile.nas-details.packages.empty.title"))
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    } icon: { Image(systemName: "shippingbox") }
                } description: { Text(L10n.string(page == .sources ? "mobile.package.sources.emptyHint" : "mobile.package.emptyHint")) }
            }
        case .content: EmptyView()
        }
        if let error = model.errors[page], [.content, .empty].contains(section.phase) { Section { Text(error.mobilePackageMessage) } }
    }
}
struct MobilePackageActivitySection: View {
    @Bindable var model: MobilePackageCenterModel
    var body: some View {
        if !model.entries.isEmpty { Section(L10n.string("mobile.nas.service.activity")) { ForEach(model.entries) { MobilePackageRecord(model: model, entry: $0) } } }
    }
}
private struct MobilePackageRecord: View {
    @Bindable var model: MobilePackageCenterModel
    let entry: MobilePackageOperationStore.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.kind.mobilePackageTitle).font(.headline)
            if let package = model.installed.first(where: { MobilePackageOperationStore.digest($0.id) == entry.packageID }) {
                Text(package.name).font(.subheadline)
            }
            Text(model.recovery.isExecuting(entry.id) ? L10n.string("mobile.nas.service.working") : entry.mobilePackageMessage).accessibilityIdentifier("mobile.package.activity.\(entry.phase.rawValue)")
            Text(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale))).font(.caption).foregroundStyle(.secondary)
            if entry.isProtected {
                Button(L10n.string("package.center.refresh")) { Task { await model.refresh(entry.kind.page) } }
                    .disabled(model.isOperating).accessibilityIdentifier("mobile.package.recover")
            } else {
                Button(L10n.string("mobile.nas.service.removeRecord")) { model.removeRecord(entry.id) }.disabled(model.recovery.isExecuting(entry.id)).accessibilityIdentifier("mobile.package.removeRecord")
            }
        }
    }
}

extension NasPackageCenterSettings.UpdatePolicy { var mobilePackageTitle: String { mobilePackagePolicyTitle(rawValue) } }
extension NasPackageUpdatePreference.Policy { var mobilePackageTitle: String { mobilePackagePolicyTitle(rawValue) } }
private func mobilePackagePolicyTitle(_ value: String) -> String {
    let key = switch value { case "important": "package.center.policy.important"; case "latest": "package.center.policy.latest"; case "selected": "package.center.policy.selected"; default: "package.center.policy.manual" }
    return L10n.string(key)
}
extension NasPackagePreferenceKind {
    var mobilePackageTitle: String {
        let key = switch self { case .settings: "package.center.save-settings"; case .saveSource: "package.center.source-save"; case .removeSource: "package.center.source-remove" }
        return L10n.string(key)
    }
}
extension MobilePackageOperationStore.Kind {
    var mobilePackageTitle: String {
        if let action { return action.mobileControlTitle }
        let key = switch self { case .settings: "package.center.save-settings"; case .saveSource: "package.center.source-save"; default: "package.center.source-remove" }
        return L10n.string(key)
    }
}
extension NasPackage {
    var mobilePackageStatus: String {
        let key = switch status?.lowercased() { case "running", "active": "mobile.package.running"; case "stopped", "inactive", "disabled": "mobile.package.stopped"; default: "mobile.nas-health.status.unknown" }
        return L10n.string(key)
    }
}
extension MobilePackageCenterModel.Failure {
    var mobilePackageMessage: String {
        let key = switch self { case .read: "mobile.package.readError"; case .denied: "mobile.package.denied"; case .unavailable: "mobile.package.unavailable"; case .changed: "mobile.package.changed"; case .storage: "mobile.package.storageError"; case .trust: "mobile.nas.system.trustError" }
        return L10n.string(key)
    }
}
extension MobilePackageOperationStore.Entry {
    var mobilePackageMessage: String {
        let key: String
        switch phase {
        case .prepared: key = "mobile.nas.service.working"
        case .submitted: key = "mobile.package.pending"
        case .succeeded:
            key = switch kind {
            case .settings: "mobile.package.settingsSaved"
            case .saveSource: "mobile.package.sourceSaved"
            case .removeSource: "mobile.package.sourceRemoved"
            case .start: "package.start.completed"
            case .stop: "package.stop.completed"
            case .uninstall: "package.uninstall.completed"
            }
        case .cancelled: key = "mobile.nas.system.cancelled"
        case .failed:
            switch failure { case .denied: key = "mobile.package.denied"; case .unavailable: key = "mobile.package.unavailable"; case .changed: key = "mobile.package.changed"; default: key = "mobile.package.failed" }
        }
        return L10n.string(key)
    }
}
