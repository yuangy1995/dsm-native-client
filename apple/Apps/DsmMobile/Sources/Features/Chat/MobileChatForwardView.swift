import DsmCore
import DsmLocalization
import SwiftUI

struct MobileChatForwardSheet: View {
    @Bindable var forwarding: MobileChatForwardModel
    let messages: [ChatMessage]
    var initialSelection: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var presentsRecipients = false

    var body: some View {
        NavigationStack {
            Group {
                if messages.isEmpty {
                    ContentUnavailableView(L10n.string("mobile.chat.forward.no-messages"), systemImage: "bubble.left",
                        description: Text(L10n.string("mobile.chat.forward.no-messages-help"))).fillsAvailableContentArea()
                } else {
                    List(messages) { message in
                        Button {
                            if !selected.insert(message.id).inserted { selected.remove(message.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selected.contains(message.id) ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(message.senderDisplayName ?? L10n.string("mobile.chat.sender.unknown")).font(.subheadline.weight(.semibold))
                                    Text(message.text ?? L10n.string("mobile.chat.interaction.attachment")).lineLimit(4)
                                    ForEach(message.attachments) { attachment in
                                        Label(attachment.fileName, systemImage: "paperclip").font(.subheadline).foregroundStyle(.secondary)
                                    }
                                    Text(message.sentAt, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).disabled(!forwarding.canSelect(message) && !selected.contains(message.id))
                        .accessibilityAddTraits(selected.contains(message.id) ? .isSelected : [])
                        .accessibilityIdentifier("chat-forward-source-\(message.id)")
                    }.listStyle(.plain)
                }
            }
            .navigationTitle(L10n.string("mobile.chat.forward.select"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.chat.forward.next")) { presentsRecipients = true }
                        .disabled(selected.isEmpty || !messages.filter { selected.contains($0.id) }.allSatisfy(forwarding.canSelect))
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("chat-forward-next")
                }
            }
            .navigationDestination(isPresented: $presentsRecipients) {
                MobileChatForwardRecipientsView(forwarding: forwarding, messages: messages.filter { selected.contains($0.id) })
            }
            .onAppear { if selected.isEmpty { selected = initialSelection } }
        }
    }
}

private struct MobileChatForwardRecipientsView: View {
    @Bindable var forwarding: MobileChatForwardModel
    let messages: [ChatMessage]
    @State private var query = ""
    @State private var isSearching = false
    @State private var conversations: Set<String> = []
    @State private var contacts: Set<String> = []
    @State private var batchID: UUID?
    private var visibleConversations: [ChatConversation] { forwarding.conversations.filter { matches($0.title) } }
    private var visibleContacts: [ChatUser] { forwarding.contacts.filter { matches($0.displayName) } }
    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }

    var body: some View {
        Group {
            if forwarding.targetState == .content, !forwarding.recovery.failed {
                content.searchable(text: $query, isPresented: $isSearching,
                    placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("mobile.chat.forward.search"))
            } else { content }
        }
            .navigationTitle(L10n.string("mobile.chat.forward.recipients"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.chat.forward.action")) {
                        isSearching = false
                        if let id = forwarding.createBatch(messages: messages, conversationIDs: conversations, contactIDs: contacts) {
                            batchID = id
                            Task { await forwarding.run(id, continuePlanned: true) }
                        }
                    }
                    .disabled((conversations.isEmpty && contacts.isEmpty) || forwarding.isBusy || forwarding.recovery.failed
                        || !messages.allSatisfy(forwarding.canSelect) || (!contacts.isEmpty && !forwarding.canSelectNewContact))
                    .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("chat-forward-submit")
                }
            }
            .navigationDestination(item: $batchID) { id in MobileChatForwardResultView(forwarding: forwarding, id: id) }
            .task { await forwarding.loadTargets(sourceConversationID: messages.first?.conversationID ?? "") }
            .onAppear {
                conversations.formIntersection(Set(forwarding.conversations.map(\.id)))
                contacts.formIntersection(Set(forwarding.contacts.map(\.id)))
            }
    }

    @ViewBuilder private var content: some View {
        if forwarding.recovery.failed {
            ContentUnavailableView(L10n.string("mobile.chat.create.storage-error.title"), systemImage: "exclamationmark.circle",
                description: Text(L10n.string("mobile.chat.interaction.storage-error"))).fillsAvailableContentArea()
        } else if forwarding.targetState == .loading {
            ProgressView(L10n.string("mobile.chat.forward.loading")).fillsAvailableContentArea()
        } else if forwarding.targetState == .error {
            ContentUnavailableView {
                Label(L10n.string("mobile.chat.forward.load-error"), systemImage: "exclamationmark.bubble")
            } description: { Text(L10n.string("mobile.chat.forward.load-help")) }
            actions: { Button(L10n.string("mobile.chat.action.retry")) { Task { await forwarding.loadTargets(sourceConversationID: messages.first?.conversationID ?? "") } } }
                .fillsAvailableContentArea()
        } else if forwarding.targetState == .empty {
            ContentUnavailableView(L10n.string("mobile.chat.forward.empty"), systemImage: "person.2",
                description: Text(L10n.string("mobile.chat.forward.empty-help"))).fillsAvailableContentArea()
        } else if visibleConversations.isEmpty && visibleContacts.isEmpty {
            ContentUnavailableView {
                Label(L10n.string("mobile.chat.forward.filtered-empty"), systemImage: "magnifyingglass")
            } description: { Text(L10n.string("mobile.chat.create.filtered-empty.message")) }
            actions: { Button(L10n.string("mobile.chat.forward.clear-search")) { query = ""; isSearching = false } }
                .fillsAvailableContentArea()
        } else {
            List {
                if let error = forwarding.errorKey { Text(L10n.string(error)).foregroundStyle(.orange) }
                if !visibleConversations.isEmpty {
                    Section(L10n.string("mobile.chat.forward.conversations")) {
                        ForEach(visibleConversations) { conversation in
                            choice(conversation.title, selected: conversations.contains(conversation.id), id: "conversation-\(conversation.id)") {
                                if !conversations.insert(conversation.id).inserted { conversations.remove(conversation.id) }
                            }
                        }
                    }
                }
                if !visibleContacts.isEmpty {
                    Section(L10n.string("mobile.chat.forward.contacts")) {
                        ForEach(visibleContacts) { user in
                            choice(user.displayName, selected: contacts.contains(user.id), id: "contact-\(user.id)") {
                                if !contacts.insert(user.id).inserted { contacts.remove(user.id) }
                            }.disabled(!forwarding.canSelectNewContact)
                        }
                        if !forwarding.canSelectNewContact { Text(L10n.string("mobile.chat.forward.contact-busy")).foregroundStyle(.secondary) }
                    }
                }
                if forwarding.contactsUnavailable { Text(L10n.string("mobile.chat.forward.contacts-error")).foregroundStyle(.secondary) }
            }
        }
    }
    private func choice(_ title: String, selected: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button {
            action(); isSearching = false
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").accessibilityHidden(true)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("chat-forward-target-\(id)")
    }
}

struct MobileChatForwardRecordsSheet: View {
    @Bindable var forwarding: MobileChatForwardModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if forwarding.recovery.failed {
                    ContentUnavailableView(L10n.string("mobile.chat.create.storage-error.title"), systemImage: "exclamationmark.circle",
                        description: Text(L10n.string("mobile.chat.interaction.storage-error"))).fillsAvailableContentArea()
                } else if forwarding.entries.isEmpty {
                    ContentUnavailableView(L10n.string("mobile.chat.forward.no-records"), systemImage: "arrowshape.turn.up.right").fillsAvailableContentArea()
                } else {
                    List(forwarding.entries.reversed()) { entry in
                        NavigationLink {
                            MobileChatForwardResultView(forwarding: forwarding, id: entry.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.createdAt, format: .dateTime.month().day().hour().minute())
                                Text(L10n.string(entry.hasUnfinished ? "mobile.chat.forward.incomplete" : "mobile.chat.forward.finished"))
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.frame(minHeight: 44)
                        }.accessibilityIdentifier("chat-forward-record-\(entry.id)")
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.chat.forward.records"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }
}

private struct MobileChatForwardResultView: View {
    @Bindable var forwarding: MobileChatForwardModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let entry = forwarding.entry(id) {
                List {
                    if forwarding.recovery.isExecuting(id) {
                        ProgressView(L10n.string("mobile.chat.forward.running"))
                        if entry.hasPlanned {
                            Button(L10n.string("mobile.chat.forward.cancel-remaining")) { forwarding.cancelRemaining(id) }
                                .accessibilityIdentifier("chat-forward-cancel-remaining").frame(minHeight: 44)
                        }
                    }
                    if forwarding.recovery.failed { Text(L10n.string("mobile.chat.interaction.storage-error")).foregroundStyle(.orange) }
                    else if forwarding.errorBatchID == id, let error = forwarding.errorKey { Text(L10n.string(error)).foregroundStyle(.orange) }
                    ForEach(Array(entry.items.enumerated()), id: \.element.id) { index, item in
                        Section {
                            ForEach(entry.destinations) { destination in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(title(destination))
                                    Text(L10n.string(status(item, destination))).font(.subheadline).foregroundStyle(.secondary)
                                }.frame(minHeight: 44).accessibilityElement(children: .combine)
                                    .accessibilityIdentifier("chat-forward-result-\(index)-\(destination.referenceID)")
                            }
                        } header: {
                            Text(L10n.string("mobile.chat.forward.message-number", index + 1))
                        } footer: { Text(item.source.sentAt, format: .dateTime.year().month().day().hour().minute()) }
                    }
                    if !forwarding.recovery.isExecuting(id) {
                        if entry.hasSubmitted {
                            Button(L10n.string("mobile.chat.forward.refresh")) { Task { await forwarding.run(id, continuePlanned: false) } }
                                .accessibilityIdentifier("chat-forward-refresh").frame(minHeight: 44)
                        }
                        if entry.hasPlanned && !entry.hasSubmitted {
                            Button(L10n.string("mobile.chat.forward.continue")) { Task { await forwarding.run(id, continuePlanned: true) } }
                                .disabled(!forwarding.canForward).accessibilityIdentifier("chat-forward-continue").frame(minHeight: 44)
                        }
                        if entry.hasPlanned {
                            Button(L10n.string("mobile.chat.forward.cancel-remaining")) { forwarding.cancelRemaining(id) }
                                .accessibilityIdentifier("chat-forward-cancel-remaining").frame(minHeight: 44)
                        }
                        if !entry.hasUnfinished {
                            Button(L10n.string("mobile.chat.forward.remove-record")) { forwarding.remove(id); if forwarding.entry(id) == nil { dismiss() } }
                                .accessibilityIdentifier("chat-forward-remove-record").frame(minHeight: 44)
                        }
                    }
                }.disabled(forwarding.recovery.failed)
            } else { ContentUnavailableView(L10n.string("mobile.chat.forward.no-records"), systemImage: "arrowshape.turn.up.right").fillsAvailableContentArea() }
        }
        .navigationTitle(L10n.string("mobile.chat.forward.results"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) {
            if let entry = forwarding.entry(id) { await forwarding.loadTargets(sourceConversationID: entry.items[0].source.conversationID) }
        }
    }

    private func title(_ destination: MobileChatForwardStore.Destination) -> String {
        if let id = destination.conversationID, let conversation = forwarding.conversations.first(where: { $0.id == id }) { return conversation.title }
        if destination.kind == .contact, let contact = forwarding.contacts.first(where: { $0.id == destination.referenceID }) { return contact.displayName }
        return L10n.string(destination.kind == .contact ? "mobile.chat.forward.contact" : "chat.search.conversation")
    }
    private func status(_ item: MobileChatForwardStore.Item, _ destination: MobileChatForwardStore.Destination) -> String {
        if destination.phase == .failed { return "mobile.chat.forward.recipient-failed" }
        if destination.phase == .cancelled || item.phase == .cancelled { return "mobile.chat.forward.cancelled" }
        if destination.phase == .submitted { return "mobile.chat.forward.preparing-contact" }
        if destination.phase == .planned { return "mobile.chat.forward.planned" }
        if let target = item.receipt?.targets.first(where: { $0.conversationID == destination.conversationID }), target.confirmedMessageID != nil {
            return "mobile.chat.forward.sent"
        }
        if item.phase == .failed { return "mobile.chat.forward.failed" }
        return item.phase == .submitted ? "mobile.chat.forward.pending" : "mobile.chat.forward.planned"
    }
}
