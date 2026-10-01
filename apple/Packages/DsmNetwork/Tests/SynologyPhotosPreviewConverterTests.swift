import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import DsmNetwork

final class SynologyPhotosPreviewConverterTests: XCTestCase {
    func test失败分类不把取消断网资源不足或缺少编码器上报为媒体转换失败() {
        for error in [PhotosPreviewConversionError.unreadableMedia, .encodingFailed] {
            XCTAssertTrue(SynologyPhotosPreviewConverter.shouldRecordFailure(error))
        }
        for code in [AVError.Code.decodeFailed, .invalidSourceMedia, .fileFormatNotRecognized] {
            XCTAssertTrue(SynologyPhotosPreviewConverter.shouldRecordFailure(NSError(domain: AVFoundationErrorDomain, code: code.rawValue)))
        }
        let excluded: [Error] = [CancellationError(), URLError(.cancelled), URLError(.timedOut), URLError(.networkConnectionLost),
            PhotosPreviewConversionError.invalidDimensions, CocoaError(.fileWriteOutOfSpace),
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.encoderNotFound.rawValue),
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.encoderTemporarilyUnavailable.rawValue),
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.exportFailed.rawValue),
            NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue)]
        for error in excluded { XCTAssertFalse(SynologyPhotosPreviewConverter.shouldRecordFailure(error), String(describing: error)) }
    }

    @MainActor func test视频结果签名允许重新封装但拒绝不同编码内容() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov"), converted = directory.appendingPathComponent("converted.mp4"), remuxed = directory.appendingPathComponent("remuxed.mov")
        try await PhotoPreviewFixture.video(at: source, codec: .jpeg, withAudio: true)
        try await SynologyPhotosPreviewConverter.video(file: source, to: converted)
        let expected = try await SynologyPhotosPreviewConverter.videoSignature(file: converted)
        let original = try await SynologyPhotosPreviewConverter.videoSignature(file: source)
        XCTAssertNotEqual(original, expected)
        let session = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: converted), presetName: AVAssetExportPresetPassthrough))
        session.outputURL = remuxed; session.outputFileType = .mov
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
        XCTAssertEqual(session.status, .completed)
        XCTAssertNotEqual(try Data(contentsOf: remuxed), try Data(contentsOf: converted))
        let actual = try await SynologyPhotosPreviewConverter.videoSignature(file: remuxed)
        XCTAssertEqual(expected, actual)
        let invalid = directory.appendingPathComponent("invalid")
        try Data("invalid video".utf8).write(to: invalid)
        do { _ = try await SynologyPhotosPreviewConverter.videoSignature(file: invalid); XCTFail("错误页不是可核对的视频") } catch { }
    }

    func test大图三档保持比例且不方形裁剪() async throws {
        let source = try PhotoPreviewFixture.image(width: 2400, height: 1600)
        let result = try await Self.convert(source)
        for (data, width, height) in [(result.large, 1920, 1280), (result.small, 360, 240), (result.medium, 480, 320)] {
            let image = try PhotoPreviewFixture.decoded(data)
            XCTAssertEqual(image.width, width); XCTAssertEqual(image.height, height)
            XCTAssertTrue(data.starts(with: [0xff, 0xd8, 0xff]))
        }
    }

    func test小图不放大且去除方向标签避免重复旋转() async throws {
        let result = try await Self.convert(PhotoPreviewFixture.image(width: 48, height: 24, orientation: 6, type: .jpeg))
        for data in [result.large, result.small, result.medium] {
            let image = try PhotoPreviewFixture.decoded(data)
            XCTAssertEqual(image.width, 24); XCTAssertEqual(image.height, 48)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1)
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
        }
    }

    func test图片与视频无效内容均明确失败() async throws {
        for type in ["photo", "video", "unknown"] {
            do { _ = try await Self.convert(Data("not media".utf8), type: type); XCTFail("不能给无法解码的内容生成预览") } catch {}
        }
    }

    func test取消不继续生成文件() async throws {
        let data = try PhotoPreviewFixture.image(width: 32, height: 16)
        let task = Task.detached { @Sendable in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SynologyPhotosPreviewConverterTests.convert(data)
        }
        do { _ = try await task.value; XCTFail("取消不能继续转换") } catch is CancellationError {} catch { XCTFail("错误类型不符：\(type(of: error))") }
    }

    func test短视频提取方向正确的三档预览不改写视频() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.mov")
        try await PhotoPreviewFixture.video(at: url)
        let original = try Data(contentsOf: url)
        let result = try await SynologyPhotosPreviewConverter.convert(file: url, mediaType: "video")
        for data in [result.large, result.small, result.medium] {
            let image = try PhotoPreviewFixture.decoded(data)
            XCTAssertEqual(image.width, 32); XCTAssertEqual(image.height, 64)
        }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    private static func convert(_ data: Data, type: String = "photo") async throws -> PhotosConvertedPreview {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await SynologyPhotosPreviewConverter.convert(file: url, mediaType: type)
    }

    func test自动视频转换输出H264并保留方向时长和原件() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov"), output = directory.appendingPathComponent("output.mp4")
        try await PhotoPreviewFixture.video(at: source, codec: .jpeg, withAudio: true)
        let original = try Data(contentsOf: source)
        try await SynologyPhotosPreviewConverter.video(file: source, to: output)
        let asset = AVURLAsset(url: output), tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(descriptions.first)), kCMVideoCodecType_H264)
        let duration = try await asset.load(.duration).seconds; XCTAssertEqual(duration, 1, accuracy: 0.05)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let audio = try XCTUnwrap(audioTracks.first)
        let audioFormats = try await audio.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(try XCTUnwrap(audioFormats.first)), kAudioFormatMPEG4AAC)
        let previews = try await SynologyPhotosPreviewConverter.convert(file: output, mediaType: "video")
        let image = try PhotoPreviewFixture.decoded(previews.large)
        XCTAssertEqual(image.width, 32); XCTAssertEqual(image.height, 64)
        XCTAssertEqual(try Data(contentsOf: source), original)
        do { try await SynologyPhotosPreviewConverter.video(file: source, to: source); XCTFail("不能覆盖原件") } catch { }
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func test自动视频失败及取消保留已有目标且不导出照片() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png"), output = directory.appendingPathComponent("output.mp4")
        try PhotoPreviewFixture.image().write(to: source)
        let old = Data("existing output".utf8); try old.write(to: output)
        do { try await SynologyPhotosPreviewConverter.video(file: source, to: output); XCTFail("照片不是视频") } catch { }
        XCTAssertEqual(try Data(contentsOf: output), old)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await SynologyPhotosPreviewConverter.video(file: source, to: output)
        }
        do { try await task.value; XCTFail("取消必须停止") } catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: output), old)
    }
}

/// 合成媒体只用于本地验证，不包含真实照片或元数据。
enum PhotoPreviewFixture {
    static func video(at url: URL, codec: AVVideoCodecType = .h264, withAudio: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: 64, AVVideoHeightKey: 32])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32])
        writer.add(input)
        let audio = withAudio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]) : nil
        if let audio { writer.add(audio) }
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 32, kCVPixelFormatType_32ARGB, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)), 127, CVPixelBufferGetDataSize(pixels))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        for frame in 0..<2 {
            for _ in 0..<100 where !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 2)))
        }
        if let audio {
            for _ in 0..<100 where !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(audio.append(try audioSample())); audio.markAsFinished()
        }
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1)); input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    static func audioOnly(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        writer.add(audio); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for _ in 0..<100 where !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(audio.append(try audioSample())); audio.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1)); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    private static func audioSample() throws -> CMSampleBuffer {
        var format = AudioStreamBasicDescription(mSampleRate: 8000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0,
            layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 16000,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 16000,
            flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
        let samples = try XCTUnwrap(block)
        XCTAssertEqual(CMBlockBufferFillDataBytes(with: 0, blockBuffer: samples, offsetIntoDestination: 0, dataLength: 16000), kCMBlockBufferNoErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 8000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var output: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: samples,
            formatDescription: try XCTUnwrap(description), sampleCount: 8000, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &output), noErr)
        return try XCTUnwrap(output)
    }

    static func image(width: Int = 80, height: Int = 40, orientation: Int = 1, type: UTType = .png) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage()), data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    static func decoded(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
}
