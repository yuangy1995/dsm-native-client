import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

extension MobileAppModel {
    func selectTopLevel(_ destination: MobileTopLevelDestination) {
        selectedTopLevel = destination
        selectModule(preferredModule(for: destination))
    }

    func selectModule(_ module: MobileModule) {
        guard isModuleVisible(module) else { return }
        cancelSelectedModuleLoad()
        if selectedModule == .files, module != .files {
            fileShareLinkModel.deactivate()
            deactivateFileLocations()
            filePreviewModel.close()
        }
        if selectedModule == .photos, module != .photos {
            photoLibraryModel.deactivate()
            filePreviewModel.close()
        }
        if selectedModule == .chat, module != .chat {
            chatModel.deactivate()
        }
        if selectedModule == .downloads, module != .downloads {
            deactivateDownloads()
        }
        if selectedModule == .nasSettings, module != .nasSettings {
            nasHealthModel.deactivate()
        }
        if selectedModule == .containers, module != .containers {
            containerInventoryModel.deactivate()
        }
        if selectedModule == .virtualMachines, module != .virtualMachines {
            virtualMachineInventoryModel.deactivate()
        }
        selectedModule = module
        if !selectedTopLevel.childModules.contains(module),
           let destination = MobileTopLevelDestination.allCases.first(where: {
               $0.childModules.contains(module)
           }) {
            selectedTopLevel = destination
        }
        saveNavigationState()
        selectedModuleLoadTask = Task { [weak self] in
            await self?.loadSelectedModule()
        }
    }

    func saveNavigationState() {
        guard let profileID = activeProfile?.id else { return }
        navigationStates[profileID] = MobileProfileNavigationState(
            selectedTopLevel: selectedTopLevel,
            selectedModule: selectedModule
        )
    }

    func restoreNavigationState(for profileID: UUID) {
        let state = navigationStates[profileID] ?? .initial
        selectedTopLevel = state.selectedTopLevel
        selectedModule = isModuleVisible(state.selectedModule)
            && state.selectedTopLevel.childModules.contains(state.selectedModule)
            ? state.selectedModule
            : preferredModule(for: state.selectedTopLevel)
    }

    func visibleChildModules(for destination: MobileTopLevelDestination) -> [MobileModule] {
        destination.childModules.filter(isModuleVisible)
    }

    func optionalModulesAvailableForPreference() -> [MobileModule] {
        MobileModule.allCases.filter {
            $0.isOptionalPreference && $0.isAvailable(in: capabilities)
        }
    }

    func setModule(_ module: MobileModule, isVisible: Bool) {
        guard module.isOptionalPreference else { return }
        settingsStore.setVisible(isVisible, module: module)
        guard !isVisible, selectedModule == module else { return }
        selectModule(preferredModule(for: selectedTopLevel))
    }

    func refreshSettingsCacheSummary() async {
        settingsStore.setPhotoThumbnailCacheBytes(
            await photoLibraryModel.thumbnailCacheCost()
        )
    }

    func clearRegenerableCaches() async {
        guard settingsStore.beginClearingCache() else { return }
        await photoLibraryModel.clearThumbnailCache()
        let remainingBytes = await photoLibraryModel.thumbnailCacheCost()
        settingsStore.finishClearingCache(
            result: remainingBytes == 0 ? .success : .failure,
            remainingBytes: remainingBytes
        )
    }

    private func preferredModule(for destination: MobileTopLevelDestination) -> MobileModule {
        let visible = visibleChildModules(for: destination)
        if visible.contains(destination.defaultModule) {
            return destination.defaultModule
        }
        return visible.first ?? .settings
    }

    func loadSelectedModule() async {
        guard isConnected else { return }
        let loadGeneration = selectedModuleLoadGeneration
        let loadModule = selectedModule
        let loadProfileID = activeProfile?.id
        isLoading = true
        message = nil
        do {
            switch loadModule {
            case .files:
                try await loadFiles()
            case .photos:
                break
            case .chat:
                guard let profileID = activeProfile?.id else { break }
                let restoresCachedProfile = chatModel.profiles[profileID] != nil
                await chatModel.activate(profileID: profileID, repository: chatRepository)
                if restoresCachedProfile {
                    await chatModel.reloadConversations()
                }
            case .downloads:
                let snapshot: DownloadStationSnapshot?
                if let downloadStationLoadOverride {
                    snapshot = try await downloadStationLoadOverride()
                } else {
                    snapshot = try await serviceRepository?.loadDownloadStation()
                }
                try Task.checkCancellation()
                guard isCurrentModuleLoad(
                    generation: loadGeneration,
                    module: loadModule,
                    profileID: loadProfileID
                ) else { return }
                downloadSnapshot = snapshot
                syncDownloadSnapshotToActivity()
            case .containers:
                guard let profileID = activeProfile?.id,
                      let serviceRepository else { break }
                await containerInventoryModel.activate(
                    profileID: profileID,
                    repository: MobileReadOnlyContainerRepository(
                        profileID: profileID,
                        base: serviceRepository
                    )
                )
            case .virtualMachines:
                guard let profileID = activeProfile?.id,
                      let serviceRepository else { break }
                await virtualMachineInventoryModel.activate(
                    profileID: profileID,
                    repository: MobileReadOnlyVirtualMachineRepository(
                        profileID: profileID,
                        base: serviceRepository
                    )
                )
            case .nasSettings:
                await loadNasHealth()
            case .transfers, .settings:
                break
            }
            guard isCurrentModuleLoad(
                generation: loadGeneration,
                module: loadModule,
                profileID: loadProfileID
            ) else { return }
            isLoading = false
        } catch {
            guard isCurrentModuleLoad(
                generation: loadGeneration,
                module: loadModule,
                profileID: loadProfileID
            ) else { return }
            message = userMessage(error)
            isLoading = false
        }
    }

    func cancelSelectedModuleLoad() {
        selectedModuleLoadGeneration &+= 1
        selectedModuleLoadTask?.cancel()
        selectedModuleLoadTask = nil
        isLoading = false
    }

    private func isModuleVisible(_ module: MobileModule) -> Bool {
        settingsStore.isVisible(module) && module.isAvailable(in: capabilities)
    }

    private func isCurrentModuleLoad(
        generation: UInt64,
        module: MobileModule,
        profileID: UUID?
    ) -> Bool {
        generation == selectedModuleLoadGeneration
            && isConnected
            && activeProfile?.id == profileID
            && selectedModule == module
            && isModuleVisible(module)
    }

    func syncDownloadSnapshotToActivity() {
        guard let profileID = activeProfile?.id,
              let downloadSnapshot else { return }
        let snapshot = downloadSnapshot
        Task { [transferCoordinator] in
            await transferCoordinator.syncDownloadStationTasks(
                profileID: profileID,
                snapshot: snapshot
            )
        }
    }


    func configureWorkspace(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession
    ) throws {
        let fileRepository = try DsmFileRepository(
            profile: profile,
            capabilities: capabilities,
            session: session
        )
        self.fileRepository = fileRepository
        photoRepository = FileStationPhotoRepository(files: fileRepository)
        serviceRepository = try DsmServiceManagementRepository(
            profile: profile,
            capabilities: capabilities,
            session: session
        )
        chatRepository = try DsmChatRepository(
            profile: profile,
            capabilities: capabilities,
            session: session
        )
        nasRepository = try DsmNasAdministrationRepository(
            profile: profile,
            capabilities: capabilities,
            session: session
        )
    }

    func perform(_ success: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !actionInProgress else { return }
        actionInProgress = true
        message = nil
        Task {
            do {
                try await operation()
                message = success
            } catch {
                message = userMessage(error)
            }
            actionInProgress = false
        }
    }
}
