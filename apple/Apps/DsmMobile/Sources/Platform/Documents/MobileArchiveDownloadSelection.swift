import CryptoKit
import DsmCore
import Foundation

/// 只保存用户选定的原路径与类型，恢复时不依赖当前目录或翻译后的文件名。
struct MobileArchiveDownloadSource: Codable, Equatable, Sendable {
    let path: String
    let isDirectory: Bool
}

enum MobileArchiveDownloadSelection {
    static let maximumCount = 20

    static func canSelect(_ item: FileItem, profileID: UUID) -> Bool {
        item.profileID == profileID && (item.kind == .file || item.kind == .directory)
            && item.permissions?.canRead != false && isValidPath(item.path)
    }

    static func sources(_ items: [FileItem], profileID: UUID) -> [MobileArchiveDownloadSource]? {
        guard items.allSatisfy({ canSelect($0, profileID: profileID) }) else { return nil }
        let sources = items.map { MobileArchiveDownloadSource(path: $0.path, isDirectory: $0.isDirectory) }
        return isValid(sources) ? sources : nil
    }

    static func isValid(_ sources: [MobileArchiveDownloadSource]) -> Bool {
        guard !sources.isEmpty, sources.count <= maximumCount,
              sources.count > 1 || sources[0].isDirectory,
              Set(sources.map(\.path)).count == sources.count,
              sources.allSatisfy({ isValidPath($0.path) }) else { return false }
        // 同时选择目录和其内容会在压缩副本中重复包含项目。
        return !sources.contains { source in
            sources.contains { $0.path != source.path && $0.isDirectory && source.path.hasPrefix($0.path + "/") }
        }
    }

    static func identity(_ sources: [MobileArchiveDownloadSource]) -> String {
        let value = sources.sorted { $0.path < $1.path }.map {
            "\($0.path.utf8.count):\($0.path):\($0.isDirectory ? 1 : 0)"
        }.joined()
        return "archive:" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"), !path.contains("//") else { return false }
        return !path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }
}
