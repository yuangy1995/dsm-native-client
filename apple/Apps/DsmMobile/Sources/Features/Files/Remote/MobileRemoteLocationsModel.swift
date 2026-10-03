import CryptoKit
import DsmCore
import DsmFileFeature
import DsmLocalization
import DsmNetwork
import Foundation
import Observation

protocol MobileRemoteLocationServing: AnyObject, Sendable {
    var profileID: UUID { get }
    var allowsRemoteMountManagement: Bool { get }
    func loadFileStationAdvancedAccess() async throws -> FileStationAdvancedAccess
    func remoteMountInventory() async throws -> RemoteMountInventory
    func createRemoteMount(_ configuration: RemoteMountConfiguration) async throws
    func updateRemoteMount(expectedConnection: RemoteMountConnection, configuration: RemoteMountConfiguration) async throws
    func removeRemoteMount(expectedConnection: RemoteMountConnection) async throws
    func pendingRemoteMountOperations() async -> [RemoteMountOperation]
    func reviewRemoteMountOperation(id: UUID) async throws -> RemoteMountOperation?
    func continueRemoteMountOperation(id: UUID, password: String, confirmed: Bool) async throws -> RemoteMountOperation?
    func abandonRemoteMountOperation(id: UUID, confirmed: Bool) async throws -> RemoteMountOperation?
    func changeISOMount(_ change: FileISOMountChange) async throws -> MutationResult
    func reviewISOMount(_ change: FileISOMountChange) async throws -> MutationResult
    func getInfo(paths: [String]) async throws -> [FileItem]
    func listFileVFSProtocols() async throws -> [FileVFSProtocol]
    func listFileVFSProfiles() async throws -> [FileVFSProfile]
    func loadFileVFSDetail(_ profile: FileVFSProfile) async throws -> FileVFSDetail
    func listFileVFSFolder(_ profile: FileVFSProfile, path: String, offset: Int, limit: Int) async throws -> FilePage
    func changeFileVFS(_ change: FileVFSChange, password: String?, confirmed: Bool) async throws -> MutationResult
    func reviewFileVFS(_ change: FileVFSChange) async throws -> MutationResult
    func prepareFileVFSCloudAuthorization(protocolID: String) async throws -> FileVFSCloudAuthorizationRequest
    func authorizeFileVFS(_ change: FileVFSChange, authorization: FileVFSCloudAuthorization, confirmed: Bool) async throws -> MutationResult
}
extension DsmFileRepository: MobileRemoteLocationServing {}

@MainActor
@Observable
final class MobileRemoteLocationsModel {
    struct Pending: Codable, Identifiable, Equatable {
        enum Kind: String, Codable { case mount, iso, vfs }
        let id: UUID
        let profileID: UUID
        let context: String
        let kind: Kind
        let targets: Set<String>
    }
    private struct Recovery: Codable { let version: Int; let entries: [Pending] }
    enum MountChange {
        case create(RemoteMountSetup)
        case update(RemoteMountConnection, RemoteMountSetup)
        case disconnect(RemoteMountConnection)
        var targets: Set<String> {
            switch self {
            case .create(let setup): [setup.mountPoint]
            case .update(let old, let setup): [old.mountPoint, setup.mountPoint]
            case .disconnect(let old): [old.mountPoint]
            }
        }
    }

    private(set) var inventory: RemoteMountInventory?
    private(set) var profiles: [FileVFSProfile] = []
    private(set) var protocols: [FileVFSProtocol] = []
    private(set) var access: FileStationAdvancedAccess?
    private(set) var mountError: String?
    private(set) var vfsError: String?
    private(set) var error: String?
    private(set) var feedback: String?
    private(set) var loading = false
    private(set) var busy = false
    private(set) var recoveryFailed = false
    private(set) var context = ""
    private(set) var mountOperations: [UUID: RemoteMountOperation] = [:]
    @ObservationIgnored var onLocationsChanged: ((String) async -> Void)?
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var repository: (any MobileRemoteLocationServing)?
    @ObservationIgnored private var repositoryID: ObjectIdentifier?
    private var profileID: UUID?
    private var generation: UInt64 = 0
    private var records: [Pending] = []
    @ObservationIgnored private var vfsChanges: [UUID: FileVFSChange] = [:]
    @ObservationIgnored private var isoChanges: [UUID: FileISOMountChange] = [:]

    init(rootURL: URL? = nil) {
        root = rootURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("MobileRemoteLocations-\(UUID())")
        let file = root.appendingPathComponent("remote-locations-v1.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let saved = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: file))
                guard saved.version == 1, Set(saved.entries.map(\.id)).count == saved.entries.count,
                      saved.entries.allSatisfy({ !$0.context.isEmpty && !$0.targets.isEmpty }) else {
                    throw MobileTransferRecoveryStore.StoreError.invalidRecord
                }
                records = saved.entries
            } catch { recoveryFailed = true }
        }
    }

    func configure(profile: NasProfile?, repository: (any MobileRemoteLocationServing)?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier } ?? ""
        let identity = repository.map(ObjectIdentifier.init)
        guard next != context || identity != repositoryID else { return }
        generation &+= 1; context = next; profileID = profile?.id; repositoryID = identity
        self.repository = profile?.id == repository?.profileID ? repository : nil
        inventory = nil; profiles = []; protocols = []; access = nil
        mountError = nil; vfsError = nil; error = nil; feedback = nil; loading = false; busy = false
        mountOperations = [:]; vfsChanges = [:]; isoChanges = [:]
    }
    var pending: [Pending] { records.filter { $0.context == context && $0.profileID == profileID } }
    var canManageMounts: Bool {
        !busy && !loading && !recoveryFailed && repository?.allowsRemoteMountManagement == true
            && inventory != nil
    }
    var canCreateMounts: Bool { canManageMounts && inventory?.isRemoteMountingEnabled == true }
    var canManageISO: Bool { !busy && !loading && !recoveryFailed && access?.writesEnabled == true && inventory?.isISOMountingEnabled == true }
    var canManageVFS: Bool { !busy && !loading && !recoveryFailed && access?.writesEnabled == true && vfsError == nil }
    var available: Bool { repository != nil }

    func load() async {
        guard !busy, !loading, let repository else { return }
        let token = generation; loading = true
        defer { if token == generation { loading = false } }
        let mounts: Result<RemoteMountInventory, Error>
        let connections: Result<[FileVFSProfile], Error>
        do { mounts = .success(try await repository.remoteMountInventory()) } catch { mounts = .failure(error) }
        do { connections = .success(try await repository.listFileVFSProfiles()) } catch { connections = .failure(error) }
        let services = try? await repository.listFileVFSProtocols()
        let access = try? await repository.loadFileStationAdvancedAccess()
        guard token == generation else { return }
        switch mounts {
        case .success(let value) where value.profileID == profileID: inventory = value; mountError = nil
        case .success: inventory = nil; mountError = L10n.string("mobile.remote.load-error")
        case .failure(let error): inventory = nil; mountError = Self.message(error)
        }
        switch connections {
        case .success(let value) where value.allSatisfy({ $0.profileID == profileID }): profiles = value; vfsError = nil
        case .success: profiles = []; vfsError = L10n.string("mobile.remote.load-error")
        case .failure(let error): profiles = []; vfsError = Self.message(error)
        }
        protocols = services ?? []; self.access = access
    }

    func isMountBlocked(_ paths: Set<String>) -> Bool {
        pending.contains { $0.kind != .vfs && $0.targets.contains { old in paths.contains { Self.overlap(old, $0) } } }
    }
    func isVFSBlocked(_ change: FileVFSChange) -> Bool {
        pending.contains { $0.kind == .vfs && !$0.targets.isDisjoint(with: Self.vfsTargets(change)) }
    }
    func canReview(_ entry: Pending) -> Bool {
        mountOperations[entry.id] != nil || vfsChanges[entry.id] != nil || isoChanges[entry.id] != nil
    }
    func clearFeedback() { error = nil; feedback = nil }

    func destination(_ path: String) async throws -> FileItem {
        guard let repository else { throw CancellationError() }
        let token = generation
        guard let item = try await repository.getInfo(paths: [path]).first(where: { $0.path == path }),
              token == generation, item.profileID == profileID, item.isDirectory else { throw CancellationError() }
        return item
    }
    func detail(_ profile: FileVFSProfile) async throws -> FileVFSDetail {
        guard let repository, profile.profileID == profileID else { throw CancellationError() }
        let token = generation, value = try await repository.loadFileVFSDetail(profile)
        guard token == generation else { throw CancellationError() }; return value
    }
    func prepareCloud(_ protocolID: String) async throws -> FileVFSCloudAuthorizationRequest {
        guard canManageVFS, let repository else { throw CancellationError() }
        let token = generation, request = try await repository.prepareFileVFSCloudAuthorization(protocolID: protocolID)
        guard token == generation, request.profileID == profileID else { throw CancellationError() }; return request
    }

    /// SMB/NFS 的抛错可能发生在提交后，必须先读取原 Repository 的阶段，不能直接释放目标。
    @discardableResult
    func changeMount(_ change: MountChange, password: String = "", confirmed: Bool) async -> Bool {
        guard confirmed, canManageMounts, !isMountBlocked(change.targets), let repository,
              let entry = reserve(kind: .mount, targets: change.targets) else { return false }
        if case .disconnect = change {}
        else if !canCreateMounts { finish(entry); return false }
        let token = generation; busy = true; clearFeedback()
        do {
            switch change {
            case .create(let setup): try await repository.createRemoteMount(setup.configuration(password: password))
            case .update(let old, let setup): try await repository.updateRemoteMount(expectedConnection: old, configuration: setup.configuration(password: password))
            case .disconnect(let old): try await repository.removeRemoteMount(expectedConnection: old)
            }
            finish(entry)
            guard token == generation else { return false }
            busy = false; feedback = L10n.string("mobile.remote.saved")
            await reloadAfterChange(entry.context); return token == generation
        } catch {
            let operations = await repository.pendingRemoteMountOperations()
            let operation = operations.first { $0.profileID == entry.profileID && $0.affectedPaths == entry.targets }
            if operation == nil { finish(entry) }
            guard token == generation else { return false }
            busy = false
            if let operation { mountOperations[entry.id] = operation; feedback = L10n.string("mobile.remote.pending") }
            else { self.error = Self.message(error) }
            return false
        }
    }

    @discardableResult
    func changeISO(_ change: FileISOMountChange) async -> Bool {
        guard canManageISO, !isMountBlocked([change.mountPoint]), let repository,
              let entry = reserve(kind: .iso, targets: [change.mountPoint]) else { return false }
        isoChanges[entry.id] = change
        return await perform(entry, repository: repository) { try await repository.changeISOMount(change) }
    }

    @discardableResult
    func changeVFS(_ raw: FileVFSChange, password: String? = nil,
                   authorization: FileVFSCloudAuthorization? = nil, confirmedCleartext: Bool = false) async -> Bool {
        guard canManageVFS, let repository else { return false }
        let change: FileVFSChange
        do {
            switch raw {
            case .create(let draft):
                let value = try FileVFSForm.configuration(draft, protocols: protocols)
                guard !FileVFSForm.usesCleartext(value) || confirmedCleartext else { return false }
                change = .create(value)
            case .update(let old, let draft):
                let value = try FileVFSForm.configuration(draft, protocols: protocols, editingProtocol: old.profile.protocolID)
                guard !FileVFSForm.usesCleartext(value) || confirmedCleartext else { return false }
                change = .update(baseline: old, configuration: value)
            default: change = raw
            }
        } catch { self.error = Self.message(error); return false }
        guard !isVFSBlocked(change), let entry = reserve(kind: .vfs, targets: Self.vfsTargets(change)) else { return false }
        vfsChanges[entry.id] = change
        return await perform(entry, repository: repository) {
            if let authorization { return try await repository.authorizeFileVFS(change, authorization: authorization, confirmed: true) }
            return try await repository.changeFileVFS(change, password: password, confirmed: true)
        }
    }

    func review(_ entry: Pending) async {
        guard pending.contains(entry), !busy, let repository else { return }
        if let operation = mountOperations[entry.id] {
            await continueMount(entry, operation: operation, password: "", action: .review, repository: repository)
        } else if let change = isoChanges[entry.id] {
            _ = await perform(entry, repository: repository, review: true) { try await repository.reviewISOMount(change) }
        } else if let change = vfsChanges[entry.id] {
            _ = await perform(entry, repository: repository, review: true) { try await repository.reviewFileVFS(change) }
        } else { await load() }
    }
    enum Continuation { case review, resume, abandon }
    func continueMount(_ entry: Pending, password: String, action: Continuation, confirmed: Bool) async {
        guard confirmed, pending.contains(entry), !busy, !recoveryFailed, let repository,
              let operation = mountOperations[entry.id], operation.stage.canContinue else { return }
        await continueMount(entry, operation: operation, password: password, action: action, repository: repository)
    }
    private func continueMount(_ entry: Pending, operation: RemoteMountOperation, password: String,
                               action: Continuation, repository: any MobileRemoteLocationServing) async {
        let token = generation; busy = true; clearFeedback()
        do {
            let next: RemoteMountOperation?
            switch action {
            case .review: next = try await repository.reviewRemoteMountOperation(id: operation.id)
            case .resume: next = try await repository.continueRemoteMountOperation(id: operation.id, password: password, confirmed: true)
            case .abandon: next = try await repository.abandonRemoteMountOperation(id: operation.id, confirmed: true)
            }
            guard let next, next.id == operation.id, next.profileID == entry.profileID else { throw CancellationError() }
            if next.stage.isTerminal { finish(entry) }
            guard token == generation else { return }
            busy = false; mountOperations[entry.id] = next.stage.isTerminal ? nil : next
            feedback = L10n.string(next.stage == .completed ? "mobile.remote.saved" : next.stage == .cancelled
                ? "mobile.remote.remaining-ended" : "mobile.remote.pending")
            if next.stage.isTerminal { await reloadAfterChange(entry.context) }
        } catch {
            let current = await repository.pendingRemoteMountOperations().first { $0.id == operation.id }
            guard token == generation else { return }
            busy = false; if let current { mountOperations[entry.id] = current }
            self.error = Self.message(error)
        }
    }

    func removeProfile(_ id: UUID) {
        let old = records; records.removeAll { $0.profileID == id }
        if !persist() { records = old }
        if profileID == id { configure(profile: nil, repository: nil) }
    }

    private func perform(_ entry: Pending, repository: any MobileRemoteLocationServing, review: Bool = false,
                         operation: () async throws -> MutationResult) async -> Bool {
        let token = generation; busy = true; clearFeedback()
        do {
            let result = try await operation()
            if !result.requiresRefresh { finish(entry) }
            guard token == generation else { return false }
            busy = false
            feedback = L10n.string(result.status == .confirmedSuccess ? "mobile.remote.saved"
                : result.requiresRefresh ? "mobile.remote.pending" : result.localizationKey ?? "mobile.remote.save-error")
            if result.status == .confirmedSuccess { await reloadAfterChange(entry.context); return token == generation }
        } catch {
            // ISO/VFS 共享层仅在提交前抛错；提交后的未知由 MutationResult 表达。
            if !review { finish(entry) }
            guard token == generation else { return false }
            busy = false; self.error = Self.message(error)
        }
        return false
    }
    private func reloadAfterChange(_ context: String) async {
        await load()
        if context == self.context { await onLocationsChanged?(context) }
    }
    private func reserve(kind: Pending.Kind, targets: Set<String>) -> Pending? {
        guard let profileID, !context.isEmpty, !targets.isEmpty, !recoveryFailed else { return nil }
        let entry = Pending(id: UUID(), profileID: profileID, context: context, kind: kind, targets: targets)
        records.append(entry)
        guard persist() else { return nil }; return entry
    }
    private func finish(_ entry: Pending) {
        let old = records; records.removeAll { $0.id == entry.id }
        if !persist() { records = old }
        mountOperations[entry.id] = nil; isoChanges[entry.id] = nil; vfsChanges[entry.id] = nil
    }
    private func persist() -> Bool {
        guard !recoveryFailed else { return false }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var location = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            try JSONEncoder().encode(Recovery(version: 1, entries: records)).write(
                to: root.appendingPathComponent("remote-locations-v1.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { recoveryFailed = true; return false }
    }
    private static func overlap(_ left: String, _ right: String) -> Bool {
        left == right || left.hasPrefix(right + "/") || right.hasPrefix(left + "/")
    }
    private static func vfsTargets(_ change: FileVFSChange) -> Set<String> {
        switch change {
        case .create(let value):
            return [fingerprint([value.protocolID, value.hostname.lowercased(), String(value.port), value.account, value.folder]),
                    fingerprint(["alias", value.alias])]
        case .createCloud(let value): return [fingerprint([value.protocolID, value.account]), fingerprint(["alias", value.alias])]
        case .update(let old, let desired): return ["id:" + old.profile.id, fingerprint(["alias", old.profile.alias]), fingerprint(["alias", desired.alias])]
        case .reauthorize(let old), .connect(let old), .disconnect(let old), .removeSavedProfile(let old): return ["id:" + old.id, fingerprint(["alias", old.alias])]
        }
    }
    private static func fingerprint(_ values: [String]) -> String {
        SHA256.hash(data: (try? JSONEncoder().encode(values)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    static func message(_ error: Error) -> String {
        if let error = error as? FileVFSForm.ValidationError { return L10n.string(error.resourceKey) }
        if let error = error as? AppError {
            if error.category == .conflict { return L10n.string("mobile.remote.changed") }
            return error.safeUserMessage
        }
        return L10n.string("mobile.remote.load-error")
    }
}
