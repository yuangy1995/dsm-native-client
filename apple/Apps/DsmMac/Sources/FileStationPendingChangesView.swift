import DsmCore
import DsmLocalization
import SwiftUI

struct FileStationPendingChangesView: View {
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [FileStationPendingChange] = []
    @State private var loading = true
    @State private var busy: String?
    @State private var feedback: [String: String] = [:]
    @State private var verified: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("files.pending.title")).font(.title2.bold())
                Spacer()
                Button(L10n.string("files.sharing.refresh")) { Task { await load() } }.disabled(busy != nil)
                Button(L10n.string("files.common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text(L10n.string("files.pending.scope")).foregroundStyle(.secondary)
            if loading { ProgressView().fillsAvailableContentArea() }
            else if rows.isEmpty {
                ContentUnavailableView(L10n.string("files.pending.empty"), systemImage: "checkmark.circle",
                    description: Text(L10n.string("files.pending.emptyDetail"))).fillsAvailableContentArea()
            } else {
                List(rows) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(title(row.kind)).font(.headline)
                                if let target = row.target { Text(target).textSelection(.enabled) }
                            }
                            Spacer()
                            if busy == row.id { ProgressView().controlSize(.small) }
                            Button(L10n.string("files.permissions.review")) { Task { await review(row) } }.disabled(busy != nil || verified.contains(row.id))
                        }
                        if let message = feedback[row.id] { Text(message).foregroundStyle(.secondary) }
                    }.padding(.vertical, 8)
                }
            }
        }.padding(24).frame(width: 700, height: 460).task { await load() }
    }

    private func load() async {
        rows = await model.pendingFileStationChanges()
        loading = false
    }
    private func title(_ kind: FileStationPendingChange.Kind) -> String {
        switch kind {
        case .permissions: L10n.string("files.pending.kind.permissions")
        case .iso: L10n.string("files.pending.kind.iso")
        case .connection: L10n.string("files.pending.kind.connection")
        case .general: L10n.string("files.pending.kind.general")
        case .mountAccess: L10n.string("files.pending.kind.mountAccess")
        case .bandwidth: L10n.string("files.pending.kind.bandwidth")
        case .theme: L10n.string("files.pending.kind.theme")
        }
    }
    private func review(_ row: FileStationPendingChange) async {
        guard busy == nil else { return }
        busy = row.id; defer { busy = nil }
        do {
            let result = try await model.reviewPendingFileStationChange(id: row.id)
            feedback[row.id] = result.localizationKey.map { L10n.string($0) }
                ?? L10n.string(result.status == .confirmedSuccess ? "files.pending.verified" : "files.settings.pending")
            if result.status == .confirmedSuccess { verified.insert(row.id) }
            // 核查成功后保留本次反馈，主动刷新时移除已完成项目。
        } catch {
            feedback[row.id] = (error as? AppError)?.safeUserMessage ?? L10n.string("files.advanced.readFailed")
        }
    }
}
