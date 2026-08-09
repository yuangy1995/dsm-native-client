import DsmCore
import DsmLocalization
import SwiftUI

struct MobileFileCopyMoveView: View {
    @Bindable var copyMove: MobileFileCopyMoveModel
    let repository: any MobileFileCopyMoving
    let didConfirm: (MobileFileCopyMoveSuccess) async -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            Group {
                if let presentation = copyMove.presentation {
                    switch presentation.phase {
                    case .review:
                        reviewView
                    case .submitting:
                        submittingView(presentation)
                    case .browsing, .loadingDestination:
                        destinationBrowser(presentation)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .interactiveDismissDisabled(copyMove.presentation?.phase == .submitting)
    }

    private func destinationBrowser(
        _ presentation: MobileFileCopyMovePresentation
    ) -> some View {
        VStack(spacing: 0) {
            destinationHeader(presentation)
            MobilePageStateView(
                state: presentation.phase == .loadingDestination
                    ? .loading
                    : presentation.destination.pageState,
                labels: destinationLabels,
                emptySystemImage: "folder",
                retryAction: retry
            ) {
                folderList(presentation)
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    private func destinationHeader(
        _ presentation: MobileFileCopyMovePresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("mobile.files.copy-move.destination.label"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(destinationDisplayPath(presentation.destination.path))
                .font(.body.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(
                    L10n.string(
                        "mobile.files.copy-move.destination.accessibility",
                        destinationDisplayPath(presentation.destination.path)
                    )
                )
            if let feedback = presentation.feedback {
                Label(feedbackMessage(feedback), systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(feedbackMessage(feedback))
            }
            if presentation.destination.hasRefreshError {
                Label(
                    L10n.string("mobile.files.copy-move.error.message"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func folderList(_ presentation: MobileFileCopyMovePresentation) -> some View {
        List {
            ForEach(presentation.destination.folders) { folder in
                Button {
                    copyMove.openFolder(folder, repository: repository)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)
                        Text(folder.name)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(folder.name)
                .accessibilityValue(folder.path)
                .accessibilityHint(L10n.string("mobile.files.copy-move.folder.hint"))
            }

            if presentation.destination.loadMoreFailed {
                VStack(spacing: 8) {
                    Label(
                        L10n.string("mobile.files.copy-move.more.error"),
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Button(L10n.string("mobile.files.copy-move.retry"), action: loadMore)
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                }
                .frame(maxWidth: .infinity)
            } else if presentation.destination.isLoadingMore {
                ProgressView(L10n.string("mobile.files.copy-move.loading"))
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else if presentation.destination.hasMore {
                Button(L10n.string("mobile.files.copy-move.more"), action: loadMore)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        }
        .listStyle(.plain)
    }

    private func submittingView(
        _ presentation: MobileFileCopyMovePresentation
    ) -> some View {
        VStack(spacing: 16) {
            if let fraction = presentation.progressFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel(
                        L10n.string(
                            "mobile.files.copy-move.progress.accessibility",
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

    private var reviewView: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.files.copy-move.review.title"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(L10n.string("mobile.files.copy-move.review.message"))
        } actions: {
            Button(L10n.string("mobile.files.copy-move.review.dismiss")) {
                copyMove.dismiss()
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
                if copyMove.presentation?.phase == .submitting {
                    copyMove.requestCancellation()
                } else {
                    copyMove.dismiss()
                }
            }
            .disabled(copyMove.presentation?.cancellationRequested == true)
            .frame(minHeight: 44)
        }
        if let presentation = copyMove.presentation,
           presentation.phase == .browsing || presentation.phase == .loadingDestination {
            ToolbarItemGroup(placement: .topBarLeading) {
                if !presentation.destination.history.isEmpty {
                    Button {
                        copyMove.goBack(repository: repository)
                    } label: {
                        Image(systemName: "chevron.backward")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(presentation.phase != .browsing)
                    .accessibilityLabel(L10n.string("mobile.files.copy-move.back"))
                }
                if !presentation.destination.path.isEmpty {
                    Button {
                        copyMove.goUp(repository: repository)
                    } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(presentation.phase != .browsing)
                    .accessibilityLabel(L10n.string("mobile.files.copy-move.up"))
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(confirmTitle(presentation.operation)) { submit() }
                    .disabled(
                        presentation.phase != .browsing ||
                        presentation.destination.path.isEmpty ||
                        presentation.destination.path == presentation.sourceParentPath
                    )
                    .frame(minHeight: 44)
            }
        }
    }

    private var title: String {
        guard let presentation = copyMove.presentation else { return "" }
        return L10n.string(
            presentation.operation == .copy
                ? "mobile.files.copy-move.copy.title"
                : "mobile.files.copy-move.move.title",
            presentation.source.name
        )
    }

    private var cancelTitle: String {
        copyMove.presentation?.cancellationRequested == true
            ? L10n.string("mobile.files.copy-move.cancelling")
            : L10n.string("mobile.files.copy-move.cancel")
    }

    private var destinationLabels: MobilePageStateLabels {
        MobilePageStateLabels(
            loading: L10n.string("mobile.files.copy-move.loading"),
            emptyTitle: L10n.string("mobile.files.copy-move.empty.title"),
            emptyMessage: L10n.string("mobile.files.copy-move.empty.message"),
            filteredEmptyTitle: L10n.string("mobile.files.copy-move.empty.title"),
            filteredEmptyMessage: L10n.string("mobile.files.copy-move.empty.message"),
            errorTitle: L10n.string("mobile.files.copy-move.error.title"),
            errorMessage: L10n.string("mobile.files.copy-move.error.message"),
            retryTitle: L10n.string("mobile.files.copy-move.retry")
        )
    }

    private func destinationDisplayPath(_ path: String) -> String {
        path.isEmpty ? L10n.string("mobile.files.copy-move.shares.title") : path
    }

    private func confirmTitle(_ operation: FileCopyMoveOperation) -> String {
        return L10n.string(
            operation == .copy
                ? "mobile.files.copy-move.copy.confirm"
                : "mobile.files.copy-move.move.confirm"
        )
    }

    private func workingText(_ presentation: MobileFileCopyMovePresentation) -> String {
        if presentation.cancellationRequested {
            return L10n.string("mobile.files.copy-move.cancelling")
        }
        return L10n.string(
            presentation.operation == .copy
                ? "mobile.files.copy-move.working.copy"
                : "mobile.files.copy-move.working.move"
        )
    }

    private func feedbackMessage(_ feedback: MobileFileCopyMoveFeedback) -> String {
        switch feedback {
        case .permission: L10n.string("mobile.files.copy-move.permission")
        case .unsupported: L10n.string("mobile.files.copy-move.unsupported")
        case .conflict: L10n.string("mobile.files.copy-move.conflict")
        case .invalidDestination: L10n.string("mobile.files.copy-move.destination.invalid")
        }
    }

    private func retry() { copyMove.retry(repository: repository) }
    private func loadMore() { copyMove.loadMore(repository: repository) }
    private func submit() {
        Task {
            if let success = await copyMove.submit(repository: repository) {
                await didConfirm(success)
            }
        }
    }
}
