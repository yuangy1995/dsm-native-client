import AppKit
import AVKit
import CryptoKit
import DsmCore
import Observation
import PDFKit
import Security
import SwiftUI
import UniformTypeIdentifiers
import DsmLocalization

private final class MediaLoadingContext: @unchecked Sendable {
    let loadingRequest: AVAssetResourceLoadingRequest
    let requestedOffset: Int64
    let maximumLength: Int
    var receivedLength = 0

    init(
        loadingRequest: AVAssetResourceLoadingRequest,
        requestedOffset: Int64,
        maximumLength: Int
    ) {
        self.loadingRequest = loadingRequest
        self.requestedOffset = requestedOffset
        self.maximumLength = maximumLength
    }
}

@MainActor
@Observable
final class PreviewWindowPresentationState {
    var isFullScreen = false
}

final class DsmAVAssetResourceLoaderDelegate: NSObject, AVAssetResourceLoaderDelegate, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let source: MediaStreamSource
    private let onFailure: @Sendable (String) -> Void
    private let onLoadingMetrics: @Sendable (Double?, Bool) -> Void
    private var session: URLSession!
    private var activeRequests = [URLSessionDataTask: MediaLoadingContext]()
    private let lock = NSLock()
    private var speedWindowStartedAt = Date()
    private var speedWindowBytes: Int64 = 0
    private var smoothedBytesPerSecond: Double?

    init(
        source: MediaStreamSource,
        onFailure: @escaping @Sendable (String) -> Void,
        onLoadingMetrics: @escaping @Sendable (Double?, Bool) -> Void
    ) {
        self.source = source
        self.onFailure = onFailure
        self.onLoadingMetrics = onLoadingMetrics
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func cancelAll() {
        let requests = lock.withLock {
            let values = Array(activeRequests.values)
            activeRequests.removeAll()
            return values
        }
        session.invalidateAndCancel()
        onLoadingMetrics(nil, false)
        for context in requests {
            context.loadingRequest.finishLoading(with: CancellationError())
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let dataRequest = loadingRequest.dataRequest
        let offset = max(dataRequest?.currentOffset ?? dataRequest?.requestedOffset ?? 0, 0)
        let requestedLength = max(dataRequest?.requestedLength ?? 1, 1)
        // 防止播放器或异常媒体一次请求整个大文件；AVFoundation 会按需继续请求后续区间。
        let maximumLength = min(requestedLength, 16 * 1_024 * 1_024)

        var request = source.request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "bytes=\(offset)-\(offset + Int64(maximumLength) - 1)",
            forHTTPHeaderField: "Range"
        )

        let task = session.dataTask(with: request)
        lock.withLock {
            if activeRequests.isEmpty {
                speedWindowStartedAt = Date()
                speedWindowBytes = 0
                smoothedBytesPerSecond = nil
            }
            activeRequests[task] = MediaLoadingContext(
                loadingRequest: loadingRequest,
                requestedOffset: offset,
                maximumLength: maximumLength
            )
        }
        onLoadingMetrics(nil, true)
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        lock.withLock {
            if let task = activeRequests.first(where: { $0.value.loadingRequest == loadingRequest })?.key {
                task.cancel()
                activeRequests.removeValue(forKey: task)
            }
        }
        publishIdleIfNeeded()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let context = activeRequests[dataTask]
        lock.unlock()

        guard let context, let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(dataTask, message: L10n.string("ui.4feefc15ab58f95b"))
            return
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .lowercased()
        guard (200..<300).contains(httpResponse.statusCode),
              contentType?.contains("application/json") != true,
              contentType?.contains("text/html") != true else {
            completionHandler(.cancel)
            finish(dataTask, message: L10n.string("ui.13c93a65254a46cc"))
            return
        }

        let contentRange = Self.parseContentRange(
            httpResponse.value(forHTTPHeaderField: "Content-Range")
        )
        let supportsRange = httpResponse.statusCode == 206 && contentRange != nil
        if context.requestedOffset > 0 && !supportsRange {
            completionHandler(.cancel)
            finish(dataTask, message: L10n.string("ui.d0b56b3e4f2fb3cf"))
            return
        }
        if let contentRange, contentRange.start != context.requestedOffset {
            completionHandler(.cancel)
            finish(dataTask, message: L10n.string("ui.02de0cf3dca4382e"))
            return
        }

        if let infoRequest = context.loadingRequest.contentInformationRequest {
            infoRequest.contentType = Self.typeIdentifier(
                mimeType: contentType,
                fileExtension: source.fileExtension
            )
            infoRequest.isByteRangeAccessSupported = supportsRange
            if let total = contentRange?.total ?? source.expectedContentLength {
                infoRequest.contentLength = total
            } else if httpResponse.statusCode == 200,
                      let length = httpResponse.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init) {
                infoRequest.contentLength = length
            }
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let context = activeRequests[dataTask]
        lock.unlock()

        guard let context else { return }
        let remaining = context.maximumLength - context.receivedLength
        guard remaining > 0 else {
            finish(dataTask)
            return
        }
        let accepted = data.prefix(remaining)
        if !accepted.isEmpty {
            context.loadingRequest.dataRequest?.respond(with: Data(accepted))
            context.receivedLength += accepted.count
            recordReceivedBytes(accepted.count)
        }
        if context.receivedLength >= context.maximumLength {
            finish(dataTask)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let dataTask = task as? URLSessionDataTask else { return }
        let context = lock.withLock { activeRequests.removeValue(forKey: dataTask) }
        guard let context else { return }
        if let error, (error as? URLError)?.code != .cancelled {
            context.loadingRequest.finishLoading(with: error)
            onFailure(L10n.string("ui.457c462f18bd4fc3"))
        } else {
            context.loadingRequest.finishLoading()
        }
        publishIdleIfNeeded()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let redirectedRequest = MediaStreamRedirectPolicy.redirectedRequest(
            from: source.request,
            proposedRequest: request
        ) else {
            completionHandler(nil)
            if let dataTask = task as? URLSessionDataTask {
                finish(dataTask, message: L10n.string("ui.dea6a9f8ea69e6d9"))
            }
            return
        }
        completionHandler(redirectedRequest)
    }

    // MARK: - URLSessionDelegate (TLS)

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == source.expectedHost.lowercased(),
              let serverTrust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate])?.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        var systemError: CFError?
        let systemTrusted = SecTrustEvaluateWithError(serverTrust, &systemError)
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }
            .joined()
        let pin = source.pinnedCertificateSHA256?
            .replacingOccurrences(of: ":", with: "")
            .uppercased()

        if systemTrusted, pin == nil || pin == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }
        if pin == fingerprint,
           SecTrustSetPolicies(serverTrust, SecPolicyCreateBasicX509()) == errSecSuccess,
           SecTrustSetAnchorCertificates(serverTrust, [certificate] as CFArray) == errSecSuccess,
           SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess {
            var pinnedError: CFError?
            if SecTrustEvaluateWithError(serverTrust, &pinnedError) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
        onFailure(L10n.string("ui.9bf6e079d400159d"))
    }

    private func finish(_ task: URLSessionDataTask, message: String? = nil) {
        let context = lock.withLock { activeRequests.removeValue(forKey: task) }
        guard let context else { return }
        if let message {
            let error = NSError(
                domain: "LanStashMediaStream",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            context.loadingRequest.finishLoading(with: error)
            onFailure(message)
        } else {
            context.loadingRequest.finishLoading()
        }
        task.cancel()
        publishIdleIfNeeded()
    }

    private func recordReceivedBytes(_ count: Int) {
        let result: (Double, Bool)? = lock.withLock {
            speedWindowBytes += Int64(count)
            let elapsed = Date().timeIntervalSince(speedWindowStartedAt)
            guard elapsed >= 0.25 else { return nil }
            let instantSpeed = Double(speedWindowBytes) / elapsed
            if let previous = smoothedBytesPerSecond {
                smoothedBytesPerSecond = previous * 0.65 + instantSpeed * 0.35
            } else {
                smoothedBytesPerSecond = instantSpeed
            }
            speedWindowStartedAt = Date()
            speedWindowBytes = 0
            return (smoothedBytesPerSecond ?? instantSpeed, !activeRequests.isEmpty)
        }
        if let result {
            onLoadingMetrics(result.0, result.1)
        }
    }

    private func publishIdleIfNeeded() {
        let isLoading = lock.withLock { !activeRequests.isEmpty }
        if !isLoading {
            onLoadingMetrics(nil, false)
        }
    }

    private static func parseContentRange(
        _ value: String?
    ) -> (start: Int64, end: Int64, total: Int64?)? {
        guard let value,
              value.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard let rangePart = parts.first else { return nil }
        let bounds = rangePart.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              end >= start else { return nil }
        let total = parts.count == 2 && parts[1] != "*" ? Int64(parts[1]) : nil
        return (start, end, total)
    }

    private static func typeIdentifier(
        mimeType: String?,
        fileExtension: String?
    ) -> String {
        if let mimeType, let type = UTType(mimeType: mimeType) {
            return type.identifier
        }
        if let fileExtension, let type = UTType(filenameExtension: fileExtension) {
            return type.identifier
        }
        return AVFileType.mp4.rawValue
    }
}

struct FileDetailView: View {
    @Bindable var model: WorkspaceModel
    @Bindable var windowState: PreviewWindowPresentationState
    let onDownload: (FileItem, WorkspaceModel.FolderDownloadMode) -> Void
    let onDelete: ([FileItem]) -> Void
    let onRestore: (FileItem) -> Void
    @State private var confirmsDiscardAndClose = false
    @State private var confirmsCancelEditing = false
    @State private var livePhotoPlayer: AVPlayer?
    @State private var livePhotoResourceLoaderDelegate: DsmAVAssetResourceLoaderDelegate?
    @State private var metadata: PhotoMetadata?
    @State private var isLoadingMetadata = false
    @State private var decodedPreview: DecodedImage?
    @State private var previewDecodingFailed = false
    @State private var showFullMetadataPopover = false

    var body: some View {
        Group {
            if windowState.isFullScreen, let item = model.selectedItem, supportsFullScreen {
                fullScreenPreview(item)
            } else {
                standardPreview
            }
        }
        .background {
            PreviewSpaceShortcutHandler {
                requestClose()
            }
        }
        .alert(L10n.string("ui.01aeaa37eedefb79"), isPresented: $confirmsDiscardAndClose) {
            Button(L10n.string("ui.fd4b9e3b6c685bae"), role: .cancel) {}
            Button(L10n.string("ui.9b7824cefa1e8b16"), role: .destructive) {
                model.cancelTextEditing()
                model.dismissPreview()
            }
        } message: {
            Text(L10n.string("ui.f76d9fbcbb4dd66f"))
        }
        .alert(L10n.string("ui.8d45a3f709e375f4"), isPresented: $confirmsCancelEditing) {
            Button(L10n.string("ui.fd4b9e3b6c685bae"), role: .cancel) {}
            Button(L10n.string("ui.9b7824cefa1e8b16"), role: .destructive) {
                model.cancelTextEditing()
            }
        } message: {
            Text(L10n.string("ui.58f8945d5a6ac8d0"))
        }
    }

    private var standardPreview: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.126689cc9d017c4c"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if supportsFullScreen {
                    Button {
                        NSApp.keyWindow?.toggleFullScreen(nil)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("f", modifiers: [.command, .control])
                    .help(L10n.string("ui.16611f4f13b21eaa"))
                    .accessibilityLabel(L10n.string("ui.967a720c0622734e"))
                }
                Button {
                    requestClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .disabled(model.isSavingText)
                .help(L10n.string("ui.f2873f0def187cc5"))
                .accessibilityLabel(L10n.string("ui.f2873f0def187cc5"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            
            Divider()

            Group {
                if model.selection.count > 1 {
                    ContentUnavailableView(
                        L10n.string("ui.9db17d4290e27f67", String(describing: model.selection.count)),
                        systemImage: "checkmark.circle",
                        description: Text(L10n.string("ui.20803ae2cc67f9ff"))
                    )
                } else if let item = model.selectedItem {
                    detail(for: item)
                } else {
                    ContentUnavailableView(
                        L10n.string("ui.c0365276d32f78ff"),
                        systemImage: "sidebar.right",
                        description: Text(L10n.string("ui.a5454cba27a893ad"))
                    )
                }
            }
            .fillsAvailableContentArea()
        }
    }

    private var supportsFullScreen: Bool {
        guard let item = model.selectedItem else { return false }
        let kind = model.resolvedPreviewKind ?? PreviewKind.classify(item)
        return kind == .image || kind == .video
    }

    private var isFavorite: Bool {
        guard let item = model.selectedItem else { return false }
        return model.favorites.contains { $0.path == item.path }
    }

    private func fullScreenPreview(_ item: FileItem) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            preview(item)
                .ignoresSafeArea()
            Button {
                NSApp.keyWindow?.toggleFullScreen(nil)
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.48), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: [.command, .control])
            .help(L10n.string("ui.88ebd1615b038fe1"))
            .accessibilityLabel(L10n.string("ui.0f1505b6ad3fafe4"))
            .padding(20)
        }
    }

    private func livePhotoVideoPath(for item: FileItem) -> String? {
        if model.section?.belongsToPhotosModule == true {
            if let photoItem = model.photoLibrary.displayedItems.first(where: { $0.id == item.id }),
               let videoPath = photoItem.livePhotoVideoPath {
                return videoPath
            }
        }
        let directory = (item.path as NSString).deletingLastPathComponent
        let stem = ((item.name as NSString).deletingPathExtension).lowercased()
        for candidate in model.filteredItems {
            guard candidate.id != item.id else { continue }
            let candidateDir = (candidate.path as NSString).deletingLastPathComponent
            let candidateStem = ((candidate.name as NSString).deletingPathExtension).lowercased()
            let candidateExt = candidate.fileExtension?.lowercased() ?? ""
            if candidateDir == directory && candidateStem == stem && ["mov", "mp4"].contains(candidateExt) {
                return candidate.path
            }
        }
        return nil
    }

    private func detail(for item: FileItem) -> some View {
        VStack(spacing: 0) {
            // 单行极简 Header：完美集成图标、文件名、LIVE 标记与收藏按钮
            HStack(spacing: 8) {
                FileIcon(item: item)
                    .font(.system(size: 16))
                
                Text(item.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .help(item.path)
                
                if let videoPath = livePhotoVideoPath(for: item) {
                    LivePhotoPreviewBadgeButton(
                        model: model,
                        item: item,
                        videoPath: videoPath,
                        player: $livePhotoPlayer,
                        resourceLoaderDelegate: $livePhotoResourceLoaderDelegate
                    )
                }
                
                Spacer()

                if item.isRecyclePath {
                    Button {
                        onRestore(item)
                    } label: {
                        Label(L10n.string("ui.e0534b8a4e46a0cb"), systemImage: "arrow.uturn.backward.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("ui.0c61c4b47e2d4bb9"))
                } else if !item.isDirectory {
                    Button {
                        model.toggleFavorite(item)
                    } label: {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isFavorite ? L10n.string("ui.d9eba5226c5df4c4") : L10n.string("ui.0cfc396e4aa347ad"))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if item.isDirectory {
                folderDetails(item)
            } else {
                preview(item)

                if isLoadingMetadata || metadata != nil {
                    Divider()
                    metadataPanel(for: item)
                }
            }

        }
        .task(id: item.id) {
            metadata = nil
            isLoadingMetadata = true
            metadata = await model.metadata(for: item)
            isLoadingMetadata = false
        }
        .onChange(of: item.id) { _, _ in
            livePhotoPlayer?.pause()
            livePhotoPlayer = nil
            livePhotoResourceLoaderDelegate?.cancelAll()
            livePhotoResourceLoaderDelegate = nil
        }
    }

    @ViewBuilder
    private func preview(_ item: FileItem) -> some View {
        switch model.preview {
        case .empty:
            Color.clear
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text(L10n.string("ui.9cbeebf62a6d909d"))
                    .foregroundStyle(.secondary)
                if let speed = model.previewLoadingSpeedBytesPerSecond, speed > 0 {
                    Text(L10n.string("ui.6b6dde1b911d84d4", String(describing: networkSpeedText(speed))))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .image(let data):
            Group {
                if let decoded = decodedPreview {
                    ZStack {
                        FittedImagePreview(cgImage: decoded.cgImage, orientation: decoded.orientation)
                            .id(item.id)
                        if livePhotoPlayer != nil {
                            VideoPlayerRepresentable(
                                player: $livePhotoPlayer,
                                controlsStyle: .none,
                                showsFrameSteppingButtons: false,
                                showsSharingServiceButton: false
                            )
                            .background(Color.black)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if model.canPreviewPreviousImage || model.canPreviewNextImage {
                            HStack {
                                imageNavigationButton(
                                    title: L10n.string("ui.bcf200709dbc7ff4"),
                                    systemImage: "chevron.left",
                                    isEnabled: model.canPreviewPreviousImage,
                                    shortcut: .leftArrow,
                                    action: model.previewPreviousImage
                                )
                                Spacer()
                                imageNavigationButton(
                                    title: L10n.string("ui.dcd4eb0273699416"),
                                    systemImage: "chevron.right",
                                    isEnabled: model.canPreviewNextImage,
                                    shortcut: .rightArrow,
                                    action: model.previewNextImage
                                )
                            }
                            .padding(.horizontal, 18)
                        }
                    }
                } else if previewDecodingFailed {
                    previewMessage(L10n.string("ui.b8661cfa7d6d10fe"), systemImage: "photo.badge.exclamationmark") {
                        onDownload(item, .archive)
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(L10n.string("ui.4836a49a67cdc785"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: data) {
                decodedPreview = nil
                previewDecodingFailed = false
                let decoded = await Task.detached(priority: .userInitiated) { () -> DecodedImage? in
                    DecodedImage(from: data)
                }.value
                if let decoded {
                    self.decodedPreview = decoded
                } else {
                    previewDecodingFailed = true
                }
            }
        case .text(let text, let truncated):
            VStack(spacing: 0) {
                if truncated {
                    Label(L10n.string("ui.947b866677d0b366"), systemImage: "scissors")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                }
                HStack(spacing: 10) {
                    if model.isEditingText {
                        Button(L10n.string("ui.2cd0f3be8738a86c")) {
                            if model.hasUnsavedTextEdits {
                                confirmsCancelEditing = true
                            } else {
                                model.cancelTextEditing()
                            }
                        }
                        .disabled(model.isSavingText)
                        if model.canFormatSelectedText {
                            Button(L10n.string("ui.18a69f09939e46cd")) {
                                model.formatEditableText()
                            }
                            .disabled(model.isSavingText)
                            .help(L10n.string("ui.87f219b0a6b8d93b"))
                        }
                        Spacer()
                        Button {
                            Task { await model.saveTextEdits() }
                        } label: {
                            if model.isSavingText {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.string("ui.6bdb4435095e5d28"))
                                }
                            } else {
                                Text(L10n.string("ui.a3030bf8f16dc63c"))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(model.isSavingText || !model.hasUnsavedTextEdits)
                    } else {
                        Spacer()
                        if model.canEditSelectedText {
                            Button(L10n.string("ui.051836569928a9f9")) {
                                model.beginTextEditing()
                            }
                            .keyboardShortcut("e", modifiers: .command)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))

                if let message = model.textEditingMessage {
                    Label(
                        message,
                        systemImage: model.textEditingMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(model.textEditingMessageIsError ? .red : .secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if model.isEditingText {
                    TextEditor(text: $model.editableText)
                        .font(.system(.callout, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor))
                        .accessibilityLabel(L10n.string("ui.5d5903894506eb80", String(describing: item.name)))
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        Text(text)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
        case .pdf(let url):
            PDFDocumentView(url: url)
        case .video(let source):
            VideoPlayerView(source: source) {
                onDownload(item, .archive)
            }
        case .audio(let source):
            AudioPlayerView(source: source)
        case .unsupported(let message):
            previewMessage(message, systemImage: "doc.questionmark") {
                onDownload(item, .archive)
            }
        case .failed(let message):
            previewMessage(message, systemImage: "exclamationmark.triangle", color: .red) {
                onDownload(item, .archive)
            }
        }
    }

    @ViewBuilder
    private func metadataPanel(for item: FileItem) -> some View {
        if isLoadingMetadata {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.string("ui.89eb41c818ad7eba"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        } else if let metadata {
            HStack(spacing: 12) {
                // 左侧：曝光四要素参数芯片 (EXIF Exposure Chips)
                HStack(spacing: 6) {
                    if let aperture = metadata.aperture, !aperture.isEmpty {
                        exifChip(icon: "camera.aperture", text: "f/\(aperture)")
                    }
                    if let shutter = metadata.shutterSpeed, !shutter.isEmpty {
                        exifChip(icon: "timer", text: shutter)
                    }
                    if let iso = metadata.iso, !iso.isEmpty {
                        exifChip(icon: "gauge.with.dots.needle.bottom.50percent", text: "ISO \(iso)")
                    }
                    if let focal = metadata.focalLength, !focal.isEmpty {
                        exifChip(icon: "scope", text: "\(focal)mm")
                    }
                }

                Spacer(minLength: 8)

                // 右侧：尺寸、相机模型与展开详情按钮
                HStack(spacing: 10) {
                    if let width = metadata.width, let height = metadata.height {
                        Label("\(width) × \(height)", systemImage: "aspectratio")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else if let sizeBytes = item.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    if let modelName = metadata.cameraModel ?? metadata.cameraMake {
                        Label(modelName, systemImage: "camera")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Button {
                        showFullMetadataPopover.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(showFullMetadataPopover ? Color.accentColor : Color.secondary)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("ui.24ffcb3067b0acb2"))
                    .popover(isPresented: $showFullMetadataPopover, arrowEdge: .top) {
                        fullMetadataPopoverContent(for: item, metadata: metadata)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func exifChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }

    @ViewBuilder
    private func fullMetadataPopoverContent(for item: FileItem, metadata: PhotoMetadata) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(L10n.string("ui.1932da4d4dba4ed0"), systemImage: "info.circle.fill")
                    .font(.headline)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let width = metadata.width, let height = metadata.height {
                    metadataRow(label: L10n.string("ui.71a90485d5657484"), value: "\(width) × \(height)")
                }
                if let creationDate = metadata.creationDate {
                    metadataRow(
                        label: L10n.string("ui.50b635ec9c64c64e"),
                        value: Self.metadataDateFormatter.string(from: creationDate)
                    )
                } else if let creationDate = item.times?.createdAt {
                    metadataRow(
                        label: L10n.string("ui.07ec86e0f1d44f91"),
                        value: Self.metadataDateFormatter.string(from: creationDate)
                    )
                }
                if let sizeBytes = item.sizeBytes {
                    metadataRow(
                        label: L10n.string("ui.b9bf6916437a77eb"),
                        value: ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
                    )
                }
                if let make = metadata.cameraMake, let model = metadata.cameraModel {
                    metadataRow(label: L10n.string("ui.a5ab5f9773e993ed"), value: "\(make) \(model)")
                } else if let model = metadata.cameraModel {
                    metadataRow(label: L10n.string("ui.a5ab5f9773e993ed"), value: model)
                } else if let make = metadata.cameraMake {
                    metadataRow(label: L10n.string("ui.a5ab5f9773e993ed"), value: make)
                }
                if let lens = metadata.lens {
                    metadataRow(label: L10n.string("ui.f2a3530d04d3e68a"), value: lens)
                }
                if let iso = metadata.iso, !iso.isEmpty {
                    metadataRow(label: L10n.string("ui.f683414a7a7238a2"), value: iso)
                }
                if let aperture = metadata.aperture, !aperture.isEmpty {
                    metadataRow(label: L10n.string("ui.deb7484ef13d3b08"), value: "f/\(aperture)")
                }
                if let shutter = metadata.shutterSpeed, !shutter.isEmpty {
                    metadataRow(label: L10n.string("ui.82941f1032948e2b"), value: shutter)
                }
                if let focal = metadata.focalLength, !focal.isEmpty {
                    metadataRow(label: L10n.string("ui.d19c52b976916327"), value: "\(focal) mm")
                }
                if let location = metadata.locationText, !location.isEmpty {
                    metadataRow(label: L10n.string("ui.8dc9d6d1e78dda28"), value: location)
                }
                metadataRow(label: L10n.string("ui.c71200b5952e3781"), value: item.path)
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private static var metadataDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = L10n.locale
        return formatter
    }

    private func requestClose() {
        guard !model.isSavingText else { return }
        if model.hasUnsavedTextEdits {
            confirmsDiscardAndClose = true
        } else {
            model.dismissPreview()
        }
    }

    private func imageNavigationButton(
        title: String,
        systemImage: String,
        isEnabled: Bool,
        shortcut: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.32)
        .keyboardShortcut(shortcut, modifiers: [])
        .help(L10n.string("ui.bce7873cec1f287f", String(describing: title)))
        .accessibilityLabel(title)
    }

    private func folderDetails(_ item: FileItem) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.fill")
                .font(.system(size: 72))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
            Text(L10n.string("ui.0ac754408132ab71"))
                .foregroundStyle(.secondary)
            Button(L10n.string("ui.fcf8b4bff0df782d")) {
                Task { await model.open(item) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewMessage(
        _ message: String,
        systemImage: String,
        color: Color = .secondary,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(color)
            Text(L10n.string("ui.b825ccc758e9cba4"))
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(L10n.string("ui.d683d1f7d649b079"), action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PreviewSpaceShortcutHandler: NSViewRepresentable {
    let onSpace: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSpace: onSpace) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onSpace = onSpace
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onSpace: () -> Void
        private weak var hostView: NSView?
        private var monitor: Any?

        init(onSpace: @escaping () -> Void) {
            self.onSpace = onSpace
        }

        func attach(to view: NSView) {
            hostView = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor [weak self] event in
                guard let self,
                      event.window === self.hostView?.window,
                      !self.isEditingText(in: event.window),
                      event.keyCode == 49,
                      event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                    return event
                }
                self.onSpace()
                return nil
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func isEditingText(in window: NSWindow?) -> Bool {
            window?.firstResponder is NSTextView
        }
    }
}

private struct FittedImagePreview: View {
    let cgImage: CGImage
    let orientation: Image.Orientation
    @State private var zoom: CGFloat = 1
    @State private var rotation = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    private var originalWidth: CGFloat {
        CGFloat(cgImage.width) / displayScale
    }

    private var originalHeight: CGFloat {
        CGFloat(cgImage.height) / displayScale
    }

    private var isBaseQuarterTurn: Bool {
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return true
        default:
            return false
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(1, geometry.size.width - 32)
            let availableHeight = max(1, geometry.size.height - 32)
            let baseWidth = isBaseQuarterTurn ? originalHeight : originalWidth
            let baseHeight = isBaseQuarterTurn ? originalWidth : originalHeight
            let isQuarterTurn = abs(rotation) % 180 == 90
            let rotatedWidth = isQuarterTurn ? baseHeight : baseWidth
            let rotatedHeight = isQuarterTurn ? baseWidth : baseHeight
            let fittedScale = min(1, availableWidth / rotatedWidth, availableHeight / rotatedHeight)
            let imageWidth = baseWidth * fittedScale * zoom
            let imageHeight = baseHeight * fittedScale * zoom
            let visualWidth = isQuarterTurn ? imageHeight : imageWidth
            let visualHeight = isQuarterTurn ? imageWidth : imageHeight

            ZStack(alignment: .center) {
                Image(decorative: cgImage, scale: displayScale, orientation: orientation)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: imageWidth, height: imageHeight)
                    .rotationEffect(.degrees(Double(rotation)))
                    .frame(width: visualWidth, height: visualHeight)
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .background {
                ImageScrollWheelReader { delta, isPrecise in
                    let step = isPrecise ? delta * 0.012 : delta * 0.08
                    updateZoom(zoom + step)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityLabel(L10n.string("ui.288f3d9291737873"))
    }

    private func updateZoom(_ value: CGFloat) {
        let newValue = min(5, max(0.25, value))
        if reduceMotion {
            zoom = newValue
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                zoom = newValue
            }
        }
    }
}

private struct ImageScrollWheelReader: NSViewRepresentable {
    let onScroll: (CGFloat, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onScroll: (CGFloat, Bool) -> Void
        private weak var hostView: NSView?
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat, Bool) -> Void) {
            self.onScroll = onScroll
        }

        func attach(to view: NSView) {
            hostView = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { @MainActor [weak self] event in
                guard let self,
                      event.window === self.hostView?.window,
                      let hostView = self.hostView else { return event }
                let point = hostView.convert(event.locationInWindow, from: nil)
                guard hostView.bounds.contains(point) else { return event }
                self.onScroll(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
                return nil
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

private struct PDFDocumentView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
            view.autoScales = true
        }
    }
}

struct VideoPlayerView: View {
    let source: MediaStreamSource
    let onDownload: () -> Void
    @State private var player: AVPlayer?
    @State private var resourceLoaderDelegate: DsmAVAssetResourceLoaderDelegate?
    @State private var playbackGeneration = UUID()
    @State private var isPreparing = true
    @State private var failureMessage: String?
    @State private var networkSpeed: Double?
    @State private var isNetworkLoading = false

    var body: some View {
        ZStack {
            VideoPlayerRepresentable(player: $player)

            if isPreparing, failureMessage == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(L10n.string("ui.6ffae3d623e16c04"))
                        .foregroundStyle(.secondary)
                    if let networkSpeed, networkSpeed > 0 {
                        Text(L10n.string("ui.6b6dde1b911d84d4", String(describing: networkSpeedText(networkSpeed))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
            }

            if !isPreparing, failureMessage == nil, isNetworkLoading,
               let networkSpeed, networkSpeed > 0 {
                VStack {
                    HStack {
                        Spacer()
                        Label(networkSpeedText(networkSpeed), systemImage: "arrow.down.circle")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .accessibilityLabel(L10n.string("ui.076788e9cbfea3aa", String(describing: networkSpeedText(networkSpeed))))
                    }
                    Spacer()
                }
                .padding(14)
                .allowsHitTesting(false)
            }

            if let failureMessage {
                VStack(spacing: 12) {
                    Image(systemName: "video.slash")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text(L10n.string("ui.e84df95c16ea8a1f"))
                        .font(.headline)
                    Text(failureMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack {
                    Button(L10n.string("ui.b8784c8dd5636ff2")) {
                        setupPlayer()
                    }
                        Button(L10n.string("ui.d683d1f7d649b079"), action: onDownload)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .frame(maxWidth: 420)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .contain)
            }
        }
            .onAppear {
                setupPlayer()
            }
            .onDisappear {
                cleanPlayer()
            }
            .onChange(of: source.request.url) { _, _ in
                setupPlayer()
            }
    }

    private func setupPlayer() {
        cleanPlayer()
        isPreparing = true
        failureMessage = nil
        networkSpeed = nil
        isNetworkLoading = false
        let generation = UUID()
        playbackGeneration = generation

        let delegate = DsmAVAssetResourceLoaderDelegate(source: source) { message in
            Task { @MainActor in
                guard playbackGeneration == generation else { return }
                isPreparing = false
                failureMessage = message.replacingOccurrences(of: L10n.string("ui.fa33e10009759859"), with: L10n.string("ui.c20f7618d330a854"))
                player?.pause()
            }
        } onLoadingMetrics: { speed, isLoading in
            Task { @MainActor in
                guard playbackGeneration == generation else { return }
                networkSpeed = speed
                isNetworkLoading = isLoading
            }
        }
        resourceLoaderDelegate = delegate

        let suffix = source.fileExtension.map { ".\($0)" } ?? ".mp4"
        guard let assetURL = URL(string: "lanstash-media://stream/\(UUID().uuidString)\(suffix)") else {
            failureMessage = L10n.string("ui.5b623f125f236df3")
            isPreparing = false
            return
        }
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(
            delegate,
            queue: DispatchQueue(label: "io.github.qwertyuiop1995.lanstash.media-loader")
        )
        let playerItem = AVPlayerItem(asset: asset)
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer

        Task {
            do {
                let playable = try await asset.load(.isPlayable)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard playbackGeneration == generation else { return }
                    guard playable else {
                        isPreparing = false
                        failureMessage = L10n.string("ui.a9df5c3dfdbf9c18")
                        return
                    }
                    isPreparing = false
                    newPlayer.play()
                }
            } catch {
                await MainActor.run {
                    guard playbackGeneration == generation, failureMessage == nil else { return }
                    isPreparing = false
                    failureMessage = L10n.string("ui.d8af503f7d5ff85b")
                }
            }
        }
    }

    private func cleanPlayer() {
        playbackGeneration = UUID()
        player?.pause()
        player = nil
        resourceLoaderDelegate?.cancelAll()
        resourceLoaderDelegate = nil
        networkSpeed = nil
        isNetworkLoading = false
    }
}

struct VideoPlayerRepresentable: NSViewRepresentable {
    @Binding var player: AVPlayer?
    var controlsStyle: AVPlayerViewControlsStyle = .floating
    var showsFrameSteppingButtons: Bool = true
    var showsSharingServiceButton: Bool = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = controlsStyle
        view.showsFrameSteppingButtons = showsFrameSteppingButtons
        view.showsSharingServiceButton = showsSharingServiceButton
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player != player {
            view.player = player
        }
    }
}

struct AudioPlayerView: View {
    let source: MediaStreamSource
    @State private var player: AVPlayer?
    @State private var resourceLoaderDelegate: DsmAVAssetResourceLoaderDelegate?
    @State private var playbackGeneration = UUID()
    @State private var isPlaying = false
    @State private var isPreparing = true
    @State private var isSeeking = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timer: Timer?
    @State private var failureMessage: String?
    @State private var networkSpeed: Double?
    @State private var isNetworkLoading = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            
            // 音频播放精美图标
            Image(systemName: "music.note.waveform")
                .font(.system(size: 64))
                .foregroundStyle(.blue.gradient)
                .symbolEffect(.bounce, value: isPlaying)
                .accessibilityHidden(true)

            if isPreparing, failureMessage == nil {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("ui.6aa0e81ab840c508"))
                        .foregroundStyle(.secondary)
                    if let networkSpeed, networkSpeed > 0 {
                        Text(L10n.string("ui.6b6dde1b911d84d4", String(describing: networkSpeedText(networkSpeed))))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if !isPreparing, failureMessage == nil, isNetworkLoading,
               let networkSpeed, networkSpeed > 0 {
                Label(L10n.string("ui.441591bc8c8af4d4", String(describing: networkSpeedText(networkSpeed))), systemImage: "arrow.down.circle")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(L10n.string("ui.1ce1dca1fe366c40", String(describing: networkSpeedText(networkSpeed))))
            }

            if let failureMessage {
                VStack(spacing: 10) {
                    Label(L10n.string("ui.2949b071d192f28f"), systemImage: "waveform.badge.exclamationmark")
                        .font(.headline)
                    Text(failureMessage)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button(L10n.string("ui.b8784c8dd5636ff2")) {
                        setupPlayer()
                    }
                }
                .padding(.horizontal, 24)
                .accessibilityElement(children: .contain)
            }
            
            VStack(spacing: 8) {
                Slider(value: $currentTime, in: 0...max(duration, 1.0)) { editing in
                    isSeeking = editing
                    if !editing {
                        player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
                    }
                }
                .tint(.blue)
                .disabled(isPreparing || failureMessage != nil || duration <= 0)
                .accessibilityLabel(L10n.string("ui.fc16e2a0fca66884"))
                
                HStack {
                    Text(formatTime(currentTime))
                    Spacer()
                    Text(formatTime(duration))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            
            // 控制按钮
            HStack(spacing: 24) {
                Button {
                    let newTime = max(currentTime - 10, 0)
                    player?.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
                    currentTime = newTime
                } label: {
                    Image(systemName: "backward.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(isPreparing || failureMessage != nil)
                .accessibilityLabel(L10n.string("ui.6ffd3c04b1370caa"))
                
                Button {
                    if isPlaying {
                        player?.pause()
                        isPlaying = false
                    } else {
                        player?.play()
                        isPlaying = true
                    }
                } label: {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .disabled(isPreparing || failureMessage != nil)
                .accessibilityLabel(isPlaying ? L10n.string("ui.8d12fc0d4eb26021") : L10n.string("ui.c3396195e91ccdd8"))
                
                Button {
                    let newTime = min(currentTime + 10, duration)
                    player?.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
                    currentTime = newTime
                } label: {
                    Image(systemName: "forward.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(isPreparing || failureMessage != nil)
                .accessibilityLabel(L10n.string("ui.f7d78f76e1921809"))
            }
            
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            cleanPlayer()
        }
        .onChange(of: source.request.url) { _, _ in
            setupPlayer()
        }
    }

    private func setupPlayer() {
        cleanPlayer()
        isPreparing = true
        failureMessage = nil
        networkSpeed = nil
        isNetworkLoading = false
        let generation = UUID()
        playbackGeneration = generation

        let delegate = DsmAVAssetResourceLoaderDelegate(source: source) { message in
            Task { @MainActor in
                guard playbackGeneration == generation else { return }
                isPreparing = false
                failureMessage = message.replacingOccurrences(of: L10n.string("ui.fa33e10009759859"), with: L10n.string("ui.db95142124934467"))
                player?.pause()
                isPlaying = false
            }
        } onLoadingMetrics: { speed, isLoading in
            Task { @MainActor in
                guard playbackGeneration == generation else { return }
                networkSpeed = speed
                isNetworkLoading = isLoading
            }
        }
        resourceLoaderDelegate = delegate

        let suffix = source.fileExtension.map { ".\($0)" } ?? ".mp3"
        guard let assetURL = URL(string: "lanstash-media://stream/\(UUID().uuidString)\(suffix)") else {
            failureMessage = L10n.string("ui.970627a6535d2a4a")
            isPreparing = false
            return
        }
        let asset = AVURLAsset(url: assetURL)
        asset.resourceLoader.setDelegate(
            delegate,
            queue: DispatchQueue(label: "io.github.qwertyuiop1995.lanstash.audio-loader")
        )
        let playerItem = AVPlayerItem(asset: asset)
        let avPlayer = AVPlayer(playerItem: playerItem)
        self.player = avPlayer

        Task {
            do {
                async let playableValue = asset.load(.isPlayable)
                async let durationValue = asset.load(.duration)
                let (playable, loadedDuration) = try await (playableValue, durationValue)
                await MainActor.run {
                    guard playbackGeneration == generation else { return }
                    guard playable else {
                        isPreparing = false
                        failureMessage = L10n.string("ui.c90f56be41b10767")
                        return
                    }
                    let seconds = loadedDuration.seconds
                    duration = seconds.isFinite && seconds > 0 ? seconds : 0
                    isPreparing = false
                }
            } catch {
                await MainActor.run {
                    guard playbackGeneration == generation, failureMessage == nil else { return }
                    isPreparing = false
                    failureMessage = L10n.string("ui.878fa46daa32ef0f")
                }
            }
        }

        let currentPlayer = avPlayer
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak currentPlayer] _ in
            Task { @MainActor in
                if !isSeeking,
                   let current = currentPlayer?.currentTime().seconds,
                   current.isFinite {
                    currentTime = current
                }
            }
        }
    }

    private func cleanPlayer() {
        playbackGeneration = UUID()
        timer?.invalidate()
        timer = nil
        player?.pause()
        player = nil
        resourceLoaderDelegate?.cancelAll()
        resourceLoaderDelegate = nil
        networkSpeed = nil
        isNetworkLoading = false
        isPlaying = false
        isSeeking = false
        currentTime = 0
        duration = 0
    }

    private func formatTime(_ time: Double) -> String {
        guard !time.isNaN else { return "00:00" }
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

private func networkSpeedText(_ bytesPerSecond: Double) -> String {
    let formatted = ByteCountFormatter.string(
        fromByteCount: Int64(max(0, bytesPerSecond)),
        countStyle: .file
    )
    return L10n.string("ui.3b14d1af77ab3e3e", String(describing: formatted))
}

private struct LivePhotoPreviewBadgeButton: View {
    let model: WorkspaceModel
    let item: FileItem
    let videoPath: String
    @Binding var player: AVPlayer?
    @Binding var resourceLoaderDelegate: DsmAVAssetResourceLoaderDelegate?

    var body: some View {
        let isPlaying = player != nil
        Button {
            triggerLivePhoto()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isPlaying ? "livephoto.play" : "livephoto")
                    .font(.caption.weight(.bold))
                Text(L10n.string("photo.live"))
                    .font(.caption2.weight(.bold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isPlaying ? Color.accentColor : Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(isPlaying ? .white : .primary)
        }
        .buttonStyle(.plain)
        .help(L10n.string("ui.f7ed6c3484c83a67"))
    }

    private func triggerLivePhoto() {
        guard player == nil else { return }
        Task {
            do {
                let source = try await model.mediaStreamSource(
                    path: videoPath,
                    fileExtension: "mov"
                )
                guard let assetURL = URL(string: "lanstash-media://stream/\(UUID().uuidString).mov") else { return }
                let asset = AVURLAsset(url: assetURL)
                let delegate = DsmAVAssetResourceLoaderDelegate(
                    source: source,
                    onFailure: { _ in },
                    onLoadingMetrics: { _, _ in }
                )
                asset.resourceLoader.setDelegate(
                    delegate,
                    queue: DispatchQueue(label: "io.github.qwertyuiop1995.lanstash.livephoto-loader")
                )
                let playerItem = AVPlayerItem(asset: asset)
                let avPlayer = AVPlayer(playerItem: playerItem)
                avPlayer.actionAtItemEnd = .pause

                // 先异步加载 asset.isPlayable，等资源加载器拿到内容信息后再播放，
                // 避免直接 play() 让主线程等待资源信息而卡死。
                await MainActor.run {
                    resourceLoaderDelegate = delegate
                }
                let playable = try await asset.load(.isPlayable)
                guard !Task.isCancelled else {
                    await MainActor.run {
                        resourceLoaderDelegate?.cancelAll()
                        resourceLoaderDelegate = nil
                    }
                    return
                }

                await MainActor.run {
                    guard playable else {
                        resourceLoaderDelegate?.cancelAll()
                        resourceLoaderDelegate = nil
                        return
                    }
                    player = avPlayer
                    avPlayer.play()
                }

                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await MainActor.run {
                    player?.pause()
                    player = nil
                    resourceLoaderDelegate?.cancelAll()
                    resourceLoaderDelegate = nil
                }
            } catch {
                await MainActor.run {
                    player?.pause()
                    player = nil
                    resourceLoaderDelegate?.cancelAll()
                    resourceLoaderDelegate = nil
                }
            }
        }
    }
}
