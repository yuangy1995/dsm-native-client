import CoreGraphics
import DsmCore
import Foundation
#if os(macOS)
import AppKit
#else
import ImageIO
import UniformTypeIdentifiers
#endif

public struct PhotoFaceDraft: Identifiable, Equatable, Sendable {
    public let id: String
    public let original: SynologyPhotoFaceRegion?
    public var bounds: SynologyPhotoFaceBounds
    public var personID: Int
    public var name: String
    public var removed = false
    public init(id: String, original: SynologyPhotoFaceRegion?, bounds: SynologyPhotoFaceBounds, personID: Int, name: String, removed: Bool = false) {
        self.id = id; self.original = original; self.bounds = bounds; self.personID = personID; self.name = name; self.removed = removed
    }
}

/// 裁剪和变化计算独立于视图，合成图片可验证坐标、方向和保存快照。
public enum PhotoFaceEditing {
    public enum Failure: Error { case invalidImage, invalidSelection }

    public static func jpeg(_ image: CGImage, bounds: SynologyPhotoFaceBounds) throws -> Data {
        guard bounds.isValid else { throw Failure.invalidSelection }
        let rect = CGRect(x: bounds.x * Double(image.width), y: bounds.y * Double(image.height),
                          width: bounds.width * Double(image.width), height: bounds.height * Double(image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: rect), crop.width > 0, crop.height > 0 else { throw Failure.invalidImage }
        let scale = min(1, 256 / Double(max(crop.width, crop.height)))
        let width = max(1, Int((Double(crop.width) * scale).rounded()))
        let height = max(1, Int((Double(crop.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.invalidImage }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw Failure.invalidImage }
        #if os(macOS)
        guard let data = NSBitmapImageRep(cgImage: result).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { throw Failure.invalidImage }
        return data
        #else
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.invalidImage }
        CGImageDestinationAddImage(destination, result, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        return data as Data
        #endif
    }

    public static func changes(photo: SynologyPhoto, image: CGImage, drafts: [PhotoFaceDraft], people: [SynologyPhotoCollection]) throws -> [SynologyPhotoFaceChange] {
        var changes: [SynologyPhotoFaceChange] = []
        for (index, draft) in drafts.enumerated() {
            if draft.removed {
                if let original = draft.original { changes.append(.remove(original)) }
                continue
            }
            if let original = draft.original, original.bounds == draft.bounds, original.personID == draft.personID, original.name == draft.name { continue }
            let person = people.first { $0.id == draft.personID }
            let name = person?.name ?? draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard person != nil || !name.isEmpty else { throw Failure.invalidSelection }
            if let original = draft.original, original.bounds == draft.bounds {
                if original.personID != draft.personID || original.name != name { changes.append(.reassign(original, person: person, name: name)) }
            } else {
                if let original = draft.original { changes.append(.remove(original)) }
                changes.append(.add(.init(temporaryID: "\(photo.id.unitID)-\(index)", bounds: draft.bounds, person: person, name: name,
                    jpeg: try jpeg(image, bounds: draft.bounds))))
            }
        }
        return changes
    }

    public static func square(from start: CGPoint, to end: CGPoint, in size: CGSize) -> SynologyPhotoFaceBounds? {
        guard size.width > 0, size.height > 0 else { return nil }
        let x = min(size.width, max(0, start.x)), y = min(size.height, max(0, start.y))
        let right = end.x >= x, down = end.y >= y
        let side = min(max(abs(end.x - x), abs(end.y - y)), right ? size.width - x : x, down ? size.height - y : y)
        guard side >= min(36, min(size.width, size.height)) else { return nil }
        return .init(x: (right ? x : x - side) / size.width, y: (down ? y : y - side) / size.height,
                     width: side / size.width, height: side / size.height)
    }
}
