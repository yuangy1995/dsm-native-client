import DsmLocalization
import SwiftUI

@main
struct DsmMobileApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = initialModel()
    @State private var language = AppLanguageStore.shared

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
                .environment(language)
                .environment(\.locale, language.locale)
                #if DEBUG
                .task {
                    if MobileUIFixture.isEnabled, let profile = model.activeProfile {
                        await model.prepareWorkspaceContext(for: profile)
                        await model.loadSelectedModule()
                        await MobileUIFixture.prepareUploadSelection(model)
                    }
                }
                #endif
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.refreshModuleAccess() } }
                }
                .onChange(of: model.chatModel.notifications.destination) { _, destination in
                    if destination != nil, model.isConnected, model.isModuleVisible(.chat) { model.selectModule(.chat) }
                }
                .task(id: chatForegroundContext) {
                    await model.updateChatForeground(
                        chatForegroundContext.isActive
                    )
                }
        }
    }

    private static func initialModel() -> MobileAppModel {
        #if DEBUG
        if MobileUIFixture.isEnabled { return MobileUIFixture.makeModel() }
        #endif
        return MobileAppModel(transferRecoveryStore: .application,
            transferBackgroundExecution: MobileTransferBackgroundExecution(driver: MobileSystemTransferBackgroundDriver(),
                identifierPrefix: (Bundle.main.bundleIdentifier ?? "io.github.qwertyuiop1995.dsmnativeclient.mobile") + ".transfer"))
    }

    private var chatForegroundContext: MobileChatForegroundContext {
        MobileChatForegroundContext(
            isActive: scenePhase == .active
                && model.isConnected
                && model.isModuleVisible(.chat),
            context: model.activeProfile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        )
    }
}

private struct MobileChatForegroundContext: Hashable {
    let isActive: Bool
    let context: String?
}
