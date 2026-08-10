import DsmCore
import DsmLocalization
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// iPhone 与 iPad 共用的单附件聊天编辑器。
/// 系统选择器、预览和导出界面由系统组件完成，避免保存选择器返回的本地路径。
struct MobileChatAttachmentComposer: View {
    @Bindable var chat: MobileChatModel
    @State private var photoAttachmentItem: PhotosPickerItem?
    @State private var isImportingAttachmentFile = false
    @State private var showsSelectedAttachmentPreview = false

    var body: some View {
        let state = chat.state
        VStack(alignment: .leading, spacing: 8) {
            feedback(state)
            if let attachment = chat.selectedAttachment {
                selectedAttachmentChip(attachment)
            }
            if state.isSendingAttachment {
                sendingStatus(state)
            }
            HStack(alignment: .bottom, spacing: 8) {
                pickerActions
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("mobile.chat.composer.label"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        L10n.string("mobile.chat.send.placeholder"),
                        text: draftBinding,
                        axis: .vertical
                    )
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { Task { await chat.sendSelectedMessage() } }
                    .disabled(state.isSendingMessage || state.isSendingAttachment || state.isPreparingAttachment)
                    .accessibilityLabel(L10n.string("mobile.chat.composer.label"))
                    .accessibilityHint(L10n.string("mobile.chat.send.hint"))
                }
                Button {
                    Task { await chat.sendSelectedMessage() }
                } label: {
                    if state.isSendingMessage || state.isSendingAttachment {
                        ProgressView()
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .frame(width: 24, height: 24)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!chat.canSendSelectedDraft)
                .accessibilityLabel(
                    state.isSendingMessage || state.isSendingAttachment
                        ? L10n.string("mobile.chat.sending")
                        : L10n.string("mobile.chat.action.send")
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .fileImporter(
            isPresented: $isImportingAttachmentFile,
            allowedContentTypes: fileTypes,
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
        .onChange(of: photoAttachmentItem) { _, item in
            guard let item else { return }
            photoAttachmentItem = nil
            chat.preparePhotoAttachment(MobileSystemPhotosPickerItem(item))
        }
        .sheet(isPresented: $showsSelectedAttachmentPreview) {
            if let attachment = chat.selectedAttachment {
                MobileQuickLookPreview(
                    localURL: attachment.localURL,
                    title: attachment.fileName,
                    onDismiss: { showsSelectedAttachmentPreview = false }
                )
            }
        }
    }

    @ViewBuilder
    private func feedback(_ state: MobileChatProfileState) -> some View {
        if state.isPreparingAttachment {
            Label(L10n.string("mobile.chat.attachment.preparing"), systemImage: "hourglass")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        } else if state.attachmentReviewRequired {
            Label(L10n.string("mobile.chat.attachment.review"), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        } else if state.attachmentErrorCategory != nil {
            Label(L10n.string("mobile.chat.attachment.failed"), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        } else if state.selectedDraftRequiresReview {
            Label(L10n.string("mobile.chat.send.review"), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        } else if state.sendErrorCategory != nil {
            Label(L10n.string("mobile.chat.send.failed"), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        }
    }

    private var pickerActions: some View {
        HStack(spacing: 8) {
            if chat.state.availability.supportedFeatures.contains(.imageAttachment) {
                PhotosPicker(
                    selection: $photoAttachmentItem,
                    matching: .images,
                    preferredItemEncoding: .current
                ) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .frame(width: 24, height: 24)
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!chat.canSelectAttachment)
                .accessibilityLabel(L10n.string("mobile.chat.attachment.action.photos"))
                .accessibilityHint(L10n.string("mobile.chat.attachment.photos.hint"))
            }
            if supportsFileImport {
                Button {
                    isImportingAttachmentFile = true
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 24, height: 24)
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!chat.canSelectAttachment)
                .accessibilityLabel(L10n.string("mobile.chat.attachment.action.files"))
                .accessibilityHint(L10n.string("mobile.chat.attachment.files.hint"))
            }
        }
    }

    private func selectedAttachmentChip(_ attachment: MobileChatAttachmentSelection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage(for: attachment.kind))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(attachment.fileName)
                .font(.subheadline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                showsSelectedAttachmentPreview = true
            } label: {
                Image(systemName: "eye")
                    .frame(width: 24, height: 24)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(L10n.string("mobile.chat.attachment.action.preview"))
            .accessibilityHint(L10n.string("mobile.chat.attachment.preview.hint"))
            Button {
                chat.removeSelectedAttachment()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .frame(minWidth: 44, minHeight: 44)
            .disabled(chat.state.isSendingAttachment)
            .accessibilityLabel(L10n.string("mobile.chat.attachment.action.remove"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private func sendingStatus(_ state: MobileChatProfileState) -> some View {
        HStack(spacing: 8) {
            if let fraction = state.attachmentProgressFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel(progressLabel(fraction))
            } else {
                ProgressView()
                    .accessibilityLabel(L10n.string("mobile.chat.attachment.sending"))
            }
            Text(L10n.string("mobile.chat.attachment.sending"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                chat.cancelSelectedAttachmentSend()
            } label: {
                Label(L10n.string("mobile.chat.attachment.action.cancel"), systemImage: "xmark")
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityElement(children: .contain)
    }

    private var supportsFileImport: Bool {
        let features = chat.state.availability.supportedFeatures
        return features.contains(.fileAttachment) || features.contains(.videoAttachment)
    }

    private var fileTypes: [UTType] {
        let features = chat.state.availability.supportedFeatures
        if features.contains(.fileAttachment) { return [.data] }
        var types: [UTType] = []
        if features.contains(.imageAttachment) { types.append(.image) }
        if features.contains(.videoAttachment) { types.append(.movie) }
        return types.isEmpty ? [.data] : types
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { chat.state.selectedDraft },
            set: { chat.setDraft($0) }
        )
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard urls.count == 1, let url = urls.first else {
                chat.rejectAttachmentSelection()
                return
            }
            chat.prepareFileAttachment(url)
        case .failure:
            chat.rejectAttachmentSelection()
        }
    }
}

/// 将远端附件临时文件交给系统预览或导出面板；面板关闭即清理专用临时目录。
private struct MobileChatRemoteAttachmentPresentationModifier: ViewModifier {
    @Bindable var chat: MobileChatModel

    func body(content: Content) -> some View {
        content.sheet(
            item: presentationBinding,
            onDismiss: chat.dismissRemoteAttachmentPresentation
        ) { presentation in
            switch presentation.intent {
            case .preview:
                MobileQuickLookPreview(
                    localURL: presentation.localURL,
                    title: presentation.title,
                    onDismiss: chat.dismissRemoteAttachmentPresentation
                )
            case .exportCopy:
                MobileDocumentExporter(url: presentation.localURL) {
                    chat.dismissRemoteAttachmentPresentation()
                }
            }
        }
    }

    private var presentationBinding: Binding<MobileChatRemoteAttachmentPresentation?> {
        Binding(
            get: { chat.remoteAttachmentPresentation },
            set: { presentation in
                if presentation == nil {
                    chat.dismissRemoteAttachmentPresentation()
                }
            }
        )
    }
}

extension View {
    func mobileChatRemoteAttachmentPresentation(chat: MobileChatModel) -> some View {
        modifier(MobileChatRemoteAttachmentPresentationModifier(chat: chat))
    }
}

struct MobileChatRemoteAttachmentRow: View {
    @Bindable var chat: MobileChatModel
    let message: ChatMessage
    let attachment: ChatAttachment

    var body: some View {
        Group {
            if chat.canUseRemoteAttachment(attachment, in: message) {
                supportedContent
            } else {
                readOnlyContent
            }
        }
        .task(id: thumbnailTaskID) {
            guard attachment.kind == .image else { return }
            chat.loadAttachmentThumbnail(for: message)
        }
    }

    private var supportedContent: some View {
        let state = chat.state
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                visual(state)
                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.fileName)
                        .font(.subheadline)
                        .lineLimit(2)
                    Text(kindLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if state.remoteAttachmentMessageID == message.id {
                transferStatus(state)
            }
            if state.remoteAttachmentErrorMessageID == message.id,
               state.remoteAttachmentErrorCategory != nil {
                Label(
                    L10n.string("mobile.chat.attachment.remote.failed"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }
            HStack(spacing: 8) {
                Button {
                    chat.previewRemoteAttachment(attachment, in: message)
                } label: {
                    Label(
                        L10n.string("mobile.chat.attachment.action.preview"),
                        systemImage: "eye"
                    )
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .disabled(!chat.canOpenRemoteAttachment(attachment, in: message))
                .accessibilityHint(L10n.string("mobile.chat.attachment.preview.hint"))
                Button {
                    chat.saveRemoteAttachment(attachment, in: message)
                } label: {
                    Label(
                        L10n.string("mobile.chat.attachment.action.save"),
                        systemImage: "square.and.arrow.down"
                    )
                }
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .disabled(!chat.canOpenRemoteAttachment(attachment, in: message))
                .accessibilityHint(L10n.string("mobile.chat.attachment.save.hint"))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private var readOnlyContent: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName)
                    .font(.subheadline)
                Text(L10n.string("mobile.chat.attachment.read-only"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage(for: attachment.kind))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func visual(_ state: MobileChatProfileState) -> some View {
        if attachment.kind == .image,
           let data = state.attachmentThumbnailsByMessageID[message.id],
           let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 72)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityLabel(attachment.fileName)
        } else if attachment.kind == .image,
                  state.loadingAttachmentThumbnailIDs.contains(message.id) {
            ProgressView()
                .frame(width: 72, height: 72)
                .accessibilityLabel(L10n.string("mobile.chat.attachment.thumbnail.loading"))
        } else {
            Image(systemName: systemImage(for: attachment.kind))
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 72, height: 72)
                .background(.quaternary, in: .rect(cornerRadius: 8))
                .accessibilityHidden(true)
        }
    }

    private func transferStatus(_ state: MobileChatProfileState) -> some View {
        HStack(spacing: 8) {
            if let fraction = state.remoteAttachmentProgressFraction {
                ProgressView(value: fraction)
                    .accessibilityLabel(progressLabel(fraction))
            } else {
                ProgressView()
                    .accessibilityLabel(L10n.string("mobile.chat.attachment.remote.loading"))
            }
            Text(L10n.string("mobile.chat.attachment.remote.loading"))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                chat.cancelRemoteAttachmentDownload()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(L10n.string("mobile.chat.attachment.action.cancel"))
        }
        .accessibilityElement(children: .contain)
    }

    private var kindLabel: String {
        switch attachment.kind {
        case .image:
            L10n.string("mobile.chat.attachment.kind.image")
        case .video:
            L10n.string("mobile.chat.attachment.kind.video")
        case .file, .voice:
            L10n.string("mobile.chat.attachment.kind.file")
        }
    }

    private var thumbnailTaskID: String {
        "\(message.id)-\(attachment.id)"
    }
}

private func systemImage(for kind: ChatAttachmentKind) -> String {
    switch kind {
    case .image: "photo"
    case .video: "video"
    case .file: "doc"
    case .voice: "waveform"
    }
}

private func progressLabel(_ fraction: Double) -> String {
    L10n.string(
        "mobile.chat.attachment.progress.accessibility",
        Int64((fraction * 100).rounded())
    )
}
