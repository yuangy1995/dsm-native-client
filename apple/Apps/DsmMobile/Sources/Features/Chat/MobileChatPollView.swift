import DsmCore
import DsmLocalization
import SwiftUI

struct MobileChatCreatePollSheet: View {
    @Bindable var polls: MobileChatPollModel
    let conversation: ChatConversation
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var multiple = false
    @State private var anonymous = false

    private var hasPending: Bool { polls.pending.contains { $0.kind == .create && $0.conversationID == conversation.id } }
    private var valid: Bool {
        options.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && (try? ChatPollDraft(conversationID: conversation.id, question: question, options: options,
                allowsMultipleSelection: multiple, isAnonymous: anonymous)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if polls.recovery.failed {
                    Text(L10n.string("mobile.chat.interaction.storage-error")).foregroundStyle(.orange)
                } else if hasPending {
                    Section {
                        Text(L10n.string("mobile.chat.poll.create-pending"))
                        Button(L10n.string("mobile.chat.action.refresh-messages")) {
                            Task { await polls.recover(); if !hasPending && !polls.recovery.failed { dismiss() } }
                        }.disabled(polls.isMutating || polls.isRecovering)
                    }
                } else if let error = polls.errorKey { Text(L10n.string(error)).foregroundStyle(.orange) }
                if !hasPending, !valid, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   options.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    Text(L10n.string("mobile.chat.poll.invalid")).foregroundStyle(.orange)
                }
                Group {
                    Section(L10n.string("mobile.chat.poll.question")) {
                        TextField(L10n.string("mobile.chat.poll.question"), text: $question, axis: .vertical)
                            .lineLimit(2...6).accessibilityIdentifier("chat-poll-question")
                    }
                    Section(L10n.string("mobile.chat.poll.options")) {
                        ForEach(options.indices, id: \.self) { index in
                            HStack {
                                TextField(L10n.string("mobile.chat.poll.option", index + 1), text: $options[index], axis: .vertical)
                                    .accessibilityIdentifier("chat-poll-option-\(index)")
                                if options.count > 2 {
                                    Button { options.remove(at: index) } label: {
                                        Image(systemName: "minus.circle").frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel(L10n.string("mobile.chat.poll.remove-option", index + 1))
                                }
                            }
                        }
                        if options.count < 10 {
                            Button { options.append("") } label: { Label(L10n.string("mobile.chat.poll.add-option"), systemImage: "plus") }
                                .frame(minHeight: 44).accessibilityIdentifier("chat-poll-add-option")
                        }
                    }
                    Section {
                        Toggle(L10n.string("mobile.chat.poll.multiple"), isOn: $multiple).accessibilityIdentifier("chat-poll-multiple")
                        Toggle(L10n.string("mobile.chat.poll.anonymous"), isOn: $anonymous).accessibilityIdentifier("chat-poll-anonymous")
                    }
                }
                .disabled(hasPending || polls.isMutating || polls.recovery.failed)
            }
            .navigationTitle(L10n.string("mobile.chat.poll.create"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.chat.poll.create")) {
                        Task {
                            if await polls.create(in: conversation, question: question, options: options, multiple: multiple, anonymous: anonymous) { dismiss() }
                        }
                    }
                    .disabled(!valid || !polls.canCreate(in: conversation)).frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("chat-poll-submit")
                }
            }
            .interactiveDismissDisabled(polls.isMutating)
            .task { await polls.recover() }
        }
    }
}

struct MobileChatPollSheet: View {
    @Bindable var polls: MobileChatPollModel
    let original: ChatMessage
    @Environment(\.dismiss) private var dismiss
    @State private var choices: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if polls.isLoading && polls.message == nil {
                    ProgressView(L10n.string("mobile.chat.poll.loading")).fillsAvailableContentArea()
                } else if polls.missing {
                    ContentUnavailableView(L10n.string("mobile.chat.interaction.missing"), systemImage: "chart.bar.xaxis",
                        description: Text(L10n.string("mobile.chat.interaction.missing-help"))).fillsAvailableContentArea()
                } else if let value = polls.message, let poll = value.poll {
                    detail(value, poll: poll)
                } else {
                    ContentUnavailableView {
                        Label(L10n.string("mobile.chat.poll.load-failed"), systemImage: "chart.bar.xaxis")
                    } description: { Text(L10n.string("chat.vote.recovery")) }
                    actions: { Button(L10n.string("mobile.chat.action.retry")) { Task { await reload() } } }
                        .fillsAvailableContentArea()
                }
            }
            .navigationTitle(L10n.string("chat.vote.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("mobile.chat.action.refresh-messages"))
                        .disabled(polls.isLoading || polls.isMutating || polls.isRecovering)
                }
            }
            .task { await reload() }
            .onDisappear { polls.close() }
            .interactiveDismissDisabled(polls.isMutating)
        }
    }

    private func detail(_ value: ChatMessage, poll: ChatPoll) -> some View {
        Form {
            Section {
                Text(poll.question).font(.headline)
                if poll.isAnonymous { Text(L10n.string("mobile.chat.poll.anonymous")).font(.subheadline).foregroundStyle(.secondary) }
                Text(L10n.string(poll.isClosed ? "chat.vote.closed" : (poll.allowsMultipleSelection ? "chat.vote.multiple" : "chat.vote.single")))
                    .font(.subheadline).foregroundStyle(.secondary)
                if let closesAt = poll.closesAt {
                    LabeledContent(L10n.string("mobile.chat.poll.closes")) {
                        Text(closesAt, format: .dateTime.year().month().day().hour().minute())
                    }
                }
            }
            Section {
                ForEach(poll.options) { option in
                    Button {
                        if poll.allowsMultipleSelection {
                            if choices.contains(option.id) { choices.remove(option.id) } else { choices.insert(option.id) }
                        } else { choices = [option.id] }
                    } label: {
                        HStack(alignment: .top) {
                            Image(systemName: choices.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(option.text).foregroundStyle(Color.primary).fixedSize(horizontal: false, vertical: true)
                                Text(L10n.string("chat.vote.count", option.voteCount)).font(.caption).foregroundStyle(Color.secondary)
                            }
                        }
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .disabled(polls.isMutating || poll.isClosed || poll.closesAt.map({ $0 <= Date() }) == true || polls.recovery.failed)
                    .accessibilityAddTraits(choices.contains(option.id) ? .isSelected : [])
                    .accessibilityIdentifier("chat-poll-choice-\(option.id)")
                }
                Button(L10n.string("chat.vote.submit")) {
                    let selected = choices
                    Task { _ = await polls.vote(value, choices: selected) }
                }
                .disabled(!polls.canVote(value, choices: choices)).frame(minHeight: 44)
                .accessibilityIdentifier("chat-poll-vote")
            }
            if polls.recovery.failed { Text(L10n.string("mobile.chat.interaction.storage-error")).foregroundStyle(.orange) }
            else if let error = polls.errorKey { Text(L10n.string(error)).foregroundStyle(.orange) }
            else if polls.pending.contains(where: { $0.kind == .vote && $0.conversationID == value.conversationID && $0.messageID == value.id }) {
                Text(L10n.string("mobile.chat.poll.vote-pending")).foregroundStyle(.secondary)
            }
        }
        .refreshable { if !polls.isMutating { await reload() } }
    }

    private func reload() async {
        await polls.open(original)
        choices = Set(polls.message?.poll?.options.filter(\.isSelectedByCurrentUser).map(\.id) ?? [])
    }
}
