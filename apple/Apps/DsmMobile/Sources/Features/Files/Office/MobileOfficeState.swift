import DsmCore
import DsmFileFeature
import Foundation

enum MobileOfficePhase: String, Codable, Sendable {
    case ready, changed, unchanged, saving, saved, conflict, uncertain
    var isActive: Bool { self != .saved && self != .unchanged }
}

enum MobileOfficeFailure: String, Error, Sendable {
    case connection, permission, changed, format, local, recovery, interrupted
}

struct MobileOfficeRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let context: String
    let createdAt: Date
    var baseline: FileItem
    var baselineFingerprint: OfficeFileFingerprint
    let originalID: UUID
    var candidateID: UUID?
    var candidateFingerprint: OfficeFileFingerprint?
    var phase: MobileOfficePhase = .ready

    var isValid: Bool {
        !context.isEmpty && MobileOfficePolicy.supports(baseline)
            && baselineFingerprint.size == baseline.sizeBytes
            && valid(baselineFingerprint)
            && ((candidateID == nil) == (candidateFingerprint == nil))
            && (candidateFingerprint.map(valid) ?? true)
            && (![.changed, .saving, .saved, .uncertain].contains(phase) || candidateID != nil)
    }

    private func valid(_ fingerprint: OfficeFileFingerprint) -> Bool {
        fingerprint.size >= 0 && fingerprint.md5.count == 32 && fingerprint.sha256.count == 64
            && (fingerprint.md5 + fingerprint.sha256).allSatisfy { $0.isHexDigit && $0.isASCII }
    }
}

enum MobileOfficePolicy {
    static func supports(_ item: FileItem) -> Bool {
        OfficeDocumentFormat.supports(item) && item.kind == .file && !item.isRecyclePath
            && item.path.hasPrefix("/") && item.path.split(separator: "/").count >= 2
            && !item.path.contains("//") && !item.path.contains("\0")
            && !item.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
            && (item.path as NSString).lastPathComponent == item.name
            && !item.name.contains(where: { $0 == "\"" || $0 == "\r" || $0 == "\n" })
            && (item.name as NSString).pathExtension.lowercased() == item.fileExtension?.lowercased()
            && [nil, "", "normal", "shared_folder"].contains(item.mountPointType)
            && item.permissions?.canRead != false
    }

    static func sameVersion(_ lhs: FileItem, _ rhs: FileItem) -> Bool {
        lhs.profileID == rhs.profileID && lhs.path == rhs.path && lhs.kind == rhs.kind
            && lhs.sizeBytes == rhs.sizeBytes && lhs.times?.modifiedAt == rhs.times?.modifiedAt
            && lhs.times?.createdAt == rhs.times?.createdAt && lhs.mountPointType == rhs.mountPointType
    }
}

struct MobileOfficeStore {
    private struct Envelope: Codable { let version: Int; let records: [MobileOfficeRecord] }
    let root: URL
    var file: URL { root.appendingPathComponent("sessions-v1.json") }

    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func artifact(_ record: MobileOfficeRecord, id: UUID) -> URL {
        directory(record.id).appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(record.baseline.name)
    }

    func load() throws -> [MobileOfficeRecord] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: file))
        guard envelope.version == 1, envelope.records.allSatisfy(\.isValid),
              Set(envelope.records.map(\.id)).count == envelope.records.count,
              Set(envelope.records.map { $0.context + "\0" + $0.baseline.path }).count == envelope.records.count
        else { throw MobileOfficeFailure.recovery }
        return envelope.records.map { original in
            var record = original
            if record.phase == .saving { record.phase = .uncertain }
            return record
        }
    }

    func save(_ records: [MobileOfficeRecord]) throws {
        guard records.allSatisfy(\.isValid) else { throw MobileOfficeFailure.recovery }
        try MobileTransferRecoveryStore.prepareDirectory(root)
        try JSONEncoder().encode(Envelope(version: 1, records: records)).write(to: file,
            options: [.atomic, .completeFileProtection])
    }
}
