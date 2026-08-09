import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDownloadsView: View {
    @Bindable var model: MobileAppModel
    @State private var selectedTask: DownloadStationTask?
    @State private var isShowingCreateTask = false

    var body: some View {
        MobilePageStateView(
            state: model.downloadPageState,
            labels: MobilePageStateLabels(
                loading: L10n.string("ui.86b6d0d63062ba81"),
                emptyTitle: L10n.string("ui.e0c9f46a0d2db5c0"),
                emptyMessage: L10n.string("mobile.downloads.read-only.notice"),
                filteredEmptyTitle: L10n.string("ui.e0c9f46a0d2db5c0"),
                filteredEmptyMessage: L10n.string("mobile.downloads.read-only.notice"),
                errorTitle: L10n.string("ui.0bc1fb72ae1be5c5"),
                errorMessage: model.message ?? L10n.string("ui.38245f0b3e213b62"),
                retryTitle: L10n.string("ui.7bdd5ce1e298a972")
            ),
            emptySystemImage: "arrow.down.circle",
            retryAction: model.reloadDownloads
        ) {
            taskList
        }
        .sheet(item: $selectedTask) { task in
            MobileDownloadTaskDetailView(model: model, initialTask: task)
        }
        .sheet(isPresented: $isShowingCreateTask) {
            MobileDownloadCreateTaskView(model: model)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isShowingCreateTask = true
                } label: {
                    Label(
                        L10n.string("mobile.downloads.create.action"),
                        systemImage: "plus"
                    )
                }
                .disabled(!model.canCreateDownloadTask)
                .frame(
                    minWidth: MobileMetrics.minimumTouchTarget,
                    minHeight: MobileMetrics.minimumTouchTarget
                )
                .accessibilityHint(L10n.string("mobile.downloads.create.action.hint"))
            }
        }
    }

    private var taskList: some View {
        List {
            Section {
                Label(
                    L10n.string("mobile.downloads.read-only.notice"),
                    systemImage: "eye"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            Section {
                ForEach(model.downloadSnapshot?.tasks ?? []) { task in
                    Button {
                        selectedTask = task
                    } label: {
                        DownloadTaskRow(task: task)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: MobileMetrics.minimumTouchTarget)
                    .contentShape(Rectangle())
                    .accessibilityHint(L10n.string("ui.a748cc074f78de00"))
                }
            }
        }
        .listStyle(.insetGrouped)
    }
}

private struct MobileDownloadCreateTaskView: View {
    @Bindable var model: MobileAppModel
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
    @Bindable var model: MobileAppModel
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
                Text(task.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let progress = task.progress {
                    ProgressView(value: progress)
                        .accessibilityLabel(L10n.string("ui.755ca1516d681c2c"))
                        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
                }
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
    @Bindable var model: MobileAppModel
    let initialTask: DownloadStationTask
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDelete = false

    private var task: DownloadStationTask {
        model.downloadTask(id: initialTask.id) ?? initialTask
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        L10n.string("mobile.downloads.read-only.notice"),
                        systemImage: "pause.circle"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }

                controlSection
                deleteSection

                Section(L10n.string("ui.1932da4d4dba4ed0")) {
                    LabeledContent(
                        L10n.string("background-tasks.filter-label"),
                        value: task.status
                    )
                    if let progress = task.progress {
                        LabeledContent(L10n.string("ui.755ca1516d681c2c")) {
                            Text(progress, format: .percent.precision(.fractionLength(0)))
                        }
                        ProgressView(value: progress)
                            .accessibilityLabel(L10n.string("ui.755ca1516d681c2c"))
                            .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
                    }
                    if let sizeBytes = task.sizeBytes {
                        LabeledContent(L10n.string("mobile.files.details.size")) {
                            Text(sizeBytes, format: .byteCount(style: .file))
                        }
                    }
                    if let downloadedBytes = task.downloadedBytes {
                        Text(
                            L10n.string(
                                "desktopDrive.cache.size",
                                downloadedBytes.formatted(.byteCount(style: .file))
                            )
                        )
                    }
                    if let destination = task.destination, !destination.isEmpty {
                        LabeledContent(
                            L10n.string("ui.0b7e2876922e4662"),
                            value: destination
                        )
                    }
                    if let error = task.errorDescription, !error.isEmpty {
                        LabeledContent(
                            L10n.string("ui.0bc1fb72ae1be5c5"),
                            value: error
                        )
                    }
                }
            }
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
                    Button(L10n.string("ui.2cd0f3be8738a86c")) {
                        dismiss()
                    }
                    .frame(
                        minWidth: MobileMetrics.minimumTouchTarget,
                        minHeight: MobileMetrics.minimumTouchTarget
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var controlSection: some View {
        if model.feedbackForDownloadTask(task) != nil
            || model.canPauseDownloadTask(task)
            || model.canResumeDownloadTask(task)
            || model.isControllingDownloadTask {
            Section(L10n.string("mobile.downloads.control.section")) {
                if let feedback = model.feedbackForDownloadTask(task) {
                    DownloadControlFeedbackView(model: model, feedback: feedback)
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
    @Bindable var model: MobileAppModel
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
    @Bindable var model: MobileAppModel
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
