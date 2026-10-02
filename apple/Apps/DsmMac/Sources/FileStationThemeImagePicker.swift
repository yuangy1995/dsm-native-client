import AppKit
import DsmCore
import DsmLocalization
import SwiftUI
import UniformTypeIdentifiers

struct FileStationThemeImagePicker: View {
    let model: WorkspaceModel
    let kind: FileStationThemeImage.Kind
    let onSelect: (FileStationThemeImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.nas
    @State private var path: String?
    @State private var files: [FileItem] = []
    @State private var images: [FileStationThemeImage] = []
    @State private var selected: FileStationThemeImage?
    @State private var preview: Data?
    @State private var localData: Data?
    @State private var localName = ""
    @State private var loading = true
    @State private var busy = false
    @State private var offset = 0
    @State private var hasMore = false
    @State private var error: String?
    @State private var generation = UUID()
    private enum Source: String { case nas, history, local, defaults }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string(kind == .logo ? "files.theme.chooseLogo" : "files.theme.chooseBackground")).font(.title2.bold())
            Picker(L10n.string("files.theme.source"), selection: $source) {
                Text(L10n.string("files.theme.nas")).tag(Source.nas)
                Text(L10n.string("files.theme.history")).tag(Source.history)
                Text(L10n.string("files.theme.local")).tag(Source.local)
                if kind == .background { Text(L10n.string("files.theme.defaults")).tag(Source.defaults) }
            }.pickerStyle(.segmented).labelsHidden()
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(busy)
            if source == .nas {
                HStack {
                    Button {
                        if let path { let parent = (path as NSString).deletingLastPathComponent; self.path = parent == "/" ? nil : parent }
                    } label: { Label(L10n.string("ui.8e7847be62b68c2b"), systemImage: "arrow.up") }
                        .disabled(path == nil || loading || busy)
                    Text(path ?? model.profile.displayName).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(alignment: .top, spacing: 20) {
                if source == .local {
                    VStack(alignment: .leading, spacing: 16) {
                        Button(L10n.string("files.theme.chooseLocal")) { chooseLocal() }.disabled(busy)
                        Text(localName).lineLimit(2)
                        Text(L10n.string("files.theme.uploadScope")).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else if loading && files.isEmpty && images.isEmpty {
                    ProgressView().fillsAvailableContentArea()
                } else if source == .nas {
                    if files.isEmpty { emptyState }
                    else {
                        List(files) { file in
                            Button {
                                if file.isDirectory { path = file.path }
                                else { choose(.init(kind: kind, source: .nas, path: file.path, name: file.name)) }
                            } label: {
                                Label(file.name, systemImage: file.isDirectory ? "folder" : "photo")
                            }.buttonStyle(.plain).disabled(busy)
                        }
                    }
                } else if images.isEmpty { emptyState }
                else {
                    List(images) { image in
                        Button(imageTitle(image)) {
                            choose(image)
                        }.buttonStyle(.plain).disabled(busy)
                    }
                }
                VStack(spacing: 10) {
                    if let preview, let image = NSImage(data: preview) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 280)
                            .accessibilityLabel(L10n.string("files.theme.preview"))
                    } else {
                        Image(systemName: "photo").font(.system(size: 64)).foregroundStyle(.secondary)
                    }
                    if let selected { Text(selected.name).lineLimit(2) }
                }.frame(width: 260, height: 300)
            }.frame(maxHeight: .infinity)
            if let error {
                HStack {
                    Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    if source != .local { Button(L10n.string("files.common.retry")) { Task { await load(reset: true) } }.disabled(busy) }
                }
            }
            HStack {
                if hasMore { Button(L10n.string("files.principals.more")) { Task { await load(reset: false) } }.disabled(loading || busy) }
                Spacer()
                Button(L10n.string("files.common.close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                if source == .local {
                    Button(L10n.string("files.theme.uploadSelect")) { Task { await upload() } }.buttonStyle(.borderedProminent)
                        .disabled(localData == nil || busy)
                } else {
                    Button(L10n.string("files.theme.select")) { if let selected { onSelect(selected); dismiss() } }
                        .buttonStyle(.borderedProminent).disabled(selected == nil || preview == nil || busy || loading)
                }
            }
        }.padding(24).frame(width: 760, height: 570)
            .task(id: source.rawValue + ":" + (path ?? "")) { await load(reset: true) }
            .onDisappear { generation = UUID(); localData = nil; preview = nil }
    }

    private var emptyState: some View {
        ContentUnavailableView(L10n.string("files.theme.empty"), systemImage: "photo",
            description: Text(L10n.string("files.theme.emptyDetail"))).fillsAvailableContentArea()
    }

    private func imageTitle(_ image: FileStationThemeImage) -> String {
        image.source == .systemDefault
            ? L10n.string("files.theme.defaultNumber", (images.firstIndex(of: image) ?? 0) + 1) : image.name
    }

    private func load(reset: Bool) async {
        let token: UUID
        if reset {
            token = UUID(); generation = token; files = []; images = []; selected = nil; preview = nil; offset = 0; hasMore = false
            localData = nil; localName = ""
        } else { guard !loading else { return }; token = generation }
        loading = true; error = nil
        do {
            if source == .nas {
                let page: FilePage
                if let path { page = try await model.fileRepository.listFolder(path: path, offset: offset, limit: 200) }
                else { page = try await model.fileRepository.listShares(offset: offset, limit: 200) }
                guard token == generation, !Task.isCancelled else { return }
                files += page.items.filter { $0.isDirectory || ($0.kind == .file && FileStationThemeImage.supportsFilename($0.name)) }
                offset = page.offset + page.items.count; hasMore = page.hasMore
            } else if source == .history {
                let result = try await model.listFileStationThemeImages(kind: kind)
                guard token == generation, !Task.isCancelled else { return }
                images = result
            } else if source == .defaults {
                images = (1...10).map { .init(kind: .background, source: .systemDefault, path: "dsm7_0\($0).jpg", name: "dsm7_0\($0).jpg") }
            }
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.theme.imageLoadFailed")
        }
        loading = false
    }

    private func choose(_ image: FileStationThemeImage) {
        selected = image; preview = nil; error = nil; busy = true
        let token = generation
        Task {
            defer { if token == generation { busy = false } }
            do {
                let data = try await model.loadFileStationThemeImage(image)
                guard token == generation, !Task.isCancelled else { return }
                guard NSImage(data: data) != nil else { throw AppError(category: .invalidResponse, isRetryable: true, safeUserMessage: L10n.string("files.theme.imageLoadFailed")) }
                preview = data
            } catch { if token == generation { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.theme.imageLoadFailed") } }
        }
    }

    private func chooseLocal() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .gif, .bmp]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource(); defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard NSImage(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
            localData = data; preview = data; localName = url.lastPathComponent; error = nil
        } catch { localData = nil; preview = nil; self.error = L10n.string("files.theme.invalidImage") }
    }

    private func upload() async {
        guard let localData, !busy else { return }
        busy = true; error = nil; defer { busy = false }
        do {
            let image = try await model.uploadFileStationThemeImage(data: localData, filename: localName, kind: kind)
            onSelect(image); dismiss()
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.theme.uploadUnknown") }
    }
}
