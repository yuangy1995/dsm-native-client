import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

extension MobileAppModel {
    func loadNasHealth() async {
        guard let profileID = activeProfile?.id, let nasRepository else {
            await nasHealthModel.activate(profileID: nil, repository: nil)
            return
        }
        await nasHealthModel.activate(
            profileID: profileID,
            repository: MobileReadOnlyNasHealthRepository(
                profileID: profileID,
                base: nasRepository
            )
        )
    }
}
