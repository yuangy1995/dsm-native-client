import DsmCore
import DsmFileFeature
import DsmLocalization
import DsmNetwork
import SwiftUI

struct MobileFileCompressionView: View {
    let items: [FileItem]
    let repository: DsmFileRepository
    let queue: MobileFileArchiveQueue
    @State var destination: String
    @State private var name = ""
    @State private var format = ArchiveFormat.zip
    @State private var level = ArchiveCompressionLevel.moderate
    @State private var password = ""
    @State private var showsDestination = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(items) { Text($0.name).accessibilityIdentifier("files.archive.source." + $0.path) }
                }
                Section {
                    TextField(L10n.string("mobile.archive.name"), text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("files.archive.name")
                    Picker(L10n.string("mobile.archive.format"), selection: $format) {
                        Text(L10n.string("mobile.archive.format.zip")).tag(ArchiveFormat.zip)
                        Text(L10n.string("mobile.archive.format.sevenZip")).tag(ArchiveFormat.sevenZip)
                    }
                    Picker(L10n.string("mobile.archive.level"), selection: $level) {
                        ForEach(ArchiveCompressionLevel.allCases, id: \.self) { value in
                            Text(value.mobileTitle).tag(value)
                        }
                    }
                    SecureField(L10n.string("files.archive.password"), text: $password)
                    Button { showsDestination = true } label: {
                        LabeledContent(L10n.string("mobile.archive.destination"), value: destination)
                    }
                }
                if let error = queue.error ?? queue.recoveryError { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle(L10n.string("mobile.archive.compress"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.archive.compress")) {
                        if queue.compress(items: items, destination: destination, name: name, format: format,
                            level: level, password: password.isEmpty ? nil : password) { dismiss() }
                    }.accessibilityIdentifier("files.archive.start-compression")
                    .disabled(items.isEmpty || MobileFileArchiveQueue.filename(name, format: format) == nil || !MobileFileArchiveQueue.validFolder(destination))
                }
            }
        }
        .sheet(isPresented: $showsDestination) {
            MobileFileFolderPicker(repository: repository) { destination = $0 }
        }
    }
}

struct MobileFileExtractionView: View {
    let repository: DsmFileRepository
    let queue: MobileFileArchiveQueue
    @State private var browser: FileArchiveBrowserModel
    @State private var showsDestination = false
    @State private var confirmsOverwrite = false
    @State private var error: String?
    @State private var preparation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    init(item: FileItem, destination: String, repository: DsmFileRepository, queue: MobileFileArchiveQueue) {
        self.repository = repository; self.queue = queue
        _browser = State(initialValue: FileArchiveBrowserModel(item: item, destination: destination, repository: repository))
    }
    var body: some View {
        @Bindable var browser = browser
        NavigationStack {
            Form {
                Section {
                    Text(browser.item.name)
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
                }.disabled(browser.isLoading)
                contents
                Section {
                    Button { showsDestination = true } label: {
                        LabeledContent(L10n.string("files.archive.destination"), value: browser.destination)
                    }
                    Toggle(L10n.string("mobile.archive.subfolder"), isOn: $browser.createSubfolder)
                    Toggle(L10n.string("mobile.archive.keep-folders"), isOn: $browser.keepDirectories)
                    Toggle(L10n.string("ui.c834c7a717bae791"), isOn: $browser.overwrite)
                }.disabled(browser.isLoading)
                if let error = error ?? browser.error ?? queue.error ?? queue.recoveryError {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(L10n.string("mobile.archive.extract"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.archive.extract")) {
                        if browser.overwrite { confirmsOverwrite = true } else { start() }
                    }.disabled(!browser.canExtract || preparation != nil).accessibilityIdentifier("files.archive.start-extraction")
                }
            }
        }
        .task { await browser.reload() }
        .sheet(isPresented: $showsDestination) {
            MobileFileFolderPicker(repository: repository) { browser.destination = $0 }
        }
        .alert(L10n.string("ui.cf24ad005620d2c7"), isPresented: $confirmsOverwrite) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("ui.3fcff1dca38adc47"), role: .destructive, action: start)
        } message: { Text(L10n.string("ui.a8bca50469cec17d")) }
        .onDisappear { preparation?.cancel(); browser.invalidate() }
    }
    private var contents: some View {
        @Bindable var browser = browser
        return Section {
            Picker(L10n.string("files.archive.scope"), selection: $browser.extractAll) {
                Text(L10n.string("files.archive.all")).tag(true)
                Text(L10n.string("files.archive.selected")).tag(false)
            }
            if !browser.parents.isEmpty {
                Button { Task { await browser.back() } } label: {
                    Label(browser.currentFolder, systemImage: "chevron.backward")
                }.disabled(browser.isLoading)
            }
            if browser.isLoading { ProgressView(L10n.string("files.archive.read")) }
            if browser.hasLoaded && browser.items.isEmpty {
                Text(L10n.string("files.archive.emptyNext")).foregroundStyle(.secondary)
            }
            ForEach(browser.items, id: \.id) { item in
                HStack {
                    if !browser.extractAll {
                        Button {
                            if browser.selected[item.id] == nil { browser.selected[item.id] = item }
                            else { browser.selected[item.id] = nil }
                        } label: {
                            Image(systemName: browser.selected[item.id] == nil ? "circle" : "checkmark.circle.fill")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.string("mobile.archive.select-item", item.name))
                        .accessibilityAddTraits(browser.selected[item.id] == nil ? [] : [.isSelected])
                    }
                    Label(item.name, systemImage: item.isDirectory ? "folder" : "doc").lineLimit(2)
                    Spacer()
                    if item.isDirectory {
                        Button { Task { await browser.enter(item) } } label: {
                            Image(systemName: "chevron.forward").frame(width: 44, height: 44)
                        }.buttonStyle(.borderless).accessibilityLabel(L10n.string("files.archive.openFolder"))
                    }
                }.disabled(browser.isLoading)
            }
            if browser.hasMore {
                Button(L10n.string("files.archive.more")) { Task { await browser.more() } }.disabled(browser.isLoading)
            }
        }
    }
    private func start() {
        guard preparation == nil else { return }; error = nil
        preparation = Task {
            defer { preparation = nil }
            do {
                let (request, inventory) = try await browser.prepare()
                try Task.checkCancellation()
                if queue.extract(item: browser.item, request: request, inventory: inventory) { dismiss() }
            } catch is CancellationError {} catch {
                self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.archive.loadFailed")
            }
        }
    }
}

struct MobileFileArchiveSections: View {
    @Bindable var queue: MobileFileArchiveQueue
    let filter: MobileActivityFilter
    @State private var cancelling: UUID?
    var body: some View {
        content.alert(L10n.string("mobile.archive.stop-title"), isPresented: Binding(
            get: { cancelling != nil }, set: { if !$0 { cancelling = nil } })) {
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { cancelling = nil }
                Button(L10n.string("mobile.archive.stop"), role: .destructive) {
                    if let id = cancelling { queue.cancel(id) }; cancelling = nil
                }
            } message: { Text(L10n.string("mobile.archive.stop-message")) }
    }
    @ViewBuilder private var content: some View {
        if let error = queue.error ?? queue.recoveryError { Section { Text(error).foregroundStyle(.red) } }
        let records = queue.records.filter { filter.includes(active: $0.isActive) }
        if !records.isEmpty {
            Section(L10n.string("mobile.archive.tasks")) {
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(record.name, systemImage: record.extraction ? "archivebox.fill" : "archivebox")
                            .font(.headline)
                        Text(record.destination).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Text(record.phase.title)
                            .accessibilityIdentifier("files.archive.phase." + record.phase.rawValue)
                        if record.phase == .running {
                            if let fraction = record.fraction { ProgressView(value: fraction) } else { ProgressView() }
                        }
                        if record.phase == .interrupted {
                            Text(L10n.string("mobile.archive.interrupted")).font(.callout).foregroundStyle(.secondary)
                            if record.acknowledged {
                                Button(L10n.string("ui.aee88743413144a2")) { Task { await queue.refresh(record.id) } }
                                    .disabled(queue.refreshing.contains(record.id))
                            }
                        }
                        if [.preparing, .running].contains(record.phase), queue.isRunning(record.id) {
                            Button(L10n.string("mobile.archive.stop"), role: .destructive) { cancelling = record.id }
                        } else if [.completed, .failed].contains(record.phase) {
                            Button(L10n.string("mobile.archive.remove-record")) { queue.removeFinished(record.id) }
                        }
                    }.padding(.vertical, 4)
                }
            }
        }

    }
}

private extension ArchiveCompressionLevel {
    var mobileTitle: String {
        switch self {
        case .moderate: L10n.string("mobile.archive.level.moderate")
        case .store: L10n.string("mobile.archive.level.store")
        case .fastest: L10n.string("mobile.archive.level.fastest")
        case .best: L10n.string("mobile.archive.level.best")
        }
    }
}
private extension MobileFileArchiveQueue.Phase {
    var title: String {
        switch self {
        case .preparing: L10n.string("mobile.archive.phase.preparing")
        case .running: L10n.string("mobile.archive.phase.running")
        case .interrupted: L10n.string("mobile.archive.phase.interrupted")
        case .completed: L10n.string("mobile.archive.phase.completed")
        case .failed: L10n.string("mobile.archive.phase.failed")
        }
    }
}
