import DsmCore
import CryptoKit
import Foundation
import ImageIO

extension DsmFileRepository {
    public func listFileStationThemeImages(kind: FileStationThemeImage.Kind) async throws -> [FileStationThemeImage] {
        let data: FileThemeImageListPayload = try await advancedFileCall(DsmAPIName.coreThemeImage, method: "list",
            parameters: ["type": .string("fbsharing_login_" + kind.rawValue)])
        let images = try data.list.map { row -> FileStationThemeImage in
            guard row.index >= 0, !row.path.isEmpty, FileStationThemeImage.supportsFilename(row.path) else { throw Self.advancedFileError() }
            return .init(kind: kind, source: .history, path: row.path, name: row.filename ?? (row.path as NSString).lastPathComponent, historyIndex: row.index)
        }
        guard Set(images.map(\.id)).count == images.count,
              Set(images.compactMap(\.historyIndex)).count == images.count else { throw Self.advancedFileError() }
        return images
    }

    public func loadFileStationThemeImage(_ image: FileStationThemeImage) async throws -> Data {
        try await validateThemeImage(image)
        if image.source == .nas { return try await getThumbnail(path: image.path, size: .large) }
        let request: URLRequest
        if image.source == .systemDefault {
            let url = baseURL.appendingPathComponent("webman/resources/images/1x/default_login_background/" + image.path)
            request = URLRequest(url: url)
        } else {
            // 历史图片的 index 会随新上传变化；先按稳定路径重新找到当前 index。
            let current = try await listFileStationThemeImages(kind: image.kind)
            guard let index = current.first(where: { $0.path == image.path })?.historyIndex,
                  let capability = capabilities[DsmAPIName.coreThemeImage], capability.selectedVersion == 1 else { throw Self.advancedFileError() }
            request = try DsmRequestBuilder.build(baseURL: baseURL, path: capability.path, api: capability.name,
                version: 1, method: "get", requestFormat: capability.requestFormat,
                parameters: ["type": .string("fbsharing_login_" + image.kind.rawValue), "index": .integer(index), "is_thumbnail": .boolean(true)],
                credential: credential, httpMethod: "GET")
        }
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode), CGImageSourceCreateWithData(response.data as CFData, nil) != nil else {
            throw Self.advancedFileError(.invalidResponse, "files.theme.imageLoadFailed")
        }
        return response.data
    }

    public func uploadFileStationThemeImage(data: Data, filename: String, kind: FileStationThemeImage.Kind, confirmed: Bool) async throws -> FileStationThemeImage {
        let key = "theme-upload:" + kind.rawValue
        guard confirmed, !activeAdvancedFileChanges.contains(key) else { throw Self.advancedFileError(.conflict, "files.settings.confirmRequired") }
        guard FileStationThemeImage.supportsFilename(filename), CGImageSourceCreateWithData(data as CFData, nil) != nil,
              !filename.contains(where: { $0.isNewline || $0 == "\"" || $0 == "/" || $0 == "\\" }) else {
            throw Self.advancedFileError(.invalidResponse, "files.theme.invalidImage")
        }
        let pendingKey = key + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !unverifiedAdvancedFileChanges.contains(pendingKey) else {
            throw Self.advancedFileError(.conflict, "files.theme.uploadUnknown")
        }
        activeAdvancedFileChanges.insert(key); defer { activeAdvancedFileChanges.remove(key) }
        try await requireAdvancedFileWrite(administrator: true)
        guard let capability = capabilities[DsmAPIName.coreThemeImage], capability.selectedVersion == 1 else { throw Self.advancedFileError() }
        let boundary = "LanStash-" + UUID().uuidString
        var request = try DsmRequestBuilder.build(baseURL: baseURL, path: capability.path, api: capability.name,
            version: 1, method: "upload", requestFormat: .form, parameters: [:], credential: credential)
        var body = Data()
        var fields = ["api": capability.name, "method": "upload", "version": "1", "type": "fbsharing_login_" + kind.rawValue,
                      "_sid": credential.sid]
        if let token = credential.synoToken { fields["SynoToken"] = token }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"upload_image\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let response: DsmHTTPResponse
        try Task.checkCancellation()
        unverifiedAdvancedFileChanges.insert(pendingKey)
        do { response = try await transport.send(request) }
        catch { throw Self.advancedFileError(.unknown, "files.theme.uploadUnknown") }
        guard (200..<300).contains(response.statusCode),
              let envelope = try? JSONDecoder().decode(FileThemeUploadEnvelope.self, from: response.data) else {
            throw Self.advancedFileError(.invalidResponse, "files.theme.uploadUnknown")
        }
        if let code = envelope.error?.code {
            unverifiedAdvancedFileChanges.remove(pendingKey)
            throw DsmErrorMapper.map(.api(code: code, requestID: UUID()))
        }
        guard envelope.success, let uploaded = envelope.data else { throw Self.advancedFileError(.invalidResponse, "files.theme.uploadUnknown") }
        // 上传只添加到主题图片历史；选择后还须独立确认保存页面设置。
        let history = try await listFileStationThemeImages(kind: kind)
        guard let confirmedImage = history.first(where: { $0.path == uploaded.path }) else {
            throw Self.advancedFileError(.invalidResponse, "files.theme.uploadUnknown")
        }
        unverifiedAdvancedFileChanges.remove(pendingKey)
        return confirmedImage
    }

    func validateThemeImage(_ image: FileStationThemeImage) async throws {
        guard FileStationThemeImage.supportsFilename(image.path), !image.path.contains("\0"),
              !image.path.contains(where: { $0.isNewline }),
              !image.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw Self.advancedFileError() }
        switch image.source {
        case .nas:
            guard image.path.hasPrefix("/"), let item = try await getInfo(paths: [image.path]).first,
                  item.path == image.path, item.kind == .file, item.permissions?.canRead != false else { throw Self.advancedFileError() }
        case .history:
            guard try await listFileStationThemeImages(kind: image.kind).contains(where: { $0.path == image.path }) else {
                throw Self.advancedFileError(.conflict, "files.settings.changed")
            }
        case .systemDefault:
            guard image.kind == .background, (1...10).contains(where: { image.path == "dsm7_0\($0).jpg" }) else { throw Self.advancedFileError() }
        }
    }
}

private struct FileThemeImageListPayload: Decodable, Sendable {
    struct Row: Decodable, Sendable { let index: Int; let filename: String?; let path: String }
    let list: [Row]
}
private struct FileThemeUploadEnvelope: Decodable, Sendable {
    struct Payload: Decodable, Sendable { let path: String }
    struct Failure: Decodable, Sendable { let code: Int }
    let success: Bool
    let data: Payload?
    let error: Failure?
}
