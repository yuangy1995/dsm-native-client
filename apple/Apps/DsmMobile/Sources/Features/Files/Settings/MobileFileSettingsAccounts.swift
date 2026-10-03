import DsmCore
import DsmLocalization
import SwiftUI

struct MobileFilePolicyAccountPicker: View {
    let model: MobileFileSettingsModel
    @Binding var selection: Set<FileStationPolicyAccountID>
    @Environment(\.dismiss) private var dismiss
    @State private var kind = FileStationPrincipal.Kind.user
    @State private var query = ""
    @State private var rows: [FileStationPolicyAccount] = []
    @State private var offset = 0
    @State private var total = 0
    @State private var loading = false
    @State private var failed = false
    @State private var generation = UUID()
    var body: some View {
        NavigationStack {
            List {
                MobileFileAccountKindPicker(kind: $kind)
                if loading && rows.isEmpty { ProgressView() }
                if failed { Button(L10n.string("files.common.retry")) { Task { await load(reset: true) } } }
                else if !loading && rows.isEmpty { Text(L10n.string("files.principals.emptyDetail")) }
                ForEach(rows) { row in
                    Toggle(row.name, isOn: Binding(get: { row.isAdministrator || selection.contains(row.id) }, set: { selected in
                        if selected { selection.insert(row.id) } else { selection.remove(row.id) }
                    })).disabled(row.isAdministrator)
                }
                if offset < total { Button(L10n.string("files.principals.more")) { Task { await load(reset: false) } }.disabled(loading) }
                Text(L10n.string("files.settings.adminAccess")).foregroundStyle(.secondary)
            }.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("files.principals.search"))
                .navigationTitle(L10n.string("files.settings.selectedAccounts")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("files.common.close")) { dismiss() } } }
                .task(id: kind.rawValue + ":" + query) { await load(reset: true) }
                .onDisappear { generation = UUID() }
        }
    }
    private func load(reset: Bool) async {
        if reset { generation = UUID(); rows = []; offset = 0; total = 0 } else if loading { return }
        let token = generation, start = offset, kind = kind, query = query
        loading = true; failed = false
        defer { if token == generation { loading = false } }
        do {
            let page = try await model.read { try await $0.listFileStationPolicyAccounts(kind: kind, query: query, offset: start, limit: 200) }
            guard token == generation else { return }
            let ids = Set(rows.map(\.id)); rows += page.items.filter { !ids.contains($0.id) }; offset = page.nextOffset; total = page.total
        } catch is CancellationError { }
        catch { if token == generation { failed = true } }
    }
}

struct MobileFileAccountKindPicker: View {
    @Binding var kind: FileStationPrincipal.Kind
    var body: some View {
        Picker(L10n.string("files.settings.accountType"), selection: $kind) {
            Text(L10n.string("files.principals.user")).tag(FileStationPrincipal.Kind.user)
            Text(L10n.string("files.principals.group")).tag(FileStationPrincipal.Kind.group)
        }.pickerStyle(.segmented)
    }
}

struct MobileFileMountSettingsView: View {
    let model: MobileFileSettingsModel
    let profileID: UUID
    @State private var baseline: FileStationMountAccessScope?
    @State private var value = FileStationMountAccessScope.administrators
    @State private var failed = false
    var body: some View {
        Group {
            if let baseline {
                Form {
                    Section {
                        Picker(L10n.string("files.settings.remoteAccess"), selection: $value) {
                            Text(L10n.string("files.settings.administrators")).tag(FileStationMountAccessScope.administrators)
                            Text(L10n.string("files.settings.everyone")).tag(FileStationMountAccessScope.everyone)
                            Text(L10n.string("files.settings.selectedAccounts")).tag(FileStationMountAccessScope.selected)
                        }.disabled(!model.canWrite || model.isBlocked("mountAccess"))
                        NavigationLink(L10n.string("files.settings.manageLocalAccounts")) { MobileFileMountAccountList(model: model) }
                    } footer: {
                        Text(L10n.string("files.settings.remoteAccessScope"))
                        if baseline != .selected { Text(L10n.string("files.settings.localAccountScope")) }
                    }
                    MobileFileSettingsCommit(model: model, target: "mountAccess", change: value == baseline ? nil
                        : .mountAccess(baseline: baseline, updated: value, profileID: profileID), saved: load)
                }
            } else if failed { MobileFileSettingsLoadError { Task { await load() } } }
            else { ProgressView(L10n.string("mobile.file-settings.loading")).fillsAvailableContentArea().accessibilityIdentifier("files.settings.loading") }
        }.navigationTitle(L10n.string("files.settings.remoteAccess")).navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel(L10n.string("files.sharing.refresh")).disabled(model.busy) } }
    }
    private func load() async {
        do { let result = try await model.read { try await $0.loadFileStationMountAccess() }; baseline = result; value = result; failed = false }
        catch is CancellationError { }
        catch { baseline = nil; failed = true }
    }
}

private struct MobileFileMountAccountList: View {
    let model: MobileFileSettingsModel
    @State private var kind = FileStationPrincipal.Kind.user
    @State private var source = FileStationMountAccountSource.local
    @State private var directories: [FileStationMountDirectory] = [.init(source: .local, name: "")]
    @State private var directoryError = false
    @State private var query = ""
    @State private var rows: [FileStationMountAccount] = []
    @State private var offset = 0
    @State private var total = 0
    @State private var loading = false
    @State private var failed = false
    @State private var generation = UUID()
    @State private var selected: FileStationMountAccount?
    var body: some View {
        List {
            if directories.count > 1 {
                Picker(L10n.string("files.settings.accountSource"), selection: $source) {
                    ForEach(directories) { directory in Text(directoryName(directory)).tag(directory.source) }
                }
            }
            if directoryError {
                Section {
                    Text(L10n.string("files.settings.directoryUnavailable"))
                    Button(L10n.string("files.common.retry")) { Task { await loadDirectories() } }
                }
            }
            MobileFileAccountKindPicker(kind: $kind)
            if loading && rows.isEmpty { ProgressView() }
            if failed { Section { Text(L10n.string("files.principals.loadFailed")); Button(L10n.string("files.common.retry")) { Task { await load(reset: true) } } } }
            else if !loading && rows.isEmpty { Text(L10n.string("files.principals.emptyDetail")) }
            ForEach(rows) { row in
                Button { selected = row } label: {
                    VStack(alignment: .leading) {
                        Text(row.name)
                        Text(L10n.string(row.enabled ? "files.settings.accountAllowed" : "files.settings.accountDenied")).foregroundStyle(.secondary)
                    }.frame(minHeight: 44)
                }.disabled(!row.canModify)
            }
            if offset < total { Button(L10n.string("files.principals.more")) { Task { await load(reset: false) } }.disabled(loading) }
        }.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("files.principals.search"))
            .navigationTitle(L10n.string("files.settings.manageLocalAccounts")).navigationBarTitleDisplayMode(.inline)
            .task { await loadDirectories() }
            .task(id: source.id + ":" + kind.rawValue + ":" + query) { await load(reset: true) }
            .onDisappear { generation = UUID() }
            .sheet(item: $selected, onDismiss: { Task { await load(reset: true) } }) { MobileFileMountAccountEditor(model: model, account: $0) }
    }
    private func directoryName(_ directory: FileStationMountDirectory) -> String {
        switch directory.source { case .local: L10n.string("files.settings.source.local"); case .ldap: L10n.string("files.settings.source.ldap"); case .domain: directory.name }
    }
    private func loadDirectories() async {
        do {
            let result = try await model.read { try await $0.loadFileStationMountDirectories() }
            directories = result.items; directoryError = result.hasUnavailableSources
            if !directories.contains(where: { $0.source == source }) { source = .local }
        } catch is CancellationError { }
        catch { directoryError = true }
    }
    private func load(reset: Bool) async {
        if reset { generation = UUID(); rows = []; offset = 0; total = 0 } else if loading { return }
        let token = generation, start = offset, source = source, kind = kind, query = query
        loading = true; failed = false
        defer { if token == generation { loading = false } }
        do {
            let page = try await model.read { try await $0.listFileStationMountAccounts(source: source, kind: kind, query: query, offset: start, limit: 200) }
            guard token == generation else { return }
            let ids = Set(rows.map(\.id)); rows += page.items.filter { !ids.contains($0.id) }; offset = page.nextOffset; total = page.total
        } catch is CancellationError { }
        catch { if token == generation { failed = true } }
    }
}

private struct MobileFileMountAccountEditor: View {
    let model: MobileFileSettingsModel
    let account: FileStationMountAccount
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    init(model: MobileFileSettingsModel, account: FileStationMountAccount) { self.model = model; self.account = account; _enabled = State(initialValue: account.enabled) }
    private var change: FileStationSettingsChange { .mountAccount(baseline: account, enabled: enabled) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(account.name).textSelection(.enabled)
                    Toggle(L10n.string("files.settings.allowRemoteAccess"), isOn: $enabled)
                        .disabled(!account.canModify || !model.canWrite || model.isBlocked(MobileFileSettingsModel.target(change)))
                }
                MobileFileSettingsCommit(model: model, target: MobileFileSettingsModel.target(change), change: account.enabled == enabled ? nil : change) { dismiss() }
            }.navigationTitle(L10n.string("files.settings.editAccountPermissions")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("files.common.close")) { dismiss() } } }
        }
    }
}

struct MobileFileBandwidthList: View {
    let model: MobileFileSettingsModel
    @State private var ownerType = FileStationBandwidthEntry.OwnerType.localUser
    @State private var rows: [FileStationBandwidthEntry] = []
    @State private var query = ""
    @State private var offset = 0
    @State private var total = 0
    @State private var loading = false
    @State private var failed = false
    @State private var generation = UUID()
    @State private var selected: FileStationBandwidthEntry?
    private var filtered: [FileStationBandwidthEntry] { rows.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List {
            Picker(L10n.string("files.settings.accountType"), selection: $ownerType) {
                ForEach(FileStationBandwidthEntry.OwnerType.allCases, id: \.self) { Text(L10n.string(Self.ownerKey($0))).tag($0) }
            }
            if loading && rows.isEmpty { ProgressView() }
            if failed { Section { Text(L10n.string("files.settings.loadFailed")); Button(L10n.string("files.common.retry")) { Task { await load(reset: true) } } } }
            else if !loading && filtered.isEmpty { Text(L10n.string(query.isEmpty ? "files.settings.noAccounts" : "files.principals.emptyDetail")) }
            ForEach(filtered) { row in
                Button { selected = row } label: {
                    VStack(alignment: .leading) { Text(row.name); Text(Self.policyTitle(row)).foregroundStyle(.secondary) }.frame(minHeight: 44)
                }
            }
            if offset < total { Button(L10n.string("files.principals.more")) { Task { await load(reset: false) } }.disabled(loading) }
        }.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("files.principals.search"))
            .navigationTitle(L10n.string("files.settings.speed")).navigationBarTitleDisplayMode(.inline)
            .refreshable { await load(reset: true) }.task(id: ownerType) { await load(reset: true) }
            .onDisappear { generation = UUID() }
            .sheet(item: $selected, onDismiss: { Task { await load(reset: true) } }) { MobileFileBandwidthEditor(model: model, baseline: $0) }
    }
    static func policyTitle(_ row: FileStationBandwidthEntry) -> String {
        switch row.policy {
        case .notConfigured: L10n.string([.localUser, .ldapUser, .domainUser].contains(row.ownerType) ? "files.settings.groupBandwidth" : "files.settings.noBandwidthConfiguration")
        case .disabled: L10n.string("files.settings.unlimited")
        case .enabled: L10n.string("files.settings.alwaysLimit")
        case .scheduled: L10n.string("files.settings.scheduleLimit")
        }
    }
    private static func ownerKey(_ type: FileStationBandwidthEntry.OwnerType) -> String {
        switch type {
        case .localUser: "files.settings.localUsers"; case .localGroup: "files.settings.localGroups"
        case .domainUser: "files.settings.domainUsers"; case .domainGroup: "files.settings.domainGroups"
        case .ldapUser: "files.settings.ldapUsers"; case .ldapGroup: "files.settings.ldapGroups"
        }
    }
    private func load(reset: Bool) async {
        if reset { generation = UUID(); rows = []; offset = 0; total = 0 } else if loading { return }
        let token = generation, start = offset, ownerType = ownerType
        loading = true; failed = false
        defer { if token == generation { loading = false } }
        do {
            let page = try await model.read { try await $0.listFileStationBandwidth(ownerType: ownerType, offset: start, limit: 200) }
            guard token == generation else { return }
            let ids = Set(rows.map(\.id)); rows += page.items.filter { !ids.contains($0.id) }; offset = page.nextOffset; total = page.total
        } catch is CancellationError { }
        catch { if token == generation { failed = true } }
    }
}

struct MobileFileBandwidthEditor: View {
    let model: MobileFileSettingsModel
    let baseline: FileStationBandwidthEntry
    @State private var value: FileStationBandwidthEntry
    @Environment(\.dismiss) private var dismiss
    init(model: MobileFileSettingsModel, baseline: FileStationBandwidthEntry) { self.model = model; self.baseline = baseline; _value = State(initialValue: baseline) }
    private var change: FileStationSettingsChange { .bandwidth(baseline: baseline, updated: value) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(baseline.name).textSelection(.enabled)
                    MobileFileBandwidthPolicyPicker(value: $value.policy, inheritedTitle: baseline.policy == .notConfigured ? MobileFileBandwidthList.policyTitle(baseline) : nil)
                    if value.policy == .enabled || value.policy == .scheduled {
                        Text(L10n.string("files.settings.rateUnits")).foregroundStyle(.secondary)
                        rateField("files.settings.uploadLimit", value: $value.uploadLimit)
                        rateField("files.settings.downloadLimit", value: $value.downloadLimit)
                    }
                    if value.policy == .scheduled {
                        rateField("files.settings.alternateUpload", value: $value.alternateUploadLimit)
                        rateField("files.settings.alternateDownload", value: $value.alternateDownloadLimit)
                        NavigationLink(L10n.string("files.settings.scheduleLimit")) { MobileFileScheduleEditor(value: $value.schedule, perAccount: true) }
                    }
                    if !Self.validRates(value) { Text(L10n.string("files.settings.invalidRate")).foregroundStyle(.red) }
                }.disabled(!model.canWrite || model.isBlocked(MobileFileSettingsModel.target(change)))
                MobileFileSettingsCommit(model: model, target: MobileFileSettingsModel.target(change), change: value == baseline || value.policy == .notConfigured || !Self.validRates(value) ? nil : change) { dismiss() }
            }.scrollDismissesKeyboard(.interactively)
                .navigationTitle(L10n.string("files.settings.editLimit")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("files.common.close")) { dismiss() } } }
                .onChange(of: value.policy) { _, policy in if policy == .scheduled && value.schedule.isEmpty { value.schedule = String(repeating: "1", count: 168) } }
        }
    }
    private func rateField(_ key: String, value: Binding<Int>) -> some View {
        LabeledContent(L10n.string(key)) {
            TextField(L10n.string(key), value: value, format: .number.locale(L10n.locale))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(minWidth: 72)
        }
    }
    static func validRates(_ value: FileStationBandwidthEntry) -> Bool { [value.uploadLimit, value.downloadLimit, value.alternateUploadLimit, value.alternateDownloadLimit].allSatisfy { $0 == 0 || (10...999_999_999).contains($0) } }
}
