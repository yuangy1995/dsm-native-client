import DsmCore
import DsmLocalization
import SwiftUI

struct MobileRootView: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        Group {
            if model.isConnected {
                MobileWorkspaceView(model: model)
            } else {
                MobileLoginView(model: model)
            }
        }
        .mobileAppearanceRoot()
        .tint(.blue)
        .preferredColorScheme(model.settingsStore.appearance.colorScheme)
    }
}
