import DsmCore
import DsmLocalization
import Foundation

enum PackagePreparationFailure: Error {
    case signature, customOptions
    var messageKey: String { self == .signature ? "package.center.signature-failed" : "package.center.custom-options" }
}

extension DsmNasAdministrationRepository {
    public func uploadPackageForInstallation(fileURL: URL) async throws -> NasPackageInstallProgress {
        try await uploadPackageForInstallationChecked(fileURL: fileURL, checkpoint: nil)
    }

    public func uploadPackageForInstallation(fileURL: URL,
        checkpoint: @escaping NasPackageInstallationObserver) async throws -> NasPackageInstallProgress {
        do { return try await uploadPackageForInstallationChecked(fileURL: fileURL, checkpoint: checkpoint) }
        catch let failure as PackageInstallationCheckpointFailure { throw failure.underlying }
        catch let failure as URLError { throw DsmErrorMapper.map(.transport(code: failure.code.rawValue, requestID: UUID())) }
    }

    private func uploadPackageForInstallationChecked(fileURL: URL,
        checkpoint: NasPackageInstallationObserver?) async throws -> NasPackageInstallProgress {
        try requirePackageInstallationIdle()
        guard let capability = capabilities[DsmAPIName.corePackageInstallation], capability.selectedVersion != nil,
              let binaryTransport = transport as? any DsmBinaryHTTPTransport,
              fileURL.isFileURL, fileURL.pathExtension.lowercased() == "spk" else {
            throw packageCenterError("package.center.invalid-file")
        }
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { fileURL.stopAccessingSecurityScopedResource() } }
        let resource = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard resource.isRegularFile == true, (resource.fileSize ?? 0) > 0 else { throw packageCenterError("package.center.invalid-file") }
        let boundary = "LanStashPackage-" + UUID().uuidString
        let bodyURL = try packageUploadBody(fileURL: fileURL, boundary: boundary)
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        var request = try DsmRequestBuilder.build(baseURL: client.baseURL, path: capability.path,
            api: capability.name, version: 1, method: "upload", requestFormat: .form, parameters: [:], credential: credential)
        request.httpBody = nil
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(try bodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), forHTTPHeaderField: "Content-Length")
        try Task.checkCancellation()
        let operationID = UUID()
        try await notifyPackageInstallation(.init(id: operationID, step: .upload, stage: .willSubmit,
            package: nil, completedCount: 0, totalCount: 1), observer: checkpoint)
        try Task.checkCancellation()
        let response = try await binaryTransport.upload(request, from: bodyURL) { _, _ in }
        guard (200..<300).contains(response.statusCode),
              let envelope = try? JSONDecoder().decode(DsmDynamicJSON.self, from: response.data) else {
            throw packageCenterError("package.center.upload-failed")
        }
        if let code = packageInteger(envelope["error"]?["code"]) {
            try await notifyPackageInstallation(.init(id: operationID, step: .upload, stage: .rejected,
                package: nil, completedCount: 0, totalCount: 1), observer: checkpoint)
            throw DsmErrorMapper.map(.api(code: Int(code), requestID: UUID()))
        }
        guard envelope["success"] == .boolean(true), let checked = envelope["data"] else {
            throw packageCenterError("package.center.upload-failed")
        }
        // 上传接受以后即使后续元数据读取失败，也不重新发送文件。
        try await notifyPackageInstallation(.init(id: operationID, step: .upload, stage: .accepted,
            package: nil, completedCount: 0, totalCount: 1), observer: checkpoint)
        var ownedJob: PackageInstallationJobState?
        do {
            guard let id = packageMetadata(checked, "id")?.scalarString,
                  let name = packageMetadata(checked, "name")?.scalarString,
                  let version = packageMetadata(checked, "version")?.scalarString else {
                throw packageCenterError("package.center.incomplete")
            }
            let installed = try await loadPackages(includingIcons: false, management: checkpoint != nil)
            let current = installed.first { $0.id == id }
            let entry = NasPackageCatalogEntry(packageID: id, name: name, version: version,
                description: packageMetadata(checked, "description")?.scalarString ?? "", isOfficial: false,
                installedVersion: current?.version, isUpdateAvailable: current != nil && current?.version != version)
            let candidate = PackageCatalogCandidate(entry: entry, raw: checked)
            var job = PackageInstallationJobState(id: operationID, candidates: [candidate], items: [NasPackageInstallItem(package: entry)],
                volumes: [:], startAfterInstall: true, checkpoint: checkpoint)
            job.checkedPackage = checked; job.manual = true; ownedJob = job
            let configuration = try await packageConfiguration(checked, expected: entry)
            job.phase = .needsOptions; job.configuration = configuration; job.checkedPackage = checked; job.manual = true
            packageInstallJob = job
            try await recordPackageInstallation(job, step: .upload, stage: .prepared)
            return job.progress
        } catch {
            if error is PackageInstallationCheckpointFailure || (checkpoint != nil && Self.packagePreferenceTrustFailure(error)) { throw error }
            if checkpoint != nil {
                // 仅清理本次上传响应内的目标；无法识别的元数据不猜测清理路径。
                if let ownedJob { try await cleanOwnedPackageUpload(checked, job: ownedJob) }
            } else { try? await cleanOwnedPackageUpload(checked) }
            if let failure = error as? PackagePreparationFailure { throw packageCenterError(failure.messageKey) }
            throw error
        }
    }

    func packageConfiguration(_ checked: DsmDynamicJSON, expected: NasPackageCatalogEntry) async throws -> NasPackageInstallConfiguration {
        guard checked["codesign_error"] == nil || checked["codesign_error"] == .null else {
            throw PackagePreparationFailure.signature
        }
        guard packageMetadata(checked, "id")?.scalarString == expected.packageID,
              packageMetadata(checked, "version")?.scalarString == expected.version,
              checked["errmsg"] == nil || checked["errmsg"]?.scalarString == "" else {
            throw packageCenterError("package.center.incomplete")
        }
        try await packageInstallFeasibility([expected.packageID])
        let settings = try await call(DsmAPIName.corePackageSetting, method: "get", version: 1,
            parameters: ["option": .string(packageMetadata(checked, "install_on_cold_storage")?.scalarBoolean == true ? "include_cold_storage" : "")])
        let defaultSettings = try await call(DsmAPIName.corePackageSettingVolume, method: "get", version: 1)
        let volumes = try packageVolumes(settings["volume_list"])
        let defaultVolume = defaultSettings.string(["default_vol"]) ?? (volumes.count == 1 ? volumes[0].id : "")
        let fields = try packageInstallFields(packageMetadata(checked, "install_pages"))
        let license = packageMetadata(checked, "licence")?.scalarString
        return NasPackageInstallConfiguration(packageName: expected.name, version: expected.version,
            license: license?.isEmpty == false ? license : nil, fields: fields, volumes: volumes,
            defaultVolumeID: defaultVolume,
            canStart: packageMetadata(checked, "startable")?.scalarBoolean == true && packageMetadata(checked, "install_reboot")?.scalarBoolean != true,
            requiresRestart: packageMetadata(checked, "install_reboot")?.scalarBoolean == true)
    }

    func packageMetadata(_ value: DsmDynamicJSON, _ key: String) -> DsmDynamicJSON? {
        value["additional"]?[key] ?? value[key]
    }

    func packageInstallFields(_ raw: DsmDynamicJSON?) throws -> [NasPackageInstallField] {
        guard var raw, raw != .null, raw != .string("") else { return [] }
        if case .string(let encoded) = raw {
            let decoded = encoded.removingPercentEncoding ?? encoded
            guard let data = decoded.data(using: .utf8), let parsed = try? JSONDecoder().decode(DsmDynamicJSON.self, from: data) else {
                throw PackagePreparationFailure.customOptions
            }
            raw = parsed
        }
        guard let pages = raw.array else { throw PackagePreparationFailure.customOptions }
        var fields: [NasPackageInstallField] = []
        var keys = Set<String>()
        for (pageIndex, page) in pages.enumerated() {
            guard let items = page["items"]?.array else { throw PackagePreparationFailure.customOptions }
            for (itemIndex, item) in items.enumerated() {
                let prefix = "page-\(pageIndex)-item-\(itemIndex)"
                if let description = item.string(["desc"]), !description.isEmpty {
                    fields.append(NasPackageInstallField(id: prefix, label: description, kind: .description))
                }
                guard let type = item.string(["type"]) else {
                    guard item["subitems"] == nil else { throw PackagePreparationFailure.customOptions }
                    continue
                }
                let kind: NasPackageInstallField.Kind
                switch type {
                case "textfield": kind = .text
                case "password": kind = .password
                case "multiselect": kind = .toggle
                case "singleselect": kind = .radio
                case "combobox": kind = .choice
                default: throw PackagePreparationFailure.customOptions
                }
                guard let subitems = item["subitems"]?.array else { throw PackagePreparationFailure.customOptions }
                for subitem in subitems {
                    guard let key = subitem.string(["key"]), keys.insert(key).inserted else { throw PackagePreparationFailure.customOptions }
                    let validator = subitem["validator"]
                    // 套件的任意脚本、远程表单数据源及浏览器专属验证不能在原生界面静默忽略或执行。
                    guard validator?["fn"] == nil, validator?["regex"] == nil, validator?["vtype"] == nil,
                          subitem["api_store"] == nil, subitem["listeners"] == nil,
                          subitem.boolean(["hidden"]) != true, subitem.boolean(["disabled"]) != true else {
                        throw PackagePreparationFailure.customOptions
                    }
                    var choices: [NasPackageCategory] = []
                    if kind == .choice {
                        guard let rows = subitem["store"]?.array else { throw PackagePreparationFailure.customOptions }
                        choices = try rows.map { row in
                            if let values = row.array, values.count == 2, case .string(let id) = values[0], let label = values[1].scalarString {
                                return NasPackageCategory(id: id, name: label)
                            }
                            if case .string(let value) = row { return NasPackageCategory(id: value, name: value) }
                            throw PackagePreparationFailure.customOptions
                        }
                    }
                    let value: NasPackageOptionValue = (kind == .toggle || kind == .radio)
                        ? .flag(subitem["defaultValue"] == .boolean(true))
                        : .text(subitem.string(["defaultValue", "value"]) ?? "")
                    fields.append(NasPackageInstallField(id: key, label: subitem.string(["desc"]) ?? key, kind: kind,
                        defaultValue: value, choices: choices, group: kind == .radio ? prefix : nil,
                        required: validator?["allowBlank"] == .boolean(false),
                        minimumLength: packageInteger(validator?["minLength"]).map(Int.init),
                        maximumLength: packageInteger(validator?["maxLength"]).map(Int.init)))
                }
            }
        }
        return fields
    }

    private func packageUploadBody(fileURL: URL, boundary: String) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("LanStashPackage-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw packageCenterError("package.center.upload-failed")
        }
        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            var fields = ["api": DsmAPIName.corePackageInstallation, "version": "1", "method": "upload", "_sid": credential.sid,
                "additional": "[\"description\",\"maintainer\",\"distributor\",\"startable\",\"dsm_apps\",\"status\",\"install_reboot\",\"install_type\",\"install_on_cold_storage\",\"break_pkgs\",\"replace_pkgs\"]"]
            if let token = credential.synoToken { fields["SynoToken"] = token }
            for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
                try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
            }
            // 固定传输文件名，避免本机路径泄露及 multipart 头注入。
            try output.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"package.spk\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return bodyURL
        } catch { try? FileManager.default.removeItem(at: bodyURL); throw error }
    }
}
