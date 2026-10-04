import DsmCore
import DsmLocalization
import SwiftUI

struct MobileChatDeletionSheet: View {
    @Bindable var chat: MobileChatModel
    @Bindable var deletion: MobileChatDeletionModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var query = ""
    @State private var isSearching = false
    @State private var confirmsDelete = false
    @State private var confirmationMessages: [ChatMessage] = []
    @State private var batchID: UUID?
    private var messages: [ChatMessage] { chat.state.selectedMessages.messages.filter(MobileChatDeletionModel.permits) }
    private var visible: [ChatMessage] {
        messages.filter { query.isEmpty || $0.text?.localizedStandardContains(query) == true
            || $0.attachments.contains { $0.fileName.localizedStandardContains(query) } }
    }
    private var selection: [ChatMessage] { messages.filter { selected.contains($0.id) } }

    var body: some View {
        NavigationStack {
            Group {
                if !messages.isEmpty, !deletion.recovery.failed {
                    content.searchable(text: $query, isPresented: $isSearching,
                        placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("mobile.chat.deletion.search"))
                } else { content }
            }
            .navigationTitle(L10n.string("mobile.chat.deletion.select"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.chat.message.action.delete"), role: .destructive) {
                        confirmationMessages = selection; isSearching = false; confirmsDelete = true
                    }
                        .disabled(selection.isEmpty || selection.count != selected.count || !selection.allSatisfy(deletion.canSelect))
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("chat-deletion-submit")
                }
            }
            .confirmationDialog(L10n.string("mobile.chat.deletion.confirm", confirmationMessages.count), isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button(L10n.string("mobile.chat.message.action.delete"), role: .destructive) {
                    if let id = deletion.createBatch(confirmationMessages) {
                        batchID = id; selected = []
                        Task { await deletion.run(id, continuePlanned: true) }
                    }
                }.accessibilityIdentifier("chat-deletion-confirm")
                Button(L10n.string("mobile.chat.message.delete.confirm.cancel"), role: .cancel) {}
            } message: { Text(L10n.string("mobile.chat.deletion.confirm.message")) }
            .navigationDestination(item: $batchID) { id in MobileChatDeletionResultView(deletion: deletion, id: id) }
        }
    }

    @ViewBuilder private var content: some View {
        if deletion.recovery.failed {
            ContentUnavailableView(L10n.string("mobile.chat.create.storage-error.title"), systemImage: "exclamationmark.circle",
                description: Text(L10n.string("mobile.chat.interaction.storage-error"))).fillsAvailableContentArea()
        } else if chat.state.messagePageState == .loading {
            ProgressView(L10n.string("mobile.chat.loading.messages")).fillsAvailableContentArea()
        } else if chat.state.messagePageState == .error {
            ContentUnavailableView {
                Label(L10n.string("mobile.chat.deletion.load-error"), systemImage: "exclamationmark.bubble")
            } description: { Text(L10n.string("mobile.chat.deletion.load-help")) }
            actions: { Button(L10n.string("mobile.chat.action.retry")) { Task { await chat.refreshMessages() } } }
                .fillsAvailableContentArea()
        } else if messages.isEmpty {
            ContentUnavailableView(L10n.string("mobile.chat.deletion.empty"), systemImage: "bubble.left",
                description: Text(L10n.string("mobile.chat.deletion.empty-help"))).fillsAvailableContentArea()
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label(L10n.string("mobile.chat.deletion.filtered-empty"), systemImage: "magnifyingglass")
            } description: { Text(L10n.string("mobile.chat.create.filtered-empty.message")) }
            actions: { Button(L10n.string("mobile.chat.forward.clear-search")) { query = ""; isSearching = false } }
                .fillsAvailableContentArea()
        } else {
            List {
                if let key = deletion.errorKey { Text(L10n.string(key)).foregroundStyle(.orange) }
                ForEach(visible) { message in
                    Button {
                        if !selected.insert(message.id).inserted { selected.remove(message.id) }
                        isSearching = false
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: selected.contains(message.id) ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(message.text ?? L10n.string("mobile.chat.interaction.attachment")).lineLimit(4)
                                ForEach(message.attachments) { attachment in
                                    Label(attachment.fileName, systemImage: "paperclip").font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text(message.sentAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(!deletion.canSelect(message) && !selected.contains(message.id))
                        .accessibilityAddTraits(selected.contains(message.id) ? .isSelected : [])
                        .accessibilityIdentifier("chat-deletion-source-\(message.id)")
                }
            }.listStyle(.plain)
        }
    }
}

struct MobileChatDeletionRecordsSheet: View {
    @Bindable var deletion: MobileChatDeletionModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if deletion.recovery.failed {
                    ContentUnavailableView(L10n.string("mobile.chat.create.storage-error.title"), systemImage: "exclamationmark.circle",
                        description: Text(L10n.string("mobile.chat.interaction.storage-error"))).fillsAvailableContentArea()
                } else if deletion.entries.isEmpty {
                    ContentUnavailableView(L10n.string("mobile.chat.deletion.no-records"), systemImage: "trash").fillsAvailableContentArea()
                } else {
                    List(deletion.entries.reversed()) { entry in
                        NavigationLink {
                            MobileChatDeletionResultView(deletion: deletion, id: entry.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                                Text(L10n.string(entry.hasUnfinished ? "mobile.chat.deletion.incomplete" : "mobile.chat.deletion.finished"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }.accessibilityIdentifier("chat-deletion-record-\(entry.id)")
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.chat.deletion.records"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }
}

private struct MobileChatDeletionResultView: View {
    @Bindable var deletion: MobileChatDeletionModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsContinue = false
    var body: some View {
        Group {
            if let entry = deletion.entry(id) {
                List {
                    if deletion.recovery.isExecuting(id) {
                        ProgressView(L10n.string("mobile.chat.message.delete.progress"))
                    }
                    if deletion.recovery.failed { Text(L10n.string("mobile.chat.interaction.storage-error")).foregroundStyle(.orange) }
                    else if deletion.errorBatchID == id, let key = deletion.errorKey { Text(L10n.string(key)).foregroundStyle(.orange) }
                    ForEach(Array(entry.items.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.string("mobile.chat.forward.message-number", index + 1)).font(.headline)
                            Text(item.source.sentAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.string(status(item))).foregroundStyle(item.phase == .failed ? .orange : .secondary)
                        }.frame(minHeight: 44).accessibilityElement(children: .combine)
                            .accessibilityIdentifier("chat-deletion-result-\(index)")
                    }
                    if !deletion.recovery.isExecuting(id) {
                        if entry.hasSubmitted {
                            Button(L10n.string("mobile.chat.forward.refresh")) { Task { await deletion.run(id, continuePlanned: false) } }
                                .accessibilityIdentifier("chat-deletion-refresh").frame(minHeight: 44)
                        }
                        if entry.hasPlanned && !entry.hasSubmitted {
                            Button(L10n.string("mobile.chat.deletion.continue"), role: .destructive) { confirmsContinue = true }
                                .disabled(!deletion.canDelete).accessibilityIdentifier("chat-deletion-continue").frame(minHeight: 44)
                        }
                        if !entry.hasUnfinished {
                            Button(L10n.string("mobile.chat.forward.remove-record")) { deletion.remove(id); if deletion.entry(id) == nil { dismiss() } }
                                .accessibilityIdentifier("chat-deletion-remove-record").frame(minHeight: 44)
                        }
                    }
                    if entry.hasPlanned {
                        Button(L10n.string("mobile.chat.deletion.cancel-remaining")) { deletion.cancelRemaining(id) }
                            .accessibilityIdentifier("chat-deletion-cancel-remaining").frame(minHeight: 44)
                    }
                }.disabled(deletion.recovery.failed)
                    .confirmationDialog(L10n.string("mobile.chat.deletion.confirm", entry.items.filter { $0.phase == .planned }.count),
                        isPresented: $confirmsContinue, titleVisibility: .visible) {
                        Button(L10n.string("mobile.chat.deletion.continue"), role: .destructive) { Task { await deletion.run(id, continuePlanned: true) } }
                            .accessibilityIdentifier("chat-deletion-confirm-continue")
                        Button(L10n.string("mobile.chat.message.delete.confirm.cancel"), role: .cancel) {}
                    } message: { Text(L10n.string("mobile.chat.deletion.confirm.message")) }
            } else { ContentUnavailableView(L10n.string("mobile.chat.deletion.no-records"), systemImage: "trash").fillsAvailableContentArea() }
        }
        .navigationTitle(L10n.string("mobile.chat.deletion.results"))
        .navigationBarTitleDisplayMode(.inline)
    }
    private func status(_ item: MobileChatDeletionStore.Item) -> String {
        switch item.phase {
        case .planned: "mobile.chat.deletion.planned"
        case .submitted: "chat.delete.pending"
        case .complete: "mobile.chat.deletion.deleted"
        case .cancelled: "mobile.chat.deletion.cancelled"
        case .failed:
            switch item.failure {
            case .changed: "chat.message.changed"
            case .denied: "chat.delete.unavailable"
            default: "mobile.chat.deletion.failed"
            }
        }
    }
}
