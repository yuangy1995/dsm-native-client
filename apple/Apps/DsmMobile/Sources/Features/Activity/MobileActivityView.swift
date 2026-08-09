import DsmLocalization
import SwiftUI

struct MobileActivityView: View {
    @Bindable var model: MobileAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tasks: [MobileActivityTask] = []
    @State private var filter = MobileActivityFilter.all
    @State private var isLoading = true
    @State private var hasError = false

    private var visibleTasks: [MobileActivityTask] {
        tasks.filter(filter.includes)
    }

    private var state: MobileActivityPresentationState {
        .resolve(
            isLoading: isLoading,
            hasError: hasError,
            allTasks: tasks,
            visibleTasks: visibleTasks,
            filter: filter
        )
    }

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView(L10n.string("mobile.activity.loading"))
                    .accessibilityElement(children: .combine)
                    .fillsAvailableContentArea()
            case .empty:
                ContentUnavailableView(
                    L10n.string("ui.d01c644a2d1f3570"),
                    systemImage: "arrow.up.arrow.down",
                    description: Text(L10n.string("ui.c8066901cae15044"))
                )
                .fillsAvailableContentArea()
            case .filteredEmpty:
                ContentUnavailableView {
                    Label(
                        L10n.string("ui.e8c286bbf6e5bd12"),
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                } description: {
                    Text(L10n.string("mobile.activity.filtered-empty-message"))
                } actions: {
                    Button(L10n.string("background-tasks.show-all")) {
                        filter = .all
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: MobileMetrics.minimumTouchTarget)
                }
                .fillsAvailableContentArea()
            case .error:
                ContentUnavailableView {
                    Label(
                        L10n.string("mobile.activity.error-title"),
                        systemImage: "exclamationmark.triangle"
                    )
                } description: {
                    Text(L10n.string("mobile.activity.error-message"))
                } actions: {
                    Button(L10n.string("background-tasks.retry")) {
                        Task { await refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minHeight: MobileMetrics.minimumTouchTarget)
                }
                .fillsAvailableContentArea()
            case .content:
                taskList
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !tasks.isEmpty {
                filterPicker
            }
        }
        .animation(reduceMotion ? nil : MobileMotion.stateTransition, value: state)
        .task(id: model.activeProfile?.id) {
            await observeCurrentProfile()
        }
    }

    private var filterPicker: some View {
        Picker(L10n.string("mobile.activity.filter-label"), selection: $filter) {
            Text(L10n.string("background-tasks.filter-all"))
                .tag(MobileActivityFilter.all)
            Text(L10n.string("background-tasks.filter-active"))
                .tag(MobileActivityFilter.inProgress)
            Text(L10n.string("background-tasks.filter-finished"))
                .tag(MobileActivityFilter.ended)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, MobileSpacing.content)
        .padding(.vertical, MobileSpacing.controlGap)
        .background(.bar)
    }

    private var taskList: some View {
        List {
            taskSection(source: .app)
            taskSection(source: .nas)
        }
        .listStyle(.insetGrouped)
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    @ViewBuilder
    private func taskSection(source: MobileActivitySource) -> some View {
        let sourceTasks = visibleTasks.filter { $0.source == source }
        if !sourceTasks.isEmpty {
            Section {
                ForEach(sourceTasks) { task in
                    MobileActivityTaskRow(
                        task: task,
                        usesWideLayout: horizontalSizeClass == .regular,
                        cancel: { cancel(task.id) },
                        retry: { retry(task.id) }
                    )
                }
            } header: {
                Label(source.title, systemImage: source.systemImage)
            }
        }
    }

    private func observeCurrentProfile() async {
        isLoading = true
        hasError = false
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func refresh() async {
        guard let profileID = model.activeProfile?.id else {
            tasks = []
            isLoading = false
            hasError = false
            return
        }
        tasks = await model.transferCoordinator.tasks(profileID: profileID)
        isLoading = false
        hasError = false
    }

    private func cancel(_ id: UUID) {
        Task {
            await model.transferCoordinator.cancel(id)
            await refresh()
        }
    }

    private func retry(_ id: UUID) {
        guard let repository = model.fileRepository else {
            hasError = true
            return
        }
        let service = MobileFileTransferService(repository: repository)
        Task {
            await model.transferCoordinator.retryFromBeginning(id, using: service)
            await refresh()
        }
    }
}

private struct MobileActivityTaskRow: View {
    let task: MobileActivityTask
    let usesWideLayout: Bool
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: MobileSpacing.controlGap) {
            if usesWideLayout {
                HStack(alignment: .firstTextBaseline, spacing: MobileSpacing.content) {
                    identity
                    Spacer(minLength: MobileSpacing.content)
                    statusLabel
                }
            } else {
                identity
                statusLabel
            }
            progress
            if task.status == .resultNeedsReview {
                Label(
                    L10n.string("mobile.activity.review-message"),
                    systemImage: "exclamationmark.magnifyingglass"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            action
        }
        .padding(.vertical, MobileSpacing.compact)
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        Label {
            VStack(alignment: .leading, spacing: MobileSpacing.compact) {
                Text(task.displayName)
                    .font(.headline)
                    .lineLimit(2)
                Text(task.direction.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: task.direction.systemImage)
                .foregroundStyle(.tint)
                .frame(width: 28)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLabel: some View {
        Label(task.status.title, systemImage: task.status.systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(task.status.foregroundStyle)
            .accessibilityLabel(
                L10n.string("mobile.activity.status-accessibility", task.status.title)
            )
    }

    @ViewBuilder
    private var progress: some View {
        if task.status.showsProgress {
            VStack(alignment: .leading, spacing: MobileSpacing.compact) {
                if let fraction = task.progress.fraction {
                    ProgressView(value: fraction)
                    Text(
                        L10n.string(
                            "mobile.activity.bytes-progress",
                            task.progress.completedBytes.formatted(.byteCount(style: .file)),
                            (task.progress.totalBytes ?? 0).formatted(.byteCount(style: .file))
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    if task.progress.completedBytes > 0 {
                        Text(
                            L10n.string(
                                "mobile.activity.bytes-processed",
                                task.progress.completedBytes.formatted(.byteCount(style: .file))
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var action: some View {
        if task.canCancel {
            Button(role: .cancel, action: cancel) {
                Label(L10n.string("desktopDrive.cancel"), systemImage: "xmark.circle")
                    .frame(minHeight: MobileMetrics.minimumTouchTarget)
            }
            .buttonStyle(.bordered)
            .disabled(task.status == .cancelling)
        } else if task.canRetryFromBeginning {
            Button(action: retry) {
                Label(
                    L10n.string("mobile.activity.retry-from-beginning"),
                    systemImage: "arrow.counterclockwise"
                )
                .frame(minHeight: MobileMetrics.minimumTouchTarget)
            }
            .buttonStyle(.bordered)
        }
    }
}

private extension MobileActivitySource {
    var title: String {
        switch self {
        case .app: L10n.string("background-tasks.source-app")
        case .nas: L10n.string("background-tasks.source-nas")
        }
    }

    var systemImage: String {
        switch self {
        case .app: "iphone"
        case .nas: "externaldrive"
        }
    }
}

private extension MobileTransferDirection {
    var title: String {
        switch self {
        case .upload: L10n.string("mobile.activity.direction-upload")
        case .download: L10n.string("mobile.activity.direction-download")
        }
    }

    var systemImage: String {
        switch self {
        case .upload: "arrow.up.circle"
        case .download: "arrow.down.circle"
        }
    }
}

private extension MobileTransferStatus {
    var title: String {
        switch self {
        case .queued: L10n.string("mobile.activity.status-queued")
        case .preparing: L10n.string("mobile.activity.status-preparing")
        case .running: L10n.string("mobile.activity.status-running")
        case .cancelling: L10n.string("mobile.activity.status-cancelling")
        case .succeeded: L10n.string("mobile.activity.status-succeeded")
        case .failed: L10n.string("mobile.activity.status-failed")
        case .cancelledBeforeSubmission:
            L10n.string("mobile.activity.status-cancelled-before-submission")
        case .cancelled: L10n.string("mobile.activity.status-cancelled")
        case .resultNeedsReview: L10n.string("mobile.activity.status-result-needs-review")
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .preparing: "ellipsis.circle"
        case .running: "arrow.triangle.2.circlepath"
        case .cancelling: "xmark.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelledBeforeSubmission, .cancelled: "minus.circle"
        case .resultNeedsReview: "exclamationmark.magnifyingglass"
        }
    }

    var foregroundStyle: Color {
        switch self {
        case .succeeded: .green
        case .failed: .red
        case .resultNeedsReview: .orange
        case .queued, .preparing, .running, .cancelling, .cancelledBeforeSubmission, .cancelled:
            .secondary
        }
    }

    var showsProgress: Bool {
        switch self {
        case .preparing, .running, .cancelling:
            true
        case .queued, .succeeded, .failed, .cancelledBeforeSubmission, .cancelled,
             .resultNeedsReview:
            false
        }
    }
}

private extension MobileActivityTask {
    var displayName: String {
        let name = (stableTarget as NSString).lastPathComponent
        return name.isEmpty ? stableTarget : name
    }
}
