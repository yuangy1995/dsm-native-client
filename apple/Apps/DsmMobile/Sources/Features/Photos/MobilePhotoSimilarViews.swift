import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI

/// 分组操作与删除原件使用不同确认；选中照片不会随预览切换重新计算。
struct MobilePhotoSimilarPanel: View {
    @Bindable var session: MobileSynologyPhotosSession
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmation: SynologyPhotosMutation?

    var body: some View {
        NavigationStack {
            List {
                if model.isLoadingSimilarPreview {
                    ProgressView(L10n.string("photos.similar.loading"))
                } else if let error = model.similarPreviewError {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.string("photos.retry")) { Task { await model.retrySimilarPreview() } }
                } else if let detail = model.previewSimilarDetail {
                    Section {
                        if let photo = model.previewPhoto {
                            Button(L10n.string("photos.similar.setTopPick")) { confirmation = .editSimilarGroup(detail, .topPick(photo.id.unitID)) }
                                .disabled(!canEdit || photo.id.unitID == detail.group.topPickID)
                                .accessibilityIdentifier("mobile.photos.similar.topPick")
                        }
                        Button(L10n.string("photos.similar.remove")) {
                            confirmation = .editSimilarGroup(detail, .remove(detail.photos.filter { model.similarSelectedIDs.contains($0.id) }.map(\.id.unitID)))
                        }.disabled(!canEdit || model.similarSelectedIDs.isEmpty).accessibilityIdentifier("mobile.photos.similar.remove")
                        Button(L10n.string("photos.similar.ungroup")) { confirmation = .editSimilarGroup(detail, .ungroup) }
                            .disabled(!canEdit).accessibilityIdentifier("mobile.photos.similar.ungroup")
                        Button(L10n.string("photos.similar.keepSelected"), role: .destructive) {
                            model.requestSimilarCleanup(detail, keeping: model.similarSelectedIDs, closePreviewBeforeConfirmation: false)
                        }.disabled(!canEdit || model.similarSelectedIDs.isEmpty || model.similarSelectedIDs.count >= detail.photos.count || !model.canDeletePhotos(detail.photos.filter { !model.similarSelectedIDs.contains($0.id) }))
                            .accessibilityIdentifier("mobile.photos.similar.cleanup")
                    }
                    Section(L10n.string("photos.similar.count", detail.photos.count)) {
                        ForEach(detail.photos) { photo in
                            HStack(spacing: 12) {
                                MobileSynologyPhotoCell(photo: photo, session: session, isSelecting: false, isSelected: false, showsSimilarBadge: false) {
                                    model.showSimilarPreview(photo); dismiss()
                                }.frame(width: 64, height: 64).accessibilityHidden(true)
                                Button {
                                    model.showSimilarPreview(photo); dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(photo.filename).foregroundStyle(.primary).lineLimit(2)
                                            if photo.id.unitID == detail.group.topPickID { Text(L10n.string("photos.similar.topPick")).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer(minLength: 0)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("mobile.photos.similar.photo.\(photo.id.unitID)")
                                Button {
                                    if !model.similarSelectedIDs.insert(photo.id).inserted { model.similarSelectedIDs.remove(photo.id) }
                                } label: {
                                    Image(systemName: model.similarSelectedIDs.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                                        .frame(minWidth: 44, minHeight: 44)
                                }.buttonStyle(.borderless)
                                    .accessibilityLabel(L10n.string("photos.selection.toggle", photo.filename))
                                    .accessibilityValue(L10n.string(model.similarSelectedIDs.contains(photo.id) ? "photos.selection.selected" : "photos.selection.unselected"))
                                    .accessibilityIdentifier("mobile.photos.similar.select.\(photo.id.unitID)")
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label(L10n.string("photos.category.similar"), systemImage: "square.stack.3d.up")
                    } description: { Text(L10n.string("photos.similar.empty")) }
                }
                if model.similarRecovery != nil || model.isPreparingSimilarBatch || model.managementMessage != nil || model.similarRecoveryError != nil || model.albumRecoveryError != nil {
                    Section {
                        if model.isManaging || model.managementMessage != nil || model.albumRecoveryError != nil || model.pendingMutationID != nil {
                            MobilePhotoManagementStatus(model: model)
                        }
                        MobilePhotoSimilarStatus(model: model)
                    }
                }
            }
            .accessibilityIdentifier("mobile.photos.similar.panel")
            .navigationTitle(L10n.string("photos.category.similar"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("photos.media.close")) { dismiss() }.keyboardShortcut(.cancelAction) } }
            .alert(L10n.string("photos.similar.manage"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { command in
                Button(L10n.string("photos.delete.cancel"), role: .cancel) { confirmation = nil }
                Button(L10n.string("photos.similar.confirm")) { model.submitMutation(command); confirmation = nil }
                    .accessibilityIdentifier("mobile.photos.similar.confirm")
            } message: { command in Text(message(command)) }
        }.modifier(MobileSynologyPhotoDeletionPresentation(model: model, active: true))
    }
    private var canEdit: Bool { model.canStartManagementMutation && !model.isPreparingSimilarBatch && model.managementFeatures.contains(.similarGroups) }
    private func message(_ command: SynologyPhotosMutation) -> String {
        guard case .editSimilarGroup(_, let edit) = command else { return "" }
        switch edit {
        case .topPick: return L10n.string("photos.similar.topPickConfirm")
        case .remove(let ids): return L10n.string("photos.similar.removeConfirm", ids.count)
        case .ungroup: return L10n.string("photos.similar.ungroupConfirm")
        case .undo: return L10n.string("mobile.photos.similar.undoConfirm")
        }
    }
}

struct MobilePhotoSimilarStatus: View {
    @Bindable var model: SynologyPhotosModel
    @State private var confirmsUndo = false
    var body: some View {
        VStack(spacing: 8) {
            if model.isPreparingSimilarBatch { ProgressView(L10n.string("photos.similar.loading")) }
            if let error = model.similarRecoveryError {
                Text(error).fixedSize(horizontal: false, vertical: true)
                Button(L10n.string("photos.retry")) { Task { await model.retrySimilarRecovery() } }
                    .disabled(model.isManaging || model.isPreparingSimilarBatch).accessibilityIdentifier("mobile.photos.similar.retry")
            } else if let batch = model.similarRecovery {
                if batch.isFinished {
                    Text(L10n.string("mobile.photos.similar.finished", batch.count(.confirmed), batch.entries.count - batch.count(.confirmed)))
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("mobile.photos.similar.result")
                }
                if batch.count(.prepared) > 0 {
                    Text(L10n.string("mobile.photos.similar.progress", batch.count(.confirmed), batch.count(.prepared))).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.string("mobile.photos.similar.continue", batch.count(.prepared))) { model.continueSimilarBatch() }
                        .disabled(!model.hasSimilarBatchToContinue).accessibilityIdentifier("mobile.photos.similar.continue")
                    Button(L10n.string("mobile.photos.similar.cancelRemaining")) { model.cancelRemainingSimilarGroups() }
                        .disabled(model.isManaging || model.isPreparingSimilarBatch).accessibilityIdentifier("mobile.photos.similar.cancelRemaining")
                }
                if !batch.undoReceipts.isEmpty {
                    Button(L10n.string("photos.similar.undo")) { confirmsUndo = true }
                        .disabled(!model.canUndoSimilarChanges).accessibilityIdentifier("mobile.photos.similar.undo")
                }
            }
            if let error = model.similarRefreshError {
                Text(error).fixedSize(horizontal: false, vertical: true)
                Button(L10n.string("photos.retry")) { Task { await model.refreshAffectedSimilarGroups() } }
            }
        }.font(.callout).frame(maxWidth: .infinity).buttonStyle(.bordered).controlSize(.large)
            .alert(L10n.string("photos.similar.undo"), isPresented: $confirmsUndo) {
                Button(L10n.string("photos.delete.cancel"), role: .cancel) {}
                Button(L10n.string("photos.similar.confirm")) { model.undoSimilarChanges() }
            } message: { Text(L10n.string("mobile.photos.similar.undoConfirm")) }
    }
}
