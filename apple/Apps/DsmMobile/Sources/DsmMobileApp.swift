import DsmLocalization
import SwiftUI

@main
struct DsmMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MobileAppModel()
    @State private var language = AppLanguageStore.shared

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
                .environment(language)
                .environment(\.locale, language.locale)
                .task(id: chatForegroundContext) {
                    await model.chatModel.setForegroundRealtimeActive(
                        chatForegroundContext.isActive
                    )
                }
        }
    }

    private var chatForegroundContext: MobileChatForegroundContext {
        MobileChatForegroundContext(
            isActive: scenePhase == .active
                && model.isConnected
                && model.selectedModule == .chat
                && model.activeProfile?.id == model.chatModel.activeProfileID,
            profileID: model.chatModel.activeProfileID
        )
    }
}

private struct MobileChatForegroundContext: Hashable {
    let isActive: Bool
    let profileID: UUID?
}
