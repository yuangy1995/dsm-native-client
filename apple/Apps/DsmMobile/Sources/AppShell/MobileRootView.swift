import DsmCore
import DsmLocalization
import SwiftUI

struct MobileRootView: View {
    @Bindable var model: MobileAppModel

    var body: some View {
        Group {
            #if DEBUG
            if MobileFilesUIFixture.isEnabled {
                MobileFilesUIFixtureView(app: model)
            } else if MobileShareUIFixture.isEnabled {
                MobileShareUIFixtureView(model: model)
            } else {
                content
            }
            #else
            content
            #endif
        }
        .tint(.blue)
        .preferredColorScheme(model.settingsStore.appearance.colorScheme)
    }

    @ViewBuilder private var content: some View {
        if model.isConnected {
            MobileWorkspaceView(model: model)
                .id(model.activeProfile.map(MobileWorkspaceIdentity.init))
        } else {
            MobileLoginView(model: model)
        }
    }
}
