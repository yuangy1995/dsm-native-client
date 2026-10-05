import DsmCore
import Foundation
import Observation

/// 只保存创建摘要和回执；链接、文件内容与凭据不进入恢复记录。
@MainActor
@Observable
final class MobileDownloadCreateStore {
    enum Source: String, Codable { case link, file }
    enum Phase: String, Codable { case submitted, accepted, failed, cancelled }
    enum Failure: String, Codable { case denied, unavailable }
    enum StoreError: Error, Equatable { case invalid, duplicate }
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let context: String
        let createdAt: Date
        let source: Source
        let identity: DownloadTaskCreationIdentity
        var phase: Phase = .submitted
        var failure: Failure?
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    private static var activeInputs: Set<URL> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("DownloadCreations-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("creations-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard value.version == 1 else { throw StoreError.invalid }
                try validate(value.entries); entries = value.entries
            }
        } catch { failed = true }
        do {
            // 文件不会自动重发；进程结束后遗留的专用输入副本可以删除。
            let folder = self.root.appendingPathComponent("creation-inputs", isDirectory: true)
            if FileManager.default.fileExists(atPath: folder.path) {
                for input in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    where !Self.activeInputs.contains(input) { try FileManager.default.removeItem(at: input) }
            }
        } catch { failed = true }
    }
    func entry(_ id: UUID, context: String) -> Entry? { entries.first { $0.id == id && $0.context == context } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func end(_ id: UUID) { executing.remove(id) }
    func reserve(_ entry: Entry) throws {
        guard !failed, entry.phase == .submitted, entry.failure == nil else { throw StoreError.invalid }
        guard !entries.contains(where: { $0.context == entry.context && $0.identity.sourceDigest == entry.identity.sourceDigest && $0.phase == .submitted }) else {
            throw StoreError.duplicate
        }
        try persist(entries + [entry]); executing.insert(entry.id)
    }
    func progress(_ id: UUID, context: String, phase: Phase, failure: Failure? = nil) throws {
        guard !failed, executing.contains(id), let index = entries.firstIndex(where: { $0.id == id && $0.context == context }),
              entries[index].phase == .submitted, phase != .submitted, (phase == .failed) == (failure != nil) else { throw StoreError.invalid }
        var updated = entries; updated[index].phase = phase; updated[index].failure = failure; try persist(updated)
    }
    func remove(_ id: UUID, context: String) throws {
        guard let entry = entry(id, context: context), entry.phase != .submitted, !isExecuting(id) else { throw StoreError.invalid }
        try persist(entries.filter { $0.id != id })
    }
    func copyInput(_ source: URL, id: UUID) async throws -> URL {
        guard !failed, source.isFileURL, ["torrent", "nzb", "txt"].contains(source.pathExtension.lowercased()) else { throw StoreError.invalid }
        let folder = root.appendingPathComponent("creation-inputs", isDirectory: true)
        try MobileTransferRecoveryStore.prepareDirectory(folder)
        let target = folder.appendingPathComponent(id.uuidString).appendingPathExtension(source.pathExtension.lowercased())
        Self.activeInputs.insert(target)
        do {
            try await Task.detached(priority: .userInitiated) {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let values = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size >= 0, size <= 100 * 1_024 * 1_024 else { throw StoreError.invalid }
                guard FileManager.default.createFile(atPath: target.path, contents: nil,
                    attributes: [.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: target)
                defer { try? input.close(); try? output.close() }
                var copied = 0
                while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                    copied += bytes.count
                    guard copied <= 100 * 1_024 * 1_024 else { throw StoreError.invalid }
                    try output.write(contentsOf: bytes)
                }
                guard copied == size else { throw StoreError.invalid }
            }.value
            return target
        } catch { removeInput(target); throw error }
    }
    func removeInput(_ url: URL) {
        guard Self.activeInputs.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url)
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw StoreError.invalid }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(
                to: root.appendingPathComponent("creations-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        var ids: Set<UUID> = [], pending: Set<String> = []
        for entry in values {
            guard ids.insert(entry.id).inserted, entry.identity.isValid,
                  DownloadTaskCreationIdentity(sourceDigest: entry.context, requestDigest: entry.context).isValid,
                  entry.createdAt.timeIntervalSince1970.isFinite, (entry.phase == .failed) == (entry.failure != nil) else { throw StoreError.invalid }
            if entry.phase == .submitted {
                guard pending.insert(entry.context + entry.identity.sourceDigest).inserted else { throw StoreError.invalid }
            }
        }
    }
}
