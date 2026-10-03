import DsmCore
import DsmLocalization
import DsmNetwork
import SwiftUI

struct MobileRemoteMountEditor: View {
    @Bindable var model: MobileRemoteLocationsModel
    let repository: DsmFileRepository
    let existing: RemoteMountConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var protocolType: RemoteMountProtocol = .smb
    @State private var server = ""
    @State private var remotePath = ""
    @State private var mountPoint = ""
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var nfsVersion: RemoteMountNFSVersion = .v3
    @State private var nfsTransport: RemoteMountNFSTransport = .tcp
    @State private var automatic = false
    @State private var picksFolder = false
    @State private var initialized = false

    var body: some View {
        NavigationStack {
            Form {
                MobileRemoteFeedback(model: model)
                Section {
                    Picker(L10n.string("ui.485a26050ce57431"), selection: $protocolType) {
                        Text(L10n.string("ui.a8321322c1053180")).tag(RemoteMountProtocol.smb)
                        Text(L10n.string("protocol.nfs")).tag(RemoteMountProtocol.nfs)
                    }
                    TextField(L10n.string("files.vfs.hostname"), text: $server).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("files.remote.mount.server")
                    TextField(L10n.string("files.vfs.folder"), text: $remotePath).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("files.remote.mount.folder")
                    Button { picksFolder = true } label: {
                        LabeledContent(L10n.string("mobile.files.choose-folder"), value: mountPoint)
                    }.accessibilityIdentifier("files.remote.mount.destination")
                }.disabled(model.busy || blocked)
                if protocolType == .smb {
                    Section {
                        TextField(L10n.string("files.vfs.account"), text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(L10n.string("files.vfs.password"), text: $password)
                        TextField(L10n.string("ui.99ac911a386914a8"), text: $domain).textInputAutocapitalization(.never).autocorrectionDisabled()
                        if existing != nil { Text(L10n.string("remote-mount.credentials-again")).foregroundStyle(.secondary) }
                    }.disabled(model.busy || blocked)
                } else {
                    Section {
                        Picker(L10n.string("remote-mount.nfs-version"), selection: $nfsVersion) {
                            Text(L10n.string("remote-mount.nfs3")).tag(RemoteMountNFSVersion.v3)
                            Text(L10n.string("remote-mount.nfs4")).tag(RemoteMountNFSVersion.v4)
                        }
                        Picker(L10n.string("remote-mount.nfs-transport"), selection: $nfsTransport) {
                            Text(L10n.string("remote-mount.tcp")).tag(RemoteMountNFSTransport.tcp)
                            Text(L10n.string("remote-mount.udp")).tag(RemoteMountNFSTransport.udp)
                        }.disabled(nfsVersion == .v4)
                    }.disabled(model.busy || blocked)
                }
                Section {
                    Toggle(L10n.string("files.mount.automatic"), isOn: $automatic)
                    if automatic { Text(L10n.string("files.mount.automaticImpact")).foregroundStyle(.secondary) }
                    if existing != nil { Text(L10n.string("remote-mount.edit-impact")).foregroundStyle(.secondary) }
                }.disabled(model.busy || blocked)
            }.navigationTitle(L10n.string(existing == nil ? "files.vfs.add" : "files.vfs.edit"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("files.common.close")) { password = ""; dismiss() }.disabled(model.busy)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if model.busy { ProgressView() }
                        else {
                            Button(L10n.string("files.vfs.saveConnect")) { submit() }
                                .disabled(!canSubmit).accessibilityIdentifier("files.remote.mount.save")
                        }
                    }
                }
        }.interactiveDismissDisabled(model.busy)
            .sheet(isPresented: $picksFolder) { MobileFileFolderPicker(repository: repository) { mountPoint = $0 } }
            .task { initialize() }
            .onChange(of: protocolType) { _, value in if value == .nfs { username = ""; password = ""; domain = "" } }
            .onChange(of: nfsVersion) { _, value in if value == .v4 { nfsTransport = .tcp } }
            .onDisappear { password = "" }
    }
    private var paths: Set<String> { Set([existing?.mountPoint, mountPoint].compactMap { $0 }.filter { !$0.isEmpty }) }
    private var blocked: Bool { model.isMountBlocked(paths) }
    private var canSubmit: Bool {
        model.canCreateMounts && !blocked && !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mountPoint.hasPrefix("/")
    }
    private func initialize() {
        guard !initialized else { return }; initialized = true
        guard let existing else { return }
        protocolType = existing.protocolType; mountPoint = existing.mountPoint; automatic = existing.automaticMount ?? false
        let source = existing.source
        if existing.protocolType == .smb, source.hasPrefix("//"), let slash = source.dropFirst(2).firstIndex(of: "/") {
            server = String(source[source.index(source.startIndex, offsetBy: 2)..<slash])
            remotePath = String(source[source.index(after: slash)...])
        } else if existing.protocolType == .nfs, let separator = source.range(of: ":/") {
            server = String(source[..<separator.lowerBound]); remotePath = String(source[separator.upperBound...])
        }
    }
    private func submit() {
        guard canSubmit else { return }
        let setup = RemoteMountSetup(.init(protocolType: protocolType, server: server, remotePath: remotePath, mountPoint: mountPoint,
            username: username, domain: domain, nfsVersion: nfsVersion, nfsTransport: nfsTransport, automaticMount: automatic))
        let secret = password; password = ""
        let change = existing.map { MobileRemoteLocationsModel.MountChange.update($0, setup) } ?? .create(setup)
        Task { if await model.changeMount(change, password: secret, confirmed: true) { dismiss() } }
    }
}

struct MobileRemoteContinuationView: View {
    @Bindable var model: MobileRemoteLocationsModel
    let entry: MobileRemoteLocationsModel.Pending
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    private var operation: RemoteMountOperation? { model.mountOperations[entry.id] }
    var body: some View {
        NavigationStack {
            Form {
                MobileRemoteFeedback(model: model)
                Section {
                    ForEach(entry.targets.sorted(), id: \.self) { Text($0) }
                    Text(L10n.string(operation?.stage == .readyToConnect ? "mobile.remote.resume-connection" : "mobile.remote.resume-disconnect"))
                    if operation?.stage == .readyToConnect && operation?.setup?.protocolType == .smb {
                        SecureField(L10n.string("files.vfs.password"), text: $password)
                    }
                }
                Section {
                    Button(L10n.string("mobile.remote.continue")) { run(.resume) }
                    Button(L10n.string("mobile.remote.end-remaining"), role: .destructive) { run(.abandon) }
                    Text(L10n.string("mobile.remote.end-impact")).foregroundStyle(.secondary)
                }.disabled(model.busy || operation?.stage.canContinue != true)
            }.navigationTitle(L10n.string("mobile.remote.incomplete"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.disabled(model.busy)
                } }
        }.interactiveDismissDisabled(model.busy).onDisappear { password = "" }
    }
    private func run(_ action: MobileRemoteLocationsModel.Continuation) {
        let secret = password; password = ""
        Task {
            await model.continueMount(entry, password: secret, action: action, confirmed: true)
            if !model.pending.contains(entry) { dismiss() }
        }
    }
}

struct MobileISOMountView: View {
    @Bindable var model: MobileRemoteLocationsModel
    let repository: DsmFileRepository
    let source: FileItem?
    let existing: FileISOMountConnection?
    @Environment(\.dismiss) private var dismiss
    @State private var destination: FileItem?
    @State private var automatic = false
    @State private var picksFolder = false
    @State private var choosing = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                MobileRemoteFeedback(model: model)
                Section {
                    Text(source?.name ?? URL(fileURLWithPath: existing?.source ?? "").lastPathComponent).font(.headline)
                    if let existing {
                        Text(existing.mountPoint)
                        Text(L10n.string("files.iso.unmountImpact")).foregroundStyle(.secondary)
                    } else {
                        Button { picksFolder = true } label: {
                            LabeledContent(L10n.string("files.iso.chooseDestination"), value: destination?.path ?? "")
                        }.accessibilityIdentifier("files.remote.iso.destination")
                        Toggle(L10n.string("files.mount.automatic"), isOn: $automatic)
                        if automatic { Text(L10n.string("files.mount.automaticImpact")).foregroundStyle(.secondary) }
                        Text(L10n.string("files.iso.emptyFolderRequired")).foregroundStyle(.secondary)
                    }
                }.disabled(model.busy || choosing || blocked)
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button(L10n.string(existing == nil ? "files.iso.mount" : "files.iso.unmount")) {
                        guard let change else { return }
                        Task { if await model.changeISO(change) { dismiss() } }
                    }.disabled(!model.canManageISO || choosing || change == nil || blocked)
                        .accessibilityIdentifier("files.remote.iso.save")
                }
            }.navigationTitle(L10n.string(existing == nil ? "files.iso.mount" : "files.iso.unmount"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.disabled(model.busy)
                } }
        }.interactiveDismissDisabled(model.busy)
            .task { await model.load() }
            .sheet(isPresented: $picksFolder) {
                MobileFileFolderPicker(repository: repository) { path in
                    choosing = true; destination = nil; error = nil
                    Task {
                        defer { choosing = false }
                        do { destination = try await model.destination(path) }
                        catch { self.error = MobileRemoteLocationsModel.message(error) }
                    }
                }
            }
    }
    private var change: FileISOMountChange? {
        if let existing { return .unmount(existing) }
        guard let source, let destination else { return nil }
        return .mount(.init(source: source, destination: destination, automaticMount: automatic))
    }
    private var blocked: Bool { change.map { model.isMountBlocked([$0.mountPoint]) } ?? false }
}
