import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

extension MobileAppModel {
    func loadNasHealth() async {
        guard let profile = activeProfile, let nasRepository else {
            nasDetailsModel.deactivate()
            nasStorageModel.deactivate()
            await nasHealthModel.activate(profileID: nil, repository: nil)
            return
        }
        let profileID = profile.id, expectedIdentity = MobileWorkspaceIdentity(profile)
        let accessReader = moduleAccessReader
        nasStorageModel.configure(profile: profile, repository: nasRepository, fileRepository: fileRepository) { [weak self] in
            guard let self, self.activeProfile.map(MobileWorkspaceIdentity.init) == expectedIdentity,
                  let accessReader else { throw CancellationError() }
            let privileges = try await accessReader.readPrivileges()
            guard self.activeProfile.map(MobileWorkspaceIdentity.init) == expectedIdentity, !Task.isCancelled else { throw CancellationError() }
            return privileges.isAdministrator && privileges.applications[.nasSettings] != false
        }
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
