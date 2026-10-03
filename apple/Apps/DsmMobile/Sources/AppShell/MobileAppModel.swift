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
    let fileUploadQueue: MobileFileUploadQueue
    let fileArchiveQueue: MobileFileArchiveQueue
    let fileActivityModel: MobileFileActivityModel
    let documentTransferController: MobileDocumentTransferController
    let settingsStore: MobileSettingsStore
    let fileBrowserModel = MobileFileBrowserModel()
    let filePreviewModel = MobileFilePreviewModel()
    let fileShareLinkModel: MobileFileShareLinkModel
    let photoLibraryModel = MobilePhotoLibraryModel()
    let synologyPhotos = MobileSynologyPhotosSession()
    let chatModel = MobileChatModel()
    let nasHealthModel = MobileNasHealthModel()
    let nasDetailsModel = MobileNasDetailsModel()
    let containerInventoryModel = MobileContainerInventoryModel()
    let virtualMachineInventoryModel = MobileVirtualMachineInventoryModel()
    let downloads: MobileDownloadsModel

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

    var isConnected = false
    var activeProfile: NasProfile? {
        didSet {
            filePreviewModel.activate(profileID: activeProfile?.id)
            fileUploadQueue.configure(profile: activeProfile, repository: fileRepository)
            fileArchiveQueue.configure(profile: activeProfile, repository: fileRepository)
            downloads.configure(profile: activeProfile, repository: serviceRepository)
            if activeProfile.map(MobileWorkspaceIdentity.init) != oldValue.map(MobileWorkspaceIdentity.init) {
                fileActivityModel.reset()
                fileShareLinkModel.deactivate()
                deactivateFileLocations()
                photoLibraryModel.deactivate()
                synologyPhotos.deactivate()
                chatModel.deactivate()
                nasHealthModel.deactivate()
                nasDetailsModel.deactivate()
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

    var capabilities: CapabilitySet?
    var session: AuthSession?
    var activeConnectionProfile: NasProfile?
    var fileRepository: DsmFileRepository? {
        didSet {
            fileActivityModel.reset()
            fileUploadQueue.configure(profile: activeProfile, repository: fileRepository)
            fileArchiveQueue.configure(profile: activeProfile, repository: fileRepository)
        }
    }
    var photoRepository: FileStationPhotoRepository?
    var serviceRepository: DsmServiceManagementRepository? {
        didSet { downloads.configure(profile: activeProfile, repository: serviceRepository) }
    }
    var chatRepository: DsmChatRepository?
    var nasRepository: DsmNasAdministrationRepository?

    init(
        defaults: UserDefaults = .standard,
        sessionStore: any SessionSecureStoring = MobileSecureStoreDefaults.sessionStore(),
        passwordStore: any PasswordSecureStoring = MobileSecureStoreDefaults.passwordStore(),
        authRepository: (any AuthRepository)? = nil,
        quickConnectResolver: any QuickConnectResolving = DsmQuickConnectResolver(),
        mutationCoordinator: MobileMutationCoordinator = MobileMutationCoordinator(),
        transferRecoveryStore: MobileTransferRecoveryStore? = nil
    ) {
        self.defaults = defaults
        self.sessionStore = sessionStore
        self.passwordStore = passwordStore
        self.authRepository = authRepository ?? DsmAuthRepository(sessionStore: sessionStore)
        self.quickConnectResolver = quickConnectResolver
        self.mutationCoordinator = mutationCoordinator
        self.fileShareLinkModel = MobileFileShareLinkModel(
            mutationCoordinator: mutationCoordinator,
            rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("Sharing", isDirectory: true)
        )
        self.settingsStore = MobileSettingsStore(defaults: defaults)
        let transferCoordinator = MobileTransferCoordinator(
            mutationCoordinator: mutationCoordinator, recoveryStore: transferRecoveryStore
        )
        self.transferCoordinator = transferCoordinator
        self.fileActivityModel = MobileFileActivityModel(coordinator: transferCoordinator, rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("NasControls", isDirectory: true))
        self.fileUploadQueue = MobileFileUploadQueue(rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("UploadBatches", isDirectory: true))
        self.fileArchiveQueue = MobileFileArchiveQueue(rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("Archives", isDirectory: true))
        self.downloads = MobileDownloadsModel(transferCoordinator: transferCoordinator)
        self.documentTransferController = MobileDocumentTransferController(
            transferCoordinator: transferCoordinator, recoveryStore: transferRecoveryStore
        )
        fileArchiveQueue.onDestinationChanged = { [weak self] context, destination in
            guard let self, let profile = activeProfile,
                  MobileWorkspaceIdentity(profile).storageIdentifier == context,
                  let repository = fileRepository else { return }
            await fileBrowserModel.refreshAfterArchiveChange(destination: destination, repository: repository)
        }
        loadProfiles()
        if let profile = profiles.first(where: {
            $0.id.uuidString == defaults.string(forKey: lastProfileKey)
        }) ?? profiles.first {
            applyProfile(profile)
            Task { await loadSavedPassword(for: profile, attemptsAutoLogin: true) }
        }
    }
}

enum MobileSecureStoreDefaults {
    static func sessionStore() -> any SessionSecureStoring {
#if targetEnvironment(simulator)
        LocalFileSecureStore()
#else
        KeychainSessionStore()
#endif
    }

    static func passwordStore() -> any PasswordSecureStoring {
#if targetEnvironment(simulator)
        LocalFileSecureStore()
#else
        KeychainPasswordStore()
#endif
    }
}
