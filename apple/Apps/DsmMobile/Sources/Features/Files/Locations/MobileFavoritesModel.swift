import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import Observation

protocol MobileFavoriteServing: AnyObject, Sendable {
    var profileID: UUID { get }
    func listFavoritesPage(offset: Int, limit: Int) async throws -> FileFavoritePage
    func getInfo(paths: [String]) async throws -> [FileItem]
    func addFavoriteResult(path: String, name: String) async throws -> MutationResult
    func removeFavoriteResult(path: String) async throws -> MutationResult
}
extension DsmFileRepository: MobileFavoriteServing {}

/// 收藏只改变快捷入口。未知写保留原目标，刷新只读，不自动重发。
@MainActor
@Observable
final class MobileFavoritesModel {
    struct Pending: Codable, Equatable, Identifiable {
        let id: UUID
        let profileID: UUID
        let context: String
        let path: String
        let name: String
        let removing: Bool
    }
    private struct Recovery: Codable { let version: Int; let entries: [Pending] }
    static let snapshotLimit = 5_000
    private(set) var context = ""
    private(set) var busy = false
    private(set) var recoveryFailed = false
    private(set) var feedback: String?
    @ObservationIgnored var onChanged: ((String) async -> Void)?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var repository: (any MobileFavoriteServing)?
    @ObservationIgnored private var repositoryID: ObjectIdentifier?
    private var profileID: UUID?
    private var generation = 0
    private var records: [Pending] = []

    init(rootURL: URL? = nil) {
        root = rootURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobileFavorites-\(UUID())")
        let file = root.appendingPathComponent("favorites-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let value = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: file))
                guard value.version == 1, Set(value.entries.map(\.id)).count == value.entries.count,
                      value.entries.allSatisfy({ !$0.context.isEmpty && Self.validPath($0.path) && !$0.name.isEmpty }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                records = value.entries
            } catch { recoveryFailed = true }
        }
    }

    var pending: [Pending] { records.filter { $0.context == context && $0.profileID == profileID } }
    var available: Bool { repository != nil && !busy && !recoveryFailed }
    func isBlocked(_ path: String) -> Bool { pending.contains { $0.path == path } }
    func clearFeedback() { feedback = nil }

    func configure(profile: NasProfile?, repository: (any MobileFavoriteServing)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier } ?? ""
        let identity = repository.map(ObjectIdentifier.init)
        guard next != context || identity != repositoryID else { return }
        generation &+= 1; context = next; profileID = profile?.id; repositoryID = identity
        self.repository = profile?.id == repository?.profileID ? repository : nil
        busy = false; feedback = nil
    }

    @discardableResult
    func setFavorite(path: String, name: String, removing: Bool) async -> Bool {
        guard available, Self.validPath(path), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isBlocked(path), let profileID, let repository else { return false }
        let token = generation, operationContext = context
        busy = true; feedback = nil
        defer { if token == generation { busy = false } }
        let entry: Pending
        do {
            let page = try await repository.listFavoritesPage(offset: 0, limit: Self.snapshotLimit)
            guard token == generation, !Task.isCancelled else { return false }
            let existing = page.locations.first { $0.path == path }
            if removing ? existing == nil && Self.isComplete(page) : existing != nil {
                feedback = L10n.string(removing ? "ui.25400251730cea8a" : "ui.f8f147eae9ef4058")
                await onChanged?(operationContext); return token == generation
            }
            guard existing != nil || Self.isComplete(page) else {
                feedback = L10n.string("mobile.favorites.incomplete"); return false
            }
            if removing {
                guard existing?.name == name else { feedback = L10n.string("mobile.favorites.changed"); return false }
            } else {
                let items = try await repository.getInfo(paths: [path])
                guard token == generation, !Task.isCancelled else { return false }
                guard items.contains(where: { $0.profileID == profileID && $0.path == path }) else {
                    feedback = L10n.string("mobile.favorites.changed"); return false
                }
            }
            entry = Pending(id: UUID(), profileID: profileID, context: operationContext, path: path, name: removing ? name : name.trimmingCharacters(in: .whitespacesAndNewlines), removing: removing)
            records.append(entry)
            guard persist() else { feedback = L10n.string("mobile.favorites.recovery-error"); return false }
        } catch {
            if token == generation { feedback = Self.message(error) }; return false
        }
        do {
            let result: MutationResult
            if removing { result = try await repository.removeFavoriteResult(path: path) }
            else { result = try await repository.addFavoriteResult(path: path, name: name) }
            if !result.requiresRefresh {
                finish(entry)
                guard token == generation else { return false }
                feedback = L10n.string(result.status == .confirmedSuccess
                    ? removing ? "ui.25400251730cea8a" : "ui.f8f147eae9ef4058"
                    : result.localizationKey ?? "mobile.favorites.save-error")
                await onChanged?(operationContext)
                return result.status == .confirmedSuccess && token == generation
            }
        } catch {
            // 共享结果接口仅在提交前抛错，传输未知由结果对象表达。
            finish(entry)
            if token == generation { feedback = Self.message(error) }
            return false
        }
        let resolved = await resolve(entry, repository: repository)
        guard token == generation else { return false }
        feedback = L10n.string(resolved ? removing ? "ui.25400251730cea8a" : "ui.f8f147eae9ef4058" : "mobile.favorites.pending")
        await onChanged?(operationContext)
        return resolved && token == generation
    }

    func refreshPending() async {
        guard !busy, let repository, !pending.isEmpty else { return }
        let token = generation, entries = pending
        busy = true
        defer { if token == generation { busy = false } }
        for entry in entries {
            _ = await resolve(entry, repository: repository)
            guard token == generation else { return }
        }
        feedback = pending.isEmpty ? nil : L10n.string("mobile.favorites.pending")
    }

    func removeProfile(_ id: UUID) {
        let old = records; records.removeAll { $0.profileID == id }
        if !persist() { records = old }
        if profileID == id { configure(profile: nil, repository: nil) }
    }

    private func resolve(_ entry: Pending, repository: any MobileFavoriteServing) async -> Bool {
        guard let page = try? await repository.listFavoritesPage(offset: 0, limit: Self.snapshotLimit) else { return false }
        let current = page.locations.first { $0.path == entry.path }
        let matches = entry.removing ? current == nil && Self.isComplete(page) : current?.name == entry.name
        if matches { finish(entry) }
        return matches
    }
    private static func isComplete(_ page: FileFavoritePage) -> Bool { !page.hasMore && !page.isTruncated && page.offset == 0 }
    private func finish(_ entry: Pending) {
        let old = records; records.removeAll { $0.id == entry.id }
        if !persist() { records = old }
    }
    private func persist() -> Bool {
        guard !recoveryFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var location = root, values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            try JSONEncoder().encode(Recovery(version: 1, entries: records)).write(to: root.appendingPathComponent("favorites-v1.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { recoveryFailed = true; return false }
    }
    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && !path.hasSuffix("/") && !path.contains("//") && !path.contains("\\")
            && path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." && $0.caseInsensitiveCompare("#recycle") != .orderedSame }
    }
    private static func message(_ error: Error) -> String {
        (error as? AppError)?.safeUserMessage ?? L10n.string("mobile.favorites.save-error")
    }
}
