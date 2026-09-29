import DsmCore
import DsmLocalization
import Foundation
import CryptoKit

/// Synology Photos 内部接口，读取与管理证据分别见 photos-library-read.md、photos-management.md。
/// 不实现 File Station 降级，不读取旧照片缓存；写入独立检查权限、身份与结果。
public actor SynologyPhotosRepository: SynologyPhotosServing {
    public static let discoveryAPIs = [
        "SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin",
        "SYNO.Foto.Setting.TeamSpace", "SYNO.Foto.Browse.Timeline", "SYNO.Foto.Browse.Item",
        "SYNO.Foto.Browse.Folder", "SYNO.Foto.Browse.Album", "SYNO.Foto.Browse.RecentlyAdded",
        "SYNO.Foto.Search.Search", "SYNO.Foto.Thumbnail", "SYNO.Foto.Streaming", "SYNO.Foto.Download",
        "SYNO.Foto.Search.Filter", "SYNO.Foto.Browse.Category", "SYNO.Foto.Browse.Person",
        "SYNO.Foto.Browse.Concept", "SYNO.Foto.Browse.Geocoding", "SYNO.Foto.Browse.GeneralTag",
        "SYNO.Foto.Sharing.Misc", "SYNO.Foto.PhotoRequest", "SYNO.Foto.Browse.Unit",
        "SYNO.Foto.BackgroundTask.File", "SYNO.Foto.BackgroundTask.Info",
        "SYNO.Foto.Browse.NormalAlbum", "SYNO.Foto.Browse.ConditionAlbum", "SYNO.Foto.Upload.Item", "SYNO.Foto.Sharing.Passphrase"
    ]
    private let profileID: UUID
    private let capabilities: CapabilitySet
    private let credential: DsmSessionCredential
    private let client: DsmAPIClient
    private let baseURL: URL
    private let transport: any DsmHTTPTransport
    private let pinnedCertificate: String?
    private var allowedSpaces: Set<SynologyPhotoSpace> = []
    private var accessGeneration = 0
    private var categoryThumbnails: [SynologyPhotoCategory: [Int: SynologyPhotoThumbnail]] = [:]
    private var currentUserID: Int?
    private var currentUserUID: SynologyPhotoConditionValue?
    private var mutationInFlight = false
    private var mutations: [UUID: PhotosMutationRecord] = [:]
    private let deletionEnabled: Bool
    private var deletionLocks: Set<SynologyPhotoID> = []
    private var pendingDeletions: [SynologyPhotoID: SynologyPhoto] = [:]
    private var deletionOperations: [UUID: SynologyPhotoID] = [:]
    private var rejectedDeletionOperations: [UUID: AppError] = [:]
    private var confirmedDeletions: [SynologyPhotoID: SynologyPhoto] = [:]

    public init(
        profile: NasProfile, capabilities: CapabilitySet, session: AuthSession,
        transport: (any DsmHTTPTransport)? = nil,
        deletionEnabled: Bool = false
    ) throws {
        profileID = profile.id
        pinnedCertificate = profile.pinnedCertificateSHA256
        self.capabilities = capabilities
        self.deletionEnabled = deletionEnabled
        credential = DsmSessionCredential(sid: session.sid, synoToken: session.synoToken)
        let baseURL = try DsmEndpoint.baseURL(for: profile)
        let transport = transport ?? URLSessionTransport(
                expectedHost: profile.host,
                pinnedCertificateSHA256: profile.pinnedCertificateSHA256,
                requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(profile.host)
        )
        self.baseURL = baseURL
        self.transport = transport
        client = DsmAPIClient(baseURL: baseURL, transport: transport)
    }

    public func access() async throws -> SynologyPhotosAccess {
        // 每次重新核对都先撤销旧授权；失败不得继续沿用上次空间权限。
        allowedSpaces = []
        categoryThumbnails = [:]
        currentUserID = nil
        currentUserUID = nil
        accessGeneration += 1
        let current = accessGeneration
        let user: UserPayload = try await call("SYNO.Foto.UserInfo", version: 1, method: "me")
        guard user.enabled else { throw Self.failure(.permissionDenied) }
        let settings: UserSettings = try await call("SYNO.Foto.Setting.User", version: 1, method: "get")
        let admin: AdminSettings = try await call("SYNO.Foto.Setting.Admin", version: 1, method: "get")
        let team: TeamSettings = try await call("SYNO.Foto.Setting.TeamSpace", version: 1, method: "get")
        guard current == accessGeneration, !Task.isCancelled else { throw CancellationError() }
        var spaces: [SynologyPhotoSpace] = []
        if settings.enable_home_service { spaces.append(.personal) }
        // 当前观察仅确认 none 为无权。其他权限枚举完成证据核对前不猜测开放。
        // 不使用 UserInfo.is_admin 绕过 Photos 权限。
        _ = team
        currentUserID = user.id
        currentUserUID = user.uid
        allowedSpaces = Set(spaces)
        return SynologyPhotosAccess(spaces: spaces, packageVersion: admin.package_version)
    }

    public func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        try requireAccess(space)
        let payload: TimelinePayload = try await call(
            api("Browse.Timeline", in: space), version: 5, method: "get",
            parameters: ["timeline_group_unit": .string("day")]
        )
        return try decodeDays(payload)
    }

    public func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] {
        try requireAccess(space)
        let payload: TimelinePayload = try await call(
            api("Search.Search", in: space), version: 2, method: "get_search_timeline",
            parameters: ["timeline_group_unit": .string("day"), "keyword": .string(keyword)]
        )
        return try decodeDays(payload)
    }

    private func decodeDays(_ payload: TimelinePayload) throws -> [SynologyPhotoDay] {
        try payload.section.flatMap { section in
            try section.list.map { day in
                guard day.item_count >= 0, (1...12).contains(day.month), (1...31).contains(day.day) else {
                    throw Self.failure(.invalidResponse)
                }
                return SynologyPhotoDay(year: day.year, month: day.month, day: day.day, itemCount: day.item_count)
            }
        }
    }

    public func photos(
        in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int
    ) async throws -> SynologyPhotoPage {
        try requireAccess(space)
        guard offset >= 0, (1...500).contains(limit), offset <= Int.max - limit else {
            throw Self.failure(.invalidResponse)
        }
        var parameters: [String: DsmParameterValue] = [
            "offset": .integer(offset), "limit": .integer(limit),
            "additional": .stringArray(["thumbnail", "resolution", "orientation", "video_convert", "video_meta", "address"])
        ]
        var name = api("Browse.Item", in: space)
        var version = 4
        var method = "list"
        switch query {
        case .timeline(let start, let end):
            guard start >= 0, end >= start else { throw Self.failure(.invalidResponse) }
            parameters["start_time"] = .integer(start)
            parameters["end_time"] = .integer(end)
        case .search(let keyword, let start, let end):
            guard start >= 0, end >= start else { throw Self.failure(.invalidResponse) }
            name = api("Search.Search", in: space)
            version = 1
            method = "list_item"
            parameters["keyword"] = .string(keyword)
            parameters["start_time"] = .integer(start)
            parameters["end_time"] = .integer(end)
        case .folder(let id):
            guard id > 0 else { throw Self.failure(.invalidResponse) }
            parameters["folder_id"] = .integer(id)
            parameters["sort_by"] = .string("takentime")
            parameters["sort_direction"] = .string("asc")
            parameters["additional"] = .stringArray(["thumbnail", "resolution", "orientation", "video_convert", "video_meta"])
        case .album(let id):
            guard id > 0 else { throw Self.failure(.invalidResponse) }
            parameters["album_id"] = .integer(id)
            parameters["sort_by"] = .string("takentime")
            parameters["sort_direction"] = .string("desc")
            parameters["additional"] = .stringArray(["thumbnail", "resolution", "orientation", "video_convert", "video_meta", "provider_user_id"])
        case .recentlyAdded:
            name = api("Browse.RecentlyAdded", in: space)
            version = 1
            parameters["additional"] = .stringArray(["thumbnail"])
        case .filtered(let filter, let start, let end):
            guard start >= 0, end >= start else { throw Self.failure(.invalidResponse) }
            method = "list_with_filter"
            version = 2
            parameters.merge(try filterParameters(filter)) { _, new in new }
            if parameters["time"] == nil {
                parameters["time"] = .objectArray([["start_time": .integer(start), "end_time": .integer(end)]])
            }
        case .category(let category, let id, let start, let end):
            guard id > 0, start >= 0, end >= start else { throw Self.failure(.invalidResponse) }
            parameters[try categoryParameter(category)] = .integer(id)
            parameters["start_time"] = .integer(start)
            parameters["end_time"] = .integer(end)
        }
        let payload: ItemList = try await call(name, version: version, method: method, parameters: parameters)
        guard payload.list.count <= limit,
              Set(payload.list.map(\.id)).count == payload.list.count else {
            throw Self.failure(.invalidResponse)
        }
        let items = try payload.list.map { item in
            guard item.id > 0, item.folder_id > 0, item.filesize >= 0 else {
                throw Self.failure(.invalidResponse)
            }
            var photo = SynologyPhoto(
                id: SynologyPhotoID(profileID: profileID, space: space, unitID: item.id),
                filename: item.filename, sizeBytes: item.filesize,
                takenAt: Date(timeIntervalSince1970: item.time),
                indexedAt: Date(timeIntervalSince1970: item.indexed_time),
                folderID: item.folder_id, mediaType: item.type,
                thumbnail: item.additional?.thumbnail.map {
                    SynologyPhotoThumbnail(unitID: $0.unit_id, revision: $0.cache_key)
                },
                width: item.additional?.resolution?.width,
                height: item.additional?.resolution?.height,
                orientation: item.additional?.orientation
            )
            photo.description = item.additional?.description
            photo.camera = item.additional?.exif?.camera
            photo.duration = item.additional?.video_meta?.duration
            return photo
        }
        // 接口没有返回 total/has_more；满页继续请求，空页或短页才结束。
        return SynologyPhotoPage(items: items, offset: offset, nextOffset: offset + payload.list.count, hasMore: payload.list.count == limit)
    }

    private func requireAccess(_ space: SynologyPhotoSpace) throws {
        guard allowedSpaces.contains(space) else { throw Self.failure(.permissionDenied) }
    }

    public func thumbnail(for photo: SynologyPhoto) async throws -> Data {
        try await image(for: photo, size: "m")
    }

    public func previewImage(for photo: SynologyPhoto) async throws -> Data {
        try await image(for: photo, size: "xl")
    }

    private func image(for photo: SynologyPhoto, size: String) async throws -> Data {
        try requireAccess(photo.id.space)
        guard photo.id.profileID == profileID, photo.id.space == .personal,
              let thumbnail = photo.thumbnail, thumbnail.unitID > 0 else {
            throw Self.failure(.permissionDenied)
        }
        return try await image(thumbnail: thumbnail, size: size)
    }

    public func thumbnail(for album: SynologyPhotoCollection) async throws -> Data {
        try requireAccess(.personal)
        // 重新按相册编号读取当前会话有权查看的封面，避免采用其他会话留下的缩略图标识。
        let current = try await managedAlbum(album.id)
        guard let thumbnail = current.collection.thumbnail, thumbnail.unitID > 0 else { throw Self.failure(.apiUnavailable) }
        return try await image(thumbnail: thumbnail, size: "m")
    }

    public func thumbnail(for collection: SynologyPhotoCollection, category: SynologyPhotoCategory) async throws -> Data {
        try requireAccess(.personal)
        guard let thumbnail = categoryThumbnails[category]?[collection.id], thumbnail == collection.thumbnail,
              thumbnail.unitID > 0 else { throw Self.failure(.permissionDenied) }
        return try await image(thumbnail: thumbnail, size: "m")
    }

    private func image(thumbnail: SynologyPhotoThumbnail, size: String) async throws -> Data {
        try requireAccess(.personal)
        // 路由来自官方实际请求，参数独立编码；认证仅使用请求头。
        var components = URLComponents(url: baseURL.appendingPathComponent("synofoto/api/v2/p/Thumbnail/get"), resolvingAgainstBaseURL: false)
        let revision = String(decoding: try JSONEncoder().encode(thumbnail.revision), as: UTF8.self)
        components?.queryItems = [
            URLQueryItem(name: "id", value: String(thumbnail.unitID)),
            URLQueryItem(name: "cache_key", value: revision),
            URLQueryItem(name: "type", value: "\"unit\""),
            URLQueryItem(name: "size", value: "\"\(size)\"")
        ]
        guard let url = components?.url else { throw Self.failure(.invalidResponse) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(credential.cookieHeaderValue, forHTTPHeaderField: "Cookie")
        request.setValue(credential.synoToken, forHTTPHeaderField: "X-SYNO-TOKEN")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let response: DsmHTTPResponse
        do { response = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as DsmCertificateTrustError { throw error }
        catch let error as URLError {
            throw DsmErrorMapper.map(.transport(code: error.errorCode, requestID: UUID()))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw DsmErrorMapper.map(.httpStatus(code: response.statusCode, requestID: UUID()))
        }
        guard !response.data.isEmpty, response.data.count <= 8 * 1_024 * 1_024,
              response.headers.contains(where: { $0.key.lowercased() == "content-type" && $0.value.lowercased().hasPrefix("image/") }) else {
            throw Self.failure(.invalidResponse)
        }
        return response.data
    }

    public func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection {
        try requireAccess(space)
        let payload: FolderPayload = try await call(api("Browse.Folder", in: space), version: 2, method: "get", parameters: [
            "name": .string("/"), "additional": .stringArray(["access_permission"])
        ])
        guard payload.folder.id > 0, payload.folder.additional?.access_permission?.view == true else { throw Self.failure(.permissionDenied) }
        return payload.folder.collection
    }

    public func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        try requireAccess(space)
        guard parentID > 0, offset >= 0, (1...500).contains(limit) else { throw Self.failure(.invalidResponse) }
        let payload: FolderList = try await call(api("Browse.Folder", in: space), version: 2, method: "list", parameters: [
            "id": .integer(parentID), "offset": .integer(offset), "limit": .integer(limit),
            "sort_by": .string("filename"), "sort_direction": .string("asc"), "additional": .stringArray(["thumbnail"])
        ])
        guard payload.list.count <= limit, payload.list.allSatisfy({ $0.id > 0 && $0.parent == parentID }), Set(payload.list.map(\.id)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
        return payload.list.map(\.collection)
    }

    public func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        try requireAccess(.personal)
        guard offset >= 0, (1...500).contains(limit) else { throw Self.failure(.invalidResponse) }
        let payload: AlbumList = try await call("SYNO.Foto.Browse.Album", version: 4, method: "list", parameters: [
            "offset": .integer(offset), "limit": .integer(limit), "category": .string("normal_share_with_me"),
            "additional": .stringArray(["thumbnail", "sharing_info"])
        ])
        guard payload.list.count <= limit, payload.list.allSatisfy({ $0.id > 0 }), Set(payload.list.map(\.id)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
        return payload.list.map { SynologyPhotoCollection(id: $0.id, name: $0.name, itemCount: $0.item_count, thumbnail: $0.additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) }, isConditional: $0.type == "condition") }
    }

    public func details(for photo: SynologyPhoto) async throws -> SynologyPhoto {
        try requirePhoto(photo)
        let payload: ItemList = try await call(api("Browse.Item", in: photo.id.space), version: 5, method: "get", parameters: [
            "id": .integerArray([photo.id.unitID]),
            "additional": .stringArray(["description", "tag", "exif", "resolution", "orientation", "gps", "video_meta", "video_convert", "thumbnail", "address", "geocoding_id", "rating", "motion_photo", "person"])
        ])
        guard payload.list.count == 1, let item = payload.list.first, item.id == photo.id.unitID, item.filesize >= 0 else { throw Self.failure(.invalidResponse) }
        var result = SynologyPhoto(id: photo.id, filename: item.filename, sizeBytes: item.filesize,
            takenAt: Date(timeIntervalSince1970: item.time), indexedAt: Date(timeIntervalSince1970: item.indexed_time),
            folderID: item.folder_id, mediaType: item.type,
            thumbnail: item.additional?.thumbnail.map { SynologyPhotoThumbnail(unitID: $0.unit_id, revision: $0.cache_key) },
            width: item.additional?.resolution?.width, height: item.additional?.resolution?.height, orientation: item.additional?.orientation)
        result.description = item.additional?.description
        result.camera = item.additional?.exif?.camera
        result.lens = item.additional?.exif?.lens
        result.aperture = item.additional?.exif?.aperture
        result.exposureTime = item.additional?.exif?.exposure_time
        result.focalLength = item.additional?.exif?.focal_length
        result.iso = item.additional?.exif?.iso
        result.rating = item.additional?.rating
        result.tags = item.additional?.tag
        if let gps = item.additional?.gps, (-90...90).contains(gps.latitude), (-180...180).contains(gps.longitude) {
            result.latitude = gps.latitude
            result.longitude = gps.longitude
        }
        if let address = item.additional?.address {
            var seen = Set<String>()
            result.addressComponents = ["country", "state", "county", "city", "town", "district", "village", "route", "landmark"]
                .compactMap { address[$0] }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        result.duration = item.additional?.video_meta?.duration
        return result
    }

    public func videoSource(for photo: SynologyPhoto) async throws -> MediaStreamSource {
        try requirePhoto(photo)
        guard photo.mediaType == "video" || photo.mediaType == "live" else { throw Self.failure(.invalidResponse) }
        var videoID = photo.id.unitID
        var sourceType = "item"
        var filename = photo.filename
        let conversions: [ItemPayload.VideoConversion]
        if photo.mediaType == "live" {
            let payload: UnitPayload = try await call(api("Browse.Unit", in: photo.id.space), version: 1, method: "get", parameters: [
                "id_item": .integerArray([photo.id.unitID]),
                "additional": .stringArray(["orientation", "resolution", "thumbnail", "video_meta", "video_convert"])
            ])
            guard payload.list.count == 1, let entry = payload.list.first, entry.id_item == photo.id.unitID else { throw Self.failure(.invalidResponse) }
            let videos = entry.unit.filter { $0.live_type == "video" }
            guard videos.count == 1, let video = videos.first, video.id > 0 else { throw Self.failure(.invalidResponse) }
            videoID = video.id
            sourceType = "unit"
            filename = video.filename ?? "video.mov"
            conversions = video.additional?.video_convert ?? []
        } else {
            let payload: ItemList = try await call(api("Browse.Item", in: photo.id.space), version: 5, method: "get",
                parameters: ["id": .integerArray([photo.id.unitID]), "additional": .stringArray(["video_convert"])])
            guard payload.list.count == 1, let item = payload.list.first, item.id == photo.id.unitID,
                  item.type == "video" else { throw Self.failure(.invalidResponse) }
            filename = item.filename
            conversions = item.additional?.video_convert ?? []
        }
        // 只选套件实际提供的转换版本；没有转换版时读取原视频，不按扩展名猜测。
        let quality = ["raw", "orig_h264", "high", "medium", "low", "mobile"].first { candidate in
            conversions.contains { $0.quality == candidate }
        }
        if quality == nil || quality == "raw" {
            let request = try mediaRequest(api("Download", in: photo.id.space), method: "download", parameters: [
                sourceType == "unit" ? "unit_id" : "item_id": .integerArray([videoID])
            ])
            return MediaStreamSource(request: request, fileExtension: (filename as NSString).pathExtension.lowercased(),
                expectedContentLength: nil, expectedHost: baseURL.host!, pinnedCertificateSHA256: pinnedCertificate)
        }
        let request = try mediaRequest(api("Streaming", in: photo.id.space), method: "streaming", parameters: [
            "id": .integer(videoID), "type": .string(sourceType), "quality": .string(quality!), "use_mov": .boolean(true)
        ])
        return MediaStreamSource(request: request, fileExtension: "mov", expectedContentLength: nil,
                                 expectedHost: baseURL.host!, pinnedCertificateSHA256: pinnedCertificate)
    }

    public func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        try requirePhoto(photo)
        guard destination.isFileURL, let binary = transport as? any DsmBinaryHTTPTransport else { throw Self.failure(.invalidResponse) }
        let request = try mediaRequest(api("Download", in: photo.id.space), method: "download", parameters: [
            "item_id": .integerArray([photo.id.unitID]), "force_download": .boolean(true), "download_type": .string("source")
        ])
        // 在随机临时文件中校验再提升；失败不覆盖用户目标文件。
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(".\(UUID().uuidString).photos-download")
        defer { try? FileManager.default.removeItem(at: staging) }
        let response = try await binary.download(request, to: staging, progress: progress)
        guard response.statusCode == 200 else { throw DsmErrorMapper.map(.httpStatus(code: response.statusCode, requestID: UUID())) }
        let type = response.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        guard !type.contains("json"), !type.contains("html"), !type.contains("zip") else { throw Self.failure(.invalidResponse) }
        let size = (try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value
        guard size == photo.sizeBytes else { throw Self.failure(.invalidResponse) }
        try Task.checkCancellation()
        try await DownloadedFileExporter.export(from: staging, to: destination, replaceExisting: false)
    }

    private func requirePhoto(_ photo: SynologyPhoto) throws {
        try requireAccess(photo.id.space)
        guard photo.id.profileID == profileID, photo.id.unitID > 0 else { throw Self.failure(.permissionDenied) }
    }

    public func prepareDeletion(_ photo: SynologyPhoto) async throws {
        guard !mutationInFlight, !mutations.values.contains(where: { $0.result.state == .pendingReview }) else { throw deletionError(.conflict, "photos.manage.pending") }
        try requirePhoto(photo)
        guard photo.id.space == .personal, deletionEnabled else {
            throw deletionError(.apiUnavailable, "photos.delete.unverified")
        }
        guard let deleteCapability = capabilities["SYNO.Foto.BackgroundTask.File"],
              deleteCapability.minVersion <= 1, deleteCapability.maxVersion >= 1,
              deleteCapability.requestFormat == .json else {
            throw deletionError(.versionUnsupported, "photos.delete.unverified")
        }
        // 删除身份核查不依赖 EXIF、地址或视频转换等可选详情的解析。
        let identity: DeletionItemList = try await call("SYNO.Foto.Browse.Item", version: 5, method: "get",
            parameters: ["id": .integerArray([photo.id.unitID])])
        guard identity.list.count == 1, let current = identity.list.first,
              current.matches(photo) else { throw deletionError(.conflict, "photos.delete.changed") }
        let folder: FolderPayload = try await call("SYNO.Foto.Browse.Folder", version: 2, method: "get", parameters: [
            "id": .integer(photo.folderID), "additional": .stringArray(["access_permission"])
        ])
        guard folder.folder.id == photo.folderID, folder.folder.additional?.access_permission?.view == true,
              folder.folder.additional?.access_permission?.manage == true else {
            throw deletionError(.permissionDenied, "photos.delete.denied")
        }
    }

    public func deletePhoto(_ photo: SynologyPhoto, operationID: UUID) async throws -> SynologyPhotoDeletionResult {
        try requirePhoto(photo)
        if let previous = deletionOperations[operationID], previous != photo.id { throw deletionError(.conflict, "photos.delete.changed") }
        if let rejection = rejectedDeletionOperations[operationID] { throw rejection }
        if let confirmed = confirmedDeletions[photo.id], Self.sameDeletionTarget(confirmed, photo) { return .confirmed }
        guard deletionLocks.insert(photo.id).inserted else { return .pendingReview }
        defer { deletionLocks.remove(photo.id) }
        if let pending = pendingDeletions[photo.id] {
            guard Self.sameDeletionTarget(pending, photo) else { throw deletionError(.conflict, "photos.delete.changed") }
            return try await reviewDeletion(photo)
        }
        // 确认框之后重新核对版本、目标与权限，再且仅再提交一次。
        try await prepareDeletion(photo)
        try Task.checkCancellation()
        guard allowedSpaces.contains(photo.id.space) else { throw deletionError(.permissionDenied, "photos.delete.denied") }
        deletionOperations[operationID] = photo.id
        pendingDeletions[photo.id] = photo
        let capability = capabilities["SYNO.Foto.BackgroundTask.File"]!
        do {
            try await client.callVoid(path: capability.path, api: capability.name, version: 1, method: "delete",
                requestFormat: .json, parameters: ["item_id": .integerArray([photo.id.unitID]), "folder_id": .integerArray([])],
                credential: credential)
        } catch let error as DsmNetworkError {
            // 明确的会话/权限拒绝没有启动删除，不能伪装成永久待核查；未知错误仍不重放。
            if case .api(let code, _) = error, [105, 106, 107, 119].contains(code) {
                let rejection = DsmErrorMapper.map(error)
                pendingDeletions.removeValue(forKey: photo.id)
                rejectedDeletionOperations[operationID] = rejection
                throw rejection
            }
            return .pendingReview
        } catch {
            // 提交后的错误或取消不能证明未执行；保留待核对记录，不自动重放。
            return .pendingReview
        }
        return (try? await reviewDeletion(photo)) ?? .pendingReview
    }

    public func reviewDeletion(_ photo: SynologyPhoto) async throws -> SynologyPhotoDeletionResult {
        try requirePhoto(photo)
        if let confirmed = confirmedDeletions[photo.id], Self.sameDeletionTarget(confirmed, photo) { return .confirmed }
        guard let pending = pendingDeletions[photo.id], Self.sameDeletionTarget(pending, photo) else {
            throw deletionError(.conflict, "photos.delete.changed")
        }
        let payload: DeletionItemList = try await call("SYNO.Foto.Browse.Item", version: 5, method: "get",
            parameters: ["id": .integerArray([photo.id.unitID])])
        // 只有成功空响应表示原件已不存在；权限错误、失败响应和其他项目都不能视为删除成功。
        if payload.list.isEmpty {
            pendingDeletions.removeValue(forKey: photo.id)
            confirmedDeletions[photo.id] = photo
            return .confirmed
        }
        return .pendingReview
    }

    private static func sameDeletionTarget(_ lhs: SynologyPhoto, _ rhs: SynologyPhoto) -> Bool {
        lhs.id == rhs.id && lhs.filename == rhs.filename && lhs.folderID == rhs.folderID
            && lhs.sizeBytes == rhs.sizeBytes && lhs.takenAt == rhs.takenAt
            && lhs.indexedAt == rhs.indexedAt && lhs.mediaType == rhs.mediaType
    }
    private func deletionError(_ category: AppErrorCategory, _ key: String) -> AppError {
        AppError(category: category, isRetryable: false, safeUserMessage: L10n.string(key))
    }

    public func filteredTimeline(in space: SynologyPhotoSpace, filter: SynologyPhotoFilter) async throws -> [SynologyPhotoDay] {
        try requireAccess(space)
        var parameters = try filterParameters(filter)
        parameters["timeline_group_unit"] = .string("day")
        let payload: TimelinePayload = try await call(api("Browse.Timeline", in: space), version: 3, method: "get_with_filter", parameters: parameters)
        return try decodeDays(payload)
    }

    private func filterParameters(_ filter: SynologyPhotoFilter) throws -> [String: DsmParameterValue] {
        guard (filter.startTime == nil) == (filter.endTime == nil) else { throw Self.failure(.invalidResponse) }
        var result: [String: DsmParameterValue] = [:]
        if let type = filter.mediaType {
            guard [0, 1].contains(type) else { throw Self.failure(.invalidResponse) }
            result["item_type"] = .integerArray([type])
        }
        if let person = filter.personID { result["person"] = .integerArray([person]); result["person_policy"] = .string("or") }
        if let location = filter.locationID { result["geocoding"] = .integerArray([location]) }
        if let tag = filter.tagID { result["general_tag"] = .integerArray([tag]); result["general_tag_policy"] = .string("or") }
        for (key, id) in [("camera", filter.cameraID), ("lens", filter.lensID), ("iso", filter.isoID), ("aperture", filter.apertureID)] {
            if let id { result[key] = .integerArray([id]) }
        }
        if let range = filter.focalRange {
            result["focal_length_group"] = .objectArray([["start": .integer(range.start), "end": .integer(range.end)]])
        }
        if let range = filter.exposureRange {
            guard range.start.den > 0, range.end.den > 0 else { throw Self.failure(.invalidResponse) }
            result["exposure_time_group"] = .objectArray([[
                "start": .object(["num": .integer(range.start.num), "den": .integer(range.start.den)]),
                "end": .object(["num": .integer(range.end.num), "den": .integer(range.end.den)])
            ]])
        }
        if let rating = filter.rating {
            guard (0...5).contains(rating) else { throw Self.failure(.invalidResponse) }
            result["rating"] = .integerArray([rating])
        }
        if let start = filter.startTime, let end = filter.endTime {
            guard start >= 0, end >= start else { throw Self.failure(.invalidResponse) }
            result["time"] = .objectArray([["start_time": .integer(start), "end_time": .integer(end)]])
        }
        return result
    }

    public func filterOptions(in space: SynologyPhotoSpace) async throws -> SynologyPhotoFilterOptions {
        try requireAccess(space)
        let payload: FilterOptionsPayload = try await call(api("Search.Filter", in: space), version: 3, method: "list", parameters: [
            "additional": .stringArray(["thumbnail"]),
            "setting": .object(["item_type": .boolean(true), "time": .boolean(true), "person": .boolean(true),
                "geocoding": .boolean(true), "rating": .boolean(true), "general_tag": .boolean(true),
                "camera": .boolean(true), "lens": .boolean(true), "iso": .boolean(true), "aperture": .boolean(true),
                "focal_length_group": .boolean(true), "exposure_time_group": .boolean(true)])
        ])
        return SynologyPhotoFilterOptions(
            people: payload.person.map { SynologyPhotoCollection(id: $0.id, name: $0.name, itemCount: $0.item_count, thumbnail: $0.additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) }) },
            locations: payload.geocoding.map(\.location), tags: payload.general_tag ?? [],
            cameras: payload.camera ?? [], lenses: payload.lens ?? [], isoValues: payload.iso ?? [],
            apertures: payload.aperture ?? [], focalRanges: payload.focal_length_group ?? [],
            exposureRanges: payload.exposure_time_group ?? [])
    }

    public func categories() async throws -> Set<SynologyPhotoCategory> {
        try requireAccess(.personal)
        let payload: CategoryPayload = try await call("SYNO.Foto.Browse.Category", version: 3, method: "get")
        let mapping: [String: SynologyPhotoCategory] = ["recently_added": .recentlyAdded, "person": .person, "concept": .concept, "geocoding": .location, "general_tag": .tags, "video": .videos]
        return Set(payload.list.compactMap { mapping[$0.id] })
    }

    public func categoryItems(_ category: SynologyPhotoCategory, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        try requireAccess(.personal)
        guard offset >= 0, (1...500).contains(limit) else { throw Self.failure(.invalidResponse) }
        let generation = accessGeneration
        let suffix: String
        switch category {
        case .person: suffix = "Person"
        case .concept: suffix = "Concept"
        case .location: suffix = "Geocoding"
        case .tags: suffix = "GeneralTag"
        default: throw Self.failure(.invalidResponse)
        }
        let payload: AlbumList = try await call("SYNO.Foto.Browse." + suffix, version: category == .concept ? 2 : 1, method: "list", parameters: [
            "offset": .integer(offset), "limit": .integer(limit), "additional": .stringArray(["thumbnail"])
        ])
        guard payload.list.count <= limit, payload.list.allSatisfy({ $0.id > 0 }), Set(payload.list.map(\.id)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        let collections = payload.list.map { SynologyPhotoCollection(id: $0.id, name: $0.name, itemCount: $0.item_count, thumbnail: $0.additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) }) }
        if offset == 0 { categoryThumbnails[category] = [:] }
        for collection in collections {
            if let thumbnail = collection.thumbnail { categoryThumbnails[category, default: [:]][collection.id] = thumbnail }
        }
        return collections
    }

    public func categoryTimeline(_ category: SynologyPhotoCategory, id: Int) async throws -> [SynologyPhotoDay] {
        try requireAccess(.personal)
        let payload: TimelinePayload = try await call("SYNO.Foto.Browse.Timeline", version: 5, method: "get", parameters: [
            "timeline_group_unit": .string("day"), try categoryParameter(category): .integer(id)
        ])
        return try decodeDays(payload)
    }

    private func categoryParameter(_ category: SynologyPhotoCategory) throws -> String {
        switch category {
        case .person: return "person_id"
        case .concept: return "concept_id"
        case .location: return "geocoding_id"
        case .tags: return "general_tag_id"
        default: throw Self.failure(.invalidResponse)
        }
    }

    public func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int) async throws -> [SynologyPhotoSharedEntry] {
        try requireAccess(.personal)
        guard offset >= 0, (1...500).contains(limit) else { throw Self.failure(.invalidResponse) }
        var parameters: [String: DsmParameterValue] = ["offset": .integer(offset), "limit": .integer(limit)]
        if scope == .requests {
            let payload: PhotoRequestList = try await call("SYNO.Foto.PhotoRequest", version: 1, method: "list", parameters: parameters)
            guard payload.list.count <= limit, Set(payload.list.map(\.passphrase)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
            return payload.list.map { SynologyPhotoSharedEntry(id: $0.passphrase, title: $0.subject, url: Self.safeSharingURL($0.sharing_link)) }
        }
        parameters["additional"] = .stringArray(["sharing_info", "thumbnail", "access_permission"])
        let payload: SharedAlbumList
        if scope == .withMe {
            payload = try await call("SYNO.Foto.Sharing.Misc", version: 2, method: "list_shared_with_me_album", parameters: parameters)
        } else {
            parameters["category"] = .string("shared")
            parameters["sort_by"] = .string("share_modify_time")
            parameters["sort_direction"] = .string("desc")
            parameters["additional"] = .stringArray(["thumbnail", "sharing_info"])
            payload = try await call("SYNO.Foto.Browse.Album", version: 4, method: "list", parameters: parameters)
        }
        guard payload.list.count <= limit, payload.list.allSatisfy({ $0.id > 0 }), Set(payload.list.map(\.id)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
        return payload.list.map { SynologyPhotoSharedEntry(id: String($0.id), title: $0.name, albumID: $0.id) }
    }

    private static func safeSharingURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func mediaRequest(_ name: String, method: String, parameters: [String: DsmParameterValue]) throws -> URLRequest {
        guard let capability = capabilities[name], capability.minVersion <= 2, capability.maxVersion >= 2 else { throw Self.failure(.apiUnavailable) }
        return try DsmRequestBuilder.build(baseURL: baseURL, path: capability.path, api: name, version: 2,
            method: method, requestFormat: .json, parameters: parameters, credential: credential, httpMethod: "GET")
    }

    private func api(_ suffix: String, in space: SynologyPhotoSpace) -> String {
        (space == .personal ? "SYNO.Foto." : "SYNO.FotoTeam.") + suffix
    }

    private func call<T: Decodable & Sendable>(
        _ name: String, version: Int, method: String,
        parameters: [String: DsmParameterValue] = [:]
    ) async throws -> T {
        guard let capability = capabilities[name] else { throw Self.failure(.apiUnavailable) }
        guard capability.minVersion <= version, capability.maxVersion >= version,
              capability.requestFormat == .json else { throw Self.failure(.versionUnsupported) }
        do {
            return try await client.call(
                path: capability.path, api: name, version: version, method: method,
                requestFormat: .json, parameters: parameters, credential: credential, as: T.self
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private static func failure(_ category: AppErrorCategory) -> AppError {
        let key: String
        switch category {
        case .permissionDenied: key = "photos.service.permission"
        case .apiUnavailable, .versionUnsupported: key = "photos.service.unavailable"
        default: key = "photos.service.invalidResponse"
        }
        return AppError(category: category, isRetryable: false, safeUserMessage: L10n.string(key))
    }
}

private struct UserPayload: Decodable, Sendable { let enabled: Bool; let id: Int?; let uid: SynologyPhotoConditionValue? }
private struct UserSettings: Decodable, Sendable {
    let enable_home_service: Bool
    let team_space_permission: String
}
private struct AdminSettings: Decodable, Sendable { let package_version: String }
private struct TeamSettings: Decodable, Sendable { let enabled: Bool }
private struct TimelinePayload: Decodable, Sendable {
    let section: [Section]
    struct Section: Decodable, Sendable { let list: [Day] }
    struct Day: Decodable, Sendable { let year: Int; let month: Int; let day: Int; let item_count: Int }
}
private struct ItemList: Decodable, Sendable { let list: [ItemPayload] }
private struct DeletionItemList: Decodable, Sendable {
    let list: [Identity]
    struct Identity: Decodable, Sendable {
        let id: Int
        let filename: String
        let filesize: Int64
        let time: Double
        let indexed_time: Double
        let folder_id: Int
        let type: String
        func matches(_ photo: SynologyPhoto) -> Bool {
            id == photo.id.unitID && filename == photo.filename && filesize == photo.sizeBytes
                && Date(timeIntervalSince1970: time) == photo.takenAt
                && Date(timeIntervalSince1970: indexed_time) == photo.indexedAt
                && folder_id == photo.folderID && type == photo.mediaType
        }
    }
}
private struct ItemPayload: Decodable, Sendable {
    let id: Int
    let filename: String
    let filesize: Int64
    let time: TimeInterval
    let indexed_time: TimeInterval
    let folder_id: Int
    let type: String
    let additional: Additional?
    struct Additional: Decodable, Sendable {
        let thumbnail: Thumbnail?
        let resolution: Resolution?
        let orientation: Int?
        let description: String?
        let exif: Exif?
        let video_meta: VideoMeta?
        let video_convert: [VideoConversion]?
        let rating: Int?
        let tag: [SynologyPhotoFilterChoice]?
        let address: [String: String]?
        let gps: GPS?
    }
    struct Exif: Decodable, Sendable {
        let camera: String?; let lens: String?; let aperture: String?
        let exposure_time: String?; let focal_length: String?; let iso: String?
    }
    struct VideoMeta: Decodable, Sendable { let duration: Double? }
    struct VideoConversion: Decodable, Sendable { let quality: String }
    struct GPS: Decodable, Sendable { let latitude: Double; let longitude: Double }
    struct Thumbnail: Decodable, Sendable { let unit_id: Int; let cache_key: String }
    struct Resolution: Decodable, Sendable { let width: Int; let height: Int }
}

private struct FolderPayload: Decodable, Sendable { let folder: FolderEntry }
private struct FolderList: Decodable, Sendable { let list: [FolderEntry] }
private struct FolderEntry: Decodable, Sendable {
    let id: Int; let name: String; let parent: Int
    let additional: Additional?
    struct Additional: Decodable, Sendable { let access_permission: Access? }
    struct Access: Decodable, Sendable { let view: Bool; let manage: Bool? }
    var collection: SynologyPhotoCollection { SynologyPhotoCollection(id: id, name: (name as NSString).lastPathComponent, parentID: parent) }
}
private struct AlbumList: Decodable, Sendable { let list: [AlbumEntry] }
private struct AlbumEntry: Decodable, Sendable {
    let type: String?
    let id: Int; let name: String; let item_count: Int?
    let additional: Additional?
    struct Additional: Decodable, Sendable { let thumbnail: ItemPayload.Thumbnail? }
}

private struct CategoryPayload: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable { let id: String }
}
private struct UnitPayload: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable {
        let id_item: Int
        let unit: [Unit]
    }
    struct Unit: Decodable, Sendable {
        let id: Int; let live_type: String
        let filename: String?
        let additional: ItemPayload.Additional?
    }
}
private struct FilterOptionsPayload: Decodable, Sendable {
    let person: [AlbumEntry]
    let geocoding: [Location]
    let general_tag: [SynologyPhotoFilterChoice]?
    let camera: [SynologyPhotoFilterChoice]?
    let lens: [SynologyPhotoFilterChoice]?
    let iso: [SynologyPhotoFilterChoice]?
    let aperture: [SynologyPhotoFilterChoice]?
    let focal_length_group: [SynologyPhotoFocalRange]?
    let exposure_time_group: [SynologyPhotoExposureRange]?
    struct Location: Decodable, Sendable {
        let id: Int; let name: String; let level: Int; let children: [Location]?
        var location: SynologyPhotoLocation { SynologyPhotoLocation(id: id, name: name, level: level, children: (children ?? []).map(\.location)) }
    }
}
private struct PhotoRequestList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable { let passphrase: String; let subject: String; let sharing_link: String? }
}
private struct SharedAlbumList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable {
        let id: Int; let name: String
    }
}

// MARK: - 按实际接口能力与权限开放的个人空间管理

private struct PhotosMutationRecord: Sendable {
    let mutation: SynologyPhotosMutation
    var taskID: Int?
    var itemID: Int?
    var albumID: Int?
    var folderID: Int?
    var createdTag: SynologyPhotoFilterChoice?
    var tagAdditionRejected = false
    var tagAdditionAttempted = false
    var shiftedSubmittedIDs: Set<SynologyPhotoID> = []
    var shiftedRejectedID: SynologyPhotoID?
    var shiftingPhotoID: SynologyPhotoID?
    var enableSharingAttempted = false
    var sharingBefore: ManagementAlbum.Sharing?
    var personPhotoIDs: Set<Int>?
    var personReceipt: PersonNameReceipt?
    var result = SynologyPhotosMutationResult(state: .pendingReview)
}

extension SynologyPhotosRepository {
    public func managementFeatures() async -> Set<SynologyPhotosManagementFeature> {
        guard allowedSpaces.contains(.personal) else { return [] }
        return Set(SynologyPhotosManagementFeature.allCases.filter { feature in
            managementRequirements(feature).allSatisfy { name, version in
                guard let capability = capabilities[name] else { return false }
                return capability.minVersion <= version && capability.maxVersion >= version && capability.requestFormat == .json
            }
        })
    }

    private func managementRequirements(_ feature: SynologyPhotosManagementFeature) -> [(String, Int)] {
        let common = [("SYNO.Foto.Browse.Item", 5), ("SYNO.Foto.Browse.Folder", 2)]
        switch feature {
        case .metadata: return common + [("SYNO.Foto.Browse.Item", 2)]
        case .tags: return common + [("SYNO.Foto.Browse.Item", 1)]
        case .tagCreation: return common + [("SYNO.Foto.Browse.Item", 1), ("SYNO.Foto.Browse.GeneralTag", 1)]
        case .albums: return common + [("SYNO.Foto.Browse.Album", 4), ("SYNO.Foto.Browse.NormalAlbum", 1)]
        case .conditionAlbums: return [("SYNO.Foto.Browse.Album", 4), ("SYNO.Foto.Browse.ConditionAlbum", 3), ("SYNO.Foto.Browse.Folder", 2)]
        case .folders: return [("SYNO.Foto.Browse.Folder", 1), ("SYNO.Foto.Browse.Folder", 2)]
        case .fileTransfer: return common + [("SYNO.Foto.BackgroundTask.File", 1), ("SYNO.Foto.BackgroundTask.Info", 1)]
        case .upload: return common + [("SYNO.Foto.Upload.Item", 1)]
        case .sharing: return [("SYNO.Foto.Browse.Album", 4), ("SYNO.Foto.Sharing.Passphrase", 1)]
        case .peopleNames: return [("SYNO.Foto.Browse.Person", 1)]
        case .peopleMerge: return [("SYNO.Foto.Browse.Person", 2), ("SYNO.Foto.Browse.Timeline", 5), ("SYNO.Foto.Browse.Item", 4), ("SYNO.Foto.Browse.Folder", 2)]
        }
    }

    public func prepareMutation(_ mutation: SynologyPhotosMutation) async throws {
        try requireAccess(.personal)
        guard await managementFeatures().contains(mutation.feature) else {
            throw deletionError(.apiUnavailable, "photos.manage.unavailable")
        }
        let generation = accessGeneration
        let targets = mutation.photos
        guard targets.count <= 100, Set(targets.map(\.id)).count == targets.count else { throw Self.failure(.invalidResponse) }
        switch mutation {
        case .renamePerson(let person, _):
            try await validatePeople([person])
        case .mergePeople(let target, let sources, _):
            guard !sources.isEmpty else { throw Self.failure(.invalidResponse) }
            try await validatePeople([target] + sources)
        case .edit(let photos, let edit):
            guard !photos.isEmpty else { throw Self.failure(.invalidResponse) }
            if case .rating(let rating) = edit, !(0...5).contains(rating) { throw Self.failure(.invalidResponse) }
            if case .takenAt(let date) = edit, !date.timeIntervalSince1970.isFinite || date.timeIntervalSince1970 < 0 || date.timeIntervalSince1970 > Double(Int.max / 2) { throw Self.failure(.invalidResponse) }
        case .shiftDates(let photos, let seconds):
            guard !photos.isEmpty, seconds != 0 else { throw Self.failure(.invalidResponse) }
            for photo in photos { _ = try shiftedTimestamp(photo, seconds: seconds) }
        case .createTag(let name, _):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.failure(.invalidResponse) }
        case .addTags(let photos, let ids), .removeTags(let photos, let ids):
            guard !photos.isEmpty, !ids.isEmpty, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else { throw Self.failure(.invalidResponse) }
        case .createAlbum(let name, _), .renameAlbum(_, let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.failure(.invalidResponse) }
        case .createConditionAlbum(let name, let condition):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.failure(.invalidResponse) }
            try await validateCondition(condition)
        case .setAlbumCondition(let id, let original, let condition):
            let current = try await albumCondition(id: id)
            guard try conditionParameters(current) == conditionParameters(original) else { throw Self.failure(.conflict) }
            try await validateCondition(condition)
        case .createFolder(let parent, let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw Self.failure(.invalidResponse) }
            try await requireManagedFolder(parent)
        case .addToAlbum(_, let photos), .removeFromAlbum(_, let photos), .move(let photos, _), .copy(let photos, _):
            guard !photos.isEmpty else { throw Self.failure(.invalidResponse) }
        default: break
        }
        for photo in targets {
            try requirePhoto(photo)
            guard photo.id.space == .personal, pendingDeletions[photo.id] == nil else { throw Self.failure(.permissionDenied) }
            let identity: DeletionItemList = try await call("SYNO.Foto.Browse.Item", version: 5, method: "get", parameters: ["id": .integerArray([photo.id.unitID])])
            guard identity.list.count == 1, identity.list.first?.matches(photo) == true else { throw deletionError(.conflict, "photos.delete.changed") }
            try await requireManagedFolder(photo.folderID)
        }
        switch mutation {
        case .renameAlbum(let id, _), .deleteAlbum(let id), .addToAlbum(let id, _), .removeFromAlbum(let id, _), .setAlbumCover(let id, _), .shareAlbum(let id, _, _, _):
            let album = try await managedAlbum(id)
            guard let user = currentUserID, user > 0, album.owner_user_id == user else { throw Self.failure(.permissionDenied) }
            if case .shareAlbum(_, _, let original, let members) = mutation {
                if let members {
                    guard let original, let existing = original.members else { throw Self.failure(.invalidResponse) }
                    try validateSharingMembers(members, original: existing, conditional: album.type == "condition")
                }
                if let original, try sharingState(album).revision != original.revision {
                    throw deletionError(.conflict, "photos.sharing.changed")
                }
            }
            switch mutation {
            case .addToAlbum, .removeFromAlbum: guard album.type != "condition" else { throw Self.failure(.invalidResponse) }
            default: break
            }
        case .move(let photos, let folder), .copy(let photos, let folder):
            guard !photos.contains(where: { $0.folderID == folder }) else { throw Self.failure(.invalidResponse) }
            try await requireManagedFolder(folder)
        case .upload(let url, let size, let modified, let folder):
            guard url.isFileURL, size > 0 else { throw Self.failure(.invalidResponse) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.fileSize.map(Int64.init) == size, values.contentModificationDate == modified else { throw deletionError(.conflict, "photos.manage.fileChanged") }
            if let folder { try await requireManagedFolder(folder) }
            else { let root = try await rootFolder(in: .personal); try await requireManagedFolder(root.id) }
        default: break
        }
        if case .setAlbumCover(let id, let photo) = mutation {
            guard try await verifyAlbumMembership(id, photos: [photo], present: true) else { throw Self.failure(.conflict) }
        }
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try requireAccess(.personal)
    }

    private func shiftedTimestamp(_ photo: SynologyPhoto, seconds: Int) throws -> Int {
        let original = photo.takenAt.timeIntervalSince1970
        guard original.isFinite, original >= 0, original <= Double(Int.max / 2) else { throw Self.failure(.invalidResponse) }
        let (target, overflow) = Int(original).addingReportingOverflow(seconds)
        guard !overflow, target >= 0, target <= Int.max / 2 else { throw Self.failure(.invalidResponse) }
        return target
    }

    private func requireManagedFolder(_ id: Int) async throws {
        guard id > 0 else { throw Self.failure(.invalidResponse) }
        let folder: FolderPayload = try await call("SYNO.Foto.Browse.Folder", version: 2, method: "get", parameters: ["id": .integer(id), "additional": .stringArray(["access_permission"])])
        guard folder.folder.id == id, folder.folder.additional?.access_permission?.view == true,
              folder.folder.additional?.access_permission?.manage == true else { throw Self.failure(.permissionDenied) }
    }

    private func managedAlbum(_ id: Int) async throws -> ManagementAlbum {
        guard id > 0 else { throw Self.failure(.invalidResponse) }
        let payload: ManagementAlbums = try await call("SYNO.Foto.Browse.Album", version: 4, method: "get", parameters: ["id": .integerArray([id]), "additional": .stringArray(["sharing_info", "thumbnail"])])
        guard payload.list.count == 1, let album = payload.list.first, album.id == id else { throw Self.failure(.invalidResponse) }
        return album
    }

    public func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        if let existing = mutations[operationID] {
            guard existing.mutation == mutation else { throw Self.failure(.conflict) }
            return try await reviewMutation(operationID: operationID)
        }
        guard !mutationInFlight, !mutations.values.contains(where: { $0.result.state == .pendingReview }), pendingDeletions.isEmpty, deletionLocks.isEmpty else {
            throw deletionError(.conflict, "photos.manage.pending")
        }
        mutationInFlight = true
        defer { mutationInFlight = false }
        try await prepareMutation(mutation)
        var sharingAlbum: ManagementAlbum?
        var sharingSnapshot: SynologyPhotoSharingState?
        if case .shareAlbum(let id, _, let original, let members) = mutation {
            let album = try await managedAlbum(id)
            guard let user = currentUserID, user > 0, album.owner_user_id == user else { throw Self.failure(.permissionDenied) }
            let current = try sharingState(album)
            if let original, original.revision != current.revision { throw deletionError(.conflict, "photos.sharing.changed") }
            if let members {
                guard let existing = current.members else { throw Self.failure(.invalidResponse) }
                try validateSharingMembers(members, original: existing, conditional: album.type == "condition")
                let newMembers = members.filter { value in !existing.contains { $0.id == value.id } }
                if !newMembers.isEmpty {
                    let available = try await sharingRecipients()
                    guard newMembers.allSatisfy({ member in available.contains { $0.id == member.id } }) else { throw Self.failure(.permissionDenied) }
                }
            }
            try Task.checkCancellation()
            try requireAccess(.personal)
            sharingAlbum = album; sharingSnapshot = current
        }
        var record = PhotosMutationRecord(mutation: mutation)
        if case .mergePeople(let target, let sources, _) = mutation {
            var photoIDs: Set<Int> = [], checkedFolders: Set<Int> = []
            for person in [target] + sources {
                let photos = try await personPhotos(person.id)
                if let count = person.itemCount, count != photos.count { throw Self.failure(.conflict) }
                for photo in photos {
                    if checkedFolders.insert(photo.folderID).inserted { try await requireManagedFolder(photo.folderID) }
                    photoIDs.insert(photo.id.unitID)
                }
            }
            try await validatePeople([target] + sources)
            record.personPhotoIDs = photoIDs
            try Task.checkCancellation()
            try requireAccess(.personal)
        }
        // 先保留提交记录。提交后的取消、解码失败或断网都不能证明没有执行。
        mutations[operationID] = record
        do {
            let ids = mutation.photos.map(\.id.unitID)
            switch mutation {
            case .renamePerson(let person, let name):
                if person.name == name {
                    record.result = .init(state: .confirmed, person: person)
                    mutations[operationID] = record; return record.result
                }
                let receipt: PersonNameReceipt = try await call("SYNO.Foto.Browse.Person", version: 1, method: "set", parameters: ["id": .integer(person.id), "name": .string(name)])
                guard receipt.id == person.id, receipt.name == name else { throw Self.failure(.invalidResponse) }
                record.personReceipt = receipt
            case .mergePeople(let target, let sources, let name):
                try await managementWrite("SYNO.Foto.Browse.Person", version: 2, method: "merge", parameters: ["target_id": .integer(target.id), "merged_id": .integerArray(sources.map(\.id)), "name": .string(name)])
            case .edit(_, let edit):
                var params: [String: DsmParameterValue] = ["id": .integerArray(ids)]
                switch edit {
                case .rating(let value): params["rating"] = .integer(value)
                case .description(let value): params["description"] = .string(value)
                case .takenAt(let value): params["time"] = .integer(Int(value.timeIntervalSince1970))
                }
                try await managementWrite("SYNO.Foto.Browse.Item", version: 2, method: "set", parameters: params)
            case .shiftDates(let photos, let seconds):
                for photo in photos {
                    try Task.checkCancellation()
                    try requireAccess(.personal)
                    record.shiftedSubmittedIDs.insert(photo.id)
                    record.shiftingPhotoID = photo.id
                    try await managementWrite("SYNO.Foto.Browse.Item", version: 2, method: "set", parameters: [
                        "id": .integerArray([photo.id.unitID]), "time": .integer(try shiftedTimestamp(photo, seconds: seconds))])
                    record.shiftingPhotoID = nil
                }
            case .createTag(let name, let photos):
                let created: CreatedManagementTag = try await call("SYNO.Foto.Browse.GeneralTag", version: 1, method: "create", parameters: ["name": .string(name)])
                guard created.tag.id > 0, created.tag.name == name else { throw Self.failure(.invalidResponse) }
                record.createdTag = created.tag
                if !photos.isEmpty {
                    try Task.checkCancellation()
                    try requireAccess(.personal)
                    record.tagAdditionAttempted = true
                    try await managementWrite("SYNO.Foto.Browse.Item", method: "add_tag", parameters: ["id": .integerArray(ids), "tag": .integerArray([created.tag.id])])
                }
            case .addTags(_, let tags), .removeTags(_, let tags):
                let method: String
                if case .addTags = mutation { method = "add_tag" } else { method = "remove_tag" }
                try await managementWrite("SYNO.Foto.Browse.Item", method: method, parameters: ["id": .integerArray(ids), "tag": .integerArray(tags)])
            case .createConditionAlbum(let name, let condition):
                let created: CreatedConditionAlbum = try await call("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "create", parameters: ["name": .string(name), "condition": .object(try conditionParameters(condition))])
                guard created.album.id > 0 else { throw Self.failure(.invalidResponse) }
                record.albumID = created.album.id
            case .setAlbumCondition(let id, _, let condition):
                try await managementWrite("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "set_condition", parameters: ["id": .integer(id), "condition": .object(try conditionParameters(condition))])
            case .createAlbum(let name, _):
                let created: CreatedManagementAlbum = try await call("SYNO.Foto.Browse.NormalAlbum", version: 1, method: "create", parameters: ["name": .string(name), "item": .integerArray(ids)])
                guard created.album.id > 0 else { throw Self.failure(.invalidResponse) }
                record.albumID = created.album.id
            case .createFolder(let parent, let name):
                let created: CreatedManagementFolder = try await call("SYNO.Foto.Browse.Folder", version: 1, method: "create", parameters: [
                    "target_id": .integer(parent), "name": .string(name)])
                guard created.folder.id > 0 else { throw Self.failure(.invalidResponse) }
                record.folderID = created.folder.id
            case .renameAlbum(let id, let name):
                try await managementWrite("SYNO.Foto.Browse.Album", method: "set_name", parameters: ["id": .integer(id), "name": .string(name)])
            case .deleteAlbum(let id):
                try await managementWrite("SYNO.Foto.Browse.Album", method: "delete", parameters: ["id": .integerArray([id])])
            case .addToAlbum(let id, _), .removeFromAlbum(let id, _):
                let method: String
                if case .addToAlbum = mutation { method = "add_item" } else { method = "delete_item" }
                try await managementWrite("SYNO.Foto.Browse.NormalAlbum", method: method, parameters: ["id": .integer(id), "item": .integerArray(ids)])
            case .setAlbumCover(let id, let photo):
                try await managementWrite("SYNO.Foto.Browse.Album", method: "set_cover", parameters: ["id": .integer(id), "id_item": .integer(photo.id.unitID)])
            case .move(_, let folder), .copy(_, let folder):
                let method: String
                if case .move = mutation { method = "move" } else { method = "copy" }
                let task: ManagementTaskReceipt = try await call("SYNO.Foto.BackgroundTask.File", version: 1, method: method, parameters: ["target_folder_id": .integer(folder), "item_id": .integerArray(ids), "folder_id": .integerArray([]), "action": .string("skip")])
                guard task.task_info.id > 0 else { throw Self.failure(.invalidResponse) }
                record.taskID = task.task_info.id
            case .upload(let url, let size, let modified, let folder):
                record.itemID = try await uploadPhoto(url, size: size, modifiedAt: modified, folderID: folder, progress: progress)
            case .shareAlbum(let id, let access, _, let members):
                guard let album = sharingAlbum, let current = sharingSnapshot else { throw Self.failure(.invalidResponse) }
                let memberChanges = try sharingMemberChanges(from: current.members, to: members)
                if current.access == access, memberChanges.isEmpty {
                    record.result = .init(state: .confirmed, album: album.collection, sharingURL: current.url)
                    mutations[operationID] = record
                    return record.result
                }
                record.sharingBefore = album.additional?.sharing_info
                if access == .disabled, memberChanges.isEmpty {
                    try await managementWrite("SYNO.Foto.Sharing.Passphrase", method: "set_shared", parameters: ["policy": .string("album"), "album_id": .integer(id), "enabled": .boolean(false)])
                } else {
                    // 先关闭公开访问，再更新权限，最后启用；中途失败不会扩大旧权限。
                    let link: ManagementLink = try await call("SYNO.Foto.Sharing.Passphrase", version: 1, method: "set_shared", parameters: ["policy": .string("album"), "album_id": .integer(id), "enabled": .boolean(false)])
                    guard let passphrase = link.passphrase, !passphrase.isEmpty else { throw Self.failure(.invalidResponse) }
                    try Task.checkCancellation()
                    var changes = memberChanges
                    if access != .disabled, access != current.access {
                        var change: [String: DsmJSONValue] = ["action": .string(access == .invited ? "delete" : "update"), "member": .object(["type": .string("public")])]
                        if access != .invited { change["role"] = .string(access.rawValue) }
                        changes.append(change)
                    }
                    if !changes.isEmpty {
                        try await managementWrite("SYNO.Foto.Sharing.Passphrase", method: "update", parameters: ["passphrase": .string(passphrase), "permission": .objectArray(changes)])
                    }
                    if access != .disabled {
                        try Task.checkCancellation()
                        try requireAccess(.personal)
                        record.enableSharingAttempted = true
                        try await managementWrite("SYNO.Foto.Sharing.Passphrase", method: "set_shared", parameters: ["policy": .string("album"), "album_id": .integer(id), "enabled": .boolean(true)])
                    }
                }
            }
        } catch {
            let appError: AppError?
            if let networkError = error as? DsmNetworkError { appError = DsmErrorMapper.map(networkError) }
            else { appError = error as? AppError }
            let rejected = appError?.category == .permissionDenied || appError?.category == .authenticationRequired
            switch mutation {
            case .shiftDates:
                if rejected { record.shiftedRejectedID = record.shiftingPhotoID }
            case .createTag:
                if rejected, record.createdTag != nil { record.tagAdditionRejected = true }
                else if rejected { record.result = .init(state: .rejected) }
            case .shareAlbum: break
            default:
                if rejected { record.result = .init(state: .rejected) }
            }
            mutations[operationID] = record
            switch mutation {
            case .shiftDates:
                return (try? await inspectMutation(operationID)) ?? record.result
            case .createTag where record.createdTag != nil:
                return (try? await inspectMutation(operationID)) ?? record.result
            default: return record.result
            }
        }
        mutations[operationID] = record
        return (try? await inspectMutation(operationID)) ?? record.result
    }

    private func managementWrite(_ name: String, version: Int = 1, method: String, parameters: [String: DsmParameterValue]) async throws {
        guard let capability = capabilities[name], capability.minVersion <= version, capability.maxVersion >= version, capability.requestFormat == .json else { throw Self.failure(.apiUnavailable) }
        try await client.callVoid(path: capability.path, api: name, version: version, method: method, requestFormat: .json, parameters: parameters, credential: credential)
    }

    public func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        try requireAccess(.personal)
        guard let record = mutations[operationID] else { throw Self.failure(.conflict) }
        if record.result.state != .pendingReview || mutationInFlight { return record.result }
        mutationInFlight = true
        defer { mutationInFlight = false }
        return try await inspectMutation(operationID)
    }

    private func inspectMutation(_ operationID: UUID) async throws -> SynologyPhotosMutationResult {
        try requireAccess(.personal)
        guard var record = mutations[operationID] else { throw Self.failure(.conflict) }
        var result = SynologyPhotosMutationResult(state: .pendingReview)
        switch record.mutation {
        case .renamePerson(let original, let name):
            let people = try await managementPeople()
            if let person = people.first(where: { $0.id == original.id }), person.name == name {
                result = .init(state: .confirmed, person: person)
            } else if name.isEmpty, original.itemCount.map({ $0 < 2 }) == true,
                      record.personReceipt?.id == original.id, record.personReceipt?.name == name,
                      !people.contains(where: { $0.id == original.id }) {
                // 官方在少于两张照片的人物清空名称后重新加载；已确认回执与列表隐去共同验证。
                result = .init(state: .confirmed, person: .init(id: original.id, name: name, itemCount: original.itemCount), removedPersonIDs: [original.id])
            }
        case .mergePeople(let target, let sources, let name):
            let people = try await managementPeople()
            if let person = people.first(where: { $0.id == target.id }), person.name == name,
               sources.allSatisfy({ source in !people.contains { $0.id == source.id } }),
               let expected = record.personPhotoIDs,
               Set(try await personPhotos(target.id).map { $0.id.unitID }) == expected {
                result = .init(state: .confirmed, person: person, removedPersonIDs: sources.map(\.id))
            }
        case .edit(let originals, _), .addTags(let originals, _), .removeTags(let originals, _):
            var updated: [SynologyPhoto] = []
            for original in originals {
                let photo = try await details(for: original)
                guard photo.filename == original.filename, photo.sizeBytes == original.sizeBytes, photo.folderID == original.folderID, photo.indexedAt == original.indexedAt else { throw Self.failure(.conflict) }
                let matches: Bool
                switch record.mutation {
                case .edit(_, let value):
                    switch value {
                    case .rating(let rating): matches = photo.rating == rating
                    case .description(let description): matches = photo.description == description
                    case .takenAt(let date): matches = Int(photo.takenAt.timeIntervalSince1970) == Int(date.timeIntervalSince1970)
                    }
                case .addTags(_, let ids): matches = photo.tags.map { Set(ids).isSubset(of: Set($0.map(\.id))) } ?? false
                case .removeTags(_, let ids): matches = photo.tags.map { Set(ids).isDisjoint(with: Set($0.map(\.id))) } ?? false
                default: matches = false
                }
                if matches { updated.append(photo) }
            }
            result = SynologyPhotosMutationResult(state: updated.count == originals.count ? .confirmed : .pendingReview, photos: updated, completedCount: updated.count)
        case .shiftDates(let originals, let seconds):
            var updated: [SynologyPhoto] = []
            for original in originals where record.shiftedSubmittedIDs.contains(original.id) {
                let photo = try await details(for: original)
                guard photo.filename == original.filename, photo.sizeBytes == original.sizeBytes,
                      photo.folderID == original.folderID, photo.indexedAt == original.indexedAt else { throw Self.failure(.conflict) }
                if Int(photo.takenAt.timeIntervalSince1970) == (try shiftedTimestamp(original, seconds: seconds)) { updated.append(photo) }
            }
            let confirmed = Set(updated.map(\.id))
            let resolved = confirmed.union(record.shiftedRejectedID.map { [$0] } ?? [])
            let state: SynologyPhotosMutationResult.State = updated.count == originals.count ? .confirmed
                : (record.shiftedSubmittedIDs.isSubset(of: resolved) ? .partial : .pendingReview)
            result = .init(state: state, photos: updated, completedCount: updated.count)
        case .createTag(let name, let originals):
            if let tag = record.createdTag, try await verifyTag(tag) {
                var updated: [SynologyPhoto] = []
                for original in originals {
                    let photo = try await details(for: original)
                    guard photo.filename == original.filename, photo.sizeBytes == original.sizeBytes,
                          photo.folderID == original.folderID, photo.indexedAt == original.indexedAt else { throw Self.failure(.conflict) }
                    if photo.tags?.contains(where: { $0.id == tag.id && $0.name == name }) == true { updated.append(photo) }
                }
                result = .init(state: updated.count == originals.count ? .confirmed : ((record.tagAdditionRejected || !record.tagAdditionAttempted) ? .partial : .pendingReview),
                    photos: updated, completedCount: updated.count, tag: tag)
            }
        case .createAlbum(let name, let photos):
            if let id = record.albumID {
                let album = try await managedAlbum(id)
                if album.name == name, try await verifyAlbumMembership(id, photos: photos, present: true) {
                    result = SynologyPhotosMutationResult(state: .confirmed, album: album.collection, completedCount: photos.count)
                }
            }
        case .createConditionAlbum(let name, let condition):
            if let id = record.albumID {
                let album = try await managedAlbum(id)
                let current = try await albumCondition(id: id)
                if album.name == name, try conditionParameters(current) == conditionParameters(condition) {
                    result = .init(state: .confirmed, album: album.collection)
                }
            }
        case .setAlbumCondition(let id, _, let condition):
            let current = try await albumCondition(id: id)
            if try conditionParameters(current) == conditionParameters(condition) {
                result = .init(state: .confirmed, album: try await managedAlbum(id).collection)
            }
        case .renameAlbum(let id, let name):
            let album = try await managedAlbum(id)
            if album.name == name { result = SynologyPhotosMutationResult(state: .confirmed, album: album.collection) }
        case .createFolder(let parent, let name):
            if let id = record.folderID {
                let payload: FolderPayload = try await call("SYNO.Foto.Browse.Folder", version: 2, method: "get", parameters: [
                    "id": .integer(id), "additional": .stringArray(["access_permission"])])
                let folder = payload.folder
                if folder.id == id, folder.parent == parent, folder.collection.name == name,
                   folder.additional?.access_permission?.view == true, folder.additional?.access_permission?.manage == true {
                    result = .init(state: .confirmed, folder: folder.collection)
                }
            }
        case .deleteAlbum(let id):
            let payload: ManagementAlbums = try await call("SYNO.Foto.Browse.Album", version: 4, method: "get", parameters: ["id": .integerArray([id])])
            if payload.list.isEmpty { result = SynologyPhotosMutationResult(state: .confirmed) }
        case .addToAlbum(let id, let photos), .removeFromAlbum(let id, let photos):
            let present: Bool
            if case .addToAlbum = record.mutation { present = true } else { present = false }
            if try await verifyAlbumMembership(id, photos: photos, present: present) { result = SynologyPhotosMutationResult(state: .confirmed, completedCount: photos.count) }
        case .setAlbumCover(let id, let photo):
            let album = try await managedAlbum(id)
            if album.additional?.thumbnail?.unit_id == photo.id.unitID { result = SynologyPhotosMutationResult(state: .confirmed, album: album.collection) }
        case .move(let photos, let folder), .copy(let photos, let folder):
            if let taskID = record.taskID {
                let tasks: ManagementTaskList = try await call("SYNO.Foto.BackgroundTask.Info", version: 1, method: "get_status", parameters: ["id": .integerArray([taskID])])
                if tasks.list.count == 1, let task = tasks.list.first, task.id == taskID, task.status == "done" {
                    guard task.completion >= 0, task.error >= 0, task.skip >= 0, task.overwrite == 0 else { throw Self.failure(.invalidResponse) }
                    if task.error > 0 || task.skip > 0 { result = SynologyPhotosMutationResult(state: .partial, completedCount: task.completion) }
                    else if task.completion == photos.count {
                        var updated: [SynologyPhoto] = []
                        if case .move = record.mutation {
                            for photo in photos {
                                let moved = try await details(for: photo)
                                guard moved.folderID == folder, moved.sizeBytes == photo.sizeBytes, moved.filename == photo.filename else { throw Self.failure(.conflict) }
                                updated.append(moved)
                            }
                        }
                        result = SynologyPhotosMutationResult(state: .confirmed, photos: updated, completedCount: task.completion)
                    }
                }
            }
        case .upload(_, let size, _, let folder):
            if let id = record.itemID {
                let placeholder = SynologyPhoto(id: SynologyPhotoID(profileID: profileID, space: .personal, unitID: id), filename: "", sizeBytes: size, takenAt: .distantPast, indexedAt: .distantPast, folderID: folder ?? 0, mediaType: "")
                let uploaded = try await details(for: placeholder)
                if uploaded.sizeBytes == size, folder == nil || uploaded.folderID == folder { result = SynologyPhotosMutationResult(state: .confirmed, photos: [uploaded], completedCount: 1) }
            }
        case .shareAlbum(let id, let access, _, let members):
            let album = try await managedAlbum(id)
            let currentMembers = sharingMembers(album.additional?.sharing_info?.permission)
            let expectedMembers = members ?? sharingMembers(record.sharingBefore?.permission)
            let membersMatch = expectedMembers.map { expected in currentMembers.map { sharingMemberRoles($0) == sharingMemberRoles(expected) } ?? false } ?? true
            let protectionsMatch = album.additional?.sharing_info?.enable_password == record.sharingBefore?.enable_password && album.additional?.sharing_info?.expiration == record.sharingBefore?.expiration
            if access == .disabled, album.shared == false, members == nil || (membersMatch && protectionsMatch) { result = SynologyPhotosMutationResult(state: .confirmed, album: album.collection) }
            else if access != .disabled, !record.enableSharingAttempted, album.shared == false {
                result = SynologyPhotosMutationResult(state: .partial, album: album.collection)
            }
            else if membersMatch, album.shared == true, album.additional?.sharing_info?.privacy_type == (access == .invited ? "private" : "public-\(access.rawValue)"),
                    album.additional?.sharing_info?.enable_password == record.sharingBefore?.enable_password,
                    album.additional?.sharing_info?.expiration == record.sharingBefore?.expiration,
                    let raw = album.additional?.sharing_info?.sharing_link, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil {
                result = SynologyPhotosMutationResult(state: .confirmed, album: album.collection, sharingURL: url)
            }
        }
        record.result = result
        mutations[operationID] = record
        return result
    }

    private func verifyTag(_ tag: SynologyPhotoFilterChoice) async throws -> Bool {
        var offset = 0
        while true {
            let page = try await categoryItems(.tags, offset: offset, limit: 500)
            if let match = page.first(where: { $0.id == tag.id }) { return match.name == tag.name }
            if page.count < 500 { return false }
            offset += page.count
            try Task.checkCancellation()
        }
    }

    private func verifyAlbumMembership(_ id: Int, photos targets: [SynologyPhoto], present: Bool) async throws -> Bool {
        var remaining = Set(targets.map(\.id))
        var offset = 0
        repeat {
            let page = try await photos(in: .personal, query: .album(id: id), offset: offset, limit: 500)
            remaining.subtract(page.items.map(\.id))
            if present && remaining.isEmpty { return true }
            if !present && remaining.count != targets.count { return false }
            if !page.hasMore { return present ? remaining.isEmpty : remaining.count == targets.count }
            offset = page.nextOffset
            try Task.checkCancellation()
        } while true
    }
}

private struct ManagementAlbums: Decodable, Sendable { let list: [ManagementAlbum] }
private struct CreatedManagementTag: Decodable, Sendable { let tag: SynologyPhotoFilterChoice }
private struct CreatedManagementAlbum: Decodable, Sendable { let album: ManagementAlbum }
private struct CreatedManagementFolder: Decodable, Sendable {
    let folder: Folder
    struct Folder: Decodable, Sendable { let id: Int }
}
private struct ManagementAlbum: Decodable, Sendable {
    let type: String?
    let id: Int; let name: String; let item_count: Int?; let owner_user_id: Int?; let shared: Bool?
    let additional: Additional?
    struct Additional: Decodable, Sendable { let thumbnail: ItemPayload.Thumbnail?; let sharing_info: Sharing? }
    struct Sharing: Codable, Sendable {
        let privacy_type: String?; let sharing_link: String?; let passphrase: String?
        let enable_password: Bool?; let expiration: SynologyPhotoConditionValue?; let permission: SynologyPhotoConditionValue?
    }
    var collection: SynologyPhotoCollection { SynologyPhotoCollection(id: id, name: name, itemCount: item_count, thumbnail: additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) }, isConditional: type == "condition") }
}
private struct ManagementLink: Decodable, Sendable { let passphrase: String? }
private struct ManagementTaskReceipt: Decodable, Sendable {
    let task_info: TaskInfo
    struct TaskInfo: Decodable, Sendable { let id: Int }
}
private struct ManagementTaskList: Decodable, Sendable {
    let list: [TaskInfo]
    struct TaskInfo: Decodable, Sendable { let id: Int; let status: String; let completion: Int; let error: Int; let skip: Int; let overwrite: Int }
}

extension SynologyPhotosRepository {
    private func uploadPhoto(_ source: URL, size: Int64, modifiedAt: Date, folderID: Int?, progress: @escaping FileTransferProgress) async throws -> Int {
        guard let binaryTransport = transport as? any DsmBinaryHTTPTransport, let capability = capabilities["SYNO.Foto.Upload.Item"] else { throw Self.failure(.apiUnavailable) }
        let boundary = "LanStash-Photos-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).photos-upload")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Self.failure(.invalidResponse) }
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        let output = try FileHandle(forWritingTo: bodyURL)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? output.close(); try? input.close() }
        func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        let method = folderID == nil ? "upload" : "upload_to_folder"
        var fields = ["api": capability.name, "method": method, "version": "1",
                      "duplicate": try json("rename"), "name": try json(source.lastPathComponent), "mtime": String(Int(modifiedAt.timeIntervalSince1970))]
        if let folderID { fields["target_folder_id"] = String(folderID) }
        else { fields["folder"] = try json(["PhotoLibrary"]); fields["uploadDestination"] = try json("timeline") }
        for key in fields.keys.sorted() {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n")
        }
        // 文件名通过 name 字段传送；multipart 头使用固定名称，避免控制字符注入。
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"upload\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        var copied: Int64 = 0
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            copied += Int64(chunk.count)
            guard copied <= size else { throw deletionError(.conflict, "photos.manage.fileChanged") }
            try output.write(contentsOf: chunk)
        }
        let values = try source.resourceValues(forKeys: [.contentModificationDateKey])
        guard copied == size, values.contentModificationDate == modifiedAt else { throw deletionError(.conflict, "photos.manage.fileChanged") }
        try write("\r\n--\(boundary)--\r\n")
        try output.synchronize()
        var request = try DsmRequestBuilder.build(baseURL: baseURL, path: capability.path, api: capability.name, version: 1, method: method, requestFormat: .json, parameters: [:], credential: credential)
        request.httpBody = nil
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(try output.offset()), forHTTPHeaderField: "Content-Length")
        try Task.checkCancellation()
        try requireAccess(.personal)
        let response = try await binaryTransport.upload(request, from: bodyURL, progress: progress)
        guard (200...299).contains(response.statusCode) else { throw Self.failure(.invalidResponse) }
        let envelope = try JSONDecoder().decode(PhotosUploadEnvelope.self, from: response.data)
        guard envelope.success, let id = envelope.data?.id, id > 0 else { throw Self.failure(.invalidResponse) }
        return id
    }
}
private struct PhotosUploadEnvelope: Decodable, Sendable {
    let success: Bool
    let data: Receipt?
    struct Receipt: Decodable, Sendable { let id: Int; let action: String? }
}

private struct CreatedConditionAlbum: Decodable, Sendable {
    let album: Identifier
    struct Identifier: Decodable, Sendable { let id: Int }
}
private struct ConditionAlbumList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable {
        let id: Int
        let additional: Additional
        struct Additional: Decodable, Sendable { let condition_object: [String: SynologyPhotoConditionValue] }
    }
}

extension SynologyPhotosRepository {
    public func albumCondition(id: Int) async throws -> SynologyPhotoAlbumCondition {
        try requireAccess(.personal)
        let album = try await managedAlbum(id)
        guard album.type == "condition", let user = currentUserID, album.owner_user_id == user else { throw Self.failure(.permissionDenied) }
        let payload: ConditionAlbumList = try await call("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "get", parameters: [
            "id": .integerArray([id]), "additional": .stringArray(["condition_object"])])
        guard payload.list.count == 1, let entry = payload.list.first, entry.id == id,
              entry.additional.condition_object["user_id"]?.integer == user else { throw Self.failure(.permissionDenied) }
        var condition = SynologyPhotoAlbumCondition(fields: entry.additional.condition_object)
        let references = ["folder_filter", "rating", "person", "concept", "general_tag", "camera", "lens", "aperture", "iso", "geocoding"]
        for key in references {
            guard let raw = condition.fields[key] else { continue }
            guard let values = raw.array else { throw Self.failure(.invalidResponse) }
            var ids: [SynologyPhotoConditionValue] = []
            for value in values {
                guard let object = value.object, let id = object["id"]?.integer else { throw Self.failure(.invalidResponse) }
                ids.append(.integer(id))
                condition.names[key, default: []].append(.init(name: object["name"]?.string ?? L10n.string("photos.condition.missingReference", id), value: .integer(id)))
            }
            condition.fields[key] = .array(ids)
        }
        return condition
    }

    public func conditionSuggestions(keyword: String) async throws -> [String: [SynologyPhotoConditionOption]] {
        try requireAccess(.personal)
        guard let user = currentUserID, user > 0 else { throw Self.failure(.permissionDenied) }
        let keys = SynologyPhotoConditionField.allCases.filter { ![.keyword, .flash].contains($0) }.map(\.rawValue)
        let raw: [String: SynologyPhotoConditionValue] = try await call("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "suggest", parameters: [
            "keyword": .string(keyword), "user_id": .integer(user), "condition": .stringArray(keys), "additional": .stringArray(["thumbnail"])])
        var result: [String: [SynologyPhotoConditionOption]] = [:]
        func location(_ entry: SynologyPhotoConditionValue, parents: [String], parentID: Int? = nil) throws {
            guard let object = entry.object, let name = object["name"]?.string, let id = object["id"]?.integer else { throw Self.failure(.invalidResponse) }
            let names = parents + [name], children = object["children"]?.array ?? []
            if children.isEmpty {
                let repeatsParent = name == parents.last && parentID != nil
                result["geocoding", default: []].append(.init(name: (repeatsParent ? parents : names).joined(separator: ", "), value: .integer(repeatsParent ? parentID! : id)))
            } else { for child in children { try location(child, parents: names, parentID: id) } }
        }
        for key in keys {
            guard let data = raw[key] else { continue }
            guard let values = data.array else { throw Self.failure(.invalidResponse) }
            for value in values {
                if key == "geocoding" { try location(value, parents: []); continue }
                guard let object = value.object else { throw Self.failure(.invalidResponse) }
                if key == "focal_length_group" || key == "exposure_time_group" {
                    guard object["start"] != nil, object["end"] != nil else { throw Self.failure(.invalidResponse) }
                    result[key, default: []].append(.init(name: conditionRangeTitle(value), value: value))
                } else {
                    guard let id = object["id"]?.integer, let name = object["name"]?.string else { throw Self.failure(.invalidResponse) }
                    result[key, default: []].append(.init(name: name, value: .integer(id)))
                }
            }
        }
        return result
    }

    public func conditionItemCount(_ condition: SynologyPhotoAlbumCondition) async throws -> Int {
        try requireAccess(.personal)
        struct Count: Decodable, Sendable { let count: Int }
        let result: Count = try await call("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "peek_item_count", parameters: ["condition": .object(try conditionParameters(condition))])
        guard result.count >= 0 else { throw Self.failure(.invalidResponse) }
        return result.count
    }

    private func validateCondition(_ condition: SynologyPhotoAlbumCondition) async throws {
        _ = try conditionParameters(condition)
        for value in condition.values("folder_filter") {
            guard let id = value.integer, id > 0 else { throw Self.failure(.invalidResponse) }
            let folder: FolderPayload = try await call("SYNO.Foto.Browse.Folder", version: 2, method: "get", parameters: ["id": .integer(id), "additional": .stringArray(["access_permission"])])
            guard folder.folder.id == id, folder.folder.additional?.access_permission?.view == true else { throw Self.failure(.permissionDenied) }
        }
    }

    private func conditionParameters(_ condition: SynologyPhotoAlbumCondition) throws -> [String: DsmJSONValue] {
        guard let user = currentUserID, user > 0,
              condition.fields["user_id"] == nil || condition.fields["user_id"]?.integer == user else { throw Self.failure(.permissionDenied) }
        var fields = condition.fields
        fields["user_id"] = .integer(user)
        fields["item_type"] = fields["item_type"] ?? .array([])
        for field in SynologyPhotoConditionField.allCases where !condition.values(field.rawValue).isEmpty && field.supportsPolicy {
            guard let policy = fields[field.rawValue + "_policy"]?.string, ["and", "or"].contains(policy) else { throw Self.failure(.invalidResponse) }
        }
        for time in condition.values("time") {
            guard let object = time.object else { throw Self.failure(.invalidResponse) }
            let start = object["start_time"]?.integer, end = object["end_time"]?.integer
            guard start != nil || end != nil, start.map({ $0 >= 0 }) ?? true, end.map({ $0 >= 0 }) ?? true,
                  start == nil || end == nil || start! <= end! else { throw Self.failure(.invalidResponse) }
        }
        guard condition.values("rating").allSatisfy({ $0.integer.map { (0...5).contains($0) } ?? false }) else { throw Self.failure(.invalidResponse) }
        func json(_ value: SynologyPhotoConditionValue) -> DsmJSONValue {
            switch value {
            case .integer(let value): .integer(value)
            case .decimal(let value): .decimal(value)
            case .null: .null
            case .string(let value): .string(value)
            case .boolean(let value): .boolean(value)
            case .array(let values): .array(values.map(json))
            case .object(let values): .object(values.mapValues(json))
            }
        }
        // 只归一化已知集合字段，未知字段的空数组与顺序必须原样保留。
        let setFields = Set(SynologyPhotoConditionField.allCases.map(\.rawValue) + ["folder_filter", "rating", "item_type", "time"])
        for (key, value) in fields where setFields.contains(key) {
            if let values = value.array {
                if values.isEmpty && key != "item_type" { fields[key] = nil; continue }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                fields[key] = .array(try values.sorted { try encoder.encode($0).lexicographicallyPrecedes(encoder.encode($1)) })
            }
        }
        return fields.mapValues(json)
    }

    private func conditionRangeTitle(_ value: SynologyPhotoConditionValue) -> String {
        func title(_ value: SynologyPhotoConditionValue?) -> String {
            if let number = value?.integer { return number.formatted(.number.locale(L10n.locale)) }
            if case .decimal(let number) = value { return number.formatted(.number.locale(L10n.locale)) }
            if let fraction = value?.object, let num = fraction["num"]?.integer, let den = fraction["den"]?.integer { return "\(num)/\(den)" }
            return "—"
        }
        return L10n.string("photos.condition.range", title(value.object?["start"]), title(value.object?["end"]))
    }
}


extension SynologyPhotosRepository {
    public func albumSharing(id: Int) async throws -> SynologyPhotoSharingState {
        try requireAccess(.personal)
        let album = try await managedAlbum(id)
        guard let user = currentUserID, user > 0, album.owner_user_id == user else { throw Self.failure(.permissionDenied) }
        return try sharingState(album)
    }

    public func sharingRecipients() async throws -> [SynologyPhotoShareRecipient] {
        try requireAccess(.personal)
        let generation = accessGeneration
        struct Payload: Decodable, Sendable { let list: [SynologyPhotoConditionValue] }
        let result: Payload = try await call("SYNO.Foto.Sharing.Misc", version: 1, method: "list_user_group", parameters: ["team_space_sharable_list": .boolean(false)])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try requireAccess(.personal)
        let recipients = try result.list.map { value in
            guard let recipient = sharingRecipient(value) else { throw Self.failure(.invalidResponse) }
            return recipient
        }.filter { $0.id.type != "user" || $0.id.value != currentUserUID }
        guard Set(recipients.map(\.id)).count == recipients.count else { throw Self.failure(.invalidResponse) }
        return recipients
    }

    private func sharingRecipient(_ value: SynologyPhotoConditionValue) -> SynologyPhotoShareRecipient? {
        guard let fields = value.object, let type = fields["type"]?.string, ["user", "group"].contains(type),
              let id = fields["id"], let name = fields["name"]?.string else { return nil }
        switch id {
        case .integer(let number): guard number > 0 else { return nil }
        case .string(let text): guard !text.isEmpty else { return nil }
        default: return nil
        }
        return .init(id: .init(type: type, value: id), name: name)
    }

    private func sharingMembers(_ value: SynologyPhotoConditionValue?) -> [SynologyPhotoShareGrant]? {
        guard let values = value?.array else { return nil }
        var grants: [SynologyPhotoShareGrant] = []
        for value in values {
            if value.object?["type"]?.string == "public" { continue }
            guard let recipient = sharingRecipient(value), let role = value.object?["role"]?.string else { return nil }
            grants.append(.init(recipient: recipient, role: role))
        }
        guard Set(grants.map(\.id)).count == grants.count else { return nil }
        return grants
    }

    private func sharingMemberRoles(_ members: [SynologyPhotoShareGrant]) -> [SynologyPhotoShareRecipient.ID: String] {
        Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.role) })
    }

    private func validateSharingMembers(_ members: [SynologyPhotoShareGrant], original: [SynologyPhotoShareGrant], conditional: Bool) throws {
        guard Set(members.map(\.id)).count == members.count, Set(original.map(\.id)).count == original.count else { throw Self.failure(.invalidResponse) }
        let roles = sharingMemberRoles(original)
        for member in members {
            guard ["user", "group"].contains(member.id.type) else { throw Self.failure(.invalidResponse) }
            if roles[member.id] != member.role {
                guard (conditional ? ["view", "download"] : ["view", "download", "upload"]).contains(member.role),
                      member.id.type != "user" || member.id.value != currentUserUID else { throw Self.failure(.permissionDenied) }
            }
        }
    }

    private func sharingMemberChanges(from original: [SynologyPhotoShareGrant]?, to desired: [SynologyPhotoShareGrant]?) throws -> [[String: DsmJSONValue]] {
        guard let desired else { return [] }
        guard let original else { throw Self.failure(.invalidResponse) }
        let before = sharingMemberRoles(original), after = sharingMemberRoles(desired)
        func change(_ member: SynologyPhotoShareGrant, remove: Bool) throws -> [String: DsmJSONValue] {
            let id: DsmJSONValue
            switch member.id.value {
            case .integer(let number): id = .integer(number)
            case .string(let text): id = .string(text)
            default: throw Self.failure(.invalidResponse)
            }
            var fields: [String: DsmJSONValue] = ["action": .string(remove ? "delete" : "update"),
                "member": .object(["type": .string(member.id.type), "id": id])]
            if !remove { fields["role"] = .string(member.role) }
            return fields
        }
        return try original.filter { after[$0.id] == nil }.map { try change($0, remove: true) } +
            desired.filter { before[$0.id] != $0.role }.map { try change($0, remove: false) }
    }

    private func sharingState(_ album: ManagementAlbum) throws -> SynologyPhotoSharingState {
        let info = album.additional?.sharing_info
        let access: SynologyPhotoLinkAccess
        if album.shared == false { access = .disabled }
        else if album.shared == true {
            switch info?.privacy_type {
            case "private": access = .invited
            case "public-view": access = .view
            case "public-download": access = .download
            default: throw Self.failure(.invalidResponse)
            }
        } else { throw Self.failure(.invalidResponse) }
        struct Revision: Encodable { let id: Int; let enabled: Bool?; let info: ManagementAlbum.Sharing? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(Revision(id: album.id, enabled: album.shared, info: info)))
        let revision = digest.map { String(format: "%02x", $0) }.joined()
        let url = info?.sharing_link.flatMap(URL.init(string:)).flatMap { value in
            ["https", "http"].contains(value.scheme?.lowercased() ?? "") && value.host != nil && value.user == nil && value.password == nil ? value : nil
        }
        let hasExpiration: Bool?
        switch info?.expiration {
        case .integer(let value): hasExpiration = value > 0
        case .decimal(let value): hasExpiration = value > 0
        default: hasExpiration = nil
        }
        return .init(access: access, url: access == .disabled ? nil : url, hasPassword: info?.enable_password,
            hasExpiration: hasExpiration, revision: revision, members: sharingMembers(info?.permission))
    }
}


private struct PersonNameReceipt: Decodable, Sendable { let id: Int; let name: String }

extension SynologyPhotosRepository {
    public func managementPeople() async throws -> [SynologyPhotoCollection] {
        var people: [SynologyPhotoCollection] = [], seen: Set<Int> = []
        while true {
            try Task.checkCancellation()
            let page = try await categoryItems(.person, offset: people.count, limit: 500)
            for person in page {
                guard seen.insert(person.id).inserted else { throw Self.failure(.conflict) }
                people.append(person)
            }
            if page.count < 500 { return people }
        }
    }

    private func validatePeople(_ originals: [SynologyPhotoCollection]) async throws {
        guard !originals.isEmpty, originals.allSatisfy({ $0.id > 0 }), Set(originals.map(\.id)).count == originals.count else { throw Self.failure(.invalidResponse) }
        let current = try await managementPeople()
        for original in originals {
            guard let person = current.first(where: { $0.id == original.id }), person.name == original.name,
                  original.itemCount == nil || person.itemCount == original.itemCount else { throw Self.failure(.conflict) }
        }
    }

    private func personPhotos(_ id: Int) async throws -> [SynologyPhoto] {
        let days = try await categoryTimeline(.person, id: id)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = days.compactMap { calendar.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day)) }
        guard dates.count == days.count else { throw Self.failure(.invalidResponse) }
        guard let first = dates.min(), let last = dates.max() else { return [] }
        let start = max(0, Int(first.timeIntervalSince1970) - 86_400), end = Int(last.timeIntervalSince1970) + 172_800
        var items: [SynologyPhoto] = [], seen: Set<SynologyPhotoID> = [], offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await photos(in: .personal, query: .category(.person, id: id, startTime: start, endTime: end), offset: offset, limit: 500)
            for photo in page.items {
                guard seen.insert(photo.id).inserted else { throw Self.failure(.conflict) }
                items.append(photo)
            }
            if !page.hasMore { return items }
            offset = page.nextOffset
        }
    }
}
