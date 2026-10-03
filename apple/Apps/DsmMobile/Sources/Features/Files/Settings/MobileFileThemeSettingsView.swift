import DsmCore
import DsmLocalization
import SwiftUI
import UniformTypeIdentifiers

struct MobileFileThemeSettingsView: View {
    let model: MobileFileSettingsModel
    @State private var baseline: FileStationSharingTheme?
    @State private var failed = false
    var body: some View {
        Group {
            if let baseline { MobileFileThemeForm(model: model, baseline: baseline, reload: load) }
            else if failed { MobileFileSettingsLoadError { Task { await load() } } }
            else { ProgressView(L10n.string("mobile.file-settings.loading")).fillsAvailableContentArea().accessibilityIdentifier("files.settings.loading") }
        }.navigationTitle(L10n.string("files.settings.appearance")).navigationBarTitleDisplayMode(.inline)
            .task { await load() }
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel(L10n.string("files.sharing.refresh")).disabled(model.busy) } }
    }
    private func load() async {
        do { let result = try await model.read { try await $0.loadFileStationSharingTheme() }; baseline = result; failed = false }
        catch is CancellationError { }
        catch { baseline = nil; failed = true }
    }
}

private struct MobileFileThemeForm: View {
    let model: MobileFileSettingsModel
    let baseline: FileStationSharingTheme
    let reload: @MainActor () async -> Void
    @State private var value: FileStationSharingTheme
    @State private var imageKind: FileStationThemeImage.Kind?
    init(model: MobileFileSettingsModel, baseline: FileStationSharingTheme, reload: @escaping @MainActor () async -> Void) {
        self.model = model; self.baseline = baseline; self.reload = reload; _value = State(initialValue: baseline)
    }
    var body: some View {
        Form {
            Group {
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
                    ColorPicker(L10n.string("files.settings.backgroundColor"), selection: color, supportsOpacity: false)
                }
                Section {
                    VStack(alignment: .leading) {
                        Text(L10n.string("files.settings.footer"))
                        TextField("", text: $value.footer, axis: .vertical).lineLimit(2...5).accessibilityLabel(L10n.string("files.settings.footer"))
                    }
                    Toggle(L10n.string("files.settings.footerHTML"), isOn: $value.footerUsesHTML)
                    if !validFooter { Text(L10n.string("files.settings.invalidTheme")).foregroundStyle(.red) }
                    if needsImage { Text(L10n.string("files.theme.chooseRequired")).foregroundStyle(.secondary) }
                }
            }.disabled(!model.canWrite || model.isBlocked("theme"))
            MobileFileSettingsCommit(model: model, target: "theme", change: value == baseline || needsImage || !validFooter ? nil : .theme(baseline: baseline, updated: value), saved: reload)
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $imageKind) { kind in
            MobileFileThemeImagePicker(model: model, kind: kind) { image in
                if kind == .logo { value.logoImage = image; value.customLogo = true }
                else { value.backgroundImage = image; value.customBackground = true }
            }
        }
        .onChange(of: baseline) { _, latest in value = latest }
        .onChange(of: value.customLogo) { _, enabled in if !enabled { value.logoImage = nil } }
        .onChange(of: value.customBackground) { _, enabled in if !enabled { value.backgroundImage = nil } }
    }
    private var validFooter: Bool { value.footer.count <= 512 && !value.footer.contains(where: { $0.isNewline }) }
    private var needsImage: Bool { value.customLogo && !baseline.customLogo && value.logoImage == nil || value.customBackground && !baseline.customBackground && value.backgroundImage == nil }
    private var color: Binding<Color> {
        Binding(get: {
            let number = UInt32(value.backgroundColor.dropFirst(), radix: 16) ?? 0xFFFFFF
            return Color(red: Double((number >> 16) & 255) / 255, green: Double((number >> 8) & 255) / 255, blue: Double(number & 255) / 255)
        }, set: { chosen in
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            guard UIColor(chosen).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            value.backgroundColor = String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        })
    }
}

struct MobileFileThemeImagePicker: View {
    let model: MobileFileSettingsModel
    let kind: FileStationThemeImage.Kind
    let choose: (FileStationThemeImage) -> Void
    private enum Source: String { case nas, history, local, defaults }
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.nas
    @State private var path: String?
    @State private var files: [FileItem] = []
    @State private var images: [FileStationThemeImage] = []
    @State private var selected: FileStationThemeImage?
    @State private var preview: Data?
    @State private var localData: Data?
    @State private var localName = ""
    @State private var importing = false
    @State private var loading = false
    @State private var previewLoading = false
    @State private var error: String?
    @State private var offset = 0
    @State private var hasMore = false
    @State private var generation = UUID()
    @State private var previewGeneration = UUID()
    private var uploadTarget: String? { localData.map { MobileFileSettingsModel.uploadTarget(data: $0, kind: kind) } }
    var body: some View {
        NavigationStack {
            List {
                Picker(L10n.string("files.theme.source"), selection: $source) {
                    Text(L10n.string("files.theme.nas")).tag(Source.nas)
                    Text(L10n.string("files.theme.history")).tag(Source.history)
                    Text(L10n.string("mobile.file-settings.local-image")).tag(Source.local)
                    if kind == .background { Text(L10n.string("files.theme.defaults")).tag(Source.defaults) }
                }.disabled(model.busy)
                if source == .local {
                    Section {
                        Button(L10n.string("files.theme.chooseLocal")) { importing = true }.disabled(model.busy)
                        if !localName.isEmpty { Text(localName) }
                        Text(L10n.string("files.theme.uploadScope")).foregroundStyle(.secondary)
                    }
                } else {
                    if source == .nas, let path {
                        Button { let parent = (path as NSString).deletingLastPathComponent; self.path = parent == "/" ? nil : parent } label: {
                            Label(path, systemImage: "arrow.up").lineLimit(2).truncationMode(.middle).frame(minHeight: 44)
                        }.disabled(loading || model.busy).accessibilityLabel(L10n.string("ui.2bab713fde4ebc53"))
                    }
                    if loading && files.isEmpty && images.isEmpty { ProgressView() }
                    else if !loading && files.isEmpty && images.isEmpty && error == nil {
                        ContentUnavailableView(L10n.string("files.theme.empty"), systemImage: "photo", description: Text(L10n.string("mobile.file-settings.images-empty")))
                    }
                    ForEach(files) { file in
                        Button {
                            if file.isDirectory { path = file.path }
                            else { Task { await select(.init(kind: kind, source: .nas, path: file.path, name: file.name)) } }
                        } label: { Label(file.name, systemImage: file.isDirectory ? "folder" : "photo").frame(minHeight: 44) }
                            .disabled(loading || model.busy)
                    }
                    ForEach(images) { image in
                        Button(image.source == .systemDefault ? L10n.string("files.theme.defaultNumber", (images.firstIndex(of: image) ?? 0) + 1) : image.name) {
                            Task { await select(image) }
                        }.frame(minHeight: 44).disabled(loading || model.busy)
                    }
                    if hasMore { Button(L10n.string("files.principals.more")) { Task { await load(reset: false) } }.disabled(loading) }
                }
                if previewLoading { ProgressView() }
                if let preview, let image = UIImage(data: preview) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 280)
                        .accessibilityLabel(L10n.string("files.theme.preview"))
                }
                if let error { Section { Text(error).foregroundStyle(.red); if source != .local { Button(L10n.string("files.common.retry")) { Task { await load(reset: true) } } } } }
                if let uploadTarget, model.isBlocked(uploadTarget) {
                    Text(L10n.string("mobile.file-settings.upload-pending")).foregroundStyle(.secondary)
                }
                if model.recoveryFailed { Text(L10n.string("mobile.file-settings.recovery-error")).foregroundStyle(.red) }
                if source == .local {
                    Button(L10n.string("files.theme.uploadSelect")) { Task { await upload() } }
                        .disabled(localData == nil || !model.canWrite || uploadTarget.map(model.isBlocked) == true)
                } else {
                    Button(L10n.string("files.theme.select")) { if let selected, preview != nil { choose(selected); dismiss() } }
                        .disabled(selected == nil || preview == nil || previewLoading || loading || model.busy)
                }
            }.navigationTitle(L10n.string(kind == .logo ? "files.theme.chooseLogo" : "files.theme.chooseBackground")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("files.common.close")) { dismiss() } } }
                .task(id: source.rawValue + ":" + (path ?? "")) { await load(reset: true) }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.jpeg, .png, .gif, .bmp]) { result in
                    if case .success(let url) = result { readLocal(url) }
                    else if case .failure = result { error = L10n.string("files.theme.invalidImage") }
                }
                .onDisappear { generation = UUID(); previewGeneration = UUID(); localData = nil; preview = nil }
        }
    }
    private func load(reset: Bool) async {
        if reset {
            generation = UUID(); previewGeneration = UUID(); files = []; images = []; selected = nil; preview = nil; localData = nil
            localName = ""; offset = 0; hasMore = false; previewLoading = false
        } else if loading { return }
        let token = generation, source = source, path = path, start = offset
        loading = true; error = nil
        defer { if token == generation { loading = false } }
        do {
            switch source {
            case .nas:
                let page = try await model.read { repository in
                    if let path { return try await repository.listFolder(path: path, offset: start, limit: 200) }
                    return try await repository.listShares(offset: start, limit: 200)
                }
                guard token == generation else { return }
                let ids = Set(files.map(\.path))
                files += page.items.filter { !ids.contains($0.path) && ($0.isDirectory || $0.kind == .file && FileStationThemeImage.supportsFilename($0.name)) }
                offset = page.offset + page.items.count; hasMore = page.hasMore
            case .history:
                let result = try await model.read { try await $0.listFileStationThemeImages(kind: kind) }
                if token == generation { images = result }
            case .defaults: images = (1...10).map { .init(kind: .background, source: .systemDefault, path: "dsm7_0\($0).jpg", name: "dsm7_0\($0).jpg") }
            case .local: break
            }
        } catch is CancellationError { }
        catch { if token == generation { self.error = L10n.string("files.theme.imageLoadFailed") } }
    }
    private func select(_ image: FileStationThemeImage) async {
        let token = UUID(); previewGeneration = token
        selected = image; preview = nil; error = nil; previewLoading = true
        defer { if token == previewGeneration { previewLoading = false } }
        do {
            let data = try await model.read { try await $0.loadFileStationThemeImage(image) }
            guard token == previewGeneration else { return }
            guard UIImage(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
            preview = data
        } catch is CancellationError { }
        catch { if token == previewGeneration { self.error = L10n.string("files.theme.imageLoadFailed") } }
    }
    private func readLocal(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard FileStationThemeImage.supportsFilename(url.lastPathComponent), UIImage(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
            localData = data; preview = data; localName = url.lastPathComponent; error = nil
        } catch { localData = nil; preview = nil; self.error = L10n.string("files.theme.invalidImage") }
    }
    private func upload() async {
        guard let localData else { return }
        let token = generation
        if let image = await model.upload(data: localData, filename: localName, kind: kind), token == generation { choose(image); dismiss() }
    }
}
