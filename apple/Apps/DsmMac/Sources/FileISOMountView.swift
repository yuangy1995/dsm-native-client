import DsmCore
import DsmLocalization
import SwiftUI

struct FileISOMountManagerView: View {
    let model: WorkspaceModel
    let onClose: () -> Void
    @State private var mounts: [FileISOMountConnection] = []
    @State private var selection: FileISOMountConnection?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("files.iso.manage")).font(.title2.bold())
            if loading { ProgressView().fillsAvailableContentArea() }
            else if let error {
                ContentUnavailableView(L10n.string("files.iso.loadFailed"), systemImage: "exclamationmark.triangle", description: Text(error))
                    .fillsAvailableContentArea()
            } else if mounts.isEmpty {
                ContentUnavailableView(L10n.string("files.iso.empty"), systemImage: "opticaldisc",
                    description: Text(L10n.string("files.iso.emptyDetail"))).fillsAvailableContentArea()
            } else {
                List(mounts) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.source)
                            Text(item.mountPoint).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.string("files.iso.unmount")) { selection = item }
                    }
                }
            }
            HStack {
                Button(L10n.string("files.sharing.refresh")) { Task { await load() } }.disabled(loading)
                Spacer()
                Button(L10n.string("files.common.close"), action: onClose).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 640, height: 460).task { await load() }
            .macSheet(item: $selection) { item in
                FileISOMountView(model: model, source: nil, connection: item) {
                    selection = nil; Task { await load() }
                }
            }
    }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do { mounts = try await model.loadISOMounts() }
        catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.iso.loadFailed") }
    }
}

struct FileISOMountView: View {
    let model: WorkspaceModel
    let source: FileItem?
    let connection: FileISOMountConnection?
    let onClose: () -> Void
    @State private var destination: FileItem?
    @State private var automatic = false
    @State private var showsPicker = false
    @State private var access: FileStationAdvancedAccess?
    @State private var submittedChange: FileISOMountChange?
    @State private var result: MutationResult?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(connection == nil ? L10n.string("files.iso.mount") : L10n.string("files.iso.unmount")).font(.title2.bold())
            Text(source?.path ?? connection?.source ?? "").textSelection(.enabled)
            if connection == nil {
                Text(destination?.path ?? L10n.string("files.iso.chooseDestination"))
                Button(L10n.string("files.iso.chooseDestination")) { showsPicker = true }.disabled(busy || submittedChange != nil)
                Toggle(L10n.string("files.mount.automatic"), isOn: $automatic).disabled(busy || submittedChange != nil)
                if automatic { Text(L10n.string("files.mount.automaticImpact")).font(.caption) }
                Text(L10n.string("files.iso.emptyFolderRequired")).foregroundStyle(.secondary)
            } else {
                Text(connection?.mountPoint ?? "").textSelection(.enabled)
                Text(L10n.string("files.iso.unmountImpact")).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if let result {
                Text(result.status == .confirmedSuccess ? L10n.string("files.iso.completed")
                    : result.requiresRefresh ? L10n.string("files.iso.unverified") : L10n.string("files.iso.failed"))
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.string("files.common.close"), action: onClose).keyboardShortcut(.cancelAction).disabled(busy)
                if result?.requiresRefresh == true {
                    Button(L10n.string("files.iso.review")) { submit(review: true) }.disabled(busy)
                } else if submittedChange == nil {
                    Button(connection == nil ? L10n.string("files.iso.mount") : L10n.string("files.iso.unmount")) { submit(review: false) }
                        .buttonStyle(.borderedProminent).disabled(busy || change == nil || access?.writesEnabled != true)
                }
            }
        }.padding(24).frame(width: 570).interactiveDismissDisabled(busy)
            .task {
                do { access = try await model.loadFileStationAdvancedAccess() }
                catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.advanced.readFailed") }
            }
            .macSheet(isPresented: $showsPicker) {
                FileLocationPicker(model: model) { path in
                    destination = nil; busy = true
                    Task {
                        defer { busy = false }
                        do { destination = try await model.loadISODestination(path); error = nil }
                        catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.iso.loadFailed") }
                    }
                }
            }
    }
    private var change: FileISOMountChange? {
        if let connection { return .unmount(connection) }
        guard let source, let destination else { return nil }
        return .mount(.init(source: source, destination: destination, automaticMount: automatic))
    }
    private func submit(review: Bool) {
        guard !busy, let change = review ? submittedChange : change else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do {
                let outcome = try await model.changeISO(change, reviewOnly: review)
                submittedChange = change; result = outcome
            } catch {
                self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.iso.failed")
            }
        }
    }
}
