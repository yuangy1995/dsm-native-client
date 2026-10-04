#if DEBUG
import AVFoundation
import DsmCore
import DsmNetwork
import Foundation

/// 仅显式 UI fixture 使用：合成静音文件代替麦克风，试听仍走系统解码器。
@MainActor
final class MobileChatAudioUIDriver: MobileChatAudioDriving {
    private let playback = MobileSystemChatAudioDriver()
    private let denied: Bool
    private var startedAt: Date?
    init(denied: Bool = false) { self.denied = denied }
    var recordedDuration: TimeInterval { startedAt.map { max(1, min(300, Date().timeIntervalSince($0))) } ?? 0 }
    func requestRecordPermission() async -> Bool { !denied }
    func record(to url: URL, limit: TimeInterval, finished: @escaping @MainActor (Bool) -> Void) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441_000)!
        buffer.frameLength = 441_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        try file.write(from: buffer)
        startedAt = Date()
    }
    func stopRecording() { startedAt = nil }
    func play(_ url: URL, finished: @escaping @MainActor (Bool) -> Void) throws { try playback.play(url, finished: finished) }
    func pause() { playback.pause() }
    func resume() throws { try playback.resume() }
    func stopPlayback() { playback.stopPlayback() }
}

actor MobileChatAudioUITransport: DsmBinaryHTTPTransport {
    private let base = MobileChatUITransport()
    private let state: String
    private var uploaded: [String: Any]?
    private var uploadedBytes: Data?
    private var writes = 0
    private var downloads = 0
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(state: String = "chat-audio-content") { self.state = state }
    func counts() -> (writes: Int, downloads: Int) { (writes, downloads) }
    func waitForDownload() async {
        if blocked != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func releaseDownload() { blocked?.resume(); blocked = nil }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let text = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let fields = URLComponents(string: "https://fixture.invalid/?" + text)?.queryItems ?? []
        func field(_ key: String) -> String? { fields.first { $0.name == key }?.value }
        if field("api") == DsmAPIName.chatPost, field("method") == "list" {
            if field("channel_id") == "28" { return try response(["success": true, "data": ["posts": []]]) }
            if field("post_id") == "9401", let uploaded { return try response(["success": true, "data": ["posts": [uploaded]]]) }
            var messages = [Self.post(id: "9400", name: "sample.wav", size: Self.wave.count)]
            if let uploaded { messages.append(uploaded) }
            return try response(["success": true, "data": ["posts": messages]])
        }
        return try await base.send(request)
    }

    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        writes += 1
        if state == "chat-audio-send-denied" { return try response(["success": false, "error": ["code": 105]]) }
        let data = try Data(contentsOf: bodyFileURL)
        guard let boundary = request.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: "boundary=").last,
              let nameStart = data.range(of: Data("filename=\"".utf8)),
              let nameEnd = data.range(of: Data("\"".utf8), in: nameStart.upperBound..<data.endIndex),
              let headerEnd = data.range(of: Data("\r\n\r\n".utf8), in: nameEnd.upperBound..<data.endIndex),
              let bodyEnd = data.range(of: Data(("\r\n--" + boundary).utf8), in: headerEnd.upperBound..<data.endIndex) else { throw URLError(.badServerResponse) }
        let name = String(decoding: data[nameStart.upperBound..<nameEnd.lowerBound], as: UTF8.self)
        let bytes = Data(data[headerEnd.upperBound..<bodyEnd.lowerBound])
        uploadedBytes = bytes
        uploaded = Self.post(id: "9401", name: name, size: bytes.count)
        progress(Int64(data.count), Int64(data.count))
        if state == "chat-audio-send-unknown" { throw URLError(.networkConnectionLost) }
        return try response(["success": true, "data": ["post_id": "9401"]])
    }

    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        downloads += 1
        if state == "chat-audio-loading" {
            await withCheckedContinuation { blocked = $0; waiters.forEach { $0.resume() }; waiters = [] }
        }
        if state == "chat-audio-download-failed" { throw URLError(.notConnectedToInternet) }
        let fields = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        let sentVoice = fields.first { $0.name == "post_id" }?.value == "9401"
        let data: Data
        if state == "chat-audio-invalid" { data = Data("invalid audio".utf8) }
        else if sentVoice {
            guard let uploadedBytes else { throw URLError(.badServerResponse) }
            data = uploadedBytes
        } else { data = Self.wave }
        try data.write(to: destinationURL)
        progress(Int64(data.count), Int64(data.count))
        return .init(data: Data(), statusCode: 200, headers: ["Content-Type": sentVoice ? "audio/aac" : "audio/wav"])
    }

    private static func post(id: String, name: String, size: Int) -> [String: Any] {
        ["post_id": id, "channel_id": 27, "creator_id": 1, "create_at": 1_790_000_000_000, "thread_id": "0", "type": "normal", "message": "",
         "files": [["file_id": id, "name": name, "size": size, "content_type": name.hasSuffix(".aac") ? "audio/aac" : "audio/wav"]]]
    }
    private func response(_ object: [String: Any]) throws -> DsmHTTPResponse {
        .init(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }

    /// 10 秒、8kHz、单声道静音 WAV，用于原生播放，不含任何用户声音。
    static var wave: Data {
        var data = Data("RIFF".utf8)
        func integer<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        integer(UInt32(160_036)); data.append(Data("WAVEfmt ".utf8)); integer(UInt32(16))
        integer(UInt16(1)); integer(UInt16(1)); integer(UInt32(8_000)); integer(UInt32(16_000))
        integer(UInt16(2)); integer(UInt16(16)); data.append(Data("data".utf8)); integer(UInt32(160_000))
        data.append(Data(count: 160_000)); return data
    }
}
#endif
