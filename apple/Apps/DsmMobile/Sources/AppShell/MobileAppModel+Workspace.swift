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
            chatModel.leaveChatPage()
        }
        if selectedModule == .downloads, module != .downloads {
            downloads.cancelLoad()
        }
        if selectedModule == .nasSettings, module != .nasSettings {
            nasHealthModel.deactivate()
        }
        if selectedModule == .containers, module != .containers {
            containerInventoryModel.deactivate()
            containerControls.deactivate(); containerImagePulls.deactivate(); containerImageDeletions.deactivate(); containerNetworks.deactivate()
        }
        if selectedModule == .virtualMachines, module != .virtualMachines {
            virtualMachineInventoryModel.deactivate(); virtualMachineControls.deactivate()
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
        if module == .chat, !isVisible { chatModel.deactivate() }
        guard !isVisible, selectedModule == module else { return }
        selectModule(.settings)
    }

    /// 前台聊天属于当前工作区，切换页面不会重建发送队列或实时订阅。
    func updateChatForeground(_ isActive: Bool) async {
        guard isConnected, isModuleVisible(.chat), let profile = activeProfile, chatRepository != nil else {
            chatModel.deactivate()
            return
        }
        if isActive { await prepareChatContext() }
        guard activeProfile?.id == profile.id, chatModel.activeProfileID == profile.id else { return }
        await chatModel.setForegroundRealtimeActive(isActive)
    }

    private func prepareChatContext() async {
        guard isConnected, isModuleVisible(.chat), let profile = activeProfile,
              chatModel.activeProfileID != profile.id else { return }
        await chatModel.activate(profileID: profile.id, repository: chatRepository,
            context: MobileWorkspaceIdentity(profile).storageIdentifier)
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
                await prepareChatContext()
            case .downloads:
                await downloads.load()
            case .containers:
                guard let profile = activeProfile,
                      let serviceRepository else { break }
                let profileID = profile.id, identity = MobileWorkspaceIdentity(profile), reader = moduleAccessReader
                let authorize: @MainActor @Sendable () async throws -> Bool = { [weak self] in
                    guard let self, self.activeProfile.map(MobileWorkspaceIdentity.init) == identity,
                          self.isConnected, self.isModuleVisible(.containers), let reader else { throw CancellationError() }
                    let privileges = try await reader.readPrivileges()
                    guard self.activeProfile.map(MobileWorkspaceIdentity.init) == identity,
                          self.isConnected, self.isModuleVisible(.containers), !Task.isCancelled else { throw CancellationError() }
                    return privileges.applications[.containers] == true
                }
                containerNetworks.configure(profile: profile, repository: serviceRepository, authorize: authorize)
                containerControls.configure(profile: profile, repository: serviceRepository, authorize: authorize)
                containerImagePulls.configure(profile: profile, repository: serviceRepository,
                    deletionRecovery: containerImageDeletions.recovery, authorize: authorize)
                containerImageDeletions.configure(profile: profile, repository: serviceRepository,
                    pullRecovery: containerImagePulls.recovery, authorize: authorize)
                await containerInventoryModel.activate(
                    profileID: profileID,
                    repository: MobileReadOnlyContainerRepository(
                        profileID: profileID,
                        base: serviceRepository
                    )
                )
                await containerControls.refresh()
            case .virtualMachines:
                guard let profile = activeProfile, let serviceRepository else { break }
                let profileID = profile.id, identity = MobileWorkspaceIdentity(profile), reader = moduleAccessReader
                let authorize: @MainActor @Sendable () async throws -> Bool = { [weak self] in
                    guard let self, self.activeProfile.map(MobileWorkspaceIdentity.init) == identity,
                          self.isConnected, self.isModuleVisible(.virtualMachines), let reader else { throw CancellationError() }
                    let privileges = try await reader.readPrivileges()
                    guard self.activeProfile.map(MobileWorkspaceIdentity.init) == identity,
                          self.isConnected, self.isModuleVisible(.virtualMachines), !Task.isCancelled else { throw CancellationError() }
                    return privileges.applications[.virtualMachines] == true
                }
                virtualMachineControls.configure(profile: profile, repository: serviceRepository, authorize: authorize)
                await virtualMachineInventoryModel.activate(profileID: profileID,
                    repository: MobileReadOnlyVirtualMachineRepository(profileID: profileID, base: serviceRepository))
                await virtualMachineControls.refresh()
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
