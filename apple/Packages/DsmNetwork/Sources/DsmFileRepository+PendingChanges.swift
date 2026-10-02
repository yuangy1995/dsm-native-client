import DsmCore

extension DsmFileRepository {
    public func pendingFileStationChanges() async -> [FileStationPendingChange] {
        var changes = pendingFilePermissions.map { key, value in
            FileStationPendingChange(id: key, kind: .permissions, target: value.change.baseline.target.path)
        }
        changes += pendingISOChanges.map { key, value in .init(id: "iso:" + key, kind: .iso, target: value.mountPoint) }
        changes += pendingFileVFS.map { key, value in
            let target: String
            switch value.change {
            case .create(let configuration): target = configuration.alias
            case .createCloud(let identity): target = identity.alias
            case .update(_, let configuration): target = configuration.alias
            case .connect(let profile), .disconnect(let profile), .removeSavedProfile(let profile), .reauthorize(let profile): target = profile.alias
            }
            return .init(id: key, kind: .connection, target: target)
        }
        changes += pendingFileStationSettings.map { key, value in
            switch value {
            case .general: .init(id: key, kind: .general)
            case .mountAccess: .init(id: key, kind: .mountAccess)
            case .mountAccount(let baseline, _): .init(id: key, kind: .mountAccess, target: baseline.name)
            case .bandwidth(let baseline, _): .init(id: key, kind: .bandwidth, target: baseline.name)
            case .theme: .init(id: key, kind: .theme)
            }
        }
        return changes.sorted { $0.id < $1.id }
    }

    public func reviewPendingFileStationChange(id: String) async throws -> MutationResult {
        if let pending = pendingFilePermissions[id] { return try await reviewFilePermissions(pending.change) }
        if id.hasPrefix("iso:"), let change = pendingISOChanges[String(id.dropFirst(4))] { return try await reviewISOMount(change) }
        if let pending = pendingFileVFS[id] { return try await reviewFileVFS(pending.change) }
        if let change = pendingFileStationSettings[id] { return try await reviewFileStationSettings(change) }
        throw Self.advancedFileError(.conflict, "files.pending.noLongerPending")
    }
}
