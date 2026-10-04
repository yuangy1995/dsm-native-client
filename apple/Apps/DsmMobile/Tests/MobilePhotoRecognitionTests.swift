@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@MainActor
final class MobilePhotoRecognitionTests: XCTestCase {
    private func fixture(_ state: String = "photo-recognition") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-recognition-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待人物或人脸操作超时")
    }
    private func category(_ category: SynologyPhotoCategory, in session: MobileSynologyPhotosSession, open: Bool = true) async throws -> SynologyPhotoCollection {
        await session.model.selectSection(.albums); await session.model.openCategory(category)
        let collection = try XCTUnwrap(session.model.collections.first)
        if open { await session.model.open(collection) }
        return collection
    }
    private func begin(_ action: MobilePhotoRecognitionModel.Action, in session: MobileSynologyPhotosSession, collection: SynologyPhotoCollection? = nil, photos: [SynologyPhoto]? = nil) async throws -> MobilePhotoRecognitionModel {
        let value = try XCTUnwrap(session.recognition); value.begin(action, collection: collection, photos: photos)
        try await wait { !value.isLoading }; return value
    }
    private func faceEditor(in session: MobileSynologyPhotosSession) async throws -> MobilePhotoFaceModel {
        let photo = try XCTUnwrap(session.model.items.first); session.model.showPreview(photo)
        try await wait { !session.model.isPreparingPreview && session.model.previewData != nil }
        let editor = try XCTUnwrap(session.faces); editor.begin(); try await wait { !editor.isLoading }; return editor
    }

    func test人物列表改名裁剪空白与重复保存只提交一次() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let person = try await category(.person, in: session, open: false)
        let value = try await begin(.rename, in: session, collection: person); XCTAssertNil(value.mutation)
        value.text = "  Revised name  "; XCTAssertTrue(value.save()); XCTAssertFalse(value.save()); try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .renamePerson(let original, let name) = commands.first else { return XCTFail("应保存人物名称") }
        XCTAssertEqual(original, person); XCTAssertEqual(name, "Revised name")
        XCTAssertEqual(session.model.collections.first(where: { $0.id == person.id })?.name, name)
    }

    func test人物合并排除自身并冻结确认内容() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let person = try await category(.person, in: session, open: false), value = try await begin(.merge, in: session, collection: person)
        XCTAssertFalse(value.people.contains { $0.id == person.id }); XCTAssertTrue(value.people.contains { $0.id == 79 })
        value.selected = [78]; XCTAssertFalse(value.save()); XCTAssertTrue(value.showsConfirmation)
        value.cancelConfirmation(); var commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(value.save()); value.text = "Changed after confirmation"; XCTAssertFalse(value.confirmSave())
        XCTAssertFalse(value.save()); XCTAssertTrue(value.confirmSave()); XCTAssertFalse(value.confirmSave()); try await wait { !session.model.isManaging }
        commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .mergePeople(let target, let sources, let name) = commands.first else { return XCTFail("应合并已选人物") }
        XCTAssertEqual(target.id, 77); XCTAssertEqual(sources.map(\.id), [78]); XCTAssertEqual(name, "Changed after confirmation")
    }

    func test人物主题显示隐藏只提交有变化项并支持搜索() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for action in [MobilePhotoRecognitionModel.Action.peopleVisibility, .conceptVisibility] {
            let value = try await begin(action, in: session)
            XCTAssertTrue(value.visibilityEntries.contains { !$0.visible })
            value.search = "does not exist"; XCTAssertTrue(value.filteredVisibility.isEmpty); value.search = "hidden"; XCTAssertEqual(value.filteredVisibility.count, 1)
            value.search = ""; value.selected = Set(value.visibilityEntries.map(\.id)); value.visible = false
            XCTAssertTrue(value.save()); try await wait { !session.model.isManaging }
        }
        let commands = await service.commands; XCTAssertEqual(commands.count, 2)
        guard case .setPeopleVisibility(let people, false) = commands[0], case .setConceptVisibility(let concepts, false) = commands[1] else { return XCTFail("应只保存可见项的隐藏变化") }
        XCTAssertEqual(Set(people.map(\.id)), [77, 78]); XCTAssertEqual(concepts.map(\.id), [31])
    }

    func test人物归属使用人脸编号并保留照片与其他人脸() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await category(.person, in: session); let photo = try XCTUnwrap(session.model.items.first)
        let value = try await begin(.reassignFaces, in: session, photos: [photo])
        XCTAssertEqual(value.selected, [photo.id.unitID * 100 + 1]); XCTAssertFalse(value.people.contains { $0.id == 77 })
        value.targetPersonID = 77; XCTAssertNil(value.mutation); value.targetPersonID = 78
        XCTAssertTrue(value.save()); try await wait { !session.model.isManaging }
        let commands = await service.commands
        guard case .reassignPersonFaces(let person, let faces, let target, let name) = commands.first else { return XCTFail("应修改所选人脸的归属") }
        XCTAssertEqual(person.id, 77); XCTAssertEqual(faces.map(\.id), [photo.id.unitID * 100 + 1]); XCTAssertEqual(target?.id, 78); XCTAssertEqual(name, "Another person")
        let regions = try await service.photoFaces(for: photo); XCTAssertEqual(regions.count, 2); XCTAssertTrue(regions.allSatisfy { $0.personID == 78 })
    }

    func test人物移除确认不删除原图以及封面仅允许单张() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await category(.person, in: session); let photos = session.model.items, photo = try XCTUnwrap(photos.first)
        let value = try XCTUnwrap(session.recognition); XCTAssertFalse(value.allows(.personCover, photos: photos)); XCTAssertTrue(value.allows(.personCover, photos: [photo]))
        _ = try await begin(.removeFaces, in: session, photos: [photo]); XCTAssertFalse(value.save()); value.cancelConfirmation()
        var commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(value.save()); XCTAssertTrue(value.confirmSave()); try await wait { !session.model.isManaging }
        let remaining = try await service.photoFaces(for: photo); XCTAssertEqual(remaining.count, 1); XCTAssertEqual(remaining.first?.personID, 78)
        commands = await service.commands; guard case .removePersonFaces(_, let faces) = commands.first else { return XCTFail("应仅移除人物关联") }
        XCTAssertEqual(faces.count, 1)
    }

    func test主题封面移出阈值与跨来源失效() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        _ = try await category(.concept, in: session); let photo = try XCTUnwrap(session.model.items.first)
        let value = try await begin(.conceptCover, in: session, photos: [photo]); XCTAssertNotNil(value.mutation)
        XCTAssertTrue(value.save()); try await wait { !session.model.isManaging }
        _ = try await begin(.removeConceptItems, in: session, photos: [photo]); XCTAssertTrue(value.belowConceptThreshold)
        XCTAssertFalse(value.save()); XCTAssertTrue(value.confirmSave()); try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.count, 2)
        guard case .removeConceptItems(let original, let photos) = commands[1] else { return XCTFail("应从主题移出选片") }
        XCTAssertEqual(original.displayThreshold, 2); XCTAssertEqual(photos.map(\.id), [photo.id])
        _ = try await begin(.peopleVisibility, in: session); value.selected = [77]; value.visible = false
        await session.model.selectSpace(.shared); XCTAssertFalse(value.editable); XCTAssertNil(value.mutation)
    }

    func test人物主题空内容错误和只读禁止写入() async throws {
        for state in ["photo-recognition-empty", "photo-recognition-error", "photo-recognition-readonly"] {
            let (root, _, service, session) = try await fixture(state); defer { try? FileManager.default.removeItem(at: root) }
            let value = try await begin(.peopleVisibility, in: session)
            if state.hasSuffix("empty") { XCTAssertTrue(value.visibilityEntries.isEmpty); XCTAssertNil(value.error) }
            else if state.hasSuffix("error") { XCTAssertNotNil(value.error) }
            else { XCTAssertNil(value.draft) }
            XCTAssertFalse(value.save()); let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        }
    }

    func test人物迟到读取不回填新账号() async throws {
        let (root, _, service, session) = try await fixture("photo-recognition-held"); defer { try? FileManager.default.removeItem(at: root) }
        let value = try XCTUnwrap(session.recognition); value.begin(.peopleVisibility)
        for _ in 0..<100 { if await service.isRecognitionHeld { break }; await Task.yield() }
        let held = await service.isRecognitionHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-recognition")); await service.releaseRecognition(); await session.activate()
        for _ in 0..<10 { await Task.yield() }; XCTAssertNil(value.draft); XCTAssertTrue(value.visibilityEntries.isEmpty)
    }

    func test人物未知保存重启只查询以及部分完成重新编辑() async throws {
        for state in ["photo-recognition-unknown", "photo-recognition-partial"] {
            let (root, storage, service, session) = try await fixture(state); defer { try? FileManager.default.removeItem(at: root) }
            let value = try await begin(.peopleVisibility, in: session); value.visible = false; value.selected = [77, 78]
            XCTAssertTrue(value.save()); try await wait { !session.model.isManaging }
            if state.hasSuffix("unknown") {
                XCTAssertNotNil(session.model.pendingMutationID)
                session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
                XCTAssertNotNil(session.model.pendingMutationID); let reopened = try await begin(.peopleVisibility, in: session); XCTAssertFalse(reopened.editable)
                await service.setPending(false); session.model.reviewPendingMutation(); try await wait { !session.model.isManaging }; XCTAssertNil(session.model.pendingMutationID)
            } else {
                let reopened = try await begin(.peopleVisibility, in: session)
                XCTAssertEqual(reopened.peopleVisibility.filter(\.isVisible).map(\.id), [78]); XCTAssertNil(session.model.pendingMutationID)
            }
            let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        }
    }

    func test人脸新框命名裁剪尺寸及隐藏人物选择() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await faceEditor(in: session); XCTAssertEqual(editor.faces.count, 2); XCTAssertTrue(editor.people.contains { $0.id == 79 })
        editor.addCentered(); XCTAssertFalse(editor.canSave); editor.setName("  New person  "); XCTAssertTrue(editor.canSave)
        let image = try XCTUnwrap(editor.image), face = try XCTUnwrap(editor.selected)
        XCTAssertEqual(face.bounds.width * Double(image.width), face.bounds.height * Double(image.height), accuracy: 0.001)
        XCTAssertTrue(editor.save()); XCTAssertFalse(editor.save()); try await wait { !session.model.isManaging }
        let commands = await service.commands
        guard case .editPhotoFaces(_, let changes) = commands.first, case .add(let addition) = changes.first else { return XCTFail("应新增带裁剪图片的人脸") }
        XCTAssertEqual(changes.count, 1); XCTAssertEqual(addition.name, "New person")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(addition.jpeg as CFData, nil)), crop = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(max(crop.width, crop.height), 256); XCTAssertEqual(crop.width, crop.height)
    }

    func test人脸调整框生成新旧标注并支持撤销移除() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await faceEditor(in: session), original = try XCTUnwrap(editor.selected)
        editor.removeSelected(); XCTAssertEqual(editor.pendingChangeCount, 1); editor.undoRemove(); XCTAssertFalse(editor.canSave)
        var bounds = original.bounds; bounds.x += 0.02; editor.setBounds(bounds, for: original.id); XCTAssertEqual(editor.pendingChangeCount, 2)
        XCTAssertTrue(editor.save()); try await wait { !session.model.isManaging }
        let commands = await service.commands
        guard case .editPhotoFaces(_, let changes) = commands.first else { return XCTFail("应保存框选变化") }
        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(changes.contains { if case .remove(let region) = $0 { return region.id == original.original?.id }; return false })
        XCTAssertTrue(changes.contains { if case .add(let addition) = $0 { return addition.bounds == bounds }; return false })
    }

    func test人脸归属改动不重建框新增后取消不发送() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await faceEditor(in: session); editor.setPerson(79); XCTAssertEqual(editor.pendingChangeCount, 1)
        XCTAssertTrue(editor.save()); try await wait { !session.model.isManaging }
        let commands = await service.commands
        guard case .editPhotoFaces(_, let changes) = commands.first, case .reassign(_, let person, _) = changes.first else { return XCTFail("应只修改人物归属") }
        XCTAssertEqual(person?.id, 79); XCTAssertEqual(changes.count, 1)
        _ = try await faceEditor(in: session); let count = editor.faces.count; editor.addCentered(); editor.removeSelected(); XCTAssertEqual(editor.faces.count, count)
        editor.addCentered(); editor.setName("Unsaved"); editor.cancel(); XCTAssertNil(editor.draft); XCTAssertFalse(editor.canSave)
        let after = await service.commands; XCTAssertEqual(after.count, 1)
    }

    func test人脸未知保存重启禁重发及空内容错误状态() async throws {
        let (root, storage, service, session) = try await fixture("photo-recognition-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await faceEditor(in: session); editor.addCentered(); editor.setName("Recovery name"); XCTAssertTrue(editor.save()); try await wait { !session.model.isManaging }
        XCTAssertNotNil(session.model.pendingMutationID); session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        XCTAssertNotNil(session.model.pendingMutationID); XCTAssertFalse(session.faces?.canBegin == true)
        await service.setPending(false); session.model.reviewPendingMutation(); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID); let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        for state in ["photo-recognition-empty", "photo-recognition-error"] {
            let (otherRoot, _, _, other) = try await fixture(state); defer { try? FileManager.default.removeItem(at: otherRoot) }
            let value = try await faceEditor(in: other)
            if state.hasSuffix("empty") { XCTAssertTrue(value.faces.isEmpty); XCTAssertNil(value.error); value.addCentered(); XCTAssertEqual(value.faces.count, 1) }
            else { XCTAssertNotNil(value.error); XCTAssertFalse(value.editable) }
        }
    }

    func test显示方向解码后像素正方形裁剪不随屏幕变形() async throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(MobilePhotosUIService.recognitionImage as CFData, nil))
        let original = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, original, [kCGImagePropertyOrientation: 6] as CFDictionary); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded = await MobileSynologyPhotoImage.decode(data as Data, maximumPixels: 4096), image = try XCTUnwrap(decoded?.cgImage)
        XCTAssertEqual(image.width, original.height); XCTAssertEqual(image.height, original.width)
        let size = CGSize(width: image.width, height: image.height)
        let bounds = try XCTUnwrap(PhotoFaceEditing.square(from: .init(x: 20, y: 40), to: .init(x: 130, y: 110), in: size))
        XCTAssertEqual(bounds.width * size.width, bounds.height * size.height, accuracy: 0.001)
        let jpeg = try PhotoFaceEditing.jpeg(image, bounds: bounds)
        let cropSource = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil)), crop = try XCTUnwrap(CGImageSourceCreateImageAtIndex(cropSource, 0, nil))
        XCTAssertEqual(crop.width, crop.height); XCTAssertLessThanOrEqual(crop.width, 256)
    }

    func test人脸迟到读取与预览换片使旧草稿失效() async throws {
        let (root, _, service, session) = try await fixture("photo-recognition-held"); defer { try? FileManager.default.removeItem(at: root) }
        let photo = try XCTUnwrap(session.model.items.first); session.model.showPreview(photo)
        try await wait { !session.model.isPreparingPreview && session.model.previewData != nil }
        let old = try XCTUnwrap(session.faces); old.begin()
        for _ in 0..<300 { if await service.isRecognitionHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        let held = await service.isRecognitionHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-recognition")); await service.releaseRecognition(); await session.activate()
        for _ in 0..<10 { await Task.yield() }; XCTAssertNil(old.draft); XCTAssertNil(old.image); XCTAssertTrue(old.faces.isEmpty)
        let editor = try await faceEditor(in: session); editor.addCentered(); editor.setName("Unsaved")
        let next = try XCTUnwrap(session.model.items.last); session.model.showPreview(next)
        XCTAssertFalse(editor.editable); XCTAssertFalse(editor.save())
    }
}
