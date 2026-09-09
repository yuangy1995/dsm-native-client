import AppKit
import DsmCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import DsmLocalization

extension ContainerManagerPane {
    var title: String {
        switch self {
        case .overview: L10n.string("ui.a33db573055626c5")
        case .containers: L10n.string("ui.6d23f04b26967d64")
        case .images: L10n.string("ui.ceb4432ba2356217")
        case .networks: L10n.string("ui.97b31b5d63f57e51")
        case .projects: L10n.string("ui.79f326be4409d51f")
        case .events: L10n.string("ui.f98dfe0b4d543087")
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .networks: "network"
        case .projects: "folder"
        case .events: "clock.arrow.circlepath"
        }
    }
}

extension VirtualMachineManagerPane {
    var title: String {
        switch self {
        case .machines: L10n.string("ui.f3fb4b3a41570007")
        case .hosts: L10n.string("ui.e87d9f23a3f5a830")
        case .storages: L10n.string("ui.a3434acddb75d8fb")
        case .networks: L10n.string("ui.97b31b5d63f57e51")
        case .images: L10n.string("ui.ceb4432ba2356217")
        case .protection: L10n.string("ui.0f810a7901cf0422")
        case .events: L10n.string("ui.7dbac1c20f237bd4")
        }
    }

    var icon: String {
        switch self {
        case .machines: "desktopcomputer"
        case .hosts: "server.rack"
        case .storages: "internaldrive"
        case .networks: "network"
        case .images: "square.stack.3d.up"
        case .protection: "shield.checkered"
        case .events: "doc.text.magnifyingglass"
        }
    }
}

struct ServiceManagementView: View {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    let module: ServiceManagementModel.Module
    @Bindable var model: ServiceManagementModel
    let containerPane: ContainerManagerPane
    let virtualMachinePane: VirtualMachineManagerPane
    let onSelectContainerPane: @MainActor @Sendable (ContainerManagerPane) -> Void
    let onSelectVirtualMachinePane: @MainActor @Sendable (VirtualMachineManagerPane) -> Void

    init(
        module: ServiceManagementModel.Module,
        model: ServiceManagementModel,
        containerPane: ContainerManagerPane = .overview,
        virtualMachinePane: VirtualMachineManagerPane = .machines,
        onSelectContainerPane: @escaping @MainActor @Sendable (ContainerManagerPane) -> Void = { _ in },
        onSelectVirtualMachinePane: @escaping @MainActor @Sendable (VirtualMachineManagerPane) -> Void = { _ in }
    ) {
        self.module = module
        self.model = model
        self.containerPane = containerPane
        self.virtualMachinePane = virtualMachinePane
        self.onSelectContainerPane = onSelectContainerPane
        self.onSelectVirtualMachinePane = onSelectVirtualMachinePane
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Group {
                    switch module {
                    case .downloads:
                        DownloadStationView(model: model)
                    case .containers:
                        ContainerManagerView(
                            model: model,
                            pane: containerPane,
                            onSelectPane: onSelectContainerPane
                        )
                    case .virtualMachines:
                        VirtualMachineManagerView(
                            model: model,
                            pane: virtualMachinePane,
                            onSelectPane: onSelectVirtualMachinePane
                        )
                    }
                }

                if let message = model.message {
                    FloatingToastView(
                        message: message,
                        isError: model.messageIsError,
                        onDismiss: { model.message = nil }
                    )
                    .padding(.top, max(24, geo.size.height * 0.20))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(999)
                }
            }
        }
        .animation(reducesMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: model.message)
        .macThemedScrollContent(selection: [model.downloadSelection, model.containerSelection, model.imageSelection,
            model.networkSelection, model.virtualMachineSelection, model.virtualMachineNetworkSelection, model.virtualMachineImageSelection])
        .task(id: module) {
            await model.activate(module)
        }
        .task(id: model.message) {
            if model.message != nil {
                try? await Task.sleep(for: .seconds(3.5))
                withAnimation(reducesMotion ? nil : .default) {
                    model.message = nil
                }
            }
        }
    }
}

private struct ServiceHeader: View {
    let title: String
    let subtitle: String
    let isLoading: Bool
    let refresh: () -> Void

    var body: some View {
        MacPageHeader(title: title, subtitle: subtitle) {
            if isLoading {
                ProgressView().controlSize(.small).accessibilityLabel(L10n.string("ui.30fa385526238641"))
            }
            Button(action: refresh) {
                Label(L10n.string("ui.aee88743413144a2"), systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
            .keyboardShortcut("r", modifiers: .command)
            .buttonStyle(MacToolbarButtonStyle())
        }
    }
}

private struct FloatingToastView: View {
    let message: String
    let isError: Bool
    let onDismiss: () -> Void

    private var statusColor: Color {
        isError ? .red : .green
    }

    private var statusIcon: String {
        isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusIcon)
                .font(.headline)
                .foregroundStyle(statusColor)

            Text(message)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .background(
            Capsule()
                .fill(statusColor.opacity(0.12))
        )
        .overlay(
            Capsule()
                .stroke(statusColor.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyServiceState: View {
    let title: String
    let message: String
    let icon: String

    var body: some View {
        ContentUnavailableView(title, systemImage: icon, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DownloadStationView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case active
        case finished
        case paused

        var id: Self { self }
        var title: String {
            switch self {
            case .all: L10n.string("ui.5c55a67935af8f45")
            case .active: L10n.string("ui.dc9591e56d502b43")
            case .finished: L10n.string("ui.f28461bb49c85647")
            case .paused: L10n.string("ui.eb0c326b60ae897a")
            }
        }
    }

    @Bindable var model: ServiceManagementModel
    @State private var filter: Filter = .all
    @State private var showsCreate = false
    @State private var showsSettings = false
    @State private var deleteChoice: DeleteChoice?

    private enum DeleteChoice {
        case taskOnly
        case taskAndData
    }

    private var tasks: [DownloadStationTask] {
        let source = model.downloads?.tasks ?? []
        return source.filter { task in
            let status = task.status.lowercased()
            switch filter {
            case .all:
                return true
            case .active:
                return ["downloading", "uploading", "seeding", "waiting", "hash_checking"]
                    .contains(status)
            case .finished:
                return ["finished", "completed"].contains(status)
            case .paused:
                return ["paused", "stopped"].contains(status)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ServiceHeader(
                title: L10n.string("ui.5248507df52ff455"),
                subtitle: speedSummary,
                isLoading: model.isLoading
            ) { Task { await model.activate(.downloads, force: true) } }

            HStack(spacing: 12) {
                MacPageTabs(options: Filter.allCases, selection: $filter, title: { $0.title })
                    .frame(maxWidth: 360)
                Spacer(minLength: 0)
                HStack {
                    Button {
                        Task { await model.controlDownloads(.resume) }
                    } label: {
                        Label(L10n.string("ui.7c9691192f1b7340"), systemImage: "play.fill")
                    }
                    .disabled(!model.canControlDownloads(.resume))
                    .labelStyle(.iconOnly)
                    .help(L10n.string("ui.7c9691192f1b7340"))
                    Button {
                        Task { await model.controlDownloads(.pause) }
                    } label: {
                        Label(L10n.string("ui.8d12fc0d4eb26021"), systemImage: "pause.fill")
                    }
                    .disabled(!model.canControlDownloads(.pause))
                    .labelStyle(.iconOnly)
                    .help(L10n.string("ui.8d12fc0d4eb26021"))
                    Menu {
                        Button(L10n.string("ui.3a72267129185266"), role: .destructive) {
                            deleteChoice = .taskOnly
                        }
                        Button(L10n.string("ui.810ad53a1c16de5d"), role: .destructive) {
                            deleteChoice = .taskAndData
                        }
                    } label: {
                        Label(L10n.string("ui.6135d4159e892541"), systemImage: "trash")
                    }
                    .disabled(model.downloadSelection.isEmpty || model.isPerformingAction)
                    .labelStyle(.iconOnly)
                    Button {
                        showsSettings = true
                    } label: {
                        Label(L10n.string("ui.df3d58c7d84b85f2"), systemImage: "gearshape")
                    }
                    .disabled(model.isPerformingAction)
                    .labelStyle(.iconOnly)
                    .help(L10n.string("ui.df3d58c7d84b85f2"))
                    Button {
                        showsCreate = true
                    } label: {
                        Label(L10n.string("ui.52b312406b04b9a7"), systemImage: "plus")
                    }
                    .buttonStyle(MacToolbarButtonStyle(prominent: true))
                    .disabled(model.isPerformingAction)
                }
                .buttonStyle(MacToolbarButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(MacGlassSurface(role: .toolbar))
            Divider()

            if tasks.isEmpty, !model.isLoading {
                EmptyServiceState(
                    title: filter == .all ? L10n.string("ui.1640d50f8dbf6fa3") : L10n.string("ui.1c125edbf975b9ba"),
                    message: L10n.string("ui.dbf81937e698b1dc"),
                    icon: "arrow.down.doc"
                )
            } else {
                List(tasks, selection: $model.downloadSelection) { task in
                    DownloadTaskRow(task: task)
                        .tag(task.id)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .contextMenu {
                            if ServiceManagementModel.supportsDownloadAction(.resume, task: task) {
                                Button(L10n.string("ui.7c9691192f1b7340")) {
                                    model.downloadSelection = [task.id]
                                    Task { await model.controlDownloads(.resume) }
                                }
                                .disabled(model.isPerformingAction)
                            }
                            if ServiceManagementModel.supportsDownloadAction(.pause, task: task) {
                                Button(L10n.string("ui.8d12fc0d4eb26021")) {
                                    model.downloadSelection = [task.id]
                                    Task { await model.controlDownloads(.pause) }
                                }
                                .disabled(model.isPerformingAction)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
        .macSheet(isPresented: $showsCreate) {
            CreateDownloadSheet(
                defaultDestination: model.downloads?.defaultDestination,
                loadFolders: { path in
                    try await model.loadDownloadDestinationFolders(in: path)
                },
                submitURL: { uri, destination in
                    let succeeded = await model.createDownload(uri: uri, destination: destination)
                    if succeeded { showsCreate = false }
                    return succeeded
                },
                submitFile: { fileURL, destination, unzipPassword in
                    let succeeded = await model.createDownload(
                        fileURL: fileURL,
                        destination: destination,
                        unzipPassword: unzipPassword
                    )
                    if succeeded { showsCreate = false }
                    return succeeded
                }
            )
        }
        .macSheet(isPresented: $showsSettings) {
            DownloadSettingsSheet(
                loadFolders: { path in
                    try await model.loadDownloadDestinationFolders(in: path)
                },
                load: {
                    try await model.loadDownloadSettings()
                },
                save: { settings in
                    let succeeded = await model.saveDownloadSettings(settings)
                    if succeeded { showsSettings = false }
                    return succeeded
                }
            )
        }
        .confirmationDialog(
            L10n.string("ui.f0b382eeac27d246"),
            isPresented: Binding(
                get: { deleteChoice != nil },
                set: { if !$0 { deleteChoice = nil } }
            )
        ) {
            Button(
                deleteChoice == .taskAndData ? L10n.string("ui.631851c80f615dc3") : L10n.string("ui.3a72267129185266"),
                role: .destructive
            ) {
                let removeData = deleteChoice == .taskAndData
                deleteChoice = nil
                Task { await model.deleteDownloads(removeData: removeData) }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { deleteChoice = nil }
        } message: {
            Text(
                deleteChoice == .taskAndData
                    ? L10n.string("ui.7ee4c98525fb52f7")
                    : L10n.string("ui.3719b045e8772446")
            )
        }
    }

    private var speedSummary: String {
        let down = ServiceFormat.speed(model.downloads?.downloadBytesPerSecond ?? 0)
        let up = ServiceFormat.speed(model.downloads?.uploadBytesPerSecond ?? 0)
        return L10n.string("ui.22779f62aa21a7ad", String(describing: down), String(describing: up))
    }
}

private struct DownloadTaskRow: View {
    let task: DownloadStationTask

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                Text(task.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                Text(ServiceFormat.status(task.status))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            if let progress = task.progress {
                ProgressView(value: progress)
                    .accessibilityLabel(task.title)
                    .accessibilityValue("\(Int(progress * 100))%")
            }
            HStack {
                Text(sizeSummary)
                Spacer()
                Label(
                    ServiceFormat.speed(task.downloadBytesPerSecond ?? 0),
                    systemImage: "arrow.down"
                )
                Label(
                    ServiceFormat.speed(task.uploadBytesPerSecond ?? 0),
                    systemImage: "arrow.up"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .macDataRowSurface()
        .accessibilityElement(children: .combine)
    }

    private var sizeSummary: String {
        guard let total = task.sizeBytes else { return L10n.string("ui.f8f5f153c20d00b9") }
        let completed = ServiceFormat.bytes(task.downloadedBytes ?? 0)
        return "\(completed) / \(ServiceFormat.bytes(total))"
    }

    private var statusIcon: String {
        switch task.status.lowercased() {
        case "finished", "completed": "checkmark.circle.fill"
        case "paused", "stopped": "pause.circle.fill"
        case "error": "exclamationmark.triangle.fill"
        default: "arrow.down.circle.fill"
        }
    }

    private var statusColor: Color {
        switch task.status.lowercased() {
        case "finished", "completed": .green
        case "paused", "stopped": .orange
        case "error": .red
        default: .blue
        }
    }
}

struct CreateDownloadSheet: View {
    private enum Source: String, CaseIterable, Identifiable {
        case file
        case url

        var id: Self { self }
        var title: String {
            switch self {
            case .file: L10n.string("ui.4c8a4e3da39e5c2a")
            case .url: L10n.string("ui.abb7b877109a1746")
            }
        }
    }

    let defaultDestination: String?
    let loadFolders: (String?) async throws -> [FileItem]
    let submitURL: (String, String?) async -> Bool
    let submitFile: (URL, String?, String?) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .file
    @State private var uri = ""
    @State private var selectedFileURL: URL?
    @State private var unzipPassword = ""
    @State private var destination = ""
    @State private var isSubmitting = false
    @State private var showsDestinationPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("ui.52b312406b04b9a7")).font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(MacGlassSurface(role: .toolbar).clipShape(RoundedRectangle(cornerRadius: 12)))
            MacPageTabs(options: Source.allCases, selection: $source, title: { $0.title })
                .accessibilityLabel(L10n.string("ui.1f39096f50fcbc99"))
            Form {
                if source == .file {
                    LabeledContent(L10n.string("ui.00a38e1c717a7a03")) {
                        HStack(spacing: 8) {
                            Label(
                                selectedFileURL?.lastPathComponent ?? L10n.string("ui.a96f374e86bc73e4"),
                                systemImage: "doc.badge.plus"
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Button(L10n.string("ui.29d75b8eb8866bb4"), action: chooseTaskFile)
                        }
                    }
                    SecureField(L10n.string("ui.c2a29d7321f21fa1"), text: $unzipPassword)
                } else {
                    TextField(L10n.string("ui.5518511f5b5add04"), text: $uri, axis: .vertical)
                        .lineLimit(3...6)
                }
                LabeledContent(L10n.string("ui.0b7e2876922e4662")) {
                    HStack(spacing: 8) {
                        Label(destinationDisplay, systemImage: "folder")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(L10n.string("ui.27978521d005ac46", String(describing: destinationDisplay)))
                        if destination != normalizedDefaultDestination {
                            Button(L10n.string("ui.ba2e93e73037c71e")) {
                                destination = normalizedDefaultDestination
                            }
                        }
                        Button(L10n.string("ui.4aea6b5ff7a5857c")) {
                            showsDestinationPicker = true
                        }
                    }
                }
            }
            Text(helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { dismiss() }
                Button(L10n.string("ui.52b312406b04b9a7")) {
                    isSubmitting = true
                    Task {
                        let selectedDestination =
                            destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? defaultDestination
                            : destination
                        switch source {
                        case .file:
                            if let selectedFileURL {
                                _ = await submitFile(
                                    selectedFileURL,
                                    selectedDestination,
                                    unzipPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                                )
                            }
                        case .url:
                            _ = await submitURL(uri, selectedDestination)
                        }
                        isSubmitting = false
                    }
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(!canSubmit || isSubmitting)
            }
            .buttonStyle(MacToolbarButtonStyle())
        }
        .padding(24)
        .frame(width: 620)
        .fillsAvailableContentArea(alignment: .topLeading)
        .background(MacGlassSurface(role: .sidebar))
        .onAppear { destination = normalizedDefaultDestination }
        .macSheet(isPresented: $showsDestinationPicker) {
            DownloadDestinationPicker(
                selectedDestination: destination,
                loadFolders: loadFolders,
                onSelect: {
                    destination = $0
                    showsDestinationPicker = false
                },
                onCancel: {
                    showsDestinationPicker = false
                }
            )
        }
    }

    private var normalizedDefaultDestination: String {
        Self.normalizeDestination(defaultDestination ?? "")
    }

    private var destinationDisplay: String {
        destination.isEmpty ? L10n.string("ui.113d2c57a282180f") : "/\(destination)"
    }

    private var canSubmit: Bool {
        switch source {
        case .file:
            selectedFileURL != nil
        case .url:
            !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var helpText: String {
        switch source {
        case .file:
            L10n.string("ui.c879b7fd860d70d4")
        case .url:
            L10n.string("ui.9dc5f2124edb52cc")
        }
    }

    private func chooseTaskFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("ui.525bd66f339aafa2")
        panel.prompt = L10n.string("ui.c11330b85234f9c0")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["torrent", "nzb", "txt"].compactMap {
            UTType(filenameExtension: $0)
        }
        guard panel.runModal() == .OK else { return }
        selectedFileURL = panel.url
    }

    private static func normalizeDestination(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

struct DownloadSettingsSheet: View {
    let loadFolders: (String?) async throws -> [FileItem]
    let load: () async throws -> DownloadStationSettings
    let save: (DownloadStationSettings) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var settings: DownloadStationSettings?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showsDestinationPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("ui.f988df886e7d7e73")).font(.title2.weight(.semibold))
                Spacer()
                if isLoading || isSaving {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)
            .background(MacGlassSurface(role: .toolbar).clipShape(RoundedRectangle(cornerRadius: 12)))

            if let settingsBinding {
                Form {
                    Section(L10n.string("ui.40fae00b7c6d8ac0")) {
                        LabeledContent(L10n.string("ui.22939a4ebb0b8d00")) {
                            HStack(spacing: 8) {
                                Label(
                                    destinationDisplay(settingsBinding.wrappedValue),
                                    systemImage: "folder"
                                )
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button(L10n.string("ui.4aea6b5ff7a5857c")) {
                                    showsDestinationPicker = true
                                }
                            }
                        }
                        Toggle(L10n.string("ui.36ec0018d6d2e3cf"), isOn: settingsBinding.isEMuleEnabled)
                        Toggle(L10n.string("ui.1ec1e57766d7769a"), isOn: settingsBinding.isAutoExtractEnabled)
                    }

                    Section(L10n.string("ui.b4b2fe2e349f95a5")) {
                        speedField(L10n.string("ui.72f4d786f20ef7d0"), value: settingsBinding.btDownloadLimit)
                        speedField(L10n.string("ui.4475d765a50bb50e"), value: settingsBinding.btUploadLimit)
                        speedField(L10n.string("ui.6669be0cf447b7bc"), value: webLimitBinding(settingsBinding))
                        speedField(L10n.string("ui.810040fd1925dbd0"), value: settingsBinding.nzbDownloadLimit)
                        speedField(L10n.string("ui.9d6bf94d4704e700"), value: settingsBinding.emuleDownloadLimit)
                        speedField(L10n.string("ui.6c4096f61b5a084f"), value: settingsBinding.emuleUploadLimit)
                        Text(L10n.string("ui.4b7f80b866336348"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section(L10n.string("ui.d2375298b39b3c94")) {
                        Toggle(L10n.string("ui.f6075112320525c0"), isOn: settingsBinding.isScheduleEnabled)
                        Toggle(L10n.string("ui.c24278e3a16b4c52"), isOn: settingsBinding.isEMuleScheduleEnabled)
                            .disabled(!settingsBinding.wrappedValue.isScheduleEnabled)
                    }
                }
                .formStyle(.grouped)
                .macThemedScrollContent()
            } else if let errorMessage {
                ContentUnavailableView(
                    L10n.string("ui.7fdd539ffbe65c3f"),
                    systemImage: "gearshape.fill",
                    description: Text(errorMessage)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }

            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { dismiss() }
                Button(L10n.string("ui.a3030bf8f16dc63c")) {
                    guard let settings else { return }
                    isSaving = true
                    Task {
                        _ = await save(settings)
                        isSaving = false
                    }
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(settings == nil || isLoading || isSaving)
            }
            .buttonStyle(MacToolbarButtonStyle())
        }
        .padding(24)
        .frame(width: 680, height: 650)
        .background(MacGlassSurface(role: .sidebar))
        .task {
            do {
                settings = try await load()
            } catch let error as AppError {
                errorMessage = error.safeUserMessage
            } catch {
                errorMessage = L10n.string("ui.ab820ed96cf327c2")
            }
            isLoading = false
        }
        .macSheet(isPresented: $showsDestinationPicker) {
            DownloadDestinationPicker(
                selectedDestination: settings?.defaultDestination ?? "",
                loadFolders: loadFolders,
                onSelect: {
                    settings?.defaultDestination = $0
                    showsDestinationPicker = false
                },
                onCancel: {
                    showsDestinationPicker = false
                }
            )
        }
    }

    private var settingsBinding: Binding<DownloadStationSettings>? {
        guard settings != nil else { return nil }
        return Binding(
            get: { settings ?? DownloadStationSettings() },
            set: { settings = $0 }
        )
    }

    private func speedField(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("0", value: value, format: .number)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(title)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110)
                Text(L10n.string("unit.kilobytes_per_second")).foregroundStyle(.secondary)
            }
        }
    }

    private func webLimitBinding(
        _ settings: Binding<DownloadStationSettings>
    ) -> Binding<Int> {
        Binding(
            get: { settings.wrappedValue.ftpDownloadLimit },
            set: {
                settings.wrappedValue.httpDownloadLimit = max(0, $0)
                settings.wrappedValue.ftpDownloadLimit = max(0, $0)
            }
        )
    }

    private func destinationDisplay(_ settings: DownloadStationSettings) -> String {
        let path = settings.defaultDestination.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return path.isEmpty ? L10n.string("ui.88f6fc489aa185af") : "/\(path)"
    }
}

struct DownloadDestinationPicker: View {
    private struct Location {
        let path: String?
        let canWrite: Bool
    }

    let selectedDestination: String
    let loadFolders: (String?) async throws -> [FileItem]
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var location = Location(path: nil, canWrite: false)
    @State private var history: [Location] = []
    @State private var folders: [FileItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.9ee6e08b1f3e18a1"))
                    .font(.headline)
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))

            Divider()

            HStack(spacing: 8) {
                Button {
                    Task { await goBack() }
                } label: {
                    Label(L10n.string("ui.572cf45ba43634b3"), systemImage: "chevron.backward")
                }
                .labelStyle(.iconOnly)
                .disabled(history.isEmpty || isLoading)
                .help(L10n.string("ui.2bab713fde4ebc53"))
                Text(locationTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel(L10n.string("ui.4b8e2df221ec32ef", String(describing: locationTitle)))
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.string("ui.6b47f90bd6bd7cce"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))

            Group {
                if isLoading && folders.isEmpty {
                    ProgressView(L10n.string("ui.038b9263cfd8c1a8"))
                        .fillsAvailableContentArea()
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label(L10n.string("ui.c7046f4c767b4d60"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button(L10n.string("ui.35588dcb9be3dc8e")) {
                            Task { await reload() }
                        }
                    }
                    .fillsAvailableContentArea()
                } else if folders.isEmpty {
                    ContentUnavailableView(
                        L10n.string("ui.2e3012c9f8d17867"),
                        systemImage: "folder",
                        description: Text(
                            location.path == nil
                                ? L10n.string("ui.e5181b73526b80b5")
                                : L10n.string("ui.8ed1c0e8bd363f97")
                        )
                    )
                    .fillsAvailableContentArea()
                } else {
                    folderList
                }
            }

            Divider()

            HStack(spacing: 12) {
                Text(selectionHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { onCancel() }
                Button(L10n.string("ui.1ab259e4d2286371")) {
                    guard let path = location.path else { return }
                    onSelect(Self.downloadStationPath(from: path))
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(location.path == nil || !location.canWrite || isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
        }
        .frame(minWidth: 540, minHeight: 440)
        .macThemedScrollContent()
        .background(MacGlassSurface(role: .sidebar))
        .task { await reload() }
    }

    private var folderList: some View {
        List(folders) { folder in
            let canWrite = folder.permissions?.canWrite != false
            Button {
                Task { await open(folder) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: canWrite ? "folder.fill" : "folder.badge.minus")
                        .foregroundStyle(canWrite ? Color.blue : Color.secondary)
                        .accessibilityHidden(true)
                    Text(folder.name)
                        .lineLimit(1)
                    if Self.downloadStationPath(from: folder.path) == selectedDestination {
                        Text(L10n.string("ui.8d30e0eb426fee8f"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .accessibilityHint(
                canWrite
                    ? L10n.string("ui.fcf8b4bff0df782d")
                    : L10n.string("ui.32566e1138fc4714")
            )
        }
        .listStyle(.inset)
    }

    private var locationTitle: String {
        location.path ?? L10n.string("ui.8df2fa80a06c49b5")
    }

    private var selectionHint: String {
        guard location.path != nil else {
            return L10n.string("ui.1d6e8d61f9bf0615")
        }
        return location.canWrite
            ? L10n.string("ui.4678a2e85ab192f0")
            : L10n.string("ui.3160b68f56978d8b")
    }

    private func open(_ folder: FileItem) async {
        let previous = location
        history.append(previous)
        location = Location(
            path: folder.path,
            canWrite: folder.permissions?.canWrite != false
        )
        await reload()
    }

    private func goBack() async {
        guard let previous = history.popLast() else { return }
        location = previous
        await reload()
    }

    private func reload() async {
        isLoading = true
        errorMessage = nil
        do {
            folders = try await loadFolders(location.path)
            isLoading = false
        } catch {
            folders = []
            errorMessage = (error as? AppError)?.safeUserMessage
                ?? L10n.string("ui.44a58a5148d0b6dd")
            isLoading = false
        }
    }

    private static func downloadStationPath(from fileStationPath: String) -> String {
        fileStationPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private struct ContainerManagerView: View {
    @Bindable var model: ServiceManagementModel
    let pane: ContainerManagerPane
    let onSelectPane: @MainActor @Sendable (ContainerManagerPane) -> Void
    @State private var confirmsContainerDelete = false
    @State private var confirmsImageDelete = false
    @State private var confirmsNetworkDelete = false
    @State private var showsPullImage = false
    @State private var showsCreateNetwork = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ServiceHeader(
                title: L10n.string("ui.aaf778d85ce5c2ed"),
                subtitle: containerSummary,
                isLoading: model.isLoading
            ) { Task { await model.activate(.containers, force: true) } }
            MacPageTabs(options: ContainerManagerPane.allCases, selection: paneSelection, title: { $0.title })
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(MacGlassSurface(role: .toolbar))
            Divider()

            Group {
                switch pane {
                case .overview: overview
                case .containers: containerList
                case .images: imageList
                case .networks: networkList
                case .projects: projectList
                case .events: eventList(model.containers?.events ?? [])
                }
            }
            .padding(20)
            .buttonStyle(MacToolbarButtonStyle())
        }
        .confirmationDialog(L10n.string("ui.e63f7b537862f807"), isPresented: $confirmsContainerDelete) {
            Button(L10n.string("ui.60fc3386091b5647"), role: .destructive) {
                Task { await model.deleteContainers() }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.d146f8b315800ce5"))
        }
        .confirmationDialog(L10n.string("ui.08e648b8e120039f"), isPresented: $confirmsImageDelete) {
            Button(L10n.string("ui.17f38b5ced278466"), role: .destructive) {
                Task { await model.deleteImages() }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.0b16ae28e158fd97"))
        }
        .confirmationDialog(L10n.string("ui.ee4929b66715cd3c"), isPresented: $confirmsNetworkDelete) {
            Button(L10n.string("ui.8e3a6be52ed69dde"), role: .destructive) {
                Task { await model.deleteNetworks() }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.cd8a980b07eec901"))
        }
        .macSheet(isPresented: $showsPullImage) {
            PullImageSheet(
                search: { try await model.searchImages(query: $0) },
                loadTags: { try await model.loadImageTags(repositoryName: $0) },
                submit: { repository, tag in
                    let succeeded = await model.pullImage(repositoryName: repository, tag: tag)
                    if succeeded {
                        showsPullImage = false
                        return nil
                    }
                    return model.message ?? L10n.string("ui.181d86c6f58ca795")
                }
            )
        }
        .macSheet(isPresented: $showsCreateNetwork) {
            CreateNetworkSheet { name, driver in
                let succeeded = await model.createNetwork(name: name, driver: driver)
                if succeeded { showsCreateNetwork = false }
                return succeeded
            }
        }
    }

    private var paneSelection: Binding<ContainerManagerPane> {
        Binding(
            get: { pane },
            set: { pane in
                Task { @MainActor in onSelectPane(pane) }
            }
        )
    }

    private var containerSummary: String {
        let containers = model.containers?.containers ?? []
        let running = containers.filter {
            ["running", "started", "up"].contains($0.status.lowercased())
        }.count
        return L10n.string("ui.0bd7c9fa74d70720", String(describing: running), String(describing: containers.count))
    }

    private var overview: some View {
        let snapshot = model.containers
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 180), spacing: 14)],
            spacing: 14
        ) {
            SummaryCard(title: L10n.string("ui.6d23f04b26967d64"), value: "\(snapshot?.containers.count ?? 0)", icon: "shippingbox", tint: .blue)
            SummaryCard(title: L10n.string("ui.ceb4432ba2356217"), value: "\(snapshot?.images.count ?? 0)", icon: "square.stack.3d.up", tint: .purple)
            SummaryCard(title: L10n.string("ui.97b31b5d63f57e51"), value: "\(snapshot?.networks.count ?? 0)", icon: "network", tint: .green)
            SummaryCard(title: L10n.string("ui.79f326be4409d51f"), value: "\(snapshot?.projects.count ?? 0)", icon: "square.grid.2x2", tint: .orange)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 8)
    }

    private var containerList: some View {
        VStack(spacing: 10) {
            HStack {
                Button(L10n.string("ui.56410fc65314dfb5")) { Task { await model.controlContainers(.start) } }
                Button(L10n.string("ui.ca4d973c0b006b75")) { Task { await model.controlContainers(.stop) } }
                Button(L10n.string("ui.4c7c6cc2eb16ec30")) { Task { await model.controlContainers(.restart) } }
                Spacer()
                Button(L10n.string("ui.2f9daa828907b93f"), role: .destructive) { confirmsContainerDelete = true }
            }
            .disabled(model.containerSelection.isEmpty || model.isPerformingAction)
            List(model.containers?.containers ?? [], selection: $model.containerSelection) { item in
                HStack {
                    StatusDot(status: item.status)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).fontWeight(.medium)
                        Text(item.image).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let cpu = item.cpuUsage {
                        Text(L10n.string("processor.usage.percent", String(format: "%.1f", cpu)))
                    }
                    if let memory = item.memoryBytes {
                        Text(ServiceFormat.bytes(memory))
                    }
                    Text(ServiceFormat.status(item.status))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .macDataRowSurface()
                .tag(item.id)
            }
            .listStyle(.inset)
        }
    }

    private var imageList: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button(L10n.string("ui.2f9daa828907b93f"), role: .destructive) { confirmsImageDelete = true }
                    .disabled(model.imageSelection.isEmpty || model.isPerformingAction)
                Button {
                    model.clearMessage()
                    showsPullImage = true
                } label: {
                    Label(L10n.string("ui.54c566409f4d5f69"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
            }
            List(model.containers?.images ?? [], selection: $model.imageSelection) { image in
                HStack {
                    Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.purple)
                    Text(image.repository).fontWeight(.medium)
                    Text(image.tag).foregroundStyle(.secondary)
                    Spacer()
                    Text(ServiceFormat.bytes(image.sizeBytes ?? 0)).foregroundStyle(.secondary)
                    if image.isInUse {
                        Text(L10n.string("ui.fa48e89389404e60"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    }
                }
                .macDataRowSurface()
                .tag(image.id)
            }
            .listStyle(.inset)
        }
    }

    private var networkList: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button(L10n.string("ui.2f9daa828907b93f"), role: .destructive) { confirmsNetworkDelete = true }
                    .disabled(model.networkSelection.isEmpty || model.isPerformingAction)
                Button {
                    showsCreateNetwork = true
                } label: {
                    Label(L10n.string("ui.bbb95fc4344b8391"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            List(model.containers?.networks ?? [], selection: $model.networkSelection) { network in
                HStack {
                    Image(systemName: "network").foregroundStyle(.green)
                    Text(network.name).fontWeight(.medium)
                    Text(network.driver).foregroundStyle(.secondary)
                    Spacer()
                    Text(L10n.string("ui.9e93c07975ef7973", String(describing: network.connectedContainerCount)))
                        .foregroundStyle(.secondary)
                }
                .macDataRowSurface()
                .tag(network.id)
            }
            .listStyle(.inset)
        }
    }

    private var projectList: some View {
        List(model.containers?.projects ?? []) { project in
            HStack {
                StatusDot(status: project.status)
                Text(project.name).fontWeight(.medium)
                Spacer()
                Text(L10n.string("ui.9e93c07975ef7973", String(describing: project.containerCount))).foregroundStyle(.secondary)
                Text(ServiceFormat.status(project.status)).foregroundStyle(.secondary)
            }
            .macDataRowSurface()
        }
        .listStyle(.inset)
    }

    private func eventList(_ events: [ServiceEvent]) -> some View {
        List(events) { event in
            HStack(alignment: .top) {
                Text(event.timestamp?.formatted(date: .numeric, time: .standard) ?? "—")
                    .foregroundStyle(.secondary)
                    .frame(width: 150, alignment: .leading)
                Text(event.level).frame(width: 72, alignment: .leading)
                Text(event.message).textSelection(.enabled)
            }
            .font(.callout)
            .macDataRowSurface()
        }
        .listStyle(.inset)
    }
}

private struct VirtualMachineManagerView: View {
    enum ProtectionPane: String, CaseIterable, Identifiable {
        case plans
        case schedules
        case retentions

        var id: Self { self }
        var title: String {
            switch self {
            case .plans: L10n.string("ui.677050193f34702b")
            case .schedules: L10n.string("ui.457b5e7e319ab16a")
            case .retentions: L10n.string("ui.00213c7f272b9a59")
            }
        }
    }

    @Bindable var model: ServiceManagementModel
    let pane: VirtualMachineManagerPane
    let onSelectPane: @MainActor @Sendable (VirtualMachineManagerPane) -> Void
    @State private var protectionPane: ProtectionPane = .plans
    @State private var pendingPowerAction: VirtualMachinePowerAction?
    @State private var confirmsDelete = false
    @State private var confirmsNetworkDelete = false
    @State private var confirmsImageDelete = false
    @State private var deletingImage: VirtualizationResource?
    @State private var showsCreation = false
    @State private var editingMachine: VirtualMachine?
    @State private var editingNetwork: VirtualizationResource?
    @State private var logSearch = ""
    @State private var logLevel: String?
    @State private var consoleWindowController: VirtualMachineConsoleWindowController?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ServiceHeader(
                title: L10n.string("ui.80c43bd2481c9580"),
                subtitle: L10n.string("ui.c7892f3db4ba87d6", String(describing: model.virtualMachines?.machines.count ?? 0)),
                isLoading: model.isLoading
            ) { Task { await model.activate(.virtualMachines, force: true) } }
            MacPageTabs(options: VirtualMachineManagerPane.allCases, selection: paneSelection, title: { $0.title })
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(MacGlassSurface(role: .toolbar))
            Divider()

            Group {
            switch pane {
            case .machines: machineList
            case .hosts:
                resourceList(
                    model.virtualMachines?.hosts ?? [],
                    icon: "server.rack",
                    section: .hosts
                )
            case .storages:
                resourceList(
                    model.virtualMachines?.storages ?? [],
                    icon: "internaldrive",
                    section: .storages
                )
            case .networks: networkList
            case .images: imageList
            case .protection: protectionView
            case .events: eventList
            }
            }
            .padding(20)
            .buttonStyle(MacToolbarButtonStyle())
        }
        .confirmationDialog(
            powerConfirmationTitle,
            isPresented: Binding(
                get: { pendingPowerAction != nil },
                set: { if !$0 { pendingPowerAction = nil } }
            )
        ) {
            Button(powerConfirmationButton, role: pendingPowerAction == .powerOff ? .destructive : nil) {
                guard let action = pendingPowerAction else { return }
                pendingPowerAction = nil
                Task { await model.controlVirtualMachines(action) }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { pendingPowerAction = nil }
        } message: {
            Text(powerConfirmationMessage)
        }
        .confirmationDialog(L10n.string("ui.ad40eb8a01cc6468"), isPresented: $confirmsDelete) {
            Button(L10n.string("ui.09c9bbb37a697b22"), role: .destructive) {
                Task { await model.deleteVirtualMachines() }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.67d3d2f7145c7bb6"))
        }
        .confirmationDialog(L10n.string("ui.ee4929b66715cd3c"), isPresented: $confirmsNetworkDelete) {
            Button(L10n.string("ui.8e3a6be52ed69dde"), role: .destructive) {
                Task { await model.deleteVirtualMachineNetworks() }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.1f42dd983ef3248f"))
        }
        .confirmationDialog(
            deletingImage != nil
                ? L10n.string("image.delete.confirm", deletingImage?.name ?? "")
                : L10n.string("ui.08e648b8e120039f"),
            isPresented: Binding(
                get: { confirmsImageDelete || deletingImage != nil },
                set: { if !$0 { confirmsImageDelete = false; deletingImage = nil } }
            )
        ) {
            Button(L10n.string("ui.17f38b5ced278466"), role: .destructive) {
                if let image = deletingImage {
                    model.virtualMachineImageSelection = [image.id]
                }
                deletingImage = nil
                confirmsImageDelete = false
                Task { await model.deleteVirtualMachineImages() }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {
                deletingImage = nil
                confirmsImageDelete = false
            }
        } message: {
            if let image = deletingImage {
                Text(L10n.string("ui.1ac52411484d9eb2", String(describing: image.name)))
            } else {
                Text(L10n.string("ui.44af5924ab3698a1"))
            }
        }
        .macSheet(isPresented: $showsCreation) {
            CreateVirtualMachineSheet(
                snapshot: model.virtualMachines,
                submit: { await model.createVirtualMachine($0) }
            )
        }
        .macSheet(item: $editingMachine) { machine in
            EditVirtualMachineSheet(
                machine: machine,
                submit: { await model.updateVirtualMachine(id: machine.id, configuration: $0) }
            )
        }
        .macSheet(item: $editingNetwork) { network in
            EditVirtualMachineNetworkSheet(
                network: network,
                submit: {
                    await model.updateVirtualMachineNetwork(
                        id: network.id,
                        configuration: $0
                    )
                }
            )
        }
    }

    private var paneSelection: Binding<VirtualMachineManagerPane> {
        Binding(
            get: { pane },
            set: { pane in
                Task { @MainActor in onSelectPane(pane) }
            }
        )
    }

    private var machineList: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    showsCreation = true
                } label: {
                    Label(L10n.string("ui.50ef2f4cf6a46924"), systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(
                    model.isPerformingAction
                        || model.virtualMachines?.storages.isEmpty != false
                        || model.virtualMachines?.networks.isEmpty != false
                )
                Button {
                    editingMachine = selectedMachine
                } label: {
                    Label(L10n.string("ui.37090f45651676fc"), systemImage: "slider.horizontal.3")
                }
                .disabled(selectedMachine == nil || model.isPerformingAction)
                Button {
                    if let consoleWindowController {
                        consoleWindowController.show()
                        return
                    }
                    guard let machine = selectedMachine else { return }
                    Task {
                        guard let session = await model.openVirtualMachineConsole(id: machine.id) else {
                            return
                        }
                        let controller = VirtualMachineConsoleWindowController(
                            machineName: machine.name,
                            session: session
                        )
                        controller.onClose = {
                            consoleWindowController = nil
                        }
                        consoleWindowController = controller
                        controller.show()
                    }
                } label: {
                    Label(L10n.string("ui.678b783fb578172b"), systemImage: "display")
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(
                    selectedMachine == nil
                        || selectedMachine.map { !isRunning($0.status) } == true
                        || model.isPerformingAction
                )
                Divider().frame(height: 18)
                Group {
                Button(L10n.string("ui.56410fc65314dfb5")) { pendingPowerAction = .powerOn }
                Button(L10n.string("ui.0c6d079c4c60bcf5")) { pendingPowerAction = .shutdown }
                Menu(L10n.string("ui.38844b135cf70dfc")) {
                    Button(L10n.string("ui.4c7c6cc2eb16ec30")) { pendingPowerAction = .restart }
                    Divider()
                    Button(L10n.string("ui.b775502757e1b262"), role: .destructive) {
                        pendingPowerAction = .powerOff
                    }
                    Button(L10n.string("ui.0552e329ccf875fb"), role: .destructive) { confirmsDelete = true }
                }
                }
                .disabled(model.virtualMachineSelection.isEmpty || model.isPerformingAction)
                Spacer()
            }

            let machines = model.virtualMachines?.machines ?? []
            if machines.isEmpty, !model.isLoading {
                EmptyServiceState(
                    title: L10n.string("ui.7c1ae9a0ba0f3e91"),
                    message: L10n.string("ui.49e52b056f9720b2"),
                    icon: "desktopcomputer"
                )
            } else {
                List(machines, selection: $model.virtualMachineSelection) { machine in
                    HStack(spacing: 12) {
                        Image(systemName: "desktopcomputer")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 42, height: 42)
                            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                        StatusDot(status: machine.status)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(machine.name).fontWeight(.medium)
                            Text(machine.host ?? L10n.string("ui.1f7269533836a148"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let cpu = machine.cpuCount { Text(L10n.string("ui.4e1409633e0962fd", String(describing: cpu))) }
                        if let memory = machine.memoryBytes { Text(ServiceFormat.bytes(memory)) }
                        Text(ServiceFormat.status(machine.status)).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .macDataRowSurface()
                    .tag(machine.id)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.inset)
            }
        }
    }

    private var selectedMachine: VirtualMachine? {
        guard model.virtualMachineSelection.count == 1,
              let id = model.virtualMachineSelection.first else {
            return nil
        }
        return model.virtualMachines?.machines.first(where: { $0.id == id })
    }

    private func isRunning(_ status: String) -> Bool {
        ["running", "started", "up", "online"].contains(status.lowercased())
    }

    private func resourceList(
        _ resources: [VirtualizationResource],
        icon: String,
        section: VirtualMachineManagerSection? = nil
    ) -> some View {
        Group {
            if let section, isUnavailable(section) {
                unavailableState(icon: icon)
            } else if resources.isEmpty, !model.isLoading {
                EmptyServiceState(
                    title: L10n.string("ui.193f5172b1a610e3"),
                    message: L10n.string("ui.eb8c045aa9ca1324"),
                    icon: icon
                )
            } else {
                List(resources) { resource in
                    HStack {
                        Image(systemName: icon).foregroundStyle(.indigo)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(resource.name).fontWeight(.medium)
                            if let detail = resource.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let status = resource.status {
                            Text(ServiceFormat.status(status)).foregroundStyle(.secondary)
                        }
                    }
                    .macDataRowSurface()
                }
                .listStyle(.inset)
            }
        }
    }

    private var networkList: some View {
        VStack(spacing: 10) {
            HStack {
                Button {
                    editingNetwork = selectedNetwork
                } label: {
                    Label(L10n.string("ui.37090f45651676fc"), systemImage: "pencil")
                }
                .disabled(selectedNetwork == nil || model.isPerformingAction)
                Button(role: .destructive) {
                    confirmsNetworkDelete = true
                } label: {
                    Label(L10n.string("ui.2f9daa828907b93f"), systemImage: "trash")
                }
                .disabled(
                    model.virtualMachineNetworkSelection.isEmpty
                        || model.isPerformingAction
                )
                Spacer()
            }

            if isUnavailable(.networks) {
                unavailableState(icon: "network")
            } else {
                selectableResourceList(
                    model.virtualMachines?.networks ?? [],
                    selection: $model.virtualMachineNetworkSelection,
                    icon: "network",
                    emptyMessage: L10n.string("ui.61feec1ad1dfaeaa")
                )
            }
        }
    }

    private var imageList: some View {
        Group {
            if isUnavailable(.images) {
                unavailableState(icon: "opticaldisc")
            } else {
                selectableResourceList(
                    model.virtualMachines?.images ?? [],
                    selection: $model.virtualMachineImageSelection,
                    icon: "opticaldisc",
                    emptyMessage: L10n.string("ui.1f0117cd8f4f1c48"),
                    onDelete: { resource in
                        deletingImage = resource
                        model.virtualMachineImageSelection = [resource.id]
                        confirmsImageDelete = true
                    }
                )
            }
        }
    }

    private func selectableResourceList(
        _ resources: [VirtualizationResource],
        selection: Binding<Set<String>>,
        icon: String,
        emptyMessage: String,
        onDelete: ((VirtualizationResource) -> Void)? = nil
    ) -> some View {
        Group {
            if resources.isEmpty, !model.isLoading {
                EmptyServiceState(
                    title: L10n.string("ui.193f5172b1a610e3"),
                    message: emptyMessage,
                    icon: icon
                )
            } else {
                List(resources, selection: selection) { resource in
                    HStack {
                        Image(systemName: icon)
                            .foregroundStyle(.indigo)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(resource.name).fontWeight(.medium)
                            if let detail = resource.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if let status = resource.status {
                            Text(ServiceFormat.status(status))
                                .foregroundStyle(.secondary)
                        }
                        if let onDelete {
                            Button(role: .destructive) {
                                onDelete(resource)
                            } label: {
                                Label(L10n.string("ui.2f9daa828907b93f"), systemImage: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(model.isPerformingAction)
                            .help(L10n.string("ui.917a7a94b8712191"))
                        }
                    }
                    .font(.callout)
                    .macDataRowSurface()
                    .tag(resource.id)
                    .contextMenu {
                        if let onDelete {
                            Button(role: .destructive) {
                                onDelete(resource)
                            } label: {
                                Label(L10n.string("ui.2f9daa828907b93f"), systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var selectedNetwork: VirtualizationResource? {
        guard model.virtualMachineNetworkSelection.count == 1,
              let id = model.virtualMachineNetworkSelection.first else {
            return nil
        }
        return model.virtualMachines?.networks.first(where: { $0.id == id })
    }

    private var protectionView: some View {
        VStack(alignment: .leading, spacing: 10) {
            MacPageTabs(options: ProtectionPane.allCases, selection: $protectionPane, title: { $0.title })
            .frame(maxWidth: 420, alignment: .leading)

            if isUnavailable(.protection) {
                unavailableState(icon: "shield.checkered")
            } else {
                switch protectionPane {
                case .plans:
                    resourceList(
                        model.virtualMachines?.protectionPlans ?? [],
                        icon: "shield.checkered"
                    )
                case .schedules:
                    resourceList(
                        model.virtualMachines?.protectionSchedulePolicies ?? [],
                        icon: "calendar.badge.clock"
                    )
                case .retentions:
                    resourceList(
                        model.virtualMachines?.protectionRetentionPolicies ?? [],
                        icon: "clock.arrow.circlepath"
                    )
                }
            }
        }
    }

    private var eventList: some View {
        VStack(spacing: 10) {
            HStack {
                Picker(L10n.string("ui.3d9d02e83d396eb7"), selection: $logLevel) {
                    Text(L10n.string("ui.5c55a67935af8f45")).tag(String?.none)
                    ForEach(logLevels, id: \.self) { level in
                        Text(level).tag(Optional(level))
                    }
                }
                .labelsHidden()
                .frame(width: 150)
                TextField(L10n.string("ui.1b9b75f51d2061d7"), text: $logSearch)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Spacer()
                Text(L10n.string("ui.08f9603e78071336", String(describing: filteredEvents.count)))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.string("ui.0c920203a10756c5", String(describing: filteredEvents.count)))
            }

            if isUnavailable(.logs) {
                unavailableState(icon: "list.bullet.rectangle")
            } else if filteredEvents.isEmpty, !model.isLoading {
                EmptyServiceState(
                    title: logSearch.isEmpty && logLevel == nil ? L10n.string("ui.dcb3b8dbca4fe140") : L10n.string("ui.865c08a7984a645c"),
                    message: logSearch.isEmpty && logLevel == nil
                        ? L10n.string("ui.ecf80647b8e4391b")
                        : L10n.string("ui.3304fa471bdc74d4"),
                    icon: "list.bullet.rectangle"
                )
            } else {
                List(filteredEvents) { event in
                    HStack(alignment: .top, spacing: 12) {
                        Text(event.timestamp?.formatted(date: .numeric, time: .standard) ?? "—")
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .leading)
                        Text(event.level)
                            .foregroundStyle(logColor(event.level))
                            .frame(width: 72, alignment: .leading)
                        Text(event.user ?? "—")
                            .foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .leading)
                        Text(event.message)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                    .macDataRowSurface()
                }
                .listStyle(.inset)
            }
        }
    }

    private var logLevels: [String] {
        let levels = Set((model.virtualMachines?.events ?? []).map(\.level))
        return levels.sorted()
    }

    private var filteredEvents: [ServiceEvent] {
        (model.virtualMachines?.events ?? []).filter { event in
            let matchesLevel = logLevel == nil || event.level == logLevel
            let query = logSearch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard matchesLevel, !query.isEmpty else { return matchesLevel }
            return event.message.localizedCaseInsensitiveContains(query)
                || event.level.localizedCaseInsensitiveContains(query)
                || event.user?.localizedCaseInsensitiveContains(query) == true
        }
    }

    private func logColor(_ level: String) -> Color {
        let normalized = level.lowercased()
        if normalized.contains("error") || level.contains(L10n.string("ui.0bc1fb72ae1be5c5")) { return .red }
        if normalized.contains("warn") || level.contains(L10n.string("ui.a8b7a4480407ac8a")) { return .orange }
        return .primary
    }

    private func isUnavailable(_ section: VirtualMachineManagerSection) -> Bool {
        model.virtualMachines?.unavailableSections.contains(section) == true
    }

    private func unavailableState(icon: String) -> some View {
        VStack(spacing: 12) {
            EmptyServiceState(
                title: L10n.string("ui.109cd48ec39191ef"),
                message: L10n.string("ui.c092d7f7594f314f"),
                icon: icon
            )
            Button(L10n.string("ui.7bdd5ce1e298a972")) {
                Task { await model.activate(.virtualMachines, force: true) }
            }
            .disabled(model.isLoading)
        }
    }

    private var powerConfirmationTitle: String {
        switch pendingPowerAction {
        case .powerOn: L10n.string("ui.5999db1c5bcd59ea")
        case .shutdown: L10n.string("ui.77e0d3de8918fc1e")
        case .powerOff: L10n.string("ui.755b142b5e3f542b")
        case .restart: L10n.string("ui.88568c6d970bcb8c")
        case nil: ""
        }
    }

    private var powerConfirmationButton: String {
        switch pendingPowerAction {
        case .powerOn: L10n.string("ui.56410fc65314dfb5")
        case .shutdown: L10n.string("ui.0c6d079c4c60bcf5")
        case .powerOff: L10n.string("ui.95e6d4dab18115c2")
        case .restart: L10n.string("ui.4c7c6cc2eb16ec30")
        case nil: ""
        }
    }

    private var powerConfirmationMessage: String {
        pendingPowerAction == .powerOff
            ? L10n.string("ui.5657849d1aaa3d79")
            : L10n.string("ui.105effc619602b8b")
    }
}

struct EditVirtualMachineNetworkSheet: View {
    let network: VirtualizationResource
    let submit: (VirtualMachineNetworkUpdate) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var isSaving = false

    init(
        network: VirtualizationResource,
        submit: @escaping (VirtualMachineNetworkUpdate) async -> Bool
    ) {
        self.network = network
        self.submit = submit
        _name = State(initialValue: network.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("ui.d1650277320baac5"))
                .font(.title2.bold())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(MacGlassSurface(role: .toolbar).clipShape(RoundedRectangle(cornerRadius: 12)))
            Form {
                TextField(L10n.string("ui.d44e9b3d3b31d37b"), text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            Text(L10n.string("ui.cfef0ea3f7b9cf6a"))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? L10n.string("ui.6bdb4435095e5d28") : L10n.string("ui.a3030bf8f16dc63c")) {
                    isSaving = true
                    Task {
                        let succeeded = await submit(
                            VirtualMachineNetworkUpdate(
                                name: name.trimmingCharacters(in: .whitespacesAndNewlines)
                            )
                        )
                        isSaving = false
                        if succeeded { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(
                    isSaving
                        || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .buttonStyle(MacToolbarButtonStyle())
        }
        .padding(24)
        .frame(width: 440)
        .fillsAvailableContentArea(alignment: .topLeading)
        .background(MacGlassSurface(role: .sidebar))
        .interactiveDismissDisabled(isSaving)
    }
}

struct CreateVirtualMachineSheet: View {
    let snapshot: VirtualMachineManagerSnapshot?
    let submit: (VirtualMachineCreation) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var name = ""
    @State private var operatingSystem: VirtualMachineOperatingSystem = .linux
    @State private var description = ""
    @State private var cpuCount = 2
    @State private var memoryGiB = 2
    @State private var diskGiB = 20
    @State private var storageID = ""
    @State private var networkID = ""
    @State private var imageID = ""
    @State private var firmware: VirtualMachineFirmware = .legacy
    @State private var autoStart = false
    @State private var powerOnAfterCreation = false
    @State private var confirmsCreation = false
    @State private var isSubmitting = false

    private let stepTitles = [L10n.string("ui.e8df058725699a17"), L10n.string("ui.2c37d50911e8f6fa"), L10n.string("ui.3933d78a8f0d2181")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("ui.5f2c0e533b04bbb4")).font(.title2.weight(.semibold))
                    Text(L10n.string("ui.823c07fbeb2b65e1", String(describing: step + 1), String(describing: stepTitles.count), String(describing: stepTitles[step])))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView(value: Double(step + 1), total: Double(stepTitles.count))
                    .frame(width: 180)
                    .accessibilityLabel(L10n.string("ui.a7bed16ef55763e1"))
                    .accessibilityValue(L10n.string("ui.161a76ddf252f824", String(describing: step + 1), String(describing: stepTitles.count)))
            }
            .padding(20)
            .background(MacGlassSurface(role: .toolbar))

            Divider()

            Form {
                switch step {
                case 0:
                    Section(L10n.string("ui.f3fb4b3a41570007")) {
                        TextField(L10n.string("ui.d44e9b3d3b31d37b"), text: $name)
                            .accessibilityHint(L10n.string("ui.90461e9bf1e3bc09"))
                        Picker(L10n.string("ui.360480034cc3e9d3"), selection: $operatingSystem) {
                            Text(L10n.string("operating_system.windows")).tag(VirtualMachineOperatingSystem.windows)
                            Text(L10n.string("operating_system.linux")).tag(VirtualMachineOperatingSystem.linux)
                            Text(L10n.string("ui.d2909f1647e7c891")).tag(VirtualMachineOperatingSystem.other)
                        }
                        TextField(L10n.string("ui.19ad97a6aca8b249"), text: $description, axis: .vertical)
                            .lineLimit(2...4)
                    }
                case 1:
                    Section(L10n.string("ui.7f5cc0a851ac4208")) {
                        Stepper(L10n.string("ui.bb5b9e48a5da55ca", String(describing: cpuCount)), value: $cpuCount, in: 1...64)
                        Stepper(L10n.string("ui.66c70ccb2d262130", String(describing: memoryGiB)), value: $memoryGiB, in: 1...1_024)
                        Text(L10n.string("ui.67ade39ec6c1f46b"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                default:
                    Section(L10n.string("ui.8abdc8d4e6d8a103")) {
                        Picker(L10n.string("ui.26de3dd933ce00e3"), selection: $storageID) {
                            ForEach(snapshot?.storages ?? []) { resource in
                                Text(resource.name).tag(resource.id)
                            }
                        }
                        Stepper(L10n.string("ui.7c6d6431eee3c5ee", String(describing: diskGiB)), value: $diskGiB, in: 1...1_048_576)
                        Picker(L10n.string("ui.97b31b5d63f57e51"), selection: $networkID) {
                            ForEach(snapshot?.networks ?? []) { resource in
                                Text(resource.name).tag(resource.id)
                            }
                        }
                    }
                    Section(L10n.string("ui.56410fc65314dfb5")) {
                        Picker(L10n.string("ui.7aa6fa597cb79db4"), selection: $imageID) {
                            Text(L10n.string("ui.7edc5052876d6c37")).tag("")
                            ForEach(snapshot?.images ?? []) { resource in
                                Text(resource.name).tag(resource.id)
                            }
                        }
                        Picker(L10n.string("ui.a981c51cd86afd77"), selection: $firmware) {
                            Text(L10n.string("firmware.legacy_bios")).tag(VirtualMachineFirmware.legacy)
                            Text(L10n.string("firmware.uefi")).tag(VirtualMachineFirmware.uefi)
                        }
                        Toggle(L10n.string("ui.3c399a5b5ecdd522"), isOn: $autoStart)
                        Toggle(L10n.string("ui.e6f251f0421991aa"), isOn: $powerOnAfterCreation)
                    }
                }
            }
            .formStyle(.grouped)
            .macThemedScrollContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 {
                    Button(L10n.string("ui.da336fdc0dbd1818")) { step -= 1 }
                        .disabled(isSubmitting)
                }
                if step < stepTitles.count - 1 {
                    Button(L10n.string("ui.acfc4e74a650e7df")) { step += 1 }
                        .buttonStyle(MacToolbarButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue || isSubmitting)
                } else {
                    Button {
                        confirmsCreation = true
                    } label: {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L10n.string("ui.0dcae6dc6ec16060"))
                        }
                    }
                    .buttonStyle(MacToolbarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || isSubmitting)
                }
            }
            .padding(20)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 500, idealHeight: 580)
        .background(MacGlassSurface(role: .sidebar))
        .onAppear {
            storageID = storageID.isEmpty ? snapshot?.storages.first?.id ?? "" : storageID
            networkID = networkID.isEmpty ? snapshot?.networks.first?.id ?? "" : networkID
        }
        .interactiveDismissDisabled(isSubmitting)
        .confirmationDialog(L10n.string("ui.e654f7902a1c46f1"), isPresented: $confirmsCreation) {
            Button(L10n.string("ui.cf9fb1d68001bd37")) {
                Task {
                    isSubmitting = true
                    let succeeded = await submit(configuration)
                    isSubmitting = false
                    if succeeded { dismiss() }
                }
            }
            Button(L10n.string("ui.84eef12f27a433d7"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.15261cbb837fb193", String(describing: cpuCount), String(describing: memoryGiB), String(describing: diskGiB)))
        }
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool {
        switch step {
        case 0:
            !normalizedName.isEmpty
                && normalizedName.count <= 255
                && description.count <= 1_024
        default:
            true
        }
    }

    private var canCreate: Bool {
        !normalizedName.isEmpty && !storageID.isEmpty && !networkID.isEmpty
    }

    private var configuration: VirtualMachineCreation {
        VirtualMachineCreation(
            name: normalizedName,
            operatingSystem: operatingSystem,
            storageID: storageID,
            networkID: networkID,
            bootImageID: imageID.isEmpty ? nil : imageID,
            cpuCount: cpuCount,
            memoryMiB: memoryGiB * 1_024,
            diskGiB: diskGiB,
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            firmware: firmware,
            autoStart: autoStart,
            powerOnAfterCreation: powerOnAfterCreation
        )
    }
}

struct EditVirtualMachineSheet: View {
    let machine: VirtualMachine
    let submit: (VirtualMachineUpdate) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var cpuCount: Int
    @State private var memoryGiB: Int
    @State private var priority: Int
    @State private var autoStart: Bool
    @State private var confirmsSave = false
    @State private var isSubmitting = false

    init(
        machine: VirtualMachine,
        submit: @escaping (VirtualMachineUpdate) async -> Bool
    ) {
        self.machine = machine
        self.submit = submit
        _name = State(initialValue: machine.name)
        _description = State(initialValue: machine.description ?? "")
        _cpuCount = State(initialValue: machine.cpuCount ?? 1)
        _memoryGiB = State(
            initialValue: max(1, Int((machine.memoryBytes ?? 1_073_741_824) / 1_073_741_824))
        )
        _priority = State(initialValue: machine.cpuWeight ?? 256)
        _autoStart = State(initialValue: machine.autoStart)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("ui.3f4bfb5bd8fc2b38")).font(.title2.weight(.semibold))
                Text(machine.name).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MacGlassSurface(role: .toolbar))

            Divider()

            Form {
                Section(L10n.string("ui.40fae00b7c6d8ac0")) {
                    TextField(L10n.string("ui.d44e9b3d3b31d37b"), text: $name)
                    TextField(L10n.string("ui.19ad97a6aca8b249"), text: $description, axis: .vertical)
                        .lineLimit(2...4)
                    Picker(L10n.string("ui.74e92edaaa85d6a3"), selection: $priority) {
                        Text(L10n.string("ui.552f8f8b1402dc6d")).tag(128)
                        Text(L10n.string("ui.6bea77acefb364ac")).tag(256)
                        Text(L10n.string("ui.dfbad24e7f4a9cb8")).tag(512)
                    }
                    Toggle(L10n.string("ui.3c399a5b5ecdd522"), isOn: $autoStart)
                }
                Section(L10n.string("ui.7f5cc0a851ac4208")) {
                    Stepper(L10n.string("ui.bb5b9e48a5da55ca", String(describing: cpuCount)), value: $cpuCount, in: 1...64)
                        .disabled(isRunning)
                    Stepper(L10n.string("ui.66c70ccb2d262130", String(describing: memoryGiB)), value: $memoryGiB, in: 1...1_024)
                        .disabled(isRunning)
                    if isRunning {
                        Label(
                            L10n.string("ui.b622d3a704e293d5"),
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .formStyle(.grouped)
            .macThemedScrollContent()

            Divider()

            HStack {
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string("ui.5eaaf3264a3f652d")) { confirmsSave = true }
                    .buttonStyle(MacToolbarButtonStyle(prominent: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || !hasChanges || isSubmitting)
            }
            .padding(20)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 460, idealHeight: 520)
        .background(MacGlassSurface(role: .sidebar))
        .interactiveDismissDisabled(isSubmitting)
        .confirmationDialog(L10n.string("ui.ae182336517d15ef"), isPresented: $confirmsSave) {
            Button(L10n.string("ui.991bb7cfe5a81550")) {
                Task {
                    isSubmitting = true
                    let succeeded = await submit(update)
                    isSubmitting = false
                    if succeeded { dismiss() }
                }
            }
            Button(L10n.string("ui.84eef12f27a433d7"), role: .cancel) {}
        } message: {
            Text(isRunning ? L10n.string("ui.d0fcf04434f861fb") : L10n.string("ui.4e02a5a907afb67a"))
        }
    }

    private var isRunning: Bool {
        ["running", "started", "up", "online"].contains(machine.status.lowercased())
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !normalizedName.isEmpty && normalizedName.count <= 255 && description.count <= 1_024
    }

    private var hasChanges: Bool {
        normalizedName != machine.name
            || description != (machine.description ?? "")
            || priority != (machine.cpuWeight ?? 256)
            || autoStart != machine.autoStart
            || (!isRunning && cpuCount != (machine.cpuCount ?? 1))
            || (!isRunning
                && memoryGiB
                    != max(1, Int((machine.memoryBytes ?? 1_073_741_824) / 1_073_741_824)))
    }

    private var update: VirtualMachineUpdate {
        VirtualMachineUpdate(
            name: normalizedName == machine.name ? nil : normalizedName,
            description: description == (machine.description ?? "") ? nil : description,
            cpuCount: !isRunning && cpuCount != (machine.cpuCount ?? 1) ? cpuCount : nil,
            memoryMiB: !isRunning
                && memoryGiB
                    != max(1, Int((machine.memoryBytes ?? 1_073_741_824) / 1_073_741_824))
                ? memoryGiB * 1_024
                : nil,
            cpuWeight: priority == (machine.cpuWeight ?? 256) ? nil : priority,
            autoStart: autoStart == machine.autoStart ? nil : autoStart
        )
    }
}

@MainActor
private final class VirtualMachineConsoleWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(machineName: String, session: VirtualMachineConsoleSession) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.string("ui.cc15f5e62327b120", String(describing: machineName))
        window.minSize = NSSize(width: 720, height: 480)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: VirtualMachineConsoleWindowView(
                machineName: machineName,
                session: session,
                close: { [weak self] in
                    self?.close()
                },
                toggleFullScreen: { [weak self] in
                    self?.window?.toggleFullScreen(nil)
                }
            )
            .macAppearanceRoot()
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError(L10n.string("ui.d9a88c8c1cc92db6"))
    }

    func show() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // 立即释放非持久网页视图，避免控制台会话在窗口关闭后继续驻留。
        window?.contentView = nil
        onClose?()
        onClose = nil
    }
}

// 隔离窗口检查复用此外壳；不改变控制台网页的会话配置。
struct VirtualMachineConsoleWindowView: View {
    let machineName: String
    let session: VirtualMachineConsoleSession
    let close: () -> Void
    let toggleFullScreen: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 40).allowsHitTesting(false)
            HStack {
                Label(machineName, systemImage: "display")
                    .font(.headline)
                Spacer()
                Text(L10n.string("ui.4f9880bb8182fd14"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    toggleFullScreen()
                } label: {
                    Label(L10n.string("ui.aa8b6477c2ce1916"), systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
                .help(L10n.string("ui.8f0b51770d50edbd"))
                .accessibilityHint(L10n.string("ui.1b99651d3233525a"))
                Button(L10n.string("ui.3fd47edce45b3603")) { close() }
                    .keyboardShortcut("w", modifiers: .command)
            }
            .buttonStyle(MacToolbarButtonStyle())
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(MacGlassSurface(role: .toolbar))
            Divider()
            VirtualMachineConsoleWebView(session: session)
                .accessibilityLabel(L10n.string("ui.c3247acb301cfeb0", String(describing: machineName)))
        }
        .background(MacGlassSurface(role: .sidebar).ignoresSafeArea())
        .background(MacWorkspaceWindowChrome(fullSize: true))
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 720, idealWidth: 1_100, minHeight: 480, idealHeight: 760)
    }
}

private struct VirtualMachineConsoleWebView: NSViewRepresentable {
    let session: VirtualMachineConsoleSession

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = true
        guard let host = session.url.host,
              let cookie = HTTPCookie(properties: [
                  .domain: host,
                  .path: "/",
                  .name: "id",
                  .value: session.sessionCookieValue,
                  .secure: "TRUE"
              ]) else {
            return webView
        }
        configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            webView.load(URLRequest(url: session.url))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: ()) {
        webView.stopLoading()
    }
}

struct SummaryCard: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(
            MacCardFill(),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }
}

private struct StatusDot: View {
    let status: String

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(Color.primary.opacity(0.14)))
            .accessibilityLabel(ServiceFormat.status(status))
    }

    private var color: Color {
        switch status.lowercased() {
        case "running", "started", "up", "healthy", "online": .green
        case "paused", "stopped", "shutdown", "offline": .secondary
        case "error", "failed", "unhealthy": .red
        default: .orange
        }
    }
}

struct PullImageSheet: View {
    let search: (String) async throws -> [ContainerRegistryImage]
    let loadTags: (String) async throws -> [String]
    let submit: (String, String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [ContainerRegistryImage] = []
    @State private var selectedImageID: String?
    @State private var repository = ""
    @State private var tags: [String] = []
    @State private var tag = "latest"
    @State private var hasSearched = false
    @State private var isSearching = false
    @State private var isLoadingTags = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var tagSuggestions: [String] {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = normalized.isEmpty
            ? tags
            : tags.filter { $0.localizedCaseInsensitiveContains(normalized) }
        return Array(matches.prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部 Header
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("ui.ca0af0bbf50d2b45"))
                    .font(.title2.weight(.semibold))

                HStack(spacing: 8) {
                    TextField(L10n.string("ui.41b3f0900cf8fd0f"), text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await performSearch() } }
                        .accessibilityHint(L10n.string("ui.cf00ba193f6977fa"))
                    Button {
                        Task { await performSearch() }
                    } label: {
                        if isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(L10n.string("ui.44ce7ae909bbb28b"), systemImage: "magnifyingglass")
                        }
                    }
                    .buttonStyle(MacToolbarButtonStyle(prominent: true))
                    .disabled(
                        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || isSearching
                            || isSubmitting
                    )
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .background(MacGlassSurface(role: .toolbar))

            Divider()

            // 中央主列表区：充满剩余的全部垂直高度！
            Group {
                if isSearching {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.string("ui.326539c4b5681140"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if hasSearched && results.isEmpty {
                    ContentUnavailableView(
                        L10n.string("ui.fd4d26c833ae1a5f"),
                        systemImage: "magnifyingglass",
                        description: Text(L10n.string("ui.492a18ca73e90820"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView(
                        L10n.string("ui.0526a189f40b7360"),
                        systemImage: "shippingbox",
                        description: Text(L10n.string("ui.1ef15e3b65ff17cd"))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results, selection: $selectedImageID) { image in
                        HStack(alignment: .top, spacing: 12) {
                            Image(
                                systemName: image.isOfficial
                                    ? "checkmark.seal.fill"
                                    : "shippingbox"
                            )
                            .foregroundStyle(image.isOfficial ? .blue : .secondary)
                            .frame(width: 22)
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(image.name).fontWeight(.medium)
                                    if image.isOfficial {
                                        Text(L10n.string("ui.e73e38c1f65d0326"))
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.blue)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.blue.opacity(0.1), in: Capsule())
                                    }
                                }
                                if let description = image.description {
                                    Text(description)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if image.starCount > 0 {
                                Label("\(image.starCount)", systemImage: "star.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                        .tag(image.id)
                        .accessibilityElement(children: .combine)
                    }
                    .listStyle(.inset)
                    .macThemedScrollContent(selection: selectedImageID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 已选镜像与标签选择框
            if !repository.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(L10n.string("ui.389d1756df651b7c", String(describing: repository)), systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        if isLoadingTags {
                            ProgressView().controlSize(.small)
                                .accessibilityLabel(L10n.string("ui.f060a7a7228db374"))
                        }
                    }
                    HStack(spacing: 8) {
                        Text(L10n.string("ui.596e85c0537dd625"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(L10n.string("ui.50df581521d18cc1"), text: $tag)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isLoadingTags || isSubmitting)
                            .accessibilityHint(L10n.string("ui.3827d10546d97ed3"))
                    }
                    if !tagSuggestions.isEmpty && !isLoadingTags {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                ForEach(tagSuggestions, id: \.self) { suggestion in
                                    Button(suggestion) { tag = suggestion }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                    .accessibilityElement(children: .combine)
            }

            Divider()

            // 固底 Footer 操作栏
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("ui.ca0af0bbf50d2b45")) {
                    isSubmitting = true
                    errorMessage = nil
                    Task {
                        errorMessage = await submit(repository, tag)
                        isSubmitting = false
                    }
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(
                    repository.isEmpty
                        || tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !tags.contains(
                            tag.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                        || isLoadingTags
                        || isSubmitting
                )
            }
            .padding(16)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
        }
        .frame(width: 620, height: 540)
        .macThemedScrollContent()
        .background(MacGlassSurface(role: .sidebar))
        .onChange(of: selectedImageID) { _, newValue in
            guard let image = results.first(where: { $0.id == newValue }) else { return }
            repository = image.name
            tag = "latest"
            tags = []
            errorMessage = nil
            Task { await performTagLoad(for: image.name) }
        }
    }

    @MainActor
    private func performSearch() async {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !isSearching else { return }
        isSearching = true
        errorMessage = nil
        selectedImageID = nil
        repository = ""
        tags = []
        isLoadingTags = false
        do {
            results = try await search(normalized)
            hasSearched = true
        } catch {
            results = []
            hasSearched = true
            errorMessage = userMessage(for: error, fallback: L10n.string("ui.7b2f11d094f2a9b9"))
        }
        isSearching = false
    }

    @MainActor
    private func performTagLoad(for repository: String) async {
        isLoadingTags = true
        errorMessage = nil
        do {
            let loadedTags = try await loadTags(repository)
            guard self.repository == repository else { return }
            tags = loadedTags
            if !tags.contains(tag), let first = tags.first {
                tag = first
            }
            if tags.isEmpty {
                errorMessage = L10n.string("ui.394350058428e0ad")
            }
        } catch {
            guard self.repository == repository else { return }
            tags = []
            errorMessage = userMessage(
                for: error,
                fallback: L10n.string("ui.29a0c35e68c4ba5a")
            )
        }
        if self.repository == repository {
            isLoadingTags = false
        }
    }

    private func userMessage(for error: Error, fallback: String) -> String {
        (error as? AppError)?.safeUserMessage ?? fallback
    }
}

struct CreateNetworkSheet: View {
    let submit: (String, String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var driver = "bridge"
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("ui.49fe5148286aa7f8")).font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(MacGlassSurface(role: .toolbar).clipShape(RoundedRectangle(cornerRadius: 12)))
            Form {
                TextField(L10n.string("ui.ac8d90dfa36e5134"), text: $name)
                Picker(L10n.string("ui.fefbff4b349c9621"), selection: $driver) {
                    Text(L10n.string("ui.441caa6812c4d683")).tag("bridge")
                    Text(L10n.string("ui.e87d9f23a3f5a830")).tag("host")
                }
            }
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { dismiss() }
                Button(L10n.string("ui.c03b2ae791fe7fa1")) {
                    isSubmitting = true
                    Task {
                        _ = await submit(name, driver)
                        isSubmitting = false
                    }
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(name.isEmpty || isSubmitting)
            }
            .buttonStyle(MacToolbarButtonStyle())
        }
        .padding(24)
        .frame(width: 440)
        .fillsAvailableContentArea(alignment: .topLeading)
        .background(MacGlassSurface(role: .sidebar))
    }
}

private enum ServiceFormat {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ value: Int64) -> String {
        L10n.string("ui.3b14d1af77ab3e3e", String(describing: bytes(value)))
    }

    static func status(_ raw: String) -> String {
        switch raw.lowercased() {
        case "running", "started", "up": L10n.string("ui.9273b8cc8f40fabd")
        case "stopped", "shutdown", "offline": L10n.string("ui.f006455e3baf2b0b")
        case "paused": L10n.string("ui.eb0c326b60ae897a")
        case "waiting": L10n.string("ui.7a287e16547c1189")
        case "downloading": L10n.string("ui.06b2117d58cc6295")
        case "uploading", "seeding": L10n.string("ui.acad4927ac1c4ecd")
        case "finished", "completed": L10n.string("ui.f28461bb49c85647")
        case "error", "failed": L10n.string("ui.b7e3e715f18b9bac")
        case "healthy", "online": L10n.string("ui.296de0e31f8c22d9")
        case "unhealthy": L10n.string("ui.34c01d4e4769a3bc")
        default: raw.isEmpty ? L10n.string("ui.ec0d9bdb00a4a8f6") : raw
        }
    }
}
