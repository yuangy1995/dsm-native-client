import AppKit
import CryptoKit
import DsmCore
import DsmLocalization
import Foundation
import Observation

struct OfficeFileFingerprint: Equatable, Sendable {
    let size: Int64
    let md5: String
    let sha256: String

    static func read(_ url: URL) throws -> Self {
        _ = try OfficeLocalFileStamp.read(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5(), sha256 = SHA256()
        var size: Int64 = 0
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            size += Int64(bytes.count); md5.update(data: bytes); sha256.update(data: bytes)
        }
        return .init(size: size, md5: md5.finalize().map { String(format: "%02x", $0) }.joined(),
                     sha256: sha256.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

struct OfficeLocalFileStamp: Equatable, Sendable {
    let size: Int
    let modifiedAt: Date?
    let identifier: String

    static func read(_ url: URL) throws -> Self {
        // URL 会缓存资源属性；编辑器原子替换后必须重新读取文件标识和时间。
        var refreshed = url
        refreshed.removeAllCachedResourceValues()
        let value = try refreshed.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                     .contentModificationDateKey, .fileResourceIdentifierKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true, let size = value.fileSize else {
            throw OfficeEditingError.localFileUnavailable
        }
        return .init(size: size, modifiedAt: value.contentModificationDate,
                     identifier: String(describing: value.fileResourceIdentifier))
    }
}

enum OfficeEditingError: Error { case localFileUnavailable, changedDuringRead, remoteChanged, invalidTarget, noApplication }

/// 每次回传使用独立快照，编辑器后续的保存不会改变正在上传的文件。
struct OfficeUploadSnapshot: Sendable {
    let directory: URL
    let url: URL
    let fingerprint: OfficeFileFingerprint
    let sourceStamp: OfficeLocalFileStamp

    static func create(from source: URL, remoteName: String) throws -> Self {
        guard !remoteName.isEmpty, remoteName != ".", remoteName != "..",
              (remoteName as NSString).lastPathComponent == remoteName else { throw OfficeEditingError.invalidTarget }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("LanStashOfficeUpload-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(remoteName)
        do {
            let before = try OfficeLocalFileStamp.read(source)
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { coordinated in
                do { try manager.copyItem(at: coordinated, to: destination) }
                catch { copyError = error }
            }
            if let error = coordinationError ?? copyError as NSError? { throw error }
            let fingerprint = try OfficeFileFingerprint.read(destination)
            guard before == (try OfficeLocalFileStamp.read(source)), fingerprint.size == Int64(before.size) else {
                throw OfficeEditingError.changedDuringRead
            }
            return .init(directory: directory, url: destination, fingerprint: fingerprint, sourceStamp: before)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }
}

@MainActor @Observable
final class OfficeEditingSession: Identifiable {
    enum Phase: Equatable { case preparing, watching, waitingForSave, saving, saved, paused, conflict, needsReview, stopped }
    let id = UUID()
    let item: FileItem
    let localURL: URL
    private(set) var phase: Phase = .preparing
    private(set) var message: String?
    private(set) var isStopped = false
    private(set) var lastSavedAt: Date?
    @ObservationIgnored private let repository: any FileRepository
    @ObservationIgnored private var baseline: FileItem?
    @ObservationIgnored private var baselineFingerprint: OfficeFileFingerprint?
    @ObservationIgnored private var attemptedFingerprint: OfficeFileFingerprint?
    @ObservationIgnored private var observedStamp: OfficeLocalFileStamp?
    @ObservationIgnored private var observedAt: Date?
    @ObservationIgnored private var synchronizedStamp: OfficeLocalFileStamp?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var holdsSecurityScope = false
    @ObservationIgnored private var isChecking = false

    init(item: FileItem, localURL: URL, repository: any FileRepository) {
        self.item = item; self.localURL = localURL; self.repository = repository
    }

    var isBusy: Bool { phase == .preparing || phase == .saving || isChecking }
    var canRetry: Bool { !isStopped && phase == .paused && !isChecking }

    func prepare() async throws {
        guard OfficeDocumentFormat.supports(item), !item.isRecyclePath,
              item.path.hasPrefix("/"), localURL.isFileURL else { throw OfficeEditingError.invalidTarget }
        holdsSecurityScope = localURL.startAccessingSecurityScopedResource()
        do {
            let before = try await currentRemote()
            try await checkPermission()
            guard !isStopped else { throw CancellationError() }
            try await repository.download(remotePath: item.path, to: localURL, expectedSize: before.sizeBytes) { _, _ in }
            guard !isStopped else { throw CancellationError() }
            let fingerprint = try await Task.detached { [localURL] in try OfficeFileFingerprint.read(localURL) }.value
            let after = try await currentRemote()
            guard Self.sameVersion(before, after), after.sizeBytes == fingerprint.size,
                  try await repository.fileMD5(remotePath: item.path).lowercased() == fingerprint.md5,
                  Self.sameVersion(after, try await currentRemote()) else { throw OfficeEditingError.remoteChanged }
            guard !isStopped else { throw CancellationError() }
            baseline = after; baselineFingerprint = fingerprint
            synchronizedStamp = try OfficeLocalFileStamp.read(localURL)
            phase = .watching
        } catch {
            await repository.removePartialDownload(to: localURL)
            stop(); throw error
        }
    }

    func startMonitoring() {
        guard monitor == nil, !isStopped, baseline != nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, !self.isStopped else { return }
                await self.poll()
            }
        }
    }

    /// 连续两秒元数据稳定后再读取；文件标识变化也能捕捉编辑器的原子替换保存。
    func poll(now: Date = Date()) async {
        guard !isStopped, !isChecking, [.watching, .waitingForSave, .saved].contains(phase) else { return }
        do {
            let stamp = try OfficeLocalFileStamp.read(localURL)
            guard stamp != synchronizedStamp else { observedStamp = nil; observedAt = nil; return }
            if observedStamp != stamp { observedStamp = stamp; observedAt = now; phase = .waitingForSave; return }
            guard let observedAt, now.timeIntervalSince(observedAt) >= 2 else { return }
            await synchronize()
        } catch {
            phase = .paused; message = L10n.string("files.office.localUnavailable")
        }
    }

    func retry() async {
        guard canRetry else { return }
        phase = .waitingForSave; message = nil; observedStamp = nil; observedAt = nil
        await poll()
    }

    private func synchronize() async {
        guard !isChecking, let baseline, let oldFingerprint = baselineFingerprint else { return }
        isChecking = true; defer { isChecking = false; finishStopIfNeeded() }
        var snapshot: OfficeUploadSnapshot?
        defer { if let snapshot { try? FileManager.default.removeItem(at: snapshot.directory) } }
        do {
            let prepared = try await Task.detached { [localURL, item] in
                try OfficeUploadSnapshot.create(from: localURL, remoteName: item.name)
            }.value
            snapshot = prepared
            guard !isStopped else { return }
            // 单纯打开、触碰时间或保存相同内容均不会请求 NAS 写入。
            if prepared.fingerprint.sha256 == oldFingerprint.sha256 {
                synchronizedStamp = prepared.sourceStamp; phase = .watching; observedStamp = nil; return
            }
            let current = try await currentRemote()
            guard Self.sameVersion(current, baseline),
                  try await repository.fileMD5(remotePath: item.path).lowercased() == oldFingerprint.md5 else {
                phase = .conflict; message = L10n.string("files.office.conflict"); return
            }
            try await checkPermission()
            guard Self.sameVersion(current, try await currentRemote()) else {
                phase = .conflict; message = L10n.string("files.office.conflict"); return
            }
            guard !isStopped else { return }
            phase = .saving; message = nil; attemptedFingerprint = prepared.fingerprint
            do {
                try await repository.upload(localURL: prepared.url, to: (item.path as NSString).deletingLastPathComponent,
                                            overwrite: true) { _, _ in }
            } catch {
                // 请求发出后只核对内容；超时或取消不得自动重发覆盖。
            }
            if try await verifyAttempt() {
                synchronizedStamp = prepared.sourceStamp; observedStamp = nil; observedAt = nil
            }
        } catch OfficeEditingError.changedDuringRead {
            observedStamp = nil; observedAt = nil; phase = .waitingForSave
        } catch {
            if attemptedFingerprint != nil {
                phase = .needsReview; message = L10n.string("files.office.unknown")
            } else {
                phase = .paused; message = L10n.string("files.office.paused")
            }
        }
    }

    /// 结果不明时按钮只回读，不再次上传。确认后下一次本机保存仍沿同一会话处理。
    func review() async {
        guard phase == .needsReview, !isChecking else { return }
        isChecking = true; defer { isChecking = false; finishStopIfNeeded() }
        do { _ = try await verifyAttempt() }
        catch { message = L10n.string("files.office.unknown") }
    }

    private func verifyAttempt() async throws -> Bool {
        guard let attemptedFingerprint else { return false }
        let current = try await currentRemote()
        guard current.sizeBytes == attemptedFingerprint.size,
              try await repository.fileMD5(remotePath: item.path).lowercased() == attemptedFingerprint.md5,
              Self.sameVersion(current, try await currentRemote()) else {
            phase = .needsReview; message = L10n.string("files.office.unknown"); return false
        }
        baseline = current; baselineFingerprint = attemptedFingerprint; self.attemptedFingerprint = nil
        lastSavedAt = Date(); phase = .saved; message = nil
        return true
    }

    func stop() {
        isStopped = true
        // 已发送的上传继续核查结果；停止后不再启动下一次写入。
        if !isChecking { monitor?.cancel(); monitor = nil }
        finishStopIfNeeded()
    }

    private func finishStopIfNeeded() {
        guard isStopped, !isChecking else { return }
        if phase != .needsReview && phase != .conflict { phase = .stopped }
        if holdsSecurityScope { localURL.stopAccessingSecurityScopedResource(); holdsSecurityScope = false }
    }

    private func checkPermission() async throws {
        // 与既有覆盖上传一致：公开权限检查只保证目录中新建权限，不能用现有文件名探测覆盖。
        // 是否允许覆盖由正式 Upload 判定，随后必须核对远端内容。
        try await repository.checkWritePermission(folderPath: (item.path as NSString).deletingLastPathComponent,
                                                 filename: "LanStash-Write-Check-\(UUID().uuidString).tmp", createOnly: true)
    }

    private func currentRemote() async throws -> FileItem {
        let matches = try await repository.getInfo(paths: [item.path])
        guard matches.count == 1, let current = matches.first, current.profileID == item.profileID,
              current.path == item.path, !current.isDirectory, !current.isRecyclePath else { throw OfficeEditingError.remoteChanged }
        return current
    }

    private static func sameVersion(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        lhs.profileID == rhs.profileID && lhs.path == rhs.path && lhs.kind == rhs.kind && lhs.sizeBytes == rhs.sizeBytes
            && lhs.times?.modifiedAt == rhs.times?.modifiedAt && lhs.times?.createdAt == rhs.times?.createdAt
            && lhs.mountPointType == rhs.mountPointType
    }
}

/// 由应用持有会话；关闭预览或主窗口不丢失仍在运行的编辑与回传。
@MainActor @Observable
final class OfficeEditingCoordinator {
    static let shared = OfficeEditingCoordinator()
    private(set) var sessions: [OfficeEditingSession] = []
    private(set) var preparingIDs = Set<String>()

    var hasActiveSessions: Bool { !preparingIDs.isEmpty || sessions.contains { !$0.isStopped || $0.isBusy } }
    var hasBusySessions: Bool { !preparingIDs.isEmpty || sessions.contains(where: \.isBusy) }

    func session(for item: FileItem) -> OfficeEditingSession? {
        sessions.first { $0.item.id == item.id && !$0.isStopped }
    }

    func begin(item: FileItem, localURL: URL, repository: any FileRepository, monitor: Bool = true) async throws -> OfficeEditingSession {
        guard !preparingIDs.contains(item.id), !sessions.contains(where: {
            (!$0.isStopped || $0.isBusy)
                && ($0.item.id == item.id || $0.localURL.standardizedFileURL == localURL.standardizedFileURL)
        }) else {
            throw OfficeEditingError.invalidTarget
        }
        preparingIDs.insert(item.id); defer { preparingIDs.remove(item.id) }
        let session = OfficeEditingSession(item: item, localURL: localURL, repository: repository)
        // 提前登记，使断开连接和退出保护也覆盖准备阶段。
        sessions.append(session)
        do {
            try await session.prepare()
            guard !session.isStopped else { throw CancellationError() }
            if monitor { session.startMonitoring() }
            return session
        } catch {
            session.stop(); sessions.removeAll { $0.id == session.id }; throw error
        }
    }

    func stop(profileID: UUID) { sessions.filter { $0.item.profileID == profileID }.forEach { $0.stop() } }

    func confirmTermination() -> Bool {
        guard hasActiveSessions else { return true }
        let alert = NSAlert()
        if hasBusySessions {
            alert.messageText = L10n.string("files.office.quitBusy")
            alert.informativeText = L10n.string("files.office.quitBusyDetail")
            alert.addButton(withTitle: L10n.string("files.office.keepRunning"))
            alert.runModal(); return false
        }
        alert.messageText = L10n.string("files.office.quitTitle")
        alert.informativeText = L10n.string("files.office.quitDetail")
        alert.addButton(withTitle: L10n.string("files.office.keepRunning"))
        alert.addButton(withTitle: L10n.string("files.office.quitKeepCopies"))
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        sessions.forEach { $0.stop() }
        return true
    }
}
