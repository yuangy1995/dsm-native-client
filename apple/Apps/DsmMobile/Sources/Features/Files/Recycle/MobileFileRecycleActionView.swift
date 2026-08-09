import DsmCore
import DsmLocalization
import SwiftUI

struct MobileFileRecycleActionView: View {
    @Bindable var recycleAction: MobileFileRecycleActionModel
    let repository: any MobileFileRecycleMutating
    let didConfirm: (MobileFileRecycleActionSuccess) async -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                if let presentation = recycleAction.presentation {
                    switch presentation.phase {
                    case .confirming:
                        confirmationView(presentation)
                    case .submitting:
                        submittingView(presentation)
                    case .result:
                        resultView(presentation)
                    case .review:
                        reviewView
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(recycleAction.presentation?.phase == .submitting)
    }

    private func confirmationView(
        _ presentation: MobileFileRecycleActionPresentation
    ) -> some View {
        Form {
            Section {
                LabeledContent(L10n.string("mobile.files.recycle.source.label")) {
                    Text(presentation.source.name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(L10n.string("mobile.files.recycle.destination.label")) {
                    Text(presentation.destinationPath)
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                        .accessibilityLabel(
                            L10n.string(
                                "mobile.files.recycle.destination.accessibility",
                                presentation.destinationPath
                            )
                        )
                }
            } footer: {
                Text(message(presentation.operation))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    private func submittingView(
        _ presentation: MobileFileRecycleActionPresentation
    ) -> some View {
        VStack(spacing: 16) {
            if let fraction = presentation.progressFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel(
                        L10n.string(
                            "mobile.files.recycle.progress.accessibility",
                            workingText(presentation),
                            Int((fraction * 100).rounded())
                        )
                    )
                    .accessibilityValue(fraction.formatted(.percent.precision(.fractionLength(0))))
            } else {
                ProgressView()
                    .accessibilityLabel(workingText(presentation))
            }
            Text(workingText(presentation))
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(presentation.source.name)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: 520)
        .fillsAvailableContentArea(alignment: .center)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private func resultView(
        _ presentation: MobileFileRecycleActionPresentation
    ) -> some View {
        ContentUnavailableView {
            Label(
                feedbackTitle(presentation.feedback),
                systemImage: "exclamationmark.circle"
            )
        } description: {
            Text(feedbackMessage(presentation.feedback))
        } actions: {
            Button(L10n.string("mobile.files.recycle.feedback.close")) {
                recycleAction.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 44, minHeight: 44)
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var reviewView: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.files.recycle.review.title"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(L10n.string("mobile.files.recycle.review.message"))
        } actions: {
            Button(L10n.string("mobile.files.recycle.review.dismiss")) {
                recycleAction.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(minWidth: 44, minHeight: 44)
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(cancelTitle) {
                if recycleAction.presentation?.phase == .submitting {
                    recycleAction.requestCancellation()
                } else {
                    recycleAction.dismiss()
                }
            }
            .disabled(recycleAction.presentation?.cancellationRequested == true)
            .frame(minHeight: 44)
        }
        if recycleAction.presentation?.phase == .confirming {
            ToolbarItem(placement: .confirmationAction) {
                Button(submitTitle) { submit() }
                    .frame(minHeight: 44)
            }
        }
    }

    private var title: String {
        guard let presentation = recycleAction.presentation else { return "" }
        return L10n.string(
            presentation.operation == .moveToRecycle
                ? "mobile.files.recycle.move.title"
                : "mobile.files.recycle.restore.title",
            presentation.source.name
        )
    }

    private var submitTitle: String {
        guard let operation = recycleAction.presentation?.operation else { return "" }
        return L10n.string(
            operation == .moveToRecycle
                ? "mobile.files.recycle.move.submit"
                : "mobile.files.recycle.restore.submit"
        )
    }

    private var cancelTitle: String {
        recycleAction.presentation?.cancellationRequested == true
            ? L10n.string("mobile.files.recycle.cancelling")
            : L10n.string("mobile.files.recycle.cancel")
    }

    private func message(_ operation: MobileFileRecycleActionOperation) -> String {
        L10n.string(
            operation == .moveToRecycle
                ? "mobile.files.recycle.move.message"
                : "mobile.files.recycle.restore.message"
        )
    }

    private func workingText(_ presentation: MobileFileRecycleActionPresentation) -> String {
        if presentation.cancellationRequested {
            return L10n.string("mobile.files.recycle.cancelling")
        }
        return L10n.string(
            presentation.operation == .moveToRecycle
                ? "mobile.files.recycle.working.move"
                : "mobile.files.recycle.working.restore"
        )
    }

    private func feedbackTitle(_ feedback: MobileFileRecycleActionFeedback?) -> String {
        switch feedback {
        case .permission: L10n.string("mobile.files.recycle.permission.title")
        case .unsupported: L10n.string("mobile.files.recycle.unsupported.title")
        case .conflict: L10n.string("mobile.files.recycle.conflict.title")
        case .none: L10n.string("mobile.files.recycle.conflict.title")
        }
    }

    private func feedbackMessage(_ feedback: MobileFileRecycleActionFeedback?) -> String {
        switch feedback {
        case .permission: L10n.string("mobile.files.recycle.permission.message")
        case .unsupported: L10n.string("mobile.files.recycle.unsupported.message")
        case .conflict: L10n.string("mobile.files.recycle.conflict.message")
        case .none: L10n.string("mobile.files.recycle.conflict.message")
        }
    }

    private func submit() {
        Task {
            if let success = await recycleAction.submit(repository: repository) {
                await didConfirm(success)
            }
        }
    }
}
