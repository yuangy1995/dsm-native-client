import DsmCore
import DsmFileFeature
import DsmNetwork
import Foundation
import Observation

protocol MobileOfficeServing: AnyObject, Sendable {
    func getInfo(paths: [String]) async throws -> [FileItem]
    func fileMD5(remotePath: String) async throws -> String
    func checkWritePermission(folderPath: String, filename: String, createOnly: Bool) async throws
    func download(remotePath: String, to localURL: URL, expectedSize: Int64?, progress: @escaping FileTransferProgress) async throws
    func upload(localURL: URL, to folderPath: String, overwrite: Bool, progress: @escaping FileTransferProgress) async throws
}

extension DsmFileRepository: MobileOfficeServing {}

/// 编辑器只接收本机副本；原位置覆盖必须由用户主动操作，并保留可恢复的原始基线。
@MainActor @Observable
final class MobileOfficeModel {
    @ObservationIgnored let store: MobileOfficeStore
    @ObservationIgnored private var repository: (any MobileOfficeServing)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let backgroundExecution: (any MobileTransferBackgroundManaging)?
    @ObservationIgnored private var execution: (id: UUID, cancel: @Sendable () -> Void, settle: @Sendable () async -> Void, token: UUID?)?
    private var allRecords: [MobileOfficeRecord] = []
    private(set) var context: String?
    private(set) var profileID: UUID?
    private(set) var isBusy = false
    private(set) var busyID: UUID?
    private(set) var progress: Double?
    private(set) var failure: MobileOfficeFailure?
    private(set) var recoveryFailed = false
    var onChanged: (@MainActor (String) async -> Void)?

    init(rootURL: URL? = nil, backgroundExecution: (any MobileTransferBackgroundManaging)? = nil) {
        self.backgroundExecution = backgroundExecution
        store = MobileOfficeStore(root: rootURL ?? MobileTransferRecoveryStore.application.rootURL
            .appendingPathComponent("Office", isDirectory: true))
        do { allRecords = try store.load() }
        catch { recoveryFailed = true }
    }

    var records: [MobileOfficeRecord] { allRecords.filter { $0.context == context && $0.baseline.profileID == profileID } }

    func configure(profile: NasProfile?, repository: (any MobileOfficeServing)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier }
        guard next != context || self.repository.map(ObjectIdentifier.init) != repository.map(ObjectIdentifier.init) else { return }
        execution?.cancel()
        generation &+= 1
        for index in allRecords.indices where allRecords[index].phase == .saving { allRecords[index].phase = .uncertain }
        self.repository = repository; context = next; profileID = profile?.id
        isBusy = false; busyID = nil; progress = nil; failure = nil
    }

    func record(_ id: UUID) -> MobileOfficeRecord? { records.first { $0.id == id } }
    func existing(_ item: FileItem) -> MobileOfficeRecord? { records.first { $0.baseline.path == item.path && $0.baseline.profileID == item.profileID } }
    func clearFailure() { failure = nil }

    func prepare(_ item: FileItem) async -> UUID? {
        if let record = existing(item) {
            if !isBusy { failure = nil }
            return record.id
        }
        return await execute(activity: .download, action: { await self.prepareCopy(item) }, success: { $0 != nil }) ?? nil
    }

    private func prepareCopy(_ item: FileItem) async -> UUID? {
        guard MobileOfficePolicy.supports(item), item.profileID == profileID,
              let operation = begin(), let context else { return nil }
        defer { finish(operation.generation) }
        let id = UUID(), originalID = UUID()
        let directory = store.directory(id).appendingPathComponent(originalID.uuidString, isDirectory: true)
        let local = directory.appendingPathComponent(item.name)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: store.directory(id)) } }
        do {
            let before = try await current(item, repository: operation.repository)
            try check(operation.generation)
            guard let size = before.sizeBytes, size >= 0 else { throw MobileOfficeFailure.changed }
            try MobileTransferRecoveryStore.prepareDirectory(directory)
            try await operation.repository.download(remotePath: item.path, to: local, expectedSize: size,
                progress: progressHandler(operation.generation))
            try check(operation.generation)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: local.path)
            let fingerprint = try await Self.fingerprint(local)
            try check(operation.generation)
            let after = try await current(item, repository: operation.repository)
            try check(operation.generation)
            guard MobileOfficePolicy.sameVersion(before, after), fingerprint.size == after.sizeBytes,
                  try await matches(after, fingerprint: fingerprint, repository: operation.repository) else { throw MobileOfficeFailure.changed }
            try check(operation.generation)
            let record = MobileOfficeRecord(id: id, context: context, createdAt: Date(), baseline: after,
                baselineFingerprint: fingerprint, originalID: originalID)
            try store.save(allRecords + [record])
            allRecords.append(record); retained = true
            return id
        } catch { report(error, generation: operation.generation); return nil }
    }

    func importEdited(_ source: URL, id: UUID, expectedContext: String) async {
        guard expectedContext == context, let record = record(id), ![.saving, .uncertain].contains(record.phase),
              let operation = begin(id) else { return }
        defer { finish(operation.generation) }
        let candidateID = UUID(), directory = store.directory(id).appendingPathComponent(UUID().uuidString, isDirectory: true)
        // 先在独立目录冻结，再原子接入会话，保存失败不会损坏上一个副本。
        var retained = false
        let destination = store.artifact(record, id: candidateID)
        defer {
            try? FileManager.default.removeItem(at: directory)
            if !retained { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        }
        do {
            guard source.isFileURL,
                  source.pathExtension.lowercased() == (record.baseline.name as NSString).pathExtension.lowercased()
            else { throw MobileOfficeFailure.format }
            try MobileTransferRecoveryStore.prepareDirectory(directory)
            let hasScope = source.startAccessingSecurityScopedResource()
            defer { if hasScope { source.stopAccessingSecurityScopedResource() } }
            let snapshot = try await Task.detached {
                try OfficeUploadSnapshot.create(from: source, remoteName: record.baseline.name, root: directory)
            }.value
            try check(operation.generation)
            try MobileTransferRecoveryStore.prepareDirectory(destination.deletingLastPathComponent())
            try FileManager.default.moveItem(at: snapshot.url, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
            var updated = record
            updated.candidateID = candidateID; updated.candidateFingerprint = snapshot.fingerprint
            updated.phase = snapshot.fingerprint.sha256 == record.baselineFingerprint.sha256 ? .unchanged : .changed
            try replace(updated); retained = true
            if let old = record.candidateID { try? FileManager.default.removeItem(at: store.artifact(record, id: old).deletingLastPathComponent()) }
        } catch { report(error, generation: operation.generation) }
    }

    func save(_ id: UUID) async {
        guard record(id)?.phase == .changed else { return }
        _ = await execute(activity: .upload, action: {
            await self.saveCopy(id)
            return self.record(id)?.phase == .saved
        }, success: { $0 })
    }

    private func saveCopy(_ id: UUID) async {
        guard var record = record(id), record.phase == .changed,
              let candidate = record.candidateID, let fingerprint = record.candidateFingerprint,
              let operation = begin(id) else { return }
        defer { finish(operation.generation) }
        let attemptID = UUID()
        let attemptURL = store.artifact(record, id: attemptID)
        let scratch = store.directory(id).appendingPathComponent(UUID().uuidString, isDirectory: true)
        var retained = false
        defer {
            try? FileManager.default.removeItem(at: scratch)
            if !retained { try? FileManager.default.removeItem(at: attemptURL.deletingLastPathComponent()) }
        }
        do {
            let source = store.artifact(record, id: candidate)
            try MobileTransferRecoveryStore.prepareDirectory(scratch)
            let name = record.baseline.name
            let snapshot = try await Task.detached {
                try OfficeUploadSnapshot.create(from: source, remoteName: name, root: scratch)
            }.value
            guard snapshot.fingerprint == fingerprint else { throw MobileOfficeFailure.local }
            try check(operation.generation)
            try MobileTransferRecoveryStore.prepareDirectory(attemptURL.deletingLastPathComponent())
            try FileManager.default.moveItem(at: snapshot.url, to: attemptURL)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: attemptURL.path)
            let current = try await current(record.baseline, repository: operation.repository)
            try check(operation.generation)
            guard MobileOfficePolicy.sameVersion(record.baseline, current),
                  try await matches(current, fingerprint: record.baselineFingerprint, repository: operation.repository)
            else { throw MobileOfficeFailure.changed }
            try check(operation.generation)
            guard current.permissions?.canWrite != false else { throw MobileOfficeFailure.permission }
            let parent = (current.path as NSString).deletingLastPathComponent
            try await operation.repository.checkWritePermission(folderPath: parent,
                filename: "LanStash-Write-Check-\(UUID().uuidString).tmp", createOnly: true)
            try check(operation.generation)
            guard MobileOfficePolicy.sameVersion(current, try await self.current(record.baseline, repository: operation.repository)),
                  try await matches(current, fingerprint: record.baselineFingerprint, repository: operation.repository)
            else { throw MobileOfficeFailure.changed }
            try check(operation.generation)
            record.candidateID = attemptID
            record.phase = .saving
            try replace(record) // 必须先落盘；失败则零写请求。
            retained = true
            do {
                try await operation.repository.upload(localURL: attemptURL, to: parent, overwrite: true,
                    progress: progressHandler(operation.generation))
            } catch {
                // 已开始覆盖后，取消、超时和丢回执均只读恢复，不自动再上传。
            }
            try check(operation.generation)
            record.phase = .uncertain
            try replace(record)
            try await verify(record, operation: operation)
        } catch {
            if isCurrent(operation.generation), let latest = self.record(id), latest.phase == .saving {
                var uncertain = latest; uncertain.phase = .uncertain
                do { try replace(uncertain) } catch { recoveryFailed = true }
            } else if isCurrent(operation.generation), (error as? MobileOfficeFailure) == .changed {
                record.phase = .conflict
                do { try replace(record) } catch { recoveryFailed = true }
            }
            report(error, generation: operation.generation)
        }
    }

    func refresh(_ id: UUID) async {
        guard let record = record(id), record.phase == .uncertain, let operation = begin(id) else { return }
        defer { finish(operation.generation) }
        do { try await verify(record, operation: operation) }
        catch { report(error, generation: operation.generation) }
    }

    /// 不删除 NAS 原件；结果未知时保留记录及副本，不能通过关闭会话解除原写限制。
    func discard(_ id: UUID) {
        guard !isBusy, !recoveryFailed, let record = record(id), ![.saving, .uncertain].contains(record.phase) else { return }
        do {
            let remaining = allRecords.filter { $0.id != id }
            try store.save(remaining); allRecords = remaining
            try? FileManager.default.removeItem(at: store.directory(id))
        } catch { failure = .recovery }
    }

    func copyURL(_ id: UUID) -> URL? {
        guard let record = record(id) else { return nil }
        let url = store.artifact(record, id: record.candidateID ?? record.originalID)
        guard (try? OfficeLocalFileStamp.read(url)) != nil else { failure = .local; return nil }
        return url
    }

    private struct Operation {
        let generation: Int
        let repository: any MobileOfficeServing
    }

    /// 持有实际网络任务，系统到期先取消并等待原流程收尾，不能只丢弃迟到的界面结果。
    private func execute<Value: Sendable>(activity: MobileTransferBackgroundActivity,
        action: @escaping @MainActor () async -> Value,
        success: @escaping @MainActor (Value) -> Bool) async -> Value? {
        guard execution == nil, !isBusy, !recoveryFailed, context != nil, repository != nil else { return nil }
        let id = UUID(), expectedGeneration = generation
        let task = Task<Value?, Never> {
            guard self.generation == expectedGeneration, !Task.isCancelled else { return nil }
            return await action()
        }
        execution = (id, { task.cancel() }, { _ = await task.value }, nil)
        let token = backgroundExecution?.begin(taskID: id, activity: activity) { [weak self] in
            guard let current = self?.execution, current.id == id else { return }
            current.cancel()
            await current.settle()
        }
        execution?.token = token
        let value = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if execution?.id == id { execution = nil }
        if let token { backgroundExecution?.finish(token, success: !task.isCancelled && value.map(success) == true) }
        return value
    }

    private func begin(_ id: UUID? = nil) -> Operation? {
        guard !isBusy, !recoveryFailed, context != nil, let repository else { return nil }
        generation &+= 1
        isBusy = true; busyID = id; failure = nil; progress = nil
        return Operation(generation: generation, repository: repository)
    }

    private func finish(_ generation: Int) {
        guard isCurrent(generation) else { return }
        isBusy = false; busyID = nil; progress = nil
    }

    private func isCurrent(_ token: Int) -> Bool { token == generation }
    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard isCurrent(token) else { throw CancellationError() }
    }

    private func replace(_ record: MobileOfficeRecord) throws {
        guard let index = allRecords.firstIndex(where: { $0.id == record.id }) else { throw MobileOfficeFailure.recovery }
        var next = allRecords; next[index] = record
        try store.save(next); allRecords = next
    }

    private func current(_ original: FileItem, repository: any MobileOfficeServing) async throws -> FileItem {
        let items = try await repository.getInfo(paths: [original.path])
        guard items.count == 1, let item = items.first, item.profileID == original.profileID,
              item.path == original.path, MobileOfficePolicy.supports(item) else { throw MobileOfficeFailure.changed }
        return item
    }

    private func matches(_ item: FileItem, fingerprint: OfficeFileFingerprint, repository: any MobileOfficeServing) async throws -> Bool {
        guard item.sizeBytes == fingerprint.size else { return false }
        let digest = try await repository.fileMD5(remotePath: item.path)
        let after = try await current(item, repository: repository)
        return digest.lowercased() == fingerprint.md5 && MobileOfficePolicy.sameVersion(item, after)
    }

    private func verify(_ record: MobileOfficeRecord, operation: Operation) async throws {
        guard let fingerprint = record.candidateFingerprint else { throw MobileOfficeFailure.recovery }
        let remote = try await current(record.baseline, repository: operation.repository)
        try check(operation.generation)
        guard try await matches(remote, fingerprint: fingerprint, repository: operation.repository)
        else { throw MobileOfficeFailure.interrupted }
        try check(operation.generation)
        var updated = record
        updated.baseline = remote; updated.baselineFingerprint = fingerprint; updated.phase = .saved
        try replace(updated)
        await onChanged?(record.context)
    }

    private func progressHandler(_ token: Int) -> FileTransferProgress {
        { [weak self] completed, total in
            Task { @MainActor in
                guard let self, self.isCurrent(token), self.isBusy else { return }
                self.progress = total.flatMap { $0 > 0 ? min(1, Double(completed) / Double($0)) : nil }
                if let backgroundToken = self.execution?.token {
                    self.backgroundExecution?.update(backgroundToken, completed: completed, total: total)
                }
            }
        }
    }

    private nonisolated static func fingerprint(_ url: URL) async throws -> OfficeFileFingerprint {
        try await Task.detached { try OfficeFileFingerprint.read(url) }.value
    }

    private func report(_ error: any Error, generation token: Int) {
        guard isCurrent(token) else { return }
        if let known = error as? MobileOfficeFailure { failure = known }
        else if let app = error as? AppError, app.category == .permissionDenied { failure = .permission }
        else if error is OfficeEditingError || (error as NSError).domain == NSCocoaErrorDomain { failure = .local }
        else { failure = .connection }
    }
}
