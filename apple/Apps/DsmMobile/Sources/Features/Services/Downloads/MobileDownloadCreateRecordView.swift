import DsmLocalization
import SwiftUI

struct MobileDownloadCreateRecordView: View {
    @Bindable var model: MobileDownloadsModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    private var entry: MobileDownloadCreateStore.Entry? { model.createEntries.first { $0.id == id } }
    var body: some View {
        List {
            if model.createRecovery.failed {
                Text(L10n.string("download.edit.storage-error")).foregroundStyle(.orange)
            }
            if let entry {
                Section {
                    Text(L10n.string(entry.source == .link ? "download.creation.link" : "download.creation.file"))
                    Text(entry.createdAt.formatted(.dateTime.locale(L10n.locale))).foregroundStyle(.secondary)
                    Text(L10n.string(Self.statusKey(entry, executing: model.createRecovery.isExecuting(id))))
                        .accessibilityIdentifier("downloads.creation.status.\(entry.phase.rawValue)")
                } footer: {
                    if entry.phase == .submitted && !model.createRecovery.isExecuting(id) {
                        Text(L10n.string("mobile.downloads.create.review.message"))
                    } else if entry.phase == .failed {
                        Text(L10n.string(entry.failure == .denied ? "mobile.downloads.create.permission.message" : "mobile.downloads.create.failure.message"))
                    }
                }
                if let message = model.message { Text(message).foregroundStyle(.orange) }
                if entry.phase == .submitted {
                    Button(L10n.string("download.creation.refresh")) { model.reloadDownloads() }
                        .disabled(model.isLoading || model.createRecovery.isExecuting(id))
                        .accessibilityIdentifier("downloads.creation.refresh")
                } else {
                    Button(L10n.string("mobile.downloads.batch.remove-record")) {
                        model.removeDownloadCreation(id); if self.entry == nil { dismiss() }
                    }
                    .disabled(model.createRecovery.isExecuting(id))
                    .accessibilityIdentifier("downloads.creation.remove")
                }
            }
        }
        .navigationTitle(L10n.string("mobile.downloads.create.menu"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("downloads.creation.record")
    }
    static func statusKey(_ entry: MobileDownloadCreateStore.Entry, executing: Bool) -> String {
        switch entry.phase {
        case .submitted: executing ? "mobile.downloads.create.creating.title" : "mobile.downloads.create.review.title"
        case .accepted: "mobile.downloads.create.success.title"
        case .cancelled: "mobile.downloads.create.cancelled.title"
        case .failed: entry.failure == .denied ? "mobile.downloads.create.permission.title" : "mobile.downloads.create.failure.title"
        }
    }
}
