import Foundation
import XCTest
@testable import DsmNetwork

final class DownloadedFileExporterTests: XCTestCase {
    func test完整副本经系统替换目录保存且源文件保留() async throws {
        let root = try directory()
        let source = root.appendingPathComponent("source")
        let targetDirectory = try directory()
        let target = targetDirectory.appendingPathComponent("saved")
        let contents = Data("complete".utf8)
        try contents.write(to: source)
        try await DownloadedFileExporter.export(from: source, to: target, replaceExisting: false)
        XCTAssertEqual(try Data(contentsOf: target), contents)
        XCTAssertEqual(try Data(contentsOf: source), contents)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: targetDirectory.path), ["saved"])
    }

    func test未授权替换保留已有文件而明确授权可替换() async throws {
        let root = try directory(), source = root.appendingPathComponent("source"), target = root.appendingPathComponent("saved")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: target)
        do { try await DownloadedFileExporter.export(from: source, to: target, replaceExisting: false); XCTFail("未确认不能覆盖") }
        catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteFileExists) }
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
        try await DownloadedFileExporter.export(from: source, to: target, replaceExisting: true)
        XCTAssertEqual(try Data(contentsOf: target), Data("new".utf8))
    }

    func test源文件缺失不会破坏已有目标() async throws {
        let root = try directory(), target = root.appendingPathComponent("saved")
        try Data("old".utf8).write(to: target)
        do { try await DownloadedFileExporter.export(from: root.appendingPathComponent("missing"), to: target, replaceExisting: true); XCTFail("源文件缺失不能保存") }
        catch { }
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
    }

    func test分片位于应用临时区且同名不同目标隔离() throws {
        let root = try directory()
        let first = DsmFileRepository.partialDownloadArtifactURL(localURL: root.appendingPathComponent("a/file.bin"), identitySuffix: "0123456789abcdef")
        let second = DsmFileRepository.partialDownloadArtifactURL(localURL: root.appendingPathComponent("b/file.bin"), identitySuffix: "0123456789abcdef")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL)
        XCTAssertFalse(first.path.hasPrefix(root.path))
    }

    func test已取消导出不创建目标或触碰源文件() async throws {
        let root = try directory(), source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
        let contents = Data("complete".utf8)
        try contents.write(to: source)
        let operation = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            try await DownloadedFileExporter.export(from: source, to: target, replaceExisting: false)
        }
        do { try await operation.value; XCTFail("取消后不得导出") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: source), contents)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
