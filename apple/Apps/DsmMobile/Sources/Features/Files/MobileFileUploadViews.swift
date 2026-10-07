import DsmFileFeature
import DsmLocalization
import SwiftUI

struct MobileFileUploadSelectionView: View {
    @Bindable var queue: MobileFileUploadQueue
    @State private var overwrite = false
    @State private var confirmsReplacement = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L10n.string("files.upload.destination"), value: queue.destination)
                }
                if queue.isPreparing {
                    Section { ProgressView(L10n.string("files.upload.preparing")) }
                } else if let error = queue.error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("mobile.upload.error") }
                } else if queue.sources.isEmpty {
                    ContentUnavailableView(L10n.string("files.upload.empty"), systemImage: "folder",
                        description: Text(L10n.string("files.upload.chooseAgain")))
                }
                if !queue.sources.isEmpty {
                    Section {
                        Picker(L10n.string("files.upload.sameName"), selection: $overwrite) {
                            Text(L10n.string("files.upload.skip")).tag(false)
                            Text(L10n.string("files.upload.replace")).tag(true)
                        }
                        .disabled(queue.isPreparing)
                    }
                    Section {
                        ForEach(queue.sources) { source in
                            VStack(alignment: .leading) {
                                Label(source.relativePath, systemImage: source.kind == .directory ? "folder" : "doc")
                                if source.kind == .symbolicLink {
                                    Text(L10n.string("files.upload.linkSkipped")).font(.caption).foregroundStyle(.secondary)
                                } else if source.kind == .unreadable {
                                    Text(L10n.string("files.upload.sourceUnavailable")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("files.upload.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("ui.2cd0f3be8738a86c")) { queue.dismissSelection() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.files.upload-submit")) {
                        if overwrite { confirmsReplacement = true }
                        else { Task { await queue.submit(overwrite: false) } }
                    }
                    .disabled(queue.isPreparing || queue.sources.isEmpty)
                    .accessibilityIdentifier("mobile.upload.start")
                }
            }
            .confirmationDialog(L10n.string("mobile.files.upload-replace-title"), isPresented: $confirmsReplacement,
                                titleVisibility: .visible) {
                Button(L10n.string("files.upload.replace"), role: .destructive) {
                    Task { await queue.submit(overwrite: true) }
                }
            } message: {
                Text(L10n.string("mobile.files.upload-replace-message"))
            }
        }
    }
}

struct MobileFileUploadSections: View {
    @Bindable var queue: MobileFileUploadQueue
    let filter: MobileActivityFilter
    var sourceTitle: String? = nil
    var onEmpty: (() -> Void)? = nil

    var body: some View {
        if let error = queue.recoveryError {
            Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary) }
        }
        ForEach(queue.batches.filter(includes)) { batch in
            Section {
                ForEach(batch.entries) { entry in
                    VStack(alignment: .leading, spacing: MobileSpacing.compact) {
                        Text(entry.source.relativePath).font(.headline)
                        Text(entry.state == .unverified ? L10n.string("mobile.activity.status-result-needs-review") : entry.state.title)
                            .font(.subheadline).foregroundStyle(.secondary)
                        if entry.state == .running {
                            ProgressView(value: Double(entry.completedBytes), total: Double(max(entry.source.size, 1)))
                        }
                        if entry.state == .unverified {
                            Text(L10n.string("mobile.activity.review-message")).font(.caption).foregroundStyle(.secondary)
                        } else if let message = entry.message {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                controls(batch)
            } header: {
                VStack(alignment: .leading, spacing: MobileSpacing.compact) {
                    if let sourceTitle { Text(sourceTitle) }
                    Label(batch.destination, systemImage: "arrow.up.doc")
                    Text(L10n.string("files.upload.summary", batch.finishedCount.formatted(.number.locale(L10n.locale)),
                                     batch.entries.count.formatted(.number.locale(L10n.locale))))
                }
                .textCase(nil)
            }
        }
    }

    @ViewBuilder private func controls(_ batch: FileUploadBatch) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { buttons(batch) }
            VStack(alignment: .leading) { buttons(batch) }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(queue.isConfiguring)
    }

    @ViewBuilder private func buttons(_ batch: FileUploadBatch) -> some View {
        if batch.isRunning {
            Button(L10n.string("files.upload.pause")) { batch.pause() }
            Button(L10n.string("files.upload.cancel"), role: .cancel) { batch.cancel() }
        } else {
            if batch.isPaused {
                Button(L10n.string("files.upload.resume")) { queue.resume(batch) }
            }
            if batch.entries.contains(where: { [.failed, .conflict].contains($0.state) && $0.retryAllowed }) {
                Button(L10n.string("files.upload.retryFailed")) { queue.retryFailed(batch) }
            }
            if batch.entries.contains(where: { $0.state == .unverified }) {
                Button(L10n.string("mobile.activity.refresh-result")) { Task { await queue.refresh(batch) } }
            }
            if batch.isPaused || batch.hasPending {
                Button(L10n.string("files.upload.cancel"), role: .cancel) { batch.cancel() }
            }
            if batch.entries.allSatisfy({ [.succeeded, .skipped, .cancelled].contains($0.state) }) {
                Button(L10n.string("mobile.files.upload-clear")) {
                    queue.removeFinished(batch)
                    if queue.batches.isEmpty { onEmpty?() }
                }
            }
        }
    }

    private func includes(_ batch: FileUploadBatch) -> Bool {
        let active = batch.isRunning || batch.isPaused || batch.hasPending
        switch filter {
        case .all: return true
        case .inProgress: return active
        case .ended: return !active
        }
    }
}
