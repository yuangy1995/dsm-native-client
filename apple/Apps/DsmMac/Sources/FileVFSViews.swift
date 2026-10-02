import DsmCore
import DsmLocalization
import SwiftUI

struct FileVFSProfileRow: View {
    @Bindable var model: WorkspaceModel
    let profile: FileVFSProfile
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onReauthorize: () -> Void
    let onAction: (VFSActionSheet) -> Void

    private var activity: WorkspaceModel.FileVFSConnectionActivity? { model.fileVFSConnectionActivities[profile.id] }
    private var busy: Bool { activity?.isBusy == true }
    private var needsReview: Bool { activity?.result?.requiresRefresh == true }

    private var stateTitle: String {
        L10n.string(profile.state == .connected ? "files.vfs.connected" : profile.state == .disconnected
            ? "files.vfs.disconnected" : "files.vfs.unknown")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 12) {
            Button {
                if profile.state == .connected { onOpen() }
                else if profile.state == .disconnected { connect() }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.alias)
                        Text(profile.protocolName).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: FileVFSProtocol.cloudProtocolIDs.contains(profile.protocolID) ? "cloud" : "network")
                        .foregroundStyle(.blue)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(profile.state == .unknown || busy || needsReview)
                .accessibilityIdentifier("remote-vfs.row." + profile.id)
            if busy {
                ProgressView().controlSize(.small)
                Text(L10n.string(needsReview ? "files.vfs.checkingConnection" : "files.vfs.connecting"))
                    .font(.callout).foregroundStyle(.secondary)
            } else if needsReview {
                Button(L10n.string("files.vfs.checkConnection")) { Task { await model.connectFileVFS(profile, review: true) } }
            } else {
                Text(stateTitle).font(.callout).foregroundStyle(.secondary)
            }
            if profile.state == .disconnected, !busy, !needsReview {
                Button(L10n.string("files.vfs.connect"), action: connect)
            }
            if profile.state == .connected, !busy, !needsReview {
                Button(L10n.string("files.vfs.browse"), action: onOpen)
                    .buttonStyle(MacToolbarButtonStyle())
                    .accessibilityIdentifier("remote-vfs.browse." + profile.id)
            }
            Menu { actions } label: { Label(L10n.string("files.vfs.actions"), systemImage: "ellipsis") }
                .labelStyle(.iconOnly).macThemedMenu().disabled(busy || needsReview)
                .help(L10n.string("files.vfs.actions")).accessibilityLabel(L10n.string("files.vfs.actions"))
        }
        if let error = activity?.error {
            Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        } else if !busy, let result = activity?.result {
            Text(needsReview ? L10n.string("files.vfs.connectPending")
                 : L10n.string(result.localizationKey ?? "files.vfs.connection-failed"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        }.padding(.vertical, 6).macDataRowSurface().contextMenu { actions.disabled(busy || needsReview) }
    }
    @ViewBuilder private var actions: some View {
        if profile.state == .connected {
            Button(L10n.string("files.vfs.disconnect")) {
                onAction(.init(change: .disconnect(profile), title: L10n.string("files.vfs.disconnect")))
            }
        } else if profile.state == .disconnected {
            Button(L10n.string("files.vfs.connect"), action: connect)
        }
        if ["ftp", "sftp", "dav", "davs"].contains(profile.protocolID) {
            Button(L10n.string("files.vfs.edit"), action: onEdit).disabled(profile.state == .unknown)
        }
        if FileVFSProtocol.cloudProtocolIDs.contains(profile.protocolID) {
            Button(L10n.string("files.vfs.reauthorize"), action: onReauthorize)
        }
        Button(L10n.string("files.vfs.remove"), role: .destructive) {
            onAction(.init(change: .removeSavedProfile(profile), title: L10n.string("files.vfs.remove")))
        }.disabled(profile.state != .disconnected)
    }
    private func connect() {
        Task { await model.connectFileVFS(profile) }
    }
}

struct VFSActionSheet: Identifiable {
    let id = UUID()
    let change: FileVFSChange
    let title: String
}

struct FileVFSActionView: View {
    let model: WorkspaceModel
    let sheet: VFSActionSheet
    @Environment(\.dismiss) private var dismiss
    @State private var access: FileStationAdvancedAccess?
    @State private var submitted = false
    @State private var busy = false
    @State private var result: MutationResult?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sheet.title).font(.title2.bold())
            if let profile {
                Text(profile.alias).font(.headline)
                Text(profile.protocolName).foregroundStyle(.secondary)
                if let hostname = profile.hostname { Text(hostname).textSelection(.enabled) }
            }
            if let warningKey { Text(L10n.string(warningKey)).fixedSize(horizontal: false, vertical: true) }
            if access?.writesEnabled != true { Text(L10n.string("files.advanced.permissionUnavailable")).foregroundStyle(.secondary) }
            if let error { Text(error).foregroundStyle(.red) }
            if let result { FileVFSResultView(result: result) }
            HStack {
                Button(L10n.string("files.common.close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if result?.requiresRefresh == true {
                    Button(L10n.string("files.permissions.review")) { Task { await run(review: true) } }.disabled(busy)
                } else {
                    Button(sheet.title) { Task { await run(review: false) } }.buttonStyle(.borderedProminent)
                        .disabled(submitted || busy || access?.writesEnabled != true)
                }
            }
        }.padding(24).frame(width: 540).task { access = try? await model.loadFileStationAdvancedAccess() }
    }
    private var profile: FileVFSProfile? {
        switch sheet.change {
        case .connect(let profile), .disconnect(let profile), .removeSavedProfile(let profile): profile
        default: nil
        }
    }
    private var warningKey: String? {
        switch sheet.change {
        case .disconnect: "files.vfs.disconnectWarning"
        case .removeSavedProfile: "files.vfs.removeWarning"
        default: nil
        }
    }
    private func run(review: Bool) async {
        guard !busy else { return }; busy = true; submitted = true; error = nil; defer { busy = false }
        do {
            result = try await model.changeFileVFS(sheet.change, review: review)
            if result?.status == .confirmedSuccess { dismiss() }
        }
        catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.vfs.connection-failed") }
    }
}

struct FileVFSEditor: View {
    let model: WorkspaceModel
    let profile: FileVFSProfile?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var addressIsFocused: Bool
    @State private var protocols: [FileVFSProtocol] = []
    @State private var cloudProtocol: FileVFSProtocol?
    @State private var cloudDidConnect = false
    @State private var baseline: FileVFSDetail?
    @State private var configuration = FileVFSConfiguration(protocolID: "", hostname: "", port: 0, alias: "", account: "")
    @State private var password = ""
    @State private var replacesPassword = false
    @State private var confirmedCleartext = false
    @State private var loading = true
    @State private var busy = false
    @State private var access: FileStationAdvancedAccess?
    @State private var submitted: FileVFSChange?
    @State private var result: MutationResult?
    @State private var error: String?
    private var selectedProtocol: FileVFSProtocol? { protocols.first { $0.id == configuration.protocolID } }
    private var supported: Bool { selectedProtocol?.supportsServerSetup == true }
    private var cleartext: Bool { FileVFSForm.usesCleartext(configuration) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile == nil ? L10n.string("files.vfs.add") : L10n.string("files.vfs.edit")).font(.title2.bold())
            if loading { ProgressView().fillsAvailableContentArea() }
            else if protocols.isEmpty || (profile != nil && baseline == nil) {
                FileSettingsLoadError(error: error) { Task { await load() } }
            } else {
                Form {
                    Picker(L10n.string("files.vfs.protocol"), selection: Binding(get: { configuration.protocolID }, set: { value in
                        configuration.protocolID = value
                        if let selected = protocols.first(where: { $0.id == value }) { configuration.port = selected.defaultPort ?? 0 }
                    })) {
                        ForEach(protocols) { Text($0.name).tag($0.id) }
                    }.disabled(profile != nil)
                    if supported {
                        TextField(L10n.string("files.vfs.alias"), text: $configuration.alias)
                        TextField(L10n.string("files.vfs.hostname"), text: $configuration.hostname, prompt: Text(L10n.string("files.vfs.addressExample")))
                            .focused($addressIsFocused).onSubmit { resolveAddress() }
                            .accessibilityIdentifier("files.vfs.hostname")
                        TextField(L10n.string("files.vfs.port"), value: $configuration.port, format: .number.grouping(.never))
                        TextField(L10n.string("files.vfs.account"), text: $configuration.account)
                        if profile != nil { Toggle(L10n.string("files.vfs.replacePassword"), isOn: $replacesPassword) }
                        if profile == nil || replacesPassword { SecureField(L10n.string("files.vfs.password"), text: $password) }
                        if configuration.protocolID == "dav" || configuration.protocolID == "davs" {
                            TextField(L10n.string("files.vfs.folder"), text: $configuration.folder, prompt: Text(L10n.string("files.vfs.folderExample")))
                                .textFieldStyle(.roundedBorder)
                                .help(L10n.string("files.vfs.folderHint"))
                                .accessibilityIdentifier("files.vfs.folder")
                        }
                        DisclosureGroup(L10n.string("files.vfs.moreOptions")) {
                            TextField(L10n.string("files.vfs.filenameEncoding"), text: $configuration.codepage)
                            if configuration.protocolID == "ftp" {
                                Toggle(L10n.string("files.vfs.singleConnection"), isOn: $configuration.usesOneConnection)
                            }
                        }
                        if cleartext { Toggle(L10n.string("files.vfs.confirmCleartext"), isOn: $confirmedCleartext) }
                    } else if selectedProtocol?.supportsCloudAuthorization == true {
                        Button(L10n.string("files.vfs.authorizeCloud")) { cloudProtocol = selectedProtocol }
                    } else {
                        Text(L10n.string("files.advanced.unavailable")).foregroundStyle(.secondary)
                    }
                }.formStyle(.grouped).disabled(busy || submitted != nil)
                if access?.writesEnabled != true { Text(L10n.string("files.advanced.permissionUnavailable")).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let result { FileVFSResultView(result: result) }
            }
            HStack {
                Button(L10n.string("files.common.close")) { password = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(L10n.string(result?.requiresRefresh == true ? "files.vfs.checkingConnection" : "files.vfs.savingConnect"))
                        .accessibilityIdentifier("files.vfs.saveProgress")
                    Text(L10n.string(result?.requiresRefresh == true ? "files.vfs.checkingConnection" : "files.vfs.savingConnect"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if result?.requiresRefresh == true {
                    Button(L10n.string("files.permissions.review")) { Task { await save(review: true) } }.disabled(busy)
                } else {
                    Button(L10n.string("files.vfs.saveConnect")) { Task { await save(review: false) } }.buttonStyle(.borderedProminent)
                        .disabled(loading || busy || submitted != nil || !supported || access?.writesEnabled != true
                            || (cleartext && !confirmedCleartext) || configuration.hostname.isEmpty || configuration.alias.isEmpty)
                }
            }
        }.padding(24).frame(width: 650, height: 620).task { await load() }
            .sheet(item: $cloudProtocol, onDismiss: { if cloudDidConnect { dismiss() } }) {
                FileVFSCloudConnectionView(model: model, protocolID: $0.id, protocolName: $0.name, existing: nil,
                    onSuccess: { cloudDidConnect = true })
            }
            .onChange(of: addressIsFocused) { _, focused in if !focused { resolveAddress() } }
            .onChange(of: configuration) { _, _ in confirmedCleartext = false }
            .onChange(of: replacesPassword) { _, _ in password = "" }
            .onDisappear { password = "" }
    }
    private func resolveAddress() {
        guard !busy, submitted == nil, configuration.hostname.contains("://") else { return }
        do {
            configuration = try FileVFSForm.resolveAddress(configuration, protocols: protocols, editingProtocol: profile?.protocolID)
            error = nil
        } catch let error as FileVFSForm.ValidationError { self.error = L10n.string(error.resourceKey) }
        catch { self.error = L10n.string("files.vfs.invalidAddress") }
    }

    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do {
            protocols = try await model.listFileVFSProtocols()
            if let profile {
                let detail = try await model.loadFileVFSDetail(profile); baseline = detail; configuration = detail.configuration
            } else if let first = protocols.first(where: \.supportsServerSetup) ?? protocols.first {
                configuration.protocolID = first.id; configuration.port = first.defaultPort ?? 0
            }
            access = try await model.loadFileStationAdvancedAccess()
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.vfs.loadFailed") }
    }
    private func save(review: Bool) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false }
        do {
            let change: FileVFSChange
            if review, let submitted { change = submitted }
            else {
                let value = try FileVFSForm.configuration(configuration, protocols: protocols, editingProtocol: profile?.protocolID)
                guard !FileVFSForm.usesCleartext(value) || confirmedCleartext else { return }
                configuration = value
                change = baseline.map { .update(baseline: $0, configuration: value) } ?? .create(value)
                submitted = change
            }
            defer { password = "" }
            result = try await model.changeFileVFS(change, password: review ? nil : profile == nil || replacesPassword ? password : nil, review: review)
            if result?.status == .confirmedFailure { submitted = nil }
            if result?.status == .confirmedSuccess { dismiss() }
        } catch let error as FileVFSForm.ValidationError {
            self.error = L10n.string(error.resourceKey)
        } catch {
            // Repository 对已提交但结果未知的操作返回待确认结果；抛错表示未发送或明确未生效。
            if !review { submitted = nil }
            self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.vfs.connection-failed")
        }
    }
}

struct FileVFSResultView: View {
    let result: MutationResult
    var body: some View {
        Text(result.localizationKey.map { L10n.string($0) } ?? (result.status == .confirmedSuccess ? L10n.string("files.vfs.completed")
            : result.requiresRefresh ? L10n.string("files.vfs.pending") : L10n.string("files.vfs.connection-failed")))
            .fixedSize(horizontal: false, vertical: true)
    }
}
