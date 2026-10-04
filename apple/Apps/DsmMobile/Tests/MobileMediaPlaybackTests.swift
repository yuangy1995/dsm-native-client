@testable import DsmMobile
import AVFoundation
import DsmCore
import Foundation
import XCTest

@MainActor
final class MobileMediaPlaybackTests: XCTestCase {
    private let bytes = MobileMediaPlaybackTests.silentWave()

    private var source: MediaStreamSource {
        .init(request: URLRequest(url: URL(string: "https://media.invalid/silence.wav")!), fileExtension: "wav",
              expectedContentLength: Int64(bytes.count), expectedHost: "media.invalid", pinnedCertificateSHA256: nil)
    }

    func test默认媒体不自动播放幻灯片可启动并仅触发一次结束() async throws {
        let model = MobileMediaPlaybackModel(reader: SyntheticMediaReader(bytes: bytes)), callbacks = PlaybackCallbacks()
        defer { model.close() }
        model.configurePlayback(isPlaying: nil, onFinished: { callbacks.finished += 1 }, onFailure: { callbacks.failed += 1 })
        model.prepare(source); try await ready(model)
        XCTAssertEqual(model.player?.rate, 0)
        model.setPlaying(true)
        try await wait { callbacks.finished == 1 || callbacks.failed > 0 }
        XCTAssertEqual(callbacks.finished, 1); XCTAssertEqual(callbacks.failed, 0)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: model.player?.currentItem)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(callbacks.finished, 1)
    }

    func test暂停保留播放位置且恢复后正常结束() async throws {
        let model = MobileMediaPlaybackModel(reader: SyntheticMediaReader(bytes: bytes)), callbacks = PlaybackCallbacks()
        defer { model.close() }
        model.configurePlayback(isPlaying: false, onFinished: { callbacks.finished += 1 }, onFailure: { callbacks.failed += 1 })
        model.prepare(source); try await ready(model)
        model.setPlaying(true); try await Task.sleep(for: .milliseconds(100)); model.setPlaying(false)
        let time = try XCTUnwrap(model.player).currentTime().seconds
        try await Task.sleep(for: .milliseconds(850))
        XCTAssertEqual(model.player?.rate, 0); XCTAssertEqual(callbacks.finished, 0)
        XCTAssertEqual(try XCTUnwrap(model.player).currentTime().seconds, time, accuracy: 0.05)
        model.setPlaying(true); try await wait { callbacks.finished == 1 || callbacks.failed > 0 }
        XCTAssertEqual(callbacks.finished, 1); XCTAssertEqual(callbacks.failed, 0)
    }

    func test上一项结束通知和关闭后的通知不能推进新照片() async throws {
        let model = MobileMediaPlaybackModel(reader: SyntheticMediaReader(bytes: bytes)), callbacks = PlaybackCallbacks()
        defer { model.close() }
        model.configurePlayback(isPlaying: false, onFinished: { callbacks.finished += 1 }, onFailure: nil)
        model.prepare(source); try await ready(model)
        let old = try XCTUnwrap(model.player?.currentItem)
        model.prepare(source); try await ready(model)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: old)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(callbacks.finished, 0)
        let current = try XCTUnwrap(model.player?.currentItem)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: current)
        try await wait { callbacks.finished == 1 }
        model.close(); NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: current)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(callbacks.finished, 1); XCTAssertNil(model.player)
    }

    func test资源和播放器同时报错只报告一次播放失败() async throws {
        let model = MobileMediaPlaybackModel(reader: SyntheticMediaReader(bytes: bytes, fails: true)), callbacks = PlaybackCallbacks()
        defer { model.close() }
        model.configurePlayback(isPlaying: true, onFinished: { callbacks.finished += 1 }, onFailure: { callbacks.failed += 1 })
        model.prepare(source); try await wait { callbacks.failed > 0 }
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(model.hasFailed); XCTAssertEqual(callbacks.failed, 1); XCTAssertEqual(callbacks.finished, 0)
        model.close(); for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(callbacks.failed, 1)
    }

    private func ready(_ model: MobileMediaPlaybackModel) async throws {
        try await wait { (!model.isPreparing && model.player?.currentItem?.status == .readyToPlay) || model.hasFailed }
        XCTAssertFalse(model.hasFailed); XCTAssertFalse(model.isPreparing)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("系统播放器未到达预期状态")
    }
    private static func silentWave() -> Data {
        // 内存中的短 PCM 静音片段，不访问网络、麦克风或用户媒体。
        let length: UInt32 = 12_800
        var result = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { result.append(contentsOf: $0) } }
        append(length + 36); result.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(8_000)); append(UInt32(16_000))
        append(UInt16(2)); append(UInt16(16)); result.append(Data("data".utf8)); append(length)
        result.append(Data(repeating: 0, count: Int(length))); return result
    }
}

@MainActor
private final class PlaybackCallbacks { var finished = 0; var failed = 0 }

private struct SyntheticMediaReader: MobileSecureRangeReading {
    let bytes: Data
    var fails = false
    func read(source: MediaStreamSource, offset: Int64, maximumLength: Int, ifMatch: String?, requiresStrongETag: Bool) async throws -> MobileSecureRangePayload {
        if fails { throw URLError(.badServerResponse) }
        let start = min(bytes.count, max(0, Int(offset))), end = min(bytes.count, min(bytes.count, max(0, Int(offset))) + maximumLength)
        return .init(data: bytes.subdata(in: start..<end), contentType: "audio/wav", totalLength: Int64(bytes.count), strongETag: "\"synthetic-media\"")
    }
}
