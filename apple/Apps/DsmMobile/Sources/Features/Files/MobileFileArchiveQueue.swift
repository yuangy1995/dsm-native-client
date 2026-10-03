import DsmCore
import DsmLocalization
import Foundation
import Observation

/// 归档由 NAS 执行；只记录输出快照和阶段，密码与请求不落盘，恢复时不重放写入。
@MainActor @Observable
final class MobileFileArchiveQueue {
    enum Phase: String, Codable { case preparing, running, interrupted, completed, failed }
    struct Output: Codable, Equatable {
        let path: String
        let directory: Bool
        let size: Int64?
    }
    struct Record: Codable, Identifiable {
        let id: UUID
        let context: String
        let name: String
        let destination: String
        let extraction: Bool
        let outputs: [Output]
        var phase: Phase
        var acknowledged = false
        var fraction: Double?
        var isActive: Bool { [.preparing, .running, .interrupted].contains(phase) }
    }
    private struct Envelope: Codable { let version: Int; let records: [Record] }
    private let rootURL: URL
    private var stored: [Record] = []
    private var operations: [UUID: Task<Void, Never>] = [:]
    private var context: String?
    private var repository: (any FileRepository & AnyObject)?
    private var activation = UUID()
    private var loadFailed = false
    @ObservationIgnored var onDestinationChanged: ((String, String) async -> Void)?
    private(set) var error: String?
    private(set) var recoveryError: String?
    private(set) var refreshing: Set<UUID> = []

    init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobileArchives-\(UUID())")
        let file = self.rootURL.appendingPathComponent("archives-v1.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
                guard envelope.version == 1, Set(envelope.records.map(\.id)).count == envelope.records.count,
                      envelope.records.allSatisfy({ !$0.context.isEmpty && Self.validFolder($0.destination)
                          && !$0.outputs.isEmpty && $0.outputs.allSatisfy { Self.validFolder($0.path) } }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                stored = envelope.records.map { record in
                    var record = record
                    if record.phase == .preparing { record.phase = .failed }
                    if record.phase == .running { record.phase = .interrupted }
                    return record
                }
            }
        } catch { loadFailed = true; recoveryError = L10n.string("mobile.activity.recovery-error") }
    }

    var records: [Record] { stored.filter { $0.context == context } }
    func configure(profile: NasProfile?, repository: (any FileRepository & AnyObject)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || repository.map(ObjectIdentifier.init) != self.repository.map(ObjectIdentifier.init) else { return }
        operations.values.forEach { $0.cancel() }
        activation = UUID(); context = next; self.repository = repository; error = nil
    }

    static func validFolder(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && FileArchiveSelection.safeRelativePath(String(path.dropFirst()))
    }
    static func filename(_ name: String, format: ArchiveFormat) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileArchiveSelection.safeRelativePath(name), !name.contains("/"), !name.isEmpty else { return nil }
        return (name as NSString).pathExtension.lowercased() == format.rawValue ? name : name + "." + format.rawValue
    }

    @discardableResult
    func compress(items: [FileItem], destination: String, name: String, format: ArchiveFormat,
                  level: ArchiveCompressionLevel, password: String?) -> Bool {
        guard let filename = Self.filename(name, format: format), !items.isEmpty, let repository,
              items.allSatisfy({ $0.profileID == repository.profileID }) else { return false }
        let output = destination + "/" + filename
        guard !items.contains(where: { $0.path == output || $0.isDirectory && output.hasPrefix($0.path + "/") }) else {
            error = L10n.string("mobile.archive.inside-source"); return false
        }
        return start(name: filename, destination: destination, extraction: false,
                     outputs: [.init(path: output, directory: false, size: nil)]) { [repository] in
            for item in items {
                guard let current = try await repository.getInfo(paths: [item.path]).first(where: { $0.path == item.path }),
                      current.kind == item.kind, current.sizeBytes == item.sizeBytes,
                      current.times?.modifiedAt == item.times?.modifiedAt else { throw Self.sourceChanged() }
            }
            let existing = try await Self.allItems(destination, repository: repository)
            guard !existing.contains(where: { $0.name == filename }) else {
                throw AppError(category: .conflict, isRetryable: false, safeUserMessage: L10n.string("mobile.archive.exists"))
            }
            try await repository.checkWritePermission(folderPath: destination, filename: filename, createOnly: true)
        } submission: { [repository] progress in
            try await repository.compress(paths: items.map(\.path), destinationFilePath: output,
                format: format, level: level, password: password, progress: progress)
        }
    }

    @discardableResult
    func extract(item: FileItem, request: FileExtractionRequest, inventory: [ArchiveItem]) -> Bool {
        guard let repository, item.profileID == repository.profileID, request.filePath == item.path,
              request.selection.isValid, !inventory.isEmpty,
              inventory.allSatisfy({ FileArchiveSelection.safeRelativePath($0.path)
                  && (request.keepDirectories || FileArchiveSelection.safeRelativePath($0.name) && !$0.name.contains("/")) }) else { return false }
        let folderName = (item.name as NSString).deletingPathExtension
        guard FileArchiveSelection.safeRelativePath(folderName), !folderName.contains("/") else { return false }
        let root = request.destination + (request.createSubfolder ? "/" + folderName : "")
        let outputs = inventory.filter { request.keepDirectories || !$0.isDirectory }.map { entry in
            Output(path: root + "/" + (request.keepDirectories ? entry.path : entry.name), directory: entry.isDirectory, size: entry.sizeBytes)
        }
        guard Set(outputs.map(\.path)).count == outputs.count, !outputs.isEmpty, outputs.allSatisfy({ Self.validFolder($0.path) }),
              !outputs.contains(where: { $0.path == item.path }) else {
            error = L10n.string("files.archive.invalidSelection"); return false
        }
        return start(name: item.name, destination: request.destination, extraction: true, outputs: outputs) { [repository] in
            guard let current = try await repository.getInfo(paths: [item.path]).first(where: { $0.path == item.path }),
                  current.kind == item.kind, current.sizeBytes == item.sizeBytes,
                  current.times?.modifiedAt == item.times?.modifiedAt else { throw Self.sourceChanged() }
            if !request.overwrite {
                let existing = try await repository.getInfo(paths: outputs.map(\.path))
                guard existing.allSatisfy({ item in item.isDirectory && outputs.contains { $0.path == item.path && $0.directory } }) else {
                    throw AppError(category: .conflict, isRetryable: false, safeUserMessage: L10n.string("mobile.archive.exists"))
                }
            }
            try await repository.checkWritePermission(folderPath: request.destination,
                filename: request.createSubfolder ? folderName : item.name, createOnly: !request.overwrite)
        } submission: { [repository] progress in
            try await repository.extract(request, progress: progress)
        }
    }

    private func start(name: String, destination: String, extraction: Bool, outputs: [Output],
                       preflight: @escaping @MainActor () async throws -> Void,
                       submission: @escaping @MainActor (@escaping FileTransferProgress) async throws -> Void) -> Bool {
        guard let context, let repository, !loadFailed, Self.validFolder(destination) else { return false }
        let overlaps = records.contains { record in
            [.preparing, .running, .interrupted].contains(record.phase) && record.outputs.contains { prior in
                outputs.contains { $0.path == prior.path || $0.path.hasPrefix(prior.path + "/") || prior.path.hasPrefix($0.path + "/") }
            }
        }
        guard !overlaps else { error = L10n.string("mobile.archive.pending-target"); return false }
        let id = UUID(), expected = activation
        stored.append(Record(id: id, context: context, name: name, destination: destination,
            extraction: extraction, outputs: outputs, phase: .preparing))
        do { try save() } catch { stored.removeAll { $0.id == id }; return false }
        error = nil
        operations[id] = Task { [weak self] in
            guard let self else { return }
            defer { operations[id] = nil }
            var submitted = false
            do {
                try await preflight()
                try Task.checkCancellation()
                guard expected == activation else { throw CancellationError() }
                update(id) { $0.phase = .running }
                try save()
                submitted = true
                try await submission { [weak self] completed, total in
                    Task { @MainActor in
                        self?.update(id) { record in
                            guard record.phase == .running else { return }
                            record.fraction = total.flatMap { $0 > 0 ? min(1, max(0, Double(completed) / Double($0))) : nil }
                        }
                    }
                }
                update(id) { $0.acknowledged = true }
                try save()
                try await Self.verify(outputs, repository: repository)
                update(id) { $0.phase = .completed; $0.fraction = 1 }
                try save()
            } catch {
                update(id) { $0.phase = submitted ? .interrupted : .failed }
                try? save()
                if expected == activation, !submitted, !(error is CancellationError) {
                    self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("mobile.archive.failed")
                }
            }
            if submitted, expected == activation { await onDestinationChanged?(context, destination) }
        }
        return true
    }

    func cancel(_ id: UUID) { guard records.contains(where: { $0.id == id }) else { return }; operations[id]?.cancel() }
    func isRunning(_ id: UUID) -> Bool { operations[id] != nil }
    func refresh(_ id: UUID) async {
        guard let record = records.first(where: { $0.id == id }), record.phase == .interrupted,
              record.acknowledged, let repository, refreshing.insert(id).inserted else { return }
        let expected = activation
        defer { refreshing.remove(id) }
        do {
            try await Self.verify(record.outputs, repository: repository)
            guard expected == activation else { return }
            update(id) { $0.phase = .completed; $0.fraction = 1 }; try save()
        } catch { if expected == activation { self.error = L10n.string("mobile.archive.interrupted") } }
    }
    func removeFinished(_ id: UUID) {
        guard records.contains(where: { $0.id == id && [.completed, .failed].contains($0.phase) }), operations[id] == nil else { return }
        let previous = stored; stored.removeAll { $0.id == id }
        do { try save() } catch { stored = previous }
    }
    private func update(_ id: UUID, _ change: (inout Record) -> Void) {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }; change(&stored[index])
    }
    private func save() throws {
        guard !loadFailed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        do {
            try MobileTransferRecoveryStore.prepareDirectory(rootURL)
            try JSONEncoder().encode(Envelope(version: 1, records: stored))
                .write(to: rootURL.appendingPathComponent("archives-v1.json"), options: [.atomic, .completeFileProtection])
        } catch { recoveryError = L10n.string("mobile.activity.recovery-error"); throw error }
    }
    private static func sourceChanged() -> AppError {
        AppError(category: .conflict, isRetryable: false, safeUserMessage: L10n.string("files.archive.changed"))
    }
    private static func verify(_ outputs: [Output], repository: any FileRepository) async throws {
        for output in outputs {
            try Task.checkCancellation()
            guard let item = try await repository.getInfo(paths: [output.path]).first(where: { $0.path == output.path }),
                  item.isDirectory == output.directory,
                  output.directory || output.size == nil || item.sizeBytes == output.size else {
                throw AppError(category: .partialFailure, isRetryable: false, safeUserMessage: L10n.string("files.archive.outputUnverified"))
            }
        }
    }
    private static func allItems(_ path: String, repository: any FileRepository) async throws -> [FileItem] {
        var offset = 0, items: [FileItem] = []
        while true {
            try Task.checkCancellation()
            let page = try await repository.listFolder(path: path, offset: offset, limit: 500)
            items += page.items
            if !page.hasMore { return items }
            guard page.offset == offset, !page.items.isEmpty else { throw sourceChanged() }
            offset += page.items.count
        }
    }
}
