import AppKit
import DsmCore
import DsmLocalization
import SwiftUI

/// 远程 URI 按服务端提供的完整值导航，不套用 NAS 共享目录的路径规则。
struct FileVFSBrowserView: View {
    let model: WorkspaceModel
    let profile: FileVFSProfile
    var onClose: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [(name: String, path: String)] = []
    @State private var items: [FileItem] = []
    @State private var query = ""
    @State private var offset = 0
    @State private var hasMore = false
    @State private var loading = true
    @State private var error: String?
    @State private var generation = UUID()
    private var path: String { folders.last?.path ?? profile.uri }
    private var filtered: [FileItem] { items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(folders.last?.name ?? profile.alias).font(.title2.bold())
                Spacer()
                Button(L10n.string(onClose == nil ? "files.common.close" : "remote-locations.back")) {
                    if let onClose { onClose() } else { dismiss() }
                }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Button { folders.removeLast(); query = "" } label: {
                    Label(L10n.string("ui.8e7847be62b68c2b"), systemImage: "arrow.up")
                }.disabled(folders.isEmpty || loading)
                TextField(L10n.string("files.vfs.fileFilter"), text: $query)
                Button(L10n.string("files.sharing.refresh")) { Task { await load(reset: true) } }.disabled(loading)
            }
            if loading && items.isEmpty { ProgressView().fillsAvailableContentArea() }
            else if let error { FileSettingsLoadError(error: error) { Task { await load(reset: true) } } }
            else if filtered.isEmpty {
                ContentUnavailableView(L10n.string("files.vfs.folderEmpty"), systemImage: "folder",
                    description: Text(query.isEmpty ? L10n.string("files.vfs.folderEmptyDetail") : L10n.string("files.vfs.filteredEmpty")))
                    .fillsAvailableContentArea()
            } else {
                List(filtered) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder" : "doc")
                        if item.isDirectory {
                            Button(item.name) { folders.append((item.name, item.path)); query = "" }.buttonStyle(.plain)
                        } else { Text(item.name) }
                        Spacer()
                        if !item.isDirectory {
                            Button(L10n.string("files.vfs.download")) { download(item) }.disabled(loading)
                        }
                    }.padding(.vertical, 4)
                }
            }
            if hasMore {
                Button(L10n.string("files.principals.more")) { Task { await load(reset: false) } }.disabled(loading)
            }
        }.padding(24).frame(width: onClose == nil ? 700 : nil, height: onClose == nil ? 540 : nil)
            .fillsAvailableContentArea(alignment: .topLeading)
            .task(id: path) { await load(reset: true) }
            .onDisappear { generation = UUID() }
    }

    private func load(reset: Bool) async {
        let token: UUID
        if reset { token = UUID(); generation = token; items = []; offset = 0; hasMore = false }
        else { guard !loading else { return }; token = generation }
        loading = true; error = nil
        do {
            let page = try await model.listFileVFSFolder(profile, path: path, offset: offset)
            guard token == generation, !Task.isCancelled else { return }
            let ids = Set(items.map(\.id)); items += page.items.filter { !ids.contains($0.id) }
            offset = page.offset + page.items.count; hasMore = page.hasMore
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.vfs.loadFailed")
        }
        loading = false
    }

    private func download(_ item: FileItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.enqueueDownload(item, to: url) }
    }
}
