import DsmCore
import DsmLocalization
import SwiftUI

struct ChatSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ChatWorkspaceModel
    let conversation: ChatConversation?
    @State private var query = ""
    @State private var searchesAll = false
    @State private var results: [ChatMessage] = []
    @State private var cursor: String?
    @State private var isLoading = false
    @State private var hasSearched = false
    @State private var error: String?
    @State private var result: ChatMessage?
    @State private var searchTask: Task<Void, Never>?
    @State private var generation = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("chat.search.title")).font(.headline)
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            HStack {
                TextField(L10n.string("chat.search.placeholder"), text: $query)
                    .textFieldStyle(.roundedBorder).onSubmit { search(more: false) }
                if conversation != nil {
                    Picker(L10n.string("chat.search.scope"), selection: $searchesAll) {
                        Text(L10n.string("chat.search.current")).tag(false)
                        Text(L10n.string("chat.search.all")).tag(true)
                    }.labelsHidden().fixedSize()
                }
                Button(L10n.string("chat.search.action"), systemImage: "magnifyingglass") { search(more: false) }
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            if isLoading && results.isEmpty {
                ProgressView(L10n.string("chat.search.loading")).fillsAvailableContentArea()
            } else if let error, results.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string("chat.search.failed"), systemImage: "magnifyingglass")
                } description: { Text(error) } actions: {
                    Button(L10n.string("ui.b8784c8dd5636ff2")) { search(more: false) }
                }.fillsAvailableContentArea()
            } else if results.isEmpty {
                ContentUnavailableView(hasSearched ? L10n.string("chat.search.empty") : L10n.string("chat.search.title"),
                    systemImage: "magnifyingglass", description: Text(L10n.string(hasSearched ? "chat.search.tryOther" : "chat.search.placeholder")))
                    .fillsAvailableContentArea()
            } else {
                List {
                    ForEach(results) { message in
                        Button { result = message } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(model.conversations.first(where: { $0.id == message.conversationID })?.title ?? L10n.string("chat.search.conversation"))
                                        .font(.headline)
                                    Spacer()
                                    Text(message.sentAt.formatted(.dateTime.locale(L10n.locale).year().month().day().hour().minute()))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(message.text ?? message.poll?.question ?? L10n.string("chat.preview.attachment"))
                                    .lineLimit(3).multilineTextAlignment(.leading)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if cursor != nil {
                        Button(L10n.string("chat.search.more")) { search(more: true) }.disabled(isLoading)
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }.macThemedScrollContent()
            }
        }
        .frame(width: 680, height: 570)
        .macSheet(item: $result) { message in ChatDiscussionSheet(model: model, initialMessage: message) }
        .onChange(of: query) { _, _ in invalidateSearch() }
        .onChange(of: searchesAll) { _, _ in invalidateSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    private func invalidateSearch() {
        searchTask?.cancel(); generation = UUID(); isLoading = false
        results = []; cursor = nil; hasSearched = false; error = nil
    }

    private func search(more: Bool) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !more || !isLoading else { return }
        searchTask?.cancel()
        let id = UUID(); generation = id
        let keyword = query, next = more ? cursor : nil
        let channel = searchesAll ? nil : conversation?.id
        if !more { results = []; cursor = nil }
        error = nil; isLoading = true; hasSearched = true
        searchTask = Task {
            do {
                let page = try await model.searchMessages(query: keyword, conversationID: channel, cursor: next)
                guard generation == id, !Task.isCancelled else { return }
                var ids = Set(results.map(\.id))
                results += page.messages.filter { ids.insert($0.id).inserted }
                cursor = page.nextCursor
            } catch {
                guard generation == id, !Task.isCancelled else { return }
                self.error = L10n.string("chat.search.recovery")
            }
            if generation == id { isLoading = false }
        }
    }
}

struct ChatEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ChatWorkspaceModel
    let message: ChatMessage
    var onSaved: (ChatMessage) -> Void = { _ in }
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("chat.edit.title")).font(.headline)
            TextEditor(text: $text).font(.body).frame(minHeight: 150)
                .accessibilityLabel(L10n.string("chat.edit.text"))
                .disabled(model.editingDrafts[message.id] != nil || model.isPerformingAction)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string(model.editingDrafts[message.id] == nil ? "chat.edit.save" : "chat.update.refresh")) {
                    Task {
                        if let updated = await model.editMessage(message, text: text) {
                            onSaved(updated); dismiss()
                        } else { error = model.statusMessage }
                    }
                }.buttonStyle(.borderedProminent)
                    .disabled(model.isPerformingAction || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(20).frame(width: 500)
        .onAppear { text = model.editingDrafts[message.id]?.text ?? message.text ?? "" }
    }
}

struct ChatVotingSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ChatWorkspaceModel
    let initialMessage: ChatMessage
    @State private var message: ChatMessage?
    @State private var choices: Set<String> = []
    @State private var error: String?
    @State private var isLoading = true

    private var current: ChatMessage { message ?? initialMessage }
    private var poll: ChatPoll? { current.poll }
    private var isPending: Bool { model.votingDrafts[initialMessage.id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(poll?.question ?? L10n.string("chat.vote.title")).font(.headline)
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if isLoading { ProgressView().frame(maxWidth: .infinity) }
            if let poll {
                Text(L10n.string(poll.isClosed ? "chat.vote.closed" : poll.allowsMultipleSelection ? "chat.vote.multiple" : "chat.vote.single"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(poll.options) { option in
                    Button {
                        if poll.allowsMultipleSelection {
                            if choices.contains(option.id) { choices.remove(option.id) } else { choices.insert(option.id) }
                        } else { choices = [option.id] }
                    } label: {
                        HStack {
                            Image(systemName: choices.contains(option.id) ? "checkmark.circle.fill" : "circle")
                            Text(option.text).multilineTextAlignment(.leading)
                            Spacer()
                            Text(L10n.string("chat.vote.count", option.voteCount))
                        }.padding(10).contentShape(Rectangle())
                    }.buttonStyle(.bordered)
                        .accessibilityAddTraits(choices.contains(option.id) ? .isSelected : [])
                        .disabled(poll.isClosed || isPending || model.isPerformingAction || isLoading)
                }
                if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button(L10n.string("chat.update.refresh")) { Task { await refresh() } }.disabled(isLoading || model.isPerformingAction)
                    Spacer()
                    Button(L10n.string(isPending ? "chat.update.refresh" : "chat.vote.submit")) {
                        Task {
                            if let updated = await model.vote(current, choices: choices) {
                                message = updated
                                choices = Set(updated.poll?.options.filter(\.isSelectedByCurrentUser).map(\.id) ?? [])
                                error = nil
                            } else { error = model.statusMessage }
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(isLoading || model.isPerformingAction || choices.isEmpty || poll.isClosed)
                }
            } else {
                Text(L10n.string("chat.vote.unavailable"))
            }
        }.padding(20).frame(width: 500)
        .task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let fresh = try await model.loadMessage(initialMessage), fresh.poll != nil else { throw CocoaError(.fileReadUnknown) }
            message = fresh
            choices = model.votingDrafts[initialMessage.id]?.choices ?? Set(fresh.poll!.options.filter(\.isSelectedByCurrentUser).map(\.id))
            error = nil
        } catch { self.error = L10n.string("chat.vote.recovery") }
    }
}

struct ChatDiscussionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ChatWorkspaceModel
    let initialMessage: ChatMessage
    @State private var root: ChatMessage?
    @State private var replies: [ChatMessage] = []
    @State private var cursor: String?
    @State private var isLoading = true
    @State private var isLoadingMore = false
    @State private var error: String?
    @State private var text = ""
    @State private var edit: ChatMessage?
    @State private var vote: ChatMessage?
    @State private var media: ChatMediaSelection?
    @State private var voicePlayback = ChatVoicePlayback()
    @State private var atBottom = false
    @State private var visibleReplyID: String?
    @State private var isWindowActive = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("chat.thread.title")).font(.headline)
                Spacer()
                Button(L10n.string("chat.update.refresh")) { Task { await load() } }.disabled(isLoading)
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if isLoading && root == nil {
                ProgressView().fillsAvailableContentArea()
            } else if let root {
                GeometryReader { viewport in
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                discussionMessage(root)
                                if initialMessage.id != root.id && !replies.contains(where: { $0.id == initialMessage.id }) {
                                    discussionMessage(initialMessage)
                                }
                                Divider()
                                if cursor != nil {
                                    Button(L10n.string("chat.thread.earlier")) { Task { await loadMore() } }.disabled(isLoadingMore)
                                }
                                if replies.isEmpty { Text(L10n.string("chat.thread.empty")).foregroundStyle(.secondary) }
                                ForEach(replies) { reply in discussionMessage(reply).id(reply.id) }
                                Color.clear.frame(height: 1).id("discussion-bottom")
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(key: ChatBottomPreference.self, value: ChatVisibleMessage(messageID: replies.last?.id,
                                            bottom: geometry.frame(in: .named("discussion-scroll")).maxY))
                                    })
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        }.coordinateSpace(name: "discussion-scroll")
                            .onPreferenceChange(ChatBottomPreference.self) { position in
                                atBottom = position.bottom > 0 && position.bottom <= viewport.size.height + 2
                                visibleReplyID = atBottom ? position.messageID : nil
                                if atBottom { Task { await model.synchronizeThreadRead(root, lastMessageID: visibleReplyID, isVisible: isWindowActive) } }
                            }
                            .onChange(of: replies.last?.id) { _, _ in
                                if atBottom { proxy.scrollTo("discussion-bottom", anchor: .bottom) }
                            }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).padding(.horizontal, 16) }
                if model.canReply && model.selectedConversationID == root.conversationID {
                    Divider()
                    HStack(alignment: .bottom) {
                        TextField(L10n.string("chat.thread.placeholder"), text: $text, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(1...5)
                            .disabled(model.replyDrafts[root.id] != nil || model.isPerformingAction)
                        Button(L10n.string(model.replyDrafts[root.id] == nil ? "chat.thread.send" : "chat.update.refresh")) {
                            Task {
                                if let reply = await model.sendReply(to: root, text: text) {
                                    text = ""; error = nil
                                    if !replies.contains(where: { $0.id == reply.id }) { replies.append(reply) }
                                    await load()
                                } else { error = model.statusMessage }
                            }
                        }.buttonStyle(.borderedProminent)
                            .disabled(model.isPerformingAction || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .keyboardShortcut(.return, modifiers: .command)
                    }.padding(16)
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.string("chat.thread.failed"), systemImage: "bubble.left.and.bubble.right")
                } description: { Text(error ?? L10n.string("chat.thread.recovery")) } actions: {
                    Button(L10n.string("ui.b8784c8dd5636ff2")) { Task { await load() } }
                }.fillsAvailableContentArea()
            }
        }.frame(width: 680, height: 590)
            .background(ChatWindowActivity { active in isWindowActive = active })
            .macSheet(item: $edit) { value in
                ChatEditSheet(model: model, message: value) { updated in
                    if root?.id == updated.id { root = updated }
                    if let index = replies.firstIndex(where: { $0.id == updated.id }) { replies[index] = updated }
                }
            }
            .macSheet(item: $vote) { value in ChatVotingSheet(model: model, initialMessage: value) }
            .macSheet(item: $media) { value in ChatMediaSheet(model: model, selection: value) }
            .task { await load() }
            .task(id: model.workspaceSyncIntervalSeconds) {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(model.workspaceSyncIntervalSeconds)) } catch { return }
                    if !isLoading, !isLoadingMore { await load() }
                }
            }
            .onDisappear { voicePlayback.stop(); isWindowActive = false; atBottom = false; visibleReplyID = nil }
            .onChange(of: isWindowActive) { _, active in
                if active, let root { Task { await model.synchronizeThreadRead(root, lastMessageID: visibleReplyID, isVisible: atBottom) } }
            }
    }

    private func discussionMessage(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(message.senderDisplayName ?? model.displayName(for: message.senderID) ?? L10n.string("chat.search.conversation"))
                    .font(.headline)
                Text(message.sentAt.formatted(.dateTime.locale(L10n.locale).month().day().hour().minute()))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.canEdit(message) {
                    Button(L10n.string("chat.edit.action"), systemImage: "pencil") { edit = message }.labelStyle(.iconOnly)
                }
            }
            if let body = message.text { Text(body).textSelection(.enabled) }
            ForEach(message.attachments) { attachment in
                if attachment.kind == .video || attachment.kind == .voice {
                    let selection = ChatMediaSelection(message: message, attachment: attachment)
                    Text(attachment.fileName).font(.callout)
                    ChatMediaPlaybackButton(selection: selection, playback: voicePlayback) {
                        if attachment.kind == .voice {
                            Task { await voicePlayback.toggle(selection, model: model) }
                        } else {
                            voicePlayback.stop()
                            media = selection
                        }
                    }
                } else { Label(attachment.fileName, systemImage: "paperclip") }
            }
            if message.poll != nil {
                Button(L10n.string("chat.vote.title"), systemImage: "chart.bar.xaxis") { vote = message }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func load() async {
        guard !isLoadingMore else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let value = try await model.loadDiscussionRoot(initialMessage) else { throw CocoaError(.fileReadUnknown) }
            let page = try await model.loadReplies(for: value, before: nil)
            try Task.checkCancellation()
            root = value
            if replies.isEmpty { replies = page.messages; cursor = page.previousCursor }
            else {
                let newIDs = Set(page.messages.map(\.id))
                let oldest = page.messages.first?.sentAt ?? .distantPast
                replies = (replies.filter { !newIDs.contains($0.id) && page.hasMoreBefore && $0.sentAt < oldest } + page.messages)
                    .sorted { $0.sentAt < $1.sentAt }
            }
            if let pending = model.replyDrafts[value.id] { text = pending.text ?? "" }
            error = nil
            if atBottom, visibleReplyID == replies.last?.id {
                await model.synchronizeThreadRead(value, lastMessageID: visibleReplyID, isVisible: isWindowActive)
            }
        } catch is CancellationError { return }
        catch { self.error = L10n.string("chat.thread.recovery") }
    }

    private func loadMore() async {
        guard let root, let cursor, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await model.loadReplies(for: root, before: cursor)
            let ids = Set(replies.map(\.id))
            replies = page.messages.filter { !ids.contains($0.id) } + replies
            self.cursor = page.previousCursor
        } catch { self.error = L10n.string("chat.thread.recovery") }
    }
}

struct ChatVisibleMessage: Equatable {
    let messageID: String?
    let bottom: CGFloat
}

struct ChatBottomPreference: PreferenceKey {
    static let defaultValue = ChatVisibleMessage(messageID: nil, bottom: -1)
    static func reduce(value: inout ChatVisibleMessage, nextValue: () -> ChatVisibleMessage) { value = nextValue() }
}
