@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoConditionTests: XCTestCase {
    private func fixture(_ state: String = "photo-condition") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-condition-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("条件相册操作未结束")
    }
    private func open(_ session: MobileSynologyPhotosSession, editing: Bool = false) async throws -> MobilePhotoConditionModel {
        let editor = try XCTUnwrap(session.conditions)
        if editing {
            await session.model.selectSection(.albums)
            await session.model.open(try XCTUnwrap(session.model.collections.first))
        }
        editor.begin(editing: editing); try await wait { !editor.isLoading }; return editor
    }
    private func store(_ storage: MobilePhotoUploadStorage) -> PhotoAlbumRecoveryStore {
        .init(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json"))
    }
    func test新建规则预览只创建一次且删除恢复记录() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await open(session); XCTAssertNil(editor.mutation)
        editor.name = "  Trip  "; editor.search = "holiday"; editor.addKeyword()
        editor.add(.init(name: "Three", value: .integer(3)), key: "rating")
        editor.preview(); try await wait { !editor.isCounting }; XCTAssertEqual(editor.count, 3)
        XCTAssertTrue(editor.submit()); XCTAssertFalse(editor.submit()); try await wait { !session.model.isManaging }
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .createConditionAlbum(let name, let condition) = commands[0] else { return XCTFail("应创建条件相册") }
        XCTAssertEqual(name, "Trip"); XCTAssertEqual(condition.values("keyword"), [.string("holiday")]); XCTAssertEqual(condition.fields["keyword_policy"], .string("or"))
        XCTAssertNil(try store(storage).load()); XCTAssertNil(editor.draft); XCTAssertEqual(editor.condition, .init())
    }
    func test编辑保留未知规则缺名引用与媒体且变更后清空计数() async throws {
        let (root, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await open(session, editing: true), original = try XCTUnwrap(editor.original)
        XCTAssertNil(editor.mutation); XCTAssertEqual(editor.condition.values("item_type"), [.integer(-3)])
        editor.preview(); try await wait { !editor.isCounting }; XCTAssertEqual(editor.count, 3)
        editor.search = "Another"; editor.addKeyword(); XCTAssertNil(editor.count)
        XCTAssertEqual(editor.condition.values("person"), [.integer(77)])
        XCTAssertEqual(editor.condition.fields["future_empty"], .array([])); XCTAssertEqual(editor.condition.fields["future_order"], .array([.integer(2), .integer(1)]))
        XCTAssertEqual(editor.condition.fields["keyword_policy"], .string("and"))
        XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        let commands = await service.commands
        guard case .setAlbumCondition(let id, let before, let after) = try XCTUnwrap(commands.first) else { return XCTFail("应更新原相册条件") }
        XCTAssertEqual(id, 21); XCTAssertEqual(before, original); XCTAssertEqual(after.values("keyword"), [.string("Original keyword"), .string("Another")])
    }
    func test来源草稿隔离目录完整分页并去重规则() async throws {
        let (root, _, _, session) = try await fixture("photo-condition-paged")
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await open(session); editor.name = "Rules"; editor.search = "Personal"; editor.addKeyword()
        editor.switchSource(.shared); XCTAssertTrue(editor.condition.values("keyword").isEmpty)
        editor.loadFolders(); try await wait { !editor.loadingFolders }; XCTAssertEqual(editor.folders.count, 101)
        editor.loadFolders(path: editor.folderPath + [try XCTUnwrap(editor.folders.last)]); try await wait { !editor.loadingFolders }
        XCTAssertTrue(editor.chooseFolder()); XCTAssertTrue(editor.chooseFolder()); XCTAssertEqual(editor.condition.values("folder_filter"), [.integer(102)])
        editor.switchSource(.personal); XCTAssertEqual(editor.condition.values("keyword"), [.string("Personal")]); XCTAssertTrue(editor.folderPath.isEmpty)
        editor.switchSource(.shared); XCTAssertEqual(editor.condition.values("folder_filter"), [.integer(102)]); XCTAssertEqual(editor.condition.sourceSpace, .shared)
        editor.remove(.integer(102), key: "folder_filter"); XCTAssertNil(editor.condition.fields["folder_filter"])
    }
    func test建议搜索空结果失败与移除末项策略清除() async throws {
        for state in ["photo-condition", "photo-condition-suggest-error"] {
            let (root, _, _, session) = try await fixture(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let editor = try await open(session); editor.field = .person; editor.findSuggestions(); try await wait { !editor.isSearching }
            if state.hasSuffix("error") { XCTAssertNotNil(editor.suggestionError); XCTAssertTrue(editor.suggestions.isEmpty) }
            else {
                let choice = try XCTUnwrap(editor.suggestions["person"]?.first)
                editor.add(choice, key: "person"); editor.add(choice, key: "person")
                XCTAssertEqual(editor.condition.values("person"), [.integer(77)])
                editor.remove(choice.value, key: "person"); XCTAssertNil(editor.condition.fields["person_policy"])
                editor.search = "no-match"; editor.findSuggestions(); try await wait { !editor.isSearching }; XCTAssertTrue(editor.suggestions.isEmpty)
            }
        }
    }
    func test关键词相同回写保留建议而切换来源仍清空并取消读取() async throws {
        for state in ["photo-condition", "photo-condition-suggest-held"] {
            let (root, _, service, session) = try await fixture(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let editor = try await open(session); editor.findSuggestions()
            if state.hasSuffix("held") {
                for _ in 0..<300 { if await service.isConditionHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
                editor.search = ""
                XCTAssertTrue(editor.isSearching)
                await service.releaseCondition()
            }
            try await wait { !editor.isSearching }
            XCTAssertEqual(editor.suggestions["person"]?.first?.value, .integer(77))
            editor.search = ""
            XCTAssertEqual(editor.suggestions["person"]?.first?.value, .integer(77))
            editor.switchSource(.shared); XCTAssertTrue(editor.suggestions.isEmpty)
            editor.cancel(); XCTAssertFalse(editor.isSearching); XCTAssertTrue(editor.suggestions.isEmpty)
        }
    }

    func test日期修改保留精确秒数和额外字段且错误区间禁止提交() async throws {
        let (root, _, _, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await open(session); editor.name = "Dates"
        editor.condition.setValues([.object(["start_time": .integer(123), "end_time": .integer(124), "future": .boolean(true)])], for: "time")
        editor.updateDate(0, key: "end_time", date: Date(timeIntervalSince1970: 122))
        XCTAssertFalse(editor.datesValid); XCTAssertNil(editor.mutation)
        editor.updateDate(0, key: "end_time", date: Date(timeIntervalSince1970: 125))
        XCTAssertEqual(editor.dateObject(0)?["start_time"], .integer(123)); XCTAssertEqual(editor.dateObject(0)?["future"], .boolean(true))
        XCTAssertTrue(editor.datesValid); XCTAssertNotNil(editor.mutation)
        editor.updateDate(0, key: "start_time", date: nil); XCTAssertTrue(editor.datesValid)
    }
    func test读取取消与换账号不会采用旧规则() async throws {
        let (root, _, service, session) = try await fixture("photo-condition-held")
        defer { try? FileManager.default.removeItem(at: root) }
        await session.model.selectSection(.albums); await session.model.open(try XCTUnwrap(session.model.collections.first))
        let editor = try XCTUnwrap(session.conditions); editor.begin(editing: true)
        for _ in 0..<300 { if await service.isConditionHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
        let held = await service.isConditionHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-condition")); await session.activate(); await service.releaseCondition()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(editor.original); XCTAssertNil(editor.draft); XCTAssertFalse(editor.submit()); XCTAssertFalse(editor.isLoading)
    }
    func test来源或规则变化丢弃迟到建议与数量() async throws {
        for state in ["photo-condition-suggest-held", "photo-condition-count-held"] {
            let (root, _, service, session) = try await fixture(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let editor = try await open(session)
            if state.contains("suggest") { editor.findSuggestions() } else { editor.preview() }
            for _ in 0..<300 { if await service.isConditionHeld { break }; try await Task.sleep(for: .milliseconds(5)) }
            let held = await service.isConditionHeld; XCTAssertTrue(held)
            if state.contains("suggest") { editor.switchSource(.shared) }
            else { editor.condition.setValues([.integer(-2)], for: "item_type") }
            await service.releaseCondition(); try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(editor.suggestions.isEmpty); XCTAssertNil(editor.count); XCTAssertFalse(editor.isSearching); XCTAssertFalse(editor.isCounting)
        }
    }
    func test无权限普通相册与过期草稿不允许编辑() async throws {
        for state in ["photo-condition-readonly", "photo-condition-contributor", "photo-condition-shared-entry", "photo-condition-nohome", "photo-condition"] {
            let (root, _, _, session) = try await fixture(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let editor = try XCTUnwrap(session.conditions)
            if state.hasSuffix("readonly") { XCTAssertFalse(editor.canOpen()); editor.begin(); XCTAssertNil(editor.draft); continue }
            if state.hasSuffix("contributor") {
                await session.model.selectSection(.albums); await session.model.open(try XCTUnwrap(session.model.collections.first))
                XCTAssertFalse(editor.canOpen(editing: true)); continue
            }
            editor.begin(); editor.name = "Rules"
            if state.hasSuffix("nohome") { XCTAssertEqual(editor.condition.sourceSpace, .shared); XCTAssertNotNil(editor.mutation) }
            else if state.hasSuffix("shared-entry") { editor.switchSource(.shared); XCTAssertEqual(editor.condition.sourceSpace, .personal) }
            else { await session.model.selectSpace(.shared); XCTAssertNil(editor.mutation); XCTAssertFalse(editor.submit()) }
        }
        let (root, _, _, session) = try await fixture("photo-albums")
        defer { try? FileManager.default.removeItem(at: root) }
        await session.model.selectSection(.albums); await session.model.open(try XCTUnwrap(session.model.collections.first))
        XCTAssertFalse(try XCTUnwrap(session.conditions).canOpen(editing: true))
    }
    func test未知重启只读回读且不保存规则内容() async throws {
        let (root, storage, service, session) = try await fixture("photo-condition-unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await open(session); editor.name = "Private title"; editor.search = "Private keyword"; editor.addKeyword()
        let condition = editor.condition
        XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        let saved = try XCTUnwrap(store(storage).load()); XCTAssertEqual(saved.version, 5)
        let data = String(decoding: try Data(contentsOf: store(storage).url), as: UTF8.self)
        XCTAssertFalse(data.contains("Private title")); XCTAssertFalse(data.contains("Private keyword"))
        session.deactivate()
        let reader = MobilePhotosUIService(profileID: service.profileID, state: "photo-condition"), next = MobileSynologyPhotosSession()
        await reader.seedCondition(condition, id: try XCTUnwrap(saved.createdAlbumID), name: "Private title")
        next.configure(reader, uploadStorage: storage, reviewDelay: { _ in }); await next.activate()
        XCTAssertNotNil(next.model.pendingMutationID); XCTAssertFalse(try XCTUnwrap(next.conditions).canOpen())
        next.model.reviewPendingMutation(); try await wait { !next.model.isManaging }
        XCTAssertNil(next.model.pendingMutationID); XCTAssertNil(try store(storage).load())
        let commands = await reader.commands; XCTAssertTrue(commands.isEmpty)
    }
    func test读取目录与预览错误可恢复且不阻止独立规则() async throws {
        for state in ["photo-condition-error", "photo-condition-folders-error", "photo-condition-count-error"] {
            let (root, _, _, session) = try await fixture(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let editor = try await open(session, editing: state == "photo-condition-error")
            if state == "photo-condition-error" { XCTAssertNotNil(editor.error); XCTAssertNil(editor.mutation); editor.load(); try await wait { !editor.isLoading } }
            else {
                editor.name = "Rules"
                if state.contains("folders") { editor.loadFolders(); try await wait { !editor.loadingFolders }; XCTAssertNotNil(editor.folderError); XCTAssertFalse(editor.chooseFolder()) }
                else { editor.preview(); try await wait { !editor.isCounting }; XCTAssertNotNil(editor.countError) }
                XCTAssertNotNil(editor.mutation)
            }
            editor.cancel(); XCTAssertNil(editor.error); XCTAssertNil(editor.folderError); XCTAssertNil(editor.countError)
        }
    }
    func test原快照改变或写前保存失败不发送修改() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let editor = try await open(session, editing: true); editor.search = "Updated"; editor.addKeyword()
        await service.seedCondition(.init())
        XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        var commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        editor.begin(); editor.name = "New"
        let url = store(storage).url
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertTrue(editor.submit()); try await wait { !session.model.isManaging }
        commands = await service.commands; XCTAssertTrue(commands.isEmpty); XCTAssertNotNil(session.model.albumRecoveryError)
    }
}
