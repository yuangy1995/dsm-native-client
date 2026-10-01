import Foundation
import XCTest
@testable import DsmNetwork

final class SynologyPhotosPreviewEventsTests: XCTestCase {
    private let opening = #"0{"sid":"SANITIZED-SOCKET","pingInterval":25000,"pingTimeout":20000}"#
    private let connected = #"40{"sid":"SANITIZED-NAMESPACE"}"#

    func test官方握手路径保留应用目录且查询令牌正确编码() throws {
        for (path, expected) in [("", "/FotoSocketIo/socket.io/"), ("/", "/FotoSocketIo/socket.io/"), ("/photos/index.cgi", "/photos/FotoSocketIo/socket.io/"), ("/photos/", "/photos/FotoSocketIo/socket.io/")] {
            let request = try PhotosPreviewSocketRequest.make(applicationURL: URL(string: "https://nas.example.test:5001" + path)!, credential: .init(sid: "SANITIZED-SID", synoToken: "SANITIZED+&TOKEN"))
            let url = try XCTUnwrap(request.url)
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            XCTAssertEqual(parts.scheme, "wss"); XCTAssertEqual(parts.host, "nas.example.test"); XCTAssertEqual(parts.port, 5001)
            XCTAssertEqual(parts.path, expected)
            XCTAssertEqual(parts.queryItems, [.init(name: "EIO", value: "4"), .init(name: "transport", value: "websocket"), .init(name: "SynoToken", value: "SANITIZED+&TOKEN")])
            XCTAssertFalse(url.absoluteString.contains("SANITIZED-SID"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "id=SANITIZED-SID")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://nas.example.test:5001")
        }
    }

    func test拒绝非加密地址嵌入账号及不明确查询() throws {
        for url in ["http://nas.example.test/", "https://user:password@nas.example.test/", "https://nas.example.test/?unexpected=1", "https://nas.example.test/#fragment"] {
            XCTAssertThrowsError(try PhotosPreviewSocketRequest.make(applicationURL: URL(string: url)!, credential: .init(sid: "SANITIZED", synoToken: nil)))
        }
        XCTAssertThrowsError(try PhotosPreviewSocketRequest.make(applicationURL: URL(string: "https://nas.example.test/")!, credential: .init(sid: "invalid;cookie", synoToken: nil)))
    }

    func test完整握手后订阅且心跳和其他照片不能冒充完成() async throws {
        let socket = PreviewSocketFixture([opening, "2", connected, event(id: 88, success: true), "2", #"42["thumbnail-update",{}]"#, event(id: 7, success: true)])
        let channel = SynologyPhotosPreviewEvents(socket: socket)
        try await channel.subscribe(unitID: 7)
        let sent = await socket.sent
        XCTAssertEqual(sent.count, 3); XCTAssertEqual(sent[0], "40"); XCTAssertEqual(sent[1], "3")
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sent[2].dropFirst(2).utf8)) as? [Any])
        XCTAssertEqual(array.first as? String, "regenerate-preview")
        let registration = try XCTUnwrap(array.last as? [String: Any])
        XCTAssertEqual(registration["idUnit"] as? Int, 7); XCTAssertEqual(registration["operation"] as? String, "register")
        XCTAssertNil(registration["data"])
        let result = try await channel.completion()
        XCTAssertTrue(result)
        let final = await socket.sent; let closed = await socket.closed
        XCTAssertEqual(final.count, 4); XCTAssertEqual(final.last, "3"); XCTAssertTrue(closed)
    }

    func test明确失败事件返回失败而非成功或重发请求() async throws {
        let socket = PreviewSocketFixture([opening, connected, event(id: 7, success: false)])
        let channel = SynologyPhotosPreviewEvents(socket: socket)
        try await channel.subscribe(unitID: 7)
        let result = try await channel.completion()
        XCTAssertFalse(result)
        let sent = await socket.sent
        XCTAssertEqual(sent.count, 2)
    }

    func test未握手就连接或收到完成事件拒绝订阅() async throws {
        for frames in [[connected], [event(id: 7, success: true)], [opening, opening]] {
            let socket = PreviewSocketFixture(frames)
            let channel = SynologyPhotosPreviewEvents(socket: socket)
            do { try await channel.subscribe(unitID: 7); XCTFail("非法握手不能进入写入前置状态") }
            catch { XCTAssertEqual(error as? PhotosPreviewEventError, .invalidFrame) }
            let closed = await socket.closed
            let sent = await socket.sent
            XCTAssertTrue(closed); XCTAssertFalse(sent.contains { $0.contains("register") })
        }
    }

    func test未订阅或重复订阅拒绝且不额外发包() async throws {
        let socket = PreviewSocketFixture([opening, connected])
        let channel = SynologyPhotosPreviewEvents(socket: socket)
        do { _ = try await channel.completion(); XCTFail("未订阅不能等待") } catch { XCTAssertEqual(error as? PhotosPreviewEventError, .invalidState) }
        do { try await channel.subscribe(unitID: 0); XCTFail("无效身份") } catch { XCTAssertEqual(error as? PhotosPreviewEventError, .invalidState) }
        try await channel.subscribe(unitID: 7)
        do { try await channel.subscribe(unitID: 8); XCTFail("同一通道不可切换目标") } catch { XCTAssertEqual(error as? PhotosPreviewEventError, .invalidState) }
        let sent = await socket.sent
        XCTAssertEqual(sent.count, 2)
        await channel.close()
        do { try await channel.subscribe(unitID: 7); XCTFail("已关闭不重连") } catch { XCTAssertEqual(error as? PhotosPreviewEventError, .invalidState) }
    }

    func test断线或拒绝连接不能当作完成() async throws {
        for frame in ["1", "41", #"44{"message":"SANITIZED"}"#] {
            let socket = PreviewSocketFixture([opening, connected, frame])
            let channel = SynologyPhotosPreviewEvents(socket: socket)
            try await channel.subscribe(unitID: 7)
            do { _ = try await channel.completion(); XCTFail("断线不算完成") } catch { XCTAssertEqual(error as? PhotosPreviewEventError, frame.hasPrefix("44") ? .connectionRejected : .disconnected) }
            let closed = await socket.closed; let sent = await socket.sent
            XCTAssertTrue(closed); XCTAssertEqual(sent.count, 2)
        }
    }

    func test完成事件必须有正确类型编号与布尔结果() throws {
        for frame in [#"42["regenerate-preview",{}]"#, #"42["regenerate-preview",{"data":{"idUnit":7}}]"#,
                      #"42["regenerate-preview",{"data":{"idUnit":7,"success":1}}]"#,
                      #"42["regenerate-preview",{"data":{"idUnit":0,"success":true}}]"#,
                      #"42["regenerate-preview",{"data":{"idUnit":"7","success":true}}]"#,
                      #"42["regenerate-preview",{"data":{"idUnit":7,"success":"true"}}]"#,
                      "42not-json", "0{}", "40{}"] {
            XCTAssertThrowsError(try PhotosPreviewSocketPacket.decode(frame))
        }
        XCTAssertEqual(try PhotosPreviewSocketPacket.decode(event(id: 7, success: true)), .completed(unitID: 7, success: true))
        XCTAssertEqual(try PhotosPreviewSocketPacket.decode(#"42["other-event",{}]"#), .ignored)
    }

    func test只有其他照片的事件最终超时并关闭连接() async throws {
        let socket = PreviewSocketFixture([opening, connected, event(id: 8, success: true)])
        let channel = SynologyPhotosPreviewEvents(socket: socket, timeout: .milliseconds(20))
        try await channel.subscribe(unitID: 7)
        do { _ = try await channel.completion(); XCTFail("不能因无匹配结果成功") } catch { XCTAssertEqual(error as? PhotosPreviewEventError, .timedOut) }
        let closed = await socket.closed; let sent = await socket.sent
        XCTAssertTrue(closed); XCTAssertEqual(sent.count, 2)
    }

    func test取消正在等待的任务会关闭接收且不重连() async throws {
        let socket = PreviewSocketFixture([opening, connected])
        let channel = SynologyPhotosPreviewEvents(socket: socket)
        try await channel.subscribe(unitID: 7)
        let task = Task { try await channel.completion() }
        for _ in 0..<100 { if await socket.waiting { break }; await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("取消不能报告完成") } catch { XCTAssertTrue(error is CancellationError) }
        let closed = await socket.closed; let sent = await socket.sent
        XCTAssertTrue(closed); XCTAssertEqual(sent.count, 2)
    }

    func test完成前异常数据关闭通道不会返回成功() async throws {
        let socket = PreviewSocketFixture([opening, connected, #"42["regenerate-preview",{"data":{"idUnit":7}}]"#])
        let channel = SynologyPhotosPreviewEvents(socket: socket)
        try await channel.subscribe(unitID: 7)
        do { _ = try await channel.completion(); XCTFail("无结果不能完成") } catch { XCTAssertEqual(error as? PhotosPreviewEventError, .invalidFrame) }
        let closed = await socket.closed
        XCTAssertTrue(closed)
    }

    func test握手超时不会发送订阅或允许重建() async throws {
        let socket = PreviewSocketFixture([])
        let channel = SynologyPhotosPreviewEvents(socket: socket, timeout: .milliseconds(20))
        do { try await channel.subscribe(unitID: 7); XCTFail("未连接不能返回成功") } catch { XCTAssertEqual(error as? PhotosPreviewEventError, .timedOut) }
        let closed = await socket.closed; let sent = await socket.sent
        XCTAssertTrue(closed); XCTAssertTrue(sent.isEmpty)
    }

    func test超大通知被拒绝且并发等待不会消费同一个结果() async throws {
        XCTAssertThrowsError(try PhotosPreviewSocketPacket.decode(String(repeating: "x", count: 1_048_577)))
        let socket = PreviewSocketFixture([opening, connected])
        let channel = SynologyPhotosPreviewEvents(socket: socket)
        try await channel.subscribe(unitID: 7)
        let first = Task { try await channel.completion() }
        for _ in 0..<100 { if await socket.waiting { break }; await Task.yield() }
        let waiting = await socket.waiting
        XCTAssertTrue(waiting)
        do { _ = try await channel.completion(); XCTFail("不得并发消费") } catch { XCTAssertEqual(error as? PhotosPreviewEventError, .invalidState) }
        await channel.close()
        do { _ = try await first.value; XCTFail("关闭不等于完成") } catch { XCTAssertEqual(error as? PhotosPreviewEventError, .disconnected) }
        let sent = await socket.sent
        XCTAssertEqual(sent.count, 2)
    }

    func test短暂断线重新握手订阅同一照片并接收明确成功或失败() async throws {
        for success in [true, false] {
            let original = PreviewSocketFixture([opening, connected, "41"])
            let recovered = PreviewSocketFixture([opening, "2", connected, event(id: 88, success: true), "2", event(id: 7, success: success)])
            let factory = PreviewSocketSequence([recovered])
            let channel = SynologyPhotosPreviewEvents(socket: original, reconnect: { try factory.next() }, reconnectDelay: { _ in })
            try await channel.subscribe(unitID: 7)
            let result = try await channel.completion()
            XCTAssertEqual(result, success); XCTAssertEqual(factory.calls, 1)
            let oldSent = await original.sent, newSent = await recovered.sent
            XCTAssertEqual(oldSent, ["40", try PhotosPreviewSocketPacket.registration(unitID: 7)])
            XCTAssertEqual(newSent, ["40", "3", try PhotosPreviewSocketPacket.registration(unitID: 7), "3"])
            let oldClosed = await original.closed, newClosed = await recovered.closed
            XCTAssertTrue(oldClosed); XCTAssertTrue(newClosed)
        }
    }

    func test重连握手也断线最多尝试三次且所有连接关闭() async throws {
        let original = PreviewSocketFixture([opening, connected, "1"])
        let retries = [PreviewSocketFixture(["1"]), PreviewSocketFixture([opening, "41"]), PreviewSocketFixture([opening, connected, "1"])]
        let factory = PreviewSocketSequence(retries)
        let channel = SynologyPhotosPreviewEvents(socket: original, reconnect: { try factory.next() }, reconnectDelay: { _ in })
        try await channel.subscribe(unitID: 7)
        do { _ = try await channel.completion(); XCTFail("持续断线不得当作完成") }
        catch { XCTAssertEqual(error as? PhotosPreviewEventError, .disconnected) }
        XCTAssertEqual(factory.calls, 3)
        for socket in [original] + retries { let closed = await socket.closed; XCTAssertTrue(closed) }
    }

    func test连接拒绝或畸形通知不自动重连() async throws {
        for (frame, expected) in [(#"44{"message":"SANITIZED"}"#, PhotosPreviewEventError.connectionRejected), ("42bad-json", .invalidFrame)] {
            let original = PreviewSocketFixture([opening, connected, frame])
            let factory = PreviewSocketSequence([])
            let channel = SynologyPhotosPreviewEvents(socket: original, reconnect: { try factory.next() }, reconnectDelay: { _ in })
            try await channel.subscribe(unitID: 7)
            do { _ = try await channel.completion(); XCTFail("不可重试的错误不得隐去") }
            catch { XCTAssertEqual(error as? PhotosPreviewEventError, expected) }
            XCTAssertEqual(factory.calls, 0)
        }
    }

    func test证书错误不降级为可重连断线() async throws {
        let original = PreviewSocketFixture([opening, connected], receiveFailure: URLError(.serverCertificateUntrusted))
        let factory = PreviewSocketSequence([])
        let channel = SynologyPhotosPreviewEvents(socket: original, reconnect: { try factory.next() }, reconnectDelay: { _ in })
        try await channel.subscribe(unitID: 7)
        do { _ = try await channel.completion(); XCTFail("证书错误必须原样交回") }
        catch { XCTAssertEqual((error as? URLError)?.code, .serverCertificateUntrusted) }
        XCTAssertEqual(factory.calls, 0)
        let closed = await original.closed; XCTAssertTrue(closed)
    }

    func test重连退避包含在总超时且到期不打开新连接() async throws {
        let original = PreviewSocketFixture([opening, connected, "41"])
        let factory = PreviewSocketSequence([])
        let channel = SynologyPhotosPreviewEvents(socket: original, timeout: .milliseconds(30), reconnect: { try factory.next() })
        try await channel.subscribe(unitID: 7)
        do { _ = try await channel.completion(); XCTFail("重连不能重置总等待期限") }
        catch { XCTAssertEqual(error as? PhotosPreviewEventError, .timedOut) }
        XCTAssertEqual(factory.calls, 0)
    }

    func test重连等待期间取消不再打开连接() async throws {
        let original = PreviewSocketFixture([opening, connected, "41"])
        let factory = PreviewSocketSequence([]), pause = PreviewReconnectPause()
        let channel = SynologyPhotosPreviewEvents(socket: original, reconnect: { try factory.next() }, reconnectDelay: { _ in try await pause.wait() })
        try await channel.subscribe(unitID: 7)
        let task = Task { try await channel.completion() }
        for _ in 0..<2000 { if await pause.started { break }; await Task.yield() }
        let started = await pause.started; XCTAssertTrue(started)
        task.cancel()
        do { _ = try await task.value; XCTFail("取消不能继续重连") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(factory.calls, 0)
    }

    func test显式关闭重连后的等待不再次连接() async throws {
        let original = PreviewSocketFixture([opening, connected, "41"])
        let recovered = PreviewSocketFixture([opening, connected])
        let factory = PreviewSocketSequence([recovered])
        let channel = SynologyPhotosPreviewEvents(socket: original, reconnect: { try factory.next() }, reconnectDelay: { _ in })
        try await channel.subscribe(unitID: 7)
        let task = Task { try await channel.completion() }
        for _ in 0..<2000 { if await recovered.waiting { break }; await Task.yield() }
        let waiting = await recovered.waiting; XCTAssertTrue(waiting)
        await channel.close()
        do { _ = try await task.value; XCTFail("关闭后不能消费结果") }
        catch { XCTAssertEqual(error as? PhotosPreviewEventError, .disconnected) }
        XCTAssertEqual(factory.calls, 1)
        let closed = await recovered.closed; XCTAssertTrue(closed)
    }

    private func event(id: Int, success: Bool) -> String {
        #"42["regenerate-preview",{"data":{"idUnit":\#(id),"success":\#(success)}}]"#
    }
}

actor PreviewSocketFixture: PhotosPreviewSocket {
    var sent: [String] = []
    var closed = false
    var waiting: Bool { pending != nil }
    private var frames: [String]
    private let receiveFailure: (any Error)?
    private var pending: CheckedContinuation<String, any Error>?
    init(_ frames: [String], receiveFailure: (any Error)? = nil) { self.frames = frames; self.receiveFailure = receiveFailure }
    func send(_ text: String) throws {
        guard !closed else { throw PhotosPreviewEventError.disconnected }
        sent.append(text)
    }
    func receive() async throws -> String {
        guard !closed else { throw PhotosPreviewEventError.disconnected }
        if !frames.isEmpty { return frames.removeFirst() }
        if let receiveFailure { throw receiveFailure }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func close() {
        closed = true
        let continuation = pending; pending = nil
        continuation?.resume(throwing: Task.isCancelled ? CancellationError() : PhotosPreviewEventError.disconnected)
    }
}


/// 同步工厂用于替换实际网络连接；锁只保护测试队列和计数。
final class PreviewSocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [PreviewSocketFixture]
    private var count = 0
    init(_ sockets: [PreviewSocketFixture]) { self.sockets = sockets }
    var calls: Int { lock.withLock { count } }
    func next() throws -> any PhotosPreviewSocket {
        try lock.withLock {
            count += 1
            guard !sockets.isEmpty else { throw PhotosPreviewEventError.disconnected }
            return sockets.removeFirst()
        }
    }
}

private actor PreviewReconnectPause {
    var started = false
    func wait() async throws { started = true; try await Task.sleep(for: .seconds(60)) }
}
