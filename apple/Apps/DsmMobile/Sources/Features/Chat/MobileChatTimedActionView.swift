import DsmCore
import DsmLocalization
import SwiftUI

enum MobileChatTimedListKind: String, Identifiable {
    case reminders, schedules
    var id: String { rawValue }
    var titleKey: String { self == .reminders ? "mobile.chat.reminder.list" : "mobile.chat.schedule.list" }
}

struct MobileChatTimedListSheet: View {
    @Bindable var timed: MobileChatTimedActionModel
    @Bindable var chat: MobileChatModel
    let conversation: ChatConversation
    let kind: MobileChatTimedListKind
    @Environment(\.dismiss) private var dismiss
    @State private var createsSchedule = false
    @State private var selectedReminder: ChatReminder?
    @State private var cancelsReminder: ChatReminder?
    @State private var cancelsSchedule: ChatScheduledMessage?
    @State private var filter = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                MobileChatTimedFeedback(timed: timed, conversationID: conversation.id, reminders: kind == .reminders)
                MobilePageStateView(state: pageState, labels: labels,
                    emptySystemImage: kind == .reminders ? "bell" : "clock", retryAction: { Task { await refresh() } }) {
                    List {
                        if kind == .reminders {
                            ForEach(visibleReminders) { reminder in reminderRow(reminder) }
                        } else {
                            ForEach(visibleSchedules) { schedule in scheduleRow(schedule) }
                        }
                    }
                    .refreshable { await refresh() }
                }
            }
            .searchable(text: $filter, prompt: L10n.string("mobile.chat.timed.search"))
            .navigationTitle(L10n.string(kind.titleKey))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if kind == .schedules {
                        Button { createsSchedule = true } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                            .accessibilityLabel(L10n.string("mobile.chat.schedule.create"))
                            .accessibilityIdentifier("chat-schedule-create")
                    }
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("mobile.chat.action.refresh-messages"))
                        .accessibilityIdentifier("chat-timed-refresh")
                        .disabled(timed.isMutating || timed.isRecovering)
                }
            }
        }
        .task { timed.clearError(); await refresh() }
        .sheet(isPresented: $createsSchedule) { MobileChatScheduleComposer(timed: timed, conversation: conversation) }
        .sheet(item: $selectedReminder) { reminder in
            MobileChatReminderDetail(timed: timed, reminder: reminder, conversationID: conversation.id)
        }
        .alert(L10n.string("mobile.chat.reminder.cancel-title"), isPresented: Binding(
            get: { cancelsReminder != nil }, set: { if !$0 { cancelsReminder = nil } })) {
            Button(L10n.string("mobile.chat.timed.keep"), role: .cancel) { cancelsReminder = nil }
            Button(L10n.string("mobile.chat.reminder.cancel"), role: .destructive) {
                if let value = cancelsReminder { Task { _ = await timed.deleteReminder(value, in: conversation.id) } }
                cancelsReminder = nil
            }
        } message: { Text(L10n.string("mobile.chat.reminder.cancel-message")) }
        .alert(L10n.string("mobile.chat.schedule.cancel-title"), isPresented: Binding(
            get: { cancelsSchedule != nil }, set: { if !$0 { cancelsSchedule = nil } })) {
            Button(L10n.string("mobile.chat.timed.keep"), role: .cancel) { cancelsSchedule = nil }
            Button(L10n.string("mobile.chat.schedule.cancel"), role: .destructive) {
                if let value = cancelsSchedule { Task { _ = await timed.deleteSchedule(value) } }
                cancelsSchedule = nil
            }
        } message: { Text(L10n.string("mobile.chat.schedule.cancel-message", cancelsSchedule?.text ?? "")) }
    }

    private var sourceState: MobilePageState { kind == .reminders ? timed.reminderState : timed.scheduleState }
    private var pageState: MobilePageState {
        if sourceState == .content, !filter.isEmpty, visibleReminders.isEmpty, visibleSchedules.isEmpty { return .filteredEmpty }
        return sourceState
    }
    private var visibleReminders: [ChatReminder] {
        guard kind == .reminders else { return [] }
        return timed.reminders.filter { filter.isEmpty || summary($0).localizedStandardContains(filter) }
    }
    private var visibleSchedules: [ChatScheduledMessage] {
        guard kind == .schedules else { return [] }
        return timed.schedules.filter { filter.isEmpty || $0.text.localizedStandardContains(filter) }
    }
    private func summary(_ reminder: ChatReminder) -> String {
        let message = chat.state.messagesByConversation[conversation.id]?.messages.first { $0.id == reminder.messageID && $0.conversationID == conversation.id }
        return message?.text?.isEmpty == false ? message!.text! : message?.attachments.first?.fileName ?? L10n.string("mobile.chat.reminder.open")
    }
    private func reminderRow(_ value: ChatReminder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { selectedReminder = value } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(summary(value)).foregroundStyle(Color.primary).lineLimit(3)
                    Text(value.remindAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(Color.secondary)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
            }.buttonStyle(.borderless).accessibilityIdentifier("chat-reminder-open-\(value.messageID)")
            Button(L10n.string("mobile.chat.reminder.cancel"), role: .destructive) { cancelsReminder = value }
                .buttonStyle(.borderless).frame(minHeight: 44)
                .disabled(timed.isBusy || timed.hasPending(in: conversation.id, targetID: value.messageID, reminder: true))
                .accessibilityIdentifier("chat-reminder-cancel-\(value.messageID)")
        }
    }
    private func scheduleRow(_ value: ChatScheduledMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value.text).textSelection(.enabled)
            Text(value.sendAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
            Button(L10n.string("mobile.chat.schedule.cancel"), role: .destructive) { cancelsSchedule = value }
                .buttonStyle(.borderless).frame(minHeight: 44)
                .disabled(timed.isBusy || value.sendAt <= Date() || timed.hasPending(in: conversation.id, targetID: value.id, reminder: false))
                .accessibilityIdentifier("chat-schedule-cancel-\(value.id)")
        }
    }
    private func refresh() async {
        await timed.recover()
        if kind == .reminders { await timed.loadReminders(in: conversation.id) }
        else { await timed.loadSchedules(in: conversation.id) }
    }
    private var labels: MobilePageStateLabels {
        let prefix = kind == .reminders ? "mobile.chat.reminder" : "mobile.chat.schedule"
        return MobilePageStateLabels(loading: L10n.string("mobile.chat.timed.loading"),
            emptyTitle: L10n.string(prefix + ".empty"), emptyMessage: L10n.string(prefix + ".empty-message"),
            filteredEmptyTitle: L10n.string("mobile.chat.timed.filtered"), filteredEmptyMessage: L10n.string("mobile.chat.timed.filtered-message"),
            errorTitle: L10n.string("mobile.chat.timed.load-error"), errorMessage: L10n.string("mobile.chat.timed.retry-message"),
            retryTitle: L10n.string("mobile.chat.action.retry"))
    }
}

struct MobileChatScheduleComposer: View {
    @Bindable var timed: MobileChatTimedActionModel
    let conversation: ChatConversation
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var date = Date().addingTimeInterval(3_600)
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.string("mobile.chat.schedule.text"), text: $text, axis: .vertical)
                        .lineLimit(4...10).accessibilityIdentifier("chat-schedule-text")
                    DatePicker(L10n.string("mobile.chat.schedule.date"), selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                }.disabled(!timed.canCreateSchedule(in: conversation))
                MobileChatTimedFeedback(timed: timed, conversationID: conversation.id, reminders: false)
                Button(L10n.string("mobile.chat.schedule.create")) {
                    Task { if await timed.createSchedule(in: conversation, text: text, at: date) { dismiss() } }
                }
                .frame(minHeight: 44).accessibilityIdentifier("chat-schedule-submit")
                .disabled(!timed.canCreateSchedule(in: conversation) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || date <= Date())
            }
            .navigationTitle(L10n.string("mobile.chat.schedule.create"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await timed.recover() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("mobile.chat.action.refresh-messages")).disabled(timed.isBusy)
                }
            }
        }
        .onAppear { timed.clearError() }
    }
}

struct MobileChatReminderEditor: View {
    @Bindable var timed: MobileChatTimedActionModel
    let original: ChatMessage
    @Environment(\.dismiss) private var dismiss
    @State private var date = Date().addingTimeInterval(3_600)
    @State private var baseline: ChatReminder?
    @State private var loaded = false
    @State private var cancels = false
    var body: some View {
        NavigationStack {
            Form {
                Text(original.text?.isEmpty == false ? original.text! : original.attachments.first?.fileName ?? L10n.string("mobile.chat.reminder.open"))
                if !loaded {
                    if timed.reminderState == .error {
                        Text(L10n.string("mobile.chat.timed.retry-message"))
                        Button(L10n.string("mobile.chat.action.retry")) { Task { await refresh() } }.frame(minHeight: 44)
                    } else { ProgressView(L10n.string("mobile.chat.timed.loading")) }
                } else {
                    DatePicker(L10n.string("mobile.chat.reminder.date"), selection: $date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .disabled(!timed.canSetReminder(original))
                    Button(L10n.string("mobile.chat.reminder.save")) {
                        Task { if await timed.setReminder(for: original, at: date, replacing: baseline) { dismiss() } }
                    }.frame(minHeight: 44).accessibilityIdentifier("chat-reminder-save")
                        .disabled(!timed.canSetReminder(original) || date <= Date())
                    if baseline != nil {
                        Button(L10n.string("mobile.chat.reminder.cancel"), role: .destructive) { cancels = true }
                            .frame(minHeight: 44).disabled(!timed.canSetReminder(original))
                    }
                }
                MobileChatTimedFeedback(timed: timed, conversationID: original.conversationID, reminders: true)
            }
            .navigationTitle(L10n.string("mobile.chat.reminder.action"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("mobile.chat.action.refresh-messages")).disabled(timed.isBusy)
                }
            }
        }
        .task { timed.clearError(); await refresh() }
        .alert(L10n.string("mobile.chat.reminder.cancel-title"), isPresented: $cancels) {
            Button(L10n.string("mobile.chat.timed.keep"), role: .cancel) {}
            Button(L10n.string("mobile.chat.reminder.cancel"), role: .destructive) {
                if let baseline { Task { if await timed.deleteReminder(baseline, in: original.conversationID) { dismiss() } } }
            }
        } message: { Text(L10n.string("mobile.chat.reminder.cancel-message")) }
    }
    private func refresh() async {
        loaded = false; await timed.recover(); await timed.loadReminders(in: original.conversationID)
        if timed.reminderState == .content || timed.reminderState == .empty {
            baseline = timed.reminders.first { $0.messageID == original.id }
            if let baseline { date = max(baseline.remindAt, Date().addingTimeInterval(60)) }
            loaded = true
        }
    }
}

private struct MobileChatReminderDetail: View {
    @Bindable var timed: MobileChatTimedActionModel
    let reminder: ChatReminder
    let conversationID: String
    @Environment(\.dismiss) private var dismiss
    @State private var message: ChatMessage?
    @State private var state: MobilePageState = .loading
    var body: some View {
        Group {
            if let message { MobileChatReminderEditor(timed: timed, original: message) }
            else {
                NavigationStack {
                    Group {
                        if state == .loading { ProgressView(L10n.string("mobile.chat.timed.loading")) }
                        else {
                            ContentUnavailableView {
                                Label(L10n.string(state == .empty ? "mobile.chat.timed.message-missing" : "mobile.chat.timed.load-error"), systemImage: "bubble.left")
                            } description: { Text(L10n.string("mobile.chat.timed.retry-message")) }
                            actions: { Button(L10n.string("mobile.chat.action.retry")) { Task { await load() } } }
                        }
                    }.fillsAvailableContentArea()
                        .navigationTitle(L10n.string("mobile.chat.reminder.action"))
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("files.common.close")) { dismiss() } } }
                }
            }
        }.task { await load() }
    }
    private func load() async {
        state = .loading
        do { message = try await timed.message(for: reminder, in: conversationID); state = message == nil ? .empty : .content }
        catch { state = .error }
    }
}

private struct MobileChatTimedFeedback: View {
    @Bindable var timed: MobileChatTimedActionModel
    let conversationID: String
    let reminders: Bool
    var body: some View {
        let keys = Set(timed.pending.filter { $0.conversationID == conversationID && $0.kind.isReminder == reminders }
            .map { MobileChatTimedActionModel.pendingKey($0.kind) }).sorted()
        if !keys.isEmpty || timed.error(in: conversationID) != nil || timed.recovery.failed || timed.isMutating || timed.isRecovering {
            VStack(alignment: .leading, spacing: 8) {
                if timed.recovery.failed { Text(L10n.string("mobile.chat.interaction.storage-error")) }
                else if let key = timed.error(in: conversationID), !keys.contains(key) { Text(L10n.string(key)) }
                ForEach(keys, id: \.self) { Text(L10n.string($0)) }
                if timed.isMutating || timed.isRecovering { ProgressView() }
            }
            .font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}
