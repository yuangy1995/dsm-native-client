import DsmCore
import DsmLocalization
import SwiftUI

struct FileStationMountAccountList: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind = FileStationPrincipal.Kind.user
    @State private var query = ""
    @State private var source = FileStationMountAccountSource.local
    @State private var directories: [FileStationMountDirectory] = [.init(source: .local, name: "")]
    @State private var directoryError = false
    @State private var rows: [FileStationMountAccount] = []
    @State private var nextOffset = 0
    @State private var total = 0
    @State private var loading = true
    @State private var error: String?
    @State private var generation = UUID()
    @State private var editing: FileStationMountAccount?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("files.settings.manageLocalAccounts")).font(.title2.bold())
                Spacer()
                Button(L10n.string("files.common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker(L10n.string("files.settings.accountSource"), selection: $source) {
                ForEach(directories) { directory in
                    Text(directoryName(directory)).tag(directory.source)
                }
            }
            if directoryError {
                HStack {
                    Text(L10n.string("files.settings.directoryUnavailable")).foregroundStyle(.secondary)
                    Button(L10n.string("files.common.retry")) { Task { await loadDirectories() } }
                }
            }
            Picker(L10n.string("files.principals.user"), selection: $kind) {
                Text(L10n.string("files.principals.user")).tag(FileStationPrincipal.Kind.user)
                Text(L10n.string("files.principals.group")).tag(FileStationPrincipal.Kind.group)
            }.pickerStyle(.segmented)
            TextField(L10n.string("files.principals.search"), text: $query)
            if loading && rows.isEmpty { ProgressView().fillsAvailableContentArea() }
            else if error != nil { FileSettingsLoadError(error: error) { Task { await load(reset: true) } } }
            else if rows.isEmpty {
                ContentUnavailableView(L10n.string("files.principals.empty"), systemImage: "person.2",
                    description: Text(L10n.string("files.principals.emptyDetail"))).fillsAvailableContentArea()
            } else {
                List(rows) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.name)
                            Text(L10n.string(row.enabled ? "files.settings.accountAllowed" : "files.settings.accountDenied")).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.string("files.sharing.edit")) { editing = row }.disabled(!row.canModify)
                    }
                }
                if nextOffset < total {
                    Button(L10n.string("files.principals.more")) { Task { await load(reset: false) } }.disabled(loading)
                }
            }
        }.padding(24).frame(width: 620, height: 500)
            .task { await loadDirectories() }
            .task(id: source.id + ":" + kind.rawValue + ":" + query) { await load(reset: true) }
            .onDisappear { generation = UUID() }
            .sheet(item: $editing, onDismiss: { Task { await load(reset: true) } }) { account in
                FileStationMountAccountEditor(model: model, account: account)
            }
    }
    private func directoryName(_ directory: FileStationMountDirectory) -> String {
        switch directory.source {
        case .local: L10n.string("files.settings.source.local")
        case .ldap: L10n.string("files.settings.source.ldap")
        case .domain: directory.name
        }
    }
    private func loadDirectories() async {
        do {
            let report = try await model.loadFileStationMountDirectories()
            guard !Task.isCancelled else { return }
            directories = report.items; directoryError = report.hasUnavailableSources
            if !directories.contains(where: { $0.source == source }) { source = .local }
        } catch { if !Task.isCancelled { directoryError = true } }
    }
    private func load(reset: Bool) async {
        let token: UUID
        if reset { token = UUID(); generation = token; rows = []; nextOffset = 0; total = 0 }
        else { guard !loading else { return }; token = generation }
        loading = true; error = nil
        do {
            let page = try await model.listFileStationMountAccounts(source: source, kind: kind, query: query, offset: nextOffset)
            guard token == generation, !Task.isCancelled else { return }
            let ids = Set(rows.map(\.id)); rows += page.items.filter { !ids.contains($0.id) }
            nextOffset = page.nextOffset; total = page.total
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.principals.loadFailed")
        }
        loading = false
    }
}

private struct FileStationMountAccountEditor: View {
    let model: WorkspaceModel
    let account: FileStationMountAccount
    @Environment(\.dismiss) private var dismiss
    @State private var enabled: Bool
    @State private var locked = false
    init(model: WorkspaceModel, account: FileStationMountAccount) {
        self.model = model; self.account = account; _enabled = State(initialValue: account.enabled)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(account.name).font(.title2.bold())
            Toggle(L10n.string("files.settings.allowRemoteAccess"), isOn: $enabled).disabled(locked)
            FileSettingsCommitControls(model: model, change: enabled == account.enabled ? nil : .mountAccount(baseline: account, enabled: enabled), locked: $locked)
            HStack { Spacer(); Button(L10n.string("files.common.close")) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 540, height: 320)
    }
}
