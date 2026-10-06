import Foundation
import DsmLocalization

/// 检查点只携带当前操作与套件目标，不包含下载地址、暂存路径、口令或会话。
public struct NasPackageInstallationCheckpoint: Equatable, Sendable {
    public enum Step: String, Codable, Sendable { case upload, download, install, cancelDownload, cleanup }
    public enum Stage: String, Codable, Sendable { case willSubmit, accepted, rejected, prepared, verified }
    public let id: UUID
    public let step: Step
    public let stage: Stage
    public let package: NasPackageCatalogEntry?
    public let completedCount: Int
    public let totalCount: Int
    /// 最终分步安装为同步命令；快速安装的接受回执仍需要读取任务和实际版本。
    public let isSynchronousInstallation: Bool

    public init(id: UUID, step: Step, stage: Stage, package: NasPackageCatalogEntry?,
                completedCount: Int, totalCount: Int, isSynchronousInstallation: Bool = false) {
        self.id = id; self.step = step; self.stage = stage; self.package = package
        self.completedCount = completedCount; self.totalCount = totalCount
        self.isSynchronousInstallation = isSynchronousInstallation
    }
}

public typealias NasPackageInstallationObserver = @Sendable (NasPackageInstallationCheckpoint) async throws -> Void

public extension NasSettingsRepository {
    func loadPackageCatalogForManagement() async throws -> NasPackageCatalog { throw packageInstallUnavailable() }
    func loadPackagesForManagement() async throws -> [NasPackage] { throw packageInstallUnavailable() }
    func preparePackageInstallationForManagement(catalogIDs: [String]) async throws -> NasPackageInstallPlan { throw packageInstallUnavailable() }
    private func packageInstallUnavailable() -> AppError {
        AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: L10n.string("package.center.unavailable"))
    }
    func startPackageInstallation(planID: UUID, volumes: [String: String], startAfterInstall: Bool,
        checkpoint: @escaping NasPackageInstallationObserver) async throws -> NasPackageInstallProgress {
        throw AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: L10n.string("package.center.unavailable"))
    }
    func uploadPackageForInstallation(fileURL: URL,
        checkpoint: @escaping NasPackageInstallationObserver) async throws -> NasPackageInstallProgress {
        throw AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: L10n.string("package.center.unavailable"))
    }
}
