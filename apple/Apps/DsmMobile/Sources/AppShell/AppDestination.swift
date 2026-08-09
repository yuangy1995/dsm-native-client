import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

enum MobileTopLevelDestination: String, CaseIterable, Identifiable {
    case files
    case photos
    case chat
    case activity
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: L10n.string("ui.39932f24fe11a6ba")
        case .photos: L10n.string("ui.7b50017ae47eca32")
        case .chat: L10n.string("shared.4b3510b8d86ea785")
        case .activity: L10n.string("mobile.navigation.activity")
        case .more: L10n.string("ui.38844b135cf70dfc")
        }
    }

    var systemImage: String {
        switch self {
        case .files: "folder"
        case .photos: "photo.on.rectangle.angled"
        case .chat: "bubble.left.and.bubble.right"
        case .activity: "arrow.up.arrow.down.circle"
        case .more: "ellipsis.circle"
        }
    }

    var defaultModule: MobileModule {
        switch self {
        case .files: .files
        case .photos: .photos
        case .chat: .chat
        case .activity: .transfers
        case .more: .nasSettings
        }
    }

    var childModules: [MobileModule] {
        switch self {
        case .files: [.files]
        case .photos: [.photos]
        case .chat: [.chat]
        case .activity: [.transfers, .downloads]
        case .more: [.nasSettings, .containers, .virtualMachines, .settings]
        }
    }
}

struct MobileProfileNavigationState: Equatable, Sendable {
    var selectedTopLevel: MobileTopLevelDestination
    var selectedModule: MobileModule

    static let initial = MobileProfileNavigationState(
        selectedTopLevel: .files,
        selectedModule: .files
    )
}

enum MobileModule: String, CaseIterable, Identifiable {
    case files
    case photos
    case chat
    case downloads
    case containers
    case virtualMachines
    case nasSettings
    case transfers
    case settings

    var id: String { rawValue }

    static let optionalPreferenceModules: Set<MobileModule> = [
        .downloads,
        .containers,
        .virtualMachines,
        .nasSettings,
    ]

    var isOptionalPreference: Bool {
        Self.optionalPreferenceModules.contains(self)
    }

    func isAvailable(in capabilities: CapabilitySet?) -> Bool {
        guard let capabilities else { return true }
        func supports(_ apiName: String) -> Bool {
            capabilities[apiName]?.selectedVersion != nil
        }

        switch self {
        case .downloads:
            return supports(DsmAPIName.downloadStationTask)
        case .containers:
            return supports(DsmAPIName.dockerContainer)
        case .virtualMachines:
            return supports(DsmAPIName.virtualizationAPIGuest)
        case .nasSettings:
            return [
                DsmAPIName.coreSystem,
                DsmAPIName.coreSystemUtilization,
                DsmAPIName.storageOverview,
                DsmAPIName.coreUpgradeServer,
            ].contains(where: supports)
        case .files, .photos, .chat, .transfers, .settings:
            return true
        }
    }

    var supportsMutatingManagement: Bool {
        switch self {
        case .chat, .downloads, .containers, .virtualMachines, .nasSettings:
            false
        default:
            true
        }
    }

    var title: String {
        switch self {
        case .files: L10n.string("ui.8e8343f9178e476d")
        case .photos: L10n.string("ui.7b50017ae47eca32")
        case .chat: L10n.string("ui.4da199fae933d4fa")
        case .downloads: L10n.string("ui.5248507df52ff455")
        case .containers: L10n.string("ui.aaf778d85ce5c2ed")
        case .virtualMachines: L10n.string("ui.80c43bd2481c9580")
        case .nasSettings: L10n.string("ui.b1729f4b03c4b97d")
        case .transfers: L10n.string("ui.74c2308f64b688ae")
        case .settings: L10n.string("ui.df3d58c7d84b85f2")
        }
    }

    var systemImage: String {
        switch self {
        case .files: "folder"
        case .photos: "photo.on.rectangle.angled"
        case .chat: "bubble.left.and.bubble.right"
        case .downloads: "arrow.down.circle"
        case .containers: "shippingbox"
        case .virtualMachines: "desktopcomputer"
        case .nasSettings: "externaldrive"
        case .transfers: "arrow.up.arrow.down"
        case .settings: "gearshape"
        }
    }
}
