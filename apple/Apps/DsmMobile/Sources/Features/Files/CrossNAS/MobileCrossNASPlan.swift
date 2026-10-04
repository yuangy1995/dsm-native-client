import DsmCore
import DsmNetwork
import Foundation

protocol MobileCrossNASRepository: AnyObject, Sendable {
    var profileID: UUID { get }
    func listFolder(path: String, offset: Int, limit: Int) async throws -> FilePage
    func getInfo(paths: [String]) async throws -> [FileItem]
    func fileMD5(remotePath: String) async throws -> String
    func createFolder(parentPath: String, name: String) async throws
    func deleteResult(paths: [String], recursive: Bool, progress: @escaping FileTransferProgress) async throws -> MutationResult
    func copyCrossNAS(_ item: FileItem, to target: any MobileCrossNASRepository,
                      folder: String, progress: @escaping FileTransferProgress) async throws
}

extension DsmFileRepository: MobileCrossNASRepository {
    func copyCrossNAS(_ item: FileItem, to target: any MobileCrossNASRepository,
                      folder: String, progress: @escaping FileTransferProgress) async throws {
        guard let target = target as? DsmFileRepository, let size = item.sizeBytes else {
            throw MobileCrossNASFailure.invalid
        }
        try await streamFileToNAS(remotePath: item.path, filename: item.name, expectedSize: size,
            target: target, destinationFolder: folder, overwrite: false, progress: progress)
    }
}

/// 只读清单先于所有写入；路径、分页与完整内容都来自各自的会话。
enum MobileCrossNASPlan {
    static func validPath(_ value: String) -> Bool {
        value.hasPrefix("/") && value != "/" && !value.hasSuffix("/") && !value.contains("//") &&
        !value.contains("\0") && !value.split(separator: "/").contains { $0 == "." || $0 == ".." || $0.lowercased() == "#recycle" }
    }
    static func parent(_ path: String) -> String { path.lastIndex(of: "/").map { String(path.prefix(upTo: $0)) } ?? "" }
    static func leaf(_ path: String) -> String { path.lastIndex(of: "/").map { String(path.suffix(from: path.index(after: $0))) } ?? path }
    static func validDigest(_ value: String?) -> Bool {
        guard let value, value.count == 32 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func isLocal(_ item: FileItem) -> Bool {
        let kind = item.mountPointType?.lowercased() ?? ""
        return kind.isEmpty || kind == "normal" || kind == "shared_folder"
    }
    static func canSelect(_ item: FileItem, profileID: UUID) -> Bool {
        item.profileID == profileID && validPath(item.path) && !parent(item.path).isEmpty &&
        leaf(item.path) == item.name && !item.name.contains("\"") && !item.name.contains("\r") && !item.name.contains("\n") && item.permissions?.canRead != false && !item.isRecyclePath &&
        isLocal(item) &&
        (item.kind == .directory || item.kind == .file && (item.sizeBytes ?? -1) >= 0)
    }

    static func list(_ path: String, repository: any MobileCrossNASRepository) async throws -> [FileItem] {
        var items: [FileItem] = [], paths = Set<String>(), offset = 0, total: Int?
        while true {
            try Task.checkCancellation()
            let page = try await repository.listFolder(path: path, offset: offset, limit: 200)
            try Task.checkCancellation()
            guard page.folderPath == path, page.offset == offset, page.total >= 0,
                  total == nil || total == page.total,
                  !page.hasMore || !page.items.isEmpty else { throw MobileCrossNASFailure.changed }
            total = page.total
            for item in page.items {
                guard item.profileID == repository.profileID, validPath(item.path), parent(item.path) == path,
                      leaf(item.path) == item.name, paths.insert(item.path).inserted else { throw MobileCrossNASFailure.invalid }
                items.append(item)
            }
            offset += page.items.count
            guard offset <= page.total else { throw MobileCrossNASFailure.changed }
            if !page.hasMore {
                guard offset == page.total else { throw MobileCrossNASFailure.changed }
                return items
            }
        }
    }

    static func info(_ path: String, repository: any MobileCrossNASRepository) async throws -> FileItem {
        try Task.checkCancellation()
        let values = try await repository.getInfo(paths: [path])
        try Task.checkCancellation()
        guard values.count == 1, let item = values.first, item.profileID == repository.profileID,
              item.path == path, item.name == leaf(path) else { throw MobileCrossNASFailure.changed }
        return item
    }

    static func checkSource(_ entry: MobileCrossNASEntry, repository: any MobileCrossNASRepository,
                            forDeletion: Bool = false, allowDirectoryChange: Bool = false) async throws {
        let current = try await info(entry.source.path, repository: repository)
        guard canSelect(current, profileID: repository.profileID), current.kind == entry.source.kind,
              (current.isDirectory && allowDirectoryChange) || current.times?.modifiedAt == entry.source.times?.modifiedAt,
              current.isDirectory || current.sizeBytes == entry.source.sizeBytes else { throw MobileCrossNASFailure.changed }
        if forDeletion && current.permissions?.canDelete != true { throw MobileCrossNASFailure.permission }
        if !current.isDirectory {
            let digest = try await repository.fileMD5(remotePath: current.path)
            try Task.checkCancellation()
            guard digest.lowercased() == entry.digest else { throw MobileCrossNASFailure.changed }
        }
    }

    static func checkTarget(_ entry: MobileCrossNASEntry, repository: any MobileCrossNASRepository) async throws {
        let current = try await info(entry.destination, repository: repository)
        guard current.kind == entry.source.kind, current.permissions?.canRead != false,
              isLocal(current) else { throw MobileCrossNASFailure.changed }
        if !current.isDirectory {
            guard current.sizeBytes == entry.source.sizeBytes else { throw MobileCrossNASFailure.changed }
            let digest = try await repository.fileMD5(remotePath: current.path)
            try Task.checkCancellation()
            guard digest.lowercased() == entry.digest else { throw MobileCrossNASFailure.changed }
        }
    }

    static func prepare(items: [FileItem], source: MobileCrossNASEndpoint, target: MobileCrossNASEndpoint,
                        destination: String, moveSource: Bool) async throws -> MobileCrossNASRecord {
        guard source.profile.id != target.profile.id, source.profile.id == source.repository.profileID,
              target.profile.id == target.repository.profileID, validPath(destination),
              !items.isEmpty, items.count <= 20, Set(items.map(\.name)).count == items.count,
              Set(items.map { parent($0.path) }).count == 1,
              items.allSatisfy({ canSelect($0, profileID: source.profile.id) }) else { throw MobileCrossNASFailure.invalid }
        let folder = try await info(destination, repository: target.repository)
        guard folder.isDirectory, folder.permissions?.canWrite == true else { throw MobileCrossNASFailure.permission }
        let existing = try await list(destination, repository: target.repository)
        guard !existing.contains(where: { child in items.contains { $0.name == child.name } }) else { throw MobileCrossNASFailure.conflict }
        var pending = items.map { ($0, destination + "/" + $0.name) }
        var entries: [MobileCrossNASEntry] = [], paths = Set<String>(), index = 0
        while index < pending.count {
            try Task.checkCancellation()
            let (item, targetPath) = pending[index]; index += 1
            guard canSelect(item, profileID: source.profile.id), paths.insert(item.path).inserted else { throw MobileCrossNASFailure.invalid }
            let current = try await info(item.path, repository: source.repository)
            guard current.kind == item.kind, current.times?.modifiedAt == item.times?.modifiedAt,
                  canSelect(current, profileID: source.profile.id), current.isDirectory || current.sizeBytes == item.sizeBytes else {
                throw MobileCrossNASFailure.changed
            }
            let digest: String?
            if current.isDirectory {
                digest = nil
                let children = try await list(item.path, repository: source.repository)
                pending.append(contentsOf: children.map { ($0, targetPath + "/" + $0.name) })
            } else {
                digest = try await source.repository.fileMD5(remotePath: item.path).lowercased()
                guard validDigest(digest) else { throw MobileCrossNASFailure.invalid }
            }
            let entry = MobileCrossNASEntry(source: current, destination: targetPath, digest: digest)
            try await checkSource(entry, repository: source.repository)
            entries.append(entry)
        }
        let record = MobileCrossNASRecord(id: UUID(), createdAt: Date(), sourceID: source.profile.id,
            sourceContext: source.context, sourceName: source.profile.displayName, targetID: target.profile.id,
            targetContext: target.context, targetName: target.profile.displayName, destination: destination,
            moveSource: moveSource, entries: entries)
        guard record.isValid else { throw MobileCrossNASFailure.invalid }
        return record
    }

    static func checkTree(_ entries: [MobileCrossNASEntry], repository: any MobileCrossNASRepository,
                          target: Bool) async throws {
        for entry in entries where entry.source.isDirectory {
            let path = target ? entry.destination : entry.source.path
            let expected = Set(entries.filter { parent(target ? $0.destination : $0.source.path) == path }
                .map { target ? $0.destination : $0.source.path })
            let observed = try await list(path, repository: repository)
            guard Set(observed.map(\.path)) == expected else { throw MobileCrossNASFailure.changed }
        }
    }
}
