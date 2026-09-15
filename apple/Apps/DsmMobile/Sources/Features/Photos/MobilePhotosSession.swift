import DsmCore
import DsmNetwork
import Foundation

extension MobileAppModel {
    /// 连接切换先撤销旧状态与下载，缓存不跨会话复用；不用旧 File Station 图库作降级。
    func installSynologyPhotos(_ repository: SynologyPhotosRepository, profileID: UUID) {
        deactivateSynologyPhotos()
        synologyPhotosRepository = repository
        synologyPhotosProfileID = profileID
        synologyPhotosModel = SynologyPhotosModel(repository: repository)
        synologyPhotosCache = MobilePhotoThumbnailStore(totalCostLimit: 24 * 1_024 * 1_024, concurrencyLimit: 4)
    }

    func deactivateSynologyPhotos() {
        synologyPhotosModel.setModuleEnabled(false)
        synologyPhotosExporter.cancel()
        let cache = synologyPhotosCache
        Task { await cache.removeAll() }
    }
}
