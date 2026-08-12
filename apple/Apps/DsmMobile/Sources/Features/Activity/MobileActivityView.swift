import DsmLocalization
import SwiftUI

struct MobileActivityView: View {
    @Bindable var model: MobileAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var tasks: [MobileActivityTask] = []
    @State private var filter = MobileActivityFilter.all
    @State private var isLoading = true
    @State private var hasError = false
    @State private var fileActivityModel: MobileFileActivityModel

    init(model: MobileAppModel) {
        self.model = model
        _fileActivityModel = State(
            initialValue: MobileFileActivityModel(coordinator: model.transferCoordinator)
        )
    }

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

    private var activityContext: MobileActivityContext {
        MobileActivityContext(
            profileID: model.activeProfile?.id,
            repository: model.fileRepository.map(ObjectIdentifier.init),
            scenePhase: scenePhase
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
                        Task { await refreshFileActivity() }
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
        .task(id: activityContext) {
            guard scenePhase == .active else {
                fileActivityModel.cancelRefresh()
                return
            }
            await observeCurrentProfile()
        }
        .onDisappear {
            fileActivityModel.cancelRefresh()
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
            fileActivityNotices
            taskSection(source: .app)
            taskSection(source: .nas)
        }
        .listStyle(.insetGrouped)
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    @ViewBuilder
    private var fileActivityNotices: some View {
        if fileActivityModel.isLoading {
            Section {
                HStack(spacing: MobileSpacing.controlGap) {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("mobile.activity.nas-loading"))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        if fileActivityModel.error != nil {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: MobileSpacing.compact) {
                        Text(L10n.string("mobile.activity.nas-error-title"))
                            .font(.headline)
                        Text(L10n.string("mobile.activity.nas-error-message"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Button(L10n.string("background-tasks.retry")) {
                    Task { await refreshFileActivity() }
                }
                .frame(minHeight: MobileMetrics.minimumTouchTarget)
            }
        }
        if fileActivityModel.isTruncated {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: MobileSpacing.compact) {
                        Text(L10n.string("mobile.activity.nas-truncated-title"))
                            .font(.headline)
                        Text(L10n.string("mobile.activity.nas-truncated-message"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "list.bullet.rectangle")
                }
                .accessibilityElement(children: .combine)
            }
        }
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
        await fileActivityModel.activate(
            profileID: model.activeProfile?.id,
            repository: model.fileRepository
        )
        await refresh()
        var localRefreshes = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refresh()
            localRefreshes += 1
            if localRefreshes == 120 {
                localRefreshes = 0
                await refreshFileActivity()
            }
        }
    }

    private func refreshFileActivity() async {
        await fileActivityModel.refresh()
        await refresh()
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
        hasError = fileActivityModel.error != nil && tasks.isEmpty
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

private struct MobileActivityContext: Hashable {
    let profileID: UUID?
    let repository: ObjectIdentifier?
    let scenePhase: ScenePhase
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
                    task.operation.isFileStationTask
                        ? L10n.string("mobile.activity.file-finished-message")
                        : L10n.string("mobile.activity.review-message"),
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
                if !task.operation.isFileStationTask {
                    Text(task.operation.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: task.operation.systemImage)
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
                    progressLabel
                } else {
                    ProgressView()
                        .controlSize(.small)
                    progressLabel
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var progressLabel: some View {
        if let totalBytes = task.progress.totalBytes, totalBytes > 0 {
            Text(
                L10n.string(
                    task.operation.isFileStationTask
                        ? "mobile.activity.bytes-work-progress"
                        : "mobile.activity.bytes-progress",
                    task.progress.completedBytes.formatted(.byteCount(style: .file)),
                    totalBytes.formatted(.byteCount(style: .file))
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if task.progress.completedBytes > 0 {
            Text(
                L10n.string(
                    task.operation.isFileStationTask
                        ? "mobile.activity.bytes-work-processed"
                        : "mobile.activity.bytes-processed",
                    task.progress.completedBytes.formatted(.byteCount(style: .file))
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let totalItems = task.progress.totalItems, totalItems > 0 {
            Text(
                L10n.string(
                    "mobile.activity.items-progress",
                    Int64(task.progress.completedItems ?? 0),
                    Int64(totalItems)
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if let completedItems = task.progress.completedItems, completedItems > 0 {
            Text(L10n.string("mobile.activity.items-processed", Int64(completedItems)))
                .font(.caption)
                .foregroundStyle(.secondary)
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

private extension MobileActivityOperation {
    var title: String {
        switch self {
        case .appUpload: L10n.string("mobile.activity.direction-upload")
        case .appDownload: L10n.string("mobile.activity.direction-download")
        case .downloadStation: L10n.string("mobile.activity.operation-download-station")
        case .fileCopyMove: L10n.string("mobile.activity.operation-file-copy-move")
        case .fileDelete: L10n.string("mobile.activity.operation-file-delete")
        case .fileCompress: L10n.string("mobile.activity.operation-file-compress")
        case .fileExtract: L10n.string("mobile.activity.operation-file-extract")
        }
    }

    var systemImage: String {
        switch self {
        case .appUpload: "arrow.up.circle"
        case .appDownload, .downloadStation: "arrow.down.circle"
        case .fileCopyMove: "doc.on.doc"
        case .fileDelete: "trash"
        case .fileCompress: "archivebox"
        case .fileExtract: "archivebox.fill"
        }
    }
}

private extension MobileTransferStatus {
    var title: String {
        switch self {
        case .queued: L10n.string("mobile.activity.status-queued")
        case .preparing: L10n.string("mobile.activity.status-preparing")
        case .running: L10n.string("mobile.activity.status-running")
        case .paused: L10n.string("mobile.activity.status-paused")
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
        case .paused: "pause.circle"
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
        case .queued, .preparing, .running, .paused, .cancelling, .cancelledBeforeSubmission,
             .cancelled:
            .secondary
        }
    }

    var showsProgress: Bool {
        switch self {
        case .preparing, .running, .paused, .cancelling:
            true
        case .queued, .succeeded, .failed, .cancelledBeforeSubmission, .cancelled,
             .resultNeedsReview:
            false
        }
    }
}

private extension MobileActivityTask {
    var displayName: String {
        if operation.isFileStationTask {
            return operation.title
        }
        let name = (stableTarget as NSString).lastPathComponent
        return name.isEmpty ? stableTarget : name
    }
}
