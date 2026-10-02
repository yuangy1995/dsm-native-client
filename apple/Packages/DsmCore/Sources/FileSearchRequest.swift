import Foundation

public enum FileSearchKind: String, CaseIterable, Sendable { case all, file, directory = "dir" }

public struct FileSearchTimeRange: Equatable, Sendable {
    public var from: Date?
    public var to: Date?
    public init(from: Date? = nil, to: Date? = nil) { self.from = from; self.to = to }
    public var isValid: Bool {
        [from, to].compactMap { $0 }.allSatisfy { $0.timeIntervalSince1970.isFinite && $0.timeIntervalSince1970 >= 0 && $0.timeIntervalSince1970 < Double(Int.max) }
            && (from == nil || to == nil || from! <= to!)
    }
}

/// 条件之间按 AND 组合；名称正则由界面过滤，不作为 DSM glob 参数发送。
public struct FileSearchRequest: Equatable, Sendable {
    public var folders: [String]
    public var recursive: Bool
    public var name: String
    public var fileExtension: String
    public var kind: FileSearchKind
    public var minimumBytes: Int64?
    public var maximumBytes: Int64?
    public var modified: FileSearchTimeRange
    public var created: FileSearchTimeRange
    public var accessed: FileSearchTimeRange
    public var owner: String
    public var group: String
    /// 内部索引搜索扩展；不下载文件模拟正文搜索。
    public var searchesContents: Bool

    public init(folders: [String], recursive: Bool = true, name: String = "",
                fileExtension: String = "", kind: FileSearchKind = .all,
                minimumBytes: Int64? = nil, maximumBytes: Int64? = nil,
                modified: FileSearchTimeRange = .init(), created: FileSearchTimeRange = .init(),
                accessed: FileSearchTimeRange = .init(), owner: String = "", group: String = "",
                searchesContents: Bool = false) {
        self.folders = folders; self.recursive = recursive; self.name = name
        self.fileExtension = fileExtension; self.kind = kind
        self.minimumBytes = minimumBytes; self.maximumBytes = maximumBytes
        self.modified = modified; self.created = created; self.accessed = accessed
        self.owner = owner; self.group = group
        self.searchesContents = searchesContents
    }

    public var isValid: Bool {
        !folders.isEmpty && folders.allSatisfy {
            $0.hasPrefix("/") && $0 != "/" && !$0.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        } && [minimumBytes, maximumBytes].compactMap { $0 }.allSatisfy { $0 >= 0 }
            && (minimumBytes == nil || maximumBytes == nil || minimumBytes! <= maximumBytes!)
            && modified.isValid && created.isValid && accessed.isValid
            && (!searchesContents || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

public enum FileSearchIndexCoverage: Sendable, Equatable {
    case notRequested, complete, incomplete
}

public struct FileSearchResult: Sendable, Equatable {
    public let items: [FileItem]
    public let indexCoverage: FileSearchIndexCoverage
    public init(items: [FileItem], indexCoverage: FileSearchIndexCoverage = .notRequested) {
        self.items = items; self.indexCoverage = indexCoverage
    }
}
