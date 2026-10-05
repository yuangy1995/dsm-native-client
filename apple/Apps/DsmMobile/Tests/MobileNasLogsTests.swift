import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileNasLogsTests: XCTestCase {
    func test完整日志分页与页大小切换保留正文() async throws {
        let (model, transport, _) = try makeModel()
        await model.loadIfNeeded(.logs)
        XCTAssertEqual(model.state.logs.value?.items.count, 50)
        XCTAssertEqual(model.state.logs.value?.total, 103)
        XCTAssertEqual(model.state.logs.value?.pageNumber, 1)
        XCTAssertTrue(model.state.logs.value?.items.first?.message.contains("Complete details") == true)
        XCTAssertEqual(model.state.logs.value?.items.first?.account, "Synthetic account")
        await model.loadLogPage(2)
        XCTAssertEqual(model.state.logs.value?.offset, 50)
        XCTAssertTrue(model.state.logs.value?.items.first?.message.hasPrefix("Synthetic log 51\n") == true)
        await model.loadLogPage(3)
        XCTAssertEqual(model.state.logs.value?.items.count, 3)
        XCTAssertEqual(model.state.logs.value?.hasNext, false)
        await model.loadLogPage(1, pageSize: 200)
        XCTAssertEqual(model.state.logs.value?.items.count, 103)
        XCTAssertEqual(model.state.logs.value?.limit, 200)
        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.fields["offset"] }, ["0", "50", "100", "0"])
        XCTAssertTrue(requests.allSatisfy { $0.method == "list" && $0.api == DsmAPIName.coreSystemLog })
    }

    func test未知总数可继续整页且尾页停止() async throws {
        let (model, _, _) = try makeModel(mode: "nas-logs-unknown-total")
        await model.refresh(.logs)
        XCTAssertNil(model.state.logs.value?.total)
        XCTAssertEqual(model.state.logs.value?.hasNext, true)
        await model.loadLogPage(3)
        XCTAssertNil(model.state.logs.value?.total)
        XCTAssertEqual(model.state.logs.value?.items.count, 3)
        XCTAssertEqual(model.state.logs.value?.hasNext, false)
    }

    func test错误与畸形日志不冒充空内容且重试恢复() async throws {
        for mode in ["nas-logs-error", "nas-logs-malformed"] {
            let (model, transport, _) = try makeModel(mode: mode)
            await model.refresh(.logs)
            XCTAssertEqual(model.state.logs.phase, .error)
            XCTAssertNil(model.state.logs.value)
            await transport.setMode("nas-logs-empty"); await model.refresh(.logs)
            XCTAssertEqual(model.state.logs.phase, .empty)
            XCTAssertEqual(model.state.logs.value?.hasNext, false)
        }
    }

    func test翻页失败保留原页且不谎报新页码() async throws {
        let (model, transport, _) = try makeModel()
        await model.refresh(.logs)
        let before = model.state.logs.value
        await transport.setMode("nas-logs-error")
        await model.loadLogPage(2)
        XCTAssertEqual(model.state.logs.value, before)
        XCTAssertEqual(model.state.logs.value?.pageNumber, 1)
        XCTAssertTrue(model.state.logs.hasRefreshError)
        await transport.setMode("nas-logs"); await model.loadLogPage(2)
        XCTAssertEqual(model.state.logs.value?.pageNumber, 2)
        XCTAssertFalse(model.state.logs.hasRefreshError)
    }

    func test迟到页不覆盖新翻页() async throws {
        let (model, transport, _) = try makeModel()
        await model.refresh(.logs)
        await transport.blockNext("list")
        let older = Task { await model.loadLogPage(2) }
        for _ in 0..<1000 {
            if await transport.requests().count >= 2 { break }
            await Task.yield()
        }
        await model.loadLogPage(3)
        await transport.release(); await older.value
        XCTAssertEqual(model.state.logs.value?.pageNumber, 3)
        XCTAssertTrue(model.state.logs.value?.items.first?.message.hasPrefix("Synthetic log 101\n") == true)
    }

    func test日志数量减少后的空页仍可返回首页() async throws {
        let (model, transport, _) = try makeModel()
        await model.refresh(.logs)
        await transport.setMode("nas-logs-empty"); await model.loadLogPage(2)
        XCTAssertEqual(model.state.logs.phase, .empty)
        XCTAssertEqual(model.state.logs.value?.pageNumber, 2)
        XCTAssertEqual(model.state.logs.value?.hasNext, false)
        await model.loadLogPage(1)
        XCTAssertEqual(model.state.logs.value?.pageNumber, 1)
    }

    func test同配置重新绑定清除正文与详情代次() async throws {
        let (model, _, adapter) = try makeModel()
        await model.refresh(.logs)
        let token = model.activationID
        model.activate(profileID: adapter.profileID, repository: adapter)
        XCTAssertNotEqual(token, model.activationID)
        XCTAssertNil(model.state.logs.value)
        XCTAssertEqual(model.state.logs.phase, .idle)
    }

    private func makeModel(mode: String = "nas-logs") throws -> (MobileNasDetailsModel, MobileNasStorageUITransport, MobileReadOnlyNasDetailsRepository) {
        let profile = try NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001)
        let api = DsmAPIName.coreSystemLog
        let capabilities = CapabilitySet([api: .init(name: api, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1)])
        let transport = MobileNasStorageUITransport(mode: mode)
        let base = try DsmNasAdministrationRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        let adapter = MobileReadOnlyNasDetailsRepository(profileID: profile.id, base: base)
        let model = MobileNasDetailsModel(); model.activate(profileID: profile.id, repository: adapter)
        return (model, transport, adapter)
    }
}
