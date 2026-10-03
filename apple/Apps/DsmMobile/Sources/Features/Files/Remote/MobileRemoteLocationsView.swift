import DsmCore
import DsmLocalization
import DsmNetwork
import SwiftUI

struct MobileRemoteLocationsView: View {
    @Bindable var model: MobileRemoteLocationsModel
    let repository: DsmFileRepository
    let openMount: (String) -> Void
    let download: (FileItem) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var addsMount = false
    @State private var editsMount: RemoteMountConnection?
    @State private var addsVFS = false
    @State private var editsVFS: FileVFSProfile?
    @State private var cloud: FileVFSProfile?
    @State private var iso: FileISOMountConnection?
    @State private var browserProfile: FileVFSProfile?
    @State private var action: ConnectionAction?
    @State private var continuation: MobileRemoteLocationsModel.Pending?

    private struct ConnectionAction: Identifiable {
        let id = UUID()
        let vfs: FileVFSChange?
        let mount: RemoteMountConnection?
        let title: String
        let message: String
    }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }

    var body: some View {
        NavigationStack {
            Group {
                if model.loading && model.inventory == nil && model.profiles.isEmpty { ProgressView() }
                else {
                    List {
                        MobileRemoteFeedback(model: model)
                        pendingSection
                        mountsSection
                        vfsSection
                        isoSection
                    }.refreshable { await model.load() }
                }
            }.fillsAvailableContentArea(alignment: .topLeading)
                .navigationTitle(L10n.string("mobile.files.locations.remote"))
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $query, prompt: L10n.string("remote-locations.search"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("files.common.close")) { dismiss() }.disabled(model.busy)
                    }
                    ToolbarItemGroup(placement: .confirmationAction) {
                        Button { Task { await model.load() } } label: {
                            Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel(L10n.string("ui.aee88743413144a2")).disabled(model.loading || model.busy)
                        Menu {
                            Button(L10n.string("remote-locations.addSharedFolder")) { model.clearFeedback(); addsMount = true }
                                .disabled(!model.canCreateMounts)
                            Button(L10n.string("files.vfs.title")) { model.clearFeedback(); addsVFS = true }
                                .disabled(!model.canManageVFS || model.protocols.isEmpty)
                        } label: {
                            Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel(L10n.string("files.vfs.add")).accessibilityIdentifier("files.remote.add")
                    }
                }
                .navigationDestination(isPresented: Binding(get: { browserProfile != nil }, set: { if !$0 { browserProfile = nil } })) {
                    if let profile = browserProfile {
                        MobileVFSBrowserView(repository: repository, profile: profile, download: download)
                    }
                }
        }
        .task { await model.load() }
        .interactiveDismissDisabled(model.busy)
        .sheet(isPresented: $addsMount) { MobileRemoteMountEditor(model: model, repository: repository, existing: nil) }
        .sheet(item: $editsMount) { MobileRemoteMountEditor(model: model, repository: repository, existing: $0) }
        .sheet(isPresented: $addsVFS) { MobileVFSEditor(model: model, existing: nil) }
        .sheet(item: $editsVFS) { MobileVFSEditor(model: model, existing: $0) }
        .sheet(item: $cloud) { MobileVFSCloudView(model: model, protocolID: $0.protocolID, protocolName: $0.protocolName, existing: $0) }
        .sheet(item: $iso) { MobileISOMountView(model: model, repository: repository, source: nil, existing: $0) }
        .sheet(item: $continuation) { MobileRemoteContinuationView(model: model, entry: $0) }
        .alert(action?.title ?? "", isPresented: Binding(get: { action != nil }, set: { if !$0 { action = nil } })) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { action = nil }
            Button(action?.title ?? "", role: .destructive) {
                guard let current = action else { return }; action = nil
                Task {
                    if let vfs = current.vfs { await model.changeVFS(vfs) }
                    else if let mount = current.mount { await model.changeMount(.disconnect(mount), confirmed: true) }
                }
            }
        } message: { Text(action?.message ?? "") }
    }

    @ViewBuilder private var pendingSection: some View {
        if !model.pending.isEmpty {
            Section(L10n.string("mobile.remote.incomplete")) {
                ForEach(model.pending) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        if entry.kind != .vfs { ForEach(entry.targets.sorted(), id: \.self) { Text($0).lineLimit(2).truncationMode(.middle) } }
                        Text(L10n.string(model.canReview(entry) ? "mobile.remote.pending" : "mobile.remote.previous-pending"))
                            .foregroundStyle(.secondary)
                        if model.mountOperations[entry.id]?.stage.canContinue == true {
                            Button(L10n.string("mobile.remote.continue")) { continuation = entry }
                        } else {
                            Button(L10n.string("ui.aee88743413144a2")) { Task { await model.review(entry) } }
                        }
                    }.disabled(model.busy).accessibilityIdentifier("files.remote.pending")
                }
            }
        }
    }
    @ViewBuilder private var mountsSection: some View {
        Section(L10n.string("remote-locations.addSharedFolder")) {
            if let error = model.mountError { Text(error).foregroundStyle(.red) }
            else {
                let rows = (model.inventory?.connections ?? []).filter { matches($0.mountPoint) || matches($0.source) }
                if rows.isEmpty { emptyRow(isFiltered: !query.isEmpty) }
                ForEach(rows) { item in
                    HStack {
                        Button {
                            openMount(item.mountPoint); dismiss()
                        } label: {
                            Label { VStack(alignment: .leading) {
                                Text(URL(fileURLWithPath: item.mountPoint).lastPathComponent)
                                Text(item.source).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            } } icon: { Image(systemName: "network") }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Menu {
                            Button(L10n.string("files.vfs.edit")) { model.clearFeedback(); editsMount = item }
                            Button(L10n.string("files.vfs.disconnect"), role: .destructive) {
                                action = .init(vfs: nil, mount: item, title: L10n.string("files.vfs.disconnect"),
                                    message: L10n.string("files.vfs.disconnectWarning"))
                            }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel(L10n.string("files.vfs.actions"))
                            .accessibilityIdentifier("files.remote.mount-actions." + item.mountPoint)
                            .disabled(!model.canManageMounts || model.isMountBlocked([item.mountPoint]))
                    }
                }
            }
        }
    }
    private var vfsSection: some View {
        Section(L10n.string("files.vfs.title")) {
            if let error = model.vfsError { Text(error).foregroundStyle(.red) }
            else {
                let rows = model.profiles.filter { matches($0.alias) || matches($0.protocolName) }
                if rows.isEmpty { emptyRow(isFiltered: !query.isEmpty) }
                ForEach(rows) { item in
                    HStack {
                        Button {
                            if item.state == .connected { browserProfile = item }
                            else if item.state == .disconnected { Task { await model.changeVFS(.connect(item)) } }
                        } label: {
                            Label { VStack(alignment: .leading) {
                                Text(item.alias)
                                Text(item.protocolName).font(.caption).foregroundStyle(.secondary)
                                Text(L10n.string(item.state == .connected ? "files.vfs.connected" : item.state == .disconnected
                                    ? "files.vfs.disconnected" : "files.vfs.unknown")).font(.caption).foregroundStyle(.secondary)
                            } } icon: { Image(systemName: FileVFSProtocol.cloudProtocolIDs.contains(item.protocolID) ? "cloud" : "network") }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .disabled(model.busy || model.isVFSBlocked(.connect(item)) || item.state == .unknown
                                || item.state == .disconnected && !model.canManageVFS)
                            .accessibilityIdentifier("files.remote.profile." + item.id)
                        Menu {
                            if item.state == .disconnected {
                                Button(L10n.string("files.vfs.connect")) { Task { await model.changeVFS(.connect(item)) } }
                            }
                            if item.state == .connected {
                                Button(L10n.string("files.vfs.disconnect"), role: .destructive) {
                                    action = .init(vfs: .disconnect(item), mount: nil, title: L10n.string("files.vfs.disconnect"),
                                        message: L10n.string("files.vfs.disconnectWarning"))
                                }
                            }
                            if FileVFSProtocol.cloudProtocolIDs.contains(item.protocolID) {
                                Button(L10n.string("files.vfs.reauthorize")) { model.clearFeedback(); cloud = item }
                            } else if ["ftp", "sftp", "dav", "davs"].contains(item.protocolID) {
                                Button(L10n.string("files.vfs.edit")) { model.clearFeedback(); editsVFS = item }
                                    .disabled(item.state == .unknown)
                            }
                            Button(L10n.string("files.vfs.remove"), role: .destructive) {
                                action = .init(vfs: .removeSavedProfile(item), mount: nil, title: L10n.string("files.vfs.remove"),
                                    message: L10n.string("files.vfs.removeWarning"))
                            }.disabled(item.state != .disconnected)
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel(L10n.string("files.vfs.actions"))
                            .accessibilityIdentifier("files.remote.actions." + item.id)
                            .disabled(!model.canManageVFS || model.isVFSBlocked(.connect(item)))
                    }
                }
            }
        }
    }
    @ViewBuilder private var isoSection: some View {
        if let items = model.inventory?.isoConnections {
            Section(L10n.string("files.iso.manage")) {
                let rows = items.filter { matches($0.source) || matches($0.mountPoint) }
                if rows.isEmpty {
                    Text(L10n.string(query.isEmpty ? "files.iso.emptyDetail" : "files.vfs.filteredEmpty"))
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { item in
                    HStack {
                        Button { openMount(item.mountPoint); dismiss() } label: {
                            Label { VStack(alignment: .leading) {
                                Text(URL(fileURLWithPath: item.source).lastPathComponent)
                                Text(item.mountPoint).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            } } icon: { Image(systemName: "opticaldisc") }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button(L10n.string("files.iso.unmount")) { model.clearFeedback(); iso = item }
                            .disabled(!model.canManageISO || model.isMountBlocked([item.mountPoint]))
                    }
                }
            }
        }
    }
    private func emptyRow(isFiltered: Bool) -> some View {
        Text(L10n.string(isFiltered ? "files.vfs.filteredEmpty" : "files.vfs.emptyDetail")).foregroundStyle(.secondary)
    }
}

struct MobileRemoteFeedback: View {
    let model: MobileRemoteLocationsModel
    var body: some View {
        if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
        if let feedback = model.feedback { Section { Text(feedback) }.accessibilityIdentifier("files.remote.result") }
        if model.recoveryFailed { Section { Text(L10n.string("mobile.activity.recovery-error")).foregroundStyle(.red) } }
    }
}
