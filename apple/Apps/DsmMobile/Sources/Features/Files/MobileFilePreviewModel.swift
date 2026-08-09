import DsmCore
import DsmNetwork
import Foundation
import Observation

protocol MobileFilePreviewServing: Sendable {
    var profileID: UUID { get }
    func getInfo(paths: [String]) async throws -> [FileItem]
    func mediaStreamSource(
        remotePath: String,
        fileExtension: String?,
        expectedContentLength: Int64?
    ) async throws -> MediaStreamSource
}

extension DsmFileRepository: MobileFilePreviewServing {}

@MainActor
@Observable
final class MobileFilePreviewModel {
    static let maximumTextBytes: Int64 = 1 * 1_024 * 1_024
    static let maximumQuickLookBytes: Int64 = 128 * 1_024 * 1_024

    private let fileManager: FileManager
    private let rootURL: URL
    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var ownedDirectoryURL: URL?
    @ObservationIgnored private let rangeReader: any MobileSecureRangeReading

    private(set) var state = MobileFilePreviewState()
    private(set) var mediaSource: MediaStreamSource?

    init(
        fileManager: FileManager = .default,
        rootURL: URL? = nil,
        rangeReader: any MobileSecureRangeReading = MobileSecureRangeReader()
    ) {
        self.fileManager = fileManager
        self.rangeReader = rangeReader
        self.rootURL = rootURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("LanStashPreviews", isDirectory: true)
    }

    isolated deinit {
        operationTask?.cancel()
        if let ownedDirectoryURL {
            // 只兜底删除当前实例明确持有的操作目录，不能枚举或清扫共享临时根。
            try? fileManager.removeItem(at: ownedDirectoryURL)
        }
    }

    func activate(profileID: UUID?) {
        guard state.profileID != profileID else { return }
        stopCurrentOperation()
        state = MobileFilePreviewState(profileID: profileID)
    }

    func open(_ item: FileItem, service: any MobileFilePreviewServing) async {
        guard service.profileID == state.profileID,
              item.profileID == state.profileID else { return }

        stopCurrentOperation()
        generation &+= 1
        let requestGeneration = generation
        let operationID = UUID()
        let previewKind = item.isDirectory ? PreviewKind.unsupported : PreviewKind.classify(item)
        state = MobileFilePreviewState(
            profileID: item.profileID,
            selectedItem: item,
            details: item,
            previewKind: previewKind,
            phase: .loadingDetails
        )

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runOpen(
                item: item,
                service: service,
                operationID: operationID,
                generation: requestGeneration
            )
        }
        operationTask = task
        await task.value
    }

    func retry(service: any MobileFilePreviewServing) async {
        guard let item = state.selectedItem else { return }
        await open(item, service: service)
    }

    func cancel() {
        guard state.phase == .loadingDetails || state.phase == .loadingPreview else { return }
        stopCurrentOperation()
        state.progress = nil
        state.artifactURL = nil
        mediaSource = nil
        state.phase = .cancelled
        state.previewFailure = .cancelled
    }

    func close() {
        let profileID = state.profileID
        stopCurrentOperation()
        state = MobileFilePreviewState(profileID: profileID)
    }

    private func runOpen(
        item: FileItem,
        service: any MobileFilePreviewServing,
        operationID: UUID,
        generation requestGeneration: Int
    ) async {
        var resolvedItem = item
        var hasRefreshedExactInfo = false
        do {
            let refreshed = try await service.getInfo(paths: [item.path])
            try Task.checkCancellation()
            if let exact = refreshed.first(where: {
                $0.profileID == item.profileID && $0.path == item.path
            }) {
                resolvedItem = exact
                hasRefreshedExactInfo = true
            }
            guard isCurrent(item: item, generation: requestGeneration) else { return }
            state.details = resolvedItem
            state.previewKind = resolvedItem.isDirectory
                ? .unsupported
                : PreviewKind.classify(resolvedItem)
            state.detailsFailure = nil
        } catch is CancellationError {
            guard isCurrent(item: item, generation: requestGeneration) else { return }
            // 服务主动取消详情刷新时仍可使用列表已有详情继续首版预览主流程。
            state.detailsFailure = .cancelled
        } catch {
            guard isCurrent(item: item, generation: requestGeneration) else { return }
            // 详情刷新失败时继续保留列表已有信息，预览主流程不依赖刷新成功。
            state.detailsFailure = Self.failureCategory(for: error)
        }

        guard isCurrent(item: item, generation: requestGeneration) else { return }
        let kind = state.previewKind
        guard !resolvedItem.isDirectory else {
            state.phase = .detailsOnly
            state.progress = nil
            return
        }

        if kind == .text {
            await prepareText(
                resolvedItem,
                verifiedSize: hasRefreshedExactInfo ? resolvedItem.sizeBytes : nil,
                service: service,
                originalItem: item,
                generation: requestGeneration
            )
            return
        }
        if kind == .video || kind == .audio {
            await prepareMedia(
                resolvedItem,
                verifiedSize: hasRefreshedExactInfo ? resolvedItem.sizeBytes : nil,
                service: service,
                originalItem: item,
                generation: requestGeneration
            )
            return
        }
        guard kind == .image || kind == .pdf else {
            state.phase = .detailsOnly
            state.progress = nil
            return
        }

        await prepareQuickLook(
            resolvedItem,
            verifiedSize: hasRefreshedExactInfo ? resolvedItem.sizeBytes : nil,
            service: service,
            originalItem: item,
            operationID: operationID,
            generation: requestGeneration
        )
    }

    private func prepareQuickLook(
        _ resolvedItem: FileItem,
        verifiedSize: Int64?,
        service: any MobileFilePreviewServing,
        originalItem: FileItem,
        operationID: UUID,
        generation requestGeneration: Int
    ) async {
        guard let size = verifiedSize,
              size > 0,
              size <= Self.maximumQuickLookBytes,
              let approvedExtension = Self.quickLookExtension(
                for: state.previewKind,
                proposed: resolvedItem.fileExtension
              ) else {
            state.phase = .detailsOnly
            state.progress = nil
            return
        }
        let directory = rootURL.appendingPathComponent(operationID.uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent(
            "\(UUID().uuidString).\(approvedExtension)",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        } catch {
            guard isCurrent(item: originalItem, generation: requestGeneration) else { return }
            state.phase = .failed
            state.previewFailure = Self.failureCategory(for: error)
            return
        }

        guard isCurrent(item: originalItem, generation: requestGeneration) else {
            cleanup(directory)
            return
        }
        ownedDirectoryURL = directory
        state.phase = .loadingPreview
        state.progress = MobileFilePreviewProgress(completedBytes: 0, totalBytes: size)

        do {
            let source = try await service.mediaStreamSource(
                remotePath: resolvedItem.path,
                fileExtension: approvedExtension,
                expectedContentLength: size
            )
            guard fileManager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            var offset: Int64 = 0
            var strongETag: String?
            while offset < size {
                try Task.checkCancellation()
                let length = Int(min(
                    Int64(MobileSecureRangeReader.maximumRangeLength),
                    size - offset
                ))
                let requiresStrongETag = strongETag != nil || offset + Int64(length) < size
                let payload = try await rangeReader.read(
                    source: source,
                    offset: offset,
                    maximumLength: length,
                    ifMatch: strongETag,
                    requiresStrongETag: requiresStrongETag
                )
                guard payload.totalLength == size,
                      payload.data.count == length else {
                    throw URLError(.badServerResponse)
                }
                if let current = strongETag {
                    guard payload.strongETag == current else {
                        throw URLError(.resourceUnavailable)
                    }
                } else if requiresStrongETag {
                    guard let tag = payload.strongETag else {
                        throw URLError(.resourceUnavailable)
                    }
                    strongETag = tag
                }
                try handle.write(contentsOf: payload.data)
                offset += Int64(payload.data.count)
                applyProgress(
                    completed: offset,
                    total: size,
                    item: originalItem,
                    generation: requestGeneration
                )
            }
            try Task.checkCancellation()
            guard isCurrent(item: originalItem, generation: requestGeneration) else {
                cleanup(directory)
                return
            }
            guard fileManager.fileExists(atPath: fileURL.path) else {
                cleanup(directory)
                ownedDirectoryURL = nil
                state.progress = nil
                state.phase = .failed
                state.previewFailure = .invalidResponse
                return
            }
            state.artifactURL = fileURL
            state.content = .quickLook
            state.phase = .ready
            state.previewFailure = nil
        } catch is CancellationError {
            cleanup(directory)
            guard isCurrent(item: originalItem, generation: requestGeneration) else { return }
            ownedDirectoryURL = nil
            state.artifactURL = nil
            state.progress = nil
            state.phase = .cancelled
            state.previewFailure = .cancelled
        } catch {
            cleanup(directory)
            guard isCurrent(item: originalItem, generation: requestGeneration) else { return }
            ownedDirectoryURL = nil
            state.artifactURL = nil
            state.progress = nil
            state.phase = .failed
            state.previewFailure = Self.failureCategory(for: error)
        }
    }

    private func prepareText(
        _ resolvedItem: FileItem,
        verifiedSize: Int64?,
        service: any MobileFilePreviewServing,
        originalItem: FileItem,
        generation requestGeneration: Int
    ) async {
        guard Self.mobileTextExtensions.contains(resolvedItem.fileExtension?.lowercased() ?? "") else {
            state.phase = .detailsOnly
            return
        }
        guard let size = verifiedSize else {
            state.content = .textSizeUnknown
            state.phase = .ready
            return
        }
        guard size >= 0, size <= Self.maximumTextBytes else {
            state.content = .textTooLarge
            state.phase = .ready
            return
        }
        guard size > 0 else {
            state.content = .emptyText
            state.phase = .ready
            return
        }

        state.phase = .loadingPreview
        state.progress = MobileFilePreviewProgress(completedBytes: 0, totalBytes: size)
        do {
            let source = try await service.mediaStreamSource(
                remotePath: resolvedItem.path,
                fileExtension: resolvedItem.fileExtension,
                expectedContentLength: size
            )
            let payload = try await rangeReader.read(
                source: source,
                offset: 0,
                maximumLength: Int(size) + 1,
                ifMatch: nil,
                requiresStrongETag: false
            )
            try Task.checkCancellation()
            guard isCurrent(item: originalItem, generation: requestGeneration) else { return }
            guard payload.data.count == Int(size), let text = Self.decodeText(payload.data) else {
                state.progress = nil
                state.content = .textEncodingUnsupported
                state.phase = .ready
                return
            }
            state.progress = nil
            state.content = text.isEmpty ? .emptyText : .text(text)
            state.phase = .ready
            state.previewFailure = nil
        } catch is CancellationError {
            finishReadCancellation(item: originalItem, generation: requestGeneration)
        } catch {
            finishReadFailure(error, item: originalItem, generation: requestGeneration)
        }
    }

    private func prepareMedia(
        _ resolvedItem: FileItem,
        verifiedSize: Int64?,
        service: any MobileFilePreviewServing,
        originalItem: FileItem,
        generation requestGeneration: Int
    ) async {
        let fileExtension = resolvedItem.fileExtension?.lowercased() ?? ""
        let supported = state.previewKind == .video
            ? Self.mobileVideoExtensions.contains(fileExtension)
            : Self.mobileAudioExtensions.contains(fileExtension)
        guard supported, let size = verifiedSize, size > 0 else {
            state.phase = .detailsOnly
            return
        }
        state.phase = .loadingPreview
        do {
            let source = try await service.mediaStreamSource(
                remotePath: resolvedItem.path,
                fileExtension: fileExtension,
                expectedContentLength: size
            )
            try Task.checkCancellation()
            guard isCurrent(item: originalItem, generation: requestGeneration) else { return }
            mediaSource = source
            state.content = .media
            state.phase = .ready
            state.previewFailure = nil
        } catch is CancellationError {
            finishReadCancellation(item: originalItem, generation: requestGeneration)
        } catch {
            finishReadFailure(error, item: originalItem, generation: requestGeneration)
        }
    }

    private func finishReadCancellation(item: FileItem, generation: Int) {
        guard isCurrent(item: item, generation: generation) else { return }
        mediaSource = nil
        state.progress = nil
        state.phase = .cancelled
        state.previewFailure = .cancelled
    }

    private func finishReadFailure(_ error: Error, item: FileItem, generation: Int) {
        guard isCurrent(item: item, generation: generation) else { return }
        mediaSource = nil
        state.progress = nil
        state.phase = .failed
        state.previewFailure = Self.failureCategory(for: error)
    }

    private func applyProgress(
        completed: Int64,
        total: Int64?,
        item: FileItem,
        generation requestGeneration: Int
    ) {
        guard isCurrent(item: item, generation: requestGeneration),
              state.phase == .loadingPreview else { return }
        state.progress = MobileFilePreviewProgress(
            completedBytes: completed,
            totalBytes: total
        )
    }

    private func isCurrent(item: FileItem, generation requestGeneration: Int) -> Bool {
        generation == requestGeneration
            && state.profileID == item.profileID
            && state.selectedItem?.path == item.path
    }

    private func stopCurrentOperation() {
        operationTask?.cancel()
        operationTask = nil
        generation &+= 1
        mediaSource = nil
        if let ownedDirectoryURL {
            cleanup(ownedDirectoryURL)
            self.ownedDirectoryURL = nil
        }
    }

    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        return String(data: data, encoding: .utf8)
    }

    private static let mobileTextExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "xml", "yaml", "yml", "log", "csv", "tsv",
        "swift", "kt", "kts", "java", "cs", "js", "tsx", "jsx", "html", "css",
        "py", "rb", "go", "rs", "sh", "zsh", "ini", "conf", "toml"
    ]
    private static let mobileVideoExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp"]
    private static let mobileAudioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav"]

    private static func quickLookExtension(
        for kind: PreviewKind,
        proposed: String?
    ) -> String? {
        let value = proposed?.lowercased() ?? ""
        switch kind {
        case .image where [
            "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"
        ].contains(value):
            return value
        case .pdf where value == "pdf":
            return value
        default:
            return nil
        }
    }

    private func cleanup(_ directory: URL) {
        // 只删除本模型为单次操作创建并持有的独占目录，不枚举或清扫共享临时根。
        try? fileManager.removeItem(at: directory)
    }

    private static func failureCategory(for error: Error) -> AppErrorCategory {
        if error is CancellationError { return .cancelled }
        if let appError = error as? AppError { return appError.category }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileWriteOutOfSpaceError {
            return .localStorageFull
        }
        return .unknown
    }
}
