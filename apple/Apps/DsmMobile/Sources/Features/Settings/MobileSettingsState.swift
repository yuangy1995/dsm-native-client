import SwiftUI

enum MobileAppearancePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var titleKey: String {
        switch self {
        case .system: "mobile.settings.appearance.system"
        case .light: "mobile.settings.appearance.light"
        case .dark: "mobile.settings.appearance.dark"
        }
    }
}

enum MobileSettingsCacheResult: Equatable, Sendable {
    case success
    case failure
}
