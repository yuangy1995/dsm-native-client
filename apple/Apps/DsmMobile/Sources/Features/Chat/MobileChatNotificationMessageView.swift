import DsmCore
import DsmLocalization
import SwiftUI

struct MobileChatNotificationMessageView: View {
    @Bindable var chat: MobileChatModel
    let destination: MobileChatNotifications.Destination
    @Environment(\.dismiss) private var dismiss
    @State private var message: ChatMessage?
    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L10n.string("mobile.chat.loading.messages")).fillsAvailableContentArea()
                } else if let message, let interaction = chat.interaction {
                    MobileChatDiscussionView(chat: chat, interaction: interaction, message: message)
                } else {
                    ContentUnavailableView {
                        Label(L10n.string(failed ? "chat.thread.failed" : "mobile.chat.interaction.missing"), systemImage: "bubble.left")
                    } description: {
                        Text(L10n.string(failed ? "chat.thread.recovery" : "mobile.chat.interaction.missing-help"))
                    } actions: {
                        if failed { Button(L10n.string("mobile.chat.action.retry")) { Task { await load() } } }
                    }.fillsAvailableContentArea()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minHeight: 44)
                }
            }
        }
        .task { await load() }
        .onChange(of: chat.notifications.scope) { _, scope in if scope != destination.scope { dismiss() } }
        .onDisappear { chat.interaction?.closeDiscussion() }
    }

    private func load() async {
        isLoading = true; failed = false
        do { message = try await chat.notificationMessage(destination) }
        catch is CancellationError { dismiss() }
        catch { failed = true }
        isLoading = false
    }
}
