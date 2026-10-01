import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 官方手动重建只需要三档JPEG预览，保持比例和方向，不改写原件或重新编码完整视频。
struct PhotosConvertedPreview: Sendable {
    let large: Data
    let small: Data
    let medium: Data
}

enum PhotosPreviewConversionError: Error { case unreadableMedia, invalidDimensions, encodingFailed }

/// 比较编码轨道而非容器字节，允许下载端重新封装MOV；不接受仅时长/大小相同的视频。
struct PhotosPreviewVideoSignature: Equatable, Sendable {
    struct Track: Equatable, Sendable {
        let type: String
        let formats: [FourCharCode]
        let transform: [Double]
        let sampleCount: Int
        let digest: Data
    }
    let tracks: [Track]
    let durationMicroseconds: Int64
}

enum SynologyPhotosPreviewConverter {
    /// 对应网页非连接失败分支；系统资源/能力、取消、网络和未知错误保留本地重试。
    static func shouldRecordFailure(_ error: Error) -> Bool {
        if let error = error as? PhotosPreviewConversionError {
            switch error {
            case .unreadableMedia, .encodingFailed: return true
            case .invalidDimensions: return false
            }
        }
        let error = error as NSError
        guard error.domain == AVFoundationErrorDomain else { return false }
        return [AVError.Code.decodeFailed, .invalidSourceMedia, .fileFormatNotRecognized].contains { $0.rawValue == error.code }
    }

    static func videoSignature(file: URL) async throws -> PhotosPreviewVideoSignature {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: file)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw PhotosPreviewConversionError.unreadableMedia }
        var signatures: [PhotosPreviewVideoSignature.Track] = []
        for type in [AVMediaType.video, .audio] {
            let tracks = try await asset.loadTracks(withMediaType: type)
            for track in tracks {
                let formats = try await track.load(.formatDescriptions).map { CMFormatDescriptionGetMediaSubType($0) }
                let transform = try await track.load(.preferredTransform)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(output) else { throw PhotosPreviewConversionError.unreadableMedia }
                reader.add(output)
                guard reader.startReading() else { throw reader.error ?? PhotosPreviewConversionError.unreadableMedia }
                defer { reader.cancelReading() }
                var digest = SHA256(), count = 0
                while let sample = output.copyNextSampleBuffer() {
                    try Task.checkCancellation()
                    // AVAssetReader会返回零样本的EditBoundary标记；轨道内容只计算实际样本。
                    if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                    guard let buffer = CMSampleBufferGetDataBuffer(sample) else { throw PhotosPreviewConversionError.unreadableMedia }
                    let length = CMBlockBufferGetDataLength(buffer)
                    guard length > 0 else { throw PhotosPreviewConversionError.unreadableMedia }
                    var data = Data(count: length)
                    let status = data.withUnsafeMutableBytes { bytes in
                        CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
                    }
                    guard status == kCMBlockBufferNoErr else { throw PhotosPreviewConversionError.unreadableMedia }
                    // 容器时间基可不同，按微秒记录每个样本时长，分组方式不参与比较。
                    var offset = 0
                    for index in 0..<CMSampleBufferGetNumSamples(sample) {
                        var timing = CMSampleTimingInfo()
                        guard CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr else { throw PhotosPreviewConversionError.unreadableMedia }
                        let duration = timing.duration.seconds
                        guard duration.isFinite, duration >= 0 else { throw PhotosPreviewConversionError.unreadableMedia }
                        let size = CMSampleBufferGetSampleSize(sample, at: index)
                        guard size > 0, offset + size <= length else { throw PhotosPreviewConversionError.unreadableMedia }
                        digest.update(data: Data("\(size):\(Int64((duration * 1_000_000).rounded()));".utf8))
                        digest.update(data: data.subdata(in: offset..<(offset + size)))
                        offset += size
                        count += 1
                    }
                    guard offset == length else { throw PhotosPreviewConversionError.unreadableMedia }
                }
                guard reader.status == .completed, count > 0 else { throw reader.error ?? PhotosPreviewConversionError.unreadableMedia }
                signatures.append(.init(type: type.rawValue, formats: formats,
                    transform: [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty],
                    sampleCount: count, digest: Data(digest.finalize())))
            }
        }
        guard signatures.contains(where: { $0.type == AVMediaType.video.rawValue }) else { throw PhotosPreviewConversionError.unreadableMedia }
        try Task.checkCancellation()
        return .init(tracks: signatures, durationMicroseconds: Int64((duration * 1_000_000).rounded()))
    }

    /// 自动预览的视频结果使用H.264/AAC，保持画面比例和轨道方向；原件不改写。
    @MainActor static func video(file: URL, to destination: URL) async throws {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: file)
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty,
              let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(.mp4) else { throw PhotosPreviewConversionError.unreadableMedia }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("converted.mp4")
        session.outputURL = output; session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.metadata = []
        await PhotosVideoExport(session).run()
        try Task.checkCancellation()
        guard session.status == .completed else { throw session.error ?? PhotosPreviewConversionError.encodingFailed }
        let converted = AVURLAsset(url: output)
        let duration = try await converted.load(.duration).seconds
        let tracks = try await converted.loadTracks(withMediaType: .video)
        guard duration.isFinite, duration > 0, !tracks.isEmpty else { throw PhotosPreviewConversionError.encodingFailed }
        for track in tracks {
            let formats = try await track.load(.formatDescriptions)
            guard !formats.isEmpty, formats.allSatisfy({ CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else { throw PhotosPreviewConversionError.encodingFailed }
        }
        try Task.checkCancellation()
        try await DownloadedFileExporter.export(from: output, to: destination, replaceExisting: false)
    }

    static func convert(file: URL, mediaType: String) async throws -> PhotosConvertedPreview {
        try Task.checkCancellation()
        if mediaType == "video" {
            let asset = AVURLAsset(url: file)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw PhotosPreviewConversionError.unreadableMedia }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // 与网页取帧时间一致；不足一秒的视频限制在实际时长内。
            let seconds = min(duration > 3 ? 3 : 1, max(0, duration - 1 / 30))
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            try Task.checkCancellation()
            return try thumbnails(image)
        }
        guard mediaType == "photo", let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw PhotosPreviewConversionError.unreadableMedia }
        let scale = min(1, 1280 / Double(min(width, height)))
        let size = max(1, Int(ceil(Double(max(width, height)) * scale)))
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw PhotosPreviewConversionError.unreadableMedia }
        return try thumbnails(image)
    }

    static func thumbnails(_ image: CGImage) throws -> PhotosConvertedPreview {
        try .init(large: jpeg(image, shortEdge: 1280), small: jpeg(image, shortEdge: 240), medium: jpeg(image, shortEdge: 320))
    }

    private static func jpeg(_ image: CGImage, shortEdge: Int) throws -> Data {
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0 else { throw PhotosPreviewConversionError.invalidDimensions }
        let scale = min(1, Double(shortEdge) / Double(min(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PhotosPreviewConversionError.invalidDimensions
        }
        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        guard let output = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotosPreviewConversionError.encodingFailed
        }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotosPreviewConversionError.encodingFailed }
        return data as Data
    }
}

/// macOS 14导出对象不是Sendable；启动和取消都在同一执行域，避免绕过并发检查。
@MainActor private final class PhotosVideoExport {
    private let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
    func run() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            Task { @MainActor [self] in session.cancelExport() }
        }
    }
}
