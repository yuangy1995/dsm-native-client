import DsmCore
import DsmLocalization
import FileProvider
import Foundation
import Observation
import OSLog

struct MobileFilesLocationState: Identifiable {
    let location: MobileFilesLocation
    let registered: Bool
    let systemEnabled: Bool
    let hasAccess: Bool
    let paused: Bool
    let editing: Bool
    let deleting: Bool
    let records: [DesktopDriveWritebackRecord]
    var id: UUID { location.id }
}

@MainActor @Observable
final class MobileFilesSettingsModel {
    private static let logger = Logger(subsystem: "io.github.qwertyuiop1995.dsmnativeclient.mobile", category: "FilesLocation")
    let locations: MobileFilesLocationStore
    let accounts: MobileExtensionAccountStore
    let domains: any MobileFilesDomainControlling
    private let currentProfile: () -> NasProfile?
    private(set) var rows: [MobileFilesLocationState] = []
    private(set) var loading = false
    private(set) var busy = false
    private(set) var hasLoaded = false
    var error: String?
    var addedLocation = false

    init(locations: MobileFilesLocationStore, accounts: MobileExtensionAccountStore,
         domains: any MobileFilesDomainControlling = MobileFilesDomainController(), currentProfile: @escaping () -> NasProfile?) {
        self.locations = locations; self.accounts = accounts; self.domains = domains; self.currentProfile = currentProfile
    }

    private func account() throws -> MobileExtensionAccount {
        guard let profile = currentProfile(), let account = try accounts.accounts().first(where: {
            $0.identity == MobileWorkspaceIdentity(profile) && $0.profile.pinnedCertificateSHA256 == profile.pinnedCertificateSHA256
        }) else { throw NSFileProviderError(.notAuthenticated) }
        return account
    }

    private func requireLocalAccess(_ location: MobileFilesLocation) throws {
        guard let profile = currentProfile(), MobileWorkspaceIdentity(profile) == location.identity,
              try locations.location(id: location.id) == location else { throw NSFileProviderError(.notAuthenticated) }
    }

    private func requireCurrent(_ location: MobileFilesLocation) throws {
        guard let profile = currentProfile(), MobileWorkspaceIdentity(profile) == location.identity,
              profile.pinnedCertificateSHA256 == location.profile.pinnedCertificateSHA256 else {
            throw NSFileProviderError(.notAuthenticated)
        }
        _ = try locations.requireCurrent(location, accounts: accounts)
    }

    func reload() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do { try await readRows(); error = nil; hasLoaded = true }
        catch { self.error = message(error); hasLoaded = false }
    }

    private func readRows() async throws {
        guard let profile = currentProfile() else { throw NSFileProviderError(.notAuthenticated) }
        let identity = MobileWorkspaceIdentity(profile)
        let registrations = try await domains.registrations()
        var result: [MobileFilesLocationState] = []
        for location in try locations.locations() where location.identity == identity {
            if registrations[location.id] != nil { try await domains.captureLocalChanges(location) }
            let store = try locations.configurationStore(id: location.id)
            let journal = try locations.writebackStore(id: location.id)
            let runtime = try await store.runtime(mappingID: location.id)
            result.append(.init(location: location, registered: registrations[location.id] != nil, systemEnabled: registrations[location.id] == true,
                hasAccess: (try? locations.requireCurrent(location, accounts: accounts)) != nil
                    && profile.pinnedCertificateSHA256 == location.profile.pinnedCertificateSHA256, paused: runtime.isManuallyPaused,
                editing: try journal.isEnabled(mappingID: location.id), deleting: try journal.isDeletionEnabled(mappingID: location.id),
                records: try journal.pendingRecords(mappingID: location.id)))
        }
        guard currentProfile().map(MobileWorkspaceIdentity.init) == identity else { throw NSFileProviderError(.notAuthenticated) }
        rows = result
    }

    func add() async {
        await perform {
            var stage = "account"
            do {
                let account = try self.account()
                stage = "reserve"
                let location = try self.locations.reserve(account: account)
                stage = "configuration"
                let store = try self.locations.configurationStore(id: location.id)
                if try await store.configuration(mappingID: location.id) == nil {
                    try await store.saveConnection(profile: account.connection.profile, capabilities: account.connection.capabilitySet)
                    try await store.saveMapping(location.mapping)
                    try await store.setMappingState(.available, mappingID: location.id)
                }
                stage = "account-recheck"
                try self.requireCurrent(location)
                stage = "registration-list"
                let isRegistered = try await self.domains.registrations()[location.id] != nil
                if !isRegistered {
                    stage = "registration-add"
                    try await self.domains.add(location)
                }
                stage = "account-recheck"
                try self.requireCurrent(location)
                stage = "registration-readback"
                guard try await self.domains.registrations()[location.id] != nil else { throw NSFileProviderError(.providerNotFound) }
                self.addedLocation = true
            } catch {
                Self.logFailure(error, stage: stage)
                throw error
            }
        }
    }

    func setPaused(_ paused: Bool, location: MobileFilesLocation) async {
        await perform {
            if paused { try self.requireLocalAccess(location) } else { try self.requireCurrent(location) }
            let store = try self.locations.configurationStore(id: location.id)
            try await store.setMappingPaused(paused, mappingID: location.id)
            if !paused {
                try await store.setMappingState(.available, mappingID: location.id)
                try await store.setProviderAvailable(true)
            }
            try await self.domains.signal(location)
        }
    }

    func setEditing(_ enabled: Bool, location: MobileFilesLocation) async {
        await changeAuthorization(location) { try $0.setEnabled(enabled, mappingID: location.id) }
    }

    func setDeleting(_ enabled: Bool, location: MobileFilesLocation) async {
        await changeAuthorization(location) { try $0.setDeletionEnabled(enabled, mappingID: location.id) }
    }

    private func changeAuthorization(_ location: MobileFilesLocation, requiresNetworkAccess: Bool = true, operation: (DesktopDriveWritebackStore) throws -> Void) async {
        await perform {
            if requiresNetworkAccess { try self.requireCurrent(location) } else { try self.requireLocalAccess(location) }
            let journal = try self.locations.writebackStore(id: location.id)
            do {
                let lease = try journal.lock(mappingID: location.id)
                defer { withExtendedLifetime(lease) {} }
                try operation(journal)
            }
            try await self.domains.signal(location)
        }
    }

    func retry(_ record: DesktopDriveWritebackRecord, location: MobileFilesLocation) async {
        await perform {
            try self.requireCurrent(location)
            let journal = try self.locations.writebackStore(id: location.id)
            do {
                let lease = try journal.lock(mappingID: location.id)
                defer { withExtendedLifetime(lease) {} }
                guard var current = try journal.pendingRecords(mappingID: location.id).first(where: { $0.id == record.id }),
                      try journal.isEnabled(mappingID: location.id),
                      try (!current.isDeletion || journal.isDeletionEnabled(mappingID: location.id)) else {
                    throw DesktopDriveWritebackError.disabled
                }
                current.allowOverwrite = true
                if current.phase == .conflict { current.phase = .prepared }
                try journal.save(current)
            }
            try await self.domains.recover(record, location: location)
        }
    }

    func exportURL(_ record: DesktopDriveWritebackRecord, location: MobileFilesLocation) throws -> URL {
        try requireLocalAccess(location)
        let journal = try locations.writebackStore(id: location.id)
        let lease = try journal.lock(mappingID: location.id)
        defer { withExtendedLifetime(lease) {} }
        guard let current = try journal.pendingRecords(mappingID: location.id).first(where: { $0.id == record.id }),
              let hash = current.contentHash else { throw DesktopDriveWritebackError.invalidItem }
        let url = try journal.contentURL(for: current)
        guard try DesktopDriveWritebackStore.hash(of: url) == hash else { throw DesktopDriveWritebackError.invalidItem }
        return url
    }

    func stop(_ record: DesktopDriveWritebackRecord, location: MobileFilesLocation, exportedCopy: Bool = false) async {
        await changeAuthorization(location, requiresNetworkAccess: false) { journal in
            guard let current = try journal.pendingRecords(mappingID: location.id).first(where: { $0.id == record.id }) else { return }
            guard current.contentHash == nil || exportedCopy else { throw DesktopDriveWritebackError.pendingChanges }
            try journal.keepLocally(current)
        }
    }

    func remove(_ location: MobileFilesLocation) async {
        await perform {
            try self.requireLocalAccess(location)
            let journal = try self.locations.writebackStore(id: location.id)
            try journal.requireNoPendingChanges(mappingID: location.id)
            let store = try self.locations.configurationStore(id: location.id)
            let runtime = try await store.runtime(mappingID: location.id)
            if (try? self.requireCurrent(location)) != nil, !runtime.isManuallyPaused,
               try await store.isProviderAvailable(), try await self.domains.registrations()[location.id] == true {
                try await self.domains.settle(location)
            }
            // 原账号或信任已失效时不能等候远端上传；只在用户接受本机副本丢失后移除。
            try self.requireLocalAccess(location)
            let lease = try journal.lock(mappingID: location.id)
            defer { withExtendedLifetime(lease) {} }
            try journal.requireNoPendingChanges(mappingID: location.id)
            // 先阻止新远端请求；系统移除失败时保持暂停，用户仍可明确恢复。
            try await store.setMappingPaused(true, mappingID: location.id)
            try await store.setProviderAvailable(false)
            try await self.domains.remove(location)
            guard try await self.domains.registrations()[location.id] == nil else { throw NSFileProviderError(.cannotSynchronize) }
            try self.locations.remove(location)
            // 不删除恢复目录；系统删除位置不等于允许清理尚未可见的本机资料。
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        var readingRows = false
        do {
            try await operation()
            readingRows = true
            try await readRows()
            hasLoaded = true
        } catch {
            if readingRows { Self.logFailure(error, stage: "rows-readback") }
            self.error = message(error)
            try? await readRows()
        }
    }

    private static func logFailure(_ error: Error, stage: String) {
        let issue = error as NSError
        // 只记录固定阶段与系统错误类别/码，不记录描述、userInfo、身份、地址或本机路径。
        logger.error("files-location failed stage=\(stage, privacy: .public) domain=\(issue.domain, privacy: .public) code=\(issue.code, privacy: .public)")
    }

    private func message(_ error: Error) -> String {
        if (error as? NSFileProviderError)?.code == .notAuthenticated { return L10n.string("mobile.extensions.sign-in-again") }
        if #available(iOS 17.1, *) {
            let issue = error as NSError
            let underlying = issue.userInfo[NSUnderlyingErrorKey] as? NSError
            // 系统可能在首次安装后尚未发现扩展；不能误导用户检查 NAS 或存储空间。
            if issue.domain == NSFileProviderErrorDomain,
               issue.code == NSFileProviderError.applicationExtensionNotFound.rawValue
                || (issue.code == NSFileProviderError.providerNotFound.rawValue
                    && underlying?.domain == NSFileProviderErrorDomain
                    && underlying?.code == NSFileProviderError.applicationExtensionNotFound.rawValue) {
                return L10n.string("mobile.files-location.extension-unavailable")
            }
        }
        if let failure = error as? DesktopDriveWritebackError, failure == .pendingChanges || failure == .busy {
            return L10n.string("mobile.files-location.pending-error")
        }
        return L10n.string("mobile.files-location.error")
    }
}
