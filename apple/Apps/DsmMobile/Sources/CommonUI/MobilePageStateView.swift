import SwiftUI

/// 统一承载页面的加载、空内容、筛选空、错误和正常内容五种状态。
struct MobilePageStateView<Content: View>: View {
    let state: MobilePageState
    let labels: MobilePageStateLabels
    let emptySystemImage: String
    let filteredEmptySystemImage: String
    let errorSystemImage: String
    let retryAction: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        state: MobilePageState,
        labels: MobilePageStateLabels,
        emptySystemImage: String = "tray",
        filteredEmptySystemImage: String = "line.3.horizontal.decrease.circle",
        errorSystemImage: String = "exclamationmark.triangle",
        retryAction: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.state = state
        self.labels = labels
        self.emptySystemImage = emptySystemImage
        self.filteredEmptySystemImage = filteredEmptySystemImage
        self.errorSystemImage = errorSystemImage
        self.retryAction = retryAction
        self.content = content()
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView(labels.loading)
                    .accessibilityElement(children: .combine)
            case .empty:
                ContentUnavailableView(
                    labels.emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(labels.emptyMessage)
                )
            case .filteredEmpty:
                ContentUnavailableView(
                    labels.filteredEmptyTitle,
                    systemImage: filteredEmptySystemImage,
                    description: Text(labels.filteredEmptyMessage)
                )
            case .error:
                ContentUnavailableView {
                    Label(labels.errorTitle, systemImage: errorSystemImage)
                } description: {
                    Text(labels.errorMessage)
                } actions: {
                    Button(labels.retryTitle, action: retryAction)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(minWidth: MobileMetrics.minimumTouchTarget,
                               minHeight: MobileMetrics.minimumTouchTarget)
                }
            case .content:
                content
            }
        }
        .fillsAvailableContentArea(alignment: state.layout.alignment)
        .animation(reduceMotion ? nil : MobileMotion.stateTransition, value: state)
    }
}

private extension MobilePageLayout {
    var alignment: Alignment {
        switch self {
        case .centered:
            .center
        case .topLeading:
            .topLeading
        }
    }
}

extension View {
    /// 占满页面标题栏以下的剩余区域，并明确每种页面状态的对齐方式。
    func fillsAvailableContentArea(alignment: Alignment = .center) -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}
