import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

extension MobileAppModel {
    var isRefreshingNasAdministration: Bool {
        nasHealthModel.state.isRefreshing || nasDetailsModel.state.isRefreshing || serviceSettingsModel.isRefreshing
            || nasStorageModel.storage.isRefreshing || nasStorageModel.storage.phase == .loading
            || ddnsModel.directory.isRefreshing || ddnsModel.directory.phase == .loading
            || directoryModel.directory.isRefreshing || directoryModel.directory.phase == .loading
            || regionModel.settings.isRefreshing || regionModel.settings.phase == .loading
    }

    /// 操作栏刷新所有已打开的 NAS 页面，完整管理页不应只刷新总览。
    func refreshNasAdministration() async {
        await nasHealthModel.refresh()
        await nasDetailsModel.refreshLoadedSections()
        if nasStorageModel.storage.phase != .idle { await nasStorageModel.refresh() }
        if ddnsModel.directory.phase != .idle { await ddnsModel.refresh() }
        if directoryModel.directory.phase != .idle { await directoryModel.refresh() }
        if regionModel.settings.phase != .idle { await regionModel.refresh() }
        await serviceSettingsModel.refreshLoaded()
    }

    func loadNasHealth() async {
        guard let profile = activeProfile, let nasRepository else {
            nasDetailsModel.deactivate()
            nasStorageModel.deactivate()
            ddnsModel.deactivate()
            regionModel.deactivate()
            directoryModel.deactivate()
            serviceSettingsModel.deactivate()
            await nasHealthModel.activate(profileID: nil, repository: nil)
            return
        }
        let profileID = profile.id, expectedIdentity = MobileWorkspaceIdentity(profile)
        let accessReader = moduleAccessReader
        let authorize: @MainActor @Sendable () async throws -> Bool = { [weak self] in
            guard let self, self.activeProfile.map(MobileWorkspaceIdentity.init) == expectedIdentity,
                  let accessReader else { throw CancellationError() }
            let privileges = try await accessReader.readPrivileges()
            guard self.activeProfile.map(MobileWorkspaceIdentity.init) == expectedIdentity, !Task.isCancelled else { throw CancellationError() }
            return privileges.isAdministrator && privileges.applications[.nasSettings] != false
        }
        nasStorageModel.configure(profile: profile, repository: nasRepository, fileRepository: fileRepository, authorize: authorize)
        ddnsModel.configure(profile: profile, repository: nasRepository, authorize: authorize)
        directoryModel.configure(profile: profile, repository: nasRepository, authorize: authorize)
        regionModel.configure(profile: profile, repository: nasRepository, authorize: authorize)
        serviceSettingsModel.configure(profile: profile, repository: nasRepository, authorize: authorize)
        nasDetailsModel.activate(
            profileID: profileID,
            repository: MobileReadOnlyNasDetailsRepository(
                profileID: profileID,
                base: nasRepository,
                fileRepository: fileRepository
            )
        )
        await nasHealthModel.activate(
            profileID: profileID,
            repository: MobileReadOnlyNasHealthRepository(
                profileID: profileID,
                base: nasRepository
            )
        )
    }
}
