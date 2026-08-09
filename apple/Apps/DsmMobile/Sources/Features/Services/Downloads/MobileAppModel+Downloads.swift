import DsmCore
import Foundation

extension MobileAppModel {
    var downloadPageState: MobilePageState {
        if isLoading, downloadSnapshot == nil {
            return .loading
        }
        guard let downloadSnapshot else {
            return message == nil ? .loading : .error
        }
        return downloadSnapshot.tasks.isEmpty ? .empty : .content
    }

    /// Download Station 在移动端当前只刷新服务器状态，不提交任务变更。
    func reloadDownloads() {
        selectModule(.downloads)
    }
}
