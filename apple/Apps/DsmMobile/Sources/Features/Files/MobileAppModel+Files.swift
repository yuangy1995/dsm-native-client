import DsmCore
import DsmNetwork
import Foundation
import Observation
import DsmLocalization

extension MobileAppModel {
    func deactivateFileLocations() {
        fileBrowserModel.locations.deactivate()
    }

    func purgeFileLocations(profileID: UUID) {
        fileBrowserModel.locations.purge(profileID: profileID)
    }

    func openDirectory(_ item: FileItem) {
        guard let fileRepository else { return }
        Task { await fileBrowserModel.openDirectory(item, repository: fileRepository) }
    }

    func goBackDirectory() {
        guard let fileRepository else { return }
        Task { await fileBrowserModel.goBack(repository: fileRepository) }
    }

    func goUpDirectory() {
        guard let fileRepository else { return }
        Task { await fileBrowserModel.goUp(repository: fileRepository) }
    }

    func searchFiles(_ query: String) {
        guard let fileRepository else { return }
        fileBrowserModel.setQuery(query)
        Task {
            await fileBrowserModel.submitSearch(repository: fileRepository)
        }
    }

    func loadFiles() async throws {
        guard let fileRepository else { return }
        await fileBrowserModel.activate(profileID: activeProfile?.id, repository: fileRepository)
        fileBrowserModel.locations.activate(profileID: activeProfile?.id, repository: fileRepository)
        await fileBrowserModel.locations.loadIfNeeded(repository: fileRepository)
        await fileBrowserModel.refresh(repository: fileRepository)
        // Photos 仍读取这一兼容快照；文件页本身只以浏览模型为事实来源。
        files = fileBrowserModel.state.page.items
    }
}
