import DsmCore
import DsmLocalization
import SwiftUI

struct MobilePhotoViewerNavigationControls: View {
    let state: MobilePhotoViewerState
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSaveCopy: () -> Void
    let onShare: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            navigationButton(
                key: "mobile.photos.viewer.action.previous",
                systemImage: "chevron.backward",
                enabled: state.canMovePrevious,
                shortcut: .leftArrow,
                action: onPrevious
            )
            if let selectedIndex = state.selectedIndex {
                Text(L10n.string(
                    "mobile.photos.viewer.position",
                    selectedIndex + 1,
                    state.snapshot.count
                ))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string(
                    "mobile.photos.viewer.position",
                    selectedIndex + 1,
                    state.snapshot.count
                ))
            }
            navigationButton(
                key: "mobile.photos.viewer.action.next",
                systemImage: "chevron.forward",
                enabled: state.canMoveNext,
                shortcut: .rightArrow,
                action: onNext
            )
            actionButton(
                key: "mobile.photos.action.save-copy",
                systemImage: "square.and.arrow.down",
                shortcut: "s",
                action: onSaveCopy
            )
            actionButton(
                key: "mobile.photos.action.share",
                systemImage: "square.and.arrow.up",
                action: onShare
            )
        }
    }

    private func navigationButton(
        key: String,
        systemImage: String,
        enabled: Bool,
        shortcut: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(L10n.string(key), systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .keyboardShortcut(shortcut, modifiers: [])
        .accessibilityLabel(L10n.string(key))
    }

    @ViewBuilder
    private func actionButton(
        key: String,
        systemImage: String,
        shortcut: KeyEquivalent? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
            Label(L10n.string(key), systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(state.selectedItem == nil)
        .accessibilityLabel(L10n.string(key))
        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: [.command])
        } else {
            button
        }
    }
}

struct MobilePhotoMetadataView: View {
    let viewer: MobilePhotoViewerModel
    let previewState: MobileFilePreviewState

    var body: some View {
        Group {
            switch viewer.state.metadataPhase {
            case .inactive, .unavailable:
                unavailableView
            case .loading where viewer.state.metadata == nil:
                ProgressView(L10n.string("mobile.photos.viewer.metadata.loading"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView(
                    L10n.string("mobile.photos.viewer.metadata.failed.title"),
                    systemImage: "info.circle",
                    description: Text(L10n.string("mobile.photos.viewer.metadata.failed.message"))
                )
            case .loading, .content:
                if let metadata = viewer.state.metadata {
                    metadataList(metadata)
                } else {
                    unavailableView
                }
            }
        }
        .task(id: requestIdentity) {
            await viewer.loadMetadata(from: previewState)
        }
    }

    private var unavailableView: some View {
        ContentUnavailableView(
            L10n.string("mobile.photos.viewer.metadata.unavailable.title"),
            systemImage: "info.circle",
            description: Text(L10n.string("mobile.photos.viewer.metadata.unavailable.message"))
        )
    }

    private func metadataList(_ metadata: MobilePhotoMetadata) -> some View {
        List {
            Section(L10n.string("mobile.photos.viewer.metadata.section.file")) {
                row("mobile.photos.viewer.metadata.name", metadata.name)
                row("mobile.photos.viewer.metadata.kind", kindLabel(metadata.kind))
                if let sizeBytes = metadata.sizeBytes {
                    row("mobile.photos.viewer.metadata.size", formattedSize(sizeBytes))
                }
                if let createdAt = metadata.createdAt {
                    row("mobile.photos.viewer.metadata.created", formattedDate(createdAt))
                }
                if let modifiedAt = metadata.modifiedAt {
                    row("mobile.photos.viewer.metadata.modified", formattedDate(modifiedAt))
                }
            }
            if metadata.pixelWidth != nil || metadata.pixelHeight != nil || metadata.capturedAt != nil {
                Section(L10n.string("mobile.photos.viewer.metadata.section.photo")) {
                    if let width = metadata.pixelWidth, let height = metadata.pixelHeight {
                        row("mobile.photos.viewer.metadata.dimensions", L10n.string(
                            "mobile.photos.viewer.metadata.dimensions.value", width, height
                        ))
                    }
                    if let capturedAt = metadata.capturedAt {
                        row("mobile.photos.viewer.metadata.captured", formattedDate(capturedAt))
                    }
                }
            }
            if metadata.cameraMake != nil || metadata.cameraModel != nil {
                Section(L10n.string("mobile.photos.viewer.metadata.section.camera")) {
                    if let make = metadata.cameraMake {
                        row("mobile.photos.viewer.metadata.camera.make", make)
                    }
                    if let model = metadata.cameraModel {
                        row("mobile.photos.viewer.metadata.camera.model", model)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay(alignment: .topTrailing) {
            if viewer.state.metadataPhase == .loading {
                ProgressView()
                    .padding()
                    .accessibilityLabel(L10n.string("mobile.photos.viewer.metadata.loading"))
            }
        }
    }

    private func row(_ key: String, _ value: String) -> some View {
        LabeledContent(L10n.string(key)) {
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private func kindLabel(_ kind: PhotoLibraryItemKind) -> String {
        L10n.string(kind == .video
            ? "mobile.photos.viewer.metadata.kind.video"
            : "mobile.photos.viewer.metadata.kind.image")
    }

    private func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatStyle(style: .file).locale(L10n.locale).format(bytes)
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var requestIdentity: String {
        let item = previewState.selectedItem
        return "\(item?.profileID.uuidString ?? "")|\(item?.path ?? "")|\(item?.times?.modifiedAt?.timeIntervalSince1970 ?? -1)|\(item?.sizeBytes ?? -1)|\(previewState.phase)|\(previewState.artifactURL?.path ?? "")"
    }
}
