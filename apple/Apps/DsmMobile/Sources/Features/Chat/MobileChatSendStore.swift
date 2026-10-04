import CryptoKit
import DsmCore
import Foundation
import Observation

/// 未发送草稿与副本受系统文件保护；已提交操作只能按原回执读取，成功后清理草稿。
@MainActor
@Observable
final class MobileChatSendStore {
    enum Phase: String, Codable { case prepared, submitted, complete, failed, cancelled }
    enum Kind: String, Codable { case text, reply, attachment }
    enum Failure: String, Codable { case denied, unavailable, invalid, attachmentChanged }
    struct Attachment: Codable, Equatable, Sendable {
        let fileName: String
        let kind: ChatAttachmentKind
        let byteCount: Int64
        let contentDigest: String
    }
    struct Payload: Codable, Equatable, Sendable {
        let text: String?
        let attachment: Attachment?
    }
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let context: String
        let conversationID: String
        let threadID: String?
        let createdAt: Date
        let kind: Kind
        let inputDigest: String
        var payload: Payload?
        var phase: Phase = .prepared
        var receipt: ChatMessageSendReceipt?
        var failure: Failure?
        var hasUnfinished: Bool { phase == .prepared || phase == .submitted }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []
    private var preparingContexts: Set<String> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChatSending-\(UUID())")
        do {
            if FileManager.default.fileExists(atPath: self.root.path),
               try self.root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
                throw MobileTransferRecoveryStore.StoreError.invalidRecord
            }
            let url = self.root.appendingPathComponent("message-sends-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard value.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(value.entries); entries = value.entries
                entries.filter { $0.phase == .complete }.forEach { cleanFiles($0.id) }
            }
        } catch { failed = true }
    }

    func entry(_ id: UUID, in context: String) -> Entry? { entries.first { $0.id == id && $0.context == context } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func isBusy(in context: String) -> Bool {
        preparingContexts.contains(context) || entries.contains { $0.context == context && executing.contains($0.id) }
    }
    func beginPreparing(in context: String) -> Bool {
        guard !failed, !context.isEmpty, !isBusy(in: context) else { return false }
        return preparingContexts.insert(context).inserted
    }
    func endPreparing(in context: String) { preparingContexts.remove(context) }
    func begin(_ id: UUID, in context: String) -> Bool {
        guard !failed, !isBusy(in: context), entry(id, in: context)?.hasUnfinished == true else { return false }
        return executing.insert(id).inserted
    }
    func end(_ id: UUID) { executing.remove(id) }

    func reserve(_ entry: Entry, replacing oldID: UUID? = nil) throws {
        guard entry.phase == .prepared, entry.receipt == nil, entry.failure == nil else { throw invalid() }
        if let oldID {
            guard let old = self.entry(oldID, in: entry.context), [.failed, .cancelled].contains(old.phase),
                  !isExecuting(oldID), old.conversationID == entry.conversationID, old.threadID == entry.threadID,
                  old.inputDigest == entry.inputDigest else { throw invalid() }
        }
        try persist(entries.filter { $0.id != oldID } + [entry])
        if let oldID { cleanFiles(oldID) }
    }

    func record(_ receipt: ChatMessageSendReceipt, in context: String) throws {
        try receipt.validate()
        try update(receipt.clientRequestID, context: context) { entry in
            guard entry.hasUnfinished, let payload = entry.payload,
                  receipt.conversationID == entry.conversationID, receipt.threadID == entry.threadID,
                  receipt.textDigest == ChatMessageSendReceipt.digest(text: payload.text),
                  (receipt.attachmentDigest == nil) == (payload.attachment == nil) else { throw invalid() }
            try validateReceipt(receipt, entry: entry, payload: payload)
            if var old = entry.receipt {
                let candidate = old.candidateMessageID
                old.candidateMessageID = receipt.candidateMessageID
                guard old == receipt, candidate == nil || candidate == receipt.candidateMessageID else { throw invalid() }
            } else {
                guard entry.phase == .prepared, receipt.candidateMessageID == nil else { throw invalid() }
            }
            entry.receipt = receipt; entry.phase = .submitted
        }
    }

    func finish(_ id: UUID, context: String, phase: Phase, failure: Failure? = nil) throws {
        guard [.complete, .failed, .cancelled].contains(phase), (phase == .failed) == (failure != nil) else { throw invalid() }
        try update(id, context: context) { entry in
            guard entry.hasUnfinished,
                  phase != .complete || entry.receipt?.candidateMessageID != nil,
                  phase == .complete || entry.receipt?.candidateMessageID == nil else { throw invalid() }
            entry.phase = phase; entry.failure = failure
            if phase == .complete { entry.payload = nil }
        }
        if phase == .complete { cleanFiles(id) }
    }

    func cancelPrepared(_ id: UUID, context: String) throws {
        guard entry(id, in: context)?.phase == .prepared, !isExecuting(id) else { throw invalid() }
        try update(id, context: context, requiresExecution: false) { $0.phase = .cancelled }
    }

    func remove(_ id: UUID, context: String) throws {
        guard let entry = entry(id, in: context), !entry.hasUnfinished, !isExecuting(id) else { throw invalid() }
        try persist(entries.filter { $0.id != id })
        cleanFiles(id)
    }

    func directory(_ id: UUID) -> URL {
        root.appendingPathComponent("SendFiles", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }
    func attachmentURL(_ entry: Entry) -> URL? {
        entry.payload?.attachment.map { directory(entry.id).appendingPathComponent($0.fileName, isDirectory: false) }
    }
    func cleanFiles(_ id: UUID) { try? FileManager.default.removeItem(at: directory(id)) }

    static func digest(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(payload)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func fileDigest(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let part = try handle.read(upToCount: 1_048_576), !part.isEmpty {
            try Task.checkCancellation(); hash.update(data: part)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func update(_ id: UUID, context: String, requiresExecution: Bool = true, change: (inout Entry) throws -> Void) throws {
        guard !failed, !requiresExecution || isExecuting(id),
              let index = entries.firstIndex(where: { $0.id == id && $0.context == context }) else { throw invalid() }
        var updated = entries; try change(&updated[index]); try persist(updated)
    }
    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw invalid() }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(
                to: root.appendingPathComponent("message-sends-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }
    private func validate(_ values: [Entry]) throws {
        func hasID(_ value: String) -> Bool { !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func isDigest(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        var identities: Set<UUID> = [], unfinished: Set<String> = []
        for entry in values {
            guard identities.insert(entry.id).inserted, !entry.context.isEmpty, hasID(entry.conversationID),
                  entry.threadID.map(hasID) ?? true, entry.createdAt.timeIntervalSince1970.isFinite,
                  isDigest(entry.inputDigest), (entry.phase == .failed) == (entry.failure != nil),
                  (entry.kind == .reply) == (entry.threadID != nil),
                  (entry.phase == .complete) == (entry.payload == nil),
                  entry.phase != .prepared || entry.receipt == nil,
                  ![.submitted, .complete].contains(entry.phase) || entry.receipt != nil else { throw invalid() }
            if let payload = entry.payload {
                guard payload.text == payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      payload.text?.isEmpty != true, payload.text != nil || payload.attachment != nil,
                      (entry.kind == .attachment) == (payload.attachment != nil),
                      try Self.digest(payload) == entry.inputDigest else { throw invalid() }
                if let attachment = payload.attachment {
                    guard !attachment.fileName.isEmpty,
                          attachment.fileName == MobileDocumentTransferController.safeLeafName(attachment.fileName),
                          attachment.byteCount >= 0, isDigest(attachment.contentDigest) else { throw invalid() }
                }
            }
            if let receipt = entry.receipt {
                try receipt.validate()
                if let payload = entry.payload { try validateReceipt(receipt, entry: entry, payload: payload) }
                guard receipt.clientRequestID == entry.id, receipt.conversationID == entry.conversationID,
                      receipt.threadID == entry.threadID, (receipt.attachmentDigest != nil) == (entry.kind == .attachment),
                      entry.payload.map({ ChatMessageSendReceipt.digest(text: $0.text) == receipt.textDigest }) ?? true,
                      entry.phase != .complete || receipt.candidateMessageID != nil,
                      ![.failed, .cancelled].contains(entry.phase) || receipt.candidateMessageID == nil else { throw invalid() }
            }
            if entry.hasUnfinished {
                let identity = try JSONEncoder().encode([entry.context, entry.conversationID, entry.threadID ?? "", entry.inputDigest]).base64EncodedString()
                guard unfinished.insert(identity).inserted else { throw invalid() }
            }
        }
    }
    private func validateReceipt(_ receipt: ChatMessageSendReceipt, entry: Entry, payload: Payload) throws {
        let draft = try ChatMessageDraft(clientRequestID: entry.id, conversationID: entry.conversationID,
            text: payload.text, localAttachmentURLs: attachmentURL(entry).map { [$0] } ?? [], threadID: entry.threadID)
        var expected = try ChatMessageSendReceipt(draft: draft, currentUserID: receipt.currentUserID,
            attachmentSize: payload.attachment?.byteCount, submittedAt: receipt.submittedAt)
        expected.candidateMessageID = receipt.candidateMessageID
        guard expected == receipt else { throw invalid() }
    }

    private func invalid() -> MobileTransferRecoveryStore.StoreError { .invalidRecord }
}
