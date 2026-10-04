import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatNotificationTests: XCTestCase {
    func test只有主动开启才申请系统权限并持久保存选择() async throws {
        let (model, driver, defaults) = fixture()
        model.configure(context: "synthetic-account-a")
        await model.refreshAuthorization()
        XCTAssertFalse(model.enabled); XCTAssertEqual(driver.requests, 0)
        await model.setEnabled(true)
        XCTAssertTrue(model.enabled); XCTAssertEqual(driver.requests, 1)
        XCTAssertTrue(defaults.bool(forKey: MobileChatNotifications.enabledKey))
        await model.setEnabled(false)
        XCTAssertFalse(model.enabled); XCTAssertEqual(driver.requests, 1)
    }

    func test权限拒绝与申请错误都有恢复信息且不写通知() async throws {
        let (model, driver, _) = fixture()
        driver.granted = false
        await model.setEnabled(true)
        XCTAssertFalse(model.enabled); XCTAssertEqual(model.errorKey, "mobile.chat.notification.denied")
        XCTAssertTrue(driver.values.isEmpty)
        driver.authorizationValue = .notDetermined; driver.requestFails = true
        await model.setEnabled(true)
        XCTAssertEqual(model.errorKey, "mobile.chat.notification.failed")
        XCTAssertFalse(model.enabled)
    }

    func test首次同步静默随后只通知他人新消息一次() async throws {
        let (model, driver, _) = fixture()
        let (repository, transport) = try repository()
        model.configure(context: "synthetic-account-a"); model.isForeground = true
        await model.setEnabled(true)
        await model.processIncoming(try await repository.listConversations(), repository: repository) { _ in false }
        XCTAssertTrue(driver.values.isEmpty)
        await transport.appendMessage()
        let newer = try await repository.listConversations()
        await model.processIncoming(newer, repository: repository) { _ in false }
        XCTAssertEqual(driver.values.count, 1)
        XCTAssertEqual(driver.values.values.first?.messageID, "61")
        XCTAssertNil(driver.values.values.first?.date)
        await model.processIncoming(newer, repository: repository) { _ in false }
        XCTAssertEqual(driver.adds.count, 1)
    }

    func test本人消息和正在阅读的会话不弹通知() async throws {
        let (model, driver, _) = fixture()
        let (repository, transport) = try repository()
        model.configure(context: "synthetic-account-a"); model.isForeground = true
        await model.setEnabled(true)
        await model.processIncoming(try await repository.listConversations(), repository: repository) { _ in false }
        await transport.appendMessage(isCurrentUser: true)
        await model.processIncoming(try await repository.listConversations(), repository: repository) { _ in false }
        await transport.appendMessage()
        await model.processIncoming(try await repository.listConversations(), repository: repository) { _ in true }
        XCTAssertTrue(driver.values.isEmpty)
    }

    func test关闭偏好或进入后台只更新基线不发送旧通知() async throws {
        let (model, driver, _) = fixture()
        let (repository, transport) = try repository()
        model.configure(context: "synthetic-account-a"); model.isForeground = true
        await model.processIncoming(try await repository.listConversations(), repository: repository) { _ in false }
        await transport.appendMessage()
        await model.processIncoming(try await repository.listConversations(), repository: repository) { _ in false }
        XCTAssertTrue(driver.values.isEmpty)
        await model.setEnabled(true); model.isForeground = false
        await model.processIncoming(try await repository.listConversations(), repository: repository) { _ in false }
        await transport.appendMessage()
        await model.processIncoming(try await repository.listConversations(), repository: repository) { _ in false }
        model.isForeground = true
        await model.processIncoming(try await repository.listConversations(), repository: repository) { _ in false }
        XCTAssertTrue(driver.values.isEmpty)
    }

    func test通知添加期间切换账号会清除迟到旧通知() async throws {
        let (model, driver, _) = fixture()
        let (repository, transport) = try repository()
        model.configure(context: "synthetic-account-a"); model.isForeground = true
        await model.setEnabled(true)
        await model.processIncoming(try await repository.listConversations(), repository: repository) { _ in false }
        await transport.appendMessage(); driver.blocksAdd = true
        let work = Task { await model.processIncoming(try! await repository.listConversations(), repository: repository) { _ in false } }
        await eventually { driver.addContinuation != nil }
        model.configure(context: "synthetic-account-b")
        driver.releaseAdd(); await work.value
        XCTAssertTrue(driver.values.isEmpty)
    }

    func test提醒保存改期与取消使用相同身份且后台保留系统请求() async throws {
        let (model, driver, _) = fixture()
        model.configure(context: "synthetic-account-a"); await model.setEnabled(true)
        let initial = ChatReminder(id: "reminder", messageID: "60", remindAt: Date().addingTimeInterval(300))
        await model.updateReminders([initial], conversationID: "27")
        let id = try XCTUnwrap(driver.values.keys.first)
        XCTAssertEqual(driver.values[id]?.date, initial.remindAt)
        await model.updateReminders([initial], conversationID: "27")
        XCTAssertEqual(driver.adds.count, 1)
        let changed = ChatReminder(id: initial.id, messageID: initial.messageID, remindAt: initial.remindAt.addingTimeInterval(60))
        await model.updateReminders([changed], conversationID: "27")
        XCTAssertEqual(driver.values.count, 1); XCTAssertEqual(driver.values[id]?.date, changed.remindAt)
        model.isForeground = false
        XCTAssertEqual(driver.values.count, 1)
        await model.updateReminders([], conversationID: "27")
        XCTAssertTrue(driver.values.isEmpty)
    }

    func test从真实适配器读取提醒并删除上次运行留下的过期请求() async throws {
        let (model, driver, _) = fixture()
        let (repository, transport) = try repository()
        model.configure(context: "synthetic-account-a"); model.isForeground = true; await model.setEnabled(true)
        let time = Int(Date().addingTimeInterval(900).timeIntervalSince1970 * 1_000)
        await transport.setReminders([60: time])
        await model.refreshReminders(conversations: try await repository.listConversations(), repository: repository)
        XCTAssertEqual(driver.values.count, 1)
        let scope = try XCTUnwrap(model.scope)
        let obsolete = MobileChatNotice(id: "mobile.chat.\(scope).reminder.27.old", scope: scope,
            conversationID: "27", messageID: "1", date: Date().addingTimeInterval(100))
        driver.values[obsolete.id] = obsolete
        await transport.setReminders([:])
        await model.refreshReminders(conversations: try await repository.listConversations(), repository: repository)
        XCTAssertTrue(driver.values.isEmpty)
    }

    func test提醒写入失败显示限制且重新同步可恢复() async throws {
        let (model, driver, _) = fixture()
        model.configure(context: "synthetic-account-a"); await model.setEnabled(true)
        driver.addFails = true
        let value = ChatReminder(id: "r", messageID: "60", remindAt: Date().addingTimeInterval(300))
        await model.updateReminders([value], conversationID: "27")
        XCTAssertEqual(model.errorKey, "mobile.chat.notification.sync-failed"); XCTAssertTrue(driver.values.isEmpty)
        driver.addFails = false
        await model.updateReminders([value], conversationID: "27")
        XCTAssertEqual(driver.values.count, 1)
    }

    func test临近提醒优先且超过本机容量显示明确限制() async throws {
        let (model, driver, _) = fixture()
        model.configure(context: "synthetic-account-a"); await model.setEnabled(true)
        let now = Date()
        let values = (1...55).map { ChatReminder(id: String($0), messageID: String($0), remindAt: now.addingTimeInterval(Double($0 * 60))) }
        await model.updateReminders(values.reversed(), conversationID: "27")
        XCTAssertEqual(driver.values.count, 50); XCTAssertEqual(model.errorKey, "mobile.chat.notification.limit")
        XCTAssertFalse(driver.values.values.contains { $0.messageID == "55" })
        XCTAssertTrue(driver.values.values.contains { $0.messageID == "1" })
    }

    func test权限撤销或退出会移除通知且旧通知点击不能进入新账号() async throws {
        let (model, driver, _) = fixture()
        model.configure(context: "synthetic-account-a"); await model.setEnabled(true)
        let old = try XCTUnwrap(model.scope)
        await model.updateReminders([.init(id: "r", messageID: "60", remindAt: Date().addingTimeInterval(300))], conversationID: "27")
        driver.authorizationValue = .denied
        await model.refreshAuthorization()
        await eventually { driver.values.isEmpty }
        model.configure(context: "synthetic-account-b")
        driver.onOpen?(old, "27", "60")
        XCTAssertNil(model.destination)
        XCTAssertFalse(driver.shouldPresent?(old) ?? true)
        model.configure(context: nil)
        await eventually { driver.values.isEmpty }
    }

    func test重启前的通知只有登录同一账号后恢复定位且不保存正文() async throws {
        let (model, driver, defaults) = fixture()
        model.configure(context: "synthetic-account-a"); await model.setEnabled(true)
        let scope = try XCTUnwrap(model.scope)
        let restoredDriver = NotificationDriverStub()
        let restored = MobileChatNotifications(defaults: defaults, driver: restoredDriver)
        restoredDriver.onOpen?(scope, "27", "60")
        XCTAssertNil(restored.destination)
        restored.configure(context: "synthetic-account-a")
        XCTAssertEqual(restored.scope, scope); XCTAssertEqual(restored.destination?.messageID, "60")
        let stored = try XCTUnwrap(defaults.dictionary(forKey: MobileChatNotifications.scopesKey) as? [String: String])
        XCTAssertEqual(stored, ["synthetic-account-a": scope])
        XCTAssertEqual(driver.requests, 1); XCTAssertEqual(restoredDriver.requests, 0)
    }

    func test提醒变更发生在旧添加期间会串行替换而不留下旧时间() async throws {
        let (model, driver, _) = fixture()
        model.configure(context: "synthetic-account-a"); await model.setEnabled(true)
        let now = Date(); driver.blocksAdd = true
        let first = Task { await model.updateReminders([.init(id: "r", messageID: "60", remindAt: now.addingTimeInterval(100))], conversationID: "27") }
        await eventually { driver.addContinuation != nil }
        let newer = Task { await model.updateReminders([.init(id: "r", messageID: "60", remindAt: now.addingTimeInterval(500))], conversationID: "27") }
        await Task.yield(); driver.releaseAdd()
        await first.value; await newer.value
        XCTAssertEqual(driver.values.count, 1)
        XCTAssertEqual(driver.values.values.first?.date, now.addingTimeInterval(500))
    }

    private func fixture() -> (MobileChatNotifications, NotificationDriverStub, UserDefaults) {
        let suite = "MobileChatNotificationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let driver = NotificationDriverStub()
        return (MobileChatNotifications(defaults: defaults, driver: driver), driver, defaults)
    }
    private func repository() throws -> (DsmChatRepository, MobileChatRealtimeUITransport) {
        let profile = try NasProfile(displayName: "Synthetic", host: "fixture.invalid", port: 5001, usernameHint: "fixture")
        let transport = MobileChatRealtimeUITransport()
        let versions = [DsmAPIName.chatChannel: 2, DsmAPIName.chatUser: 1, DsmAPIName.chatPost: 8, DsmAPIName.chatPostReminder: 1]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { key, value in
            (key, ApiCapability(name: key, path: "entry.cgi", minVersion: 1, maxVersion: value, requestFormat: .form, selectedVersion: value, verified: false))
        }))
        return (try DsmChatRepository(profile: profile, capabilities: capabilities,
            session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport), transport)
    }
    private func eventually(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
        XCTFail("未出现预期状态", file: file, line: line)
    }
}

@MainActor
private final class NotificationDriverStub: MobileChatNotificationDriving {
    var onOpen: ((String, String, String) -> Void)?
    var shouldPresent: ((String) -> Bool)?
    var authorizationValue: MobileChatNotificationAuthorization = .notDetermined
    var granted = true
    var requests = 0
    var requestFails = false
    var addFails = false
    var blocksAdd = false
    var addContinuation: CheckedContinuation<Void, Never>?
    var values: [String: MobileChatNotice] = [:]
    var adds: [MobileChatNotice] = []
    func authorization() async -> MobileChatNotificationAuthorization { authorizationValue }
    func requestAuthorization() async throws -> Bool {
        requests += 1
        if requestFails { throw URLError(.unknown) }
        authorizationValue = granted ? .allowed : .denied; return granted
    }
    func add(_ notice: MobileChatNotice) async throws {
        adds.append(notice)
        if blocksAdd { await withCheckedContinuation { addContinuation = $0 } }
        if addFails { throw URLError(.unknown) }
        values[notice.id] = notice
    }
    func releaseAdd() { blocksAdd = false; addContinuation?.resume(); addContinuation = nil }
    func remove(ids: [String]) async { for id in ids { values[id] = nil } }
    func removeAll(exceptScope: String?) async { values = values.filter { $0.value.scope == exceptScope } }
    func removeReminders(scope: String, keepingIDs: Set<String>) async {
        values = values.filter { !($0.value.scope == scope && $0.value.date != nil && !keepingIDs.contains($0.key)) }
    }
}
