import AVFoundation
import AVKit
import DsmCore
import DsmLocalization
import Observation
import SwiftUI
import UniformTypeIdentifiers

private final class MobileMediaResourceLoader: NSObject,
    AVAssetResourceLoaderDelegate,
    @unchecked Sendable {
    static let maximumRangeLength = 4 * 1_024 * 1_024

    private let source: MediaStreamSource
    private let coordinator: MobileMediaRangeCoordinator
    private let onFailure: @Sendable () -> Void
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(
        source: MediaStreamSource,
        reader: any MobileSecureRangeReading = MobileSecureRangeReader(),
        onFailure: @escaping @Sendable () -> Void
    ) {
        self.source = source
        coordinator = MobileMediaRangeCoordinator(source: source, reader: reader)
        self.onFailure = onFailure
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let dataRequest = loadingRequest.dataRequest else {
            if let information = loadingRequest.contentInformationRequest,
               let total = source.expectedContentLength,
               total > 0 {
                information.contentType = Self.typeIdentifier(
                    contentType: nil,
                    fileExtension: source.fileExtension
                )
                information.contentLength = total
                information.isByteRangeAccessSupported = true
                loadingRequest.finishLoading()
                return true
            }
            loadingRequest.finishLoading(with: URLError(.badServerResponse))
            return false
        }
        let offset = max(max(dataRequest.currentOffset, dataRequest.requestedOffset), 0)
        let length = min(max(dataRequest.requestedLength, 1), Self.maximumRangeLength)
        let identifier = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let payload = try await coordinator.read(
                    offset: offset,
                    maximumLength: length
                )
                try Task.checkCancellation()
                if let information = loadingRequest.contentInformationRequest {
                    information.contentType = Self.typeIdentifier(
                        contentType: payload.contentType,
                        fileExtension: source.fileExtension
                    )
                    information.contentLength = payload.totalLength
                    information.isByteRangeAccessSupported = true
                }
                dataRequest.respond(with: payload.data)
                loadingRequest.finishLoading()
            } catch {
                loadingRequest.finishLoading(with: error)
                if !(error is CancellationError) { onFailure() }
            }
            removeTask(identifier)
        }
        lock.withLock { tasks[identifier] = task }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let identifier = ObjectIdentifier(loadingRequest)
        let task = lock.withLock { tasks.removeValue(forKey: identifier) }
        task?.cancel()
    }

    func cancelAll() {
        let values = lock.withLock {
            let values = Array(tasks.values)
            tasks.removeAll()
            return values
        }
        values.forEach { $0.cancel() }
    }

    private func removeTask(_ identifier: ObjectIdentifier) {
        _ = lock.withLock { tasks.removeValue(forKey: identifier) }
    }

    private static func typeIdentifier(
        contentType: String?,
        fileExtension: String?
    ) -> String? {
        if let contentType,
           let type = UTType(mimeType: contentType) {
            return type.identifier
        }
        if let fileExtension,
           let type = UTType(filenameExtension: fileExtension) {
            return type.identifier
        }
        return nil
    }
}

actor MobileMediaRangeCoordinator {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let source: MediaStreamSource
    private let reader: any MobileSecureRangeReading
    private var strongETag: String?
    private var isReading = false
    private var waiters: [Waiter] = []
    private var pendingWaiterIDs: Set<UUID> = []
    private var cancelledWaiterIDs: Set<UUID> = []

    init(source: MediaStreamSource, reader: any MobileSecureRangeReading) {
        self.source = source
        self.reader = reader
    }

    func read(offset: Int64, maximumLength: Int) async throws -> MobileSecureRangePayload {
        try await acquire()
        defer { release() }
        let payload = try await reader.read(
            source: source,
            offset: offset,
            maximumLength: maximumLength,
            ifMatch: strongETag,
            requiresStrongETag: true
        )
        if let current = strongETag {
            guard payload.strongETag == current else { throw URLError(.resourceUnavailable) }
        } else {
            guard let value = payload.strongETag else { throw URLError(.resourceUnavailable) }
            strongETag = value
        }
        return payload
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if !isReading {
            isReading = true
            return
        }
        let id = UUID()
        pendingWaiterIDs.insert(id)
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pendingWaiterIDs.remove(id)
                if cancelledWaiterIDs.remove(id) != nil {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        guard granted else { throw CancellationError() }
    }

    private func release() {
        if waiters.isEmpty {
            isReading = false
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            if pendingWaiterIDs.contains(id) { cancelledWaiterIDs.insert(id) }
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

@MainActor
@Observable
private final class MobileMediaPlaybackModel {
    private(set) var player: AVPlayer?
    private(set) var isPreparing = true
    private(set) var hasFailed = false

    @ObservationIgnored private var loader: MobileMediaResourceLoader?
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var source: MediaStreamSource?

    func prepare(_ source: MediaStreamSource) {
        close()
        self.source = source
        isPreparing = true
        hasFailed = false
        let requestGeneration = UUID()
        generation = requestGeneration
        guard let assetURL = URL(
            string: "lanstash-media://stream/\(UUID().uuidString).\(source.fileExtension ?? "media")"
        ) else {
            fail(requestGeneration)
            return
        }
        let loader = MobileMediaResourceLoader(source: source) { [weak self] in
            Task { @MainActor in self?.fail(requestGeneration) }
        }
        self.loader = loader
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(
            loader,
            queue: DispatchQueue(label: "io.github.qwertyuiop1995.lanstash.mobile-media")
        )
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        self.player = player
        preparationTask = Task { [weak self] in
            do {
                let playable = try await asset.load(.isPlayable)
                try Task.checkCancellation()
                guard playable else { throw URLError(.cannotDecodeContentData) }
                guard let self, generation == requestGeneration else { return }
                isPreparing = false
            } catch is CancellationError {
            } catch {
                self?.fail(requestGeneration)
            }
        }
    }

    func retry() {
        guard let source else { return }
        prepare(source)
    }

    func suspend() {
        player?.pause()
        loader?.cancelAll()
        preparationTask?.cancel()
        preparationTask = nil
    }

    func resumeAfterSuspend() {
        guard let source else { return }
        prepare(source)
    }

    func close() {
        generation = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        player?.pause()
        player = nil
        loader?.cancelAll()
        loader = nil
        isPreparing = true
        hasFailed = false
    }

    private func fail(_ requestGeneration: UUID) {
        guard generation == requestGeneration else { return }
        isPreparing = false
        hasFailed = true
        player?.pause()
    }
}

struct MobileMediaPlayer: View {
    let source: MediaStreamSource
    let title: String

    @Environment(\.scenePhase) private var scenePhase
    @State private var model = MobileMediaPlaybackModel()
    @State private var wasSuspended = false

    var body: some View {
        ZStack {
            Color.black
            if let player = model.player, !model.hasFailed {
                VideoPlayer(player: player)
            }
            if model.isPreparing, !model.hasFailed {
                ProgressView(L10n.string("mobile.files.preview.media.loading"))
                    .tint(.white)
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .combine)
            }
            if model.hasFailed {
                ContentUnavailableView {
                    Label(
                        L10n.string("mobile.files.preview.media.failed.title"),
                        systemImage: "play.slash"
                    )
                } description: {
                    Text(L10n.string("mobile.files.preview.media.failed.message"))
                } actions: {
                    Button(L10n.string("mobile.files.preview.action.retry")) { model.retry() }
                        .buttonStyle(.borderedProminent)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .foregroundStyle(.white)
            }
        }
        .accessibilityLabel(L10n.string("mobile.files.preview.media.accessibility.player", title))
        .task(id: source.request.url) { model.prepare(source) }
        .onDisappear { model.close() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active where wasSuspended:
                wasSuspended = false
                model.resumeAfterSuspend()
            case .inactive, .background:
                wasSuspended = true
                model.suspend()
            default:
                break
            }
        }
    }
}
