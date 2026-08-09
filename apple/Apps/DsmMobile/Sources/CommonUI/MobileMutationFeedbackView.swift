import DsmCore
import SwiftUI

/// 展示层文案由调用方从双语资源注入；组件不把协议状态直接暴露给用户。
struct MobileMutationFeedbackLabels {
    let successTitle: String
    let failureTitle: String
    let reviewTitle: String
    let cancelledTitle: String
    let dismissTitle: String
}

struct MobileMutationFeedbackView: View {
    let result: MutationResult
    let labels: MobileMutationFeedbackLabels
    let message: String
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: MobileSpacing.content) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(labels.dismissTitle, action: dismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minWidth: MobileMetrics.minimumTouchTarget,
                       minHeight: MobileMetrics.minimumTouchTarget)
        }
        .padding(MobileSpacing.section)
        .fillsAvailableContentArea()
    }

    private var title: String {
        switch result.status {
        case .confirmedSuccess:
            labels.successTitle
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            labels.reviewTitle
        case .cancelledBeforeSubmission:
            labels.cancelledTitle
        case .confirmedFailure, .permissionDenied, .unsupported:
            labels.failureTitle
        }
    }

    private var systemImage: String {
        switch result.status {
        case .confirmedSuccess:
            "checkmark.circle.fill"
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            "arrow.clockwise.circle.fill"
        case .cancelledBeforeSubmission:
            "xmark.circle.fill"
        case .confirmedFailure, .permissionDenied, .unsupported:
            "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch result.status {
        case .confirmedSuccess:
            .green
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            .orange
        case .cancelledBeforeSubmission:
            .secondary
        case .confirmedFailure, .permissionDenied, .unsupported:
            .red
        }
    }
}
