import DsmCore
import DsmLocalization
import SwiftUI

struct MobileFilePreviewView: View {
    let state: MobileFilePreviewState
    let mediaSource: MediaStreamSource?
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void
    let onShowDetails: () -> Void
    let onOpenFullScreen: () -> Void
    let canOpenFullScreen: Bool
    var onQuickLookDismiss: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            switch state.phase {
            case .inactive:
                inactiveView
            case .loadingDetails:
                loadingView(
                    title: L10n.string("mobile.files.preview.loading-details"),
                    showsProgress: false
                )
            case .loadingPreview:
                loadingView(
                    title: L10n.string("mobile.files.preview.loading-preview"),
                    showsProgress: true
                )
            case .detailsOnly:
                detailsOnlyView
            case .ready:
                readyView
            case .failed:
                failureView
            case .cancelled:
                cancelledView
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.phase)
        .background(Color(uiColor: .systemBackground))
    }

    private var inactiveView: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.files.preview.inactive.title"),
                systemImage: "doc"
            )
        } description: {
            Text(L10n.string("mobile.files.preview.inactive.message"))
        } actions: {
            actionButton(
                L10n.string("mobile.files.preview.action.close"),
                systemImage: "xmark",
                action: onClose
            )
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private func loadingView(title: String, showsProgress: Bool) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if showsProgress, let progressText {
                Text(progressText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            adaptiveActions {
                actionButton(
                    L10n.string("mobile.files.preview.action.cancel"),
                    systemImage: "stop.circle",
                    action: onCancel
                )
                actionButton(
                    L10n.string("mobile.files.preview.action.close"),
                    systemImage: "xmark",
                    action: onClose
                )
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailsOnlyView: some View {
        VStack(spacing: 0) {
            if state.previewKind != .unsupported || state.selectedItem?.isDirectory == false {
                Label(
                    L10n.string("mobile.files.preview.unsupported.message"),
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let item = state.details ?? state.selectedItem {
                MobileFileDetailsView(item: item)
            }
            bottomActions {
                actionButton(
                    L10n.string("mobile.files.preview.action.close"),
                    systemImage: "xmark",
                    action: onClose
                )
            }
        }
    }

    private var readyView: some View {
        VStack(spacing: 0) {
            readyContent
            bottomActions {
                actionButton(
                    L10n.string("mobile.files.preview.action.details"),
                    systemImage: "info.circle",
                    action: onShowDetails
                )
                if canOpenFullScreen {
                    actionButton(
                        L10n.string("mobile.files.preview.action.full-screen"),
                        systemImage: "arrow.up.left.and.arrow.down.right",
                        action: onOpenFullScreen
                    )
                }
                actionButton(
                    L10n.string("mobile.files.preview.action.close"),
                    systemImage: "xmark",
                    action: onClose
                )
            }
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        let item = state.details ?? state.selectedItem
        switch state.content {
        case .quickLook:
            if let url = state.artifactURL, let item {
                MobileQuickLookPreview(
                    localURL: url,
                    title: item.name,
                    onDismiss: onQuickLookDismiss
                )
                .accessibilityLabel(item.name)
            } else {
                failureContent
            }
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
            }
            .fillsAvailableContentArea(alignment: .topLeading)
        case .emptyText:
            previewUnavailable(
                title: L10n.string("mobile.files.preview.text.empty.title"),
                message: L10n.string("mobile.files.preview.text.empty.message"),
                systemImage: "doc.plaintext"
            )
        case .textTooLarge:
            previewUnavailable(
                title: L10n.string("mobile.files.preview.text.too-large.title"),
                message: L10n.string("mobile.files.preview.text.too-large.message"),
                systemImage: "doc.badge.ellipsis"
            )
        case .textSizeUnknown:
            previewUnavailable(
                title: L10n.string("mobile.files.preview.text.too-large.title"),
                message: L10n.string("mobile.files.preview.text.size-unknown.message"),
                systemImage: "doc.badge.questionmark"
            )
        case .textEncodingUnsupported:
            previewUnavailable(
                title: L10n.string("mobile.files.preview.text.encoding.title"),
                message: L10n.string("mobile.files.preview.text.encoding.message"),
                systemImage: "doc.badge.xmark"
            )
        case .media:
            if let mediaSource, let item {
                MobileMediaPlayer(source: mediaSource, title: item.name)
            } else {
                failureContent
            }
        case .none:
            failureContent
        }
    }

    private func previewUnavailable(
        title: String,
        message: String,
        systemImage: String
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var failureView: some View {
        VStack(spacing: 0) {
            failureContent
            bottomActions {
                if state.details ?? state.selectedItem != nil {
                    actionButton(
                        L10n.string("mobile.files.preview.action.details"),
                        systemImage: "info.circle",
                        action: onShowDetails
                    )
                }
                actionButton(
                    L10n.string("mobile.files.preview.action.retry"),
                    systemImage: "arrow.clockwise",
                    action: onRetry,
                    prominent: true
                )
                actionButton(
                    L10n.string("mobile.files.preview.action.close"),
                    systemImage: "xmark",
                    action: onClose
                )
            }
        }
    }

    private var failureContent: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.files.preview.failed.title"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(failureMessage)
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var cancelledView: some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label(
                    L10n.string("mobile.files.preview.cancelled.title"),
                    systemImage: "stop.circle"
                )
            } description: {
                Text(L10n.string("mobile.files.preview.cancelled.message"))
            }
            .fillsAvailableContentArea(alignment: .center)
            bottomActions {
                if state.details ?? state.selectedItem != nil {
                    actionButton(
                        L10n.string("mobile.files.preview.action.details"),
                        systemImage: "info.circle",
                        action: onShowDetails
                    )
                }
                actionButton(
                    L10n.string("mobile.files.preview.action.retry"),
                    systemImage: "arrow.clockwise",
                    action: onRetry,
                    prominent: true
                )
                actionButton(
                    L10n.string("mobile.files.preview.action.close"),
                    systemImage: "xmark",
                    action: onClose
                )
            }
        }
    }

    private var progressText: String? {
        guard let progress = state.progress else { return nil }
        let completed = formattedBytes(progress.completedBytes)
        if let total = progress.totalBytes {
            return L10n.string(
                "mobile.files.preview.progress.bytes-total",
                completed,
                formattedBytes(total)
            )
        }
        return L10n.string("mobile.files.preview.progress.bytes", completed)
    }

    private var failureMessage: String {
        switch state.previewFailure ?? state.detailsFailure {
        case .authenticationRequired:
            L10n.string("mobile.files.preview.failure.authentication")
        case .otpRequired:
            L10n.string("mobile.files.preview.failure.otp")
        case .permissionDenied:
            L10n.string("mobile.files.preview.failure.permission")
        case .networkUnavailable, .timeout:
            L10n.string("mobile.files.preview.failure.network")
        case .localStorageFull:
            L10n.string("mobile.files.preview.failure.local-space")
        case .notFound:
            L10n.string("mobile.files.preview.failure.not-found")
        case .apiUnavailable, .versionUnsupported, .serverBusy:
            L10n.string("mobile.files.preview.failure.unavailable")
        default:
            L10n.string("mobile.files.preview.failure.unknown")
        }
    }

    @ViewBuilder
    private func adaptiveActions<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 8, content: content)
        } else {
            HStack(spacing: 8, content: content)
        }
    }

    private func bottomActions<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        adaptiveActions(content: content)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void,
        prominent: Bool = false
    ) -> some View {
        let button = Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatStyle(style: .file)
            .locale(L10n.locale)
            .format(bytes)
    }
}
