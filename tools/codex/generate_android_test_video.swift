import AVFoundation
import CoreVideo
import Foundation

// 仅生成原生播放器测试用的六秒H.264；可选四色角标验证方向，无用户资料或外部素材。
// 用法：swift tools/codex/generate_android_test_video.swift <输出.mp4> [--landmarks]
guard CommandLine.arguments.count == 2 || (CommandLine.arguments.count == 3 && CommandLine.arguments[2] == "--landmarks") else { fatalError("Expected output path and optional --landmarks") }
let landmarks = CommandLine.arguments.count == 3
let output = URL(fileURLWithPath: CommandLine.arguments[1])
guard !FileManager.default.fileExists(atPath: output.path) else { fatalError("Output already exists") }
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: 160, AVVideoHeightKey: 120,
    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 80_000, AVVideoMaxKeyFrameIntervalKey: 10],
])
let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
    kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120,
])
writer.add(input)
guard writer.startWriting() else { throw writer.error! }
writer.startSession(atSourceTime: .zero)
for frame in 0..<60 {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    var buffer: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pixels.pixelBufferPool!, &buffer) == kCVReturnSuccess,
          let buffer else { fatalError("Cannot allocate pixels") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let address = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    for y in 0..<120 { for x in 0..<160 {
        let p = y * stride + x * 4
        address[p] = 255; address[p + 1] = UInt8(40 + frame * 2); address[p + 2] = 120; address[p + 3] = 190
        if landmarks && (x < 40 || x >= 120) && (y < 30 || y >= 90) {
            let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
            let color = colors[(y >= 90 ? 2 : 0) + (x >= 120 ? 1 : 0)]
            address[p + 1] = color.0; address[p + 2] = color.1; address[p + 3] = color.2
        }
    } }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    guard pixels.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10)) else { throw writer.error! }
}
writer.endSession(atSourceTime: CMTime(seconds: 6, preferredTimescale: 10))
input.markAsFinished()
let complete = DispatchSemaphore(value: 0)
writer.finishWriting { complete.signal() }
complete.wait()
guard writer.status == .completed else { throw writer.error! }
print("Generated six-second synthetic test video; landmarks=\(landmarks)")
