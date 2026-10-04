import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

enum MobileTopLevelDestination: String, CaseIterable, Identifiable {
    case files, photos, chat, downloads, containers, virtualMachines, nasSettings, settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .files: L10n.string("ui.39932f24fe11a6ba")
        case .settings: L10n.string("mobile.navigation.settings")
        default: defaultModule.title
        }
    }
    var systemImage: String { defaultModule.systemImage }
    var defaultModule: MobileModule { MobileModule(rawValue: rawValue)! }
    var childModules: [MobileModule] { self == .files ? [.files, .transfers] : [defaultModule] }
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
        .photos,
        .chat,
        .downloads,
        .containers,
        .virtualMachines,
        .nasSettings,
    ]

    var isOptionalPreference: Bool {
        Self.optionalPreferenceModules.contains(self)
    }

    func isAvailable(in capabilities: CapabilitySet?) -> Bool {
        guard let capabilities else { return !isOptionalPreference }
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
        case .photos:
            return ["SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.TeamSpace"].allSatisfy(supports)
        case .chat:
            return supports(DsmAPIName.chatChannel) && supports(DsmAPIName.chatUser)
        case .files, .transfers, .settings:
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
        case .photos: L10n.string("mobile.navigation.photos")
        case .chat: L10n.string("mobile.navigation.chat")
        case .downloads: L10n.string("mobile.navigation.downloads")
        case .containers: L10n.string("mobile.navigation.containers")
        case .virtualMachines: L10n.string("mobile.navigation.virtualMachines")
        case .nasSettings: L10n.string("mobile.navigation.nasSettings")
        case .transfers: L10n.string("mobile.navigation.activity")
        case .settings: L10n.string("mobile.navigation.settings")
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
