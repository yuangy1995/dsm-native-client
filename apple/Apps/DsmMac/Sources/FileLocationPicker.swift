import DsmCore
import DsmLocalization
import SwiftUI

struct FileLocationPicker: View {
    let model: WorkspaceModel
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path: String?
    @State private var folders: [FileItem] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("files.location.title")).font(.title2.bold())
            HStack {
                Button {
                    guard let path else { return }
                    let parent = (path as NSString).deletingLastPathComponent
                    self.path = parent == "/" ? nil : parent
                } label: { Label(L10n.string("ui.8e7847be62b68c2b"), systemImage: "arrow.up") }
                    .disabled(path == nil || isLoading)
                Text(path ?? model.profile.displayName).lineLimit(2)
            }
            Group {
                if isLoading { ProgressView().fillsAvailableContentArea() }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("files.location.failed"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("files.common.retry")) { Task { await load() } }
                    }.fillsAvailableContentArea()
                } else if folders.isEmpty {
                    ContentUnavailableView(L10n.string("files.location.empty"), systemImage: "folder",
                        description: Text(L10n.string("files.location.selectCurrent"))).fillsAvailableContentArea()
                } else {
                    List(folders) { folder in
                        Button { path = folder.path } label: {
                            HStack { Image(systemName: "folder"); Text(folder.name); Spacer(); Image(systemName: "chevron.right") }
                        }.buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Spacer()
                Button(L10n.string("files.common.close"), role: .cancel) { dismiss() }
                Button(L10n.string("files.location.select")) {
                    if let path { onSelect(path); dismiss() }
                }.buttonStyle(.borderedProminent).disabled(path == nil || isLoading || error != nil)
            }
        }.padding(24).frame(width: 520, height: 420)
            .task(id: path) { await load() }
    }

    private func load() async {
        let requestedPath = path
        isLoading = true; error = nil
        do {
            let result = try await model.loadFileFolders(requestedPath)
            guard path == requestedPath, !Task.isCancelled else { return }
            folders = result
        } catch {
            guard path == requestedPath, !Task.isCancelled else { return }
            self.error = L10n.string("files.location.failed")
        }
        isLoading = false
    }
}
