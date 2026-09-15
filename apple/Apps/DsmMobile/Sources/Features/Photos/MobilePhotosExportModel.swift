import DsmCore
import DsmLocalization
import Foundation
import Observation

struct MobilePhotoExportFile: Identifiable {
    let id: UUID
    let url: URL
}

/// 只导出原图到本机临时目录；取消、换账号和关闭分享均清理，迟到结果不能再次弹出分享。
@MainActor
@Observable
final class MobilePhotosExportModel {
    private(set) var isPreparing = false
    private(set) var progress: Double?
    private(set) var presentation: MobilePhotoExportFile?
    var errorMessage: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ownedDirectory: URL?
    private let temporaryRoot: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot
    }

    func export(_ photo: SynologyPhoto, using repository: any SynologyPhotosServing) {
        guard !isPreparing, presentation == nil else { return }
        generation += 1
        let current = generation
        isPreparing = true
        progress = nil
        errorMessage = nil
        let identifier = UUID()
        let directory = temporaryRoot.appendingPathComponent("lanstash-photos-\(identifier.uuidString)", isDirectory: true)
        ownedDirectory = directory
        task = Task { [weak self] in
            guard let self else { return }
            var handedOff = false
            defer {
                if !handedOff { try? FileManager.default.removeItem(at: directory) }
                if current == self.generation { self.isPreparing = false; self.task = nil }
            }
            do {
                let filename = (photo.filename as NSString).lastPathComponent
                guard !filename.isEmpty, filename != ".", filename != ".." else { throw URLError(.badServerResponse) }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(filename, isDirectory: false)
                try await repository.downloadOriginal(photo, to: destination) { [weak self] completed, total in
                    Task { @MainActor in
                        guard let self, current == self.generation else { return }
                        self.progress = total.flatMap { $0 > 0 ? min(1, max(0, Double(completed) / Double($0))) : nil }
                    }
                }
                try Task.checkCancellation()
                guard current == self.generation else { return }
                self.presentation = MobilePhotoExportFile(id: identifier, url: destination)
                handedOff = true
            } catch is CancellationError {
                // 取消是用户结果，不显示网络失败，也不允许重试旧请求。
            } catch {
                guard current == self.generation else { return }
                self.errorMessage = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.media.saveFailed")
            }
        }
    }

    func finishPresentation() { cancel() }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isPreparing = false
        progress = nil
        presentation = nil
        errorMessage = nil
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
        ownedDirectory = nil
    }
}
