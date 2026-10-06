import DsmCore
import DsmLocalization
import Foundation

/// 检查点失败不属于 NAS 的响应，不能被通用提交/恢复分支吞掉。
struct PackageInstallationCheckpointFailure: Error {
    let underlying: Error
}

extension DsmNasAdministrationRepository {
    public func startPackageInstallation(planID: UUID, volumes: [String: String], startAfterInstall: Bool) async throws -> NasPackageInstallProgress {
        try await startPackageInstallationChecked(planID: planID, volumes: volumes, startAfterInstall: startAfterInstall, checkpoint: nil)
    }

    public func startPackageInstallation(planID: UUID, volumes: [String: String], startAfterInstall: Bool,
        checkpoint: @escaping NasPackageInstallationObserver) async throws -> NasPackageInstallProgress {
        do { return try await startPackageInstallationChecked(planID: planID, volumes: volumes, startAfterInstall: startAfterInstall, checkpoint: checkpoint) }
        catch let failure as PackageInstallationCheckpointFailure { throw failure.underlying }
    }

    private func startPackageInstallationChecked(planID: UUID, volumes: [String: String], startAfterInstall: Bool,
        checkpoint: NasPackageInstallationObserver?) async throws -> NasPackageInstallProgress {
        try requirePackageInstallationIdle()
        guard let saved = packageInstallPlan, saved.plan.id == planID else { throw packageCenterError("package.center.changed") }
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        _ = try await loadPackageCatalog(management: checkpoint != nil)
        let requested = try saved.requestedIDs.map { id in
            guard let candidate = packageCatalogCandidates[id] else { throw packageCenterError("package.center.changed") }
            return candidate
        }
        let fresh = try await buildPackageInstallPlan(requested: requested, management: checkpoint != nil)
        guard fresh.plan.items == saved.plan.items, fresh.queue == saved.queue,
              fresh.candidates == saved.candidates, fresh.installedVersions == saved.installedVersions else {
            throw packageCenterError("package.center.changed")
        }
        for item in saved.plan.items { try validatePackageVolume(volumes[item.id] ?? item.defaultVolumeID, item: item) }
        try Task.checkCancellation()
        packageInstallPlan = nil
        packageInstallJob = PackageInstallationJobState(id: UUID(), candidates: saved.candidates,
            items: saved.plan.items, volumes: volumes, startAfterInstall: startAfterInstall, checkpoint: checkpoint)
        return try await submitCurrentPackage()
    }

    /// 每次只推进已确认的同一队列；安装请求只在阶段迁移时提交一次。
    public func advancePackageInstallation(id: UUID) async throws -> NasPackageInstallProgress {
        do { return try await advancePackageInstallationChecked(id: id) }
        catch let failure as PackageInstallationCheckpointFailure { throw failure.underlying }
    }

    private func advancePackageInstallationChecked(id: UUID) async throws -> NasPackageInstallProgress {
        guard !packageInstallationRequestActive, var job = packageInstallJob, job.id == id else {
            throw packageCenterError("package.center.busy")
        }
        guard job.phase.isActive || job.phase == .unverified else { return job.progress }
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        do {
            // 暂存清理一旦提交，不重复清理，也不重新开放原安装选项。
            if job.checkpoint != nil, job.cancelRequested, job.checkedPackage != nil, job.taskID == nil {
                job.phase = .unverified; job.messageKey = "package.center.unverified"; packageInstallJob = job
                return job.progress
            }
            if let taskID = job.taskID {
                let status = try await call(DsmAPIName.corePackageInstallation, method: "status", version: 1,
                    parameters: ["task_id": .string(taskID)])
                guard case .boolean(let finished)? = status["finished"] else { throw packageCenterError("package.center.incomplete") }
                if let fraction = status.number(["progress"]), fraction.isFinite, (0...1).contains(fraction) { job.fraction = fraction }
                if !finished {
                    // 下载与安装阶段来自本地已提交的操作，不使用服务器日志作为用户提示。
                    job.phase = job.current.quick ? .installing : .downloading
                    job.messageKey = nil
                    packageInstallJob = job
                    return job.progress
                }
                if job.cancelRequested {
                    if job.checkpoint != nil {
                        guard case .boolean(let succeeded)? = status["success"] else { throw packageCenterError("package.center.incomplete") }
                        if succeeded {
                            // 取消到达前下载已结束时，清理这次下载的暂存包，不能显示已取消后又进入安装表单。
                            let checked = try await call(DsmAPIName.corePackageDownload, method: "check", version: 1,
                                parameters: ["taskid": .string("@SYNOPKG_DOWNLOAD_" + job.current.entry.packageID)])
                            job.checkedPackage = checked; job.taskID = nil; packageInstallJob = job
                            try await cleanOwnedPackageUpload(checked, job: job)
                        }
                    }
                    try await recordPackageInstallation(job, step: .cancelDownload, stage: .verified)
                    job.phase = .cancelled; job.messageKey = nil; packageInstallJob = job
                    return job.progress
                }
                guard case .boolean(let succeeded)? = status["success"] else { throw packageCenterError("package.center.incomplete") }
                guard succeeded else {
                    try await recordPackageInstallation(job, step: job.current.quick ? .install : .download, stage: .rejected)
                    job.phase = .failed; job.messageKey = "package.center.failed"; packageInstallJob = job
                    return job.progress
                }
                if !job.current.quick && job.checkedPackage == nil {
                    let checked = try await call(DsmAPIName.corePackageDownload, method: "check", version: 1,
                        parameters: ["taskid": .string("@SYNOPKG_DOWNLOAD_" + job.current.entry.packageID)])
                    job.checkedPackage = checked
                    // 校验与清理所需的标识仅保留在内存，不写入日志或持久化。
                    job.taskID = nil
                    packageInstallJob = job
                }
            }
            if let checked = job.checkedPackage, !job.finalInstallationSubmitted {
                let config = try await packageConfiguration(checked, expected: job.current.entry)
                job.configuration = config; job.phase = .needsOptions; job.messageKey = nil
                packageInstallJob = job
                try await recordPackageInstallation(job, step: .download, stage: .prepared)
                return job.progress
            }
            let installed = try await loadPackages(includingIcons: false, management: job.checkpoint != nil)
            guard packageInstallationVersionMatches(job, installed: installed) else {
                job.phase = .unverified; job.messageKey = "package.center.unverified"; packageInstallJob = job
                return job.progress
            }
            return try await completePackageInstallationStep(job)
        } catch let failure as PackagePreparationFailure {
            job = packageInstallJob ?? job
            if let checked = job.checkedPackage {
                if job.checkpoint != nil { try await cleanOwnedPackageUpload(checked, job: job) }
                else { try? await cleanOwnedPackageUpload(checked) }
            }
            job.phase = .failed; job.messageKey = failure.messageKey; packageInstallJob = job
            return job.progress
        } catch {
            job = packageInstallJob ?? job
            if error is PackageInstallationCheckpointFailure || (job.checkpoint != nil && Self.packagePreferenceTrustFailure(error)) {
                job.phase = .unverified; job.messageKey = "package.center.unverified"; packageInstallJob = job
                throw error
            }
            if job.checkpoint != nil, let failure = error as? AppError,
               [.permissionDenied, .authenticationRequired].contains(failure.category) {
                job.phase = .unverified; job.messageKey = "package.center.unverified"; packageInstallJob = job
                throw error
            }
            // 任务记录过期或查询中断后，仍可用实际目标版本恢复；下载完成不等于安装完成。
            if job.current.quick || job.finalInstallationSubmitted {
                do {
                    let installed = try await loadPackages(includingIcons: false, management: job.checkpoint != nil)
                    if packageInstallationVersionMatches(job, installed: installed) { return try await completePackageInstallationStep(job) }
                } catch {
                    if job.checkpoint != nil,
                       error is PackageInstallationCheckpointFailure || Self.packagePreferenceTrustFailure(error)
                        || [.permissionDenied, .authenticationRequired].contains((error as? AppError)?.category ?? .unknown) {
                        job.phase = .unverified; job.messageKey = "package.center.unverified"; packageInstallJob = job
                        throw error
                    }
                }
            }
            job.phase = .unverified; job.messageKey = "package.center.unverified"; packageInstallJob = job
            throw error
        }
    }

    private func packageInstallationVersionMatches(_ job: PackageInstallationJobState, installed: [NasPackage]) -> Bool {
        guard !(job.isWriteOutcomeUnknown && job.current.entry.installedVersion == job.current.entry.version),
              let current = installed.first(where: { $0.id == job.current.entry.packageID }) else { return false }
        return current.version == job.current.entry.version
            && ["running", "stopped", "active", "inactive"].contains(current.status?.lowercased() ?? "")
    }

    private func completePackageInstallationStep(_ previous: PackageInstallationJobState) async throws -> NasPackageInstallProgress {
        var job = previous
        try await recordPackageInstallation(job, step: .install, stage: .verified)
        job.index += 1; job.taskID = nil; job.checkedPackage = nil; job.configuration = nil
        job.fraction = nil; job.messageKey = nil; job.isWriteOutcomeUnknown = false; job.finalInstallationSubmitted = false; job.cancelRequested = false
        if job.index == job.candidates.count {
            job.phase = .completed; packageInstallJob = job
            return job.progress
        }
        packageInstallJob = job
        return try await submitCurrentPackage()
    }

    func submitCurrentPackage() async throws -> NasPackageInstallProgress {
        do { return try await submitCurrentPackageChecked() }
        catch {
            guard var job = packageInstallJob else { throw error }
            if error is PackageInstallationCheckpointFailure || (job.checkpoint != nil && Self.packagePreferenceTrustFailure(error)) {
                job.phase = job.isWriteOutcomeUnknown ? .unverified : .failed
                job.messageKey = job.isWriteOutcomeUnknown ? "package.center.unverified" : "package.center.failed"
                packageInstallJob = job
                throw error
            }
            job.phase = .failed; job.messageKey = "package.center.failed"; packageInstallJob = job
            return job.progress
        }
    }

    private func submitCurrentPackageChecked() async throws -> NasPackageInstallProgress {
        guard var job = packageInstallJob else { throw packageCenterError("package.center.changed") }
        let candidate = job.current
        // 付费授权由套件中心完成；不能通过安装参数跳过购买或许可步骤。
        if candidate.raw["price"] != nil && candidate.raw["price"] != .null && packageInteger(candidate.raw["type"]) != 0 {
            job.phase = .failed; job.messageKey = "package.center.purchase-required"; packageInstallJob = job
            return job.progress
        }
        let installed = try await loadPackages(includingIcons: false, management: job.checkpoint != nil)
        guard installed.first(where: { $0.id == candidate.entry.packageID })?.version == candidate.entry.installedVersion else {
            job.phase = .failed; job.messageKey = "package.center.changed"; packageInstallJob = job
            return job.progress
        }
        try await packageInstallFeasibility([candidate.entry.packageID])
        let currentEnvironment = try await packageInstallationEnvironment(candidate)
        let selectedVolume = job.volumes[candidate.entry.id] ?? job.items[job.index].defaultVolumeID
        try validatePackageVolume(selectedVolume, item: currentEnvironment)
        var parameters: [String: DsmParameterValue] = ["name": .string(candidate.entry.packageID), "blqinst": .boolean(candidate.quick)]
        if candidate.quick {
            parameters.merge(["volume_path": .string(selectedVolume), "is_syno": .boolean(candidate.entry.isOfficial),
                "beta": .boolean(candidate.entry.isBeta), "installrunpackage": .boolean(job.startAfterInstall)]) { _, value in value }
            job.phase = .installing
        } else {
            guard let link = candidate.raw.string(["link"]), let checksum = candidate.raw.string(["md5"]),
                  let size = packageInteger(candidate.raw["size"]), size > 0,
                  let type = packageInteger(candidate.raw["type"]) else {
                throw packageCenterError("package.center.incomplete")
            }
            parameters.merge(["url": .string(link), "checksum": .string(checksum), "filesize": .integer(Int(size)),
                "type": .integer(Int(type)), "operation": .string(candidate.entry.installedVersion == nil ? "install" : "upgrade")]) { _, value in value }
            job.phase = .downloading
        }
        try Task.checkCancellation()
        try await recordPackageInstallation(job, step: candidate.quick ? .install : .download, stage: .willSubmit)
        try Task.checkCancellation()
        if job.checkpoint != nil { job.isWriteOutcomeUnknown = true }
        packageInstallJob = job
        do {
            let result = try await call(DsmAPIName.corePackageInstallation,
                method: candidate.entry.installedVersion == nil ? "install" : "upgrade", version: 1, parameters: parameters)
            job.taskID = result.string(["taskid"]) ?? result["data"]?.string(["taskid"])
            packageInstallJob = job
            try await recordPackageInstallation(job, step: candidate.quick ? .install : .download, stage: .accepted)
            guard let progress = result.number(["progress"]), progress.isFinite else {
                job.phase = .unverified; job.isWriteOutcomeUnknown = true; job.messageKey = "package.center.unverified"
                packageInstallJob = job; return job.progress
            }
            guard progress >= 0 else {
                try await recordPackageInstallation(job, step: candidate.quick ? .install : .download, stage: .rejected)
                job.phase = .failed; job.messageKey = "package.center.failed"; packageInstallJob = job
                return job.progress
            }
            guard let taskID = job.taskID, !taskID.isEmpty else {
                job.phase = .unverified; job.isWriteOutcomeUnknown = true; job.messageKey = "package.center.unverified"
                packageInstallJob = job; return job.progress
            }
            job.taskID = taskID; job.fraction = min(progress, 1); job.isWriteOutcomeUnknown = false
            packageInstallJob = job; return job.progress
        } catch {
            return try await packageInstallationSubmissionFailed(job, error: error)
        }
    }

    public func configurePackageInstallation(id: UUID, volumeID: String, startAfterInstall: Bool,
        licenseAccepted: Bool, values: [String: NasPackageOptionValue]) async throws -> NasPackageInstallProgress {
        do { return try await configurePackageInstallationChecked(id: id, volumeID: volumeID, startAfterInstall: startAfterInstall, licenseAccepted: licenseAccepted, values: values) }
        catch let failure as PackageInstallationCheckpointFailure { throw failure.underlying }
    }

    private func configurePackageInstallationChecked(id: UUID, volumeID: String, startAfterInstall: Bool,
        licenseAccepted: Bool, values: [String: NasPackageOptionValue]) async throws -> NasPackageInstallProgress {
        guard !packageInstallationRequestActive, var job = packageInstallJob, job.id == id,
              job.phase == .needsOptions, let checked = job.checkedPackage, let configuration = job.configuration,
              configuration.accepts(values), configuration.license == nil || licenseAccepted else {
            throw packageCenterError("package.center.options-required")
        }
        try validatePackageVolume(volumeID, item: NasPackageInstallItem(package: job.current.entry,
            volumes: configuration.volumes, defaultVolumeID: configuration.defaultVolumeID))
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        let installed = try await loadPackages(includingIcons: false, management: job.checkpoint != nil)
        guard installed.first(where: { $0.id == job.current.entry.packageID })?.version == job.current.entry.installedVersion else {
            throw packageCenterError("package.center.changed")
        }
        try await packageInstallFeasibility([job.current.entry.packageID])
        var check: [String: DsmParameterValue] = ["id": .string(job.current.entry.packageID), "blCheckDep": .boolean(job.manual)]
        for (target, source) in [("install_type", "install_type"), ("install_on_cold_storage", "install_on_cold_storage"),
                                  ("breakpkgs", "break_pkgs"), ("replacepkgs", "replace_pkgs")] {
            if let value = packageMetadata(checked, source), let parameter = packageParameter(value) { check[target] = parameter }
        }
        let environment = try await call(DsmAPIName.corePackageInstallation, method: "check", version: 2, parameters: check)
        if job.checkpoint != nil {
            guard environment["is_occupied"] == .boolean(false) else { throw packageCenterError("package.center.busy") }
            let system = ["system", "system_hidden"].contains(packageMetadata(checked, "install_type")?.scalarString ?? "")
            let volumes = system && (environment["volume_list"] == nil || environment["volume_list"] == .null)
                ? [] : try packageVolumes(environment["volume_list"])
            // 表单打开后存储空间可能变化，不能只检查旧选项再提交原位置。
            guard (system && volumes.isEmpty && volumeID.isEmpty) || volumes.contains(where: { $0.id == volumeID }) else {
                throw packageCenterError("package.center.changed")
            }
        }
        var extra: [String: DsmJSONValue] = [:]
        for field in configuration.fields where field.kind != .description {
            switch values[field.id] ?? field.defaultValue {
            case .text(let text): extra[field.id] = .string(text)
            case .flag(let flag): extra[field.id] = .boolean(flag)
            }
        }
        let extraData = try JSONEncoder().encode(extra)
        var parameters: [String: DsmParameterValue] = ["volume_path": .string(volumeID),
            "extra_values": .string(String(decoding: extraData, as: UTF8.self)),
            "type": .integer(try packageInstallType(checked)), "check_codesign": .boolean(true),
            "force": .boolean(!job.manual), "installrunpackage": .boolean(startAfterInstall && configuration.canStart)]
        if let taskID = packageMetadata(checked, "task_id")?.scalarString {
            parameters["task_id"] = .string(taskID)
        } else if let filename = checked.string(["filename"]) {
            parameters["path"] = .string(filename)
        } else { throw packageCenterError("package.center.incomplete") }
        try Task.checkCancellation()
        try await recordPackageInstallation(job, step: .install, stage: .willSubmit, synchronous: true)
        try Task.checkCancellation()
        job.phase = .installing; job.taskID = nil; job.configuration = nil; job.finalInstallationSubmitted = true
        if job.checkpoint != nil { job.isWriteOutcomeUnknown = true }
        packageInstallJob = job
        do {
            try await callVoid(DsmAPIName.corePackageInstallation,
                method: job.current.entry.installedVersion == nil ? "install" : "upgrade", version: 1, parameters: parameters)
            // 同步安装响应之后仍使用完整列表核对版本；不依赖泛化 success 字段。
            job.isWriteOutcomeUnknown = false; packageInstallJob = job
            try await recordPackageInstallation(job, step: .install, stage: .accepted, synchronous: true)
            return job.progress
        } catch { return try await packageInstallationSubmissionFailed(job, error: error) }
    }

    public func cancelPackageInstallation(id: UUID) async throws -> NasPackageInstallProgress {
        do { return try await cancelPackageInstallationChecked(id: id) }
        catch let failure as PackageInstallationCheckpointFailure { throw failure.underlying }
    }

    private func cancelPackageInstallationChecked(id: UUID) async throws -> NasPackageInstallProgress {
        guard !packageInstallationRequestActive, var job = packageInstallJob, job.id == id else {
            throw packageCenterError("package.center.busy")
        }
        if job.cancelRequested { return job.progress }
        guard job.progress.canCancel else { throw packageCenterError("package.center.cannot-cancel") }
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        if job.phase == .downloading, let taskID = job.taskID {
            try await recordPackageInstallation(job, step: .cancelDownload, stage: .willSubmit)
            try Task.checkCancellation()
            job.cancelRequested = true; packageInstallJob = job
            do {
                try await callVoid(DsmAPIName.corePackageInstallation, method: "cancel", version: 1, parameters: ["taskid": .string(taskID)])
                try await recordPackageInstallation(job, step: .cancelDownload, stage: .accepted)
            } catch {
                job.phase = .unverified; job.messageKey = "package.center.unverified"; packageInstallJob = job
                throw error
            }
            // 不把取消请求已接受显示成取消完成，下一次继续读取同一任务。
            return job.progress
        }
        if let checked = job.checkedPackage { try await cleanOwnedPackageUpload(checked, job: job) }
        job.phase = .cancelled; job.configuration = nil; job.checkedPackage = nil; packageInstallJob = job
        return job.progress
    }

    func cleanOwnedPackageUpload(_ checked: DsmDynamicJSON, job: PackageInstallationJobState? = nil) async throws {
        let method: String, parameters: [String: DsmParameterValue]
        if let filename = checked.string(["filename"]) {
            method = "delete"; parameters = ["path": .string(filename)]
        } else if let taskID = packageMetadata(checked, "task_id")?.scalarString {
            method = "clean"; parameters = ["task_id": .string(taskID)]
        } else {
            if job?.checkpoint != nil { throw packageCenterError("package.center.incomplete") }
            return
        }
        if let job { try await recordPackageInstallation(job, step: .cleanup, stage: .willSubmit) }
        if job?.checkpoint != nil { try Task.checkCancellation() }
        if var job, job.checkpoint != nil { job.cancelRequested = true; packageInstallJob = job }
        do {
            try await callVoid(DsmAPIName.corePackageInstallation, method: method, version: 1, parameters: parameters)
            if let job { try await recordPackageInstallation(job, step: .cleanup, stage: .accepted) }
        } catch {
            if var job, job.checkpoint != nil {
                job.cancelRequested = true; job.phase = .unverified; job.messageKey = "package.center.unverified"; packageInstallJob = job
            }
            throw error
        }
    }

    func packageInstallationSubmissionFailed(_ job: PackageInstallationJobState, error: Error) async throws -> NasPackageInstallProgress {
        var updated = job
        if error is PackageInstallationCheckpointFailure || (job.checkpoint != nil && Self.packagePreferenceTrustFailure(error)) {
            updated.phase = .unverified; updated.messageKey = "package.center.unverified"; packageInstallJob = updated
            throw error
        }
        if let error = error as? AppError, error.dsmCode != nil || [.permissionDenied, .authenticationRequired, .apiUnavailable].contains(error.category) {
            try await recordPackageInstallation(job, step: job.finalInstallationSubmitted || job.current.quick ? .install : .download, stage: .rejected,
                                                synchronous: job.finalInstallationSubmitted)
            updated.phase = .failed; updated.messageKey = "package.center.failed"
        } else {
            updated.phase = .unverified; updated.isWriteOutcomeUnknown = true; updated.messageKey = "package.center.unverified"
        }
        packageInstallJob = updated
        return updated.progress
    }

    func recordPackageInstallation(_ job: PackageInstallationJobState, step: NasPackageInstallationCheckpoint.Step,
        stage: NasPackageInstallationCheckpoint.Stage, synchronous: Bool = false) async throws {
        try await notifyPackageInstallation(.init(id: job.id, step: step, stage: stage, package: job.current.entry,
            completedCount: job.index, totalCount: job.candidates.count, isSynchronousInstallation: synchronous), observer: job.checkpoint)
    }

    func notifyPackageInstallation(_ event: NasPackageInstallationCheckpoint, observer: NasPackageInstallationObserver?) async throws {
        do { try await observer?(event) }
        catch { throw PackageInstallationCheckpointFailure(underlying: error) }
    }

    func validatePackageVolume(_ selected: String, item: NasPackageInstallItem) throws {
        guard (item.volumes.isEmpty && selected.isEmpty)
                || item.volumes.contains(where: { $0.id == selected })
                || (!item.defaultVolumeID.isEmpty && selected == item.defaultVolumeID) else {
            throw packageCenterError("package.center.select-volume")
        }
    }
}
