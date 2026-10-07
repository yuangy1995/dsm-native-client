@testable import DsmMobile
import CryptoKit
import DsmCore
import DsmNetwork
import Foundation
import XCTest

private actor CrossNASRepository: MobileCrossNASRepository {
    nonisolated let profileID: UUID
    var items: [String: FileItem] = [:]
    var data: [String: Data] = [:]
    var copies: [String] = []
    var creations: [String] = []
    var deletions: [(String, Bool)] = []
    var loseCopy: String?
    var loseFolder = false
    var loseDeletion = false
    var delayed = false
    var repeatPage = false
    var delayedReads = false
    var holdsCopy = false
    var holdsDelete = false
    private(set) var cancellations = 0
    init(_ id: UUID) { profileID = id }
    func set(_ path: String, directory: Bool = false, value: String = "sample", writable: Bool = true, deletable: Bool = true) {
        items[path] = FileItem(profileID: profileID, name: MobileCrossNASPlan.leaf(path), path: path,
            kind: directory ? .directory : .file, sizeBytes: directory ? nil : Int64(value.utf8.count),
            times: .init(modifiedAt: Date(timeIntervalSince1970: 1000), createdAt: nil, accessedAt: nil),
            permissions: .init(canRead: true, canWrite: writable, canDelete: deletable, posixMode: nil))
        if !directory { data[path] = Data(value.utf8) }
    }
    func loseCopyReceipt(_ path: String) { loseCopy = path }
    func loseFolderReceipt() { loseFolder = true }
    func loseDeleteReceipt() { loseDeletion = true }
    func setDelayed() { delayed = true }
    func setDelayedReads() { delayedReads = true }
    func setRepeatPage() { repeatPage = true }
    func hold(copy: Bool = false, deletion: Bool = false) { holdsCopy = copy; holdsDelete = deletion }
    private func waitForCancellation() async throws {
        do { try await Task.sleep(for: .seconds(60)) }
        catch { cancellations += 1; throw error }
    }
    func listFolder(path: String, offset: Int, limit: Int) async throws -> FilePage {
        let children = items.values.filter { MobileCrossNASPlan.parent($0.path) == path }.sorted { $0.path < $1.path }
        let page = Array(children.dropFirst(repeatPage && offset > 0 ? 0 : offset).prefix(limit))
        return .init(folderPath: path, items: page, offset: offset, total: children.count, hasMore: offset + page.count < children.count)
    }
    func getInfo(paths: [String]) async throws -> [FileItem] {
        if delayedReads { try await Task.sleep(for: .milliseconds(150)) }
        return paths.compactMap { items[$0] }
    }
    func fileMD5(remotePath: String) async throws -> String {
        guard let data = data[remotePath] else { throw URLError(.fileDoesNotExist) }
        return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func createFolder(parentPath: String, name: String) async throws {
        let path = parentPath + "/" + name
        guard items[path] == nil else { throw MobileCrossNASFailure.conflict }
        creations.append(path); set(path, directory: true)
        if loseFolder { loseFolder = false; throw URLError(.networkConnectionLost) }
    }
    func copyCrossNAS(_ item: FileItem, to target: any MobileCrossNASRepository,
                      folder: String, progress: @escaping FileTransferProgress) async throws {
        copies.append(item.path)
        if holdsCopy { try await waitForCancellation() }
        if delayed {
            await withCheckedContinuation { continuation in
                Task { try? await Task.sleep(for: .milliseconds(120)); continuation.resume() }
            }
        }
        guard let target = target as? CrossNASRepository, let data = data[item.path] else { throw MobileCrossNASFailure.invalid }
        try await target.accept(folder + "/" + item.name, data: data)
        progress(Int64(data.count * 2), Int64(data.count * 2))
    }
    private func accept(_ path: String, data: Data) throws {
        guard items[path] == nil else { throw MobileCrossNASFailure.conflict }
        set(path, value: String(decoding: data, as: UTF8.self))
        if loseCopy == path { loseCopy = nil; throw URLError(.networkConnectionLost) }
    }
    func deleteResult(paths: [String], recursive: Bool, progress: @escaping FileTransferProgress) async throws -> MutationResult {
        for path in paths {
            deletions.append((path, recursive))
            guard !recursive, !items.keys.contains(where: { $0.hasPrefix(path + "/") }) else { throw MobileCrossNASFailure.changed }
            items[path] = nil; data[path] = nil
            if holdsDelete { try await waitForCancellation() }
        }
        if loseDeletion { loseDeletion = false; throw URLError(.networkConnectionLost) }
        return try .init(status: .confirmedSuccess, operation: "fileDelete", submitted: true,
            requiresRefresh: false, counts: .init(succeeded: paths.count, failed: 0, unknown: 0))
    }
}

private actor CrossNASSessionStore: SessionSecureStoring {
    let session: AuthSession?
    let delayed: Bool
    private(set) var requested: [UUID] = []
    init(session: AuthSession? = nil, delayed: Bool = false) { self.session = session; self.delayed = delayed }
    func save(_ session: AuthSession, for profileID: UUID) async throws {}
    func load(for profileID: UUID) async throws -> AuthSession? {
        requested.append(profileID)
        if delayed { try await Task.sleep(for: .milliseconds(120)) }
        return session
    }
    func remove(for profileID: UUID) async throws {}
}

private actor CrossNASAuth: AuthRepository {
    private(set) var discoveries = 0
    func discover(profile: NasProfile) async throws -> CapabilitySet { discoveries += 1; throw MobileCrossNASFailure.invalid }
    func login(profile: NasProfile, capabilities: CapabilitySet, account: String, password: String, otpCode: String?) async throws -> AuthSession { throw MobileCrossNASFailure.invalid }
    func restoreSession(for profileID: UUID) async throws -> AuthSession? { nil }
    func clearSession(for profileID: UUID) async throws {}
    func logout(profile: NasProfile, capabilities: CapabilitySet, session: AuthSession) async throws {}
}

@MainActor
final class MobileCrossNASTests: XCTestCase {
    @MainActor private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileCrossNASTests-" + UUID().uuidString)
        let source: MobileCrossNASEndpoint
        let target: MobileCrossNASEndpoint
        let sourceRepo: CrossNASRepository
        let targetRepo: CrossNASRepository
        let queue: MobileCrossNASQueue
        init(background: (any MobileTransferBackgroundManaging)? = nil) async throws {
            let a = try NasProfile(displayName: "Source", host: "source.invalid", port: 5001, usernameHint: "reader")
            let b = try NasProfile(displayName: "Target", host: "target.invalid", port: 5001, usernameHint: "writer")
            sourceRepo = CrossNASRepository(a.id); targetRepo = CrossNASRepository(b.id)
            source = .init(profile: a, repository: sourceRepo); target = .init(profile: b, repository: targetRepo)
            await sourceRepo.set("/source", directory: true)
            await sourceRepo.set("/source/File.txt", writable: false)
            await sourceRepo.set("/source/Folder", directory: true)
            await sourceRepo.set("/source/Folder/Empty", directory: true)
            await sourceRepo.set("/source/Folder/Child.txt", value: "nested")
            await targetRepo.set("/target", directory: true)
            queue = MobileCrossNASQueue(rootURL: root, backgroundExecution: background); queue.configure(source: source)
        }
        func selected() async -> [FileItem] { try! await sourceRepo.getInfo(paths: ["/source/File.txt", "/source/Folder"]) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    private func unwrap(_ value: UUID?) throws -> UUID { try XCTUnwrap(value) }

    func test复制到期取消网络落盘未知结果且后续项不启动() async throws {
        let driver = BackgroundDriverFixture()
        let f = try await Fixture(background: MobileTransferBackgroundExecution(driver: driver)); defer { f.cleanup() }
        await f.sourceRepo.hold(copy: true)
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: true))
        while await f.sourceRepo.copies.isEmpty { await Task.yield() }
        await driver.jobs[0].expiration()
        XCTAssertFalse(f.queue.isWorking)
        XCTAssertEqual(f.queue.records[0].entries[0].status, .uncertain)
        XCTAssertTrue(f.queue.records[0].entries.dropFirst().allSatisfy { $0.status == .pending })
        XCTAssertEqual(driver.limited[0].completions, [false])
        let cancelled = await f.sourceRepo.cancellations, copies = await f.sourceRepo.copies, deletes = await f.sourceRepo.deletions
        XCTAssertEqual(cancelled, 1); XCTAssertEqual(copies.count, 1); XCTAssertTrue(deletes.isEmpty)
        let restored = MobileCrossNASQueue(rootURL: f.root); restored.configure(source: f.source)
        XCTAssertEqual(restored.records, f.queue.records)
        restored.resume(id, target: f.target); f.queue.resume(id, target: f.target)
        let unchanged = await f.sourceRepo.copies; XCTAssertEqual(unchanged.count, 1)
    }

    func test准备清单到期不创建记录或开始复制() async throws {
        let driver = BackgroundDriverFixture()
        let f = try await Fixture(background: MobileTransferBackgroundExecution(driver: driver)); defer { f.cleanup() }
        let selected = await f.selected(); await f.sourceRepo.setDelayedReads()
        let task = Task { await f.queue.submit(items: selected, target: f.target, destination: "/target", moveSource: false) }
        while driver.jobs.isEmpty { await Task.yield() }
        await driver.jobs[0].expiration()
        let result = await task.value
        XCTAssertNil(result); XCTAssertTrue(f.queue.records.isEmpty); XCTAssertFalse(f.queue.isWorking)
        let copies = await f.sourceRepo.copies; XCTAssertTrue(copies.isEmpty)
        XCTAssertEqual(driver.limited[0].completions, [false])
    }

    func test删源到期保留未知且只读恢复后不重复已删除项目() async throws {
        let driver = BackgroundDriverFixture()
        let f = try await Fixture(background: MobileTransferBackgroundExecution(driver: driver)); defer { f.cleanup() }
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: true))
        try await wait(f.queue)
        XCTAssertEqual(driver.limited[0].completions, [true])
        await f.sourceRepo.hold(deletion: true)
        f.queue.removeSource(id, target: f.target)
        while await f.sourceRepo.deletions.isEmpty { await Task.yield() }
        // 上一轮复制的迟到到期不能取消已明确开始的删源。
        await driver.jobs[0].expiration()
        XCTAssertTrue(f.queue.isWorking); XCTAssertTrue(driver.limited[1].completions.isEmpty)
        await driver.jobs[1].expiration()
        XCTAssertFalse(f.queue.isWorking); XCTAssertTrue(f.queue.records[0].hasUnknown)
        XCTAssertEqual(driver.limited[1].completions, [false])
        f.queue.removeSource(id, target: f.target)
        let before = await f.sourceRepo.deletions; XCTAssertEqual(before.count, 1)
        await f.sourceRepo.hold()
        await f.queue.refresh(id, target: f.target)
        f.queue.removeSource(id, target: f.target); try await wait(f.queue)
        let after = await f.sourceRepo.deletions
        XCTAssertEqual(Set(after.map(\.0)).count, 4); XCTAssertEqual(after.count, 4)
        XCTAssertEqual(f.queue.records[0].phase, .finished)
        XCTAssertEqual(driver.limited[2].completions, [true])
    }

    func test系统拒绝持续时间仍用有限时间完成且两阶段单独申请() async throws {
        let driver = BackgroundDriverFixture(); driver.rejectsSubmission = true
        let f = try await Fixture(background: MobileTransferBackgroundExecution(driver: driver)); defer { f.cleanup() }
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: true))
        try await wait(f.queue)
        XCTAssertEqual(driver.jobs.count, 1)
        let deletes = await f.sourceRepo.deletions; XCTAssertTrue(deletes.isEmpty)
        f.queue.removeSource(id, target: f.target); try await wait(f.queue)
        XCTAssertEqual(driver.jobs.count, 2)
        XCTAssertEqual(driver.limited.map(\.completions), [[true], [true]])
        XCTAssertEqual(f.queue.records[0].phase, .finished)
    }

    private func wait(_ queue: MobileCrossNASQueue) async throws {
        for _ in 0..<250 {
            if !queue.isWorking { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("跨 NAS 测试任务未结束")
    }

    func test混合复制含空目录只读源与零字节逐项比对且不删除() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await f.sourceRepo.set("/source/File.txt", value: "", writable: false)
        let id = await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: false)
        XCTAssertNotNil(id); try await wait(f.queue)
        let record = try XCTUnwrap(f.queue.records.first)
        XCTAssertEqual(record.phase, .copied); XCTAssertEqual(record.entries.count, 4)
        XCTAssertTrue(record.entries.allSatisfy { $0.status == .copied }); XCTAssertFalse(record.canRemoveSource)
        let paths = await f.targetRepo.items.keys.sorted(), deletes = await f.sourceRepo.deletions
        XCTAssertEqual(paths, ["/target", "/target/File.txt", "/target/Folder", "/target/Folder/Child.txt", "/target/Folder/Empty"])
        XCTAssertTrue(deletes.isEmpty)
        let restored = MobileCrossNASQueue(rootURL: f.root); restored.configure(source: f.source)
        XCTAssertEqual(restored.records, f.queue.records); XCTAssertFalse(restored.isWorking)
    }

    func test移动复制完成后仍保留源且独立删源使用非递归倒序() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: true))
        try await wait(f.queue)
        let before = await f.sourceRepo.deletions
        XCTAssertTrue(before.isEmpty); XCTAssertTrue(f.queue.records[0].canRemoveSource)
        f.queue.removeSource(id, target: f.target); try await wait(f.queue)
        XCTAssertEqual(f.queue.records[0].phase, .finished)
        let deletions = await f.sourceRepo.deletions
        XCTAssertEqual(deletions.count, 4); XCTAssertTrue(deletions.allSatisfy { !$0.1 })
        XCTAssertLessThan(try XCTUnwrap(deletions.firstIndex { $0.0 == "/source/Folder/Child.txt" }),
            try XCTUnwrap(deletions.firstIndex { $0.0 == "/source/Folder" }))
        let remaining = await f.sourceRepo.items.keys.sorted()
        XCTAssertEqual(remaining, ["/source"])
    }

    func test目标被同大小改写拒绝删源() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: true))
        try await wait(f.queue)
        await f.targetRepo.set("/target/File.txt", value: "change")
        f.queue.removeSource(id, target: f.target); try await wait(f.queue)
        XCTAssertEqual(f.queue.records[0].failure, .changed)
        let deletions = await f.sourceRepo.deletions; XCTAssertTrue(deletions.isEmpty)
    }

    func test源目录新增内容拒绝删源且保留目标副本() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: true))
        try await wait(f.queue); await f.sourceRepo.set("/source/Folder/New.txt")
        f.queue.removeSource(id, target: f.target); try await wait(f.queue)
        let deletions = await f.sourceRepo.deletions; XCTAssertTrue(deletions.isEmpty)
        XCTAssertEqual(f.queue.records[0].failure, .changed)
    }

    func test源删除权限撤销拒绝全部删除() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: true))
        try await wait(f.queue); await f.sourceRepo.set("/source/File.txt", deletable: false)
        f.queue.removeSource(id, target: f.target); try await wait(f.queue)
        let deletions = await f.sourceRepo.deletions; XCTAssertTrue(deletions.isEmpty)
        XCTAssertEqual(f.queue.records[0].failure, .permission)
    }

    func test重名及目标无写权限在写前失败() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await f.targetRepo.set("/target/File.txt", value: "keep")
        let collision = await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: false)
        XCTAssertNil(collision); XCTAssertEqual(f.queue.error, .conflict)
        await f.targetRepo.set("/readonly", directory: true, writable: false)
        let denied = await f.queue.submit(items: await f.selected(), target: f.target, destination: "/readonly", moveSource: false)
        XCTAssertNil(denied); XCTAssertEqual(f.queue.error, .permission)
        let copies = await f.sourceRepo.copies, creates = await f.targetRepo.creations
        XCTAssertTrue(copies.isEmpty); XCTAssertTrue(creates.isEmpty)
    }

    func test文件丢回执只读刷新然后仅继续未开始项目() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await f.targetRepo.loseCopyReceipt("/target/File.txt")
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: true))
        try await wait(f.queue)
        XCTAssertEqual(f.queue.records[0].entries[0].status, .uncertain)
        XCTAssertFalse(f.queue.records[0].canContinue); XCTAssertFalse(f.queue.records[0].canRemoveSource)
        f.queue.resume(id, target: f.target); try await wait(f.queue)
        let firstCopies = await f.sourceRepo.copies; XCTAssertEqual(firstCopies, ["/source/File.txt"])
        await f.queue.refresh(id, target: f.target)
        XCTAssertTrue(f.queue.records[0].canContinue)
        f.queue.resume(id, target: f.target); try await wait(f.queue)
        XCTAssertEqual(f.queue.records[0].phase, .copied)
        let copies = await f.sourceRepo.copies
        XCTAssertEqual(copies, ["/source/File.txt", "/source/Folder/Child.txt"])
        let deletes = await f.sourceRepo.deletions; XCTAssertTrue(deletes.isEmpty)
    }

    func test目录丢回执不把同名目录当作自己创建而继续写入() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await f.targetRepo.loseFolderReceipt()
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: false))
        try await wait(f.queue); await f.queue.refresh(id, target: f.target)
        XCTAssertEqual(f.queue.records[0].entries[1].status, .uncertain); XCTAssertFalse(f.queue.records[0].canContinue)
        f.queue.resume(id, target: f.target); try await wait(f.queue)
        let copies = await f.sourceRepo.copies; XCTAssertEqual(copies, ["/source/File.txt"])
    }

    func test删除丢回执刷新后继续剩余项且不重复删除() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: true))
        try await wait(f.queue); await f.sourceRepo.loseDeleteReceipt()
        f.queue.removeSource(id, target: f.target); try await wait(f.queue)
        XCTAssertTrue(f.queue.records[0].hasUnknown)
        let first = await f.sourceRepo.deletions; XCTAssertEqual(first.count, 1)
        f.queue.removeSource(id, target: f.target); try await wait(f.queue)
        let unchanged = await f.sourceRepo.deletions; XCTAssertEqual(unchanged.count, 1)
        await f.queue.refresh(id, target: f.target); XCTAssertTrue(f.queue.records[0].canRemoveSource)
        f.queue.removeSource(id, target: f.target); try await wait(f.queue)
        XCTAssertEqual(f.queue.records[0].phase, .finished)
        let deletes = await f.sourceRepo.deletions
        XCTAssertEqual(Set(deletes.map(\.0)).count, 4); XCTAssertEqual(deletes.count, 4)
    }

    func test取消迟到成功换账号不展示也不继续其他写入() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await f.sourceRepo.setDelayed()
        _ = await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: false)
        for _ in 0..<100 { if !(await f.sourceRepo.copies).isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        let other = try NasProfile(id: f.source.profile.id, displayName: "Other", host: "source.invalid", port: 5001, usernameHint: "other")
        f.queue.configure(source: .init(profile: other, repository: f.sourceRepo))
        try await wait(f.queue); XCTAssertTrue(f.queue.records.isEmpty)
        let copies = await f.sourceRepo.copies; XCTAssertEqual(copies.count, 1)
        f.queue.configure(source: f.source)
        XCTAssertEqual(f.queue.records[0].entries[0].status, .uncertain)
        XCTAssertFalse(f.queue.records[0].canContinue)
    }

    func test目标身份变化不复用新会话恢复或删源() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let id = try unwrap(await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: true))
        try await wait(f.queue)
        let other = try NasProfile(id: f.target.profile.id, displayName: "Other", host: "target.invalid", port: 5001, usernameHint: "other")
        f.queue.removeSource(id, target: .init(profile: other, repository: f.targetRepo)); try await wait(f.queue)
        let deletions = await f.sourceRepo.deletions; XCTAssertTrue(deletions.isEmpty)
    }

    func test重复提交被阻止且重启未知状态不自动执行() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        await f.sourceRepo.setDelayed()
        let items = await f.selected()
        let first = await f.queue.submit(items: items, target: f.target, destination: "/target", moveSource: false)
        let second = await f.queue.submit(items: items, target: f.target, destination: "/target", moveSource: false)
        XCTAssertNotNil(first); XCTAssertNil(second)
        for _ in 0..<100 { if !(await f.sourceRepo.copies).isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        let restored = MobileCrossNASQueue(rootURL: f.root); restored.configure(source: f.source)
        XCTAssertFalse(restored.isWorking); XCTAssertEqual(restored.records[0].entries[0].status, .uncertain)
        f.queue.pause(); try await wait(f.queue)
        let copies = await f.sourceRepo.copies; XCTAssertEqual(copies.count, 1)
    }

    func test准备中移除目标连接取消清单且零写入() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let items = await f.selected(); await f.sourceRepo.setDelayedReads()
        let task = Task { await f.queue.submit(items: items, target: f.target, destination: "/target", moveSource: false) }
        for _ in 0..<100 { if f.queue.isPreparing { break }; try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(f.queue.isPreparing)
        f.queue.removeProfile(f.target.profile.id)
        let id = await task.value
        XCTAssertNil(id); XCTAssertTrue(f.queue.records.isEmpty)
        let copies = await f.sourceRepo.copies, folders = await f.targetRepo.creations
        XCTAssertTrue(copies.isEmpty); XCTAssertTrue(folders.isEmpty)
    }

    func test完整分页和重复页在写前被识别() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        for index in 0..<201 { await f.sourceRepo.set("/source/Folder/\(index).txt") }
        let valid = try await MobileCrossNASPlan.prepare(items: await f.selected(), source: f.source,
            target: f.target, destination: "/target", moveSource: false)
        XCTAssertEqual(valid.entries.count, 205)
        await f.sourceRepo.setRepeatPage()
        let id = await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: false)
        XCTAssertNil(id); let copies = await f.sourceRepo.copies; XCTAssertTrue(copies.isEmpty)
    }

    func test损坏或未来版本恢复记录保留原文并禁止写入() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try FileManager.default.createDirectory(at: f.root, withIntermediateDirectories: true)
        let file = f.root.appendingPathComponent("queue-v1.json"), bytes = Data(#"{"version":99,"records":[]}"#.utf8)
        try bytes.write(to: file)
        let queue = MobileCrossNASQueue(rootURL: f.root); queue.configure(source: f.source)
        XCTAssertTrue(queue.recoveryFailed)
        let id = await queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: false)
        XCTAssertNil(id); XCTAssertEqual(try Data(contentsOf: file), bytes)
        let copies = await f.sourceRepo.copies; XCTAssertTrue(copies.isEmpty)
    }

    func test保存记录失败不触发任何远端写入() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        try Data("occupied".utf8).write(to: f.root)
        let id = await f.queue.submit(items: await f.selected(), target: f.target, destination: "/target", moveSource: false)
        XCTAssertNil(id); XCTAssertTrue(f.queue.recoveryFailed)
        let copies = await f.sourceRepo.copies; XCTAssertTrue(copies.isEmpty)
    }

    func test不支持的路径类型大小和上传改名字符不能进入传输() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        for path in ["", "/", "/share", "/source/../secret", "/source/a//b", "/source/#recycle/f", "/source/quote\".txt", "/source/line\n.txt"] {
            let item = FileItem(profileID: f.source.profile.id, name: MobileCrossNASPlan.leaf(path), path: path, kind: .file, sizeBytes: 1)
            XCTAssertFalse(MobileCrossNASPlan.canSelect(item, profileID: f.source.profile.id), path)
        }
        for kind in [FileKind.symlink, .unknown] {
            XCTAssertFalse(MobileCrossNASPlan.canSelect(.init(profileID: f.source.profile.id, name: "file", path: "/source/file", kind: kind, sizeBytes: 1), profileID: f.source.profile.id))
        }
        XCTAssertFalse(MobileCrossNASPlan.canSelect(.init(profileID: f.source.profile.id, name: "file", path: "/source/file", kind: .file), profileID: f.source.profile.id))
        await f.sourceRepo.set("/source/trailing.txt ")
        let values = try await f.sourceRepo.getInfo(paths: ["/source/trailing.txt "])
        let item = try XCTUnwrap(values.first)
        XCTAssertTrue(MobileCrossNASPlan.canSelect(item, profileID: f.source.profile.id))
    }

    func test目标缺会话只读取目标账号且不复用源登录() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let store = CrossNASSessionStore(), auth = CrossNASAuth()
        let suite = "CrossNASTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = MobileAppModel(defaults: defaults, sessionStore: store, authRepository: auth,
            transferRecoveryStore: MobileTransferRecoveryStore(rootURL: f.root))
        app.profiles = [f.source.profile, f.target.profile]
        app.fileRepository = try DsmFileRepository(profile: f.source.profile, capabilities: CapabilitySet([:]),
            session: .init(sid: "fixture-source", synoToken: nil, did: nil, isPortalPort: false))
        app.activeProfile = f.source.profile; app.isConnected = true
        do { _ = try await app.crossNASTarget(f.target.profile); XCTFail("不得复用源会话") }
        catch { XCTAssertEqual(error as? MobileCrossNASFailure, .connection) }
        let requested = await store.requested, discoveries = await auth.discoveries
        XCTAssertEqual(requested, [f.target.profile.id]); XCTAssertEqual(discoveries, 0)
    }

    func test目标会话迟到时源已退出不发现也不连接目标() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let store = CrossNASSessionStore(session: .init(sid: "fixture-target", synoToken: nil, did: nil, isPortalPort: false), delayed: true)
        let auth = CrossNASAuth(), suite = "CrossNASTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = MobileAppModel(defaults: defaults, sessionStore: store, authRepository: auth,
            transferRecoveryStore: MobileTransferRecoveryStore(rootURL: f.root))
        app.profiles = [f.source.profile, f.target.profile]
        app.fileRepository = try DsmFileRepository(profile: f.source.profile, capabilities: CapabilitySet([:]),
            session: .init(sid: "fixture-source", synoToken: nil, did: nil, isPortalPort: false))
        app.activeProfile = f.source.profile; app.isConnected = true
        let task = Task { try await app.crossNASTarget(f.target.profile) }
        for _ in 0..<100 { if !(await store.requested).isEmpty { break }; try await Task.sleep(for: .milliseconds(5)) }
        app.clearWorkspace()
        do { _ = try await task.value; XCTFail("旧连接结果应丢弃") }
        catch { XCTAssertTrue(error is CancellationError) }
        let discoveries = await auth.discoveries; XCTAssertEqual(discoveries, 0)
    }

    func test真实Repository链路两端独立会话复制与非递归删除() async throws {
        let a = try NasProfile(displayName: "A", host: "a.invalid", port: 5001, usernameHint: "a")
        let b = try NasProfile(displayName: "B", host: "b.invalid", port: 5001, usernameHint: "b")
        let versions = [DsmAPIName.fileStationList: 2, DsmAPIName.fileStationDownload: 2, DsmAPIName.fileStationMD5: 2,
            DsmAPIName.fileStationUpload: 3, DsmAPIName.fileStationCheckPermission: 3, DsmAPIName.fileStationCreateFolder: 2, DsmAPIName.fileStationDelete: 2]
        let caps = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { ($0.key, ApiCapability(name: $0.key,
            path: "entry.cgi", minVersion: 1, maxVersion: $0.value, requestFormat: .form, selectedVersion: $0.value, verified: false)) }))
        func repository(_ profile: NasProfile, target: Bool) throws -> DsmFileRepository {
            try DsmFileRepository(profile: profile, capabilities: caps,
                session: .init(sid: target ? "fixture-target" : "fixture-source", synoToken: nil, did: nil, isPortalPort: false),
                transport: MobileCrossNASUITransport(target: target, state: "cross-copy", expectedSID: target ? "fixture-target" : "fixture-source"))
        }
        let source = MobileCrossNASEndpoint(profile: a, repository: try repository(a, target: false))
        let target = MobileCrossNASEndpoint(profile: b, repository: try repository(b, target: true))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CrossNASIntegration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = MobileCrossNASQueue(rootURL: root); queue.configure(source: source)
        let items = try await source.repository.getInfo(paths: ["/fixture/Sample document.txt", "/fixture/Inbox"])
        let id = try unwrap(await queue.submit(items: items, target: target, destination: "/output", moveSource: true))
        try await wait(queue); XCTAssertEqual(queue.records.first?.phase, .copied)
        queue.removeSource(id, target: target); try await wait(queue)
        XCTAssertEqual(queue.records.first?.phase, .finished)
    }
}
