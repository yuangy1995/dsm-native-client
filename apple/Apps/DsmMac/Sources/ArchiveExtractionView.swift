import DsmCore
import DsmLocalization
import SwiftUI

struct ArchiveExtractionView: View {
    let model: WorkspaceModel
    let item: FileItem
    let onExtract: (FileExtractionRequest, [ArchiveItem]) -> Void
    let onCancel: () -> Void
    @State private var browser: FileArchiveBrowserModel
    @State private var showsDestination = false
    @State private var confirmsOverwrite = false
    @State private var preparationError: String?
    @State private var preparation: Task<Void, Never>?

    init(model: WorkspaceModel, item: FileItem,
         onExtract: @escaping (FileExtractionRequest, [ArchiveItem]) -> Void, onCancel: @escaping () -> Void) {
        self.model = model; self.item = item; self.onExtract = onExtract; self.onCancel = onCancel
        _browser = State(initialValue: model.makeArchiveBrowser(item))
    }

    var body: some View {
        @Bindable var browser = browser
        VStack(alignment: .leading, spacing: 12) {
            Text(item.name).font(.title2.bold())
            HStack {
                Text(L10n.string("files.archive.destination"))
                Text(browser.destination).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(L10n.string("files.archive.chooseDestination")) { showsDestination = true }
            }
            HStack {
                SecureField(L10n.string("files.archive.password"), text: $browser.password)
                    .onChange(of: browser.password) { _, _ in browser.invalidate() }
                Picker(L10n.string("files.archive.encoding"), selection: $browser.encoding) {
                    Text(L10n.string("files.archive.encoding.auto")).tag("")
                    Text(L10n.string("files.archive.encoding.chs")).tag("chs")
                    Text(L10n.string("files.archive.encoding.cht")).tag("cht")
                    Text(L10n.string("files.archive.encoding.enu")).tag("enu")
                    Text(L10n.string("files.archive.encoding.jpn")).tag("jpn")
                    Text(L10n.string("files.archive.encoding.krn")).tag("krn")
                }.onChange(of: browser.encoding) { _, _ in browser.invalidate() }
                Button(L10n.string("files.archive.read")) { Task { await browser.reload() } }
                    .disabled(browser.isLoading)
            }.textFieldStyle(.roundedBorder).disabled(browser.isLoading)
            HStack {
                Button { Task { await browser.back() } } label: {
                    Label(L10n.string("ui.8e7847be62b68c2b"), systemImage: "arrow.up")
                }.disabled(browser.parents.isEmpty || browser.isLoading)
                Text(browser.currentFolder).lineLimit(1)
                Spacer()
                Picker(L10n.string("files.archive.scope"), selection: $browser.extractAll) {
                    Text(L10n.string("files.archive.all")).tag(true)
                    Text(L10n.string("files.archive.selected")).tag(false)
                }.frame(width: 230)
            }
            Group {
                if browser.isLoading && browser.items.isEmpty { ProgressView().fillsAvailableContentArea() }
                else if let error = browser.error {
                    ContentUnavailableView(L10n.string("files.archive.loadFailed"), systemImage: "exclamationmark.triangle", description: Text(error))
                        .fillsAvailableContentArea()
                } else if browser.items.isEmpty {
                    ContentUnavailableView(L10n.string("files.archive.empty"), systemImage: "archivebox",
                        description: Text(L10n.string("files.archive.emptyNext"))).fillsAvailableContentArea()
                } else {
                    List {
                        ForEach(browser.items, id: \.id) { entry in
                            HStack {
                                if !browser.extractAll {
                                    Toggle(isOn: Binding(get: { browser.selected[entry.id] != nil },
                                                        set: { browser.selected[entry.id] = $0 ? entry : nil })) { Text(entry.name) }
                                } else { Text(entry.name) }
                                Spacer()
                                if entry.isDirectory {
                                    Button { Task { await browser.enter(entry) } } label: {
                                        Label(L10n.string("files.archive.openFolder"), systemImage: "folder")
                                    }.disabled(browser.isLoading)
                                }
                            }
                        }
                        if browser.hasMore {
                            Button(L10n.string("files.archive.more")) { Task { await browser.more() } }.disabled(browser.isLoading)
                        }
                    }
                }
            }.frame(minHeight: 180, maxHeight: .infinity)
            HStack {
                Toggle(L10n.string("ui.82e9111f1c4f130c"), isOn: $browser.createSubfolder)
                Toggle(L10n.string("ui.afd0935d8e0eeb33"), isOn: $browser.keepDirectories)
                Toggle(L10n.string("ui.c834c7a717bae791"), isOn: $browser.overwrite)

            }
            .disabled(browser.isLoading)
            if let preparationError { Text(preparationError).foregroundStyle(.red) }
            HStack {
                if browser.isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { preparation?.cancel(); onCancel() }
                Button(L10n.string("ui.d63e300f62a9a232")) {
                    if browser.overwrite { confirmsOverwrite = true } else { start() }
                }.buttonStyle(.borderedProminent).disabled(!browser.canExtract)
            }
        }.padding(24).frame(width: 720, height: 620)
            .task { await browser.reload() }
            .macSheet(isPresented: $showsDestination) {
                FileLocationPicker(model: model) { browser.destination = $0 }
            }
            .alert(L10n.string("ui.cf24ad005620d2c7"), isPresented: $confirmsOverwrite) {
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
                Button(L10n.string("ui.3fcff1dca38adc47"), role: .destructive, action: start)
            } message: { Text(L10n.string("ui.a8bca50469cec17d")) }
    }
    private func start() {
        preparationError = nil
        preparation = Task {
            do {
                let (request, inventory) = try await browser.prepare()
                try Task.checkCancellation()
                onExtract(request, inventory)
            } catch is CancellationError { return }
            catch { preparationError = (error as? AppError)?.safeUserMessage ?? L10n.string("files.archive.loadFailed") }
        }
    }
}
