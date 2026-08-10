import DsmCore
import Foundation
import UniformTypeIdentifiers

/// 仅在当前聊天编辑器存活期间持有的本地单附件，不进入配置档状态或持久化存储。
struct MobileChatAttachmentSelection: Identifiable {
    let id: UUID
    let localURL: URL
    let directoryURL: URL
    let fileName: String
    let kind: ChatAttachmentKind
    let byteCount: Int64?

    var requiredFeature: ChatFeature {
        Self.requiredFeature(for: kind)
    }

    static func requiredFeature(for kind: ChatAttachmentKind) -> ChatFeature {
        switch kind {
        case .image: .imageAttachment
        case .video: .videoAttachment
        case .file, .voice: .fileAttachment
        }
    }

    static func kind(contentType: UTType?, fileName: String) -> ChatAttachmentKind {
        let resolvedType = contentType ?? UTType(filenameExtension: (fileName as NSString).pathExtension)
        if resolvedType?.conforms(to: .image) == true { return .image }
        if resolvedType?.conforms(to: .movie) == true { return .video }
        return .file
    }
}

enum MobileChatAttachmentSelectionError: Error, Equatable, Sendable {
    case unavailable
    case unsupportedType
    case invalidSelection
}

enum MobileChatRemoteAttachmentPresentationIntent: Sendable {
    case preview
    case exportCopy
}

/// 远端附件下载后仅在系统预览或导出面板存活期间持有的临时文件。
struct MobileChatRemoteAttachmentPresentation: Identifiable {
    let id: UUID
    let title: String
    let localURL: URL
    let directoryURL: URL
    let intent: MobileChatRemoteAttachmentPresentationIntent
}
