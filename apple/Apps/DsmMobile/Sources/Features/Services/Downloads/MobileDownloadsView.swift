import DsmCore
import DsmLocalization
import SwiftUI
import UniformTypeIdentifiers

struct MobileDownloadsView: View {
    @Bindable var model: MobileDownloadsModel
    @State private var selectedTask: DownloadStationTask?
    @State private var isShowingCreateTask = false
    @State private var isShowingBTSearch = false
    @State private var isImportingTaskFile = false
    @State private var isSelectingTasks = false
    @State private var isShowingControls = false

    var body: some View {
        MobilePageStateView(
            state: model.downloadPageState,
            labels: MobilePageStateLabels(
                loading: L10n.string("ui.86b6d0d63062ba81"),
                emptyTitle: L10n.string("ui.e0c9f46a0d2db5c0"),
                emptyMessage: L10n.string("download.workspace.empty-hint"),
                filteredEmptyTitle: L10n.string("ui.e0c9f46a0d2db5c0"),
                filteredEmptyMessage: L10n.string("download.workspace.filtered-hint"),
                errorTitle: L10n.string("ui.0bc1fb72ae1be5c5"),
                errorMessage: model.message ?? L10n.string("ui.38245f0b3e213b62"),
                retryTitle: L10n.string("ui.7bdd5ce1e298a972")
            ),
            emptySystemImage: "arrow.down.circle",
            retryAction: model.reloadDownloads
        ) {
            taskList
        }
        .accessibilityElement(children: .contain)
        .searchable(text: $model.searchText, prompt: L10n.string("download.workspace.search"))
        .refreshable { await model.load() }
        .sheet(item: $selectedTask) { task in
            MobileDownloadTaskDetailView(model: model, initialTask: task)
        }
        .sheet(isPresented: $isShowingCreateTask) {
            MobileDownloadCreateTaskView(model: model)
        }
        .sheet(isPresented: $isShowingBTSearch) {
            MobileDownloadBTSearchView(model: model)
        }
        .sheet(isPresented: $isSelectingTasks) { MobileDownloadSelectionSheet(model: model) }
        .sheet(isPresented: $isShowingControls) { MobileDownloadControlRecordsView(model: model) }
        .fileImporter(
            isPresented: $isImportingTaskFile,
            allowedContentTypes: mobileDownloadTaskFileTypes,
            allowsMultipleSelection: false,
            onCompletion: handleTaskFileImport
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { isSelectingTasks = true } label: {
                    Label(L10n.string("mobile.downloads.batch.select"), systemImage: "checkmark.circle")
                }
                .disabled(model.visibleTasks.allSatisfy { !model.canPauseDownloadTask($0) && !model.canResumeDownloadTask($0) })
                .frame(minWidth: MobileMetrics.minimumTouchTarget, minHeight: MobileMetrics.minimumTouchTarget)
                .accessibilityIdentifier("downloads.select")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { isShowingControls = true } label: {
                    Label(L10n.string("mobile.downloads.batch.records"), systemImage: "clock.arrow.circlepath")
                }
                .frame(minWidth: MobileMetrics.minimumTouchTarget, minHeight: MobileMetrics.minimumTouchTarget)
                .accessibilityIdentifier("downloads.records")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker(L10n.string("download.workspace.categories"), selection: $model.taskFilter) {
                        ForEach(MobileDownloadFilter.allCases) { filter in
                            Text(filter.title).tag(filter).accessibilityIdentifier("downloads.filter.\(filter.rawValue)")
                        }
                    }
                    Picker(L10n.string("mobile.downloads.sort"), selection: $model.taskSort) {
                        ForEach(MobileDownloadSort.allCases) { sort in Text(sort.title).tag(sort) }
                    }
                    Button(L10n.string("download.workspace.show-all")) { model.resetPresentation() }
                } label: {
                    Label(L10n.string("download.workspace.categories"), systemImage: "line.3.horizontal.decrease.circle")
                }
                .frame(minWidth: MobileMetrics.minimumTouchTarget, minHeight: MobileMetrics.minimumTouchTarget)
                .accessibilityIdentifier("downloads.filters")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button {
                        isShowingCreateTask = true
                    } label: {
                        Label(
                            L10n.string("mobile.downloads.create.link.action"),
                            systemImage: "link"
                        )
                    }
                    .disabled(!model.canCreateDownloadTask)
                    .accessibilityHint(L10n.string("mobile.downloads.create.action.hint"))

                    Button {
                        isImportingTaskFile = true
                    } label: {
                        Label(
                            L10n.string("mobile.downloads.create.file.action"),
                            systemImage: "doc.badge.plus"
                        )
                    }
                    .disabled(!model.canCreateDownloadTask)
                    .accessibilityHint(L10n.string("mobile.downloads.create.file.action.hint"))

                    if model.downloadSnapshot?.hasBTSearch == true {
                        Button {
                            isShowingBTSearch = true
                        } label: {
                            Label(
                                L10n.string("mobile.downloads.bt-search.action"),
                                systemImage: "magnifyingglass"
                            )
                        }
                        .disabled(!model.canSearchDownloadBT)
                        .accessibilityHint(L10n.string("mobile.downloads.bt-search.action.hint"))
                    }
                } label: {
                    Label(
                        L10n.string("mobile.downloads.create.menu"),
                        systemImage: "plus"
                    )
                }
                .disabled(!model.canCreateDownloadTask && !model.canSearchDownloadBT)
                .frame(
                    minWidth: MobileMetrics.minimumTouchTarget,
                    minHeight: MobileMetrics.minimumTouchTarget
                )
                .accessibilityHint(L10n.string("mobile.downloads.create.menu.hint"))
            }
        }
    }

    private var taskList: some View {
        List {
            if model.downloadSnapshot?.isComplete == false {
                Section { Text(L10n.string("mobile.downloads.catalog.limited")).foregroundStyle(.secondary) }
            }
            if model.message != nil {
                Section {
                    Text(L10n.string("mobile.downloads.catalog.refresh-failed"))
                    Button(L10n.string("ui.7bdd5ce1e298a972"), action: model.reloadDownloads)
                }
            }
            if let snapshot = model.downloadSnapshot {
                MobileDownloadActivitySummaryView(snapshot: snapshot)
            }

            if let feedback = model.downloadCreateFeedback {
                Section {
                    DownloadCreateFeedbackView(model: model, feedback: feedback)
                }
            }

            Section {
                ForEach(model.visibleTasks) { task in
                    Button {
                        selectedTask = task
                    } label: {
                        DownloadTaskRow(task: task)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: MobileMetrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                    .accessibilityHint(L10n.string("ui.a748cc074f78de00"))
                    .accessibilityIdentifier("downloads.task.\(task.id)")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func handleTaskFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result,
              let url = urls.first else {
            return
        }
        model.createDownloadTask(fileURL: url)
    }
}

private let mobileDownloadTaskFileTypes: [UTType] = {
    var types = [
        UTType(filenameExtension: "torrent"),
        UTType(filenameExtension: "nzb"),
        UTType(filenameExtension: "txt")
    ].compactMap { $0 }
    if !types.contains(.plainText) {
        types.append(.plainText)
    }
    return types
}()

private struct MobileDownloadActivitySummaryView: View {
    let snapshot: DownloadStationSnapshot

    private var showsEMuleSpeeds: Bool {
        snapshot.emuleDownloadBytesPerSecond > 0 || snapshot.emuleUploadBytesPerSecond > 0
    }

    var body: some View {
        Section(L10n.string("mobile.downloads.activity.title")) {
            LabeledContent(
                L10n.string("mobile.downloads.activity.download"),
                value: MobileDownloadPresentation.speed(snapshot.statistics?.downloadBytesPerSecond)
            )
            LabeledContent(
                L10n.string("mobile.downloads.activity.upload"),
                value: MobileDownloadPresentation.speed(snapshot.statistics?.uploadBytesPerSecond)
            )
            if showsEMuleSpeeds {
                LabeledContent(
                    L10n.string("mobile.downloads.activity.emule-download"),
                    value: MobileDownloadPresentation.speed(snapshot.statistics?.emuleDownloadBytesPerSecond)
                )
                LabeledContent(
                    L10n.string("mobile.downloads.activity.emule-upload"),
                    value: MobileDownloadPresentation.speed(snapshot.statistics?.emuleUploadBytesPerSecond)
                )
            }
        }
        .accessibilityElement(children: .contain)
    }

}

private struct MobileDownloadCreateTaskView: View {
    @Bindable var model: MobileDownloadsModel
    @Environment(\.dismiss) private var dismiss
    @State private var uri = ""

    private var canSubmit: Bool {
        !model.isCreatingDownloadTask &&
        model.downloadCreateFeedback == nil &&
        !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        L10n.string("mobile.downloads.create.url.placeholder"),
                        text: $uri,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .accessibilityLabel(L10n.string("mobile.downloads.create.url.label"))
                    Text(L10n.string("mobile.downloads.create.url.help"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text(L10n.string("mobile.downloads.create.url.label"))
                }

                Section(L10n.string("mobile.downloads.create.destination.label")) {
                    if let destination = model.downloadCreateDefaultDestination {
                        LabeledContent(
                            L10n.string("ui.0b7e2876922e4662"),
                            value: destination
                        )
                    } else {
                        Label(
                            L10n.string("mobile.downloads.create.destination.default"),
                            systemImage: "folder"
                        )
                        .accessibilityElement(children: .combine)
                    }
                }

                if let feedback = model.downloadCreateFeedback {
                    Section {
                        DownloadCreateFeedbackView(model: model, feedback: feedback)
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.downloads.create.title"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.isCreatingDownloadTask)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(closeTitle) {
                        model.dismissDownloadCreateFeedback()
                        dismiss()
                    }
                    .disabled(model.isCreatingDownloadTask)
                    .frame(
                        minWidth: MobileMetrics.minimumTouchTarget,
                        minHeight: MobileMetrics.minimumTouchTarget
                    )
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.downloads.create.submit")) {
                        model.createDownloadTask(uri: uri)
                    }
                    .disabled(!canSubmit)
                    .frame(
                        minWidth: MobileMetrics.minimumTouchTarget,
                        minHeight: MobileMetrics.minimumTouchTarget
                    )
                }
            }
        }
        .onDisappear {
            if !model.isCreatingDownloadTask {
                model.dismissDownloadCreateFeedback()
            }
        }
    }

    private var closeTitle: String {
        model.downloadCreateFeedback == nil
            ? L10n.string("mobile.downloads.create.cancel")
            : L10n.string("mobile.downloads.create.done")
    }
}

private struct DownloadCreateFeedbackView: View {
    @Bindable var model: MobileDownloadsModel
    let feedback: MobileDownloadCreateFeedback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.title(for: feedback), systemImage: systemImage)
                .font(.headline)
            Text(model.message(for: feedback))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if feedback.kind == .inProgress {
                ProgressView()
                    .accessibilityLabel(model.message(for: feedback))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var systemImage: String {
        switch feedback.kind {
        case .inProgress:
            return "clock"
        case .success:
            return "checkmark.circle"
        case .needsReview:
            return "exclamationmark.triangle"
        case .cancelled:
            return "xmark.circle"
        case .conflict:
            return "arrow.triangle.2.circlepath"
        case .permission:
            return "lock"
        case .unsupported:
            return "slash.circle"
        case .failure:
            return "exclamationmark.circle"
        }
    }
}

private struct DownloadTaskRow: View {
    let task: DownloadStationTask

    var body: some View {
        HStack(spacing: 14) {
            statusIcon(task.status)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(MobileDownloadPresentation.status(task.status))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress = task.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel(L10n.string("ui.755ca1516d681c2c"))
                        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
                }
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Label(MobileDownloadPresentation.speed(task.downloadBytesPerSecond), systemImage: "arrow.down")
                        Text(MobileDownloadPresentation.remaining(task))
                    }
                    Text(MobileDownloadPresentation.speed(task.downloadBytesPerSecond))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.forward")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct MobileDownloadTaskDetailView: View {
    @Bindable var model: MobileDownloadsModel
    let initialTask: DownloadStationTask
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false
    @State private var isShowingControlRecords = false
    @State private var details: DownloadStationTaskDetails?
    @State private var isLoadingDetails = false
    @State private var detailsFailed = false

    private var task: DownloadStationTask {
        model.downloadTask(id: initialTask.id) ?? initialTask
    }

    var body: some View {
        NavigationStack {
            Form {
                controlSection
                deleteSection

                Section(L10n.string("ui.1932da4d4dba4ed0")) {
                    LabeledContent(
                        L10n.string("background-tasks.filter-label"),
                        value: MobileDownloadPresentation.status(task.status)
                    )
                    if let progress = task.progress {
                        LabeledContent(L10n.string("ui.755ca1516d681c2c")) {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                        }
                        ProgressView(value: progress)
                            .accessibilityLabel(L10n.string("ui.755ca1516d681c2c"))
                            .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
                    }
                    LabeledContent(L10n.string("download.workspace.size"), value: MobileDownloadPresentation.bytes(task.sizeBytes))
                    LabeledContent(L10n.string("download.workspace.downloaded"), value: MobileDownloadPresentation.bytes(task.downloadedBytes))
                    LabeledContent(L10n.string("download.workspace.uploaded"), value: MobileDownloadPresentation.bytes(task.uploadedBytes))
                    LabeledContent(L10n.string("download.workspace.download-speed"), value: MobileDownloadPresentation.speed(task.downloadBytesPerSecond))
                    LabeledContent(L10n.string("download.workspace.upload-speed"), value: MobileDownloadPresentation.speed(task.uploadBytesPerSecond))
                    LabeledContent(L10n.string("download.workspace.remaining"), value: MobileDownloadPresentation.remaining(task))
                        .accessibilityIdentifier("downloads.details.remaining")
                    LabeledContent(L10n.string("download.workspace.ratio"), value: task.shareRatio?.formatted(.number.precision(.fractionLength(0...2)).locale(L10n.locale)) ?? MobileDownloadPresentation.unknown)
                    if let destination = task.destination, !destination.isEmpty {
                        LabeledContent(
                            L10n.string("ui.0b7e2876922e4662"),
                            value: destination
                        )
                    }
                    if task.status.lowercased() == "error" {
                        Text(L10n.string("download.workspace.task-error"))
                    }
                }
                if isLoadingDetails {
                    Section { ProgressView(L10n.string("ui.86b6d0d63062ba81")) }
                }
                if detailsFailed {
                    Section {
                        Text(L10n.string("mobile.downloads.details.failed"))
                        Button(L10n.string("ui.7bdd5ce1e298a972")) { Task { await loadDetails() } }
                            .accessibilityIdentifier("downloads.details.retry")
                    }
                }
                if let details { MobileDownloadAdditionalDetails(details: details) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("downloads.details.form")
            .task(id: model.activeProfile.map(MobileWorkspaceIdentity.init)) { await loadDetails() }
            .refreshable { await loadDetails() }
            .sheet(isPresented: $isShowingControlRecords) { MobileDownloadControlRecordsView(model: model) }
            .confirmationDialog(
                L10n.string("mobile.downloads.delete.confirm.title", task.title),
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button(
                    L10n.string("mobile.downloads.delete.confirm.submit"),
                    role: .destructive
                ) {
                    model.deleteDownloadTask(task)
                }
                Button(L10n.string("mobile.downloads.delete.confirm.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("mobile.downloads.delete.confirm.message"))
            }
            .navigationTitle(task.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("download.workspace.close")) {
                        dismiss()
                    }
                    .accessibilityIdentifier("downloads.details.close")
                    .frame(
                        minWidth: MobileMetrics.minimumTouchTarget,
                        minHeight: MobileMetrics.minimumTouchTarget
                    )
                }
            }
        }
    }

    private func loadDetails() async {
        guard !isLoadingDetails else { return }
        isLoadingDetails = true
        detailsFailed = false
        defer { isLoadingDetails = false }
        do { details = try await model.loadDetails(id: initialTask.id) }
        catch is CancellationError { details = nil }
        catch { detailsFailed = true }
    }

    @ViewBuilder
    private var controlSection: some View {
        if model.feedbackForDownloadTask(task) != nil
            || model.canPauseDownloadTask(task)
            || model.canResumeDownloadTask(task)
            || model.isControllingDownloadTask || model.controlProtects(task.id) {
            Section(L10n.string("mobile.downloads.control.section")) {
                if model.controlRecovery.failed { Text(L10n.string("mobile.downloads.batch.storage-error")).foregroundStyle(.orange) }
                if let feedback = model.feedbackForDownloadTask(task) {
                    DownloadControlFeedbackView(model: model, feedback: feedback)
                }
                if model.controlProtects(task.id) {
                    Button(L10n.string("mobile.downloads.batch.records")) { isShowingControlRecords = true }
                        .frame(minHeight: MobileMetrics.minimumTouchTarget)
                        .accessibilityIdentifier("downloads.details.records")
                }
                if model.canPauseDownloadTask(task) {
                    Button {
                        model.controlDownloadTask(task, action: .pause)
                    } label: {
                        Label(
                            L10n.string("mobile.downloads.control.pause"),
                            systemImage: "pause.fill"
                        )
                    }
                    .frame(minHeight: MobileMetrics.minimumTouchTarget)
                    .accessibilityHint(L10n.string("mobile.downloads.control.pause.hint"))
                    .accessibilityIdentifier("downloads.details.pause")
                }
                if model.canResumeDownloadTask(task) {
                    Button {
                        model.controlDownloadTask(task, action: .resume)
                    } label: {
                        Label(
                            L10n.string("mobile.downloads.control.resume"),
                            systemImage: "play.fill"
                        )
                    }
                    .frame(minHeight: MobileMetrics.minimumTouchTarget)
                    .accessibilityHint(L10n.string("mobile.downloads.control.resume.hint"))
                    .accessibilityIdentifier("downloads.details.resume")
                }
                if model.isControllingDownloadTask {
                    ProgressView()
                        .accessibilityLabel(
                            L10n.string("mobile.downloads.control.in-progress.message")
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        if model.deleteFeedbackForDownloadTask(task) != nil
            || model.canDeleteDownloadTask(task)
            || model.isDeletingDownloadTask {
            Section(L10n.string("mobile.downloads.delete.section")) {
                if let feedback = model.deleteFeedbackForDownloadTask(task) {
                    DownloadDeleteFeedbackView(model: model, feedback: feedback)
                }
                if model.canDeleteDownloadTask(task) {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label(
                            L10n.string("mobile.downloads.delete.action"),
                            systemImage: "trash"
                        )
                    }
                    .frame(minHeight: MobileMetrics.minimumTouchTarget)
                    .accessibilityHint(L10n.string("mobile.downloads.delete.action.hint"))
                }
                if model.isDeletingDownloadTask {
                    ProgressView()
                        .accessibilityLabel(
                            L10n.string("mobile.downloads.delete.deleting.message")
                        )
                }
            }
        }
    }
}

private struct DownloadControlFeedbackView: View {
    @Bindable var model: MobileDownloadsModel
    let feedback: MobileDownloadControlFeedback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.title(for: feedback), systemImage: systemImage)
                .font(.headline)
            Text(model.message(for: feedback))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var systemImage: String {
        switch feedback.kind {
        case .inProgress:
            return "clock"
        case .success:
            return "checkmark.circle"
        case .needsReview:
            return "exclamationmark.triangle"
        case .cancelled:
            return "xmark.circle"
        case .conflict:
            return "arrow.triangle.2.circlepath"
        case .permission:
            return "lock"
        case .unsupported:
            return "slash.circle"
        case .failure:
            return "exclamationmark.circle"
        }
    }
}

private struct DownloadDeleteFeedbackView: View {
    @Bindable var model: MobileDownloadsModel
    let feedback: MobileDownloadDeleteFeedback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.title(for: feedback), systemImage: systemImage)
                .font(.headline)
            Text(model.message(for: feedback))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var systemImage: String {
        switch feedback.kind {
        case .inProgress:
            return "clock"
        case .success:
            return "checkmark.circle"
        case .needsReview:
            return "exclamationmark.triangle"
        case .cancelled:
            return "xmark.circle"
        case .conflict:
            return "arrow.triangle.2.circlepath"
        case .permission:
            return "lock"
        case .unsupported:
            return "slash.circle"
        case .failure:
            return "exclamationmark.circle"
        }
    }
}
