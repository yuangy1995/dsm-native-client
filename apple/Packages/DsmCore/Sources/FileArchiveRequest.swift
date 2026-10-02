import Foundation

public struct ArchiveItemPage: Sendable {
    public let items: [ArchiveItem]
    public let offset: Int
    public let total: Int?
    public let hasMore: Bool
    public init(items: [ArchiveItem], offset: Int, total: Int?, hasMore: Bool) {
        self.items = items; self.offset = offset; self.total = total; self.hasMore = hasMore
    }
}

public enum FileArchiveSelection: Sendable, Equatable {
    case all
    case items([ArchiveItem])
    public var isValid: Bool {
        switch self {
        case .all: true
        case .items(let items): !items.isEmpty && items.allSatisfy { $0.id >= 0 && Self.safeRelativePath($0.path) }
        }
    }
    public static func safeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":")
            && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
    }
}

/// 密码只在一次解压操作内存中持有，不写入活动任务持久化。
public struct FileExtractionRequest: Sendable {
    public let filePath: String
    public let destination: String
    public let selection: FileArchiveSelection
    public let overwrite: Bool
    public let keepDirectories: Bool
    public let createSubfolder: Bool
    public let codepage: String?
    public let password: String?
    public init(filePath: String, destination: String, selection: FileArchiveSelection = .all,
                overwrite: Bool = false, keepDirectories: Bool = true, createSubfolder: Bool = true,
                codepage: String? = nil, password: String? = nil) {
        self.filePath = filePath; self.destination = destination; self.selection = selection
        self.overwrite = overwrite; self.keepDirectories = keepDirectories; self.createSubfolder = createSubfolder
        self.codepage = codepage; self.password = password
    }
}
