import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDownloadsView: View {
    @Bindable var model: MobileAppModel
    @State private var selectedTask: DownloadStationTask?

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
            MobileDownloadTaskDetailView(task: task)
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
    let task: DownloadStationTask
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(
                        L10n.string("mobile.downloads.read-only.notice"),
                        systemImage: "eye"
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }

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
}
