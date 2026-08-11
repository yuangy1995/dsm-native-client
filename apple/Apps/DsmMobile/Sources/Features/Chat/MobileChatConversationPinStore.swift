import Foundation

protocol MobileChatConversationPinStore {
    func loadPinnedConversationIDs(profileID: UUID) -> [String]
    func savePinnedConversationIDs(_ conversationIDs: [String], profileID: UUID)
    func removePinnedConversationIDs(profileID: UUID)
}

struct UserDefaultsMobileChatConversationPinStore: MobileChatConversationPinStore {
    private let defaults: UserDefaults
    private let keyPrefix = "LanStash.MobileChat.PinnedConversations."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadPinnedConversationIDs(profileID: UUID) -> [String] {
        guard let data = defaults.data(forKey: key(profileID)) else { return [] }
        if let stored = try? JSONDecoder().decode(StoredPinnedConversations.self, from: data) {
            return stored.conversationIDs
        }
        if let legacy = try? JSONDecoder().decode([String].self, from: data) {
            return legacy
        }
        return []
    }

    func savePinnedConversationIDs(_ conversationIDs: [String], profileID: UUID) {
        let stored = StoredPinnedConversations(version: 1, conversationIDs: conversationIDs)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key(profileID))
    }

    func removePinnedConversationIDs(profileID: UUID) {
        defaults.removeObject(forKey: key(profileID))
    }

    private func key(_ profileID: UUID) -> String {
        keyPrefix + profileID.uuidString
    }

    private struct StoredPinnedConversations: Codable {
        let version: Int
        let conversationIDs: [String]
    }
}
