import DsmCore
@testable import DsmMobile
import Foundation
import XCTest

private struct PhotoImportItemStub: MobilePhotosPickerItemServing {
    let selectionID = UUID().uuidString
    let result: Result<MobilePhotosPickerArtifact, Error>

    func loadArtifact() async throws -> MobilePhotosPickerArtifact {
        try result.get()
    }
}

private actor PhotoImportTransferServiceSpy: MobileTransferServing {
    private(set) var uploadCount = 0

    func upload(
        _ request: MobileUploadRequest,
        progress: @escaping FileTransferProgress
    ) async throws {
        uploadCount += 1
        progress(1, 1)
    }

    func reviewUpload(_ request: MobileUploadRequest) async throws -> MutationResult? { nil }
    func download(_ request: MobileDownloadRequest, progress: @escaping FileTransferProgress) async throws {}
    func removePartialDownload(_ request: MobileDownloadRequest) async {}
}

@MainActor
final class MobilePhotoImportModelTests: XCTestCase {
    func test普通照片文件进入既有Activity上传且只提交一次() async throws {
        let fixture = try makePhotoImportFixture()
        defer { fixture.cleanup() }
        let source = fixture.base.appendingPathComponent("photo.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data([1, 2, 3])))
        let service = PhotoImportTransferServiceSpy()
        var refreshed = false

        fixture.model.begin(
            item: PhotoImportItemStub(result: .success(.init(url: source))),
            destination: fixture.destination,
            repositoryProfileID: fixture.destination.profileID,
            repositoryIdentity: ObjectIdentifier(fixture.repositoryMarker),
            controller: fixture.controller,
            service: service,
            coordinator: fixture.coordinator,
            onConfirmedSuccess: { refreshed = true }
        )

        try await waitForPhotoImport {
            if case .queued = fixture.model.phase { return true }
            return false
        }
        let count = await service.uploadCount
        XCTAssertEqual(count, 1)
        let tasks = await fixture.coordinator.allTasks()
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.stableTarget, "/home/Photos/photo.jpg")
        try await waitForPhotoImport { refreshed }
    }

    func test选择器受控临时文件在进入Activity后立即清理() async throws {
        let fixture = try makePhotoImportFixture()
        defer { fixture.cleanup() }
        let pickerDirectory = fixture.base.appendingPathComponent("picker-owned")
        try FileManager.default.createDirectory(at: pickerDirectory, withIntermediateDirectories: true)
        let source = pickerDirectory.appendingPathComponent("photo.jpg")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: Data([1, 2, 3])))
        let service = PhotoImportTransferServiceSpy()

        fixture.model.begin(
            item: PhotoImportItemStub(result: .success(.init(
                url: source,
                ownedDirectory: pickerDirectory
            ))),
            destination: fixture.destination,
            repositoryProfileID: fixture.destination.profileID,
            repositoryIdentity: ObjectIdentifier(fixture.repositoryMarker),
            controller: fixture.controller,
            service: service,
            coordinator: fixture.coordinator,
            onConfirmedSuccess: {}
        )

        try await waitForPhotoImport {
            if case .queued = fixture.model.phase { return true }
            return false
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pickerDirectory.path))
        let uploadCount = await service.uploadCount
        XCTAssertEqual(uploadCount, 1)
    }

    func test系统选择项不可读取时显示通俗失败且零上传() async throws {
        let fixture = try makePhotoImportFixture()
        defer { fixture.cleanup() }
        let service = PhotoImportTransferServiceSpy()

        fixture.model.begin(
            item: PhotoImportItemStub(result: .failure(MobilePhotosPickerFailure.itemUnavailable)),
            destination: fixture.destination,
            repositoryProfileID: fixture.destination.profileID,
            repositoryIdentity: ObjectIdentifier(fixture.repositoryMarker),
            controller: fixture.controller,
            service: service,
            coordinator: fixture.coordinator,
            onConfirmedSuccess: {}
        )

        try await waitForPhotoImport { fixture.model.phase == .failed(.itemUnavailable) }
        let count = await service.uploadCount
        XCTAssertEqual(count, 0)
    }

    func test跨空间越界与回收站目标在选择前拒绝() throws {
        let profileID = UUID()
        XCTAssertFalse(MobilePhotoImportModel.isAllowed(.init(
            profileID: profileID,
            folderPath: "/photo/other",
            spaceRootPath: "/home/Photos"
        )))
        XCTAssertFalse(MobilePhotoImportModel.isAllowed(.init(
            profileID: profileID,
            folderPath: "/home/Photos/#recycle/item",
            spaceRootPath: "/home/Photos"
        )))
        XCTAssertTrue(MobilePhotoImportModel.isAllowed(.init(
            profileID: profileID,
            folderPath: "/home/Photos/Trips",
            spaceRootPath: "/home/Photos"
        )))
    }

    func test同Profile更换Repository会取消准备并拒绝旧结果() async throws {
        let fixture = try makePhotoImportFixture()
        defer { fixture.cleanup() }
        let source = fixture.base.appendingPathComponent("slow.jpg")
        _ = FileManager.default.createFile(atPath: source.path, contents: Data([1]))
        let delayed = DelayedPhotoImportItem(url: source)
        let service = PhotoImportTransferServiceSpy()

        fixture.model.begin(
            item: delayed,
            destination: fixture.destination,
            repositoryProfileID: fixture.destination.profileID,
            repositoryIdentity: ObjectIdentifier(fixture.repositoryMarker),
            controller: fixture.controller,
            service: service,
            coordinator: fixture.coordinator,
            onConfirmedSuccess: {}
        )
        fixture.model.activate(
            profileID: fixture.destination.profileID,
            repositoryIdentity: ObjectIdentifier(NSObject())
        )
        await delayed.resume()
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(fixture.model.phase, .idle)
        let count = await service.uploadCount
        XCTAssertEqual(count, 0)
    }
}

private actor DelayedPhotoImportItem: MobilePhotosPickerItemServing {
    let selectionID = UUID().uuidString
    let url: URL
    private var continuation: CheckedContinuation<Void, Never>?

    init(url: URL) { self.url = url }

    func loadArtifact() async throws -> MobilePhotosPickerArtifact {
        await withCheckedContinuation { continuation = $0 }
        try Task.checkCancellation()
        return MobilePhotosPickerArtifact(url: url)
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct PhotoImportFixture {
    let base: URL
    let root: URL
    let model: MobilePhotoImportModel
    let coordinator: MobileTransferCoordinator
    let controller: MobileDocumentTransferController
    let repositoryMarker: NSObject
    let destination: MobilePhotoImportDestination

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

@MainActor
private func makePhotoImportFixture() throws -> PhotoImportFixture {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("artifacts")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let coordinator = MobileTransferCoordinator()
    let controller = MobileDocumentTransferController(
        transferCoordinator: coordinator,
        rootURL: root
    )
    let profileID = UUID()
    let repositoryMarker = NSObject()
    let model = MobilePhotoImportModel()
    model.activate(profileID: profileID, repositoryIdentity: ObjectIdentifier(repositoryMarker))
    controller.setActiveProfile(profileID)
    return PhotoImportFixture(
        base: base,
        root: root,
        model: model,
        coordinator: coordinator,
        controller: controller,
        repositoryMarker: repositoryMarker,
        destination: MobilePhotoImportDestination(
            profileID: profileID,
            folderPath: "/home/Photos",
            spaceRootPath: "/home/Photos"
        )
    )
}

@MainActor
private func waitForPhotoImport(
    _ condition: @escaping @MainActor () async -> Bool
) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("等待照片导入状态超时")
}
