import DsmCore
import DsmLocalization
import SwiftUI

struct MobilePhotoPreviewRepairView: View {
    @Bindable var repair: MobilePhotoPreviewRepairModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if repair.model.spaces.count > 1 {
                    Picker(L10n.string("photos.library.space"), selection: Binding(get: { repair.space }, set: { repair.selectSpace($0) })) {
                        ForEach(repair.model.spaces, id: \.self) { space in
                            Text(L10n.string(space == .personal ? "mobile.photos.source.mine" : "mobile.photos.source.shared")).tag(space)
                        }
                    }.pickerStyle(.segmented).padding().accessibilityIdentifier("mobile.photos.repair.space")
                }
                Group {
                    if repair.isLoading {
                        ProgressView(L10n.string("mobile.photos.repair.loading")).accessibilityIdentifier("mobile.photos.repair.loading")
                    } else if let error = repair.error {
                        ContentUnavailableView {
                            Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                        } description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { repair.load() } }
                    } else if repair.photos.isEmpty {
                        ContentUnavailableView {
                            Label(L10n.string("photos.preview.recovery.empty"), systemImage: "checkmark.circle")
                        } description: { Text(L10n.string("photos.preview.recovery.emptyHint")) } actions: { refreshButton }
                    } else if repair.visiblePhotos.isEmpty {
                        ContentUnavailableView {
                            Label(L10n.string("photos.library.noResults"), systemImage: "magnifyingglass")
                        } actions: { Button(L10n.string("mobile.photos.timeline.action.clear-search")) { repair.search = "" } }
                    } else {
                        List(repair.visiblePhotos) { photo in
                            Button { repair.toggle(photo) } label: {
                                HStack {
                                    Image(systemName: repair.selected.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                                    Text(photo.filename).foregroundStyle(.primary).lineLimit(2)
                                    Spacer(minLength: 0)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.accessibilityLabel(photo.filename)
                                .accessibilityAddTraits(repair.selected.contains(photo.id) ? [.isSelected] : [])
                                .accessibilityIdentifier("mobile.photos.repair.item.\(photo.id.unitID)")
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !repair.photos.isEmpty && repair.error == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.string("photos.selection.count", repair.selected.count))
                            Spacer()
                            refreshButton
                            Button { repair.selectVisible() } label: { Image(systemName: "checkmark.circle.fill") }
                                .accessibilityLabel(L10n.string("photos.selection.loaded")).accessibilityIdentifier("mobile.photos.repair.select")
                            Button { repair.clearSelection() } label: { Image(systemName: "circle") }
                                .accessibilityLabel(L10n.string("photos.preview.recovery.clear")).accessibilityIdentifier("mobile.photos.repair.clear")
                        }.buttonStyle(.bordered).controlSize(.large)
                        if repair.photos.count > 100 { Text(L10n.string("photos.preview.recovery.limit")).font(.caption).foregroundStyle(.secondary) }
                    }.padding().background(.bar)
                }
                if repair.model.pendingMutationID != nil || repair.model.albumRecoveryError != nil {
                    MobilePhotoManagementStatus(model: repair.model)
                }
            }
            .searchable(text: $repair.search, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("mobile.photos.timeline.search.prompt"))
            .navigationTitle(L10n.string("photos.preview.recovery.title")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.string("photos.media.close")) { repair.cancel(); dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(L10n.string("mobile.photos.repair.resume")) { if repair.resume() { dismiss() } }
                        .disabled(!repair.canResume).accessibilityIdentifier("mobile.photos.repair.resume")
                }
            }
            .onChange(of: repair.model.pendingMutationID) { _, value in
                if value == nil, repair.isPresented { repair.load() }
            }
        }
    }
    private var refreshButton: some View {
        Button { repair.load() } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel(L10n.string("photos.library.refresh"))
            .disabled(repair.isLoading).accessibilityIdentifier("mobile.photos.repair.refresh")
    }
}

struct MobilePhotoPreviewRepairPresentation: ViewModifier {
    @Bindable var session: MobileSynologyPhotosSession
    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { session.previewRepair?.isPresented == true }, set: { if !$0 { session.previewRepair?.cancel() } }), onDismiss: { session.previewRepair?.cancel() }) {
            if let repair = session.previewRepair { MobilePhotoPreviewRepairView(repair: repair) }
        }
    }
}
