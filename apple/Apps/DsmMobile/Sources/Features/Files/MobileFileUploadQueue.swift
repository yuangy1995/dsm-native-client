import DsmCore
import DsmFileFeature
import DsmLocalization
import Foundation
import Observation

/// 移动平台持有文件副本和账号身份，共用批次负责目录顺序、冲突及未知结果。
@MainActor @Observable
final class MobileFileUploadQueue {
    struct SourceRecord: Codable {
        let id: UUID
        let relativePath: String
        let kind: FileUploadSource.Kind
        let size: Int64
        let modifiedAt: Date?
    }
    struct Record: Codable {
        let id: UUID
        let context: String
        let destination: String
        let overwrite: Bool
        let sources: [SourceRecord]
        var entries: [FileUploadEntryCheckpoint]
    }
    private struct Envelope: Codable { let version: Int; let records: [Record] }
    private let backgroundExecution: MobileTransferBackgroundExecution?
    private var backgroundRun: (batchID: UUID, generation: UUID, token: UUID)?
    private let rootURL: URL
    private var records: [Record] = []
    private var live: [UUID: FileUploadBatch] = [:]
    private var context: String?
    private var repository: (any FileRepository)?
    private var configurationTask: Task<Void, Never>?
    private var configurationID = UUID()
    private var selectionID = UUID()
    private var loadFailed = false
    private var lastProgressSave = Date.distantPast
    private(set) var isConfiguring = false
    private(set) var isPresented = false
    private(set) var isPreparing = false
    private(set) var sources: [FileUploadSource] = []
    private(set) var destination = ""
    private(set) var error: String?
    private(set) var recoveryError: String?

    init(rootURL: URL? = nil, backgroundExecution: MobileTransferBackgroundExecution? = nil) {
        self.backgroundExecution = backgroundExecution
        self.rootURL = rootURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileUploadQueue-\(UUID().uuidString)", isDirectory: true)
        let url = self.rootURL.appendingPathComponent("queue-v1.json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard envelope.version == 1,
                      Set(envelope.records.map(\.id)).count == envelope.records.count,
                      envelope.records.allSatisfy({ record in
                          !record.context.isEmpty && record.destination.hasPrefix("/")
                            && record.sources.allSatisfy { Self.validRelativePath($0.relativePath) }
                      }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                records = envelope.records
            }
        } catch {
            loadFailed = true
            recoveryError = L10n.string("mobile.activity.recovery-error")
        }
    }

    var batches: [FileUploadBatch] {
        records.filter { $0.context == context }.compactMap { live[$0.id] }
    }

    func configure(profile: NasProfile?, repository: (any FileRepository)?) {
        configurationTask?.cancel()
        dismissSelection()
        for batch in live.values where batch.isRunning { batch.pause() }
        context = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        self.repository = repository
        let generation = UUID()
        configurationID = generation
        isConfiguring = true
        configurationTask = Task { [weak self] in
            guard let self else { return }
            while live.values.contains(where: \.isRunning) {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled, configurationID == generation else { return }
            }
            guard !Task.isCancelled, configurationID == generation else { return }
            live.removeAll()
            if let repository {
                for record in records where record.context == context {
                    attach(record, repository: repository, restoring: true)
                }
            }
            isConfiguring = false
        }
    }

    func prepare(_ urls: [URL], destination: String) async {
        guard context != nil, repository != nil, !isConfiguring,
              destination.hasPrefix("/"), destination != "/",
              !destination.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return }
        dismissSelection()
        self.destination = destination
        isPresented = true; isPreparing = true
        let generation = selectionID
        let collection = Task.detached { try FileUploadPlan.collect(urls) }
        do {
            let selected = try await withTaskCancellationHandler { try await collection.value }
                onCancel: { collection.cancel() }
            guard generation == selectionID else { return }
            sources = selected
        } catch {
            guard generation == selectionID else { return }
            self.error = L10n.string("files.upload.sourceUnavailable")
        }
        if generation == selectionID { isPreparing = false }
    }

    func dismissSelection() {
        selectionID = UUID()
        isPresented = false; isPreparing = false; sources = []; error = nil
    }

    func submit(overwrite: Bool) async {
        guard !isPreparing, !sources.isEmpty, let context, let repository, !isConfiguring else { return }
        let generation = selectionID
        let id = UUID()
        let directory = sourceDirectory(id)
        let originalSources = sources
        let target = destination
        isPreparing = true; error = nil
        do {
            try MobileTransferRecoveryStore.prepareDirectory(directory)
            var copies: [SourceRecord] = []
            for source in originalSources {
                try Task.checkCancellation()
                guard generation == selectionID else { throw CancellationError() }
                guard Self.validRelativePath(source.relativePath) else { throw CocoaError(.fileReadInvalidFileName) }
                let local = directory.appendingPathComponent(source.relativePath)
                var kind = source.kind
                do {
                    if kind == .directory {
                        try MobileTransferRecoveryStore.prepareDirectory(local)
                    } else if kind == .file, !FileManager.default.fileExists(atPath: local.path) {
                        try await MobileSecurityScopedDocumentCopier().copySecurityScopedFile(from: source.url,
                            to: local, in: local.deletingLastPathComponent())
                    }
                } catch {
                    // 一项不可读不丢弃其他文件；批次仍显示该项失败且不发送它。
                    if (error as NSError).code == CocoaError.fileWriteOutOfSpace.rawValue { throw error }
                    kind = .unreadable
                }
                let values = try? local.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                copies.append(SourceRecord(id: source.id, relativePath: source.relativePath, kind: kind,
                    size: Int64(values?.fileSize ?? 0), modifiedAt: values?.contentModificationDate))
            }
            guard generation == selectionID, self.context == context else { throw CancellationError() }
            let record = Record(id: id, context: context, destination: target, overwrite: overwrite, sources: copies, entries: [])
            records.append(record)
            attach(record, repository: repository, restoring: false)
            if let batch = live[id] { update(batch) }
            try save()
            dismissSelection()
            startNext()
        } catch {
            records.removeAll { $0.id == id }; live[id] = nil
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
            guard generation == selectionID else { return }
            isPreparing = false
            self.error = error is CancellationError ? nil : L10n.string("mobile.files.upload-copy-error")
        }
    }

    func resume(_ batch: FileUploadBatch) {
        guard batches.contains(where: { $0 === batch }), !batch.isRunning, !isConfiguring else { return }
        batch.resume(); startNext()
    }

    func retryFailed(_ batch: FileUploadBatch) {
        guard batches.contains(where: { $0 === batch }), !batch.isRunning, !isConfiguring else { return }
        batch.retryFailed(); startNext()
    }

    func refresh(_ batch: FileUploadBatch) async {
        guard batches.contains(where: { $0 === batch }), !isConfiguring else { return }
        await batch.reconcileUnknown()
    }

    func removeFinished(_ batch: FileUploadBatch) {
        guard batches.contains(where: { $0 === batch }), !batch.isRunning,
              batch.entries.allSatisfy({ [.succeeded, .skipped, .cancelled].contains($0.state) }) else { return }
        let previous = records
        records.removeAll { $0.id == batch.id }
        do {
            try save()
            live[batch.id] = nil
            try? FileManager.default.removeItem(at: sourceDirectory(batch.id).deletingLastPathComponent())
        } catch { records = previous }
    }

    private func attach(_ record: Record, repository: any FileRepository, restoring: Bool) {
        let directory = sourceDirectory(record.id)
        let access = FileUploadSourceAccess(directory)
        let sources = record.sources.map {
            FileUploadSource(id: $0.id, url: directory.appendingPathComponent($0.relativePath),
                relativePath: $0.relativePath, kind: $0.kind, size: $0.size, modifiedAt: $0.modifiedAt, access: access)
        }
        let batch = FileUploadBatch(sources: sources, destination: record.destination, overwrite: record.overwrite,
            repository: repository, id: record.id, restoredEntries: restoring ? record.entries : nil)
        live[record.id] = batch
        batch.onChange = { [weak self, weak batch] entry in
            guard let self, let batch else { return }
            let prior = records.first { $0.id == batch.id }?.entries.first { $0.id == entry.id }?.state
            update(batch)
            if let run = backgroundRun, run.batchID == batch.id {
                backgroundExecution?.update(run.token, completed: batch.completedBytes, total: batch.totalBytes)
            }
            if prior != entry.state || Date().timeIntervalSince(lastProgressSave) >= 1 {
                lastProgressSave = Date()
                try? save()
            }
        }
        batch.beforeSubmission = { [weak self, weak batch] in
            guard let self, let batch, record.context == self.context, !isConfiguring else { throw CancellationError() }
            // 旧批次的同一目标还没有结果时，新批次不能代替它重复提交。
            let targets = Set(record.sources.map { record.destination + "/" + $0.relativePath })
            let unresolved = records.contains { other in
                other.id != record.id && other.context == record.context && other.sources.contains { source in
                    targets.contains(other.destination + "/" + source.relativePath)
                        && other.entries.contains { $0.id == source.id && ($0.state == .unverified || $0.needsReconciliation) }
                }
            }
            guard !unresolved else {
                throw AppError(category: .conflict, isRetryable: false, safeUserMessage: L10n.string("mobile.files.upload-earlier-pending"))
            }
            update(batch)
            try save()
        }
        batch.onSettled = { [weak self, weak batch] in
            guard let self, let batch else { return }
            update(batch); try? save()
            if let run = backgroundRun, run.batchID == batch.id {
                backgroundRun = nil
                backgroundExecution?.finish(run.token, success: batch.entries.allSatisfy { [.succeeded, .skipped].contains($0.state) })
            }
            startNext()
        }
    }

    private func update(_ batch: FileUploadBatch) {
        guard let index = records.firstIndex(where: { $0.id == batch.id }) else { return }
        records[index].entries = batch.checkpoint
    }

    private func startNext() {
        guard !isConfiguring, !loadFailed, !live.values.contains(where: \.isRunning) else { return }
        guard let batch = batches.first(where: { !$0.isPaused && $0.hasPending }) else { return }
        if let backgroundExecution {
            let generation = UUID()
            let token = backgroundExecution.begin(taskID: batch.id, direction: .upload) { [weak self] in
                guard let self, backgroundRun?.generation == generation else { return }
                backgroundRun = nil
                // 时间耗尽时也暂停尚未开始的批次，防止结算回调继续提交后项。
                for pending in batches where pending.isRunning || pending.hasPending {
                    pending.pause()
                    update(pending)
                }
                try? save()
            }
            backgroundRun = (batch.id, generation, token)
            backgroundExecution.update(token, completed: batch.completedBytes, total: batch.totalBytes)
        }
        batch.start()
    }

    private func save() throws {
        do {
            guard !loadFailed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            try MobileTransferRecoveryStore.prepareDirectory(rootURL)
            let data = try JSONEncoder().encode(Envelope(version: 1, records: records))
            try data.write(to: rootURL.appendingPathComponent("queue-v1.json"), options: [.atomic, .completeFileProtection])
            recoveryError = nil
        } catch {
            recoveryError = L10n.string("mobile.activity.recovery-error")
            throw error
        }
    }

    private func sourceDirectory(_ id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent("Sources", isDirectory: true)
    }

    static func validRelativePath(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains("\0")
            && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
