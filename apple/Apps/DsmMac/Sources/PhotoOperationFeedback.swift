import AppKit
import DsmLocalization
import DsmPhotosFeature
import SwiftUI

/// 所有照片窗口保留同一组恢复操作，避免弹窗覆盖主页后找不到继续入口。
struct PhotoOperationFeedback: View {
    @Bindable var model: SynologyPhotosModel
    var showBackgroundTasks: (() -> Void)? = nil

    private var hasManagementActions: Bool {
        model.pendingMutationID != nil || model.needsSharedListRefresh || model.hasSimilarBatchToContinue ||
            model.similarUndoMutation != nil || model.temporarySharingCleanupNeedsRetry ||
            model.retryableManagementMutation != nil || model.managementLink != nil
    }

    var body: some View {
        if let message = model.managementMessage {
            MacOperationFeedback(message: message,
                isWorking: model.isManaging && !model.isGeneratingAutomaticPreview && !model.isUploading,
                keepsVisible: hasManagementActions) {
                VStack(alignment: .leading, spacing: 8) {
                    if let showBackgroundTasks, model.managementFeatures.contains(.backgroundTasks), model.isManaging || model.pendingMutationID != nil {
                        Button(L10n.string("photos.tasks.title")) { showBackgroundTasks() }
                    }
                    if model.needsSharedListRefresh {
                        Button(L10n.string("photos.library.refresh")) { Task { await model.retrySharedListRefresh() } }
                            .disabled(model.isManaging || model.isLoadingMore)
                    }
                    if model.hasSimilarBatchToContinue {
                        Button(L10n.string("photos.similar.continueGroups")) { model.continueSimilarBatch() }
                        Button(L10n.string("photos.similar.cancelRemaining")) { model.cancelRemainingSimilarGroups() }
                    }
                    if model.similarUndoMutation != nil {
                        Button(L10n.string("photos.similar.undo")) { model.undoSimilarChanges() }
                            .disabled(model.isManaging || model.pendingMutationID != nil || model.hasSimilarBatchToContinue)
                    }
                    if model.pendingMutationID != nil && model.automaticMutationReviewID == nil && !model.isManaging {
                        Button(L10n.string("photos.selection.retryReview")) { model.reviewPendingMutation() }
                    }
                    if model.temporarySharingCleanupNeedsRetry {
                        Button(L10n.string("photos.retry")) { model.retryTemporarySharingCleanup() }
                            .disabled(model.isManaging || model.pendingMutationID != nil)
                        Button(L10n.string("photos.temporary.keepExisting")) { model.keepTemporarySharingAlbums() }
                            .disabled(model.isManaging || model.pendingMutationID != nil)
                    }
                    if model.retryableManagementMutation != nil {
                        Button(L10n.string("photos.manage.continueRemaining")) { model.continuePartialManagement() }
                            .disabled(model.isManaging || model.pendingMutationID != nil)
                    }
                    if let url = model.managementLink {
                        Button(L10n.string("photos.copyLink")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                    }
                }
            }
            .accessibilityIdentifier("photos.operation.feedback")
        }
        if model.isSaving {
            MacOperationFeedback(message: L10n.string("photos.download.saving"), isWorking: true) {
                HStack {
                    ProgressView(value: model.saveProgress)
                    Button(L10n.string("photos.download.cancel")) { model.cancelSave() }
                }
            }.accessibilityIdentifier("photos.preview.saveProgress")
        } else if let message = model.saveMessage {
            MacOperationFeedback(message: message).accessibilityIdentifier("photos.preview.saveMessage")
        }
        if let error = model.similarRefreshError {
            MacOperationFeedback(message: error, isError: true, keepsVisible: true) {
                Button(L10n.string("photos.retry")) { Task { await model.refreshAffectedSimilarGroups() } }
            }
        }
        if model.previewData != nil, let error = model.previewError {
            MacOperationFeedback(message: error, isError: true, keepsVisible: true) {
                Button(L10n.string("photos.retry")) {
                    if let photo = model.previewPhoto { model.showPreview(photo) }
                }
            }
        }
        if let message = model.deletionMessage {
            MacOperationFeedback(message: message, isWorking: model.isDeleting || model.isCheckingDeletion)
        }
    }
}
