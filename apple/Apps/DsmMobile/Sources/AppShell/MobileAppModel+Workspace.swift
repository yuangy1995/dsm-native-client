import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

extension MobileAppModel {
    func selectTopLevel(_ destination: MobileTopLevelDestination) {
        guard visibleTopLevelDestinations.contains(destination) else { return }
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
            synologyPhotos.deactivate()
            filePreviewModel.close()
        }
        if selectedModule == .chat, module != .chat {
            chatModel.deactivate()
        }
        if selectedModule == .downloads, module != .downloads {
            downloads.cancelLoad()
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
        let canRestore = isModuleVisible(state.selectedModule)
            && state.selectedTopLevel.childModules.contains(state.selectedModule)
        selectedTopLevel = canRestore ? state.selectedTopLevel : .files
        selectedModule = canRestore ? state.selectedModule : .files
    }

    func visibleChildModules(for destination: MobileTopLevelDestination) -> [MobileModule] {
        destination.childModules.filter(isModuleVisible)
    }

    func optionalModulesAvailableForPreference() -> [MobileModule] {
        MobileModule.allCases.filter {
            $0.isOptionalPreference && availableOptionalModules.contains($0) && $0.isAvailable(in: capabilities)
        }
    }

    func setModule(_ module: MobileModule, isVisible: Bool) {
        guard module.isOptionalPreference,
              !isVisible || optionalModulesAvailableForPreference().contains(module) else { return }
        settingsStore.setVisible(isVisible, module: module)
        guard !isVisible, selectedModule == module else { return }
        selectModule(.settings)
    }

    func refreshSettingsCacheSummary() async {
        let photosBytes = await synologyPhotos.thumbnails.cachedCost()
        settingsStore.setPhotoThumbnailCacheBytes(photosBytes)
    }

    func clearRegenerableCaches() async {
        guard settingsStore.beginClearingCache() else { return }
        await synologyPhotos.thumbnails.removeAll()
        let remainingBytes = await synologyPhotos.thumbnails.cachedCost()
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
        guard isConnected, isModuleVisible(selectedModule) else { return }
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
                await downloads.load()
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

    var visibleTopLevelDestinations: [MobileTopLevelDestination] {
        // 设置固定排在末尾；较多模块由系统标签栏提供原生“更多”入口。
        MobileTopLevelDestination.allCases.filter { isModuleVisible($0.defaultModule) }
    }

    func isModuleVisible(_ module: MobileModule) -> Bool {
        settingsStore.isVisible(module) && module.isAvailable(in: capabilities)
            && (!module.isOptionalPreference || availableOptionalModules.contains(module))
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
