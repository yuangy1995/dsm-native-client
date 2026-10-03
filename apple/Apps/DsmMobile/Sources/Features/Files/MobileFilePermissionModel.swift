import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import Observation

/// 权限写沿用共享 Repository；抛错仅表示提交前拒绝，已提交的未知结果只能读取。
protocol MobileFilePermissionServing: Sendable {
    var profileID: UUID { get }
    func loadFilePermissions(_ item: FileItem) async throws -> FilePermissionSnapshot
    func loadFileStationAdvancedAccess() async throws -> FileStationAdvancedAccess
    func listFileStationPrincipals(prefix: String, offset: Int, limit: Int) async throws -> FileStationPrincipalPage
    func changeFilePermissions(_ change: FilePermissionChange) async throws -> MutationResult
    func reviewFilePermissions(_ change: FilePermissionChange) async throws -> MutationResult
}

extension DsmFileRepository: MobileFilePermissionServing {}

@MainActor
@Observable
final class MobileFilePermissionModel {
    enum PickerRole { case rule, owner, group }
    private struct PendingTarget: Codable, Hashable {
        let profileID: UUID
        let context: String
        let path: String
    }
    private struct Recovery: Codable { let version: Int; let targets: Set<PendingTarget> }

    private(set) var snapshot: FilePermissionSnapshot?
    private(set) var access: FileStationAdvancedAccess?
    private(set) var loading = false
    private(set) var busy = false
    private(set) var error: String?
    private(set) var result: MutationResult?
    private(set) var recoveryFailed = false
    private(set) var pendingConfirmation: FilePermissionChange?
    @ObservationIgnored var onPermissionsChanged: ((String) async -> Void)?
    var rules: [FileACLRule] = []
    var mode = "000"
    var owner: FileStationPrincipal?
    var group: FileStationPrincipal?
    var recursive = false

    @ObservationIgnored private let root: URL
    @ObservationIgnored private var repository: (any MobileFilePermissionServing)?
    @ObservationIgnored private var identity: ObjectIdentifier?
    private var profileID: UUID?
    private var context = ""
    private var generation: UInt64 = 0
    private var needsReload = false
    private var blocked: Set<PendingTarget> = []
    @ObservationIgnored private var submitted: [PendingTarget: FilePermissionChange] = [:]

    init(rootURL: URL? = nil) {
        root = rootURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobilePermissions-\(UUID())")
        let file = root.appendingPathComponent("permissions-v1.json")
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                let recovery = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: file))
                guard recovery.version == 1,
                      recovery.targets.allSatisfy({ !$0.context.isEmpty && $0.path.hasPrefix("/") }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                blocked = recovery.targets
            }
        } catch { recoveryFailed = true }
    }

    func configure(profile: NasProfile?, repository: (any MobileFilePermissionServing)?) {
        let nextContext = profile.map { MobileWorkspaceIdentity($0).storageIdentifier } ?? ""
        let nextIdentity = repository.map { ObjectIdentifier($0 as AnyObject) }
        guard nextContext != context || nextIdentity != identity else { return }
        generation &+= 1
        profileID = profile?.id; context = nextContext; identity = nextIdentity
        self.repository = repository?.profileID == profile?.id ? repository : nil
        snapshot = nil; access = nil; loading = false; busy = false; error = nil; result = nil
        pendingConfirmation = nil; submitted = [:]; resetDraft()
        needsReload = false
    }

    var hasChanges: Bool {
        guard let snapshot else { return false }
        return rules != snapshot.rules.filter { $0.level == 0 } || mode != (snapshot.posixMode ?? "000")
            || owner != nil || group != nil
    }
    var isBlocked: Bool { targetKey.map(blocked.contains) == true }
    var permitsChanges: Bool {
        snapshot?.canChangePermissions == true || snapshot?.owner?.canChange == true && access?.isAdministrator == true
    }
    var canEdit: Bool {
        return !loading && !busy && !isBlocked && !needsReload && !recoveryFailed && access?.writesEnabled == true
            && permitsChanges
    }
    var canSave: Bool { canEdit && draft != nil }
    var canChangeOwner: Bool {
        canEdit && access?.isAdministrator == true && (snapshot?.isACL != true || snapshot?.owner?.canChange == true)
    }
    var canChangeGroup: Bool { canEdit && access?.isAdministrator == true && snapshot?.isACL == false }
    var canReview: Bool { !busy && targetKey.flatMap { submitted[$0] } != nil }
    var changedNames: [String] {
        guard let snapshot else { return [] }
        let original = snapshot.rules.filter { $0.level == 0 }
        return Array(Set(original.filter { !rules.contains($0) }.map(\.ownerName)
            + rules.filter { !original.contains($0) }.map(\.ownerName))).sorted()
    }
    var removesAccess: Bool {
        guard let snapshot else { return false }
        if !snapshot.isACL, let old = Int(snapshot.posixMode ?? "", radix: 8), let new = Int(mode, radix: 8) {
            return old & ~new != 0
        }
        let original = snapshot.rules.filter { $0.level == 0 }
        if original.contains(where: { old in !rules.contains { Self.sameAccount($0, old) } }) { return true }
        return rules.contains { rule in
            guard let old = original.first(where: { Self.sameAccount($0, rule) }) else { return rule.effect == .deny }
            return rule.effect != old.effect || rule.inheritance != old.inheritance
                || (rule.effect == .allow ? !old.rights.isSubset(of: rule.rights) : !rule.rights.isSubset(of: old.rights))
        }
    }

    func load(_ item: FileItem) async {
        guard !busy, let repository, item.profileID == profileID else { return }
        generation &+= 1; let request = generation
        loading = true; error = nil; pendingConfirmation = nil
        snapshot = nil; access = nil; result = nil
        defer { if request == generation { loading = false } }
        do {
            let loaded = try await repository.loadFilePermissions(item)
            let access = try? await repository.loadFileStationAdvancedAccess()
            guard request == generation, loaded.target.profileID == profileID, loaded.target.path == item.path else { return }
            snapshot = loaded; self.access = access; needsReload = false; resetDraft()
            result = nil
        } catch {
            guard request == generation else { return }
            snapshot = nil; access = nil; self.error = Self.message(for: error)
        }
    }

    func requestConfirmation() {
        guard canSave else { return }
        pendingConfirmation = draft
    }
    func cancelConfirmation() { pendingConfirmation = nil }

    func confirmChanges() async {
        guard canSave, let confirmed = pendingConfirmation, confirmed == draft, let repository,
              let key = targetKey else { pendingConfirmation = nil; return }
        pendingConfirmation = nil
        let change = FilePermissionChange(baseline: confirmed.baseline, explicitRules: confirmed.explicitRules,
            posixMode: confirmed.posixMode, owner: confirmed.owner, group: confirmed.group, recursive: confirmed.recursive,
            confirmedScope: confirmed.recursive, confirmedOwner: confirmed.owner != nil || confirmed.group != nil,
            confirmedAccessRemoval: true)
        blocked.insert(key)
        guard persist() else { return }
        submitted[key] = change
        await perform(change, key: key, repository: repository, review: false)
    }

    func refresh(_ item: FileItem) async {
        if let key = targetKey, let change = submitted[key], let repository, !busy {
            await perform(change, key: key, repository: repository, review: true)
        } else { await load(item) }
    }

    func principals(prefix: String, offset: Int) async throws -> FileStationPrincipalPage {
        guard let repository else { throw CancellationError() }
        let request = generation
        let page = try await repository.listFileStationPrincipals(prefix: prefix, offset: offset, limit: 200)
        guard request == generation else { throw CancellationError() }
        return page
    }

    func apply(_ principals: Set<FileStationPrincipal>, role: PickerRole) {
        guard canEdit, !principals.isEmpty else { return }
        switch role {
        case .rule:
            guard snapshot?.isACL == true, snapshot?.canChangePermissions == true else { return }
            for principal in principals.sorted(by: { $0.id < $1.id }) where !rules.contains(where: {
                $0.ownerType == principal.kind.rawValue && $0.ownerName == principal.name
            }) {
                rules.append(.init(ownerType: principal.kind.rawValue, ownerName: principal.name, effect: .allow,
                    rights: [.readData, .readAttributes, .readExtendedAttributes, .readPermissions], inheritance: [.thisFolder]))
            }
        case .owner:
            guard canChangeOwner, principals.count == 1, let value = principals.first,
                  snapshot?.isACL == true || value.kind == .user else { error = L10n.string("files.permissions.chooseOne"); return }
            owner = value
        case .group:
            guard canChangeGroup, principals.count == 1, let value = principals.first, value.kind == .group else {
                error = L10n.string("files.permissions.chooseOne"); return
            }
            group = value
        }
        error = nil
    }

    func removeProfile(_ id: UUID) {
        let original = blocked
        blocked = blocked.filter { $0.profileID != id }
        if !persist() { blocked = original }
        if profileID == id { configure(profile: nil, repository: nil) }
    }

    private var draft: FilePermissionChange? {
        guard let snapshot, hasChanges, rules.allSatisfy({ $0.level == 0 }), rules.count <= 200,
              snapshot.isACL || mode.utf8.count == 3 && mode.utf8.allSatisfy({ (48...55).contains($0) }),
              !recursive || snapshot.target.isDirectory,
              owner == nil || canChangeOwner, group == nil || canChangeGroup,
              rules == snapshot.rules.filter({ $0.level == 0 }) || snapshot.canChangePermissions,
              mode == (snapshot.posixMode ?? "000") || snapshot.canChangePermissions else { return nil }
        return .init(baseline: snapshot,
            explicitRules: snapshot.isACL && rules != snapshot.rules.filter { $0.level == 0 } ? rules : nil,
            posixMode: !snapshot.isACL && mode != snapshot.posixMode ? mode : nil,
            owner: owner, group: group, recursive: recursive,
            confirmedScope: false, confirmedOwner: false, confirmedAccessRemoval: false)
    }
    private var targetKey: PendingTarget? {
        guard let profileID, let snapshot else { return nil }
        return .init(profileID: profileID, context: context, path: snapshot.target.path)
    }
    private func resetDraft() {
        rules = snapshot?.rules.filter { $0.level == 0 } ?? []; mode = snapshot?.posixMode ?? "000"
        owner = nil; group = nil; recursive = false
    }
    private func perform(_ change: FilePermissionChange, key: PendingTarget,
                         repository: any MobileFilePermissionServing, review: Bool) async {
        guard !busy else { return }
        busy = true; error = nil; let request = generation
        defer { if request == generation { busy = false } }
        do {
            let outcome = try await (review ? repository.reviewFilePermissions(change) : repository.changeFilePermissions(change))
            if !outcome.requiresRefresh {
                let previous = blocked; blocked.remove(key)
                if !persist() { blocked = previous }
                submitted[key] = nil
            }
            guard request == generation else { return }
            result = outcome
            if outcome.status == .confirmedSuccess {
                // 已保存的结果保持可见；新的编辑必须以读取到的新权限为基线。
                let refreshed = try? await repository.loadFilePermissions(change.baseline.target)
                guard request == generation else { return }
                if let refreshed, refreshed.target.profileID == key.profileID, refreshed.target.path == key.path {
                    snapshot = refreshed; resetDraft()
                }
                else { needsReload = true; error = L10n.string("mobile.permissions.load-error") }
            }
            if outcome.submitted { await onPermissionsChanged?(key.context) }
        } catch {
            if !review {
                let previous = blocked; blocked.remove(key)
                if !persist() { blocked = previous }
                submitted[key] = nil
            }
            guard request == generation else { return }
            self.error = Self.message(for: error)
        }
    }
    private func persist() -> Bool {
        guard !recoveryFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var location = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            try JSONEncoder().encode(Recovery(version: 1, targets: blocked)).write(
                to: root.appendingPathComponent("permissions-v1.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { recoveryFailed = true; return false }
    }
    private static func sameAccount(_ lhs: FileACLRule, _ rhs: FileACLRule) -> Bool {
        lhs.ownerType == rhs.ownerType && lhs.ownerName == rhs.ownerName && lhs.ownerID == rhs.ownerID
    }
    private static func message(for error: Error) -> String {
        guard let error = error as? AppError else { return L10n.string("mobile.permissions.load-error") }
        if error.category == .conflict { return L10n.string("mobile.permissions.conflict") }
        return error.safeUserMessage
    }
}
