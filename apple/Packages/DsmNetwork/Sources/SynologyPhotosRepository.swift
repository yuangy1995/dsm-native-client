import DsmCore
import DsmLocalization
import Foundation

/// Synology Photos 内部只读接口。版本与字段证据见 photos-library-read.md。
/// 不实现 File Station 降级，不读取旧照片缓存；写能力另行验证后接入。
public actor SynologyPhotosRepository: SynologyPhotosServing {
    public static let discoveryAPIs = [
        "SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin",
        "SYNO.Foto.Setting.TeamSpace", "SYNO.Foto.Browse.Timeline", "SYNO.Foto.Browse.Item",
        "SYNO.Foto.Browse.Folder", "SYNO.Foto.Browse.Album", "SYNO.Foto.Browse.RecentlyAdded",
        "SYNO.Foto.Search.Search", "SYNO.Foto.Thumbnail", "SYNO.Foto.Streaming", "SYNO.Foto.Download",
        "SYNO.Foto.Search.Filter", "SYNO.Foto.Browse.Category", "SYNO.Foto.Browse.Person",
        "SYNO.Foto.Browse.Concept", "SYNO.Foto.Browse.Geocoding", "SYNO.Foto.Browse.GeneralTag",
        "SYNO.Foto.Sharing.Misc", "SYNO.Foto.PhotoRequest", "SYNO.Foto.Browse.Unit",
        "SYNO.Foto.BackgroundTask.File"
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
    private let deletionEnabled: Bool
    private var deletionLocks: Set<SynologyPhotoID> = []
    private var pendingDeletions: [SynologyPhotoID: SynologyPhoto] = [:]
    private var deletionOperations: [UUID: SynologyPhotoID] = [:]
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
        return payload.list.map { SynologyPhotoCollection(id: $0.id, name: $0.name, itemCount: $0.item_count) }
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
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).photos-download")
        defer { try? FileManager.default.removeItem(at: staging) }
        let response = try await binary.download(request, to: staging, progress: progress)
        guard response.statusCode == 200 else { throw DsmErrorMapper.map(.httpStatus(code: response.statusCode, requestID: UUID())) }
        let type = response.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        guard !type.contains("json"), !type.contains("html"), !type.contains("zip") else { throw Self.failure(.invalidResponse) }
        let size = (try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value
        guard size == photo.sizeBytes else { throw Self.failure(.invalidResponse) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: destination)
    }

    private func requirePhoto(_ photo: SynologyPhoto) throws {
        try requireAccess(photo.id.space)
        guard photo.id.profileID == profileID, photo.id.unitID > 0 else { throw Self.failure(.permissionDenied) }
    }

    public func prepareDeletion(_ photo: SynologyPhoto) async throws {
        try requirePhoto(photo)
        guard photo.id.space == .personal, deletionEnabled else {
            throw deletionError(.apiUnavailable, "photos.delete.unverified")
        }
        guard let deleteCapability = capabilities["SYNO.Foto.BackgroundTask.File"],
              deleteCapability.minVersion <= 1, deleteCapability.maxVersion >= 1,
              deleteCapability.requestFormat == .json else {
            throw deletionError(.versionUnsupported, "photos.delete.unverified")
        }
        let current = try await details(for: photo)
        guard Self.sameDeletionTarget(photo, current) else { throw deletionError(.conflict, "photos.delete.changed") }
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
        let payload: ItemList = try await call("SYNO.Foto.Browse.Item", version: 5, method: "get",
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
            people: payload.person.map { SynologyPhotoCollection(id: $0.id, name: $0.name, itemCount: $0.item_count) },
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
        guard payload.list.count <= limit, payload.list.allSatisfy({ $0.id > 0 }) else { throw Self.failure(.invalidResponse) }
        return payload.list.map { SynologyPhotoCollection(id: $0.id, name: $0.name, itemCount: $0.item_count) }
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

private struct UserPayload: Decodable, Sendable { let enabled: Bool }
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
private struct AlbumEntry: Decodable, Sendable { let id: Int; let name: String; let item_count: Int? }

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
