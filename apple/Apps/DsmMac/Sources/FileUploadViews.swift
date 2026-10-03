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

struct FileUploadQueueView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("files.upload.queue")).font(.title2.bold())
            if model.uploadBatches.isEmpty {
                ContentUnavailableView(L10n.string("files.upload.empty"), systemImage: "arrow.up.doc",
                    description: Text(L10n.string("files.upload.chooseAgain")))
            } else {
                List(model.uploadBatches) { batch in
                    Section {
                        ForEach(batch.entries) { entry in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack { Text(entry.source.relativePath); Spacer(); Text(entry.state.title).foregroundStyle(.secondary) }
                                if entry.state == .running {
                                    ProgressView(value: Double(entry.completedBytes), total: Double(max(entry.source.size, 1)))
                                }
                                if let message = entry.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                            }.padding(.vertical, 3)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(batch.destination).textSelection(.enabled)
                            ProgressView(value: Double(batch.completedBytes), total: Double(max(batch.totalBytes, 1)))
                            Text(L10n.string("files.upload.summary", batch.finishedCount.formatted(.number.locale(L10n.locale)),
                                             batch.entries.count.formatted(.number.locale(L10n.locale))))
                            HStack {
                                if batch.isRunning {
                                    Button(L10n.string("files.upload.pause")) { batch.pause() }
                                    Button(L10n.string("files.upload.cancel")) { batch.cancel() }
                                } else {
                                    if batch.isPaused { Button(L10n.string("files.upload.resume")) { batch.resume(); model.startNextUploadBatch() } }
                                    if batch.entries.contains(where: { [.failed, .conflict].contains($0.state) && $0.retryAllowed }) {
                                        Button(L10n.string("files.upload.retryFailed")) { batch.retryFailed(); model.startNextUploadBatch() }
                                    }
                                    if batch.entries.contains(where: { $0.state == .unverified }) {
                                        Button(L10n.string("files.upload.checkResults")) { Task { await batch.reconcileUnknown() } }
                                    }
                                    if batch.hasPending || batch.isPaused { Button(L10n.string("files.upload.cancel")) { batch.cancel() } }
                                }
                            }.buttonStyle(.bordered)
                        }.padding(.vertical, 8)
                    }
                }
            }
            Text(L10n.string("files.upload.cancelNotice")).font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button(L10n.string("files.common.close")) { dismiss() } }
        }
        .padding(24).frame(width: 680, height: 560)
    }
}
