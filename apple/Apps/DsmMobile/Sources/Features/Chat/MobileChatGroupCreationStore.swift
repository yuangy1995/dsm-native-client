import DsmCore
import Foundation
import Observation

/// 建群草稿与分步回执独立保存，完成后删除；不保存凭据，不以群名恢复归属。
@MainActor
@Observable
final class MobileChatGroupCreationStore {
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let context: String
        let title: String
        let memberIDs: [String]
        let createdAt: Date
        var receipt: ChatGroupCreateReceipt?

        func draft() throws -> ChatGroupDraft {
            try ChatGroupDraft(clientRequestID: id, title: title, memberIDs: memberIDs, isEncrypted: false)
        }
    }
    private struct Envelope: Codable { let version: Int; let entries: [Entry] }
    private let root: URL
    private(set) var entries: [Entry] = []
    private(set) var failed = false
    private var executing: Set<UUID> = []

    init(root: URL?) {
        self.root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("ChatGroupCreation-\(UUID())")
        do {
            if FileManager.default.fileExists(atPath: self.root.path),
               try self.root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true { throw invalid() }
            let url = self.root.appendingPathComponent("group-creations-v1.json")
            if FileManager.default.fileExists(atPath: url.path) {
                let value = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: url))
                guard value.version == 1 else { throw invalid() }
                try validate(value.entries); entries = value.entries
            }
        } catch { failed = true }
    }

    func entry(_ id: UUID, in context: String) -> Entry? { entries.first { $0.id == id && $0.context == context } }
    func isBusy(in context: String) -> Bool { entries.contains { $0.context == context && executing.contains($0.id) } }
    func begin(_ id: UUID, in context: String) -> Bool {
        guard !failed, !isBusy(in: context), entry(id, in: context) != nil else { return false }
        return executing.insert(id).inserted
    }
    func end(_ id: UUID) { executing.remove(id) }

    func matching(_ draft: ChatGroupDraft, in context: String) -> Entry? {
        entries.first { $0.context == context && $0.title == draft.title && $0.memberIDs == draft.memberIDs }
    }

    func reserve(_ entry: Entry) throws {
        guard entry.receipt == nil, !isBusy(in: entry.context), matching(try entry.draft(), in: entry.context) == nil else { throw invalid() }
        try persist(entries + [entry])
    }

    func record(_ receipt: ChatGroupCreateReceipt, in context: String) throws {
        guard executing.contains(receipt.clientRequestID),
              let index = entries.firstIndex(where: { $0.id == receipt.clientRequestID && $0.context == context }) else { throw invalid() }
        try receipt.validate()
        let entry = entries[index]
        guard receipt.matches(try entry.draft()) else { throw invalid() }
        if let old = entry.receipt {
            guard receipt.hasSameIdentity(as: old), receipt.revision >= old.revision,
                  receipt.revision != old.revision || receipt == old,
                  old.candidateConversationID == nil || receipt.candidateConversationID == old.candidateConversationID,
                  old.create != .completed || receipt.create == .completed,
                  old.join != .completed || receipt.join == .completed,
                  old.invite != .completed || receipt.invite == .completed else { throw invalid() }
        } else {
            guard receipt.revision == 0, receipt.create == .submitted, receipt.candidateConversationID == nil else { throw invalid() }
        }
        var updated = entries; updated[index].receipt = receipt
        try persist(updated)
    }

    /// 只有明确完成、明确未创建或创建被拒绝才能释放草稿；部分完成继续保留。
    func finish(_ entry: Entry, outcome: ChatConversationCreateOutcome) throws {
        guard executing.contains(entry.id), let current = self.entry(entry.id, in: entry.context),
              outcome.clientRequestID == entry.id else { throw invalid() }
        switch outcome.result.status {
        case .confirmedSuccess:
            guard let receipt = current.receipt, let conversation = outcome.confirmedConversation,
                  receipt.candidateConversationID == conversation.id, conversation.kind == .group, !conversation.isEncrypted,
                  receipt.titleDigest == ChatMessageSendReceipt.digest(text: conversation.title),
                  receipt.create == .completed, receipt.join == .completed, receipt.invite == .completed else { throw invalid() }
        case .cancelledBeforeSubmission:
            guard !outcome.result.submitted, current.receipt?.candidateConversationID == nil else { throw invalid() }
        case .permissionDenied, .unsupported, .confirmedFailure:
            guard current.receipt == nil || current.receipt?.create == .rejected else { throw invalid() }
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            guard current.receipt != nil else { throw invalid() }
            return
        }
        try persist(entries.filter { $0.id != entry.id })
    }

    func discardPrepared(_ entry: Entry) throws {
        guard self.entry(entry.id, in: entry.context)?.receipt == nil,
              self.entry(entry.id, in: entry.context) != nil, !isBusy(in: entry.context) else { throw invalid() }
        try persist(entries.filter { $0.id != entry.id })
    }

    private func validate(_ values: [Entry]) throws {
        guard Set(values.map(\.id)).count == values.count else { throw invalid() }
        for entry in values {
            let draft = try entry.draft()
            guard !entry.context.isEmpty, entry.createdAt.timeIntervalSince1970.isFinite,
                  draft.title == entry.title, draft.memberIDs == entry.memberIDs,
                  values.filter({ $0.context == entry.context && $0.title == entry.title && $0.memberIDs == entry.memberIDs }).count == 1 else { throw invalid() }
            if let receipt = entry.receipt {
                try receipt.validate()
                guard receipt.matches(draft) else { throw invalid() }
            }
        }
    }

    private func persist(_ values: [Entry]) throws {
        guard !failed else { throw invalid() }
        try validate(values)
        do {
            try MobileTransferRecoveryStore.prepareDirectory(root)
            try JSONEncoder().encode(Envelope(version: 1, entries: values)).write(
                to: root.appendingPathComponent("group-creations-v1.json"), options: [.atomic, .completeFileProtection])
            entries = values
        } catch { failed = true; throw error }
    }

    private func invalid() -> Error { MobileTransferRecoveryStore.StoreError.invalidRecord }
}
