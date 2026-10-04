import DsmCore
import Foundation
import Observation

/// 批次只保存身份、阶段和摘要。已提交项只能读取恢复，不能重放转发。
@MainActor
@Observable
final class MobileChatForwardStore {
    enum Phase: String, Codable { case planned, submitted, complete, failed, cancelled }
    struct Source: Codable, Equatable {
        let messageID: String
        let conversationID: String
        let threadID: String?
        let senderID: String
        let sentAt: Date
        let editedAt: Date?
        let digest: String

        init(_ message: ChatMessage) throws {
            messageID = message.id; conversationID = message.conversationID; threadID = message.threadID
            senderID = message.senderID; sentAt = message.sentAt; editedAt = message.editedAt
            digest = try ChatForwardReceipt.digest(of: message)
        }
        func matches(_ message: ChatMessage) -> Bool { (try? Source(message)) == self }
    }
    struct Item: Codable, Equatable, Identifiable {
        let id: UUID
        let source: Source
        var phase: Phase = .planned
        var receipt: ChatForwardReceipt?
    }
    struct Destination: Codable, Equatable, Identifiable {
        enum Kind: String, Codable { case conversation, contact }
        let id: UUID
        let kind: Kind
        let referenceID: String
        var conversationID: String?
        var phase: Phase

        static func conversation(_ id: String) -> Self {
            .init(id: UUID(), kind: .conversation, referenceID: id, conversationID: id, phase: .complete)
        }
        static func contact(_ id: String) -> Self {
            .init(id: UUID(), kind: .contact, referenceID: id, conversationID: nil, phase: .planned)
        }
    }
    struct Entry: Codable, Equatable, Identifiable {
        let id: UUID
        let context: String
        let createdAt: Date
        var items: [Item]
        var destinations: [Destination]
        var hasUnfinished: Bool {
            items.contains { $0.phase == .planned || $0.phase == .submitted }
                || destinations.contains { $0.phase == .planned || $0.phase == .submitted }
        }
        var hasSubmitted: Bool { items.contains { $0.phase == .submitted } || destinations.contains { $0.phase == .submitted } }
        var hasPlanned: Bool { items.contains { $0.phase == .planned } || destinations.contains { $0.phase == .planned } }
        var targetIDs: [String] { Array(Set(destinations.filter { $0.phase == .complete }.compactMap(\.conversationID))).sorted() }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChatForward-\(UUID())")
        do {
            let url = self.root.appendingPathComponent("forwarding-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard value.version == 1 else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                try validate(value.entries); entries = value.entries
            }
        } catch { failed = true }
    }

    func entry(_ id: UUID, in context: String) -> Entry? { entries.first { $0.id == id && $0.context == context } }
    func isExecuting(_ id: UUID) -> Bool { executing.contains(id) }
    func begin(_ id: UUID, in context: String) -> Bool {
        guard !failed, entry(id, in: context) != nil else { return false }
        return executing.insert(id).inserted
    }
    func end(_ id: UUID) { executing.remove(id) }

    func reserve(_ entry: Entry) throws {
        guard !failed, entry.items.allSatisfy({ $0.phase == .planned && $0.receipt == nil }),
              !entries.contains(where: { $0.id == entry.id }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries + [entry])
    }

    func destination(_ destinationID: UUID, in id: UUID, context: String, phase: Phase, conversationID: String? = nil) throws {
        try update(id, context: context) { entry in
            guard let index = entry.destinations.firstIndex(where: { $0.id == destinationID }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            let old = entry.destinations[index]
            guard old.kind == .contact, old.phase == .planned || old.phase == .submitted,
                  phase == .submitted || phase == .complete || phase == .failed,
                  phase != .submitted || old.phase == .planned else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entry.destinations[index].phase = phase; entry.destinations[index].conversationID = conversationID
        }
    }

    func progress(_ receipt: ChatForwardReceipt, in id: UUID, context: String) throws {
        try receipt.validate()
        try update(id, context: context) { entry in
            guard let index = entry.items.firstIndex(where: { $0.id == receipt.clientRequestID }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            let item = entry.items[index]
            guard item.phase == .planned || item.phase == .submitted || item.phase == .complete,
                  receipt.sourceMessageID == item.source.messageID, receipt.sourceConversationID == item.source.conversationID,
                  receipt.sourceThreadID == item.source.threadID, receipt.contentDigest == item.source.digest,
                  receipt.targets.map(\.conversationID) == entry.targetIDs else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            if let old = item.receipt {
                guard old.currentUserID == receipt.currentUserID, old.submittedAt == receipt.submittedAt,
                      !old.acknowledged || receipt.acknowledged,
                      zip(old.targets, receipt.targets).allSatisfy({ a, b in
                          a.baselineMessageIDs == b.baselineMessageIDs && a.latestBaselineDate == b.latestBaselineDate
                              && (a.confirmedMessageID == nil || a.confirmedMessageID == b.confirmedMessageID)
                      }) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            } else {
                guard item.phase == .planned, !receipt.acknowledged else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            }
            entry.items[index].receipt = receipt
            entry.items[index].phase = receipt.isComplete ? .complete : .submitted
        }
    }

    func failItem(_ itemID: UUID, in id: UUID, context: String) throws {
        try update(id, context: context) { entry in
            guard let index = entry.items.firstIndex(where: { $0.id == itemID }),
                  entry.items[index].phase == .planned || (entry.items[index].phase == .submitted && entry.items[index].receipt?.acknowledged == false)
            else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            entry.items[index].phase = .failed
        }
    }

    func cancelRemaining(_ id: UUID, context: String) throws {
        guard !isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try update(id, context: context, requiresExecution: false) { entry in
            for index in entry.items.indices where entry.items[index].phase == .planned { entry.items[index].phase = .cancelled }
            for index in entry.destinations.indices where entry.destinations[index].phase == .planned { entry.destinations[index].phase = .cancelled }
        }
    }
    func remove(_ id: UUID, context: String) throws {
        guard let entry = entry(id, in: context), !entry.hasUnfinished, !isExecuting(id) else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try persist(entries.filter { $0.id != id })
    }

    private func update(_ id: UUID, context: String, requiresExecution: Bool = true, change: (inout Entry) throws -> Void) throws {
        guard !failed, !requiresExecution || isExecuting(id), let index = entries.firstIndex(where: { $0.id == id && $0.context == context })
        else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        var updated = entries; try change(&updated[index]); try persist(updated)
    }
    private func persist(_ value: [Entry]) throws {
        guard !failed else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
        try validate(value)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: value)).write(
                to: root.appendingPathComponent("forwarding-v1.json"), options: [.atomic, .completeFileProtection])
            entries = value
        } catch { failed = true; throw error }
    }

    private func validate(_ entries: [Entry]) throws {
        func validID(_ value: String) -> Bool { !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func numericID(_ value: String) -> Bool { Int(value).map { $0 > 0 && String($0) == value } == true }
        var identities: Set<UUID> = [], occupied: Set<String> = []
        for entry in entries {
            guard identities.insert(entry.id).inserted, !entry.context.isEmpty, entry.createdAt.timeIntervalSince1970.isFinite,
                  !entry.items.isEmpty, !entry.destinations.isEmpty,
                  Set(entry.items.map { $0.source.conversationID }).count == 1,
                  Set(entry.items.map { $0.source.messageID }).count == entry.items.count,
                  Set(entry.destinations.map { $0.kind.rawValue + ":" + $0.referenceID }).count == entry.destinations.count
            else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            for destination in entry.destinations {
                guard identities.insert(destination.id).inserted, validID(destination.referenceID),
                      (destination.phase == .complete) == (destination.conversationID != nil),
                      destination.conversationID.map({ numericID($0) && $0 != entry.items[0].source.conversationID }) ?? true,
                      destination.kind != .conversation || (destination.phase == .complete && destination.referenceID == destination.conversationID)
                else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            }
            for item in entry.items {
                let source = item.source
                guard identities.insert(item.id).inserted, validID(source.messageID), validID(source.conversationID), validID(source.senderID),
                      source.threadID.map(validID) ?? true, source.sentAt.timeIntervalSince1970.isFinite,
                      source.editedAt?.timeIntervalSince1970.isFinite ?? true,
                      source.digest.count == 64, source.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
                else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                if item.phase == .planned || item.phase == .submitted {
                    // JSON 编码组合身份避免分隔符碰撞，不保存用户内容。
                    let key = try JSONEncoder().encode([entry.context, source.conversationID, source.messageID]).base64EncodedString()
                    guard occupied.insert(key).inserted else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                }
                if let receipt = item.receipt {
                    try receipt.validate()
                    guard item.phase != .planned && item.phase != .cancelled,
                          receipt.clientRequestID == item.id, receipt.sourceConversationID == source.conversationID,
                          receipt.sourceMessageID == source.messageID, receipt.sourceThreadID == source.threadID,
                          receipt.contentDigest == source.digest, receipt.targets.map(\.conversationID) == entry.targetIDs,
                          (item.phase == .complete) == receipt.isComplete,
                          item.phase != .failed || !receipt.acknowledged else { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
                } else if item.phase == .submitted || item.phase == .complete { throw MobileTransferRecoveryStore.StoreError.invalidRecord }
            }
        }
    }
}
