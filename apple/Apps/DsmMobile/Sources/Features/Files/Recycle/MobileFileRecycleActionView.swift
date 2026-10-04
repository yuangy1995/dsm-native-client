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
                        if presentation.isBatch { batchResultView(presentation) } else { resultView(presentation) }
                    case .review:
                        if presentation.isBatch { batchResultView(presentation) } else { reviewView }
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
                ForEach(presentation.itemStates, id: \.source.path) { entry in
                    Text(entry.source.name).multilineTextAlignment(.leading)
                    if !entry.destinationPath.isEmpty {
                        LabeledContent(L10n.string("mobile.files.recycle.destination.label")) {
                            Text(entry.destinationPath).font(.body.monospaced()).multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                                .accessibilityLabel(L10n.string("mobile.files.recycle.destination.accessibility", entry.destinationPath))
                        }
                    }
                }
            } footer: {
                Text(message(presentation))
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
            Text(presentation.currentSource.name)
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

    private func batchResultView(_ presentation: MobileFileRecycleActionPresentation) -> some View {
        List {
            Section {
                Text(L10n.string("mobile.files.copy-move.batch.summary", Int64(presentation.count(.confirmed)),
                    Int64(presentation.count(.failed)), Int64(presentation.count(.pendingReview)),
                    Int64(presentation.count(.cancelled)), Int64(presentation.count(.notStarted))))
                    .accessibilityIdentifier("files.recycle.summary")
                if presentation.count(.failed) > 0 { Text(feedbackMessage(presentation.itemStates.first { $0.status == .failed }?.feedback)) }
                if presentation.phase == .review {
                    Text(L10n.string(presentation.feedback == .recovery
                        ? "mobile.files.recycle.recovery.message" : "mobile.files.recycle.review.message"))
                }
            }
            Section {
                ForEach(presentation.itemStates, id: \.source.path) { entry in
                    LabeledContent(entry.source.name) { Text(itemStatus(entry)) }
                }
            }
        }.fillsAvailableContentArea(alignment: .topLeading)
    }

    private func itemStatus(_ entry: MobileFileRecycleItemState) -> String {
        let key: String
        switch entry.status {
        case .confirmed: key = "mobile.files.copy-move.batch.item.completed"
        case .notStarted: key = "mobile.files.copy-move.batch.item.not-started"
        case .cancelled: key = "mobile.files.copy-move.batch.issue.cancelled"
        case .pendingReview: key = "mobile.files.copy-move.batch.item.unavailable"
        case .submitting: key = "mobile.files.recycle.working.restore"
        case .failed: return feedbackTitle(entry.feedback)
        }
        return L10n.string(key)
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
            Text(L10n.string(recycleAction.presentation?.feedback == .recovery ? "mobile.files.recycle.recovery.message" : "mobile.files.recycle.review.message"))
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
            .disabled(recycleAction.presentation?.phase == .submitting && recycleAction.presentation?.cancellationRequested == true)
            .frame(minHeight: 44)
        }
        if recycleAction.presentation?.phase == .confirming {
            ToolbarItem(placement: .confirmationAction) {
                Button(submitTitle, role: recycleAction.presentation?.operation == .restoreFromRecycle ? nil : .destructive) { submit() }
                    .tint(recycleAction.presentation?.operation == .restoreFromRecycle ? Color.accentColor : Color.red)
                    .accessibilityIdentifier("files.recycle.submit")
                    .frame(minHeight: 44)
            }
        }
    }

    private var title: String {
        guard let presentation = recycleAction.presentation else { return "" }
        if presentation.isBatch, presentation.phase == .result || presentation.phase == .review {
            return L10n.string("mobile.files.recycle.results.title")
        }
        if presentation.isBatch {
            return L10n.string(presentation.operation == .restoreFromRecycle
                ? "mobile.files.recycle.batch.restore.title" : "mobile.files.recycle.batch.delete.title",
                Int64(presentation.itemStates.count))
        }
        if presentation.operation == .delete { return L10n.string("mobile.files.recycle.delete.title", presentation.source.name) }
        return L10n.string(
            presentation.operation == .moveToRecycle
                ? "mobile.files.recycle.move.title"
                : "mobile.files.recycle.restore.title",
            presentation.source.name
        )
    }

    private var submitTitle: String {
        guard let operation = recycleAction.presentation?.operation else { return "" }
        if operation == .delete { return L10n.string("mobile.files.recycle.delete.submit") }
        return L10n.string(
            operation == .moveToRecycle
                ? "mobile.files.recycle.move.submit"
                : "mobile.files.recycle.restore.submit"
        )
    }

    private var cancelTitle: String {
        if recycleAction.presentation?.phase == .result || recycleAction.presentation?.phase == .review {
            return L10n.string("mobile.files.recycle.feedback.close")
        }
        return recycleAction.presentation?.cancellationRequested == true
            ? L10n.string("mobile.files.recycle.cancelling")
            : L10n.string("mobile.files.recycle.cancel")
    }

    private func message(_ presentation: MobileFileRecycleActionPresentation) -> String {
        let key: String
        switch (presentation.operation, presentation.source.kind) {
        case (.delete, _):
            key = presentation.itemStates.contains { $0.source.isRecyclePath }
                ? "mobile.files.recycle.delete.permanent.message" : "mobile.files.recycle.delete.message"
        case (.moveToRecycle, .directory):
            key = "mobile.files.recycle.move.folder.message"
        case (.restoreFromRecycle, .directory):
            key = "mobile.files.recycle.restore.folder.message"
        case (.moveToRecycle, _):
            key = "mobile.files.recycle.move.message"
        case (.restoreFromRecycle, _):
            key = "mobile.files.recycle.restore.message"
        }
        return L10n.string(key)
    }

    private func workingText(_ presentation: MobileFileRecycleActionPresentation) -> String {
        if presentation.cancellationRequested {
            return L10n.string("mobile.files.recycle.cancelling")
        }
        return L10n.string(
            presentation.operation != .restoreFromRecycle
                ? "mobile.files.recycle.working.move"
                : "mobile.files.recycle.working.restore"
        )
    }

    private func feedbackTitle(_ feedback: MobileFileRecycleActionFeedback?) -> String {
        switch feedback {
        case .failed: L10n.string("mobile.files.recycle.failed.title")
        case .recovery: L10n.string("mobile.files.recycle.recovery.title")
        case .permission: L10n.string("mobile.files.recycle.permission.title")
        case .unsupported: L10n.string("mobile.files.recycle.unsupported.title")
        case .conflict: L10n.string("mobile.files.recycle.conflict.title")
        case .none: L10n.string("mobile.files.recycle.conflict.title")
        }
    }

    private func feedbackMessage(_ feedback: MobileFileRecycleActionFeedback?) -> String {
        switch feedback {
        case .failed: L10n.string("mobile.files.recycle.failed.message")
        case .recovery: L10n.string("mobile.files.recycle.recovery.message")
        case .permission: L10n.string("mobile.files.recycle.permission.message")
        case .unsupported: L10n.string("mobile.files.recycle.unsupported.message")
        case .conflict: L10n.string("mobile.files.recycle.conflict.message")
        case .none: L10n.string("mobile.files.recycle.conflict.message")
        }
    }

    private func submit() {
        let activation = recycleAction.activation
        Task {
            if let success = await recycleAction.submit(repository: repository, expectedActivation: activation) {
                await didConfirm(success)
            }
        }
    }
}
