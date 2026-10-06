import DsmCore
import DsmNetwork
import Foundation

struct MobileModuleAccessSnapshot: Sendable {
    var allowed: Set<MobileModule> = []
    var lookupFailed = false
}

/// 只读取既有权限摘要和 Photos 访问设置，不用业务列表试探套件权限。
struct MobileModuleAccessReader: Sendable {
    let capabilities: CapabilitySet
    let readPrivileges: @Sendable () async throws -> DsmDesktopAppPrivileges
    let readPhotoAccess: @Sendable () async throws -> Void

    func read() async -> MobileModuleAccessSnapshot {
        var result = MobileModuleAccessSnapshot()
        do {
            result.allowed = Self.resolve(try await readPrivileges(), capabilities: capabilities)
        } catch {
            result.lookupFailed = true
            if Task.isCancelled || Self.stopsFurtherReads(error) { return result }
        }
        guard !Task.isCancelled else { return .init(lookupFailed: true) }
        if MobileModule.photos.isAvailable(in: capabilities) {
            do {
                try await readPhotoAccess()
                result.allowed.insert(.photos)
            } catch {
                if let error = error as? AppError,
                   [.permissionDenied, .apiUnavailable, .versionUnsupported].contains(error.category) {
                    result.allowed.remove(.photos)
                } else { result.lookupFailed = true }
            }
        }
        return result
    }

    static func resolve(_ privileges: DsmDesktopAppPrivileges, capabilities: CapabilitySet) -> Set<MobileModule> {
        let mappings: [(MobileModule, DsmDesktopApplication)] = [
            (.chat, .chat), (.downloads, .downloads), (.virtualMachines, .virtualMachines),
            (.containers, .containers), (.nasSettings, .nasSettings)
        ]
        return Set(mappings.compactMap { module, application in
            let allowed = module == .nasSettings
                ? privileges.isAdministrator && privileges.applications[application] != false
                : privileges.applications[application] == true
            return allowed && module.isAvailable(in: capabilities) ? module : nil
        })
    }

    private static func stopsFurtherReads(_ error: Error) -> Bool {
        if error is CancellationError || error is DsmCertificateTrustError { return true }
        guard let error = error as? AppError else { return false }
        return [.tlsUntrusted, .tlsCertificateChanged, .cancelled, .authenticationRequired].contains(error.category)
    }
}

extension MobileAppModel {
    func configureModuleAccess(_ reader: MobileModuleAccessReader) {
        resetModuleAccess()
        moduleAccessReader = reader
        moduleAccessTask = Task { [weak self] in await self?.refreshModuleAccess() }
    }

    func resetModuleAccess() {
        moduleAccessGeneration &+= 1
        moduleAccessTask?.cancel()
        moduleAccessTask = nil
        moduleAccessReader = nil
        availableOptionalModules = []
        isLoadingModuleAccess = false
        moduleAccessLookupFailed = false
    }

    func refreshModuleAccess() async {
        guard !Task.isCancelled, isConnected, !isLoadingModuleAccess, let reader = moduleAccessReader else { return }
        let generation = moduleAccessGeneration
        isLoadingModuleAccess = true
        let snapshot = await reader.read()
        guard generation == moduleAccessGeneration, !Task.isCancelled, isConnected else {
            if generation == moduleAccessGeneration { isLoadingModuleAccess = false }
            return
        }
        availableOptionalModules = snapshot.allowed
        if !isModuleVisible(.chat) { chatModel.deactivate() }
        if !isModuleVisible(.containers) { containerControls.deactivate(); containerImagePulls.deactivate(); containerImageDeletions.deactivate(); containerNetworks.deactivate(); containerInventoryModel.deactivate() }
        moduleAccessLookupFailed = snapshot.lookupFailed
        isLoadingModuleAccess = false
        if !isModuleVisible(selectedModule) { selectModule(.settings) }
    }
}
