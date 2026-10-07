import DsmFileFeature
import DsmLocalization
import Foundation
import SwiftUI

struct FileUploadSelection: Identifiable {
    let id = UUID()
    let urls: [URL]
    let destination: String
}

struct FileUploadConfirmationView: View {
    @Bindable var model: WorkspaceModel
    let selection: FileUploadSelection
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [FileUploadSource] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var overwrite = false
    @State private var confirmsReplacement = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("files.upload.title")).font(.title2.bold())
            LabeledContent(L10n.string("files.upload.destination"), value: selection.destination)
            if isLoading {
                ProgressView(L10n.string("files.upload.preparing")).frame(maxWidth: .infinity, minHeight: 180)
            } else if let error {
                ContentUnavailableView(L10n.string("files.upload.failed"), systemImage: "exclamationmark.triangle", description: Text(error))
            } else if sources.isEmpty {
                ContentUnavailableView(L10n.string("files.upload.empty"), systemImage: "folder", description: Text(L10n.string("files.upload.chooseAgain")))
            } else {
                List(sources) { source in
                    HStack {
                        Image(systemName: source.kind == .directory ? "folder" : source.kind == .symbolicLink ? "link" : "doc")
                        Text(source.relativePath)
                        if source.kind == .symbolicLink { Text(L10n.string("files.upload.linkSkipped")).foregroundStyle(.secondary) }
                    }
                }.frame(minHeight: 180, maxHeight: 320)
                Picker(L10n.string("files.upload.sameName"), selection: $overwrite) {
                    Text(L10n.string("files.upload.skip")).tag(false)
                    Text(L10n.string("files.upload.replace")).tag(true)
                }.pickerStyle(.radioGroup)
                if overwrite {
                    Toggle(L10n.string("files.upload.confirmReplace"), isOn: $confirmsReplacement)
                }
            }
            HStack {
                Spacer()
                Button(L10n.string("files.common.close"), role: .cancel) { dismiss() }
                Button(L10n.string("files.upload.start")) {
                    model.uploadSelection = nil
                    model.beginUploadBatch(sources: sources, destination: selection.destination, overwrite: overwrite)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || error != nil || sources.isEmpty || (overwrite && !confirmsReplacement))
            }
        }
        .padding(24).frame(width: 620)
        .task {
            let task = Task.detached { try FileUploadPlan.collect(selection.urls) }
            do { sources = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
            catch { self.error = L10n.string("files.upload.sourceUnavailable") }
            isLoading = false
        }
    }
}

// 仅供 macOS 传输中心使用，不改变共享上传状态或历史存储格式。
extension FileUploadBatch {
    var canRemoveFromTransferCenter: Bool {
        !isRunning && !isPaused && entries.allSatisfy {
            [.succeeded, .skipped, .failed, .conflict, .cancelled].contains($0.state)
        }
    }

    var hasUploadFailures: Bool {
        entries.contains { [.failed, .conflict].contains($0.state) }
    }

    var uploadProgressTotal: Int64 {
        entries.filter { $0.source.kind == .file && $0.state != .skipped }.reduce(0) { $0 + $1.source.size }
    }

    var uploadProgressBytes: Int64 {
        entries.filter { $0.source.kind == .file && $0.state != .skipped }
            .reduce(0) { $0 + min(max($1.completedBytes, 0), $1.source.size) }
    }

    var hasActiveUploadItems: Bool {
        entries.contains { [.pending, .running].contains($0.state) }
    }

    var transferStatusTitle: String {
        if isPaused { return L10n.string("files.upload.state.paused") }
        if isRunning { return L10n.string(hasActiveUploadItems ? "files.upload.state.running" : "mac.upload.updating") }
        if hasPending { return L10n.string("files.upload.state.pending") }
        if entries.contains(where: { $0.state == .unverified }) { return L10n.string("mac.upload.interrupted") }
        return L10n.string("mac.upload.ended")
    }

    var transferSummary: String {
        let groups: [(String, Int)] = [
            ("mac.upload.uploadedCount", entries.filter { $0.state == .succeeded && $0.source.kind == .file }.count),
            ("mac.upload.folderCount", entries.filter { $0.state == .succeeded && $0.source.kind == .directory }.count),
            ("mac.upload.skippedCount", entries.filter { $0.state == .skipped }.count),
            ("mac.upload.failedCount", entries.filter { [.failed, .conflict].contains($0.state) }.count),
            ("mac.upload.cancelledCount", entries.filter { $0.state == .cancelled }.count),
            ("mac.upload.interruptedCount", entries.filter { $0.state == .unverified }.count)
        ]
        return groups.filter { $0.1 > 0 }.map { L10n.string($0.0, $0.1.formatted(.number.locale(L10n.locale))) }
            .joined(separator: " · ")
    }
}

struct FileUploadBatchRow: View {
    @Bindable var model: WorkspaceModel
    let batch: FileUploadBatch
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.blue).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("mac.upload.batchTitle", batch.entries.count.formatted(.number.locale(L10n.locale))))
                        .font(.headline)
                    Text(batch.destination).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                Text(batch.transferStatusTitle).font(.caption)
                    .foregroundStyle(batch.hasUploadFailures ? Color.red : Color.secondary)
            }
            if batch.hasActiveUploadItems || batch.isPaused {
                if batch.uploadProgressTotal > 0 {
                    ProgressView(value: Double(batch.uploadProgressBytes), total: Double(batch.uploadProgressTotal))
                        .accessibilityLabel(L10n.string("mac.upload.progress"))
                    Text(L10n.string("mac.upload.byteProgress", percentage,
                                     formatBytes(batch.uploadProgressBytes), formatBytes(batch.uploadProgressTotal)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if batch.isRunning {
                    ProgressView().controlSize(.small)
                }
            }
            if !batch.transferSummary.isEmpty {
                Text(batch.transferSummary).font(.caption).foregroundStyle(.secondary)
            }
            if batch.isPaused {
                Text(L10n.string("mac.upload.resumeNotice")).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if batch.isRunning && batch.hasActiveUploadItems && !batch.isPaused {
                    Button(L10n.string("mac.upload.pauseBatch")) { batch.pause() }
                    Button(L10n.string("mac.upload.cancelBatch")) { batch.cancel() }
                } else if !batch.isRunning {
                    if batch.isPaused {
                        Button(L10n.string("mac.upload.resumeBatch")) { batch.resume(); model.startNextUploadBatch() }
                    }
                    if !batch.isPaused, batch.entries.contains(where: { [.failed, .conflict].contains($0.state) && $0.retryAllowed }) {
                        Button(L10n.string("mac.upload.retryFailed")) { batch.retryFailed(); model.startNextUploadBatch() }
                    }
                    if batch.hasPending || batch.isPaused {
                        Button(L10n.string("mac.upload.cancelBatch")) { batch.cancel() }
                    }
                }
                Spacer()
                if batch.canRemoveFromTransferCenter {
                    Button(L10n.string("mac.upload.removeRecord")) { model.removeUploadBatch(batch) }
                }
            }.buttonStyle(.bordered)
            DisclosureGroup(L10n.string("mac.upload.items"), isExpanded: $isExpanded) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(batch.entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .top) {
                                Image(systemName: entry.source.kind == .directory ? "folder" : "doc")
                                    .accessibilityHidden(true)
                                Text(entry.source.relativePath).textSelection(.enabled)
                                Spacer()
                                Text(entry.state == .unverified ? L10n.string("mac.upload.interrupted") : entry.state.title)
                                    .foregroundStyle(.secondary)
                            }
                            if entry.state == .running, entry.source.size > 0 {
                                ProgressView(value: Double(min(max(entry.completedBytes, 0), entry.source.size)),
                                             total: Double(entry.source.size))
                                    .accessibilityLabel(entry.source.relativePath)
                            }
                            if entry.state == .unverified {
                                Text(L10n.string("mac.upload.interruptedMessage")).foregroundStyle(.secondary)
                            } else if entry.state == .paused && entry.needsReconciliation {
                                Text(L10n.string("mac.upload.resumeNotice")).foregroundStyle(.secondary)
                            } else if let message = entry.message {
                                Text(message).foregroundStyle(.secondary)
                            }
                        }.font(.caption)
                    }
                }.padding(.top, 8)
            }
        }
        .padding(14)
        .background(MacCardFill(), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private var percentage: String {
        let value = Double(batch.uploadProgressBytes) / Double(max(batch.uploadProgressTotal, 1))
        return value.formatted(.percent.precision(.fractionLength(0)).locale(L10n.locale))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(L10n.locale))
    }
}
