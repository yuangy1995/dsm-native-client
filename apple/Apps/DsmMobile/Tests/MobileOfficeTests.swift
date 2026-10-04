@testable import DsmMobile
import CryptoKit
import DsmCore
import DsmFileFeature
import Foundation
import XCTest

private actor OfficeGate {
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private actor OfficeRepository: MobileOfficeServing {
    let profileID: UUID
    var content = Data("original".utf8)
    var writable = true
    var permissionFailure = false
    var loseReceipt = false
    var readFailure = false
    var failAfterUpload = false
    var rejectUpload = false
    var revision: TimeInterval = 1000
    var uploadGate: OfficeGate?
    var downloadGate: OfficeGate?
    var permissionGate: OfficeGate?
    private(set) var uploads = 0
    private(set) var permissionChecks = 0
    private(set) var targets: [String] = []
    init(_ id: UUID) { profileID = id }
    func item() -> FileItem {
        .init(profileID: profileID, name: "Document.docx", path: "/sample/Document.docx", kind: .file,
              sizeBytes: Int64(content.count), times: .init(modifiedAt: Date(timeIntervalSince1970: revision), createdAt: nil, accessedAt: nil),
              permissions: .init(canRead: true, canWrite: writable, canDelete: false, posixMode: nil))
    }
    func setup(lose: Bool = false, failAfter: Bool = false, reject: Bool = false, writable: Bool = true, permission: Bool = false) {
        loseReceipt = lose; failAfterUpload = failAfter; rejectUpload = reject; self.writable = writable; permissionFailure = permission
    }
    func change(_ value: String, revision: TimeInterval? = nil) { content = Data(value.utf8); if let revision { self.revision = revision } }
    func failReads(_ value: Bool) { readFailure = value }
    func gateUpload(_ gate: OfficeGate) { uploadGate = gate }
    func gateDownload(_ gate: OfficeGate) { downloadGate = gate }
    func gatePermission(_ gate: OfficeGate) { permissionGate = gate }
    func getInfo(paths: [String]) throws -> [FileItem] {
        if readFailure { throw URLError(.networkConnectionLost) }
        return paths.contains("/sample/Document.docx") ? [item()] : []
    }
    func fileMD5(remotePath: String) throws -> String {
        if readFailure { throw URLError(.networkConnectionLost) }
        return Insecure.MD5.hash(data: content).map { String(format: "%02x", $0) }.joined()
    }
    func checkWritePermission(folderPath: String, filename: String, createOnly: Bool) async throws {
        permissionChecks += 1
        guard folderPath == "/sample", filename != "Document.docx", createOnly else { throw MobileOfficeFailure.changed }
        if let permissionGate { await permissionGate.wait() }
        if permissionFailure { throw MobileOfficeFailure.permission }
    }
    func download(remotePath: String, to localURL: URL, expectedSize: Int64?, progress: @escaping FileTransferProgress) async throws {
        let data = content
        if let downloadGate { await downloadGate.wait() }
        try data.write(to: localURL)
        progress(Int64(data.count), Int64(data.count))
    }
    func upload(localURL: URL, to folderPath: String, overwrite: Bool, progress: @escaping FileTransferProgress) async throws {
        guard folderPath == "/sample", localURL.lastPathComponent == "Document.docx", overwrite else { throw MobileOfficeFailure.changed }
        uploads += 1; targets.append(folderPath + "/" + localURL.lastPathComponent)
        if let uploadGate { await uploadGate.wait() }
        if rejectUpload { throw MobileOfficeFailure.permission }
        content = try Data(contentsOf: localURL); revision += 1
        progress(Int64(content.count), Int64(content.count))
        if failAfterUpload { readFailure = true }
        if loseReceipt { throw URLError(.networkConnectionLost) }
    }
}

@MainActor final class MobileOfficeTests: XCTestCase {
    @MainActor private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileOfficeTests-" + UUID().uuidString)
        let profile: NasProfile
        let repository: OfficeRepository
        let model: MobileOfficeModel
        init() throws {
            profile = try NasProfile(displayName: "Sample NAS", host: "sample.invalid", port: 5001, usernameHint: "writer")
            repository = OfficeRepository(profile.id)
            model = MobileOfficeModel(rootURL: root.appendingPathComponent("Office"))
            model.configure(profile: profile, repository: repository)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func prepared() async throws -> UUID {
            let item = await repository.item()
            let id = await model.prepare(item)
            return try XCTUnwrap(id)
        }
        func candidate(_ value: String = "edited", name: String = "Chosen.docx") throws -> URL {
            let file = root.appendingPathComponent(name); try Data(value.utf8).write(to: file); return file
        }
        func changed() async throws -> UUID {
            let id = try await prepared()
            await model.importEdited(try candidate(), id: id, expectedContext: try XCTUnwrap(model.context))
            XCTAssertEqual(model.record(id)?.phase, .changed)
            return id
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    func test主动回传保持原名称并从当前内容建立下一轮基线() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(); await f.model.save(id)
        XCTAssertEqual(f.model.record(id)?.phase, .saved)
        let content = await f.repository.content; XCTAssertEqual(content, Data("edited".utf8))
        let targets = await f.repository.targets; XCTAssertEqual(targets, ["/sample/Document.docx"])
        await f.model.importEdited(try f.candidate("second edit"), id: id, expectedContext: try XCTUnwrap(f.model.context))
        await f.model.save(id)
        XCTAssertEqual(f.model.record(id)?.phase, .saved)
        let uploads = await f.repository.uploads; XCTAssertEqual(uploads, 2)
    }

    func test相同内容和重复保存不会产生写请求() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.prepared()
        await f.model.importEdited(try f.candidate("original"), id: id, expectedContext: try XCTUnwrap(f.model.context))
        XCTAssertEqual(f.model.record(id)?.phase, .unchanged)
        await f.model.save(id); await f.model.save(id)
        let count = await f.repository.uploads; XCTAssertEqual(count, 0)
        let permission = await f.repository.permissionChecks; XCTAssertEqual(permission, 0)
    }

    func test远端同大小同时间的内容变化也停止覆盖() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(); await f.repository.change("modified")
        await f.model.save(id)
        XCTAssertEqual(f.model.record(id)?.phase, .conflict)
        XCTAssertNotNil(f.model.copyURL(id))
        let count = await f.repository.uploads; XCTAssertEqual(count, 0)
    }

    func test权限撤销和目录拒绝均零上传() async throws {
        for filePermission in [true, false] {
            let f = try Fixture(); defer { f.cleanup() }
            let id = try await f.changed()
            await f.repository.setup(writable: !filePermission, permission: !filePermission)
            await f.model.save(id)
            XCTAssertEqual(f.model.failure, .permission)
            let count = await f.repository.uploads; XCTAssertEqual(count, 0)
        }
    }

    func test上传丢回执但内容一致可以回读成功而不重传() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(); await f.repository.setup(lose: true)
        await f.model.save(id); await f.model.refresh(id); await f.model.save(id)
        XCTAssertEqual(f.model.record(id)?.phase, .saved)
        let count = await f.repository.uploads; XCTAssertEqual(count, 1)
    }

    func test未知结果跨重启只读恢复禁止导入或删除记录() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(); await f.repository.setup(lose: true, failAfter: true)
        await f.model.save(id)
        XCTAssertEqual(f.model.record(id)?.phase, .uncertain)
        let recovered = MobileOfficeModel(rootURL: f.model.store.root)
        recovered.configure(profile: f.profile, repository: f.repository)
        await recovered.save(id); recovered.discard(id)
        await recovered.importEdited(try f.candidate("later"), id: id, expectedContext: try XCTUnwrap(recovered.context))
        XCTAssertEqual(recovered.record(id)?.phase, .uncertain)
        await f.repository.failReads(false); await recovered.refresh(id)
        XCTAssertEqual(recovered.record(id)?.phase, .saved)
        let count = await f.repository.uploads; XCTAssertEqual(count, 1)
    }

    func test未知上传不以原文件仍在判断为成功() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(); await f.repository.setup(reject: true)
        await f.model.save(id); await f.model.refresh(id); await f.model.save(id)
        XCTAssertEqual(f.model.record(id)?.phase, .uncertain)
        let count = await f.repository.uploads; XCTAssertEqual(count, 1)
    }

    func test准备期间换账号丢弃迟到副本() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let gate = OfficeGate(); await f.repository.gateDownload(gate)
        let task = Task { await f.model.prepare(await f.repository.item()) }
        while !(await gate.waiting) { await Task.yield() }
        f.model.configure(profile: nil, repository: nil)
        await gate.release(); let result = await task.value
        XCTAssertNil(result); XCTAssertTrue(f.model.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.model.store.file.path))
    }

    func test权限读取迟到不会向旧账号提交覆盖() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(), gate = OfficeGate(); await f.repository.gatePermission(gate)
        let task = Task { await f.model.save(id) }
        while !(await gate.waiting) { await Task.yield() }
        f.model.configure(profile: nil, repository: nil); await gate.release(); await task.value
        let count = await f.repository.uploads; XCTAssertEqual(count, 0)
    }

    func test重复点击和上传期间切换会话不会串结果() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(), gate = OfficeGate(); await f.repository.gateUpload(gate)
        let task = Task { await f.model.save(id) }
        while !(await gate.waiting) { await Task.yield() }
        await f.model.save(id)
        f.model.configure(profile: nil, repository: nil); await gate.release(); await task.value
        XCTAssertTrue(f.model.records.isEmpty)
        f.model.configure(profile: f.profile, repository: f.repository)
        XCTAssertEqual(f.model.record(id)?.phase, .uncertain)
        await f.model.refresh(id); XCTAssertEqual(f.model.record(id)?.phase, .saved)
        let count = await f.repository.uploads; XCTAssertEqual(count, 1)
    }

    func test权限检查期间同大小内容变化仍阻止覆盖() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(), gate = OfficeGate(); await f.repository.gatePermission(gate)
        let task = Task { await f.model.save(id) }
        while !(await gate.waiting) { await Task.yield() }
        await f.repository.change("modified"); await gate.release(); await task.value
        XCTAssertEqual(f.model.record(id)?.phase, .conflict)
        let count = await f.repository.uploads; XCTAssertEqual(count, 0)
    }

    func test编辑器晚到保存不会改变已经冻结的上传文件() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(), gate = OfficeGate()
        let exported = try XCTUnwrap(f.model.copyURL(id))
        await f.repository.gateUpload(gate)
        let task = Task { await f.model.save(id) }
        while !(await gate.waiting) { await Task.yield() }
        try Data("later editor save".utf8).write(to: exported)
        await gate.release(); await task.value
        XCTAssertEqual(f.model.record(id)?.phase, .saved)
        let content = await f.repository.content; XCTAssertEqual(content, Data("edited".utf8))
    }

    func test记录保存失败不会开始上传且保留副本() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed()
        try FileManager.default.removeItem(at: f.model.store.file)
        try FileManager.default.createDirectory(at: f.model.store.file, withIntermediateDirectories: false)
        await f.model.save(id)
        let count = await f.repository.uploads; XCTAssertEqual(count, 0)
        XCTAssertEqual(f.model.record(id)?.phase, .changed)
        XCTAssertNotNil(f.model.copyURL(id))
    }

    func test未来版本和损坏文件保留原件并禁写() async throws {
        for content in ["{\"version\":99,\"records\":[]}", "invalid"] {
            let f = try Fixture(); defer { f.cleanup() }
            try MobileTransferRecoveryStore.prepareDirectory(f.model.store.root)
            let data = Data(content.utf8); try data.write(to: f.model.store.file)
            let model = MobileOfficeModel(rootURL: f.model.store.root)
            model.configure(profile: f.profile, repository: f.repository)
            let id = await model.prepare(await f.repository.item())
            XCTAssertNil(id); XCTAssertTrue(model.recoveryFailed)
            XCTAssertEqual(try Data(contentsOf: f.model.store.file), data)
        }
    }

    func test错误格式和符号链接不替换已有编辑副本() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(), original = f.model.record(id)
        await f.model.importEdited(try f.candidate("not word", name: "Sheet.xlsx"), id: id, expectedContext: try XCTUnwrap(f.model.context))
        XCTAssertEqual(f.model.failure, .format); XCTAssertEqual(f.model.record(id), original)
        let link = f.root.appendingPathComponent("Link.docx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.candidate())
        await f.model.importEdited(link, id: id, expectedContext: try XCTUnwrap(f.model.context))
        XCTAssertEqual(f.model.failure, .local); XCTAssertEqual(f.model.record(id), original)
        let reopened = await f.model.prepare(await f.repository.item())
        XCTAssertEqual(reopened, id); XCTAssertNil(f.model.failure)
    }

    func test候选副本被修改后不能上传旧摘要对应的内容() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed(), url = try XCTUnwrap(f.model.copyURL(id))
        try Data("mutated".utf8).write(to: url)
        await f.model.save(id)
        XCTAssertEqual(f.model.failure, .local)
        let count = await f.repository.uploads; XCTAssertEqual(count, 0)
    }

    func test相同UUID改账号隔离并保留原账号记录() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let id = try await f.changed()
        let changed = try NasProfile(id: f.profile.id, displayName: "Other", host: "sample.invalid", port: 5001, usernameHint: "other")
        f.model.configure(profile: changed, repository: f.repository)
        XCTAssertTrue(f.model.records.isEmpty); XCTAssertNil(f.model.copyURL(id))
        await f.model.save(id)
        f.model.configure(profile: f.profile, repository: f.repository)
        XCTAssertEqual(f.model.record(id)?.phase, .changed)
        f.model.discard(id); XCTAssertTrue(f.model.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.model.store.directory(id).path))
        let count = await f.repository.uploads; XCTAssertEqual(count, 0)
    }

    func test重复打开复用记录并拒绝异常目标() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = try await f.prepared(), second = try await f.prepared()
        XCTAssertEqual(first, second); XCTAssertEqual(f.model.records.count, 1)
        for path in ["/Document.docx", "/sample/../Document.docx", "/sample//Document.docx", "/sample/#recycle/Document.docx", "/sample/Bad\".docx"] {
            let item = FileItem(profileID: f.profile.id, name: (path as NSString).lastPathComponent, path: path, kind: .file)
            XCTAssertFalse(MobileOfficePolicy.supports(item), path)
        }
    }
}
