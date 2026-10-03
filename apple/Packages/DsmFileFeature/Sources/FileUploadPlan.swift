import Foundation

/// 选择器授权覆盖整个选择根；文件夹内的子项不能仅靠自身 URL 延长授权。
public final class FileUploadSourceAccess: @unchecked Sendable {
    public let url: URL
    private let accessed: Bool
    public init(_ url: URL) { self.url = url; accessed = url.startAccessingSecurityScopedResource() }
    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}

public struct FileUploadSource: Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case directory, file, symbolicLink, unreadable }
    public let id: UUID
    public let url: URL
    public let relativePath: String
    public let kind: Kind
    public let size: Int64
    public let modifiedAt: Date?
    public let access: FileUploadSourceAccess

    public init(id: UUID = UUID(), url: URL, relativePath: String, kind: Kind, size: Int64,
                modifiedAt: Date?, access: FileUploadSourceAccess) {
        self.id = id; self.url = url; self.relativePath = relativePath; self.kind = kind
        self.size = size; self.modifiedAt = modifiedAt; self.access = access
    }
}

public enum FileUploadPlan {
    public static func collect(_ urls: [URL]) throws -> [FileUploadSource] {
        var result: [FileUploadSource] = []
        var paths = Set<String>()
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey,
                                       .fileSizeKey, .contentModificationDateKey]
        func visit(_ url: URL, relative: String, access: FileUploadSourceAccess) throws {
            try Task.checkCancellation()
            guard paths.insert(url.standardizedFileURL.path).inserted else { return }
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: keys) }
            catch {
                result.append(.init(url: url, relativePath: relative, kind: .unreadable,
                                    size: 0, modifiedAt: nil, access: access))
                return
            }
            let kind: FileUploadSource.Kind = values.isSymbolicLink == true ? .symbolicLink
                : values.isDirectory == true ? .directory : values.isRegularFile == true ? .file : .unreadable
            result.append(.init(url: url, relativePath: relative, kind: kind,
                size: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate, access: access))
            guard kind == .directory else { return }
            do {
                let children = try FileManager.default.contentsOfDirectory(at: url,
                    includingPropertiesForKeys: Array(keys), options: []).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children { try visit(child, relative: relative + "/" + child.lastPathComponent, access: access) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                result.append(.init(url: url, relativePath: relative, kind: .unreadable,
                    size: 0, modifiedAt: nil, access: access))
            }
        }
        for url in urls where url.isFileURL {
            try visit(url, relative: url.lastPathComponent, access: FileUploadSourceAccess(url))
        }
        return result
    }
}
