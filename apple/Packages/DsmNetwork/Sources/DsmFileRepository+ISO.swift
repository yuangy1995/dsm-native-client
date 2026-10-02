import DsmCore
import DsmLocalization
import Foundation

extension DsmFileRepository {
    public func changeISOMount(_ change: FileISOMountChange) async throws -> MutationResult {
        try await requireAdvancedFileWrite()
        let path = change.mountPoint
        guard path.hasPrefix("/"), path.split(separator: "/").count >= 2,
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw Self.advancedFileError() }
        try reserveRemoteMountPaths([path])
        defer { activeRemoteMountPaths.remove(path) }
        let inventory = try await remoteMountInventory()
        guard let isoConnections = inventory.isoConnections, inventory.isISOMountingEnabled == true else {
            throw Self.advancedFileError(.apiUnavailable, "files.advanced.unavailable")
        }
        guard !inventory.connections.contains(where: { Self.isoPathsOverlap($0.mountPoint, path) }) else {
            throw Self.advancedFileError(.conflict, "files.iso.targetChanged")
        }
        let api: String
        let method: String
        let parameters: [String: DsmParameterValue]
        switch change {
        case .mount(let request):
            guard request.source.profileID == profileID, request.destination.profileID == profileID,
                  request.source.kind == .file, request.source.fileExtension?.lowercased() == "iso",
                  request.destination.isDirectory, !Self.isoPathsOverlap(request.source.path, path),
                  !isoConnections.contains(where: { Self.isoPathsOverlap($0.mountPoint, path) }) else {
                throw Self.advancedFileError(.conflict, "files.iso.targetChanged")
            }
            let current = try await getInfo(paths: [request.source.path, path])
            guard let source = current.first(where: { $0.path == request.source.path }),
                  let destination = current.first(where: { $0.path == path }),
                  source.kind == request.source.kind, source.sizeBytes == request.source.sizeBytes,
                  source.times?.modifiedAt == request.source.times?.modifiedAt, source.permissions?.canRead == true,
                  destination.isDirectory, destination.mountPointType == "normal", destination.permissions?.canWrite == true else {
                throw Self.advancedFileError(.conflict, "files.iso.targetChanged")
            }
            let page = try await listFolder(path: path, offset: 0, limit: 1)
            guard page.total == 0, page.items.isEmpty, !page.hasMore else {
                throw Self.advancedFileError(.conflict, "files.iso.emptyFolderRequired")
            }
            api = DsmAPIName.fileStationMount; method = "mount_iso"
            parameters = ["source": .string(source.path), "mount_point": .string(path),
                          "auto_mount": .boolean(request.automaticMount), "user_set": .boolean(true)]
        case .unmount(let expected):
            guard expected.profileID == profileID, isoConnections.contains(expected),
                  !isoConnections.contains(where: { $0.mountPoint != path && Self.isoPathsOverlap($0.mountPoint, path) }),
                  let current = try await getInfo(paths: [path]).first, current.path == path, current.isDirectory,
                  let type = current.mountPointType, type != "normal", type != "shared_folder" else {
                throw Self.advancedFileError(.conflict, "files.iso.targetChanged")
            }
            api = DsmAPIName.fileStationMountList; method = "unmount"
            parameters = ["mount_point": .stringArray([path])]
        }
        guard let capability = capabilities[api], capability.selectedVersion == 1 else {
            throw Self.advancedFileError(.apiUnavailable, "files.advanced.unavailable")
        }
        try Task.checkCancellation()
        pendingISOChanges[path] = change
        do {
            try await client.callVoid(path: capability.path, api: api, version: 1, method: method,
                requestFormat: capability.requestFormat, parameters: parameters, credential: credential)
        } catch let error as DsmNetworkError {
            if case .api = error {
                pendingISOChanges.removeValue(forKey: path)
                return try Self.isoResult(DsmErrorMapper.map(error).category == .permissionDenied ? .permissionDenied : .confirmedFailure)
            }
            if case .invalidRequest = error {
                pendingISOChanges.removeValue(forKey: path)
                throw DsmErrorMapper.map(error)
            }
        } catch { /* 传输或取消结果未知，只读取当前状态，不重放。 */ }
        if Task.isCancelled { return try Self.isoResult(.cancellationRequestedAfterSubmission) }
        return try await reviewISOMountCore(change)
    }

    public func reviewISOMount(_ change: FileISOMountChange) async throws -> MutationResult {
        guard !activeRemoteMountPaths.contains(where: { Self.isoPathsOverlap($0, change.mountPoint) }) else {
            throw Self.advancedFileError(.conflict, "files.advanced.pendingChange")
        }
        activeRemoteMountPaths.insert(change.mountPoint)
        defer { activeRemoteMountPaths.remove(change.mountPoint) }
        return try await reviewISOMountCore(change)
    }

    private func reviewISOMountCore(_ change: FileISOMountChange) async throws -> MutationResult {
        guard pendingISOChanges[change.mountPoint] == change else {
            throw Self.advancedFileError(.conflict, "files.iso.targetChanged")
        }
        do {
            let inventory = try await remoteMountInventory()
            guard let mounts = inventory.isoConnections else { return try Self.isoResult(.submittedButUnverified) }
            let entries = try await getInfo(paths: [change.mountPoint])
            guard entries.count == 1, let directory = entries.first, directory.path == change.mountPoint,
                  directory.isDirectory, let type = directory.mountPointType else { return try Self.isoResult(.submittedButUnverified) }
            let verified: Bool
            switch change {
            case .mount(let request):
                verified = mounts.contains(.init(profileID: profileID, source: request.source.path,
                    mountPoint: change.mountPoint, automaticMount: request.automaticMount))
                    && type != "normal" && type != "shared_folder"
            case .unmount:
                verified = !mounts.contains { $0.mountPoint == change.mountPoint }
                    && !inventory.connections.contains { $0.mountPoint == change.mountPoint } && type == "normal"
            }
            if verified { pendingISOChanges.removeValue(forKey: change.mountPoint) }
            return try Self.isoResult(verified ? .confirmedSuccess : .submittedButUnverified)
        } catch { return try Self.isoResult(.submittedButUnverified) }
    }

    private static func isoPathsOverlap(_ first: String, _ second: String) -> Bool {
        first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }
    private static func isoResult(_ status: MutationResultStatus) throws -> MutationResult {
        let success = status == .confirmedSuccess
        let unknown = status == .submittedButUnverified || status == .cancellationRequestedAfterSubmission
        return try MutationResult(status: status, operation: "isoMount", submitted: true, requiresRefresh: unknown,
            counts: .init(succeeded: success ? 1 : 0, failed: success || unknown ? 0 : 1, unknown: unknown ? 1 : 0),
            diagnosticTag: "file-station.iso-mount")
    }
}
