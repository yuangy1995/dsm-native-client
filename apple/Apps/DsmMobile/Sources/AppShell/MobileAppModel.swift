import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

@MainActor
@Observable
final class MobileAppModel {
    struct DiscoveredConnection {
        let profile: NasProfile
        let capabilities: CapabilitySet
    }

    let profileKey = "lanstash.mobile.profiles.v1"
    let lastProfileKey = "lanstash.mobile.last-profile.v1"
    let autoLoginKeyPrefix = "lanstash.mobile.auto-login.v1."
    let defaults: UserDefaults
    let sessionStore: any SessionSecureStoring
    let passwordStore: any PasswordSecureStoring
    let authRepository: any AuthRepository
    let quickConnectResolver: any QuickConnectResolving
    let mutationCoordinator: MobileMutationCoordinator
    let transferCoordinator: MobileTransferCoordinator
    let documentTransferController: MobileDocumentTransferController
    let settingsStore: MobileSettingsStore
    let fileBrowserModel = MobileFileBrowserModel()
    let filePreviewModel = MobileFilePreviewModel()
    let fileShareLinkModel: MobileFileShareLinkModel
    let photoLibraryModel = MobilePhotoLibraryModel()
    let chatModel = MobileChatModel()
    let nasHealthModel = MobileNasHealthModel()
    let containerInventoryModel = MobileContainerInventoryModel()
    let virtualMachineInventoryModel = MobileVirtualMachineInventoryModel()

    var profiles: [NasProfile] = []
    var selectedProfileID: UUID?
    var displayName = L10n.string("ui.b457fa7f7764aef5")
    var host = ""
    var port = ""
    var username = ""
    var password = ""
    var otpCode = ""
    var rememberPassword = false
    var autoLoginEnabled = false
    var needsOTP = false
    var isConnecting = false
    var loginError: String?
    var connectionStatus: String?
    var pendingCertificate: MobileCertificatePrompt?
    @ObservationIgnored var connectionTask: Task<Void, Never>?
    @ObservationIgnored var connectionAttemptID: UUID?
    @ObservationIgnored var certificateRetryContext: MobileCertificateRetryContext?
    @ObservationIgnored var selectedModuleLoadTask: Task<Void, Never>?
    @ObservationIgnored var selectedModuleLoadGeneration: UInt64 = 0
    @ObservationIgnored var downloadStationLoadOverride: (@Sendable () async throws -> DownloadStationSnapshot)?
    @ObservationIgnored var downloadStationControlOverride:
        (@Sendable (DownloadTaskControlRequest) async throws -> DownloadTaskControlOutcome)?
    @ObservationIgnored var downloadStationCreateOverride:
        (@Sendable (DownloadTaskCreateRequest) async throws -> DownloadTaskCreateOutcome)?
    @ObservationIgnored var downloadStationCreateFileOverride:
        (@Sendable (DownloadTaskFileCreateRequest) async throws -> DownloadTaskCreateOutcome)?
    @ObservationIgnored var downloadStationDeleteOverride:
        (@Sendable ([String], Bool) async throws -> MutationResult)?
    @ObservationIgnored var downloadControlTask: Task<Void, Never>?
    @ObservationIgnored var downloadControlGeneration: UInt64 = 0
    @ObservationIgnored var downloadCreateTask: Task<Void, Never>?
    @ObservationIgnored var downloadCreateGeneration: UInt64 = 0
    @ObservationIgnored var downloadDeleteTask: Task<Void, Never>?
    @ObservationIgnored var downloadDeleteGeneration: UInt64 = 0

    var isConnected = false
    var activeProfile: NasProfile? {
        didSet {
            filePreviewModel.activate(profileID: activeProfile?.id)
            if activeProfile?.id != oldValue?.id {
                fileShareLinkModel.deactivate()
                deactivateFileLocations()
                deactivateDownloads()
                photoLibraryModel.deactivate()
                chatModel.deactivate()
                nasHealthModel.deactivate()
                containerInventoryModel.deactivate()
                virtualMachineInventoryModel.deactivate()
            }
        }
    }
    var selectedTopLevel: MobileTopLevelDestination = .files
    var selectedModule: MobileModule = .files
    var navigationStates: [UUID: MobileProfileNavigationState] = [:]
    var isLoading = false
    var actionInProgress = false
    var message: String?

    var currentPath = ""
    var pathHistory: [String] = []
    var files: [FileItem] = []
    var downloadSnapshot: DownloadStationSnapshot?
    var downloadControlTaskID: String?
    var downloadControlAction: DownloadStationTaskAction?
    var downloadControlFeedback: MobileDownloadControlFeedback?
    var downloadCreateFeedback: MobileDownloadCreateFeedback?
    var downloadDeleteTaskID: String?
    var downloadDeleteFeedback: MobileDownloadDeleteFeedback?
    var conversations: [ChatConversation] = []
    var systemOverview: NasSystemOverview?
    var storageSnapshot: NasStorageSnapshot?
    var packages: [NasPackage] = []
    var accountsAndGroups: NasAccountDirectory?
    var logs: NasLogPage?
    var connections: NasConnectionPage?

    var capabilities: CapabilitySet?
    var session: AuthSession?
    var activeConnectionProfile: NasProfile?
    var fileRepository: DsmFileRepository?
    var photoRepository: FileStationPhotoRepository?
    var serviceRepository: DsmServiceManagementRepository?
    var chatRepository: DsmChatRepository?
    var nasRepository: DsmNasAdministrationRepository?

    init(
        defaults: UserDefaults = .standard,
        sessionStore: any SessionSecureStoring = KeychainSessionStore(),
        passwordStore: any PasswordSecureStoring = KeychainPasswordStore(),
        authRepository: (any AuthRepository)? = nil,
        quickConnectResolver: any QuickConnectResolving = DsmQuickConnectResolver(),
        mutationCoordinator: MobileMutationCoordinator = MobileMutationCoordinator()
    ) {
        self.defaults = defaults
        self.sessionStore = sessionStore
        self.passwordStore = passwordStore
        self.authRepository = authRepository ?? DsmAuthRepository(sessionStore: sessionStore)
        self.quickConnectResolver = quickConnectResolver
        self.mutationCoordinator = mutationCoordinator
        self.fileShareLinkModel = MobileFileShareLinkModel(
            mutationCoordinator: mutationCoordinator
        )
        self.settingsStore = MobileSettingsStore(defaults: defaults)
        let transferCoordinator = MobileTransferCoordinator(
            mutationCoordinator: mutationCoordinator
        )
        self.transferCoordinator = transferCoordinator
        self.documentTransferController = MobileDocumentTransferController(
            transferCoordinator: transferCoordinator
        )
        loadProfiles()
        if let profile = profiles.first(where: {
            $0.id.uuidString == defaults.string(forKey: lastProfileKey)
        }) ?? profiles.first {
            applyProfile(profile)
            Task { await loadSavedPassword(for: profile, attemptsAutoLogin: true) }
        }
    }
}
