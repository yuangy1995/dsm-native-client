import DsmFileFeature
import AppKit
import DsmCore
import DsmLocalization
import SwiftUI
import UniformTypeIdentifiers

@MainActor
enum OfficeDocumentActions {
    static func chooseApplication() -> URL? {
        let panel = NSOpenPanel()
        panel.title = L10n.string("files.office.chooseApplication")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func open(_ url: URL, application: URL? = nil) async throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { throw OfficeEditingError.localFileUnavailable }
        let selected: URL
        if let application { selected = application }
        else if let associated = NSWorkspace.shared.urlForApplication(toOpen: url) { selected = associated }
        else {
            guard let chosen = chooseApplication() else { throw CancellationError() }
            selected = chosen
        }
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: selected, configuration: .init())
    }

    static func chooseLocalCopy(for item: FileItem) -> URL? {
        let panel = NSSavePanel()
        panel.title = L10n.string("files.office.localCopyTitle")
        panel.message = L10n.string("files.office.localCopyDetail")
        panel.prompt = L10n.string("files.office.openAutoSave")
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        if let ext = item.fileExtension, let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        panel.allowsOtherFileTypes = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct OfficeDocumentEditingButton: View {
    let model: WorkspaceModel
    let item: FileItem
    var body: some View {
        Menu {
            Button(L10n.string("files.office.openAutoSave")) { model.beginOfficeEditing(item) }
            Button(L10n.string("files.office.chooseApplication")) { model.beginOfficeEditing(item, chooseApplication: true) }
        } label: {
            Label(L10n.string("files.office.edit"), systemImage: "square.and.pencil")
        }
        .disabled(item.isRecyclePath || OfficeEditingCoordinator.shared.preparingIDs.contains(item.id))
        .help(L10n.string("files.office.editHelp"))
    }
}

extension OfficeEditingSession.Phase {
    var title: String {
        switch self {
        case .preparing: L10n.string("files.office.preparing")
        case .watching: L10n.string("files.office.watching")
        case .waitingForSave: L10n.string("files.office.waitingForSave")
        case .saving: L10n.string("files.office.saving")
        case .saved: L10n.string("files.office.saved")
        case .paused: L10n.string("files.office.pausedTitle")
        case .conflict: L10n.string("files.office.conflictTitle")
        case .needsReview: L10n.string("files.office.reviewTitle")
        case .stopped: L10n.string("files.office.stopped")
        }
    }
    var isProblem: Bool { [.paused, .conflict, .needsReview].contains(self) }
}

struct OfficeEditingSessionsView: View {
    let profileID: UUID
    var coordinator: OfficeEditingCoordinator = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var stopping: OfficeEditingSession?
    private var sessions: [OfficeEditingSession] { coordinator.sessions.filter { $0.item.profileID == profileID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("files.office.sessions")).font(.title2.bold())
                Spacer()
                Button(L10n.string("files.common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if sessions.isEmpty {
                ContentUnavailableView(L10n.string("files.office.noSessions"), systemImage: "doc",
                    description: Text(L10n.string("files.office.noSessionsDetail"))).fillsAvailableContentArea()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(sessions) { session in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(session.item.name).font(.headline).lineLimit(2)
                                    Spacer()
                                    if session.isBusy { ProgressView().controlSize(.small) }
                                    Text(session.phase.title).foregroundStyle(session.phase.isProblem ? .orange : .secondary)
                                }
                                if let message = session.message { Text(message).font(.callout).fixedSize(horizontal: false, vertical: true) }
                                HStack {
                                    Button(L10n.string("files.office.showCopy")) { NSWorkspace.shared.activateFileViewerSelecting([session.localURL]) }
                                    Button(L10n.string("files.office.openCopy")) {
                                        Task {
                                            do { try await OfficeDocumentActions.open(session.localURL) }
                                            catch is CancellationError { }
                                            catch { self.error = L10n.string("files.office.openFailed") }
                                        }
                                    }.disabled(session.phase == .preparing)
                                    Spacer()
                                    if session.canRetry {
                                        Button(L10n.string("files.office.retry")) { Task { await session.retry() } }
                                    }
                                    if session.phase == .needsReview {
                                        Button(L10n.string("files.office.review")) { Task { await session.review() } }.disabled(session.isBusy)
                                    }
                                    if !session.isStopped {
                                        Button(L10n.string("files.office.stop")) { stopping = session }.disabled(session.isBusy)
                                    }
                                }
                            }.padding(14).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }.padding(24).frame(width: 780, height: 490)
            .confirmationDialog(L10n.string("files.office.stopTitle"), isPresented: Binding(
                get: { stopping != nil }, set: { if !$0 { stopping = nil } }), titleVisibility: .visible) {
                Button(L10n.string("files.office.stop")) { stopping?.stop(); stopping = nil }
                Button(L10n.string("ui.fd4b9e3b6c685bae"), role: .cancel) { stopping = nil }
            } message: { Text(L10n.string("files.office.stopDetail")) }
    }
}
