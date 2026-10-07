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
    let extensionAccess: MobileExtensionAccess?
    var extensionAccessError: String?
    let passwordStore: any PasswordSecureStoring
    let authRepository: any AuthRepository
    let quickConnectResolver: any QuickConnectResolving
    let mutationCoordinator: MobileMutationCoordinator
    let transferCoordinator: MobileTransferCoordinator
    let office: MobileOfficeModel
    let crossNAS: MobileCrossNASQueue
    let fileUploadQueue: MobileFileUploadQueue
    let sharedUploads: MobileShareTransferRecovery
    let fileArchiveQueue: MobileFileArchiveQueue
    let fileActivityModel: MobileFileActivityModel
    let documentTransferController: MobileDocumentTransferController
    let settingsStore: MobileSettingsStore
    let fileBrowserModel: MobileFileBrowserModel
    let filePreviewModel: MobileFilePreviewModel
    let fileShareLinkModel: MobileFileShareLinkModel
    let filePermissionModel: MobileFilePermissionModel
    let favorites: MobileFavoritesModel
    let fileSettings: MobileFileSettingsModel
    let remoteLocations: MobileRemoteLocationsModel
    let synologyPhotos: MobileSynologyPhotosSession
    let chatModel: MobileChatModel
    let nasHealthModel = MobileNasHealthModel()
    let nasDetailsModel = MobileNasDetailsModel()
    let nasStorageModel: MobileNasStorageModel
    let ddnsModel: MobileDDNSModel
    let serviceSettingsModel: MobileServiceSettingsModel
    let scheduledTasksModel: MobileScheduledTasksModel
    let systemActionsModel: MobileSystemActionsModel
    let packageCenterModel: MobilePackageCenterModel
    let directoryModel: MobileDirectoryModel
    let regionModel: MobileRegionModel
    let containerInventoryModel = MobileContainerInventoryModel()
    let containerControls: MobileContainerControlModel
    let containerImagePulls: MobileContainerImagePullModel
    let containerImageDeletions: MobileContainerImageDeletionModel
    let containerNetworks: MobileContainerNetworkModel
    let virtualMachineInventoryModel = MobileVirtualMachineInventoryModel()
    let virtualMachineControls: MobileVirtualMachineControlModel
    let downloads: MobileDownloadsModel

#if DEBUG
    var officeTransportFixture: MobileOfficeUITransport?
    var crossNASTargetFixture: MobileCrossNASEndpoint?
#endif
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

    @ObservationIgnored var moduleAccessReader: MobileModuleAccessReader?
    @ObservationIgnored var moduleAccessTask: Task<Void, Never>?
    @ObservationIgnored var moduleAccessGeneration: UInt64 = 0
    var availableOptionalModules: Set<MobileModule> = []
    var isLoadingModuleAccess = false
    var moduleAccessLookupFailed = false

    var isConnected = false
    var activeProfile: NasProfile? {
        didSet {
            filePreviewModel.activate(profileID: activeProfile?.id)
            crossNAS.configure(source: activeProfile.flatMap { profile in
                fileRepository.map { MobileCrossNASEndpoint(profile: profile, repository: $0) }
            })
            office.configure(profile: activeProfile, repository: fileRepository)
            fileUploadQueue.configure(profile: activeProfile, repository: fileRepository)
            sharedUploads.configure(profile: activeProfile, repository: fileRepository)
            fileArchiveQueue.configure(profile: activeProfile, repository: fileRepository)
            filePermissionModel.configure(profile: activeProfile, repository: fileRepository)
            remoteLocations.configure(profile: activeProfile, repository: fileRepository)
            favorites.configure(profile: activeProfile, repository: fileRepository)
            fileSettings.configure(profile: activeProfile, repository: fileRepository)
            downloads.configure(profile: activeProfile, repository: serviceRepository)
            if activeProfile.map(MobileWorkspaceIdentity.init) != oldValue.map(MobileWorkspaceIdentity.init) {
                resetModuleAccess()
                fileActivityModel.reset()
                fileShareLinkModel.deactivate()
                deactivateFileLocations()
                synologyPhotos.deactivate()
                chatModel.deactivate()
                nasHealthModel.deactivate()
                nasDetailsModel.deactivate()
                nasStorageModel.deactivate()
                ddnsModel.deactivate()
                regionModel.deactivate()
                serviceSettingsModel.deactivate()
                scheduledTasksModel.deactivate()
                systemActionsModel.deactivate()
                packageCenterModel.deactivate()
                containerInventoryModel.deactivate()
                containerControls.deactivate(); containerImagePulls.deactivate(); containerImageDeletions.deactivate(); containerNetworks.deactivate()
                virtualMachineInventoryModel.deactivate(); virtualMachineControls.deactivate()
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
            crossNAS.configure(source: activeProfile.flatMap { profile in
                fileRepository.map { MobileCrossNASEndpoint(profile: profile, repository: $0) }
            })
            office.configure(profile: activeProfile, repository: fileRepository)
            fileUploadQueue.configure(profile: activeProfile, repository: fileRepository)
            sharedUploads.configure(profile: activeProfile, repository: fileRepository)
            fileArchiveQueue.configure(profile: activeProfile, repository: fileRepository)
            filePermissionModel.configure(profile: activeProfile, repository: fileRepository)
            remoteLocations.configure(profile: activeProfile, repository: fileRepository)
            favorites.configure(profile: activeProfile, repository: fileRepository)
            fileSettings.configure(profile: activeProfile, repository: fileRepository)
        }
    }
    var serviceRepository: DsmServiceManagementRepository? {
        didSet {
            downloads.configure(profile: activeProfile, repository: serviceRepository)
            if oldValue.map(ObjectIdentifier.init) != serviceRepository.map(ObjectIdentifier.init) { containerControls.deactivate(); containerImagePulls.deactivate(); containerImageDeletions.deactivate(); containerNetworks.deactivate(); virtualMachineControls.deactivate() }
        }
    }
    var chatRepository: (any ChatRepository)?
    var nasRepository: DsmNasAdministrationRepository?

    init(
        defaults: UserDefaults = .standard,
        sessionStore: any SessionSecureStoring = MobileSecureStoreDefaults.sessionStore(),
        passwordStore: any PasswordSecureStoring = MobileSecureStoreDefaults.passwordStore(),
        authRepository: (any AuthRepository)? = nil,
        quickConnectResolver: any QuickConnectResolving = DsmQuickConnectResolver(),
        mutationCoordinator: MobileMutationCoordinator = MobileMutationCoordinator(),
        previewModel: MobileFilePreviewModel = MobileFilePreviewModel(),
        transferRecoveryStore: MobileTransferRecoveryStore? = nil,
        transferBackgroundExecution: MobileTransferBackgroundExecution? = nil,
        extensionAccess: MobileExtensionAccess? = nil,
        chatAudioDriver: (any MobileChatAudioDriving)? = nil,
        chatNotificationDriver: (any MobileChatNotificationDriving)? = nil,
        chatPollingIntervalNanoseconds: UInt64 = 30_000_000_000
    ) {
        self.filePreviewModel = previewModel
        self.synologyPhotos = MobileSynologyPhotosSession(backgroundExecution: transferBackgroundExecution)
        self.chatModel = MobileChatModel(realtimePollingIntervalNanoseconds: chatPollingIntervalNanoseconds,
            interactionRecoveryRoot: transferRecoveryStore?.rootURL.appendingPathComponent("Chat", isDirectory: true), audioDriver: chatAudioDriver,
            notifications: MobileChatNotifications(defaults: defaults, driver: chatNotificationDriver ?? MobileSystemChatNotificationDriver()))
        self.defaults = defaults
        self.sessionStore = sessionStore
        self.extensionAccess = extensionAccess
        self.sharedUploads = MobileShareTransferRecovery(store: extensionAccess.map {
            MobileShareTransferStore(rootURL: $0.accounts.rootURL.appendingPathComponent("ShareTransfers", isDirectory: true))
        }, backgroundExecution: transferBackgroundExecution)
        self.passwordStore = passwordStore
        self.authRepository = authRepository ?? DsmAuthRepository(sessionStore: sessionStore)
        self.quickConnectResolver = quickConnectResolver
        self.mutationCoordinator = mutationCoordinator
        self.fileBrowserModel = MobileFileBrowserModel(copyMove: MobileFileCopyMoveModel(
            blocker: MobileFileCopyMoveReviewBlocker(rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("CopyMove", isDirectory: true))
        ), recycleAction: MobileFileRecycleActionModel(
            blocker: MobileFileRecycleActionReviewBlocker(rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("Recycle", isDirectory: true))
        ))
        self.fileShareLinkModel = MobileFileShareLinkModel(
            mutationCoordinator: mutationCoordinator,
            rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("Sharing", isDirectory: true)
        )
        self.filePermissionModel = MobileFilePermissionModel(
            rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("Permissions", isDirectory: true)
        )
        self.remoteLocations = MobileRemoteLocationsModel(
            rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("RemoteLocations", isDirectory: true)
        )
        self.favorites = MobileFavoritesModel(
            rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("Favorites", isDirectory: true)
        )
        self.fileSettings = MobileFileSettingsModel(
            rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("FileSettings", isDirectory: true)
        )
        self.settingsStore = MobileSettingsStore(defaults: defaults)
        let transferCoordinator = MobileTransferCoordinator(
            mutationCoordinator: mutationCoordinator, recoveryStore: transferRecoveryStore,
            backgroundExecution: transferBackgroundExecution
        )
        self.transferCoordinator = transferCoordinator
        self.fileActivityModel = MobileFileActivityModel(coordinator: transferCoordinator, rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("NasControls", isDirectory: true))
        self.office = MobileOfficeModel(rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("Office", isDirectory: true),
            backgroundExecution: transferBackgroundExecution)
        self.crossNAS = MobileCrossNASQueue(rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("CrossNAS", isDirectory: true),
            backgroundExecution: transferBackgroundExecution)
        self.fileUploadQueue = MobileFileUploadQueue(rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("UploadBatches", isDirectory: true),
            backgroundExecution: transferBackgroundExecution)
        self.fileArchiveQueue = MobileFileArchiveQueue(rootURL: transferRecoveryStore?.rootURL.appendingPathComponent("Archives", isDirectory: true))
        self.downloads = MobileDownloadsModel(transferCoordinator: transferCoordinator,
            controlRoot: transferRecoveryStore?.rootURL.appendingPathComponent("Downloads", isDirectory: true))
        self.nasStorageModel = MobileNasStorageModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("NAS", isDirectory: true))
        self.ddnsModel = MobileDDNSModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("NAS", isDirectory: true))
        self.serviceSettingsModel = MobileServiceSettingsModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("NAS", isDirectory: true))
        self.scheduledTasksModel = MobileScheduledTasksModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("NAS", isDirectory: true))
        self.systemActionsModel = MobileSystemActionsModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("NAS", isDirectory: true))
        self.packageCenterModel = MobilePackageCenterModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("NAS", isDirectory: true))
        self.containerControls = MobileContainerControlModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("Containers", isDirectory: true))
        self.virtualMachineControls = MobileVirtualMachineControlModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("VirtualMachines", isDirectory: true))
        self.containerImagePulls = MobileContainerImagePullModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("Containers", isDirectory: true))
        self.containerImageDeletions = MobileContainerImageDeletionModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("Containers", isDirectory: true))
        self.containerNetworks = MobileContainerNetworkModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("Containers", isDirectory: true))
        self.directoryModel = MobileDirectoryModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("NAS", isDirectory: true))
        self.regionModel = MobileRegionModel(root: transferRecoveryStore?.rootURL.appendingPathComponent("NAS", isDirectory: true))
        self.documentTransferController = MobileDocumentTransferController(
            transferCoordinator: transferCoordinator, recoveryStore: transferRecoveryStore
        )
        office.onChanged = { [weak self] context in
            guard let self, let profile = activeProfile, MobileWorkspaceIdentity(profile).storageIdentifier == context,
                  let repository = fileRepository else { return }
            await fileBrowserModel.refresh(repository: repository)
        }
        crossNAS.onSourceChanged = { [weak self] context in
            guard let self, let profile = activeProfile,
                  MobileWorkspaceIdentity(profile).storageIdentifier == context,
                  let repository = fileRepository else { return }
            await fileBrowserModel.refresh(repository: repository)
        }
        fileArchiveQueue.onDestinationChanged = { [weak self] context, destination in
            guard let self, let profile = activeProfile,
                  MobileWorkspaceIdentity(profile).storageIdentifier == context,
                  let repository = fileRepository else { return }
            await fileBrowserModel.refreshAfterArchiveChange(destination: destination, repository: repository)
        }
        filePermissionModel.onPermissionsChanged = { [weak self] context in
            guard let self, let profile = activeProfile,
                  MobileWorkspaceIdentity(profile).storageIdentifier == context,
                  let repository = fileRepository else { return }
            await fileBrowserModel.refreshAfterPermissionChange(repository: repository)
        }
        remoteLocations.onLocationsChanged = { [weak self] context in
            guard let self, let profile = activeProfile,
                  MobileWorkspaceIdentity(profile).storageIdentifier == context, let repository = fileRepository else { return }
            await fileBrowserModel.refreshAfterRemoteLocationChange(repository: repository)
        }
        fileSettings.onChanged = { [weak self] context in
            guard let self, let profile = activeProfile,
                  MobileWorkspaceIdentity(profile).storageIdentifier == context, let repository = fileRepository else { return }
            await fileBrowserModel.refreshAfterPermissionChange(repository: repository)
        }
        favorites.onChanged = { [weak self] context in
            guard let self, let profile = activeProfile,
                  MobileWorkspaceIdentity(profile).storageIdentifier == context, let repository = fileRepository else { return }
            await fileBrowserModel.locations.refresh(repository: repository)
        }
        loadProfiles()
        if let extensionAccess {
            do { try extensionAccess.accounts.reconcileProfiles(profiles) }
            catch { extensionAccessError = L10n.string("mobile.extensions.unavailable") }
        }
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
