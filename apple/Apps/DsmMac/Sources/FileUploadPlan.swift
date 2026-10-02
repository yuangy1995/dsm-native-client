import Foundation

/// 选择器授权覆盖整个选择根；文件夹内的子项不能仅靠自身 URL 延长授权。
final class FileUploadSourceAccess: @unchecked Sendable {
    let url: URL
    private let accessed: Bool
    init(_ url: URL) { self.url = url; accessed = url.startAccessingSecurityScopedResource() }
    deinit { if accessed { url.stopAccessingSecurityScopedResource() } }
}

struct FileUploadSource: Identifiable, Sendable {
    enum Kind: Sendable { case directory, file, symbolicLink, unreadable }
    let id = UUID()
    let url: URL
    let relativePath: String
    let kind: Kind
    let size: Int64
    let modifiedAt: Date?
    let access: FileUploadSourceAccess
}

enum FileUploadPlan {
    static func collect(_ urls: [URL]) throws -> [FileUploadSource] {
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
