import AppKit
import DsmCore
import DsmLocalization
import SwiftUI

struct FileStationSettingsView: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("files.settings.title")).font(.title2.bold())
                Spacer()
                Button(L10n.string("files.common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TabView(selection: $selectedTab) {
                FileStationGeneralSettings(model: model).tabItem { Text(L10n.string("files.settings.general")) }.tag(0)
                FileStationMountSettings(model: model).tabItem { Text(L10n.string("files.settings.remoteAccess")) }.tag(1)
                FileStationBandwidthView(model: model).tabItem { Text(L10n.string("files.settings.speed")) }.tag(2)
                FileStationThemeSettings(model: model).tabItem { Text(L10n.string("files.settings.appearance")) }.tag(3)
            }
        }.padding(24).frame(width: 800, height: 700)
    }
}

private struct FileStationGeneralSettings: View {
    let model: WorkspaceModel
    @State private var baseline: FileStationSettings?
    @State private var error: String?
    @State private var loading = true
    var body: some View {
        Group {
            if let baseline { FileStationGeneralForm(model: model, baseline: baseline) }
            else if loading { ProgressView().fillsAvailableContentArea() }
            else { FileSettingsLoadError(error: error) { Task { await load() } } }
        }.task { if baseline == nil { await load() } }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { baseline = try await model.loadFileStationSettings() }
        catch { self.error = (error as? AppError)?.safeUserMessage }
    }
}

private struct FileStationGeneralForm: View {
    let model: WorkspaceModel
    let baseline: FileStationSettings
    @State private var value: FileStationSettings
    @State private var locked = false
    @State private var picker: Int?
    init(model: WorkspaceModel, baseline: FileStationSettings) {
        self.model = model; self.baseline = baseline; _value = State(initialValue: baseline)
    }
    var body: some View {
        VStack {
            Form {
                Toggle(L10n.string("files.settings.recordTransfers"), isOn: $value.recordsTransfers)
                Toggle(L10n.string("files.settings.defaultPermissions"), isOn: $value.usesDefaultPermissions)
                Toggle(L10n.string("files.settings.showAccounts"), isOn: $value.showsAccounts)
                if value.usesCustomSharingPage != nil {
                    Toggle(L10n.string("files.settings.customSharingPage"), isOn: Binding(
                        get: { value.usesCustomSharingPage == true }, set: { value.usesCustomSharingPage = $0 }))
                }
                accessPicker(L10n.string("files.settings.sharePermission"), value: $value.sharing)
                if value.sharing == .selected {
                    Button(L10n.string("files.settings.chooseAccounts", String(value.sharingAccounts.count))) { picker = 0 }
                }
                accessPicker(L10n.string("files.settings.requestPermission"), value: $value.fileRequests)
                if value.fileRequests == .selected {
                    Button(L10n.string("files.settings.chooseAccounts", String(value.requestAccounts.count))) { picker = 1 }
                }
                TextField(L10n.string("files.settings.linkLimit"), value: $value.defaultLinkLimit, format: .number.locale(L10n.locale))
                accessPicker(L10n.string("files.settings.mountPermission"), value: $value.remoteMounts, selected: false)
                accessPicker(L10n.string("files.settings.isoPermission"), value: $value.isoMounts, selected: false)
                Picker(L10n.string("files.settings.speedPolicy"), selection: $value.bandwidth) {
                    Text(L10n.string("files.settings.unlimited")).tag(FileStationBandwidthPolicy.disabled)
                    Text(L10n.string("files.settings.alwaysLimit")).tag(FileStationBandwidthPolicy.enabled)
                    Text(L10n.string("files.settings.scheduleLimit")).tag(FileStationBandwidthPolicy.scheduled)
                }
                if value.bandwidth == .scheduled { FileStationScheduleEditor(value: $value.schedule, perAccount: false) }
            }.formStyle(.grouped).disabled(locked)
            FileSettingsCommitControls(model: model, change: value == baseline ? nil : .general(baseline: baseline, updated: value), locked: $locked)
        }.padding(12)
            .onChange(of: value.bandwidth) { _, policy in
                if policy == .scheduled && value.schedule.isEmpty { value.schedule = String(repeating: "1", count: 168) }
            }
            .sheet(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } })) {
                FileStationPolicyAccountPicker(model: model,
                    selection: Binding(get: { picker == 0 ? value.sharingAccounts : value.requestAccounts }, set: {
                        if picker == 0 { value.sharingAccounts = $0 } else { value.requestAccounts = $0 }
                    })) { picker = nil }
            }
    }
    private func accessPicker(_ title: String, value: Binding<FileStationAccessScope>, selected: Bool = true) -> some View {
        Picker(title, selection: value) {
            Text(L10n.string("files.settings.administrators")).tag(FileStationAccessScope.administrators)
            Text(L10n.string("files.settings.everyone")).tag(FileStationAccessScope.everyone)
            if selected { Text(L10n.string("files.settings.selectedAccounts")).tag(FileStationAccessScope.selected) }
        }
    }
}

private struct FileStationMountSettings: View {
    let model: WorkspaceModel
    @State private var baseline: FileStationMountAccessScope?
    @State private var value = FileStationMountAccessScope.administrators
    @State private var loading = true
    @State private var error: String?
    @State private var locked = false
    @State private var showsAccounts = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let baseline {
                Picker(L10n.string("files.settings.remoteAccess"), selection: $value) {
                    Text(L10n.string("files.settings.administrators")).tag(FileStationMountAccessScope.administrators)
                    Text(L10n.string("files.settings.everyone")).tag(FileStationMountAccessScope.everyone)
                    Text(L10n.string("files.settings.selectedAccounts")).tag(FileStationMountAccessScope.selected)
                }.disabled(locked)
                Button(L10n.string("files.settings.manageLocalAccounts")) { showsAccounts = true }.disabled(locked)
                Text(L10n.string("files.settings.remoteAccessScope")).foregroundStyle(.secondary)
                Spacer()
                FileSettingsCommitControls(model: model,
                    change: value == baseline ? nil : .mountAccess(baseline: baseline, updated: value, profileID: model.profile.id), locked: $locked)
            } else if loading { ProgressView().fillsAvailableContentArea() }
            else { FileSettingsLoadError(error: error) { Task { await load() } } }
        }.padding(20).task { if baseline == nil { await load() } }
            .sheet(isPresented: $showsAccounts) { FileStationMountAccountList(model: model) }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { let loaded = try await model.loadFileStationMountAccess(); baseline = loaded; value = loaded }
        catch { self.error = (error as? AppError)?.safeUserMessage }
    }
}

private struct FileStationThemeSettings: View {
    let model: WorkspaceModel
    @State private var baseline: FileStationSharingTheme?
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        Group {
            if let baseline { FileStationThemeForm(model: model, baseline: baseline) }
            else if loading { ProgressView().fillsAvailableContentArea() }
            else { FileSettingsLoadError(error: error) { Task { await load() } } }
        }.task { if baseline == nil { await load() } }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do { baseline = try await model.loadFileStationSharingTheme() }
        catch { self.error = (error as? AppError)?.safeUserMessage }
    }
}

private struct FileStationThemeForm: View {
    let model: WorkspaceModel
    let baseline: FileStationSharingTheme
    @State private var value: FileStationSharingTheme
    @State private var locked = false
    @State private var imageKind: FileStationThemeImage.Kind?
    init(model: WorkspaceModel, baseline: FileStationSharingTheme) {
        self.model = model; self.baseline = baseline; _value = State(initialValue: baseline)
    }
    var body: some View {
        VStack {
            Form {
                Section {
                    Button(L10n.string("files.theme.chooseLogo")) { imageKind = .logo }
                    if let image = value.logoImage { Text(image.name).foregroundStyle(.secondary) }
                    Toggle(L10n.string("files.settings.keepLogo"), isOn: $value.customLogo)
                    Picker(L10n.string("files.settings.logoPosition"), selection: $value.logoPosition) {
                        Text(L10n.string("files.settings.topLeft")).tag(FileStationSharingTheme.LogoPosition.topLeft)
                        Text(L10n.string("files.settings.topRight")).tag(FileStationSharingTheme.LogoPosition.topRight)
                        Text(L10n.string("files.settings.bottomLeft")).tag(FileStationSharingTheme.LogoPosition.bottomLeft)
                        Text(L10n.string("files.settings.bottomRight")).tag(FileStationSharingTheme.LogoPosition.bottomRight)
                    }.disabled(!value.customLogo)
                }
                Section {
                    Button(L10n.string("files.theme.chooseBackground")) { imageKind = .background }
                    if let image = value.backgroundImage { Text(image.name).foregroundStyle(.secondary) }
                    Toggle(L10n.string("files.settings.keepBackground"), isOn: $value.customBackground)
                    Picker(L10n.string("files.settings.backgroundPosition"), selection: $value.backgroundPosition) {
                        Text(L10n.string("files.settings.center")).tag(FileStationSharingTheme.BackgroundPosition.center)
                        Text(L10n.string("files.settings.fill")).tag(FileStationSharingTheme.BackgroundPosition.fill)
                        Text(L10n.string("files.settings.fit")).tag(FileStationSharingTheme.BackgroundPosition.fit)
                        Text(L10n.string("files.settings.stretch")).tag(FileStationSharingTheme.BackgroundPosition.stretch)
                        Text(L10n.string("files.settings.tile")).tag(FileStationSharingTheme.BackgroundPosition.tile)
                    }.disabled(!value.customBackground)
                }
                ColorPicker(L10n.string("files.settings.backgroundColor"), selection: color, supportsOpacity: false)
                TextField(L10n.string("files.settings.footer"), text: $value.footer, axis: .vertical).lineLimit(2...5)
                Toggle(L10n.string("files.settings.footerHTML"), isOn: $value.footerUsesHTML)
                if value.footer.count > 512 || value.footer.contains(where: { $0 == "\n" || $0 == "\r" }) {
                    Text(L10n.string("files.settings.invalidTheme")).foregroundStyle(.red)
                }
            }.formStyle(.grouped).disabled(locked)
            if needsImage { Text(L10n.string("files.theme.chooseRequired")).foregroundStyle(.secondary) }
            FileSettingsCommitControls(model: model, change: value == baseline || needsImage ? nil : .theme(baseline: baseline, updated: value), locked: $locked)
        }.padding(12)
            .sheet(item: $imageKind) { kind in
                FileStationThemeImagePicker(model: model, kind: kind) { image in
                    if kind == .logo { value.logoImage = image; value.customLogo = true }
                    else { value.backgroundImage = image; value.customBackground = true }
                }
            }
            .onChange(of: value.customLogo) { _, enabled in if !enabled { value.logoImage = nil } }
            .onChange(of: value.customBackground) { _, enabled in if !enabled { value.backgroundImage = nil } }
    }
    private var needsImage: Bool {
        (value.customLogo && !baseline.customLogo && value.logoImage == nil)
            || (value.customBackground && !baseline.customBackground && value.backgroundImage == nil)
    }
    private var color: Binding<Color> {
        Binding(get: {
            let number = UInt32(value.backgroundColor.dropFirst(), radix: 16) ?? 0xFFFFFF
            return Color(red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255)
        }, set: { chosen in
            guard let rgb = NSColor(chosen).usingColorSpace(.sRGB) else { return }
            value.backgroundColor = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
        })
    }
}

struct FileSettingsLoadError: View {
    let error: String?
    let retry: () -> Void
    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("files.settings.loadFailed"), systemImage: "exclamationmark.triangle")
        } description: { Text(error ?? L10n.string("files.advanced.readFailed")) } actions: {
            Button(L10n.string("files.sharing.refresh"), action: retry)
        }.fillsAvailableContentArea()
    }
}

struct FileSettingsCommitControls: View {
    let model: WorkspaceModel
    let change: FileStationSettingsChange?
    @Binding var locked: Bool
    @State private var access: FileStationAdvancedAccess?
    @State private var busy = false
    @State private var submitted: FileStationSettingsChange?
    @State private var result: MutationResult?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if access?.writesEnabled != true || access?.isAdministrator != true {
                Text(access?.isAdministrator == false ? L10n.string("files.advanced.adminRequired") : L10n.string("files.advanced.permissionUnavailable"))
                    .foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let result {
                Text(result.status == .confirmedSuccess ? L10n.string("files.settings.saved") : result.requiresRefresh
                    ? L10n.string("files.settings.pending") : L10n.string("files.settings.failed"))
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                if result?.requiresRefresh == true {
                    Button(L10n.string("files.permissions.review")) { Task { await save(review: true) } }.disabled(busy)
                } else {
                    Button(L10n.string("files.settings.save")) { Task { await save(review: false) } }.buttonStyle(.borderedProminent)
                        .disabled(change == nil || submitted != nil || busy || access?.writesEnabled != true || access?.isAdministrator != true)
                }
            }
        }.task { access = try? await model.loadFileStationAdvancedAccess() }
    }
    private func save(review: Bool) async {
        guard !busy, let request = review ? submitted : change else { return }
        busy = true; locked = true; submitted = request; error = nil
        defer { busy = false }
        do { result = try await model.changeFileStationSettings(request, review: review) }
        catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.settings.failed") }
    }
}

private struct FileStationPolicyAccountPicker: View {
    let model: WorkspaceModel
    @Binding var selection: Set<FileStationPolicyAccountID>
    let close: () -> Void
    @State private var kind = FileStationPrincipal.Kind.user
    @State private var query = ""
    @State private var rows: [FileStationPolicyAccount] = []
    @State private var offset = 0
    @State private var total = 0
    @State private var loading = true
    @State private var error: String?
    @State private var generation = UUID()
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("files.settings.selectedAccounts")).font(.title2.bold())
            Picker(L10n.string("files.settings.accountType"), selection: $kind) {
                Text(L10n.string("files.principals.user")).tag(FileStationPrincipal.Kind.user)
                Text(L10n.string("files.principals.group")).tag(FileStationPrincipal.Kind.group)
            }.pickerStyle(.segmented).labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
            TextField(L10n.string("files.principals.search"), text: $query)
            if loading && rows.isEmpty { ProgressView().fillsAvailableContentArea() }
            else if error != nil { FileSettingsLoadError(error: error) { Task { await load(reset: true) } } }
            else if rows.isEmpty {
                ContentUnavailableView(L10n.string("files.principals.empty"), systemImage: "person.2",
                    description: Text(L10n.string("files.principals.emptyDetail"))).fillsAvailableContentArea()
            } else {
                List(rows) { row in
                    Toggle(row.name, isOn: Binding(get: { row.isAdministrator || selection.contains(row.id) }, set: { selected in
                        if selected { selection.insert(row.id) } else { selection.remove(row.id) }
                    })).disabled(row.isAdministrator)
                }
                if offset < total { Button(L10n.string("files.principals.more")) { Task { await load(reset: false) } }.disabled(loading) }
            }
            Text(L10n.string("files.settings.adminAccess")).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L10n.string("files.common.close"), action: close).keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 500, height: 480)
            .task(id: kind.rawValue + ":" + query) { await load(reset: true) }
            .onDisappear { generation = UUID() }
    }
    private func load(reset: Bool) async {
        let token: UUID
        if reset { token = UUID(); generation = token; rows = []; offset = 0; total = 0 }
        else { guard !loading else { return }; token = generation }
        loading = true; error = nil
        do {
            let page = try await model.listFileStationPolicyAccounts(kind: kind, query: query, offset: offset)
            guard token == generation, !Task.isCancelled else { return }
            let ids = Set(rows.map(\.id)); rows += page.items.filter { !ids.contains($0.id) }; offset = page.nextOffset; total = page.total
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.principals.loadFailed")
        }
        loading = false
    }
}
