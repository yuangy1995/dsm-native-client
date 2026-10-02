import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class FileUploadWorkflowTests: XCTestCase {
    func test保留空目录隐藏文件中文且不跟随符号链接() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(".隐藏.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("链接"), withDestinationURL: root)
        let sources = try FileUploadPlan.collect([root, root.appendingPathComponent(".隐藏.txt")])
        XCTAssertEqual(sources.count, 4)
        XCTAssertEqual(sources.filter { $0.kind == .symbolicLink }.count, 1)
        XCTAssertEqual(sources.filter { $0.kind == .directory }.count, 2)
        XCTAssertEqual(sources.first { $0.kind == .file }?.size, 0)
    }

    func test同名文件跳过类型冲突不写入() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try makeFiles(root, names: ["existing", "directory"])
        let transport = UploadWorkflowTransport(existing: ["existing": false, "directory": true])
        let batch = try makeBatch(files, transport: transport)
        batch.start(); try await finish(batch)
        XCTAssertEqual(batch.entries.map(\.state), [.skipped, .conflict])
        let writes = await transport.uploadCount; XCTAssertEqual(writes, 0)
    }

    func test多层目录按父级创建且同名目录合并保留空目录() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let top = root.appendingPathComponent("资料 & files")
        let child = top.appendingPathComponent("子目录")
        try FileManager.default.createDirectory(at: child.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        try Data().write(to: child.appendingPathComponent(".隐藏.txt"))
        let transport = UploadWorkflowTransport(existing: ["资料 & files": true])
        let batch = try makeBatch([top], transport: transport)
        batch.start(); try await finish(batch)
        XCTAssertTrue(batch.entries.allSatisfy { $0.state == .succeeded }, batch.entries.map { $0.message ?? $0.state.rawValue }.joined(separator: ","))
        let created = await transport.createdFolders
        XCTAssertEqual(created, ["资料 & files/子目录", "资料 & files/子目录/空目录"])
        let remote = await transport.existing
        XCTAssertEqual(remote["资料 & files/子目录/.隐藏.txt"], false)
        XCTAssertEqual(remote["资料 & files/子目录/空目录"], true)
    }

    func test五个文件最多两个同时上传且逐项回读() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try makeFiles(root, names: (0..<5).map(String.init))
        let transport = UploadWorkflowTransport()
        let batch = try makeBatch(files, transport: transport)
        batch.start(); try await finish(batch)
        XCTAssertTrue(batch.entries.allSatisfy { $0.state == .succeeded })
        let concurrent = await transport.maximumConcurrent; XCTAssertEqual(concurrent, 2)
        let writes = await transport.uploadCount; XCTAssertEqual(writes, 5)
    }

    func test上传超时不允许通过重试再次发送() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = UploadWorkflowTransport(failsUpload: true)
        let batch = try makeBatch(makeFiles(root, names: ["timeout"]), transport: transport)
        batch.start(); try await finish(batch)
        XCTAssertEqual(batch.entries.first?.state, .unverified)
        batch.retryFailed(); batch.start(); try await finish(batch)
        let writes = await transport.uploadCount; XCTAssertEqual(writes, 1)
    }

    func test来源改变不上传且重复目标不能重试覆盖() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try makeFiles(root, names: ["changed"])
        let transport = UploadWorkflowTransport()
        let batch = try makeBatch(files, transport: transport)
        try Data([1]).write(to: files[0])
        batch.start(); try await finish(batch)
        XCTAssertEqual(batch.entries.first?.state, .failed)
        XCTAssertFalse(batch.entries[0].retryAllowed)
        let writes = await transport.uploadCount; XCTAssertEqual(writes, 0)
    }

    func test暂停中断后先核查缺失目标再从头继续() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = UploadWorkflowTransport(uploadDelay: .milliseconds(150))
        let batch = try makeBatch(makeFiles(root, names: ["pause"]), transport: transport)
        batch.start()
        for _ in 0..<100 {
            if await transport.uploadCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        batch.pause(); try await finish(batch)
        XCTAssertEqual(batch.entries[0].state, .paused)
        XCTAssertTrue(batch.entries[0].needsReconciliation)
        batch.resume(); batch.start(); try await finish(batch)
        XCTAssertEqual(batch.entries[0].state, .succeeded)
        let writes = await transport.uploadCount; XCTAssertEqual(writes, 2)
    }

    func test取消保留已完成并把发出后的结果列为待核对() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = UploadWorkflowTransport(uploadDelay: .milliseconds(100))
        let batch = try makeBatch(makeFiles(root, names: ["a", "b", "c", "d", "e"]), transport: transport)
        batch.start()
        for _ in 0..<150 {
            if await transport.uploadCount >= 3 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        batch.cancel(); try await finish(batch)
        XCTAssertEqual(batch.entries.filter { $0.state == .succeeded }.count, 2)
        XCTAssertEqual(batch.entries.filter { $0.state == .unverified }.count, 2)
        XCTAssertEqual(batch.entries.filter { $0.state == .cancelled }.count, 1)
        let remaining = await transport.existing; XCTAssertEqual(remaining.count, 2)
    }

    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func makeFiles(_ root: URL, names: [String]) throws -> [URL] {
        try names.map { name in let url = root.appendingPathComponent(name); try Data().write(to: url); return url }
    }
    private func makeBatch(_ urls: [URL], transport: UploadWorkflowTransport) throws -> FileUploadBatch {
        let profile = try NasProfile(displayName: "Synthetic", host: "nas.invalid", port: 5001)
        let names = [DsmAPIName.fileStationList, DsmAPIName.fileStationUpload, DsmAPIName.fileStationCheckPermission, DsmAPIName.fileStationCreateFolder]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
            ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .form, selectedVersion: 2))
        }))
        let repository = try DsmFileRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        return FileUploadBatch(sources: try FileUploadPlan.collect(urls), destination: "/synthetic", overwrite: false, repository: repository)
    }
    private func finish(_ batch: FileUploadBatch) async throws {
        for _ in 0..<200 where batch.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(batch.isRunning)
    }
}

private actor UploadWorkflowTransport: DsmBinaryHTTPTransport {
    var existing: [String: Bool]
    let failsUpload: Bool
    let uploadDelay: Duration
    private(set) var uploadCount = 0
    private(set) var createdFolders: [String] = []
    private var concurrent = 0
    private(set) var maximumConcurrent = 0
    init(existing: [String: Bool] = [:], failsUpload: Bool = false, uploadDelay: Duration = .milliseconds(40)) {
        self.existing = existing; self.failsUpload = failsUpload; self.uploadDelay = uploadDelay
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let fields = URLComponents(string: "?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!
            .replacingOccurrences(of: "+", with: "%20"))?.queryItems ?? []
        let parameters = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
        let method = parameters["method"]
        if method == "write" { return try response([:]) }
        if method == "getinfo" {
            let paths = try JSONDecoder().decode([String].self, from: Data((parameters["path"] ?? "[]").utf8))
            return try response(["files": paths.compactMap { path -> [String: Any]? in
                let relative = String(path.dropFirst("/synthetic/".count))
                if path == "/synthetic" { return item(path, directory: true) }
                guard let directory = existing[relative] else { return nil }
                return item(path, directory: directory)
            }])
        }
        if method == "create", let folder = parameters["folder_path"], let name = parameters["name"] {
            let relative = String((folder + "/" + name).dropFirst("/synthetic/".count))
            existing[relative] = true; createdFolders.append(relative)
            return try response([:])
        }
        guard method == "list" else { throw URLError(.unsupportedURL) }
        let children = existing.filter { (("/synthetic/" + $0.key) as NSString).deletingLastPathComponent == parameters["folder_path"] }
        return try response(["offset": 0, "total": children.count,
            "files": children.map { item("/synthetic/" + $0.key, directory: $0.value) }])
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        uploadCount += 1; concurrent += 1; maximumConcurrent = max(concurrent, maximumConcurrent)
        defer { concurrent -= 1 }
        try await Task.sleep(for: uploadDelay)
        if failsUpload { throw URLError(.timedOut) }
        let body = try String(contentsOf: bodyFileURL, encoding: .utf8)
        let marker = "filename=\""
        guard let start = body.range(of: marker)?.upperBound, let end = body[start...].firstIndex(of: "\"") else { throw URLError(.badServerResponse) }
        let pathMarker = "name=\"path\"\r\n\r\n"
        guard let pathStart = body.range(of: pathMarker)?.upperBound,
              let pathEnd = body[pathStart...].range(of: "\r\n")?.lowerBound else { throw URLError(.badServerResponse) }
        let path = String(body[pathStart..<pathEnd]) + "/" + String(body[start..<end])
        existing[String(path.dropFirst("/synthetic/".count))] = false
        return try response([:])
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
    private func item(_ path: String, directory: Bool) -> [String: Any] {
        ["name": (path as NSString).lastPathComponent, "path": path, "isdir": directory,
         "additional": ["size": 0, "perm": ["adv_right": ["write": true, "read": true]]]]
    }
    private func response(_ data: [String: Any]) throws -> DsmHTTPResponse {
        DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
}
