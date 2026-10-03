import CryptoKit
import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import Observation

protocol MobileFileSettingsServing: AnyObject, Sendable {
    var profileID: UUID { get }
    func listShares(offset: Int, limit: Int) async throws -> FilePage
    func listFolder(path: String, offset: Int, limit: Int) async throws -> FilePage
    func loadFileStationAdvancedAccess() async throws -> FileStationAdvancedAccess
    func loadFileStationSettings() async throws -> FileStationSettings
    func loadFileStationMountAccess() async throws -> FileStationMountAccessScope
    func loadFileStationMountDirectories() async throws -> FileStationMountDirectories
    func listFileStationMountAccounts(source: FileStationMountAccountSource, kind: FileStationPrincipal.Kind, query: String, offset: Int, limit: Int) async throws -> FileStationMountAccountPage
    func listFileStationPolicyAccounts(kind: FileStationPrincipal.Kind, query: String, offset: Int, limit: Int) async throws -> FileStationPolicyAccountPage
    func listFileStationBandwidth(ownerType: FileStationBandwidthEntry.OwnerType, offset: Int, limit: Int) async throws -> FileStationBandwidthPage
    func loadFileStationSharingTheme() async throws -> FileStationSharingTheme
    func changeFileStationSettings(_ change: FileStationSettingsChange, confirmed: Bool) async throws -> MutationResult
    func reviewFileStationSettings(_ change: FileStationSettingsChange) async throws -> MutationResult
    func listFileStationThemeImages(kind: FileStationThemeImage.Kind) async throws -> [FileStationThemeImage]
    func loadFileStationThemeImage(_ image: FileStationThemeImage) async throws -> Data
    func uploadFileStationThemeImage(data: Data, filename: String, kind: FileStationThemeImage.Kind, confirmed: Bool) async throws -> FileStationThemeImage
}
extension DsmFileRepository: MobileFileSettingsServing {}

/// 不保存设置快照或图片。重启后只保留原目标限制，不能凭当前值猜测上次请求归属。
@MainActor @Observable
final class MobileFileSettingsModel {
    struct Pending: Codable, Equatable, Identifiable {
        let id: UUID
        let profileID: UUID
        let context: String
        let target: String
    }
    private struct Recovery: Codable { let version: Int; let entries: [Pending] }
    private(set) var context = ""
    private(set) var activation = UUID()
    private(set) var access: FileStationAdvancedAccess?
    private(set) var busy = false
    private(set) var recoveryFailed = false
    private(set) var feedback: String?
    private(set) var feedbackTarget: String?
    @ObservationIgnored var onChanged: ((String) async -> Void)?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var repository: (any MobileFileSettingsServing)?
    @ObservationIgnored private var repositoryID: ObjectIdentifier?
    @ObservationIgnored private var submitted: [UUID: FileStationSettingsChange] = [:]
    private var records: [Pending] = []
    private var profileID: UUID?

    init(rootURL: URL? = nil) {
        root = rootURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobileFileSettings-\(UUID())")
        let file = root.appendingPathComponent("settings-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let value = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: file))
                guard value.version == 1, Set(value.entries.map(\.id)).count == value.entries.count,
                      value.entries.allSatisfy({ !$0.context.isEmpty && !$0.target.isEmpty }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                records = value.entries
            } catch { recoveryFailed = true }
        }
    }

    var pending: [Pending] { records.filter { $0.context == context && $0.profileID == profileID } }
    var canWrite: Bool { repository != nil && access?.isAdministrator == true && access?.writesEnabled == true && !busy && !recoveryFailed }
    func isBlocked(_ target: String) -> Bool { pending.contains { $0.target == target } }
    func canReview(_ target: String) -> Bool { !busy && pending.contains { $0.target == target && submitted[$0.id] != nil } }
    func configure(profile: NasProfile?, repository: (any MobileFileSettingsServing)?) {
        let context = profile.map { MobileWorkspaceIdentity($0).storageIdentifier } ?? ""
        let identity = repository.map(ObjectIdentifier.init)
        guard self.context != context || repositoryID != identity else { return }
        activation = UUID(); self.context = context; profileID = profile?.id; repositoryID = identity
        self.repository = repository?.profileID == profile?.id ? repository : nil
        access = nil; busy = false; feedback = nil; feedbackTarget = nil; submitted = [:]
    }

    func read<T: Sendable>(_ body: (any MobileFileSettingsServing) async throws -> T) async throws -> T {
        guard let repository else { throw CancellationError() }
        let token = activation
        do {
            let value = try await body(repository)
            guard token == activation, !Task.isCancelled else { throw CancellationError() }
            return value
        } catch {
            guard token == activation, !Task.isCancelled else { throw CancellationError() }
            throw error
        }
    }
    func loadAccess() async {
        let token = activation
        let value = try? await read { try await $0.loadFileStationAdvancedAccess() }
        if token == activation { access = value }
    }

    @discardableResult
    func save(_ change: FileStationSettingsChange, acceptedRisk: Bool = false, expectedActivation: UUID? = nil) async -> Bool {
        let target = Self.target(change)
        guard expectedActivation == nil || expectedActivation == activation,
              canWrite, !isBlocked(target), Self.profile(change) == profileID,
              Self.risks(change).isEmpty || acceptedRisk, let repository, let profileID else { return false }
        let token = activation, entry = Pending(id: UUID(), profileID: profileID, context: context, target: target)
        busy = true; feedback = nil; feedbackTarget = target
        defer { if token == activation { busy = false } }
        records.append(entry)
        guard persist() else { feedback = L10n.string("mobile.file-settings.recovery-error"); return false }
        submitted[entry.id] = change
        do {
            let result = try await repository.changeFileStationSettings(change, confirmed: true)
            let success = apply(result, entry: entry, token: token)
            if token == activation { await onChanged?(entry.context) }
            return success && token == activation
        } catch {
            // 该接口只在未提交时抛错；提交后的未知统一通过 MutationResult 返回。
            finish(entry)
            if token == activation { feedback = Self.message(error) }
            return false
        }
    }

    @discardableResult
    func refresh(_ target: String) async -> Bool {
        guard !busy, let repository, let entry = pending.first(where: { $0.target == target }),
              let change = submitted[entry.id] else { return false }
        let token = activation; busy = true; feedbackTarget = target
        defer { if token == activation { busy = false } }
        do {
            let result = try await repository.reviewFileStationSettings(change)
            let success = apply(result, entry: entry, token: token)
            if token == activation { await onChanged?(entry.context) }
            return success && token == activation
        } catch {
            // 回读失败不得解除原写限制，尤其是断线重连后的 Repository 已无原回执时。
            if token == activation { feedback = L10n.string("mobile.file-settings.pending") }
            return false
        }
    }

    func upload(data: Data, filename: String, kind: FileStationThemeImage.Kind) async -> FileStationThemeImage? {
        let target = Self.uploadTarget(data: data, kind: kind)
        guard canWrite, !isBlocked(target), let repository, let profileID else { return nil }
        let token = activation, entry = Pending(id: UUID(), profileID: profileID, context: context, target: target)
        busy = true; feedback = nil; feedbackTarget = target
        defer { if token == activation { busy = false } }
        records.append(entry)
        guard persist() else { feedback = L10n.string("mobile.file-settings.recovery-error"); return nil }
        do {
            let image = try await repository.uploadFileStationThemeImage(data: data, filename: filename, kind: kind, confirmed: true)
            finish(entry)
            guard token == activation else { return nil }
            return image
        } catch {
            // 上传可能在发送后、读取历史时抛错；保留摘要，选择历史图片可继续应用主题。
            if token == activation { feedback = L10n.string("mobile.file-settings.upload-pending") }
            return nil
        }
    }

    func removeProfile(_ id: UUID) {
        let old = records; records.removeAll { $0.profileID == id }
        if !persist() { records = old }
        if profileID == id { configure(profile: nil, repository: nil) }
    }
    private func apply(_ result: MutationResult, entry: Pending, token: UUID) -> Bool {
        if !result.requiresRefresh { finish(entry) }
        guard token == activation else { return false }
        feedback = L10n.string(result.requiresRefresh ? "mobile.file-settings.pending" : result.status == .confirmedSuccess
            ? "files.settings.saved" : "mobile.file-settings.save-error")
        return result.status == .confirmedSuccess
    }
    private func finish(_ entry: Pending) {
        let old = records; records.removeAll { $0.id == entry.id }
        if persist() { submitted.removeValue(forKey: entry.id) } else { records = old }
    }
    private func persist() -> Bool {
        guard !recoveryFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var url = root, values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
            try JSONEncoder().encode(Recovery(version: 1, entries: records)).write(to: root.appendingPathComponent("settings-v1.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { recoveryFailed = true; return false }
    }
    static func target(_ change: FileStationSettingsChange) -> String {
        switch change {
        case .general: "general"
        case .mountAccess: "mountAccess"
        case .mountAccount(let row, _): "mountAccount:" + digest(row.source.id + ":" + row.id.kind.rawValue + ":" + String(row.id.value))
        case .bandwidth(let row, _): "bandwidth:" + digest(row.id)
        case .theme: "theme"
        }
    }
    static func uploadTarget(data: Data, kind: FileStationThemeImage.Kind) -> String { "upload:" + kind.rawValue + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func profile(_ change: FileStationSettingsChange) -> UUID? {
        switch change {
        case .general(let old, let new): old.profileID == new.profileID ? old.profileID : nil
        case .mountAccess(_, _, let id): id
        case .mountAccount(let row, _): row.profileID
        case .bandwidth(let old, let new): old.profileID == new.profileID ? old.profileID : nil
        case .theme(let old, let new): old.profileID == new.profileID ? old.profileID : nil
        }
    }
    static func risks(_ change: FileStationSettingsChange) -> [String] {
        switch change {
        case .general(let old, let new):
            var keys: [String] = []
            if widens(old.sharing, new.sharing) || new.sharing == .selected && !new.sharingAccounts.isSubset(of: old.sharingAccounts) { keys.append("mobile.file-settings.risk-sharing") }
            if widens(old.fileRequests, new.fileRequests) || new.fileRequests == .selected && !new.requestAccounts.isSubset(of: old.requestAccounts) { keys.append("mobile.file-settings.risk-requests") }
            if widens(old.remoteMounts, new.remoteMounts) { keys.append("mobile.file-settings.risk-mount") }
            if widens(old.isoMounts, new.isoMounts) { keys.append("mobile.file-settings.risk-iso") }
            if !old.showsAccounts && new.showsAccounts { keys.append("mobile.file-settings.risk-accounts") }
            return keys
        case .mountAccess(let old, let new, _):
            return old != new && (new == .everyone || old == .administrators) ? ["mobile.file-settings.risk-mount"] : []
        case .mountAccount(let old, let enabled): return !old.enabled && enabled ? ["mobile.file-settings.risk-mount"] : []
        default: return []
        }
    }
    private static func widens(_ old: FileStationAccessScope, _ new: FileStationAccessScope) -> Bool { old != new && (new == .everyone || old == .administrators) }
    static func message(_ error: Error) -> String {
        if let error = error as? AppError {
            if error.category == .permissionDenied { return error.safeUserMessage }
            if error.category == .conflict { return L10n.string("mobile.file-settings.changed") }
        }
        return L10n.string("mobile.file-settings.save-error")
    }
}
