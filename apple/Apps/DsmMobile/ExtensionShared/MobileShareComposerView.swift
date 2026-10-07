import DsmFileFeature
import DsmLocalization
import SwiftUI

struct MobileShareComposerView: View {
    @Bindable var model: MobileShareComposerModel
    let dismiss: @MainActor () -> Void
    @State private var overwrite = false
    @State private var confirmsReplacement = false
    @State private var isClosing = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationStack {
            Group {
                if model.phase == .loading {
                    ProgressView(L10n.string("files.upload.preparing"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.phase == .failed {
                    ContentUnavailableView(L10n.string("mobile.share.title"), systemImage: "square.and.arrow.up",
                        description: Text(model.error ?? L10n.string("mobile.share.receive-error")))
                } else if model.phase == .submitted, let queue = model.queue {
                    resultList(queue)
                } else {
                    selection
                }
            }
            .navigationTitle(L10n.string("mobile.share.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string(model.phase == .submitted ? "mobile.share.close" : "ui.2cd0f3be8738a86c")) { close() }
                        .frame(minHeight: 44).disabled(isClosing)
                        .accessibilityIdentifier("mobile.share.close")
                }
                if model.phase != .submitted {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("mobile.files.upload-submit")) {
                            if overwrite { confirmsReplacement = true }
                            else { Task { await model.upload(overwrite: false) } }
                        }
                        .frame(minHeight: 44).disabled(!model.canUpload || isClosing)
                        .accessibilityIdentifier("mobile.share.upload")
                    }
                }
            }
            .confirmationDialog(L10n.string("mobile.files.upload-replace-title"), isPresented: $confirmsReplacement, titleVisibility: .visible) {
                Button(L10n.string("files.upload.replace"), role: .destructive) { Task { await model.upload(overwrite: true) } }
            } message: { Text(L10n.string("mobile.files.upload-replace-message")) }
            .interactiveDismissDisabled(model.phase == .preparing || model.isRunning)
        }
        .task { await model.load() }
    }

    private var selection: some View {
        Form {
            if model.accounts.count > 1 {
                Section {
                    Picker(L10n.string("mobile.share.connection"), selection: Binding(
                        get: { model.selectedAccount?.id },
                        set: { if let id = $0 { Task { await model.selectAccount(id) } } }
                    )) {
                        ForEach(model.accounts) { account in
                            VStack(alignment: .leading) {
                                Text(account.profile.displayName)
                                if let name = account.profile.usernameHint { Text(name).font(.caption).foregroundStyle(.secondary) }
                            }.tag(Optional(account.id))
                        }
                    }
                    .disabled(model.phase != .ready)
                    .accessibilityIdentifier("mobile.share.connection")
                }
            }
            Section {
                if !model.path.isEmpty {
                    HStack(alignment: .center, spacing: 8) {
                        Button { Task { await model.goUp() } } label: {
                            Image(systemName: "chevron.backward").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(L10n.string("ui.2bab713fde4ebc53"))
                        .accessibilityIdentifier("mobile.share.up")
                        Text(model.path).fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled).accessibilityIdentifier("mobile.share.path")
                    }
                }
                if let error = model.folderError {
                    Text(error).foregroundStyle(.secondary)
                    Button(L10n.string("ui.b8784c8dd5636ff2")) { Task { await model.retryFolder() } }
                        .frame(minHeight: 44).accessibilityIdentifier("mobile.share.retry-folder")
                } else if model.folders.isEmpty && !model.isLoadingFolders {
                    Text(L10n.string(model.path.isEmpty ? "mobile.files.folder-picker.empty-root" : "mobile.share.empty-folder"))
                        .foregroundStyle(.secondary)
                }
                ForEach(model.folders) { folder in
                    Button { Task { await model.navigate(to: folder.path) } } label: {
                        Label(folder.name, systemImage: "folder")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    }.accessibilityIdentifier("mobile.share.folder." + folder.path)
                }
                if model.isLoadingFolders { ProgressView(L10n.string("mobile.files.loading")) }
                else if model.hasMore {
                    Button(L10n.string("mobile.files.load-more")) { Task { await model.loadMore() } }.frame(minHeight: 44)
                }
            } header: {
                Text(model.selectedAccount?.profile.displayName ?? L10n.string("files.upload.destination"))
            }
            .disabled(model.phase != .ready)
            Section {
                if dynamicTypeSize.isAccessibilitySize { conflictPicker.pickerStyle(.inline) }
                else { conflictPicker }
                ForEach(Array(model.fileNames.enumerated()), id: \.offset) { _, name in Label(name, systemImage: "doc") }
            }
            if model.phase == .preparing { Section { ProgressView(L10n.string("files.upload.preparing")) } }
            if let error = model.error { Section { Text(error).foregroundStyle(.secondary) } }
        }
        .accessibilityIdentifier("mobile.share.selection")
    }

    private var conflictPicker: some View {
        Picker(L10n.string("files.upload.sameName"), selection: $overwrite) {
            Text(L10n.string("files.upload.skip")).fixedSize(horizontal: false, vertical: true).tag(false)
            Text(L10n.string("files.upload.replace")).fixedSize(horizontal: false, vertical: true).tag(true)
        }.disabled(model.phase != .ready)
    }

    private func resultList(_ queue: MobileFileUploadQueue) -> some View {
        List {
            Section {
                if model.allSucceeded {
                    Label(L10n.string("mobile.share.completed"), systemImage: "checkmark.circle")
                        .accessibilityIdentifier("mobile.share.completed")
                } else {
                    Text(L10n.string("mobile.share.resume-in-app")).foregroundStyle(.secondary)
                }
                if let error = queue.recoveryError { Text(error).foregroundStyle(.secondary) }
            }
            ForEach(queue.batches) { batch in
                Section {
                    ForEach(batch.entries) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.source.relativePath).font(.headline)
                            Text(entry.state == .unverified ? L10n.string("mobile.activity.status-result-needs-review") : entry.state.title)
                                .font(.subheadline).foregroundStyle(.secondary)
                            if entry.state == .running { ProgressView(value: Double(entry.completedBytes), total: Double(max(entry.source.size, 1))) }
                            if entry.state == .unverified {
                                Text(L10n.string("mobile.activity.review-message")).font(.caption).foregroundStyle(.secondary)
                            } else if let message = entry.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                        }.accessibilityElement(children: .combine)
                    }
                    if batch.isRunning {
                        Button(L10n.string("files.upload.cancel"), role: .cancel) { model.cancelUploads() }.frame(minHeight: 44)
                    } else if batch.entries.contains(where: { $0.state == .unverified }) {
                        Button(L10n.string("mobile.activity.refresh-result")) { Task { await queue.refresh(batch) } }.frame(minHeight: 44)
                    }
                } header: { Text(batch.destination).textCase(nil) }
            }
        }
        .accessibilityIdentifier("mobile.share.results")
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        Task { await model.close(); dismiss() }
    }
}
