import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI

struct MobilePhotoTasksView: View {
    @Bindable var tasks: MobilePhotoTasksModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L10n.string("photos.tasks.filter"), selection: $tasks.filter) {
                    Text(L10n.string("photos.tasks.all")).tag(MobilePhotoTasksModel.Filter.all)
                    Text(L10n.string("photos.tasks.active")).tag(MobilePhotoTasksModel.Filter.active)
                    Text(L10n.string("photos.tasks.finished")).tag(MobilePhotoTasksModel.Filter.finished)
                }.pickerStyle(.segmented).padding().accessibilityIdentifier("mobile.photos.tasks.filter")
                Group {
                    if tasks.isLoading && tasks.tasks.isEmpty { ProgressView() }
                    else if let error = tasks.error, tasks.tasks.isEmpty {
                        ContentUnavailableView {
                            Label(L10n.string("photos.tasks.loadFailed"), systemImage: "exclamationmark.triangle")
                        } description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { Task { await tasks.refresh() } } }
                    } else if tasks.visibleTasks.isEmpty {
                        ContentUnavailableView {
                            Label(L10n.string(tasks.tasks.isEmpty ? "photos.tasks.empty" : "photos.tasks.filterEmpty"), systemImage: "list.bullet.rectangle")
                        } description: { Text(L10n.string(tasks.tasks.isEmpty ? "photos.tasks.emptyHint" : "photos.tasks.filterEmptyHint")) }
                    } else { List(tasks.visibleTasks) { task in row(task) }.refreshable { await tasks.refresh() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    if let error = tasks.error, !tasks.tasks.isEmpty { Text(error).foregroundStyle(.red) }
                    if let error = tasks.model.backgroundNavigationError { Text(error).foregroundStyle(.red) }
                    if let message = tasks.model.backgroundTaskMessage { Text(message) }
                    if let error = tasks.model.backgroundRecoveryError { Text(error).foregroundStyle(.red) }
                    if let error = tasks.model.albumRecoveryError { Text(error).foregroundStyle(.red) }
                    if tasks.model.pendingBackgroundMutationID != nil || tasks.model.backgroundRecoveryError != nil || tasks.model.albumRecoveryError != nil {
                        Button(L10n.string("photos.library.refresh")) {
                            Task {
                                if tasks.model.albumRecoveryError != nil { await tasks.model.retryAlbumRecovery() }
                                await tasks.model.retryBackgroundRecovery()
                            }
                        }
                            .disabled(tasks.model.isManagingBackgroundTask).accessibilityIdentifier("mobile.photos.tasks.resume")
                    }
                }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            }.navigationTitle(L10n.string("photos.tasks.title")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.string("photos.media.close")) { tasks.cancel(); dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button(L10n.string("photos.library.refresh")) { Task { await tasks.refresh() } }.disabled(tasks.isLoading)
                            Button(L10n.string("photos.tasks.clearCompleted"), role: .destructive) { tasks.requestClear() }
                                .disabled(!tasks.canControl || !tasks.tasks.contains(where: \.canClear))
                                .accessibilityIdentifier("mobile.photos.tasks.clearCompleted")
                        } label: { Label(L10n.string("photos.manage.actions"), systemImage: "ellipsis.circle") }
                            .accessibilityIdentifier("mobile.photos.tasks.actions")
                    }
                }
                .task {
                    repeat {
                        await tasks.refresh()
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    } while !Task.isCancelled && tasks.isPresented && tasks.model.isModuleEnabled
                }
                .onChange(of: tasks.model.backgroundTaskRevision) { _, _ in Task { await tasks.refresh() } }
                .alert(L10n.string(tasks.cancelling ? "photos.tasks.cancelTitle" : "photos.tasks.clearTitle"), isPresented: $tasks.showsConfirmation) {
                    Button(L10n.string("photos.delete.cancel"), role: .cancel) { tasks.cancelConfirmation() }
                    Button(L10n.string(tasks.cancelling ? "photos.tasks.cancel" : "photos.tasks.clear"), role: .destructive) { tasks.confirm() }
                        .accessibilityIdentifier("mobile.photos.tasks.confirm")
                } message: { Text(L10n.string(tasks.cancelling ? "photos.tasks.cancelHint" : "photos.tasks.clearHint")) }
                .sheet(item: Binding(get: { tasks.errorTask }, set: { if $0 == nil { tasks.closeErrors() } })) { _ in errorsView }
        }
    }
    private func row(_ task: SynologyPhotoBackgroundTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.string(task.operation == "copy" ? "photos.tasks.copy" : task.operation == "move" ? "photos.tasks.move" : "photos.tasks.other"), systemImage: task.operation == "move" ? "folder" : "doc.on.doc").font(.headline)
            Text(tasks.model.formattedPhotoDate(Date(timeIntervalSince1970: task.createdAt), includesTime: true)).font(.caption).foregroundStyle(.secondary)
            Text(statusTitle(task)).accessibilityIdentifier("mobile.photos.tasks.status.\(task.id)")
            if task.status == .processing, task.total > 0 {
                ProgressView(value: Double(task.completion), total: Double(task.total))
                    .accessibilityLabel(L10n.string("photos.tasks.progress", task.completion, task.total))
            }
            Text(L10n.string("photos.tasks.counts", task.completion, task.total, task.errors, task.skipped, task.overwritten)).font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { actions(task) }
                VStack(alignment: .leading) { actions(task) }
            }.buttonStyle(.bordered).controlSize(.large)
        }.padding(.vertical, 6)
    }
    @ViewBuilder private func actions(_ task: SynologyPhotoBackgroundTask) -> some View {
        if task.canCancel {
            Button(L10n.string("photos.tasks.cancel")) { tasks.requestCancel(task) }.disabled(!tasks.canControl)
                .accessibilityIdentifier("mobile.photos.tasks.cancel.\(task.id)")
        }
        if task.canClear {
            Button(L10n.string("photos.tasks.clear")) { tasks.requestClear(task) }.disabled(!tasks.canControl)
                .accessibilityIdentifier("mobile.photos.tasks.clear.\(task.id)")
        }
        if task.errors > 0 {
            Button(L10n.string("photos.tasks.errors")) { tasks.showErrors(task) }.accessibilityIdentifier("mobile.photos.tasks.errors.\(task.id)")
        }
        if tasks.canOpenDestination(task) {
            Button(L10n.string("photos.upload.openFolder")) { Task { if await tasks.openDestination(task) { dismiss() } } }
                .disabled(tasks.model.isLoading || tasks.model.isOpeningBackgroundDestination)
                .accessibilityIdentifier("mobile.photos.tasks.open.\(task.id)")
        }
    }
    private func statusTitle(_ task: SynologyPhotoBackgroundTask) -> String {
        switch task.status {
        case .waiting: L10n.string("photos.tasks.waiting")
        case .processing: L10n.string("photos.tasks.processing")
        case .aborting: L10n.string("photos.tasks.aborting")
        case .unknown: L10n.string("photos.tasks.unknown")
        case .done:
            if task.isCancelled { L10n.string("photos.tasks.cancelled") }
            else if task.errors > 0 { L10n.string(task.successfulCount == 0 ? "photos.tasks.failed" : "photos.tasks.partial") }
            else { L10n.string("photos.tasks.done") }
        }
    }
    private var errorsView: some View {
        NavigationStack {
            Group {
                if tasks.loadingErrors { ProgressView() }
                else if let error = tasks.errorsFailure {
                    ContentUnavailableView {
                        Label(L10n.string("photos.tasks.errors"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { tasks.loadErrors() } }
                } else if tasks.entries.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.string("photos.tasks.noErrors"), systemImage: "list.bullet.rectangle")
                    } description: { Text(L10n.string("photos.tasks.noErrorsHint")) }
                } else {
                    List(tasks.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.name ?? L10n.string(entry.kind == .folder ? "photos.tasks.errorKind.folder" : entry.kind == .item ? "photos.tasks.errorKind.item" : "photos.tasks.errorKind.unknown")).font(.headline)
                            if let path = entry.folderPath { Text(path).font(.caption).foregroundStyle(.secondary) }
                            Text(reasonTitle(entry.reason))
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(L10n.string("photos.tasks.errors")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("photos.media.close")) { tasks.closeErrors() }
                        .accessibilityIdentifier("mobile.photos.tasks.errors.close")
                } }
        }
    }
    private func reasonTitle(_ reason: SynologyPhotoBackgroundTaskError.Reason) -> String {
        switch reason {
        case .quota: L10n.string("photos.tasks.reason.quota_full")
        case .space: L10n.string("photos.tasks.reason.space_full")
        case .subfolder: L10n.string("photos.tasks.reason.skipped")
        case .missing: L10n.string("photos.tasks.reason.not_existed")
        case .targetMissing: L10n.string("photos.tasks.reason.target_not_existed")
        case .excluded: L10n.string("photos.tasks.reason.excluded_extension")
        case .unknown: L10n.string("photos.tasks.reason.unknown")
        }
    }
}

struct MobilePhotoControlSheets: ViewModifier {
    @Bindable var session: MobileSynologyPhotosSession
    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { session.folderSharing?.draft }, set: { if $0 == nil { session.folderSharing?.cancel() } }), onDismiss: { session.folderSharing?.cancel() }) { draft in
                if let sharing = session.folderSharing { MobilePhotoFolderSharingForm(sharing: sharing, draft: draft) }
            }
            .sheet(isPresented: Binding(get: { session.tasks?.isPresented == true }, set: { if !$0 { session.tasks?.cancel() } }), onDismiss: { session.tasks?.cancel() }) {
                if let tasks = session.tasks { MobilePhotoTasksView(tasks: tasks) }
            }
    }
}
