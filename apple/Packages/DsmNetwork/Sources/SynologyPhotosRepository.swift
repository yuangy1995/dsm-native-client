import DsmCore
import DsmLocalization
import Foundation
import CryptoKit
import ImageIO

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
        "SYNO.Foto.Browse.Similar", "SYNO.Foto.Browse.SimilarItem", "SYNO.Foto.Browse.SimilarTimeline",
        "SYNO.Foto.Sharing.Misc", "SYNO.Foto.PhotoRequest", "SYNO.Foto.Browse.Unit",
        "SYNO.Foto.BackgroundTask.File", "SYNO.Foto.BackgroundTask.Info",
        "SYNO.Foto.RegeneratePreview", "SYNO.Foto.Upload.ConvertedFile", "SYNO.Foto.Upload.Face", "SYNO.Foto.Browse.NormalAlbum", "SYNO.Foto.Browse.ConditionAlbum", "SYNO.Foto.Upload.Item", "SYNO.Foto.Sharing.Passphrase"
    ] + [
        "SYNO.FotoTeam.Browse.Timeline", "SYNO.FotoTeam.Browse.Item", "SYNO.FotoTeam.Browse.Folder",
        "SYNO.FotoTeam.Browse.Person", "SYNO.FotoTeam.Browse.Concept", "SYNO.FotoTeam.Browse.Geocoding",
        "SYNO.FotoTeam.Browse.Similar", "SYNO.FotoTeam.Browse.SimilarItem", "SYNO.FotoTeam.Browse.SimilarTimeline",
        "SYNO.FotoTeam.Browse.RecentlyAdded", "SYNO.FotoTeam.Search.Search", "SYNO.FotoTeam.Search.Filter",
        "SYNO.FotoTeam.Thumbnail", "SYNO.FotoTeam.Streaming", "SYNO.FotoTeam.Download", "SYNO.FotoTeam.Browse.Unit",
        "SYNO.FotoTeam.Sharing.FolderPermission", "SYNO.FotoTeam.Sharing.FolderBatchPermission", "SYNO.FotoTeam.Upload.Face", "SYNO.FotoTeam.RegeneratePreview", "SYNO.FotoTeam.Upload.ConvertedFile", "SYNO.FotoTeam.Upload.Item", "SYNO.FotoTeam.Browse.GeneralTag", "SYNO.FotoTeam.BackgroundTask.File"
    ]
    private let profileID: UUID
    private let capabilities: CapabilitySet
    private let credential: DsmSessionCredential
    private let client: DsmAPIClient
    private let baseURL: URL
    private let transport: any DsmHTTPTransport
    private let pinnedCertificate: String?
    private let previewEvents: @Sendable () throws -> SynologyPhotosPreviewEvents
    private var allowedSpaces: Set<SynologyPhotoSpace> = []
    private var isPhotosAdministrator = false
    private var hasPhotosAccess = false
    private var defaultFolderSort = SynologyPhotoSort()
    private var supportsOriginalSizeJPEG = false
    private var jpegConversions: Set<SynologyPhotoID> = []
    private var managesSharedSpace = false
    private var accessGeneration = 0
    private var categoryThumbnails: [SynologyPhotoSpace: [SynologyPhotoCategory: [Int: SynologyPhotoThumbnail]]] = [:]
    private var sharedCategorySettings: Set<SynologyPhotoCategory> = []
    private var personalRecognition: [SynologyPhotoCategory: Bool] = [:]
    private var personalSimilarEnabled = false
    private var personThumbnailTypes: [SynologyPhotoSpace: [Int: String]] = [:]
    private var photoFaceIDs: [SynologyPhotoID: Set<Int>] = [:]
    private var authorizedFaces: [SynologyPhotoSpace: [Int: SynologyPhotoFace]] = [:]
    private var currentUserID: Int?
    private var codecGenerationAcknowledgedUsers: Set<Int> = []
    private var currentUserUID: SynologyPhotoConditionValue?
    private var mutationInFlight = false
    private var mutations: [UUID: PhotosMutationRecord] = [:]
    private var albumCheckpointWriters: [UUID: @Sendable (SynologyPhotosAlbumCheckpoint) throws -> Void] = [:]
    private var uploadCheckpointWriters: [UUID: @Sendable (SynologyPhotosUploadCheckpoint) throws -> Void] = [:]
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
        let baseURL = try DsmEndpoint.baseURL(for: profile)
        let credential = DsmSessionCredential(sid: session.sid, synoToken: session.synoToken)
        try self.init(profile: profile, capabilities: capabilities, session: session, transport: transport, deletionEnabled: deletionEnabled,
            previewEvents: { try SynologyPhotosPreviewEvents(applicationURL: baseURL, credential: credential,
                pinnedCertificate: profile.pinnedCertificateSHA256, requiresSystemTrust: DsmQuickConnectResolver.isTrustedRelayHost(profile.host)) })
    }

    init(profile: NasProfile, capabilities: CapabilitySet, session: AuthSession, transport: (any DsmHTTPTransport)? = nil,
         deletionEnabled: Bool = false, previewEvents: @escaping @Sendable () throws -> SynologyPhotosPreviewEvents) throws {
        self.previewEvents = previewEvents
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
        hasPhotosAccess = false
        isPhotosAdministrator = false
        supportsOriginalSizeJPEG = false
        defaultFolderSort = .init()
        managesSharedSpace = false
        sharedCategorySettings = []
        personalSimilarEnabled = false
        personalRecognition = [:]
        categoryThumbnails = [:]
        personThumbnailTypes = [:]
        authorizedFaces = [:]
        photoFaceIDs = [:]
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
        defaultFolderSort = .init(field: settings.item_sort_by.flatMap(SynologyPhotoSort.Field.init(rawValue:)) ?? .takenTime, direction: settings.sort_direction.flatMap(SynologyPhotoSort.Direction.init(rawValue:)) ?? .ascending)
        cacheRecognition(user: settings, admin: admin)
        // 官方权限枚举见 photos-library-read.md；DSM 管理员身份不代替 Photos 授权。
        if team.enabled, ["entry", "management"].contains(settings.team_space_permission) {
            spaces.append(.shared)
            managesSharedSpace = settings.team_space_permission == "management"
            sharedCategorySettings = [.recentlyAdded, .location, .tags, .videos]
            if team.enable_person == true, admin.enable_person != false { sharedCategorySettings.insert(.person) }
            if team.enable_concept == true, admin.enable_concept != false { sharedCategorySettings.insert(.concept) }
            if team.enable_similar == true, admin.enable_similar != false { sharedCategorySettings.insert(.similar) }
        }
        currentUserID = user.id
        currentUserUID = user.uid
        allowedSpaces = Set(spaces)
        hasPhotosAccess = true
        isPhotosAdministrator = user.is_admin == true
        supportsOriginalSizeJPEG = settings.ame_status?.has_hevc == true && admin.enable_converted_original_jpeg == true
        return SynologyPhotosAccess(spaces: spaces, packageVersion: admin.package_version, canManageSharedSpace: managesSharedSpace,
                                   supportsOriginalSizeJPEG: supportsOriginalSizeJPEG, displaySettings: settings.displaySettings, automaticPreviewEnabled: settings.auto_generate_thumbnail)
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
        if case .album = query { try requireAlbumAccess() }
        else { try requireAccess(space) }
        let generation = accessGeneration
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
        case .folder(let id, let sort):
            guard id > 0 else { throw Self.failure(.invalidResponse) }
            parameters["folder_id"] = .integer(id)
            parameters["sort_by"] = .string(sort.field.rawValue)
            parameters["sort_direction"] = .string(sort.direction.rawValue)
            parameters["additional"] = .stringArray(["thumbnail", "resolution", "orientation", "video_convert", "video_meta"])
        case .album(let id, let sort):
            name = "SYNO.Foto.Browse.Item"
            guard id > 0 else { throw Self.failure(.invalidResponse) }
            parameters["album_id"] = .integer(id)
            parameters["sort_by"] = .string(sort.field.rawValue)
            parameters["sort_direction"] = .string(sort.direction.rawValue)
            parameters["additional"] = .stringArray(["thumbnail", "resolution", "orientation", "video_convert", "video_meta", "provider_user_id"])
        case .recentlyAdded:
            name = api("Browse.RecentlyAdded", in: space)
            version = 1
            parameters["additional"] = .stringArray(["thumbnail"])
        case .similar(let start, let end):
            try requireCategoryAccess(.similar, in: space)
            guard start >= 0, end >= start else { throw Self.failure(.invalidResponse) }
            name = api("Browse.SimilarItem", in: space); version = 1; method = "list_similar"
            parameters["start_time"] = .integer(start); parameters["end_time"] = .integer(end)
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
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        guard payload.list.count <= limit,
              Set(payload.list.map(\.id)).count == payload.list.count else {
            throw Self.failure(.invalidResponse)
        }
        let items = try payload.list.map { item in
            guard item.id > 0, item.folder_id > 0, item.filesize >= 0 else {
                throw Self.failure(.invalidResponse)
            }
            // 相册是统一入口，项目的owner_user_id决定原件所在空间。
            let source: SynologyPhotoSpace
            let context: SynologyPhotoAlbumContext?
            if case .album(let albumID, _) = query {
                guard let owner = item.owner_user_id, owner >= 0 else { throw Self.failure(.invalidResponse) }
                source = owner == 0 ? .shared : .personal
                context = .init(albumID: albumID, ownerUserID: owner, providerUserID: item.additional?.provider_user_id)
            } else { source = space; context = nil }
            var photo = SynologyPhoto(
                id: SynologyPhotoID(profileID: profileID, space: source, unitID: item.id),
                filename: item.filename, sizeBytes: item.filesize,
                takenAt: Date(timeIntervalSince1970: item.time),
                indexedAt: Date(timeIntervalSince1970: item.indexed_time),
                folderID: item.folder_id, mediaType: item.type,
                thumbnail: item.additional?.thumbnail.map {
                    SynologyPhotoThumbnail(unitID: $0.unit_id, revision: $0.cache_key)
                },
                width: item.additional?.resolution?.width,
                height: item.additional?.resolution?.height,
                orientation: item.additional?.orientation, albumContext: context
            )
            photo.description = item.additional?.description
            photo.camera = item.additional?.exif?.camera
            photo.duration = item.additional?.video_meta?.duration
            if case .similar = query {
                guard let group = item.similar else { throw Self.failure(.invalidResponse) }
                photo.similarGroup = try similarGroup(group, in: space)
                guard group.item_id.contains(item.id) else { throw Self.failure(.invalidResponse) }
            }
            return photo
        }
        // 接口没有返回 total/has_more；满页继续请求，空页或短页才结束。
        return SynologyPhotoPage(items: items, offset: offset, nextOffset: offset + payload.list.count, hasMore: payload.list.count == limit)
    }

    private func requireAccess(_ space: SynologyPhotoSpace) throws {
        guard allowedSpaces.contains(space) else { throw Self.failure(.permissionDenied) }
    }

    private func requireAlbumAccess() throws {
        guard hasPhotosAccess else { throw Self.failure(.permissionDenied) }
    }

    public func thumbnail(for photo: SynologyPhoto) async throws -> Data {
        try await image(for: photo, size: "m")
    }

    public func previewImage(for photo: SynologyPhoto) async throws -> Data {
        try await image(for: photo, size: "xl")
    }

    private func image(for photo: SynologyPhoto, size: String) async throws -> Data {
        try requireReadablePhoto(photo)
        guard let thumbnail = photo.thumbnail, thumbnail.unitID > 0 else {
            throw Self.failure(.permissionDenied)
        }
        return try await image(thumbnail: thumbnail, size: size, space: photo.id.space, albumID: photo.albumContext?.albumID)
    }

    public func thumbnail(for album: SynologyPhotoCollection) async throws -> Data {
        try requireAlbumAccess()
        let generation = accessGeneration
        // 重新按相册编号读取当前会话有权查看的封面，避免采用其他会话留下的缩略图标识。
        let current = try await managedAlbum(album.id)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard let thumbnail = current.collection.thumbnail, thumbnail.unitID > 0 else { throw Self.failure(.apiUnavailable) }
        return try await image(thumbnail: thumbnail, size: "m", albumID: album.id)
    }

    public func thumbnail(for collection: SynologyPhotoCollection, category: SynologyPhotoCategory) async throws -> Data {
        try requireCategoryAccess(category, in: collection.space)
        guard let thumbnail = categoryThumbnails[collection.space]?[category]?[collection.id], thumbnail == collection.thumbnail,
              thumbnail.unitID > 0 else { throw Self.failure(.permissionDenied) }
        let type = category == .person ? personThumbnailTypes[collection.space]?[collection.id] ?? "unit" : "unit"
        return try await image(thumbnail: thumbnail, size: category == .person ? nil : "m", type: type, space: collection.space)
    }

    private func image(thumbnail: SynologyPhotoThumbnail, size: String?, type: String = "unit", space: SynologyPhotoSpace = .personal, albumID: Int? = nil, folderCoverSequence: Int? = nil) async throws -> Data {
        if albumID != nil { try requireAlbumAccess() }
        else { try requireAccess(space) }
        let generation = accessGeneration
        // 路由来自官方空间选择逻辑；照片身份决定 p/t，不混用同编号的个人与共享图片。
        let route = albumID == nil && space == .shared ? "t" : "p"
        var components = URLComponents(url: baseURL.appendingPathComponent("synofoto/api/v2/\(route)/Thumbnail/get"), resolvingAgainstBaseURL: false)
        let revision = String(decoding: try JSONEncoder().encode(thumbnail.revision), as: UTF8.self)
        components?.queryItems = [
            URLQueryItem(name: "id", value: String(thumbnail.unitID)),
            URLQueryItem(name: "cache_key", value: revision),
            URLQueryItem(name: "type", value: "\"\(type)\"")
        ]
        if let folderCoverSequence { components?.queryItems?.append(URLQueryItem(name: "folder_cover_seq", value: String(folderCoverSequence))) }
        if let albumID { components?.queryItems?.append(URLQueryItem(name: "album_id", value: String(albumID))) }
        if let size { components?.queryItems?.append(URLQueryItem(name: "size", value: "\"\(size)\"")) }
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
        guard generation == accessGeneration, !Task.isCancelled else { throw CancellationError() }
        if albumID != nil { try requireAlbumAccess() }
        else { try requireAccess(space) }
        guard (200..<300).contains(response.statusCode) else {
            throw DsmErrorMapper.map(.httpStatus(code: response.statusCode, requestID: UUID()))
        }
        guard !response.data.isEmpty, response.data.count <= 8 * 1_024 * 1_024,
              response.headers.contains(where: { $0.key.lowercased() == "content-type" && $0.value.lowercased().hasPrefix("image/") }) else {
            throw Self.failure(.invalidResponse)
        }
        return response.data
    }

    /// 网页文件夹视图的选择来自同一父目录，目录快照须包含完整路径与父编号。
    private func selectedFolderParent(_ folders: [SynologyPhotoCollection]) throws -> SynologyPhotoCollection {
        guard let first = folders.first, let parentID = first.parentID, parentID > 0,
              let path = first.path, path.hasPrefix("/"), path != "/", !path.hasSuffix("/"),
              Set(folders.map(\.id)).count == folders.count else { throw Self.failure(.invalidResponse) }
        let parentPath = (path as NSString).deletingLastPathComponent
        guard folders.allSatisfy({ folder in
            guard let path = folder.path else { return false }
            return folder.id > 0 && folder.id != parentID && folder.parentID == parentID && folder.space == first.space &&
                path != "/" && !path.hasSuffix("/") && (path as NSString).lastPathComponent == folder.name &&
                (path as NSString).deletingLastPathComponent == parentPath
        }) else { throw Self.failure(.conflict) }
        return .init(id: parentID, name: (parentPath as NSString).lastPathComponent, path: parentPath, space: first.space)
    }

    private func inspectFolderDeletion(taskID: Int, photos: [SynologyPhoto], folders targets: [SynologyPhotoCollection]) async throws -> SynologyPhotosMutationResult {
        let generation = accessGeneration
        let parent = try selectedFolderParent(targets)
        let payload: ManagementTaskList = try await call("SYNO.Foto.BackgroundTask.Info", version: 1, method: "get_status",
            parameters: ["id": .integerArray([taskID])])
        guard payload.list.count == 1, let task = payload.list.first, task.id == taskID,
              task.completion >= 0, task.error >= 0, task.skip >= 0, task.overwrite == 0 else { throw Self.failure(.invalidResponse) }
        guard task.status == "done" else { return .init(state: .pendingReview) }
        // 任务有失败或跳过时，没有逐目录结果可证明哪些目标已删除；列表缺失也可能来自权限变化。
        guard task.error == 0, task.skip == 0 else { return .init(state: .partial) }
        _ = try await readableFolder(parent)
        var present: Set<Int> = [], offset = 0
        while true {
            let page = try await folders(in: parent.space, parentID: parent.id, offset: offset, limit: 100)
            let ids = Set(page.map(\.id))
            guard present.isDisjoint(with: ids) else { throw Self.failure(.invalidResponse) }
            present.formUnion(ids); offset += page.count
            if page.count < 100 { break }
        }
        let removedFolders = targets.filter { !present.contains($0.id) }
        var removedPhotos: [SynologyPhotoID] = []
        for photo in photos {
            let items: DeletionItemList = try await call(api("Browse.Item", in: photo.id.space), version: 5, method: "get",
                parameters: ["id": .integerArray([photo.id.unitID])])
            if items.list.isEmpty { removedPhotos.append(photo.id) }
            else { guard items.list.count == 1, items.list.first?.matches(photo) == true else { throw Self.failure(.conflict) } }
        }
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        // 任务完成与新鲜回读共同确认；父目录不可读、响应错误或任务回执未知均不等于删除成功。
        let complete = removedFolders.count == targets.count && removedPhotos.count == photos.count
        let state: SynologyPhotosMutationResult.State = complete ? .confirmed : .pendingReview
        return .init(state: state, completedCount: removedFolders.count + removedPhotos.count,
            deletedFolders: removedFolders, deletedPhotoIDs: removedPhotos)
    }

    private func renamedFolderPath(_ folder: SynologyPhotoCollection, name: String) throws -> String {
        guard SynologyPhotosMutation.isValidFolderName(name), let path = folder.path,
              path.hasPrefix("/"), path != "/", !path.hasSuffix("/"),
              (path as NSString).lastPathComponent == folder.name else { throw Self.failure(.invalidResponse) }
        let parent = (path as NSString).deletingLastPathComponent
        return (parent == "/" ? parent : parent + "/") + name
    }

    private func readableFolder(_ folder: SynologyPhotoCollection) async throws -> FolderEntry {
        try requireAccess(folder.space)
        let generation = accessGeneration
        guard folder.id > 0 else { throw Self.failure(.invalidResponse) }
        let payload: FolderPayload = try await call(api("Browse.Folder", in: folder.space), version: 2, method: "get",
            parameters: ["id": .integer(folder.id), "additional": .stringArray(["thumbnail", "access_permission"])])
        guard generation == accessGeneration, payload.folder.id == folder.id,
              folder.path == nil || payload.folder.name == folder.path else { throw Self.failure(.conflict) }
        guard payload.folder.additional?.access_permission?.view == true || (folder.space == .shared && managesSharedSpace) else { throw Self.failure(.permissionDenied) }
        return payload.folder
    }

    private func folderCoverImage(_ cover: FolderEntry.Cover, folder: FolderEntry, space: SynologyPhotoSpace) async throws -> Data {
        if let sequence = cover.folder_cover_seq {
            guard sequence >= 0 else { throw Self.failure(.invalidResponse) }
            return try await image(thumbnail: .init(unitID: folder.id, revision: cover.cache_key), size: nil, type: "folder", space: space, folderCoverSequence: sequence)
        }
        guard let unit = cover.unit_id, unit > 0 else { throw Self.failure(.invalidResponse) }
        return try await image(thumbnail: .init(unitID: unit, revision: cover.cache_key), size: "m", space: space)
    }

    /// 沿用内部目录读取与权限校验，供已确认上传任务导航；名称以当前NAS回读为准。
    public func folder(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection {
        let current = try await readableFolder(.init(id: id, name: "", space: space))
        return current.collection(in: space)
    }

    public func folderSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort {
        let current = try await readableFolder(folder)
        return .init(field: current.sort_by.flatMap(SynologyPhotoSort.Field.init(rawValue:)) ?? defaultFolderSort.field,
                     direction: current.sort_direction.flatMap(SynologyPhotoSort.Direction.init(rawValue:)) ?? defaultFolderSort.direction)
    }

    public func folderCoverImages(_ folder: SynologyPhotoCollection) async throws -> [Data] {
        let current = try await readableFolder(folder)
        var images: [Data] = []
        for cover in (current.additional?.thumbnail ?? []).prefix(4) {
            do { images.append(try await folderCoverImage(cover, folder: current, space: folder.space)) }
            catch is CancellationError { throw CancellationError() }
            catch { try requireAccess(folder.space) }
        }
        return images
    }

    private func prepareFolderCover(_ folder: SynologyPhotoCollection, photo: SynologyPhoto) async throws {
        try requirePhoto(photo)
        guard photo.albumContext == nil, photo.id.space == folder.space, pendingDeletions[photo.id] == nil else { throw Self.failure(.permissionDenied) }
        let target = try await readableFolder(folder)
        guard target.name != "/", canWriteFolder(target, in: folder.space, forUpload: false) else { throw Self.failure(.permissionDenied) }
        let identity: DeletionItemList = try await call(api("Browse.Item", in: folder.space), version: 5, method: "get", parameters: ["id": .integerArray([photo.id.unitID])])
        guard identity.list.count == 1, identity.list.first?.matches(photo) == true else { throw Self.failure(.conflict) }
        let source = try await readableFolder(.init(id: photo.folderID, name: "", space: folder.space))
        // 选择器以目标目录为根；可以选其子目录的可查看照片，不能扩大到兄弟目录。
        guard (source.name as NSString).pathComponents.starts(with: (target.name as NSString).pathComponents) else { throw Self.failure(.permissionDenied) }
    }

    public func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection {
        try requireAccess(space)
        let payload: FolderPayload = try await call(api("Browse.Folder", in: space), version: 2, method: "get", parameters: [
            "name": .string("/"), "additional": .stringArray(["access_permission"])
        ])
        guard payload.folder.id > 0,
              payload.folder.additional?.access_permission?.view == true || (space == .shared && managesSharedSpace) else {
            throw Self.failure(.permissionDenied)
        }
        return payload.folder.collection(in: space)
    }

    public func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        try await folders(in: space, parentID: parentID, offset: offset, limit: limit, direction: .ascending)
    }

    public func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int, direction: SynologyPhotoSort.Direction) async throws -> [SynologyPhotoCollection] {
        try requireAccess(space)
        let generation = accessGeneration
        guard parentID > 0, offset >= 0, (1...500).contains(limit) else { throw Self.failure(.invalidResponse) }
        let payload: FolderList = try await call(api("Browse.Folder", in: space), version: 2, method: "list", parameters: [
            "id": .integer(parentID), "offset": .integer(offset), "limit": .integer(limit),
            "sort_by": .string("filename"), "sort_direction": .string(direction.rawValue), "additional": .stringArray(["thumbnail"])
        ])
        guard generation == accessGeneration, !Task.isCancelled else { throw CancellationError() }
        guard payload.list.count <= limit, payload.list.allSatisfy({ $0.id > 0 && $0.parent == parentID }), Set(payload.list.map(\.id)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
        return payload.list.map { $0.collection(in: space) }
    }

    public func albumSort(id: Int) async throws -> SynologyPhotoSort {
        guard let sort = try await readAlbumSort(id: id, requiresExplicit: false) else { throw Self.failure(.invalidResponse) }
        return sort
    }

    private func readAlbumSort(id: Int, requiresExplicit: Bool) async throws -> SynologyPhotoSort? {
        try requireAlbumAccess()
        let generation = accessGeneration
        let album = try await managedAlbum(id)
        _ = try await albumAccess(album)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        // 官方相册工具栏对缺省值使用拍摄时间升序；未知非空值不伪装成已识别的顺序。
        let field = album.sort_by.flatMap(SynologyPhotoSort.Field.init(rawValue:))
        let direction = album.sort_direction.flatMap(SynologyPhotoSort.Direction.init(rawValue:))
        guard album.sort_by == nil || album.sort_by == "" || field != nil,
              album.sort_direction == nil || album.sort_direction == "" || direction != nil else { throw Self.failure(.invalidResponse) }
        guard !requiresExplicit || field != nil && direction != nil else { return nil }
        return .init(field: field ?? .takenTime, direction: direction ?? .ascending)
    }

    public func albumListSort(_ scope: SynologyPhotoAlbumListScope) async throws -> SynologyPhotoAlbumListSort {
        try requireAlbumAccess()
        let generation = accessGeneration
        let payload: [String: String] = try await call("SYNO.Foto.Browse.Album", version: 2, method: "get_album_list_order")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard let field = payload[scope.rawValue + "_sort_by"].flatMap(SynologyPhotoAlbumListSort.Field.init(rawValue:)),
              scope.fields.contains(field), let direction = payload[scope.rawValue + "_sort_direction"].flatMap(SynologyPhotoSort.Direction.init(rawValue:)) else { throw Self.failure(.invalidResponse) }
        return .init(field: field, direction: direction)
    }

    public func albumListDisplay() async throws -> SynologyPhotoAlbumDisplay {
        try requireAlbumAccess()
        let generation = accessGeneration
        let payload: [String: String] = try await call("SYNO.Foto.Browse.Album", version: 3, method: "get_album_list_display")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard let display = payload["album_display_type"].flatMap(SynologyPhotoAlbumDisplay.init(rawValue:)) else { throw Self.failure(.invalidResponse) }
        return display
    }

    public func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        try await albums(offset: offset, limit: limit, display: nil, sort: nil)
    }

    public func albums(offset: Int, limit: Int, display: SynologyPhotoAlbumDisplay?, sort: SynologyPhotoAlbumListSort?) async throws -> [SynologyPhotoCollection] {
        try requireAlbumAccess()
        let generation = accessGeneration
        guard offset >= 0, (1...500).contains(limit) else { throw Self.failure(.invalidResponse) }
        var parameters: [String: DsmParameterValue] = [
            "offset": .integer(offset), "limit": .integer(limit), "category": .string(display == .mine ? "normal" : "normal_share_with_me"),
            "additional": .stringArray(["thumbnail", "sharing_info"])]
        if let sort {
            guard SynologyPhotoAlbumListScope.albums.fields.contains(sort.field) else { throw Self.failure(.invalidResponse) }
            parameters["sort_by"] = .string(sort.field.rawValue); parameters["sort_direction"] = .string(sort.direction.rawValue)
        }
        let payload: AlbumList = try await call("SYNO.Foto.Browse.Album", version: 4, method: "list", parameters: parameters)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard payload.list.count <= limit, payload.list.allSatisfy({ $0.id > 0 }), Set(payload.list.map(\.id)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
        return payload.list.map { SynologyPhotoCollection(id: $0.id, name: $0.name, itemCount: $0.item_count, thumbnail: $0.additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) }, isConditional: $0.type == "condition", isFrozen: $0.freeze_album == true) }
    }

    public func details(for photo: SynologyPhoto) async throws -> SynologyPhoto {
        try requireReadablePhoto(photo)
        let generation = accessGeneration
        let payload: ItemList = try await call(readAPI("Browse.Item", for: photo), version: 5, method: "get", parameters: readParameters(for: photo, [
            "id": .integerArray([photo.id.unitID]),
            "additional": .stringArray(["description", "tag", "exif", "resolution", "orientation", "gps", "video_meta", "video_convert", "thumbnail", "address", "geocoding_id", "rating", "motion_photo", "person", "provider_user_id"])
        ]))
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        guard payload.list.count == 1, let item = payload.list.first, item.id == photo.id.unitID, item.filesize >= 0 else { throw Self.failure(.invalidResponse) }
        if let context = photo.albumContext, item.owner_user_id != context.ownerUserID { throw Self.failure(.invalidResponse) }
        var result = SynologyPhoto(id: photo.id, filename: item.filename, sizeBytes: item.filesize,
            takenAt: Date(timeIntervalSince1970: item.time), indexedAt: Date(timeIntervalSince1970: item.indexed_time),
            folderID: item.folder_id, mediaType: item.type,
            thumbnail: item.additional?.thumbnail.map { SynologyPhotoThumbnail(unitID: $0.unit_id, revision: $0.cache_key) },
            width: item.additional?.resolution?.width, height: item.additional?.resolution?.height, orientation: item.additional?.orientation,
            albumContext: photo.albumContext.map { .init(albumID: $0.albumID, ownerUserID: $0.ownerUserID, providerUserID: item.additional?.provider_user_id) })
        result.originalOrientation = item.additional?.orientation_original
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
        result.similarGroup = photo.similarGroup
        return result
    }

    public func videoSource(for photo: SynologyPhoto) async throws -> MediaStreamSource {
        try requireReadablePhoto(photo)
        let generation = accessGeneration
        guard photo.mediaType == "video" || photo.mediaType == "live" else { throw Self.failure(.invalidResponse) }
        var videoID = photo.id.unitID
        var sourceType = "item"
        var filename = photo.filename
        let conversions: [ItemPayload.VideoConversion]
        if photo.mediaType == "live" {
            let payload: UnitPayload = try await call(readAPI("Browse.Unit", for: photo), version: 1, method: "get", parameters: readParameters(for: photo, [
                "id_item": .integerArray([photo.id.unitID]),
                "additional": .stringArray(["orientation", "resolution", "thumbnail", "video_meta", "video_convert"])
            ]))
            guard payload.list.count == 1, let entry = payload.list.first, entry.id_item == photo.id.unitID else { throw Self.failure(.invalidResponse) }
            let videos = entry.unit.filter { $0.live_type == "video" }
            guard videos.count == 1, let video = videos.first, video.id > 0 else { throw Self.failure(.invalidResponse) }
            videoID = video.id
            sourceType = "unit"
            filename = video.filename ?? "video.mov"
            conversions = video.additional?.video_convert ?? []
        } else {
            let payload: ItemList = try await call(readAPI("Browse.Item", for: photo), version: 5, method: "get",
                parameters: readParameters(for: photo, ["id": .integerArray([photo.id.unitID]), "additional": .stringArray(["video_convert"])]))
            guard payload.list.count == 1, let item = payload.list.first, item.id == photo.id.unitID,
                  item.type == "video" else { throw Self.failure(.invalidResponse) }
            filename = item.filename
            conversions = item.additional?.video_convert ?? []
        }
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        // 只选套件实际提供的转换版本；没有转换版时读取原视频，不按扩展名猜测。
        let quality = ["raw", "orig_h264", "high", "medium", "low", "mobile"].first { candidate in
            conversions.contains { $0.quality == candidate }
        }
        if quality == nil || quality == "raw" {
            let request = try mediaRequest(readAPI("Download", for: photo), method: "download", parameters: readParameters(for: photo, [
                sourceType == "unit" ? "unit_id" : "item_id": .integerArray([videoID])
            ]))
            return MediaStreamSource(request: request, fileExtension: (filename as NSString).pathExtension.lowercased(),
                expectedContentLength: nil, expectedHost: baseURL.host!, pinnedCertificateSHA256: pinnedCertificate)
        }
        let request = try mediaRequest(readAPI("Streaming", for: photo), method: "streaming", parameters: readParameters(for: photo, [
            "id": .integer(videoID), "type": .string(sourceType), "quality": .string(quality!), "use_mov": .boolean(true)
        ]))
        return MediaStreamSource(request: request, fileExtension: "mov", expectedContentLength: nil,
                                 expectedHost: baseURL.host!, pinnedCertificateSHA256: pinnedCertificate)
    }

    public func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        _ = try await download(photo, format: .original, to: destination, progress: progress)
    }

    public func download(_ photo: SynologyPhoto, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws -> SynologyPhotoDownloadFormat {
        try requireReadablePhoto(photo)
        let generation = accessGeneration
        guard destination.isFileURL, let binary = transport as? any DsmBinaryHTTPTransport else { throw Self.failure(.invalidResponse) }
        let request: URLRequest
        var ownsConversion = false
        defer { if ownsConversion { jpegConversions.remove(photo.id) } }
        if format == .originalSizeJPEG {
            guard supportsOriginalSizeJPEG, photo.supportsOriginalSizeJPEG else { throw Self.failure(.apiUnavailable) }
            guard jpegConversions.insert(photo.id).inserted else { throw Self.failure(.conflict) }
            ownsConversion = true
            let context = try await originalJPEGContext(photo)
            try Task.checkCancellation()
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            let name = readAPI("Download", for: photo)
            var parameters = context
            parameters["item_id"] = .integer(photo.id.unitID)
            // 转换成功后再下载，不自动重放失败转换；不会修改原件。
            try await managementWrite(name, version: 2, method: "convert", parameters: parameters)
            try Task.checkCancellation()
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            parameters["item_id"] = .integerArray([photo.id.unitID])
            parameters["force_download"] = .boolean(true)
            parameters["download_type"] = .string("original_size_jpeg")
            request = try DsmRequestBuilder.build(baseURL: baseURL, path: capabilities[name]!.path, api: name, version: 2,
                method: "download", requestFormat: .json, parameters: parameters, credential: credential, httpMethod: "POST")
        } else {
            request = try mediaRequest(readAPI("Download", for: photo), method: "download", parameters: readParameters(for: photo, [
                "item_id": .integerArray([photo.id.unitID]), "force_download": .boolean(true), "download_type": .string(format == .original ? "source" : "optimized_jpeg")
            ]))
        }
        // 在随机临时文件中校验再提升；失败不覆盖用户目标文件。
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(".\(UUID().uuidString).photos-download")
        defer { try? FileManager.default.removeItem(at: staging) }
        let response = try await binary.download(request, to: staging, progress: progress)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard response.statusCode == 200 else { throw DsmErrorMapper.map(.httpStatus(code: response.statusCode, requestID: UUID())) }
        let type = response.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        guard !type.contains("json"), !type.contains("html"), !type.contains("zip") else { throw Self.failure(.invalidResponse) }
        let size = (try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value
        let actualFormat: SynologyPhotoDownloadFormat
        if format == .original {
            guard size == photo.sizeBytes else { throw Self.failure(.invalidResponse) }
            actualFormat = .original
        } else {
            guard let size, size > 0 else { throw Self.failure(.invalidResponse) }
            if let length = response.headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
                guard Int64(length) == size else { throw Self.failure(.invalidResponse) }
            }
            let handle = try FileHandle(forReadingFrom: staging)
            defer { try? handle.close() }
            let header = try handle.read(upToCount: 3) ?? Data()
            if header.starts(with: [0xff, 0xd8, 0xff]) {
                guard let image = CGImageSourceCreateWithURL(staging as CFURL, nil),
                      CGImageSourceGetType(image) as String? == "public.jpeg",
                      CGImageSourceGetStatus(image) == .statusComplete,
                      CGImageSourceCreateImageAtIndex(image, 0, nil) != nil else { throw Self.failure(.invalidResponse) }
                actualFormat = format
            } else {
                // 官方下载在不能转换时保留原格式，不能将原件内容命名为JPEG。
                guard format == .optimizedJPEG, !type.contains("jpeg"), size == photo.sizeBytes else { throw Self.failure(.invalidResponse) }
                actualFormat = .original
            }
        }
        try Task.checkCancellation()
        try await DownloadedFileExporter.export(from: staging, to: destination, replaceExisting: false)
        return actualFormat
    }

    private func originalJPEGContext(_ photo: SynologyPhoto) async throws -> [String: DsmParameterValue] {
        let identity: DeletionItemList = try await call(readAPI("Browse.Item", for: photo), version: 5, method: "get",
            parameters: readParameters(for: photo, ["id": .integerArray([photo.id.unitID]), "additional": .stringArray(["provider_user_id"])]))
        guard identity.list.count == 1, identity.list.first?.matches(photo) == true else { throw Self.failure(.conflict) }
        if let context = photo.albumContext {
            guard identity.list.first?.owner_user_id == context.ownerUserID else { throw Self.failure(.conflict) }
            let album = try await managedAlbum(context.albumID)
            let rights = try await albumAccess(album)
            // 与现有下载菜单一致：原空间开启时，可下载本人提供的照片；提供者必须重新读取确认。
            let ownContribution = allowedSpaces.contains(photo.id.space) && currentUserID != nil && identity.list.first?.additional?.provider_user_id == currentUserID
            guard rights.canDownload || ownContribution else { throw Self.failure(.permissionDenied) }
            if rights.isOwner { return ["album_id": .integer(context.albumID)] }
            guard let passphrase = album.passphrase ?? album.additional?.sharing_info?.passphrase, !passphrase.isEmpty else { throw Self.failure(.permissionDenied) }
            return ["passphrase": .string(passphrase)]
        }
        let payload: FolderPayload = try await call(api("Browse.Folder", in: photo.id.space), version: 2, method: "get",
            parameters: ["id": .integer(photo.folderID), "additional": .stringArray(["access_permission"])])
        let access = payload.folder.additional?.access_permission
        guard payload.folder.id == photo.folderID,
              (photo.id.space == .shared && managesSharedSpace) || (access?.view == true && (photo.id.space == .personal ? access?.download != false : access?.download == true)) else { throw Self.failure(.permissionDenied) }
        return [:]
    }

    public func downloadArchive(_ target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        let generation = accessGeneration
        guard format != .originalSizeJPEG else { throw Self.failure(.apiUnavailable) }
        guard destination.isFileURL, let binary = transport as? any DsmBinaryHTTPTransport else { throw Self.failure(.invalidResponse) }
        let name: String
        var parameters: [String: DsmParameterValue] = ["download_type": .string(format == .original ? "source" : "optimized_jpeg")]
        switch target {
        case .album(let id):
            try requireAlbumAccess()
            guard id > 0 else { throw Self.failure(.invalidResponse) }
            let album = try await managedAlbum(id)
            let rights = try await albumAccess(album)
            guard rights.canDownload else { throw Self.failure(.permissionDenied) }
            name = "SYNO.Foto.Browse.Album"
            if rights.isOwner { parameters["id"] = .integer(id) }
            else {
                guard let passphrase = album.passphrase ?? album.additional?.sharing_info?.passphrase, !passphrase.isEmpty else { throw Self.failure(.permissionDenied) }
                parameters["passphrase"] = .string(passphrase)
            }
        case .folder(let id, let space):
            try requireAccess(space)
            guard id > 0 else { throw Self.failure(.invalidResponse) }
            let payload: FolderPayload = try await call(api("Browse.Folder", in: space), version: 2, method: "get", parameters: [
                "id": .integer(id), "additional": .stringArray(["access_permission"])])
            let access = payload.folder.additional?.access_permission
            guard payload.folder.id == id,
                  (space == .shared && managesSharedSpace) || (access?.view == true && (space == .personal ? access?.download != false : access?.download == true)) else { throw Self.failure(.permissionDenied) }
            name = api("Download", in: space)
            parameters["folder_id"] = .integerArray([id]); parameters["force_download"] = .boolean(true)
        case .selection(let photos, let folders):
            let parent = try selectedFolderParent(folders)
            try requireAccess(parent.space)
            guard Set(photos.map(\.id)).count == photos.count else { throw Self.failure(.conflict) }
            for photo in photos {
                try requirePhoto(photo)
                guard photo.albumContext == nil, photo.id.space == parent.space, photo.folderID == parent.id else { throw Self.failure(.conflict) }
            }
            // 每个目录都按当前权限核对，不能以同级目录可下载代替整组选项的权限。
            for folder in folders + (photos.isEmpty ? [] : [parent]) {
                let current = try await readableFolder(folder)
                if folder.id != parent.id, current.parent != parent.id { throw Self.failure(.conflict) }
                let access = current.additional?.access_permission
                guard (parent.space == .shared && managesSharedSpace) ||
                    (parent.space == .personal ? access?.download != false : access?.download == true) else { throw Self.failure(.permissionDenied) }
            }
            for offset in stride(from: 0, to: photos.count, by: 100) {
                let batch = Array(photos[offset..<min(offset + 100, photos.count)])
                let identities: DeletionItemList = try await call(api("Browse.Item", in: parent.space), version: 5, method: "get",
                    parameters: ["id": .integerArray(batch.map { $0.id.unitID })])
                guard identities.list.count == batch.count,
                      batch.allSatisfy({ photo in identities.list.filter { $0.matches(photo) }.count == 1 }) else { throw Self.failure(.conflict) }
            }
            name = api("Download", in: parent.space)
            parameters["folder_id"] = .integerArray(folders.map(\.id))
            if !photos.isEmpty { parameters["item_id"] = .integerArray(photos.map { $0.id.unitID }) }
            parameters["force_download"] = .boolean(true)
        }
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard let capability = capabilities[name], capability.minVersion <= 2, capability.maxVersion >= 2,
              capability.requestFormat == .json else { throw Self.failure(.apiUnavailable) }
        // 官方表单使用POST；协作相册口令只进请求体，不出现在下载URL中。
        let request = try DsmRequestBuilder.build(baseURL: baseURL, path: capability.path, api: name, version: 2,
            method: "download", requestFormat: .json, parameters: parameters, credential: credential, httpMethod: "POST")
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(".\(UUID().uuidString).photos-archive")
        defer { try? FileManager.default.removeItem(at: staging) }
        let response = try await binary.download(request, to: staging, progress: progress)
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard response.statusCode == 200 else { throw DsmErrorMapper.map(.httpStatus(code: response.statusCode, requestID: UUID())) }
        let type = response.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        guard !type.contains("json"), !type.contains("html") else { throw Self.failure(.invalidResponse) }
        let size = (try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if let length = response.headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            guard UInt64(length) == size else { throw Self.failure(.invalidResponse) }
        }
        try Self.validatePhotoArchive(staging, size: size)
        try Task.checkCancellation()
        try await DownloadedFileExporter.export(from: staging, to: destination, replaceExisting: false)
    }

    /// 只检查ZIP容器与完整结束记录，不解压或一次读入大相册；ZIP64保留标准结束记录。
    private static func validatePhotoArchive(_ url: URL, size: UInt64) throws {
        guard size >= 22 else { throw failure(.invalidResponse) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 4) ?? Data()
        guard [Data([0x50, 0x4b, 3, 4]), Data([0x50, 0x4b, 5, 6]), Data([0x50, 0x4b, 6, 6])].contains(header) else { throw failure(.invalidResponse) }
        let count = Int(min(size, 65_557))
        try handle.seek(toOffset: size - UInt64(count))
        let tail = [UInt8](try handle.read(upToCount: count) ?? Data())
        guard tail.count == count else { throw failure(.invalidResponse) }
        for index in stride(from: count - 22, through: 0, by: -1) {
            if Array(tail[index..<(index + 4)]) == [0x50, 0x4b, 5, 6] {
                let commentLength = Int(tail[index + 20]) | Int(tail[index + 21]) << 8
                if index + 22 + commentLength == count { return }
            }
        }
        throw failure(.invalidResponse)
    }

    private func requirePhoto(_ photo: SynologyPhoto) throws {
        try requireAccess(photo.id.space)
        guard photo.id.profileID == profileID, photo.id.unitID > 0 else { throw Self.failure(.permissionDenied) }
        if photo.id.space == .personal, let context = photo.albumContext,
           context.ownerUserID != currentUserID { throw Self.failure(.permissionDenied) }
    }

    /// 相册只读请求由NAS核对相册成员与会话权限；绝不回退到原空间绕过拒绝。
    private func requireReadablePhoto(_ photo: SynologyPhoto) throws {
        guard photo.id.profileID == profileID, photo.id.unitID > 0 else { throw Self.failure(.permissionDenied) }
        if let context = photo.albumContext {
            try requireAlbumAccess()
            guard context.albumID > 0, context.ownerUserID >= 0,
                  photo.id.space == (context.ownerUserID == 0 ? .shared : .personal) else { throw Self.failure(.permissionDenied) }
        } else { try requirePhoto(photo) }
    }

    private func readAPI(_ suffix: String, for photo: SynologyPhoto) -> String {
        api(suffix, in: photo.albumContext == nil ? photo.id.space : .personal)
    }

    private func readParameters(for photo: SynologyPhoto, _ parameters: [String: DsmParameterValue]) -> [String: DsmParameterValue] {
        var result = parameters
        if let context = photo.albumContext { result["album_id"] = .integer(context.albumID) }
        return result
    }

    public func prepareDeletion(_ photo: SynologyPhoto) async throws {
        guard !mutationInFlight, !mutations.values.contains(where: { $0.result.state == .pendingReview }) else { throw deletionError(.conflict, "photos.manage.pending") }
        try requirePhoto(photo)
        guard deletionEnabled else {
            throw deletionError(.apiUnavailable, "photos.delete.unverified")
        }
        guard let deleteCapability = capabilities[api("BackgroundTask.File", in: photo.id.space)],
              deleteCapability.minVersion <= 1, deleteCapability.maxVersion >= 1,
              deleteCapability.requestFormat == .json else {
            throw deletionError(.versionUnsupported, "photos.delete.unverified")
        }
        let generation = accessGeneration
        // 删除身份核查不依赖 EXIF、地址或视频转换等可选详情的解析。
        let identity: DeletionItemList = try await call(api("Browse.Item", in: photo.id.space), version: 5, method: "get",
            parameters: ["id": .integerArray([photo.id.unitID])])
        guard identity.list.count == 1, let current = identity.list.first,
              current.matches(photo) else { throw deletionError(.conflict, "photos.delete.changed") }
        let folder: FolderPayload = try await call(api("Browse.Folder", in: photo.id.space), version: 2, method: "get", parameters: [
            "id": .integer(photo.folderID), "additional": .stringArray(["access_permission"])
        ])
        guard folder.folder.id == photo.folderID, canWriteFolder(folder.folder, in: photo.id.space, forUpload: false) else {
            throw deletionError(.permissionDenied, "photos.delete.denied")
        }
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try requireAccess(photo.id.space)
    }

    public func deletePhoto(_ photo: SynologyPhoto, operationID: UUID) async throws -> SynologyPhotoDeletionResult {
        try await deletePhoto(photo, operationID: operationID, checkpoint: nil)
    }

    public func performRecoverableDeletion(_ photo: SynologyPhoto, operationID: UUID,
        checkpoint: @escaping @Sendable (SynologyPhotoDeletionCheckpoint) throws -> Void) async throws -> SynologyPhotoDeletionResult {
        try await deletePhoto(photo, operationID: operationID, checkpoint: checkpoint)
    }

    private func deletePhoto(_ photo: SynologyPhoto, operationID: UUID,
        checkpoint: (@Sendable (SynologyPhotoDeletionCheckpoint) throws -> Void)?) async throws -> SynologyPhotoDeletionResult {
        try requirePhoto(photo)
        let identity = checkpoint == nil ? nil : try await uploadRecoveryIdentity()
        func save(_ state: SynologyPhotoDeletionCheckpoint.State) throws {
            if let checkpoint, let identity {
                try checkpoint(.init(photo: photo, operationID: operationID, identity: identity, state: state))
            }
        }
        if let previous = deletionOperations[operationID], previous != photo.id { throw deletionError(.conflict, "photos.delete.changed") }
        if let rejection = rejectedDeletionOperations[operationID] { throw rejection }
        if let confirmed = confirmedDeletions[photo.id], Self.sameDeletionTarget(confirmed, photo) { try save(.confirmed); return .confirmed }
        guard deletionLocks.insert(photo.id).inserted else { return .pendingReview }
        defer { deletionLocks.remove(photo.id) }
        if let pending = pendingDeletions[photo.id] {
            guard Self.sameDeletionTarget(pending, photo) else { throw deletionError(.conflict, "photos.delete.changed") }
            let result = try await reviewDeletion(photo)
            try save(result == .confirmed ? .confirmed : .submitted)
            return result
        }
        // 确认框之后重新核对版本、目标与权限，再且仅再提交一次。
        try await prepareDeletion(photo)
        try Task.checkCancellation()
        guard allowedSpaces.contains(photo.id.space) else { throw deletionError(.permissionDenied, "photos.delete.denied") }
        if let identity, identity != currentUserID.map({ "\(profileID.uuidString):\($0)" }) { throw Self.failure(.permissionDenied) }
        // 写前必须保存已提交边界；落盘失败时不发送删除请求。
        try save(.submitted)
        deletionOperations[operationID] = photo.id
        pendingDeletions[photo.id] = photo
        let capability = capabilities[api("BackgroundTask.File", in: photo.id.space)]!
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
                try save(.rejected)
                throw rejection
            }
            return .pendingReview
        } catch {
            // 提交后的错误或取消不能证明未执行；保留待核对记录，不自动重放。
            return .pendingReview
        }
        let result = (try? await reviewDeletion(photo)) ?? .pendingReview
        if result == .confirmed { try save(.confirmed) }
        return result
    }

    public func deletionTarget(_ checkpoint: SynologyPhotoDeletionCheckpoint) async throws -> SynologyPhoto {
        try requireDeletionCheckpoint(checkpoint)
        guard checkpoint.state == .prepared else { throw Self.failure(.conflict) }
        let generation = accessGeneration
        let payload: DeletionItemList = try await call(api("Browse.Item", in: checkpoint.target.space), version: 5, method: "get",
            parameters: ["id": .integerArray([checkpoint.target.unitID])])
        guard generation == accessGeneration, payload.list.count == 1, let value = payload.list.first else { throw deletionError(.conflict, "photos.delete.changed") }
        let photo = value.photo(for: checkpoint.target)
        guard try checkpoint.matches(photo) else { throw deletionError(.conflict, "photos.delete.changed") }
        return photo
    }

    public func reviewDeletion(_ checkpoint: SynologyPhotoDeletionCheckpoint) async throws -> SynologyPhotoDeletionResult {
        try requireDeletionCheckpoint(checkpoint)
        if checkpoint.state == .confirmed { return .confirmed }
        guard checkpoint.state == .submitted else { throw Self.failure(.conflict) }
        let generation = accessGeneration
        let payload: DeletionItemList = try await call(api("Browse.Item", in: checkpoint.target.space), version: 5, method: "get",
            parameters: ["id": .integerArray([checkpoint.target.unitID])])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        // 只有已提交记录加成功空响应才算删除完成，权限错误和原件变化均不猜测。
        if payload.list.isEmpty {
            if let pending = pendingDeletions[checkpoint.target.id], try checkpoint.matches(pending) {
                pendingDeletions.removeValue(forKey: checkpoint.target.id)
                confirmedDeletions[checkpoint.target.id] = pending
            }
            return .confirmed
        }
        guard payload.list.count == 1, let value = payload.list.first,
              try checkpoint.matches(value.photo(for: checkpoint.target)) else { throw deletionError(.conflict, "photos.delete.changed") }
        return .pendingReview
    }

    private func requireDeletionCheckpoint(_ checkpoint: SynologyPhotoDeletionCheckpoint) throws {
        try checkpoint.validate()
        guard let user = currentUserID, user > 0, "\(profileID.uuidString):\(user)" == checkpoint.identity else { throw Self.failure(.permissionDenied) }
        try requirePhoto(checkpoint.target.queryPhoto)
    }

    public func reviewDeletion(_ photo: SynologyPhoto) async throws -> SynologyPhotoDeletionResult {
        try requirePhoto(photo)
        if let confirmed = confirmedDeletions[photo.id], Self.sameDeletionTarget(confirmed, photo) { return .confirmed }
        guard let pending = pendingDeletions[photo.id], Self.sameDeletionTarget(pending, photo) else {
            throw deletionError(.conflict, "photos.delete.changed")
        }
        let payload: DeletionItemList = try await call(api("Browse.Item", in: photo.id.space), version: 5, method: "get",
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
            people: payload.person.map { $0.collection(in: space) },
            locations: payload.geocoding.map(\.location), tags: payload.general_tag ?? [],
            cameras: payload.camera ?? [], lenses: payload.lens ?? [], isoValues: payload.iso ?? [],
            apertures: payload.aperture ?? [], focalRanges: payload.focal_length_group ?? [],
            exposureRanges: payload.exposure_time_group ?? [])
    }

    public func categories() async throws -> Set<SynologyPhotoCategory> {
        try await categories(in: .personal)
    }

    public func categories(in space: SynologyPhotoSpace) async throws -> Set<SynologyPhotoCategory> {
        try requireAccess(space)
        // 官方统一分类入口不在FotoTeam命名空间；entry权限继续通过目录浏览。
        if space == .shared, !managesSharedSpace { return [] }
        let generation = accessGeneration
        let payload: CategoryPayload = try await call("SYNO.Foto.Browse.Category", version: 3, method: "get")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        let mapping: [String: SynologyPhotoCategory] = ["recently_added": .recentlyAdded, "person": .person, "concept": .concept, "geocoding": .location, "general_tag": .tags, "video": .videos, "similar": .similar]
        var categories = Set(payload.list.compactMap { mapping[$0.id] })
        if !(space == .personal ? personalSimilarEnabled : sharedCategorySettings.contains(.similar)) || !supportsSimilar(in: space) { categories.remove(.similar) }
        guard space == .shared else { return categories.filter { personalRecognition[$0] != false } }
        return categories.intersection(sharedCategorySettings).filter { category in
            let target = categoryReadAPI(category, in: space)
            guard let capability = capabilities[target.name] else { return false }
            return capability.minVersion <= target.version && capability.maxVersion >= target.version
        }
    }

    private func requireCategoryAccess(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace) throws {
        try requireAccess(space)
        if space == .personal, personalRecognition[category] == false { throw Self.failure(.permissionDenied) }
        if category == .similar {
            guard supportsSimilar(in: space) else { throw Self.failure(.apiUnavailable) }
            guard space == .shared || personalSimilarEnabled else { throw Self.failure(.permissionDenied) }
        }
        if space == .shared {
            guard managesSharedSpace, sharedCategorySettings.contains(category) else { throw Self.failure(.permissionDenied) }
        }
    }

    public func categoryPreviewImages(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace) async throws -> [Data] {
        try requireCategoryAccess(category, in: space)
        let generation = accessGeneration
        let target = categoryReadAPI(category, in: space)
        var parameters: [String: DsmParameterValue] = ["offset": .integer(0), "limit": .integer(4), "additional": .stringArray(["thumbnail"])]
        if category == .person { parameters["show_more"] = .boolean(true) }
        if category == .videos { parameters["type"] = .string("video") }
        let payload: CategoryPreviewList = try await call(target.name, version: target.version, method: category == .similar ? "list_similar" : "list", parameters: parameters)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard payload.list.count <= 4, payload.list.allSatisfy({ $0.id > 0 }),
              Set(payload.list.map(\.id)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
        var images: [Data] = []
        // 首页卡片不改写完整分类列表的封面授权缓存，迟到请求也不能覆盖后续分页。
        for item in payload.list {
            try Task.checkCancellation()
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            guard let thumbnail = item.additional?.thumbnail else { continue }
            let unitID = thumbnail.unit_id ?? (category == .person ? item.id : 0)
            guard unitID > 0 else { throw Self.failure(.invalidResponse) }
            do {
                let data = try await image(thumbnail: .init(unitID: unitID, revision: thumbnail.cache_key),
                    size: category == .person ? nil : "m", type: category == .person && thumbnail.unit_id == nil ? "person" : "unit", space: space)
                guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
                images.append(data)
            } catch {
                try Task.checkCancellation()
                guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
                if let error = error as? AppError, error.category == .permissionDenied { throw error }
                // 单张装饰性封面失败不影响其余封面或打开分类。
            }
        }
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        return images
    }

    private func categoryReadAPI(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace) -> (name: String, version: Int) {
        switch category {
        case .person: (api("Browse.Person", in: space), 1)
        case .concept: (api("Browse.Concept", in: space), 2)
        case .location: (api("Browse.Geocoding", in: space), 1)
        case .tags: (api("Browse.GeneralTag", in: space), 1)
        case .recentlyAdded: (api("Browse.RecentlyAdded", in: space), 1)
        case .videos: (api("Browse.Item", in: space), 4)
        case .similar: (api("Browse.SimilarItem", in: space), 1)
        }
    }

    private func supportsSimilar(in space: SynologyPhotoSpace) -> Bool {
        ["Browse.Similar", "Browse.SimilarItem", "Browse.SimilarTimeline"].allSatisfy {
            guard let capability = capabilities[api($0, in: space)] else { return false }
            return capability.minVersion <= 1 && capability.maxVersion >= 1
        }
    }

    public func similarTimeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        try requireCategoryAccess(.similar, in: space)
        let generation = accessGeneration
        let payload: TimelinePayload = try await call(api("Browse.SimilarTimeline", in: space), version: 1, method: "get_similar",
            parameters: ["timeline_group_unit": .string("day")])
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        return try decodeDays(payload)
    }

    private func similarGroup(_ value: SimilarGroupPayload, in space: SynologyPhotoSpace) throws -> SynologyPhotoSimilarGroup {
        guard value.id > 0, value.count >= 2, value.count == value.item_id.count,
              value.item_id.allSatisfy({ $0 > 0 }), Set(value.item_id).count == value.item_id.count,
              value.item_id.contains(value.top_pick) else { throw Self.failure(.invalidResponse) }
        return .init(profileID: profileID, space: space, id: value.id, photoIDs: value.item_id, topPickID: value.top_pick)
    }

    public func similarPhotos(for photo: SynologyPhoto) async throws -> SynologyPhotoSimilarDetail {
        try requirePhoto(photo); try requireCategoryAccess(.similar, in: photo.id.space)
        guard photo.albumContext == nil, let original = photo.similarGroup, original.profileID == profileID,
              original.space == photo.id.space, original.id > 0, original.photoIDs.contains(photo.id.unitID) else { throw Self.failure(.conflict) }
        guard let detail = try await similarGroupDetails(original), detail.group.photoIDs.contains(photo.id.unitID) else { throw Self.failure(.conflict) }
        return detail
    }

    public func similarStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoSimilarStatus {
        try requireCategoryAccess(.similar, in: space)
        let generation = accessGeneration
        let status: SimilarStatusPayload = try await call(api("Browse.Similar", in: space), version: 1, method: "get_status", parameters: [:])
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard status.waiting_count >= 0, !status.similar_clustering_stage.isEmpty else { throw Self.failure(.invalidResponse) }
        return .init(waitingCount: status.waiting_count, stage: status.similar_clustering_stage, migrationComplete: status.is_similar_hash_migration_done)
    }

    public func similarGroupDetails(_ original: SynologyPhotoSimilarGroup) async throws -> SynologyPhotoSimilarDetail? {
        guard original.profileID == profileID, original.id > 0 else { throw Self.failure(.conflict) }
        let generation = accessGeneration
        guard let group = try await currentSimilarGroup(original) else { return nil }
        try Task.checkCancellation()
        let payload: ItemList = try await call(api("Browse.Item", in: group.space), version: 5, method: "get", parameters: [
            "id": .integerArray(group.photoIDs), "additional": .stringArray(["folder", "thumbnail", "resolution", "orientation", "video_convert", "video_meta"])])
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard payload.list.count == group.photoIDs.count, Set(payload.list.map(\.id)) == Set(group.photoIDs),
              payload.list.allSatisfy({ $0.folder_id > 0 && $0.filesize >= 0 }) else { throw Self.failure(.invalidResponse) }
        let photos = try group.photoIDs.map { id in
            guard let item = payload.list.first(where: { $0.id == id }) else { throw Self.failure(.invalidResponse) }
            var member = SynologyPhoto(id: .init(profileID: profileID, space: group.space, unitID: id), filename: item.filename,
                sizeBytes: item.filesize, takenAt: Date(timeIntervalSince1970: item.time), indexedAt: Date(timeIntervalSince1970: item.indexed_time),
                folderID: item.folder_id, mediaType: item.type, thumbnail: item.additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) },
                width: item.additional?.resolution?.width, height: item.additional?.resolution?.height, orientation: item.additional?.orientation)
            member.duration = item.additional?.video_meta?.duration; member.similarGroup = group
            return member
        }
        return .init(group: group, photos: photos)
    }

    public func categoryItems(_ category: SynologyPhotoCategory, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        try await categoryItems(category, in: .personal, offset: offset, limit: limit)
    }

    public func categoryItems(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        try requireCategoryAccess(category, in: space)
        guard offset >= 0, (1...500).contains(limit) else { throw Self.failure(.invalidResponse) }
        let generation = accessGeneration
        if category == .person {
            let entries = try await personPage(offset: offset, limit: limit, includingHidden: false, in: space)
            return entries.map { $0.collection(in: space) }
        }
        guard [.concept, .location, .tags].contains(category) else { throw Self.failure(.invalidResponse) }
        let target = categoryReadAPI(category, in: space)
        let payload: AlbumList = try await call(target.name, version: target.version, method: "list", parameters: [
            "offset": .integer(offset), "limit": .integer(limit), "additional": .stringArray(["thumbnail"])
        ])
        guard payload.list.count <= limit, payload.list.allSatisfy({ $0.id > 0 }), Set(payload.list.map(\.id)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        let collections = payload.list.map { SynologyPhotoCollection(id: $0.id, name: $0.name, itemCount: $0.item_count, thumbnail: $0.additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) }, space: space) }
        if offset == 0 { categoryThumbnails[space, default: [:]][category] = [:] }
        for collection in collections {
            if let thumbnail = collection.thumbnail { categoryThumbnails[space, default: [:]][category, default: [:]][collection.id] = thumbnail }
        }
        return collections
    }

    public func categoryTimeline(_ category: SynologyPhotoCategory, id: Int) async throws -> [SynologyPhotoDay] {
        try await categoryTimeline(category, id: id, in: .personal)
    }

    public func categoryTimeline(_ category: SynologyPhotoCategory, id: Int, in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        try requireCategoryAccess(category, in: space)
        guard id > 0 else { throw Self.failure(.invalidResponse) }
        let generation = accessGeneration
        let payload: TimelinePayload = try await call(api("Browse.Timeline", in: space), version: 5, method: "get", parameters: [
            "timeline_group_unit": .string("day"), try categoryParameter(category): .integer(id)
        ])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
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
        try await sharedEntries(scope, offset: offset, limit: limit, sort: nil)
    }

    public func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int, sort: SynologyPhotoAlbumListSort?) async throws -> [SynologyPhotoSharedEntry] {
        if let sort {
            guard scope != .requests, SynologyPhotoAlbumListScope.withMe.fields.contains(sort.field) else { throw Self.failure(.invalidResponse) }
        }
        if scope == .requests { guard !allowedSpaces.isEmpty else { throw Self.failure(.permissionDenied) } }
        else { try requireAlbumAccess() }
        guard offset >= 0, (1...500).contains(limit) else { throw Self.failure(.invalidResponse) }
        var parameters: [String: DsmParameterValue] = ["offset": .integer(offset), "limit": .integer(limit)]
        if scope == .requests {
            let payload: PhotoRequestList = try await call("SYNO.Foto.PhotoRequest", version: 1, method: "list", parameters: parameters)
            guard payload.list.count <= limit, Set(payload.list.map(\.passphrase)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
            return payload.list.map { SynologyPhotoSharedEntry(id: $0.passphrase, title: $0.subject, url: Self.safeSharingURL($0.sharing_link)) }
        }
        if let sort { parameters["sort_by"] = .string(sort.field.rawValue); parameters["sort_direction"] = .string(sort.direction.rawValue) }
        parameters["additional"] = .stringArray(["sharing_info", "thumbnail", "access_permission"])
        let payload: SharedAlbumList
        if scope == .withMe {
            payload = try await call("SYNO.Foto.Sharing.Misc", version: 2, method: "list_shared_with_me_album", parameters: parameters)
        } else {
            parameters["category"] = .string("shared")
            if sort == nil {
                parameters["sort_by"] = .string("share_modify_time")
                parameters["sort_direction"] = .string("desc")
            }
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

private struct UserPayload: Decodable, Sendable { let enabled: Bool; let is_admin: Bool?; let id: Int?; let uid: SynologyPhotoConditionValue? }
private struct DuplicateSettingsPayload: Decodable, Sendable {
    let upload_default_action: String
    let copy_move_default_action: String
}
private struct UserSettings: Decodable, Sendable {
    let auto_generate_thumbnail: Bool?
    let enable_home_service: Bool
    let team_space_permission: String
    let enable_person: Bool?
    let enable_concept: Bool?
    let enable_similar: Bool?
    let item_sort_by: String?
    let sort_direction: String?
    let timeline_group_unit: String?
    let date_format: String?
    let time_format: String?
    let show_item_info_in_lightbox: Bool?
    var displaySettings: SynologyPhotoDisplaySettings? {
        guard let grouping = timeline_group_unit.flatMap(SynologyPhotoDisplaySettings.Grouping.init(rawValue:)),
              let date = date_format.flatMap({ SynologyPhotoDisplaySettings.DateFormat(rawValue: $0.lowercased()) }),
              let clock = time_format.flatMap(SynologyPhotoDisplaySettings.Clock.init(rawValue:)),
              let field = item_sort_by.flatMap(SynologyPhotoSort.Field.init(rawValue:)),
              let direction = sort_direction.flatMap(SynologyPhotoSort.Direction.init(rawValue:)),
              let info = show_item_info_in_lightbox else { return nil }
        return .init(grouping: grouping, dateFormat: date, clock: clock, defaultSort: .init(field: field, direction: direction), showsPreviewInfo: info)
    }
    let ame_status: AMEStatus?
    struct AMEStatus: Decodable, Sendable { let has_hevc: Bool?; let has_h264: Bool? }
}
private struct AdminSettings: Decodable, Sendable {
    let enable_user_sharing: Bool?
    let display_photo_info_to_guest: Bool?
    let exclude_extension: [String]?
    let package_version: String
    let enable_converted_original_jpeg: Bool?
    let enable_person: Bool?
    let enable_concept: Bool?
    let enable_similar: Bool?
}
private struct TeamSettings: Decodable, Sendable { let enabled: Bool; let allow_root_folder_public: Bool?; let team_space_disabled_by_share_folder_disabled: Bool?; let enable_person: Bool?; let enable_concept: Bool?; let enable_similar: Bool? }
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
        let owner_user_id: Int?
        let filename: String
        let filesize: Int64
        let time: Double
        let indexed_time: Double
        let folder_id: Int
        let type: String
        let additional: Additional?
        struct Additional: Decodable, Sendable { let thumbnail: ItemPayload.Thumbnail?; let provider_user_id: Int? }
        func matches(_ photo: SynologyPhoto) -> Bool {
            id == photo.id.unitID && filename == photo.filename && filesize == photo.sizeBytes
                && Date(timeIntervalSince1970: time) == photo.takenAt
                && Date(timeIntervalSince1970: indexed_time) == photo.indexedAt
                && folder_id == photo.folderID && type == photo.mediaType
        }
        func photo(for target: SynologyPhotosAlbumCheckpoint.PhotoEdit.Target) -> SynologyPhoto {
            .init(id: .init(profileID: target.profileID, space: target.space, unitID: id), filename: filename,
                  sizeBytes: filesize, takenAt: Date(timeIntervalSince1970: time), indexedAt: Date(timeIntervalSince1970: indexed_time),
                  folderID: folder_id, mediaType: type, albumContext: target.queryPhoto.albumContext)
        }
    }
}
private struct SimilarStatusPayload: Decodable, Sendable {
    let waiting_count: Int
    let similar_clustering_stage: String
    let is_similar_hash_migration_done: Bool
}
private struct SimilarGroupPayload: Decodable, Sendable {
    let id: Int; let count: Int; let top_pick: Int; let item_id: [Int]
}
private struct SimilarGroupList: Decodable, Sendable { let list: [SimilarGroupPayload] }

private struct ItemPayload: Decodable, Sendable {
    let similar: SimilarGroupPayload?
    let owner_user_id: Int?
    let id: Int
    let filename: String
    let filesize: Int64
    let time: TimeInterval
    let indexed_time: TimeInterval
    let folder_id: Int
    let type: String
    let additional: Additional?
    struct Additional: Decodable, Sendable {
        let provider_user_id: Int?
        let thumbnail: Thumbnail?
        let resolution: Resolution?
        let orientation: Int?
        let orientation_original: Int?
        let description: String?
        let exif: Exif?
        let video_meta: VideoMeta?
        let video_convert: [VideoConversion]?
        let video_convert_status: String?
        let rating: Int?
        let tag: [SynologyPhotoFilterChoice]?
        let address: [String: String]?
        let gps: GPS?
    }
    struct Exif: Decodable, Sendable {
        let camera: String?; let lens: String?; let aperture: String?
        let exposure_time: String?; let focal_length: String?; let iso: String?
    }
    struct VideoMeta: Decodable, Sendable { let duration: Double?; let video_codec: String? }
    struct VideoConversion: Decodable, Sendable { let quality: String }
    struct GPS: Decodable, Sendable { let latitude: Double; let longitude: Double }
    struct Thumbnail: Decodable, Sendable { let unit_id: Int; let cache_key: String; let xl: String?; let sm: String? }
    struct Resolution: Decodable, Sendable { let width: Int; let height: Int }
}

private struct FolderPayload: Decodable, Sendable { let folder: FolderEntry }
private struct FolderList: Decodable, Sendable { let list: [FolderEntry] }
private struct FolderEntry: Decodable, Sendable {
    let sort_by: String?
    let sort_direction: String?
    var sort: SynologyPhotoSort? {
        guard let field = sort_by.flatMap(SynologyPhotoSort.Field.init(rawValue:)), let direction = sort_direction.flatMap(SynologyPhotoSort.Direction.init(rawValue:)) else { return nil }
        return .init(field: field, direction: direction)
    }
    let id: Int; let name: String; let parent: Int; let shared: Bool?
    let additional: Additional?
    struct Additional: Decodable, Sendable { let access_permission: Access?; let thumbnail: [Cover]?; let sharing_info: ManagementAlbum.Sharing? }
    struct Cover: Decodable, Sendable { let unit_id: Int?; let folder_cover_seq: Int?; let cache_key: String }
    struct Access: Decodable, Sendable { let view: Bool; let manage: Bool?; let upload: Bool?; let download: Bool? }
    var collection: SynologyPhotoCollection { collection(in: .personal) }
    func collection(in space: SynologyPhotoSpace) -> SynologyPhotoCollection {
        SynologyPhotoCollection(id: id, name: (name as NSString).lastPathComponent, parentID: parent, path: name, space: space, sort: sort)
    }
}
private struct AlbumList: Decodable, Sendable { let list: [AlbumEntry] }
private struct AlbumEntry: Decodable, Sendable {
    let freeze_album: Bool?
    let type: String?
    let id: Int; let name: String; let item_count: Int?
    let additional: Additional?
    struct Additional: Decodable, Sendable { let thumbnail: ItemPayload.Thumbnail? }
}

private struct CategoryPreviewList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable {
        let id: Int
        let additional: PersonEntry.Additional?
    }
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
    let person: [PersonEntry]
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
    struct Entry: Decodable, Sendable {
        let passphrase: String; let subject: String; let sharing_link: String?
        let description: String?; let library: String?; let folder_home_path: String?; let folder_id: Int?
        let album_id: Int?; let album_passphrase: String?; let album_name: String?
        let expiration: Int?; let filesize_limit: Int64?; let is_folder_valid: Bool?
    }
}
private struct PreviewRegeneratingList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable { let unit_id: Int; let type: String; let filename: String }
}
private struct SharedAlbumList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable {
        let id: Int; let name: String
    }
}

// MARK: - 按实际接口能力与权限开放的照片管理

private typealias PhotosGlobalStep = SynologyPhotosAlbumCheckpoint.Administration.GlobalStep

private typealias PhotosPreviewFailureKind = SynologyPhotosAlbumCheckpoint.AutomaticPreview.FailureKind

private struct PhotosMutationRecord: Sendable {
    var automaticFailureKind: PhotosPreviewFailureKind?
    var automaticFailureAcknowledged = false
    var codecGenerationAcknowledged = false
    var codecPromptRejected = false
    var libraryMaintenanceAcknowledged = false
    var memberAttempted: Set<Int> = []
    var memberAcknowledged: Set<Int> = []
    var memberRejected: Set<Int> = []
    var memberCurrent: Int?
    var globalAttempted: Set<PhotosGlobalStep> = []
    var globalAcknowledged: Set<PhotosGlobalStep> = []
    var globalRejected: Set<PhotosGlobalStep> = []
    var globalCurrent: PhotosGlobalStep?
    let mutation: SynologyPhotosMutation
    var automaticPreviewSubmitted = false
    var automaticPreviewAcknowledged = false
    var automaticThumbnailDigests: [String: Data] = [:]
    var automaticVideoSignature: PhotosPreviewVideoSignature?
    var backgroundAttempted: Set<Int> = []
    var backgroundRejected: Set<Int> = []
    var backgroundCurrent: Int?
    var taskID: Int?
    var transferTargetVerified = false
    var transferTotal: Int?
    var itemID: Int?
    var uploadAction: String?
    var albumMembershipHasFailures = false
    var albumID: Int?
    var frozenDeletionAttempted = false
    var frozenDeletionRejected = false
    var temporaryAlbumMembers: [SynologyPhotoID: PhotosAlbumMemberSnapshot]?
    var folderID: Int?
    var createdTag: SynologyPhotoFilterChoice?
    var tagAdditionRejected = false
    var tagAdditionAttempted = false
    var metadataSubmittedIDs: Set<SynologyPhotoID> = []
    var metadataRejectedIDs: Set<SynologyPhotoID> = []
    var metadataFailureReportedIDs: Set<SynologyPhotoID> = []
    var metadataCurrentIDs: Set<SynologyPhotoID> = []
    var shiftedSubmittedIDs: Set<SynologyPhotoID> = []
    var shiftedRejectedID: SynologyPhotoID?
    var shiftingPhotoID: SynologyPhotoID?
    var enableSharingAttempted = false
    var photoRequestID: String?
    var passwordUpdateAcknowledged = false
    var folderCoverAcknowledged = false
    var folderSharingAcknowledged = false
    var restoredFolderSharing: SynologyPhotosAlbumCheckpoint.FolderSharing?
    var sharingBefore: ManagementAlbum.Sharing?
    var restoredAlbumSharing: SynologyPhotosAlbumCheckpoint.Sharing?
    var restoredPhotoRequest: SynologyPhotosAlbumCheckpoint.Request?
    var usesAlbumRecovery = false
    var restoredFrozen: SynologyPhotosAlbumCheckpoint.Frozen?
    var restoredCondition: SynologyPhotosAlbumCheckpoint.Condition?
    var restoredPhotoEdit: SynologyPhotosAlbumCheckpoint.PhotoEdit?
    var restoredRecognition: SynologyPhotosAlbumCheckpoint.Recognition?
    var restoredSimilar: SynologyPhotosAlbumCheckpoint.Similar?
    var similarSubmitted = false
    var manualAddAttempted = false
    var manualAddAcknowledged = false
    var manualAttempted: Set<String> = []
    var manualThumbnailAttempted: Set<Int> = []
    var manualCurrent: String?
    var personPhotoIDs: Set<Int>?
    var personReceipt: PersonNameReceipt?
    var personCoverReceipt: PersonCoverReceipt?
    var manualNewIDs: [String: Int] = [:]
    var manualPersonReceipts: [String: PersonNameReceipt] = [:]
    var manualUploaded: Set<Int> = []
    var manualAcknowledged: Set<String> = []
    var manualKnownFailures: Set<String> = []
    var regenerationBaseline: [SynologyPhotoID: SynologyPhotoThumbnail] = [:]
    var regenerationMarking: Set<SynologyPhotoID> = []
    var regenerationMarked: Set<SynologyPhotoID> = []
    var regenerationRestoring: Set<SynologyPhotoID> = []
    var regenerationSubmitted: Set<SynologyPhotoID> = []
    var regenerationAttempted: Set<SynologyPhotoID> = []
    var regenerationRecovered: Set<SynologyPhotoID> = []
    var regenerated: Set<SynologyPhotoID> = []
    var regenerationFailed: Set<SynologyPhotoID> = []
    var visibilityAcknowledged = false
    var conceptRemovalAcknowledged = false
    var result = SynologyPhotosMutationResult(state: .pendingReview)
}

extension SynologyPhotosRepository {
    private func recognitionState(user: UserSettings, admin: AdminSettings) -> SynologyPhotoRecognitionSettings {
        let pairs: [(SynologyPhotoRecognitionSettings.Kind, Bool?, Bool?)] = [
            (.person, user.enable_person, admin.enable_person), (.concept, user.enable_concept, admin.enable_concept),
            (.similar, user.enable_similar, admin.enable_similar)]
        var values: [SynologyPhotoRecognitionSettings.Kind: Bool] = [:]
        var enabled: Set<SynologyPhotoRecognitionSettings.Kind> = []
        for (kind, value, global) in pairs {
            if let value, let global { values[kind] = value; if global { enabled.insert(kind) } }
        }
        return .init(values: values, globallyEnabled: enabled, personalSpaceEnabled: user.enable_home_service)
    }

    private func cacheRecognition(user: UserSettings, admin: AdminSettings) {
        // 已知的关闭状态立即作用于分类；旧环境缺字段仍沿Category返回能力。
        personalRecognition = [:]
        for (category, value, global) in [(SynologyPhotoCategory.person, user.enable_person, admin.enable_person),
            (.concept, user.enable_concept, admin.enable_concept), (.similar, user.enable_similar, admin.enable_similar)] {
            if let value { personalRecognition[category] = value && global != false }
            else if global == false { personalRecognition[category] = false }
        }
        personalSimilarEnabled = user.enable_similar == true && admin.enable_similar != false
    }

    private func requirePhotosAdministrator() async throws -> Int {
        try requireAlbumAccess()
        let generation = accessGeneration
        let identity: UserPayload = try await call("SYNO.Foto.UserInfo", version: 1, method: "me")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        isPhotosAdministrator = identity.enabled && identity.is_admin == true
        guard isPhotosAdministrator, let id = identity.id, id > 0, id == currentUserID else { throw Self.failure(.permissionDenied) }
        return id
    }

    public func codecPrompt() async throws -> SynologyPhotoCodecPrompt {
        try requireAlbumAccess()
        let generation = accessGeneration
        let identity: UserPayload = try await call("SYNO.Foto.UserInfo", version: 1, method: "me")
        guard identity.enabled, let id = identity.id, id > 0, id == currentUserID,
              let administrator = identity.is_admin else { throw Self.failure(.permissionDenied) }
        let user: UserSettings = try await call("SYNO.Foto.Setting.User", version: 1, method: "get")
        struct Wizard: Decodable {
            struct Prompt: Decodable { let name: String; let show: Bool }
            let prompt: [Prompt]
        }
        let wizard: Wizard = try await call("SYNO.Foto.Setting.Wizard", version: 1, method: "get")
        let matching = wizard.prompt.filter { $0.name == "new_codec_installed" }
        guard matching.count <= 1 else { throw Self.failure(.invalidResponse) }
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        let show = matching.first?.show ?? false
        if !show { codecGenerationAcknowledgedUsers.remove(id) }
        return .init(profileID: profileID, userID: id, isAdministrator: administrator,
                     shouldShow: show, personalSpaceEnabled: user.enable_home_service,
                     generationAlreadySubmitted: codecGenerationAcknowledgedUsers.contains(id))
    }

    public func libraryMaintenanceStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoLibraryMaintenanceStatus {
        try requireAccess(space)
        let generation = accessGeneration
        let identity: UserPayload = try await call("SYNO.Foto.UserInfo", version: 1, method: "me")
        guard identity.enabled, let userID = identity.id, userID == currentUserID, userID > 0,
              space != .shared || identity.is_admin == true else { throw Self.failure(.permissionDenied) }
        let user: UserSettings = try await call("SYNO.Foto.Setting.User", version: 1, method: "get")
        if space == .personal {
            guard user.enable_home_service else { throw Self.failure(.permissionDenied) }
        } else {
            let team: TeamSettings = try await call("SYNO.Foto.Setting.TeamSpace", version: 1, method: "get")
            guard team.enabled, ["entry", "management"].contains(user.team_space_permission) else { throw Self.failure(.permissionDenied) }
        }
        struct Counts: Decodable { let basic: Int; let thumbnail: Int }
        let counts: Counts = try await call(api("Index", in: space), version: 1, method: "get")
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard counts.basic >= 0, counts.thumbnail >= 0 else { throw Self.failure(.invalidResponse) }
        return .init(profileID: profileID, userID: userID, space: space, indexingCount: counts.basic,
                     previewCount: counts.thumbnail, supportsPreviewGeneration: user.ame_status?.has_h264 == true)
    }

    public func globalSettings() async throws -> SynologyPhotoGlobalSettings {
        let generation = accessGeneration
        let id = try await requirePhotosAdministrator()
        let user: UserSettings = try await call("SYNO.Foto.Setting.User", version: 1, method: "get")
        let admin: AdminSettings = try await call("SYNO.Foto.Setting.Admin", version: 1, method: "get")
        let team: TeamSettings = try await call("SYNO.Foto.Setting.TeamSpace", version: 1, method: "get")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        guard let role = SynologyPhotoSharedSpaceSettings.Role(rawValue: user.team_space_permission) else { throw Self.failure(.invalidResponse) }
        var values: [SynologyPhotoGlobalSettings.Kind: Bool] = [:]
        for (kind, value) in [(SynologyPhotoGlobalSettings.Kind.person, admin.enable_person), (.concept, admin.enable_concept),
                              (.similar, admin.enable_similar), (.userSharing, admin.enable_user_sharing),
                              (.guestInfo, admin.display_photo_info_to_guest), (.originalJPEG, admin.enable_converted_original_jpeg)] {
            values[kind] = value
        }
        var personal: [SynologyPhotoRecognitionSettings.Kind: Bool] = [:], shared: [SynologyPhotoRecognitionSettings.Kind: Bool] = [:]
        for (kind, mine, others) in [(SynologyPhotoRecognitionSettings.Kind.person, user.enable_person, team.enable_person),
                                    (.concept, user.enable_concept, team.enable_concept), (.similar, user.enable_similar, team.enable_similar)] {
            personal[kind] = mine; shared[kind] = others
        }
        let settings = SynologyPhotoGlobalSettings(profileID: profileID, administratorID: id, values: values,
            excludedExtensions: admin.exclude_extension.map(Set.init), hasHEVC: user.ame_status?.has_hevc,
            personalRecognition: personal, sharedRecognition: shared, personalSpaceEnabled: user.enable_home_service,
            sharedSpaceEnabled: team.enabled, sharedRole: role)
        cacheRecognition(user: user, admin: admin)
        supportsOriginalSizeJPEG = settings.supportsOriginalJPEG
        for kind in SynologyPhotoRecognitionSettings.Kind.allCases {
            if shared[kind] == true, values[.init(rawValue: kind.rawValue)!] != false, team.enabled, role != .none {
                sharedCategorySettings.insert(kind.category)
            } else if shared[kind] == false || values[.init(rawValue: kind.rawValue)!] == false || !team.enabled || role == .none {
                sharedCategorySettings.remove(kind.category)
            }
        }
        return settings
    }

    public func conversionCache() async throws -> SynologyPhotoConversionCache {
        let generation = accessGeneration
        let id = try await requirePhotosAdministrator()
        struct Status: Decodable, Sendable { let status: String }
        struct Size: Decodable, Sendable { let cache_size: Int64 }
        let status: Status = try await call("SYNO.Foto.Download", version: 2, method: "get_cache_status")
        let size: Size = try await call("SYNO.Foto.Download", version: 2, method: "calculate_cache_size")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        guard !status.status.isEmpty, size.cache_size >= 0 else { throw Self.failure(.invalidResponse) }
        return .init(profileID: profileID, administratorID: id, sizeBytes: size.cache_size, isClearing: status.status == "processing")
    }

    /// 复用既有操作编号，按官方联动拆成明确步骤；核对过程绝不重放任何写入。
    private func globalSteps(_ original: SynologyPhotoGlobalSettings, _ target: SynologyPhotoGlobalSettings) -> [(PhotosGlobalStep, String, Int, String, [String: DsmParameterValue])] {
        var steps: [(PhotosGlobalStep, String, Int, String, [String: DsmParameterValue])] = []
        if original.values[.originalJPEG] == true, target.values[.originalJPEG] == false {
            steps.append((.cache, "SYNO.Foto.Download", 2, "clear_cache", [:]))
        }
        var admin: [String: DsmParameterValue] = [:]
        for kind in original.values.keys where original.values[kind] != target.values[kind] { admin[kind.rawValue] = .boolean(target.values[kind] == true) }
        if let extensions = target.excludedExtensions, extensions != original.excludedExtensions { admin["exclude_extension"] = .stringArray(extensions.sorted()) }
        if !admin.isEmpty { steps.append((.admin, "SYNO.Foto.Setting.Admin", 1, "set", admin)) }
        for (step, api, before, after) in [(PhotosGlobalStep.personal, "SYNO.Foto.Setting.User", original.personalRecognition, target.personalRecognition),
                                          (.shared, "SYNO.Foto.Setting.TeamSpace", original.sharedRecognition, target.sharedRecognition)] {
            var changes: [String: DsmParameterValue] = [:]
            for kind in before.keys where before[kind] != after[kind] { changes[kind.rawValue] = .boolean(after[kind] == true) }
            if !changes.isEmpty { steps.append((step, api, 1, "set", changes)) }
        }
        return steps
    }

    public func sharedSpaceSettings() async throws -> SynologyPhotoSharedSpaceSettings {
        try requireAlbumAccess()
        let generation = accessGeneration
        let identity: UserPayload = try await call("SYNO.Foto.UserInfo", version: 1, method: "me")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        isPhotosAdministrator = identity.enabled && identity.is_admin == true
        guard isPhotosAdministrator, let id = identity.id, id > 0, id == currentUserID else { throw Self.failure(.permissionDenied) }
        let user: UserSettings = try await call("SYNO.Foto.Setting.User", version: 1, method: "get")
        let admin: AdminSettings = try await call("SYNO.Foto.Setting.Admin", version: 1, method: "get")
        let team: TeamSettings = try await call("SYNO.Foto.Setting.TeamSpace", version: 1, method: "get")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        guard let role = SynologyPhotoSharedSpaceSettings.Role(rawValue: user.team_space_permission) else { throw Self.failure(.invalidResponse) }
        var values: [SynologyPhotoSharedSpaceSettings.Kind: Bool] = [:]
        var globallyEnabled: Set<SynologyPhotoSharedSpaceSettings.Kind> = []
        for (kind, value, global) in [(SynologyPhotoSharedSpaceSettings.Kind.person, team.enable_person, admin.enable_person),
                                     (.concept, team.enable_concept, admin.enable_concept), (.similar, team.enable_similar, admin.enable_similar)] {
            if let value, let global { values[kind] = value; if global { globallyEnabled.insert(kind) } }
        }
        values[.publicRoot] = team.allow_root_folder_public
        let state = SynologyPhotoSharedSpaceSettings(profileID: profileID, administratorID: id, isEnabled: team.enabled,
            personalSpaceEnabled: user.enable_home_service, role: role, disabledBySharedFolder: team.team_space_disabled_by_share_folder_disabled,
            values: values, globallyEnabled: globallyEnabled)
        if state.canAccess { allowedSpaces.insert(.shared) } else { allowedSpaces.remove(.shared) }
        managesSharedSpace = state.canAccess && role == .management
        sharedCategorySettings = state.canAccess ? [.recentlyAdded, .location, .tags, .videos] : []
        if state.canAccess {
            if team.enable_person == true, admin.enable_person != false { sharedCategorySettings.insert(.person) }
            if team.enable_concept == true, admin.enable_concept != false { sharedCategorySettings.insert(.concept) }
            if team.enable_similar == true, admin.enable_similar != false { sharedCategorySettings.insert(.similar) }
        }
        return state
    }

    public func sharedSpaceMembers() async throws -> SynologyPhotoSharedMembers {
        let generation = accessGeneration
        let administrator = try await requirePhotosAdministrator()
        let team: TeamSettings = try await call("SYNO.Foto.Setting.TeamSpace", version: 1, method: "get")
        // 此方法的data直接是数组；不得套用相册分享的data.list或过滤本人。
        let values: [SynologyPhotoConditionValue] = try await call("SYNO.Foto.Setting.TeamSpace", version: 1, method: "list_permission")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        let members = try values.map { value -> SynologyPhotoSharedMember in
            guard let recipient = sharingRecipient(value), let fields = value.object,
                  let role = fields["permission"]?.string, !role.isEmpty,
                  case .boolean(let backup) = fields["auto_backup"] else { throw Self.failure(.invalidResponse) }
            return .init(recipient: recipient, role: role, autoBackup: backup)
        }
        guard Set(members.map(\.id)).count == members.count else { throw Self.failure(.invalidResponse) }
        return .init(profileID: profileID, administratorID: administrator, isEnabled: team.enabled, members: members)
    }

    public func sharedSpaceMemberCandidates() async throws -> [SynologyPhotoShareRecipient] {
        let generation = accessGeneration
        _ = try await requirePhotosAdministrator()
        struct Payload: Decodable, Sendable { let list: [SynologyPhotoConditionValue] }
        let payload: Payload = try await call("SYNO.Foto.Sharing.Misc", version: 1, method: "list_user_group")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        let recipients = try payload.list.map { value in
            guard let recipient = sharingRecipient(value) else { throw Self.failure(.invalidResponse) }
            return recipient
        }
        guard Set(recipients.map(\.id)).count == recipients.count else { throw Self.failure(.invalidResponse) }
        return recipients
    }

    public func sharedSpaceMemberFolderSnapshot(for member: SynologyPhotoShareRecipient.ID) async throws -> [SynologyPhotoMemberFolder] {
        let generation = accessGeneration
        var result: [SynologyPhotoMemberFolder] = [], seen: Set<Int> = []
        func append(_ entries: [SynologyPhotoMemberFolder]) throws {
            for folder in entries {
                guard seen.insert(folder.id).inserted else { throw Self.failure(.conflict) }
                result.append(folder)
            }
        }
        var offset: Int? = 0
        while let current = offset {
            let page = try await sharedSpaceMemberFolders(for: member, parent: nil, offset: current, limit: 200)
            try append(page.folders); offset = page.nextOffset
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        }
        let parents = result
        for parent in parents {
            offset = 0
            while let current = offset {
                let page = try await sharedSpaceMemberFolders(for: member, parent: parent, offset: current, limit: 200)
                guard page.parent == parent else { throw Self.failure(.conflict) }
                try append(page.folders); offset = page.nextOffset
                guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            }
        }
        return result
    }

    private struct MemberWriteStep {
        enum Kind { case members, allFolders(Int), folders(Int) }
        let kind: Kind
        let api: String
        let method: String
        let parameters: [String: DsmParameterValue]
    }

    private func sharedMemberSteps(original: SynologyPhotoSharedMembers, members: [SynologyPhotoSharedMember], edits: [SynologyPhotoMemberFolderEdit]) throws -> [MemberWriteStep] {
        func memberID(_ id: SynologyPhotoShareRecipient.ID) throws -> [String: DsmJSONValue] {
            let value: DsmJSONValue
            switch id.value {
            case .integer(let number) where number > 0: value = .integer(number)
            case .string(let text) where !text.isEmpty: value = .string(text)
            default: throw Self.failure(.invalidResponse)
            }
            guard ["user", "group"].contains(id.type) else { throw Self.failure(.invalidResponse) }
            return ["id": value, "type": .string(id.type)]
        }
        let before = Dictionary(uniqueKeysWithValues: original.members.map { ($0.id, $0) })
        let after = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        var changes: [[String: DsmJSONValue]] = []
        for (member, action) in original.members.filter({ after[$0.id] == nil }).map({ ($0, "delete") }) +
            members.filter({ before[$0.id] != $0 }).map({ ($0, "update") }) {
            var fields = try memberID(member.id)
            fields["permission"] = .string(member.role); fields["auto_backup"] = .boolean(member.autoBackup)
            fields["action"] = .string(action); changes.append(fields)
        }
        var steps: [MemberWriteStep] = []
        if !changes.isEmpty {
            steps.append(.init(kind: .members, api: "SYNO.Foto.Setting.TeamSpace", method: "update_permission", parameters: ["list": .objectArray(changes)]))
        }
        for (index, edit) in edits.enumerated() {
            let identity = try memberID(edit.memberID)
            if let batch = edit.batch {
                steps.append(.init(kind: .allFolders(index), api: "SYNO.FotoTeam.Sharing.FolderBatchPermission", method: "update_all_by_member",
                    parameters: ["permission": .object(["member": .object(identity), "role": .string(batch.role.rawValue), "action": .string(batch.action.rawValue)])]))
            }
            if !edit.changes.isEmpty {
                var fields = identity
                fields["list"] = .array(edit.changes.map { change in
                    var value: [String: DsmJSONValue] = ["folder_id": .integer(change.folderID), "action": .string(change.role == nil ? "delete" : "update")]
                    if let role = change.role { value["role"] = .string(role.rawValue) }
                    return .object(value)
                })
                steps.append(.init(kind: .folders(index), api: "SYNO.FotoTeam.Sharing.FolderBatchPermission", method: "update_by_member", parameters: ["permission": .object(fields)]))
            }
        }
        return steps
    }

    private func sameSharedMembers(_ lhs: SynologyPhotoSharedMembers, _ rhs: SynologyPhotoSharedMembers) -> Bool {
        lhs.profileID == rhs.profileID && lhs.administratorID == rhs.administratorID && lhs.isEnabled == rhs.isEnabled &&
            Dictionary(uniqueKeysWithValues: lhs.members.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: rhs.members.map { ($0.id, $0) })
    }

    private func prepareSharedMembers(original: SynologyPhotoSharedMembers, members: [SynologyPhotoSharedMember], edits: [SynologyPhotoMemberFolderEdit]) async throws {
        guard original.profileID == profileID, original.isEnabled,
              Set(original.members.map(\.id)).count == original.members.count, Set(members.map(\.id)).count == members.count,
              Set(edits.map(\.memberID)).count == edits.count else { throw Self.failure(.conflict) }
        guard sameSharedMembers(try await sharedSpaceMembers(), original) else { throw Self.failure(.conflict) }
        let added = members.filter { member in !original.members.contains { $0.id == member.id } }
        let candidates = added.isEmpty ? [] : try await sharedSpaceMemberCandidates()
        guard original.canSave(members, candidates: candidates, allowsUnchanged: !edits.isEmpty) else { throw Self.failure(.permissionDenied) }
        for edit in edits {
            guard edit.canSave, let member = members.first(where: { $0.id == edit.memberID }), member.role == "entry", !member.isProtected,
                  edit.original.allSatisfy({ $0.profileID == profileID && $0.folder.space == .shared }) else { throw Self.failure(.permissionDenied) }
            let current = try await sharedSpaceMemberFolderSnapshot(for: edit.memberID)
            guard Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) }) == Dictionary(uniqueKeysWithValues: edit.original.map { ($0.id, $0) }) else { throw Self.failure(.conflict) }
        }
        guard !(try sharedMemberSteps(original: original, members: members, edits: edits)).isEmpty else { throw Self.failure(.conflict) }
        if !edits.isEmpty {
            guard sameSharedMembers(try await sharedSpaceMembers(), original) else { throw Self.failure(.conflict) }
        }
    }

    private func inspectSharedMembers(original: SynologyPhotoSharedMembers, members: [SynologyPhotoSharedMember], edits: [SynologyPhotoMemberFolderEdit], record: PhotosMutationRecord) async throws -> SynologyPhotosMutationResult {
        let generation = accessGeneration
        let current = try await sharedSpaceMembers()
        guard current.profileID == original.profileID, current.administratorID == original.administratorID else { throw Self.failure(.permissionDenied) }
        let steps = try sharedMemberSteps(original: original, members: members, edits: edits)
        let before = Dictionary(uniqueKeysWithValues: original.members.map { ($0.id, $0) })
        let desired = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let actual = Dictionary(uniqueKeysWithValues: current.members.map { ($0.id, $0) })
        let changedMembers = Set(before.keys).union(desired.keys).filter { before[$0] != desired[$0] }
        func sameGrant(_ lhs: SynologyPhotoSharedMember?, _ rhs: SynologyPhotoSharedMember?) -> Bool {
            lhs?.id == rhs?.id && lhs?.role == rhs?.role && lhs?.autoBackup == rhs?.autoBackup
        }
        var finished: Set<Int> = [], changed = changedMembers.contains { !sameGrant(actual[$0], before[$0]) }
        var folderSnapshots: [Int: [SynologyPhotoMemberFolder]] = [:]
        for (index, step) in steps.enumerated() where record.memberAttempted.contains(index) {
            switch step.kind {
            case .members:
                if current.isEnabled, changedMembers.allSatisfy({ sameGrant(actual[$0], desired[$0]) }) { finished.insert(index) }
            case .allFolders(let editIndex), .folders(let editIndex):
                let edit = edits[editIndex]
                if folderSnapshots[editIndex] == nil { folderSnapshots[editIndex] = try await sharedSpaceMemberFolderSnapshot(for: edit.memberID) }
                let folders = Dictionary(uniqueKeysWithValues: (folderSnapshots[editIndex] ?? []).map { ($0.id, $0) })
                func matches(_ folder: SynologyPhotoMemberFolder, role: String?) -> Bool {
                    guard let value = folders[folder.id], value.folder == folder.folder, value.privacy == folder.privacy,
                          value.hasKnownPermissions else { return false }
                    // 网页把公开权限下限内的直接角色视为等价；不推断其他群组带来的访问。
                    let expected = max(role.flatMap(SynologyPhotoFolderMemberRole.init(rawValue:))?.level ?? -1, folder.publicRole?.level ?? -1)
                    return (value.effectiveRole?.level ?? -1) == expected
                }
                changed = changed || edit.original.contains { folder in
                    guard let value = folders[folder.id] else { return false }
                    return value.directRole != folder.directRole
                }
                switch step.kind {
                case .allFolders:
                    let following = steps.indices.first { candidate in
                        if case .folders(let value) = steps[candidate].kind { return value == editIndex }
                        return false
                    }
                    let hasFollowingAttempt = following.map { record.memberAttempted.contains($0) } ?? false
                    if Set(folders.keys) == Set(edit.original.map(\.id)), edit.original.allSatisfy({ folder in
                        matches(folder, role: edit.expectedRole(for: folder, includingChanges: false)) ||
                            (hasFollowingAttempt && matches(folder, role: edit.expectedRole(for: folder)))
                    }) { finished.insert(index) }
                case .folders:
                    let direct = Set(edit.changes.map(\.folderID))
                    let affected = edit.original.filter { folder in
                        direct.contains(folder.id) || (folder.depth == 1 && folder.folder.parentID.map(direct.contains) == true &&
                            edit.expectedRole(for: folder) != edit.expectedRole(for: folder, includingChanges: false))
                    }
                    if affected.allSatisfy({ matches($0, role: edit.expectedRole(for: $0)) }) { finished.insert(index) }
                case .members: break
                }
            }
        }
        let all = Set(steps.indices)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        guard finished == all || record.memberAttempted.isSubset(of: finished.union(record.memberRejected)) else {
            return .init(state: .pendingReview, completedCount: finished.count)
        }
        // 在交付确认/部分结果前重新取得本人的实际空间角色，不能从被编辑的群组猜测权限。
        let settings = try await sharedSpaceSettings()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        let state: SynologyPhotosMutationResult.State = finished == all ? .confirmed : (changed || !finished.isEmpty ? .partial : .rejected)
        return .init(state: state, completedCount: finished.count, sharedSpaceSettings: settings, sharedMembers: current)
    }

    public func sharedSpaceMemberFolders(for member: SynologyPhotoShareRecipient.ID, parent: SynologyPhotoMemberFolder?, offset: Int, limit: Int) async throws -> SynologyPhotoMemberFolderPage {
        guard ["user", "group"].contains(member.type), isValidMemberID(member.value), offset >= 0,
              (1...200).contains(limit), offset <= Int.max - limit else { throw Self.failure(.invalidResponse) }
        if let parent {
            guard parent.profileID == profileID, parent.memberID == member, parent.depth == 0,
                  parent.folder.space == .shared, parent.id > 0 else { throw Self.failure(.conflict) }
        }
        let generation = accessGeneration
        let administrator = try await requirePhotosAdministrator()
        let team: TeamSettings = try await call("SYNO.Foto.Setting.TeamSpace", version: 1, method: "get")
        guard generation == accessGeneration, team.enabled else { throw Self.failure(.permissionDenied) }
        let root: FolderPayload = try await call("SYNO.FotoTeam.Browse.Folder", version: 2, method: "get")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard root.folder.id > 0 else { throw Self.failure(.invalidResponse) }
        var currentParent: SynologyPhotoMemberFolder?
        if let parent {
            guard parent.rootID == root.folder.id, parent.folder.parentID == root.folder.id else { throw Self.failure(.conflict) }
            let current: FolderPayload = try await call("SYNO.FotoTeam.Browse.Folder", version: 2, method: "get",
                parameters: ["id": .integer(parent.id), "additional": .stringArray(["sharing_info"])])
            guard current.folder.id == parent.id, current.folder.parent == root.folder.id,
                  current.folder.name == parent.folder.path else { throw Self.failure(.conflict) }
            currentParent = try memberFolder(current.folder, member: member, rootID: root.folder.id, depth: 0)
        }
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        let parentID = parent?.id ?? root.folder.id
        let payload: FolderList = try await call("SYNO.FotoTeam.Browse.Folder", version: 2, method: "list", parameters: [
            "id": .integer(parentID), "offset": .integer(offset), "limit": .integer(limit),
            "sort_by": .string("filename"), "sort_direction": .string("asc"), "additional": .stringArray(["sharing_info"])
        ])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        guard payload.list.count <= limit, Set(payload.list.map(\.id)).count == payload.list.count,
              payload.list.allSatisfy({ $0.id > 0 && $0.id != parentID && $0.id != root.folder.id && $0.parent == parentID }) else { throw Self.failure(.invalidResponse) }
        let folders = try payload.list.map { try memberFolder($0, member: member, rootID: root.folder.id, depth: parent == nil ? 0 : 1) }
        return .init(profileID: profileID, administratorID: administrator, memberID: member, parentID: parentID,
                     parent: currentParent, folders: folders, nextOffset: folders.count == limit ? offset + limit : nil)
    }

    private func isValidMemberID(_ id: SynologyPhotoConditionValue) -> Bool {
        switch id { case .integer(let value): value > 0; case .string(let value): !value.isEmpty; default: false }
    }

    private func memberFolder(_ folder: FolderEntry, member: SynologyPhotoShareRecipient.ID, rootID: Int, depth: Int) throws -> SynologyPhotoMemberFolder {
        guard let sharing = folder.additional?.sharing_info, let privacy = sharing.privacy_type, !privacy.isEmpty,
              let permissions = sharing.permission?.array else { throw Self.failure(.invalidResponse) }
        var roles: [SynologyPhotoShareRecipient.ID: String] = [:]
        for value in permissions {
            guard let fields = value.object, let type = fields["type"]?.string else { throw Self.failure(.invalidResponse) }
            if type == "public" { continue }
            guard ["user", "group"].contains(type), let id = fields["id"], isValidMemberID(id),
                  let role = fields["role"]?.string, !role.isEmpty else { throw Self.failure(.invalidResponse) }
            let key = SynologyPhotoShareRecipient.ID(type: type, value: id)
            guard roles.updateValue(role, forKey: key) == nil else { throw Self.failure(.invalidResponse) }
        }
        // 核对摘要只含目录身份与权限，不把分享链接或口令带入成员编辑快照。
        struct Revision: Encodable { let id: Int; let parent: Int; let name: String; let privacy: String; let permissions: [SynologyPhotoConditionValue] }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(Revision(id: folder.id, parent: folder.parent, name: folder.name,
            privacy: privacy, permissions: permissions)))
        return .init(profileID: profileID, memberID: member, rootID: rootID, folder: folder.collection(in: .shared),
                     depth: depth, privacy: privacy, directRole: roles[member], revision: digest.map { String(format: "%02x", $0) }.joined())
    }

    public func recognitionSettings() async throws -> SynologyPhotoRecognitionSettings {
        try requireAlbumAccess()
        let generation = accessGeneration
        let user: UserSettings = try await call("SYNO.Foto.Setting.User", version: 1, method: "get")
        let admin: AdminSettings = try await call("SYNO.Foto.Setting.Admin", version: 1, method: "get")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        cacheRecognition(user: user, admin: admin)
        return recognitionState(user: user, admin: admin)
    }

    public func displaySettings() async throws -> SynologyPhotoDisplaySettings {
        try requireAlbumAccess()
        let generation = accessGeneration
        let payload: UserSettings = try await call("SYNO.Foto.Setting.User", version: 1, method: "get")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard let value = payload.displaySettings else { throw Self.failure(.invalidResponse) }
        return value
    }

    public func duplicateSettings() async throws -> SynologyPhotoDuplicateSettings {
        try requireAlbumAccess()
        let generation = accessGeneration
        let payload: DuplicateSettingsPayload = try await call("SYNO.Foto.Setting.User", version: 1, method: "get")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard let upload = SynologyPhotoDuplicateSettings.Upload(rawValue: payload.upload_default_action),
              let transfer = SynologyPhotoDuplicateSettings.Transfer(rawValue: payload.copy_move_default_action) else { throw Self.failure(.invalidResponse) }
        return .init(upload: upload, transfer: transfer)
    }

    public func managementFeatures() async -> Set<SynologyPhotosManagementFeature> {
        await managementFeatures(in: .personal)
    }

    public func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> {
        guard allowedSpaces.contains(space) else {
            guard hasPhotosAccess else { return [] }
            return Set([SynologyPhotosManagementFeature.albums, .sharing, .frozenAlbums, .backgroundTasks, .codecPrompt, .globalSettings, .conversionCache, .sharedSpaceSettings, .sharedMembers, .automaticPreviewSettings, .recognitionSettings, .displaySettings, .duplicateSettings, .albumSorting, .albumListSorting, .albumListDisplay].filter { feature in
                (![.sharedMembers, .sharedSpaceSettings, .globalSettings, .conversionCache].contains(feature) || isPhotosAdministrator) && managementRequirements(feature).allSatisfy { name, version in
                    guard let capability = capabilities[name] else { return false }
                    return capability.minVersion <= version && capability.maxVersion >= version && capability.requestFormat == .json
                }
            })
        }
        // 相册与人物使用独立目标契约；照片管理按选中照片空间路由。
        var features: [SynologyPhotosManagementFeature] = space == .personal ? SynologyPhotosManagementFeature.allCases : [.frozenAlbums, .backgroundTasks, .codecPrompt, .folders, .folderDeletion, .folderCover, .folderSorting, .upload, .metadata, .rotation, .tags, .tagCreation, .fileTransfer, .photoRequests, .previewRegeneration, .albums, .automaticPreview, .automaticPreviewSettings, .recognitionSettings, .displaySettings, .duplicateSettings, .albumSorting, .albumListSorting, .albumListDisplay]
        if isPhotosAdministrator { features += [.sharedMembers, .sharedSpaceSettings, .globalSettings, .conversionCache] }
        else { features.removeAll { [.sharedMembers, .sharedSpaceSettings, .globalSettings, .conversionCache].contains($0) } }
        if !deletionEnabled { features.removeAll { $0 == .folderDeletion } }
        if space == .shared, isPhotosAdministrator { features.append(.libraryMaintenance) }
        if space == .shared, managesSharedSpace { features += [.conditionAlbums, .folderSharing] }
        if space == .personal { features.removeAll { $0 == .folderSharing } }
        if space == .shared, managesSharedSpace, sharedCategorySettings.contains(.person) {
            features += [.peopleNames, .peopleMerge, .peopleFaces, .peopleCover, .peopleVisibility, .manualFaces]
        }
        if space == .shared, managesSharedSpace, sharedCategorySettings.contains(.concept) { features += [.conceptVisibility, .conceptCover, .conceptItems] }
        if space == .shared, managesSharedSpace, sharedCategorySettings.contains(.similar) { features.append(.similarGroups) }
        if space == .personal {
            if !personalSimilarEnabled { features.removeAll { $0 == .similarGroups } }
            if personalRecognition[.person] == false { features.removeAll { [.peopleNames, .peopleMerge, .peopleFaces, .peopleCover, .peopleVisibility, .manualFaces].contains($0) } }
            if personalRecognition[.concept] == false { features.removeAll { [.conceptVisibility, .conceptCover, .conceptItems].contains($0) } }
        }
        return Set(features.filter { feature in
            managementRequirements(feature).allSatisfy { personalName, version in
                // 相册、收集和任务状态是统一入口，只有照片与目录按来源切换。
                let unified = feature == .codecPrompt || feature == .sharedMembers || feature == .conversionCache || feature == .globalSettings || ["SYNO.Foto.UserInfo", "SYNO.Foto.Setting.TeamSpace", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.User", "SYNO.Foto.BackgroundTask.Info", "SYNO.Foto.PhotoRequest", "SYNO.Foto.Browse.Album", "SYNO.Foto.Browse.NormalAlbum", "SYNO.Foto.Browse.ConditionAlbum"].contains(personalName)
                let name = space == .shared && !unified ? personalName.replacingOccurrences(of: "SYNO.Foto.", with: "SYNO.FotoTeam.") : personalName
                guard let capability = capabilities[name] else { return false }
                return capability.minVersion <= version && capability.maxVersion >= version && capability.requestFormat == .json
            }
        })
    }

    private func managementRequirements(_ feature: SynologyPhotosManagementFeature) -> [(String, Int)] {
        let common = [("SYNO.Foto.Browse.Item", 5), ("SYNO.Foto.Browse.Folder", 2)]
        switch feature {
        case .backgroundTasks: return [("SYNO.Foto.BackgroundTask.Info", 1)]
        case .codecPrompt: return [("SYNO.Foto.UserInfo", 1), ("SYNO.Foto.Setting.User", 1), ("SYNO.Foto.Setting.Wizard", 1), ("SYNO.Foto.Index", 1)]
        case .libraryMaintenance: return [("SYNO.Foto.Index", 1), ("SYNO.Foto.UserInfo", 1), ("SYNO.Foto.Setting.User", 1)]
        case .automaticPreview: return [("SYNO.Foto.Upload.ConvertedFile", 3), ("SYNO.Foto.Download", 2)]
        case .albumListSorting: return [("SYNO.Foto.Browse.Album", 2)]
        case .albumListDisplay: return [("SYNO.Foto.Browse.Album", 3)]
        case .albumSorting: return [("SYNO.Foto.Browse.Album", 1), ("SYNO.Foto.Browse.Album", 4)]
        case .conversionCache: return [("SYNO.Foto.UserInfo", 1), ("SYNO.Foto.Download", 2)]
        case .globalSettings, .sharedSpaceSettings: return [("SYNO.Foto.UserInfo", 1), ("SYNO.Foto.Setting.TeamSpace", 1), ("SYNO.Foto.Setting.Admin", 1), ("SYNO.Foto.Setting.User", 1)]
        case .sharedMembers: return [("SYNO.Foto.UserInfo", 1), ("SYNO.Foto.Setting.TeamSpace", 1), ("SYNO.Foto.Setting.Admin", 1), ("SYNO.Foto.Setting.User", 1), ("SYNO.Foto.Sharing.Misc", 1), ("SYNO.FotoTeam.Browse.Folder", 2), ("SYNO.FotoTeam.Sharing.FolderBatchPermission", 1)]
        case .recognitionSettings: return [("SYNO.Foto.Setting.User", 1), ("SYNO.Foto.Setting.Admin", 1)]
        case .automaticPreviewSettings, .displaySettings, .duplicateSettings: return [("SYNO.Foto.Setting.User", 1)]
        case .similarGroups: return common + [("SYNO.Foto.Browse.Similar", 1), ("SYNO.Foto.Browse.SimilarItem", 1), ("SYNO.Foto.Browse.SimilarTimeline", 1)]
        case .previewRegeneration: return common + [("SYNO.Foto.RegeneratePreview", 1)]
        case .metadata, .rotation: return common + [("SYNO.Foto.Browse.Item", 2)]
        case .tags: return common + [("SYNO.Foto.Browse.Item", 1)]
        case .tagCreation: return common + [("SYNO.Foto.Browse.Item", 1), ("SYNO.Foto.Browse.GeneralTag", 1)]
        case .albums: return common + [("SYNO.Foto.Browse.Album", 4), ("SYNO.Foto.Browse.NormalAlbum", 1)]
        case .frozenAlbums: return [("SYNO.Foto.Browse.Album", 4), ("SYNO.Foto.Browse.NormalAlbum", 1)]
        case .conditionAlbums: return [("SYNO.Foto.Browse.Album", 4), ("SYNO.Foto.Browse.ConditionAlbum", 3), ("SYNO.Foto.Browse.Folder", 2)]
        case .folderSorting: return [("SYNO.Foto.Browse.Folder", 1), ("SYNO.Foto.Browse.Folder", 2)]
        case .folderSharing: return [("SYNO.FotoTeam.Browse.Folder", 2), ("SYNO.FotoTeam.Sharing.FolderPermission", 1)]
        case .folderCover: return common
        case .folders: return [("SYNO.Foto.Browse.Folder", 1), ("SYNO.Foto.Browse.Folder", 2)]
        case .folderDeletion, .fileTransfer: return common + [("SYNO.Foto.BackgroundTask.File", 1), ("SYNO.Foto.BackgroundTask.Info", 1)]
        case .upload: return common + [("SYNO.Foto.Upload.Item", 1)]
        case .photoRequests: return [("SYNO.Foto.PhotoRequest", 1)]
        case .sharing: return [("SYNO.Foto.Browse.Album", 4), ("SYNO.Foto.Sharing.Passphrase", 1)]
        case .peopleFaces, .peopleCover: return common + [("SYNO.Foto.Browse.Person", 1)]
        case .manualFaces: return [("SYNO.Foto.Browse.Item", 6), ("SYNO.Foto.Browse.Folder", 2), ("SYNO.Foto.Browse.Person", 3), ("SYNO.Foto.Upload.Face", 1)]
        case .conceptCover, .conceptItems: return common + [("SYNO.Foto.Browse.Concept", 1), ("SYNO.Foto.Browse.Concept", 2), ("SYNO.Foto.Browse.Timeline", 5), ("SYNO.Foto.Browse.Item", 4)]
        case .conceptVisibility: return [("SYNO.Foto.Browse.Concept", 2)]
        case .peopleNames, .peopleVisibility: return [("SYNO.Foto.Browse.Person", 1)]
        case .peopleMerge: return [("SYNO.Foto.Browse.Person", 2), ("SYNO.Foto.Browse.Timeline", 5), ("SYNO.Foto.Browse.Item", 4), ("SYNO.Foto.Browse.Folder", 2)]
        }
    }

    /// 无照片目标的普通相册命令属于统一相册入口，不依赖个人照片空间是否开启。
    private func mutationAccessSpace(_ mutation: SynologyPhotosMutation) throws -> SynologyPhotoSpace {
        if [.frozenAlbums, .backgroundTasks, .codecPrompt, .sharedMembers, .globalSettings, .conversionCache, .sharedSpaceSettings, .automaticPreviewSettings, .recognitionSettings, .displaySettings, .duplicateSettings, .albumSorting, .albumListSorting, .albumListDisplay].contains(mutation.feature) { try requireAlbumAccess(); return .personal }
        if mutation.isAlbumCollaboration { try requireAlbumAccess(); return .personal }
        if mutation.feature == .albums, mutation.photos.isEmpty {
            try requireAlbumAccess()
            return .personal
        }
        try requireAccess(mutation.space)
        if mutation.supportsMixedPhotoSpaces {
            let spaces = Set(mutation.photos.map { $0.id.space })
            for space in spaces { try requireAccess(space) }
            if spaces.count > 1, !managesSharedSpace { throw Self.failure(.permissionDenied) }
        }
        return mutation.space
    }

    public func prepareMutation(_ mutation: SynologyPhotosMutation) async throws {
        _ = try await prepareMutationTarget(mutation)
    }

    /// 官方相册信息编辑和旋转使用原空间写接口；只读相册上下文核对实际提供者。
    private func editableAlbumPhoto(_ photo: SynologyPhoto) async throws -> SynologyPhoto {
        try requireAccess(photo.id.space)
        guard photo.id.profileID == profileID, let context = photo.albumContext,
              let user = currentUserID, pendingDeletions[photo.id] == nil else { throw Self.failure(.permissionDenied) }
        let generation = accessGeneration
        let current = try await details(for: photo)
        guard current.id == photo.id, current.filename == photo.filename, current.sizeBytes == photo.sizeBytes,
              current.folderID == photo.folderID, current.indexedAt == photo.indexedAt,
              current.takenAt == photo.takenAt, current.mediaType == photo.mediaType,
              current.albumContext?.albumID == context.albumID,
              current.albumContext?.ownerUserID == context.ownerUserID else { throw Self.failure(.conflict) }
        if photo.id.space == .shared {
            guard managesSharedSpace else { throw Self.failure(.permissionDenied) }
        } else if current.albumContext?.providerUserID != user {
            guard context.ownerUserID == user else { throw Self.failure(.permissionDenied) }
            let album = try await managedAlbum(context.albumID)
            guard album.type == "condition" || album.freeze_album == true else { throw Self.failure(.permissionDenied) }
        }
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try requireAccess(photo.id.space)
        return current
    }

    private func prepareMutationTarget(_ mutation: SynologyPhotosMutation) async throws -> (albumTarget: [String: DsmParameterValue]?, previewBaselines: [SynologyPhotoID: SynologyPhotoThumbnail]) {
        var previewBaselines: [SynologyPhotoID: SynologyPhotoThumbnail] = [:]
        var albumTarget: [String: DsmParameterValue]?
        let accessSpace = try mutationAccessSpace(mutation)
        if mutation.isAlbumCollaboration {
            let name = mutation.feature == .upload ? "SYNO.Foto.Upload.Item" : "SYNO.Foto.Browse.NormalAlbum"
            guard let capability = capabilities[name], capability.minVersion <= 1, capability.maxVersion >= 1 else { throw Self.failure(.apiUnavailable) }
        } else {
            guard await managementFeatures(in: accessSpace).contains(mutation.feature) else {
                throw deletionError(.apiUnavailable, "photos.manage.unavailable")
            }
        }
        let generation = accessGeneration
        let targets = mutation.photos
        if mutation.supportsMixedPhotoSpaces {
            for space in Set(targets.map({ $0.id.space })) {
                guard await managementFeatures(in: space).contains(mutation.feature) else { throw Self.failure(.apiUnavailable) }
            }
        }
        if mutation.feature == .albums, Set(targets.map { $0.id.unitID }).count != targets.count { throw Self.failure(.conflict) }
        guard (targets.count <= 100 || mutation.feature == .conceptItems || mutation.feature == .similarGroups || mutation.feature == .folderDeletion || !mutation.transferFolders.isEmpty), Set(targets.map(\.id)).count == targets.count else { throw Self.failure(.invalidResponse) }
        switch mutation {
        case .cancelBackgroundTask(let original):
            let current = try await currentBackgroundTask(original)
            guard original.canCancel, current.canCancel else { throw Self.failure(.conflict) }
        case .clearBackgroundTasks(let originals):
            guard !originals.isEmpty, Set(originals.map(\.id)).count == originals.count,
                  originals.allSatisfy(\.canClear) else { throw Self.failure(.conflict) }
            // 本会话尚待核对的搬移任务必须先取得终态，不能提前清掉唯一回读证据。
            guard !mutations.values.contains(where: { record in
                record.result.state == .pendingReview && record.taskID.map { id in originals.contains { $0.id == id } } == true
            }) else { throw deletionError(.conflict, "photos.manage.pending") }
            let current = try await backgroundTasks()
            for original in originals {
                guard original.profileID == profileID, original.userID == currentUserID,
                      let task = current.first(where: { $0.id == original.id }), task.canClear,
                      task.hasSameIdentity(as: original) else { throw Self.failure(.conflict) }
            }
        case .respondToCodecPrompt(let original, let generate):
            guard original.profileID == profileID, original.userID == currentUserID, original.shouldShow,
                  !generate || original.canGenerate else { throw Self.failure(.conflict) }
            let current = try await codecPrompt()
            guard current.shouldShow == original.shouldShow, current.isAdministrator == original.isAdministrator,
                  current.personalSpaceEnabled == original.personalSpaceEnabled,
                  !generate || current.canGenerate else { throw Self.failure(.conflict) }
        case .maintainLibrary(let original, let action):
            guard original.profileID == profileID, original.userID == currentUserID, original.canStart(action) else { throw Self.failure(.conflict) }
            let current = try await libraryMaintenanceStatus(in: original.space)
            guard current.userID == original.userID, current.canStart(action) else { throw Self.failure(.conflict) }
        case .setSharedMembers(let original, let members, let edits):
            try await prepareSharedMembers(original: original, members: members, edits: edits)
        case .setAutomaticPreview(let original, let enabled):
            guard original != enabled, try await automaticPreviewEnabled() == original else { throw Self.failure(.conflict) }
        case .generateAutomaticPreview(let task, let support):
            try await validateAutomaticPreview(task, support: support)
        case .setAlbumListSort(let scope, let original, let sort):
            guard original != sort, scope.fields.contains(sort.field), try await albumListSort(scope) == original else { throw Self.failure(.conflict) }
        case .setAlbumListDisplay(let original, let display):
            guard original != display, try await albumListDisplay() == original else { throw Self.failure(.conflict) }
        case .setAlbumSort(let id, let original, let sort):
            guard original != sort, try await albumSort(id: id) == original else { throw Self.failure(.conflict) }
        case .setGlobalSettings(let original, let enabled, let extensions):
            guard original.profileID == profileID, original.canSave(enabled: enabled, excludedExtensions: extensions) else { throw Self.failure(.permissionDenied) }
            guard try await globalSettings() == original else { throw Self.failure(.conflict) }
            if original.values[.originalJPEG] == true, !enabled.contains(.originalJPEG) {
                guard await managementFeatures().contains(.conversionCache), try await !conversionCache().isClearing else { throw Self.failure(.conflict) }
            }
        case .clearConversionCache(let original):
            guard original.profileID == profileID, original.canClear else { throw Self.failure(.permissionDenied) }
            let current = try await conversionCache()
            guard current.administratorID == original.administratorID, current.canClear else { throw Self.failure(.conflict) }
        case .setSharedSpaceSettings(let original, let enabled):
            guard original.profileID == profileID, original.canSave(enabled) else { throw Self.failure(.permissionDenied) }
            guard try await sharedSpaceSettings() == original else { throw Self.failure(.conflict) }
        case .setSharedSpaceEnabled(let original, let enabled):
            guard original.profileID == profileID, original.canSetEnabled(enabled) else { throw Self.failure(.permissionDenied) }
            guard try await sharedSpaceSettings() == original else { throw Self.failure(.conflict) }
        case .setRecognitionSettings(let original, let enabled):
            guard original.canSave(enabled) else { throw Self.failure(.permissionDenied) }
            guard try await recognitionSettings() == original else { throw Self.failure(.conflict) }
        case .setDisplaySettings(let original, let updated):
            guard original != updated, try await displaySettings() == original else { throw Self.failure(.conflict) }
        case .setDuplicateSettings(let original, let updated):
            guard original != updated, try await duplicateSettings() == original else { throw Self.failure(.conflict) }
        case .setFolderSharing(let original, _, let members, _, let apply):
            let current = try await folderSharing(original.folder)
            guard current == original else { throw deletionError(.conflict, "photos.sharing.changed") }
            guard !current.inheritsManagementOnly,
                  current.depth == 1 || apply == current.appliesToSubfolders else { throw Self.failure(.permissionDenied) }
            if let members {
                guard let existing = current.members else { throw Self.failure(.invalidResponse) }
                try validateSharingMembers(members, original: existing, conditional: false, folder: true)
                let added = members.filter { member in !existing.contains { $0.id == member.id } }
                if !added.isEmpty {
                    let available = try await folderSharingRecipients()
                    guard added.allSatisfy({ member in available.contains { $0.id == member.id } }) else { throw Self.failure(.permissionDenied) }
                }
            }
        case .deleteFolderItems(let photos, let folders):
            let parent = try selectedFolderParent(folders)
            guard photos.allSatisfy({ $0.id.space == parent.space && $0.folderID == parent.id && $0.albumContext == nil }) else { throw Self.failure(.conflict) }
            _ = try await readableFolder(parent)
            for folder in folders {
                let current = try await readableFolder(folder)
                guard current.parent == parent.id, canWriteFolder(current, in: folder.space, forUpload: false) else { throw Self.failure(.permissionDenied) }
            }
        case .renameFolder(let folder, let name):
            _ = try renamedFolderPath(folder, name: name)
            let current = try await readableFolder(folder)
            guard canWriteFolder(current, in: folder.space, forUpload: false),
                  folder.parentID == nil || folder.parentID == current.parent else { throw Self.failure(.permissionDenied) }
        case .setFolderSort(let folder, _):
            _ = try await readableFolder(folder)
        case .regeneratePreviews(let photos, let resuming):
            if resuming {
                for space in Set(photos.map({ $0.id.space })) {
                    let queue = try await previewRegenerationQueue(in: space)
                    for photo in photos where photo.id.space == space { try requireQueuedPreview(photo, queue: queue) }
                }
            }
            guard !photos.isEmpty else { throw Self.failure(.invalidResponse) }
        case .createPhotoRequest(let settings):
            try await validatePhotoRequestSettings(settings)
        case .updatePhotoRequest(let original, let settings):
            try await validatePhotoRequestSnapshot(original)
            try await validatePhotoRequestSettings(settings)
        case .deletePhotoRequest(let original):
            try await validatePhotoRequestSnapshot(original)
        case .editPhotoFaces(let photo, let changes):
            guard photo.mediaType != "video", !changes.isEmpty, changes.count <= 100,
                  Set(changes.map(\.id)).count == changes.count else { throw Self.failure(.invalidResponse) }
            let current = try await photoFaces(for: photo)
            var targets: [SynologyPhotoCollection] = []
            for change in changes {
                switch change {
                case .add(let face):
                    guard face.bounds.isValid, !face.temporaryID.isEmpty, face.jpeg.starts(with: [0xff, 0xd8, 0xff]),
                          !face.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || face.person != nil else { throw Self.failure(.invalidResponse) }
                    if let person = face.person { guard person.space == photo.id.space, person.name == face.name else { throw Self.failure(.conflict) }; targets.append(person) }
                case .remove(let original), .reassign(let original, _, _):
                    guard current.contains(original) else { throw Self.failure(.conflict) }
                    if case .reassign(_, let person, let name) = change {
                        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || person != nil else { throw Self.failure(.invalidResponse) }
                        if let person { guard person.space == photo.id.space, person.name == name else { throw Self.failure(.conflict) }; targets.append(person) }
                    }
                }
            }
            if !targets.isEmpty {
                let currentPeople = try await visibility(for: Array(Set(targets.map(\.id))).sorted(), in: mutation.space)
                guard targets.allSatisfy({ target in currentPeople.contains { $0.id == target.id && $0.person.name == target.name } }) else { throw Self.failure(.conflict) }
            }
        case .setConceptCover(let original, _), .removeConceptItems(let original, _):
            guard original.id > 0, !targets.isEmpty, targets.allSatisfy({ $0.id.space == original.concept.space && $0.albumContext == nil }) else { throw Self.failure(.invalidResponse) }
            let current = try await conceptState(id: original.id, in: mutation.space)
            guard current == original else { throw Self.failure(.conflict) }
            if case .removeConceptItems = mutation {
                guard let count = current.concept.itemCount, let threshold = current.displayThreshold,
                      count >= targets.count, threshold >= 0 else { throw Self.failure(.invalidResponse) }
            }
            let members = try await categoryPhotos(.concept, id: original.id, in: mutation.space)
            let memberIDs = Set(members.map(\.id))
            guard targets.allSatisfy({ memberIDs.contains($0.id) }) else { throw Self.failure(.conflict) }
        case .setConceptVisibility(let originals, let visible):
            guard !originals.isEmpty,
                  originals.allSatisfy({ $0.id > 0 && $0.concept.space == mutation.space && $0.isVisible != visible }),
                  Set(originals.map(\.id)).count == originals.count else { throw Self.failure(.invalidResponse) }
            let current = try await conceptVisibility(for: originals.map(\.id), in: mutation.space)
            for original in originals {
                guard let item = current.first(where: { $0.id == original.id }), item.isVisible == original.isVisible,
                      item.concept.name == original.concept.name else { throw Self.failure(.conflict) }
            }
        case .setPeopleVisibility(let originals, let visible):
            guard !originals.isEmpty, originals.count <= 100, originals.allSatisfy({ $0.id > 0 && $0.person.space == mutation.space && $0.isVisible != visible }),
                  Set(originals.map(\.id)).count == originals.count else { throw Self.failure(.invalidResponse) }
            let current = try await visibility(for: originals.map(\.id), in: mutation.space)
            for original in originals {
                guard let item = current.first(where: { $0.id == original.id }), item.isVisible == original.isVisible,
                      item.person.name == original.person.name,
                      original.person.itemCount == nil || item.person.itemCount == original.person.itemCount else { throw Self.failure(.conflict) }
            }
        case .removePersonFaces(let person, let faces), .reassignPersonFaces(let person, let faces, _, _):
            try await validatePeople([person], in: mutation.space)
            guard !faces.isEmpty, faces.allSatisfy({ $0.personID == person.id && $0.photo.id.space == person.space && $0.id > 0 }), Set(faces.map(\.id)).count == faces.count else { throw Self.failure(.invalidResponse) }
            if case .reassignPersonFaces(_, _, let target, let name) = mutation, let target {
                guard target.id != person.id, target.name == name else { throw Self.failure(.invalidResponse) }
                try await validatePeople([target], in: mutation.space)
            }
            let current = try await personFaces(personID: person.id, photos: targets)
            guard faces.allSatisfy({ face in current.contains { $0.id == face.id && $0.photo == face.photo } }) else { throw Self.failure(.conflict) }
        case .setPersonCover(let person, let photo):
            guard person.space == photo.id.space else { throw Self.failure(.permissionDenied) }
            try await validatePeople([person], in: mutation.space)
            guard !(try await personFaces(personID: person.id, photos: [photo])).isEmpty else { throw Self.failure(.conflict) }
        case .renamePerson(let person, _):
            try await validatePeople([person], in: mutation.space)
        case .mergePeople(let target, let sources, _):
            guard !sources.isEmpty else { throw Self.failure(.invalidResponse) }
            try await validatePeople([target] + sources, in: mutation.space)
        case .rotatePhoto(let photo):
            guard photo.supportsRotation else { throw Self.failure(.invalidResponse) }
        case .edit(let photos, let edit):
            guard !photos.isEmpty else { throw Self.failure(.invalidResponse) }
            if case .rating(let rating) = edit, !(0...5).contains(rating) { throw Self.failure(.invalidResponse) }
            if case .takenAt(let date) = edit, !date.timeIntervalSince1970.isFinite || date.timeIntervalSince1970 < 0 || date.timeIntervalSince1970 > Double(Int.max / 2) { throw Self.failure(.invalidResponse) }
        case .shiftDates(let photos, let seconds):
            guard !photos.isEmpty, seconds != 0 else { throw Self.failure(.invalidResponse) }
            for photo in photos { _ = try shiftedTimestamp(photo, seconds: seconds) }
        case .createTag(let name, _, _):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.failure(.invalidResponse) }
        case .addTags(let photos, let ids), .removeTags(let photos, let ids):
            guard !photos.isEmpty, !ids.isEmpty, ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else { throw Self.failure(.invalidResponse) }
        case .createTemporaryAlbum(let name, let photos):
            guard let user = currentUserID, user > 0, !photos.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  await managementFeatures(in: .personal).contains(.sharing) else { throw Self.failure(.permissionDenied) }
        case .copyTemporaryAlbum(_, let name, _):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.failure(.invalidResponse) }
        case .deleteTemporaryAlbum: break
        case .createAlbum(let name, _), .renameAlbum(_, let name):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.failure(.invalidResponse) }
        case .unfreezeAlbum(let original), .rebuildFrozenAlbum(let original, _, _):
            let current = try await frozenAlbum(id: original.album.id)
            guard current.hasSameState(as: original) else { throw Self.failure(.conflict) }
            if case .rebuildFrozenAlbum(_, let name, let condition) = mutation {
                guard original.canRebuild, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      await managementFeatures(in: condition.sourceSpace).contains(.conditionAlbums) else { throw Self.failure(.permissionDenied) }
                try await validateCondition(condition)
            }
        case .createConditionAlbum(let name, let condition):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Self.failure(.invalidResponse) }
            try await validateCondition(condition)
        case .setAlbumCondition(let id, let original, let condition):
            let current = try await albumCondition(id: id)
            guard try conditionParameters(current) == conditionParameters(original) else { throw Self.failure(.conflict) }
            try await validateCondition(condition)
        case .createFolder(let parent, let name, let space):
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw Self.failure(.invalidResponse) }
            try await requireManagedFolder(parent, in: space, forUpload: space == .shared)
        case .addToAlbum(_, let photos), .removeFromAlbum(_, let photos):
            guard !photos.isEmpty else { throw Self.failure(.invalidResponse) }
        default: break
        }
        if mutation.isAddingAlbumMembers, targets.contains(where: { $0.albumContext != nil }), Set(targets.map { $0.id.space }).count > 1 {
            guard managesSharedSpace else { throw Self.failure(.permissionDenied) }
        }
        let copiesOriginal: Bool = if case .copy = mutation { true } else { false }
        var verifiedAlbumPhotos: [SynologyPhoto] = []
        var verifiedEditingPhotos: [SynologyPhoto] = []
        for photo in targets {
            if case .setFolderCover(let folder, _) = mutation {
                try await prepareFolderCover(folder, photo: photo)
                continue
            }
            if mutation.isAddingAlbumMembers, photo.albumContext != nil {
                // 贡献者可添加本人提供的相册项目；原件所有者可以是相册拥有者。
                try requireAccess(photo.id.space)
                guard let user = currentUserID, pendingDeletions[photo.id] == nil else { throw Self.failure(.permissionDenied) }
                let current = try await details(for: photo)
                guard current.id == photo.id, current.filename == photo.filename, current.sizeBytes == photo.sizeBytes,
                      current.folderID == photo.folderID, current.indexedAt == photo.indexedAt else { throw Self.failure(.conflict) }
                guard current.albumContext?.providerUserID == user else { throw Self.failure(.permissionDenied) }
                continue
            }
            if case .removeFromAlbum(let id, _) = mutation, photo.albumContext?.albumID == id {
                let current = try await details(for: photo)
                guard current.id == photo.id, current.filename == photo.filename, current.sizeBytes == photo.sizeBytes,
                      current.folderID == photo.folderID, current.indexedAt == photo.indexedAt else { throw Self.failure(.conflict) }
                verifiedAlbumPhotos.append(current)
                continue
            }
            if mutation.feature == .previewRegeneration {
                if let baseline = try await validatePreviewRegenerationTarget(photo) { previewBaselines[photo.id] = baseline }
                continue
            }
            if photo.albumContext != nil, [.metadata, .rotation, .tags, .tagCreation, .manualFaces].contains(mutation.feature) {
                guard mutation.supportsMixedPhotoSpaces || photo.id.space == mutation.space else { throw Self.failure(.permissionDenied) }
                let current = try await editableAlbumPhoto(photo)
                verifiedEditingPhotos.append(current)
                if case .rotatePhoto = mutation {
                    guard current.supportsRotation, current.mediaType == photo.mediaType,
                          current.orientation == photo.orientation, current.width == photo.width,
                          current.height == photo.height else { throw Self.failure(.conflict) }
                }
                continue
            }
            try requirePhoto(photo)
            guard (mutation.feature == .albums || mutation.supportsMixedPhotoSpaces || photo.id.space == mutation.space), pendingDeletions[photo.id] == nil else { throw Self.failure(.permissionDenied) }
            if case .rotatePhoto = mutation {
                let current = try await details(for: photo)
                guard current.supportsRotation, current.filename == photo.filename, current.sizeBytes == photo.sizeBytes,
                      current.folderID == photo.folderID, current.indexedAt == photo.indexedAt,
                      current.mediaType == photo.mediaType, current.orientation == photo.orientation,
                      current.width == photo.width, current.height == photo.height else { throw Self.failure(.conflict) }
                try await requireManagedFolder(photo.folderID, in: photo.id.space)
                continue
            }
            let parameters: [String: DsmParameterValue] = ["id": .integerArray([photo.id.unitID])]
            let identity: DeletionItemList = try await call(api("Browse.Item", in: photo.id.space), version: 5, method: "get", parameters: parameters)
            guard identity.list.count == 1, identity.list.first?.matches(photo) == true else { throw deletionError(.conflict, "photos.delete.changed") }
            if (mutation.feature == .albums || copiesOriginal), photo.id.space == .shared {
                let folder: FolderPayload = try await call(api("Browse.Folder", in: .shared), version: 2, method: "get", parameters: [
                    "id": .integer(photo.folderID), "additional": .stringArray(["access_permission"])])
                guard folder.folder.id == photo.folderID, managesSharedSpace ||
                    (folder.folder.additional?.access_permission?.view == true && folder.folder.additional?.access_permission?.download == true) else { throw Self.failure(.permissionDenied) }
            } else { try await requireManagedFolder(photo.folderID, in: photo.id.space) }
        }
        if Set(targets.map { $0.id.space }).count > 1, !verifiedEditingPhotos.isEmpty {
            guard managesSharedSpace else { throw Self.failure(.permissionDenied) }
            for albumID in Set(verifiedEditingPhotos.compactMap { $0.albumContext?.albumID }) {
                let album = try await managedAlbum(albumID)
                if album.owner_user_id != currentUserID {
                    guard verifiedEditingPhotos.filter({ $0.albumContext?.albumID == albumID }).allSatisfy({ $0.albumContext?.providerUserID == currentUserID }) else { throw Self.failure(.permissionDenied) }
                }
            }
        }
        switch mutation {
        case .copyTemporaryAlbum(let id, _, let original), .deleteTemporaryAlbum(let id, let original, _):
            let album = try await managedAlbum(id)
            guard let user = currentUserID, user > 0, album.owner_user_id == user,
                  album.type != "condition", album.freeze_album != true, album.temporary_shared == true, original.isTemporary == true,
                  try sharingState(album).revision == original.revision else { throw Self.failure(.conflict) }
            if case .deleteTemporaryAlbum(_, _, let copyID) = mutation {
                guard album.shared == false, original.access == .disabled else { throw Self.failure(.conflict) }
                if let copyID {
                    guard copyID > 0, copyID != id else { throw Self.failure(.invalidResponse) }
                    let copy = try await managedAlbum(copyID)
                    guard copy.owner_user_id == user, copy.temporary_shared == false, copy.shared == false else { throw Self.failure(.conflict) }
                    guard try await albumMemberSnapshot(id) == albumMemberSnapshot(copyID) else {
                        throw deletionError(.conflict, "photos.temporary.copyChanged")
                    }
                    let current = try await managedAlbum(id)
                    guard current.owner_user_id == user, current.temporary_shared == true, current.shared == false,
                          try sharingState(current).revision == original.revision else { throw Self.failure(.conflict) }
                }
            }
        case .renameAlbum(let id, _), .deleteAlbum(let id), .addToAlbum(let id, _), .removeFromAlbum(let id, _), .setAlbumCover(let id, _), .shareAlbum(let id, _, _, _, _, _):
            let album = try await managedAlbum(id)
            let rights = try await albumAccess(album)
            if mutation.isAlbumCollaboration { albumTarget = try albumWriteTarget(album, rights: rights) }
            if case .addToAlbum = mutation { guard rights.canContribute else { throw Self.failure(.permissionDenied) } }
            else if case .removeFromAlbum = mutation {
                guard rights.canContribute, rights.isOwner || (verifiedAlbumPhotos.count == targets.count &&
                    verifiedAlbumPhotos.allSatisfy({ $0.albumContext?.providerUserID == rights.currentUserID })) else { throw Self.failure(.permissionDenied) }
            } else { guard rights.isOwner else { throw Self.failure(.permissionDenied) } }
            if case .shareAlbum(_, _, let original, let members, let expiration, let password) = mutation {
                if password != nil, original == nil { throw Self.failure(.invalidResponse) }
                if let expiration {
                    guard original != nil, expiration >= 0 else { throw Self.failure(.invalidResponse) }
                }
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
        case .move(let photos, let folder, _, let folders, _), .copy(let photos, let folder, _, let folders, _):
            guard !photos.isEmpty || !folders.isEmpty else { throw Self.failure(.invalidResponse) }
            let destination = mutation.destinationSpace
            if case .move = mutation, mutation.space == .shared, destination == .personal { throw Self.failure(.permissionDenied) }
            if folders.isEmpty {
                guard !photos.contains(where: { $0.id.space == destination && $0.folderID == folder }) else { throw Self.failure(.invalidResponse) }
                try await requireManagedFolder(folder, in: destination, forUpload: true)
            } else {
                let parent = try selectedFolderParent(folders)
                guard photos.allSatisfy({ $0.folderID == parent.id && $0.id.space == parent.space && $0.albumContext == nil }) else { throw Self.failure(.conflict) }
                _ = try await readableFolder(parent)
                for source in folders {
                    let current = try await readableFolder(source)
                    let allowed = copiesOriginal && source.space == .shared
                        ? managesSharedSpace || current.additional?.access_permission?.download == true
                        : canWriteFolder(current, in: source.space, forUpload: false)
                    guard current.parent == parent.id, allowed else { throw Self.failure(.permissionDenied) }
                }
                let target = try await readableFolder(.init(id: folder, name: "", space: destination))
                guard canWriteFolder(target, in: destination, forUpload: true),
                      mutation.acceptsTransferDestination(target.collection(in: destination)) else { throw Self.failure(.conflict) }
            }
        case .uploadToAlbum(let url, let size, let modified, let id, _):
            let album = try await managedAlbum(id)
            let rights = try await albumAccess(album)
            albumTarget = try albumWriteTarget(album, rights: rights)
            guard rights.canContribute, url.isFileURL, size > 0 else { throw Self.failure(.permissionDenied) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.fileSize.map(Int64.init) == size, values.contentModificationDate == modified else { throw deletionError(.conflict, "photos.manage.fileChanged") }
        case .upload(let url, let size, let modified, let folder, let space, _):
            guard url.isFileURL, size > 0 else { throw Self.failure(.invalidResponse) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true, values.fileSize.map(Int64.init) == size, values.contentModificationDate == modified else { throw deletionError(.conflict, "photos.manage.fileChanged") }
            if let folder { try await requireManagedFolder(folder, in: space, forUpload: space == .shared) }
            else { let root = try await rootFolder(in: space); try await requireManagedFolder(root.id, in: space, forUpload: space == .shared) }
        default: break
        }
        if case .setAlbumCover(let id, let photo) = mutation {
            guard try await verifyAlbumMembership(id, photos: [photo], present: true) else { throw Self.failure(.conflict) }
        }
        if case .editSimilarGroup(let detail, let edit) = mutation { try await prepareSimilarEdit(detail, edit: edit) }
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        _ = try mutationAccessSpace(mutation)
        return (albumTarget, previewBaselines)
    }

    private func validateSimilarSnapshot(_ detail: SynologyPhotoSimilarDetail) throws {
        let group = detail.group
        try requireCategoryAccess(.similar, in: group.space)
        guard group.profileID == profileID, group.id > 0, group.photoIDs.count >= 2,
              Set(group.photoIDs).count == group.photoIDs.count, group.photoIDs.contains(group.topPickID),
              detail.photos.count == group.photoIDs.count, Set(detail.photos.map { $0.id.unitID }) == Set(group.photoIDs),
              detail.photos.allSatisfy({ $0.id.profileID == profileID && $0.id.space == group.space && $0.albumContext == nil }) else { throw Self.failure(.conflict) }
    }

    /// 空或单成员组可以是拆组后的读取结果；绝不把失败响应当作空组。
    private func currentSimilarGroup(_ original: SynologyPhotoSimilarGroup) async throws -> SynologyPhotoSimilarGroup? {
        try requireCategoryAccess(.similar, in: original.space)
        let generation = accessGeneration
        let payload: SimilarGroupList = try await call(api("Browse.Similar", in: original.space), version: 1, method: "get", parameters: ["id": .integerArray([original.id])])
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard payload.list.count <= 1 else { throw Self.failure(.invalidResponse) }
        guard let value = payload.list.first else { return nil }
        guard value.id == original.id, value.count >= 0, value.count == value.item_id.count,
              Set(value.item_id).count == value.item_id.count, value.item_id.allSatisfy({ $0 > 0 }) else { throw Self.failure(.invalidResponse) }
        if value.count < 2 { return nil }
        return try similarGroup(value, in: original.space)
    }

    /// 同时读取原照片的归组信息，组消失本身不能证明移出或拆组已完成。
    private func similarMemberships(_ detail: SynologyPhotoSimilarDetail, restored: SynologyPhotosAlbumCheckpoint.Similar? = nil) async throws -> [SynologyPhoto] {
        try requireCategoryAccess(.similar, in: detail.group.space)
        let generation = accessGeneration
        let payload: ItemList = try await call(api("Browse.SimilarItem", in: detail.group.space), version: 1, method: "get",
            parameters: ["id": .integerArray(detail.group.photoIDs), "additional": .stringArray(["thumbnail", "resolution", "orientation"])])
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard payload.list.count == detail.photos.count, Set(payload.list.map { $0.id }) == Set(detail.group.photoIDs) else { throw Self.failure(.invalidResponse) }
        return try detail.photos.map { original in
            guard let item = payload.list.first(where: { $0.id == original.id.unitID }) else { throw Self.failure(.conflict) }
            var photo = SynologyPhoto(id: original.id, filename: item.filename, sizeBytes: item.filesize,
                takenAt: Date(timeIntervalSince1970: item.time), indexedAt: Date(timeIntervalSince1970: item.indexed_time),
                folderID: item.folder_id, mediaType: item.type,
                thumbnail: item.additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) },
                width: item.additional?.resolution?.width, height: item.additional?.resolution?.height, orientation: item.additional?.orientation)
            if let restored {
                guard let target = restored.targets.first(where: { $0.id == photo.id }), try target.matchesIdentity(photo) else { throw Self.failure(.conflict) }
            } else {
                guard item.filename == original.filename, item.filesize == original.sizeBytes, item.folder_id == original.folderID,
                      Date(timeIntervalSince1970: item.indexed_time) == original.indexedAt, item.type == original.mediaType else { throw Self.failure(.conflict) }
                photo = original
            }
            photo.similarGroup = try item.similar.flatMap { value in
                guard value.count < 2 else { return try similarGroup(value, in: detail.group.space) }
                guard value.count >= 0, value.count == value.item_id.count, value.item_id.allSatisfy({ $0 > 0 }) else { throw Self.failure(.invalidResponse) }
                return nil
            }
            if let group = photo.similarGroup, !group.photoIDs.contains(photo.id.unitID) { throw Self.failure(.invalidResponse) }
            return photo
        }
    }

    /// 剩余批次只能以当前原件重新构造写入快照，摘要占位数据不可直接提交。
    public func similarMutationTarget(_ checkpoint: SynologyPhotosAlbumCheckpoint) async throws -> SynologyPhotosMutation {
        let value = try requireSimilarCheckpoint(checkpoint)
        guard !value.submitted, !checkpoint.rejected else { throw Self.failure(.conflict) }
        if case .undo = value.edit { throw Self.failure(.conflict) }
        let generation = accessGeneration
        guard case .editSimilarGroup(let original, _) = try checkpoint.reviewMutation() else { throw Self.failure(.invalidResponse) }
        let photos = try await similarMemberships(original, restored: value)
        guard try await currentSimilarGroup(value.group) == value.group,
              generation == accessGeneration,
              photos.allSatisfy({ $0.similarGroup == value.group }) else { throw Self.failure(.conflict) }
        return .editSimilarGroup(.init(group: value.group, photos: photos), value.edit)
    }

    /// 恢复撤销资格只读取并验证已确认结果；不重放原拆组或移出请求。
    public func prepareSimilarUndo(_ checkpoint: SynologyPhotosAlbumCheckpoint) async throws -> SynologyPhotosMutation {
        let value = try requireSimilarCheckpoint(checkpoint)
        guard value.canUndo, !checkpoint.rejected, !mutationInFlight,
              case .editSimilarGroup(let original, _) = try checkpoint.reviewMutation() else { throw Self.failure(.conflict) }
        guard let result = try await inspectSimilarEdit(original, edit: value.edit, restored: value),
              result.similarGroup == value.resultingGroup,
              result.photos.allSatisfy({ $0.similarGroup == nil || $0.similarGroup?.id == value.group.id }) else { throw Self.failure(.conflict) }
        let photos = result.photos.map { value in var photo = value; photo.similarGroup = original.group; return photo }
        let detail = SynologyPhotoSimilarDetail(group: original.group, photos: photos)
        if let existing = mutations[checkpoint.operationID] {
            guard existing.result.state == .confirmed,
                  existing.restoredSimilar.map({ $0.group == value.group && $0.edit == value.edit && $0.targets == value.targets }) ?? value.hasSameIntent(as: existing.mutation) else { throw Self.failure(.conflict) }
        }
        var record = PhotosMutationRecord(mutation: .editSimilarGroup(detail, value.edit))
        record.result = result; record.usesAlbumRecovery = true; record.similarSubmitted = true
        mutations[checkpoint.operationID] = record
        return .editSimilarGroup(detail, .undo(checkpoint.operationID))
    }

    private func requireSimilarCheckpoint(_ checkpoint: SynologyPhotosAlbumCheckpoint) throws -> SynologyPhotosAlbumCheckpoint.Similar {
        _ = try checkpoint.reviewMutation()
        guard checkpoint.profileID == profileID, checkpoint.userID == currentUserID,
              let value = checkpoint.similarDetails else { throw Self.failure(.permissionDenied) }
        try requireCategoryAccess(.similar, in: value.group.space)
        return value
    }

    private func prepareSimilarEdit(_ detail: SynologyPhotoSimilarDetail, edit: SynologyPhotoSimilarEdit) async throws {
        try validateSimilarSnapshot(detail)
        let group = detail.group
        switch edit {
        case .topPick(let id): guard group.photoIDs.contains(id), group.topPickID != id else { throw Self.failure(.conflict) }
        case .remove(let ids): guard !ids.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: Set(group.photoIDs)) else { throw Self.failure(.conflict) }
        case .ungroup: break
        case .undo(let id):
            guard let previous = mutations[id], previous.result.state == .confirmed,
                  case .editSimilarGroup(let original, let priorEdit) = previous.mutation, original == detail else { throw Self.failure(.conflict) }
            switch priorEdit { case .ungroup, .remove: break; default: throw Self.failure(.conflict) }
            guard !mutations.values.contains(where: { if case .editSimilarGroup(_, .undo(let priorID)) = $0.mutation { return priorID == id }; return false }) else { throw Self.failure(.conflict) }
            guard let checked = try await inspectSimilarEdit(original, edit: priorEdit), checked.similarGroup == previous.result.similarGroup,
                  checked.photos.allSatisfy({ $0.similarGroup == nil || $0.similarGroup?.id == group.id }) else { throw Self.failure(.conflict) }
            return
        }
        guard try await currentSimilarGroup(group) == group else { throw Self.failure(.conflict) }
        let members = try await similarMemberships(detail)
        guard members.allSatisfy({ $0.similarGroup == group }) else { throw Self.failure(.conflict) }
    }

    private func inspectSimilarEdit(_ detail: SynologyPhotoSimilarDetail, edit: SynologyPhotoSimilarEdit,
        restored: SynologyPhotosAlbumCheckpoint.Similar? = nil) async throws -> SynologyPhotosMutationResult? {
        try validateSimilarSnapshot(detail)
        let generation = accessGeneration
        let current = try await currentSimilarGroup(detail.group)
        let members = try await similarMemberships(detail, restored: restored)
        let originalIDs = Set(detail.group.photoIDs)
        switch edit {
        case .topPick(let id):
            guard let current, Set(current.photoIDs) == originalIDs, current.topPickID == id,
                  members.allSatisfy({ $0.similarGroup == current }) else { return nil }
        case .ungroup:
            guard current == nil, members.allSatisfy({ $0.similarGroup?.id != detail.group.id }) else { return nil }
        case .remove(let removed):
            let remaining = originalIDs.subtracting(removed)
            if remaining.count >= 2 {
                guard let current, Set(current.photoIDs) == remaining,
                      members.filter({ remaining.contains($0.id.unitID) }).allSatisfy({ $0.similarGroup == current }) else { return nil }
            } else { guard current == nil else { return nil } }
            guard members.filter({ removed.contains($0.id.unitID) || remaining.count < 2 }).allSatisfy({ $0.similarGroup?.id != detail.group.id }) else { return nil }
        case .undo:
            guard let current, Set(current.photoIDs) == originalIDs, current.topPickID == detail.group.topPickID,
                  members.allSatisfy({ $0.similarGroup == current }) else { return nil }
        }
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        return .init(state: .confirmed, photos: members, completedCount: 1, similarGroup: current)
    }

    public func photoRequest(id: String) async throws -> SynologyPhotoRequest {
        guard let request = try await findPhotoRequest(id: id) else { throw Self.failure(.conflict) }
        return request
    }

    private func findPhotoRequest(id: String) async throws -> SynologyPhotoRequest? {
        guard !id.isEmpty else { throw Self.failure(.permissionDenied) }
        return try await findPhotoRequest { $0 == id }
    }

    private func findPhotoRequest(matching matches: (String) -> Bool) async throws -> SynologyPhotoRequest? {
        guard !allowedSpaces.isEmpty else { throw Self.failure(.permissionDenied) }
        let generation = accessGeneration
        var offset = 0, seen = Set<String>()
        while true {
            let page: PhotoRequestList = try await call("SYNO.Foto.PhotoRequest", version: 1, method: "list", parameters: ["offset": .integer(offset), "limit": .integer(500)])
            guard generation == accessGeneration, !allowedSpaces.isEmpty else { throw Self.failure(.permissionDenied) }
            guard page.list.count <= 500, page.list.allSatisfy({ !$0.passphrase.isEmpty && seen.insert($0.passphrase).inserted }) else { throw Self.failure(.invalidResponse) }
            if let item = page.list.first(where: { matches($0.passphrase) }) { return try decodePhotoRequest(item) }
            if page.list.count < 500 { return nil }
            offset += page.list.count
            try Task.checkCancellation()
        }
    }

    private func decodePhotoRequest(_ item: PhotoRequestList.Entry) throws -> SynologyPhotoRequest {
        guard let description = item.description, let path = item.folder_home_path, let valid = item.is_folder_valid,
              let expiration = item.expiration, expiration >= 0, let size = item.filesize_limit, size >= 0 else { throw Self.failure(.invalidResponse) }
        let space: SynologyPhotoSpace
        switch item.library {
        case "personal_space": space = .personal
        case "shared_space": space = .shared
        default: throw Self.failure(.invalidResponse)
        }
        let passphrase = item.album_passphrase.flatMap { $0.isEmpty ? nil : $0 }
        let settings = SynologyPhotoRequestSettings(subject: item.subject, description: description, space: space,
            folderPath: path, folderID: item.folder_id.flatMap { $0 > 0 ? $0 : nil },
            albumID: passphrase == nil ? item.album_id.flatMap { $0 > 0 ? $0 : nil } : nil,
            albumPassphrase: passphrase, expiration: expiration, sizeLimit: size)
        return .init(id: item.passphrase, profileID: profileID, settings: settings, albumName: item.album_name,
                     isFolderValid: valid, url: Self.safeSharingURL(item.sharing_link))
    }

    public func photoRequestAlbums() async throws -> [SynologyPhotoRequestAlbum] {
        guard !allowedSpaces.isEmpty, let userID = currentUserID else { throw Self.failure(.permissionDenied) }
        let generation = accessGeneration
        var result: [SynologyPhotoRequestAlbum] = [], offset = 0, seen = Set<Int>()
        while true {
            let page: ManagementAlbums = try await call("SYNO.Foto.Browse.NormalAlbum", version: 1, method: "list", parameters: [
                "category": .string("addable"), "offset": .integer(offset), "limit": .integer(500),
                "sort_by": .string("album_name"), "sort_direction": .string("asc"), "additional": .stringArray(["sharing_info", "thumbnail"])])
            guard generation == accessGeneration, !allowedSpaces.isEmpty else { throw Self.failure(.permissionDenied) }
            guard page.list.count <= 500 else { throw Self.failure(.invalidResponse) }
            for album in page.list {
                guard album.id > 0, seen.insert(album.id).inserted, let owner = album.owner_user_id, let shared = album.shared else { throw Self.failure(.invalidResponse) }
                if album.freeze_album == true { continue }
                if owner == userID { result.append(.init(albumID: album.id, name: album.name, shared: shared)) }
                else if let passphrase = album.additional?.sharing_info?.passphrase, !passphrase.isEmpty {
                    result.append(.init(passphrase: passphrase, name: album.name, shared: shared))
                } else { throw Self.failure(.invalidResponse) }
            }
            if page.list.count < 500 { return result }
            offset += page.list.count
            try Task.checkCancellation()
        }
    }

    private func validatePhotoRequestSnapshot(_ original: SynologyPhotoRequest) async throws {
        guard original.profileID == profileID else { throw Self.failure(.permissionDenied) }
        let current = try await photoRequest(id: original.id)
        guard current == original else { throw deletionError(.conflict, "photos.request.changed") }
    }

    private func validatePhotoRequestSettings(_ settings: SynologyPhotoRequestSettings) async throws {
        let subject = settings.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty, subject == settings.subject, subject.utf16.count <= 50, settings.description.utf16.count <= 100,
              settings.expiration >= 0, settings.sizeLimit == 0 || (1_048_576...3_145_728_000).contains(settings.sizeLimit),
              settings.albumID == nil || settings.albumID! > 0,
              settings.albumPassphrase == nil || settings.albumPassphrase?.isEmpty == false,
              settings.albumPassphrase == nil || settings.albumID == nil else { throw Self.failure(.invalidResponse) }
        try requireAccess(settings.space)
        if let id = settings.folderID {
            let folder: FolderPayload = try await call(api("Browse.Folder", in: settings.space), version: 2, method: "get", parameters: ["id": .integer(id), "additional": .stringArray(["access_permission"])])
            guard folder.folder.id == id, folder.folder.name == settings.folderPath,
                  canWriteFolder(folder.folder, in: settings.space, forUpload: true) else { throw Self.failure(.permissionDenied) }
        } else {
            guard settings.folderPath == SynologyPhotoRequestSettings.defaultFolderPath(subject: subject),
                  settings.space == .personal || managesSharedSpace else { throw Self.failure(.permissionDenied) }
            let root = try await rootFolder(in: settings.space)
            try await requireManagedFolder(root.id, in: settings.space, forUpload: true)
        }
        if settings.albumID != nil || settings.albumPassphrase != nil {
            let choices = try await photoRequestAlbums()
            guard choices.contains(where: { $0.albumID == settings.albumID && $0.passphrase == settings.albumPassphrase }) else { throw Self.failure(.permissionDenied) }
        }
    }

    private func photoRequestParameters(_ settings: SynologyPhotoRequestSettings) -> [String: DsmParameterValue] {
        var result: [String: DsmParameterValue] = ["subject": .string(settings.subject), "description": .string(settings.description),
            "library": .string(settings.space == .personal ? "personal_space" : "shared_space"), "folder_home_path": .string(settings.folderPath),
            "expiration": .integer(settings.expiration), "filesize_limit": .integer(Int(settings.sizeLimit))]
        if let passphrase = settings.albumPassphrase { result["album_passphrase"] = .string(passphrase) }
        else if let id = settings.albumID { result["album_id"] = .integer(id) }
        return result
    }

    private func inspectRestoredPhotoRequest(_ saved: SynologyPhotosAlbumCheckpoint.Request) async throws -> SynologyPhotosMutationResult {
        try requireAccess(saved.space)
        guard saved.targetDigest != nil else { return .init(state: .pendingReview) }
        let request = try await findPhotoRequest(matching: saved.matchesTarget)
        if saved.kind == .delete { return .init(state: request == nil ? .confirmed : .pendingReview) }
        guard let request, request.isFolderValid, try saved.matchesSettings(request.settings),
              saved.kind != .create || request.url != nil else { return .init(state: .pendingReview) }
        return .init(state: .confirmed, sharingURL: request.url, photoRequest: request)
    }

    private func photoRequestMatches(_ actual: SynologyPhotoRequestSettings, _ expected: SynologyPhotoRequestSettings) -> Bool {
        var value = actual
        // 新默认目录由NAS创建后才有编号；除此之外必须逐字段核对。
        if expected.folderID == nil { value.folderID = nil }
        return value == expected
    }

    private func shiftedTimestamp(_ photo: SynologyPhoto, seconds: Int) throws -> Int {
        let original = photo.takenAt.timeIntervalSince1970
        guard original.isFinite, original >= 0, original <= Double(Int.max / 2) else { throw Self.failure(.invalidResponse) }
        let (target, overflow) = Int(original).addingReportingOverflow(seconds)
        guard !overflow, target >= 0, target <= Int.max / 2 else { throw Self.failure(.invalidResponse) }
        return target
    }

    private func requireManagedFolder(_ id: Int, in space: SynologyPhotoSpace = .personal, forUpload: Bool = false) async throws {
        guard id > 0 else { throw Self.failure(.invalidResponse) }
        try requireAccess(space)
        let folder: FolderPayload = try await call(api("Browse.Folder", in: space), version: 2, method: "get", parameters: ["id": .integer(id), "additional": .stringArray(["access_permission"])])
        guard folder.folder.id == id, canWriteFolder(folder.folder, in: space, forUpload: forUpload) else { throw Self.failure(.permissionDenied) }
    }

    private func canWriteFolder(_ folder: FolderEntry, in space: SynologyPhotoSpace, forUpload: Bool) -> Bool {
        if space == .shared && managesSharedSpace { return true }
        guard let access = folder.additional?.access_permission, access.view else { return false }
        return access.manage == true || (forUpload && access.upload == true)
    }

    public func albumAccess(id: Int) async throws -> SynologyPhotoAlbumAccess {
        try requireAlbumAccess()
        let generation = accessGeneration
        let result = try await albumAccess(try await managedAlbum(id))
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        return result
    }

    private func albumAccess(_ album: ManagementAlbum) async throws -> SynologyPhotoAlbumAccess {
        guard let user = currentUserID, user > 0, let owner = album.owner_user_id, owner > 0 else { throw Self.failure(.permissionDenied) }
        if owner == user {
            return .init(albumID: album.id, currentUserID: user, isOwner: true, canDownload: true, canContribute: album.freeze_album != true && album.type != "condition")
        }
        guard let passphrase = album.passphrase ?? album.additional?.sharing_info?.passphrase, !passphrase.isEmpty else { throw Self.failure(.permissionDenied) }
        let result: AlbumPermissionPayload = try await call("SYNO.Foto.Sharing.Passphrase", version: 1, method: "get_permission", parameters: [
            "passphrase": .string(passphrase), "exclude_public": .boolean(false)])
        return .init(albumID: album.id, currentUserID: user, isOwner: false,
            canDownload: result.permission.download == true, canContribute: album.freeze_album != true && album.type != "condition" && result.permission.upload == true)
    }

    private func albumWriteTarget(_ album: ManagementAlbum, rights: SynologyPhotoAlbumAccess) throws -> [String: DsmParameterValue] {
        guard rights.canContribute else { throw Self.failure(.permissionDenied) }
        if rights.isOwner { return ["id": .integer(album.id)] }
        guard let passphrase = album.passphrase ?? album.additional?.sharing_info?.passphrase, !passphrase.isEmpty else { throw Self.failure(.permissionDenied) }
        return ["passphrase": .string(passphrase)]
    }

    public func addableAlbums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        try requireAlbumAccess()
        guard offset >= 0, (1...500).contains(limit) else { throw Self.failure(.invalidResponse) }
        let generation = accessGeneration
        let result: ManagementAlbums = try await call("SYNO.Foto.Browse.NormalAlbum", version: 1, method: "list", parameters: [
            "category": .string("addable"), "offset": .integer(offset), "limit": .integer(limit),
            "sort_by": .string("album_name"), "sort_direction": .string("asc"), "additional": .stringArray(["sharing_info", "thumbnail"])])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard result.list.count <= limit, result.list.allSatisfy({ $0.id > 0 && $0.type != "condition" }),
              Set(result.list.map(\.id)).count == result.list.count else { throw Self.failure(.invalidResponse) }
        return result.list.filter { $0.freeze_album != true }.map(\.collection)
    }

    private func managedAlbum(_ id: Int) async throws -> ManagementAlbum {
        guard id > 0 else { throw Self.failure(.invalidResponse) }
        let payload: ManagementAlbums = try await call("SYNO.Foto.Browse.Album", version: 4, method: "get", parameters: ["id": .integerArray([id]), "additional": .stringArray(["sharing_info", "thumbnail"])])
        guard payload.list.count == 1, let album = payload.list.first, album.id == id else { throw Self.failure(.invalidResponse) }
        return album
    }

    public func uploadRecoveryIdentity() async throws -> String {
        try requireAlbumAccess()
        guard let user = currentUserID, user > 0 else { throw Self.failure(.permissionDenied) }
        return "\(profileID.uuidString):\(user)"
    }

    public func performRecoverableUpload(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress,
                                         checkpoint: @escaping @Sendable (SynologyPhotosUploadCheckpoint) throws -> Void) async throws -> SynologyPhotosMutationResult {
        guard let user = currentUserID, user > 0, uploadCheckpointWriters[operationID] == nil else { throw Self.failure(.conflict) }
        _ = try SynologyPhotosUploadCheckpoint(mutation: mutation, operationID: operationID, profileID: profileID, userID: user)
        uploadCheckpointWriters[operationID] = checkpoint
        defer { uploadCheckpointWriters.removeValue(forKey: operationID) }
        return try await performMutation(mutation, operationID: operationID, progress: progress)
    }

    public func restoreUploadMutation(_ checkpoint: SynologyPhotosUploadCheckpoint) async throws {
        try requireAlbumAccess()
        guard checkpoint.profileID == profileID, checkpoint.userID == currentUserID, !mutationInFlight else { throw Self.failure(.permissionDenied) }
        if mutations[checkpoint.operationID] != nil { return }
        var record = PhotosMutationRecord(mutation: try checkpoint.reviewMutation())
        record.itemID = checkpoint.itemID; record.folderID = checkpoint.folderID
        record.uploadAction = checkpoint.uploadAction; record.albumMembershipHasFailures = checkpoint.membershipHasFailures
        if checkpoint.rejected { record.result = .init(state: .rejected) }
        mutations[checkpoint.operationID] = record
    }

    public func forgetUploadMutation(operationID: UUID) async throws {
        guard !mutationInFlight, let record = mutations[operationID], let user = currentUserID else { throw Self.failure(.conflict) }
        _ = try SynologyPhotosUploadCheckpoint(mutation: record.mutation, operationID: operationID, profileID: profileID, userID: user)
        mutations.removeValue(forKey: operationID)
    }

    public func performRecoverableAlbumMutation(_ mutation: SynologyPhotosMutation, operationID: UUID,
                                                checkpoint: @escaping @Sendable (SynologyPhotosAlbumCheckpoint) throws -> Void) async throws -> SynologyPhotosMutationResult {
        guard let user = currentUserID, user > 0, albumCheckpointWriters[operationID] == nil else { throw Self.failure(.conflict) }
        _ = try SynologyPhotosAlbumCheckpoint(mutation: mutation, operationID: operationID, profileID: profileID, userID: user)
        albumCheckpointWriters[operationID] = checkpoint
        defer { albumCheckpointWriters.removeValue(forKey: operationID) }
        return try await performMutation(mutation, operationID: operationID) { _, _ in }
    }

    public func restoreAlbumMutation(_ checkpoint: SynologyPhotosAlbumCheckpoint) async throws {
        if let similar = checkpoint.similarDetails { try requireCategoryAccess(.similar, in: similar.group.space) }
        else if let recognition = checkpoint.recognitionDetails { try requireAccess(recognition.space) }
        else if let maintenance = checkpoint.previewMaintenanceDetails {
            switch maintenance {
            case .automatic(let value): try requireAccess(value.task.space)
            case .library(let original, _, _): try requireAccess(original.space)
            default: try requireAlbumAccess()
            }
        } else if let preview = checkpoint.previewRegenerationDetails {
            for space in Set(preview.targets.map { $0.id.space }) { try requireAccess(space) }
        } else if case .rotation(let value) = checkpoint.preferenceDetails { try requireAccess(value.photo.id.space) }
        else if checkpoint.folderSharingDetails != nil { try requireAccess(.shared) }
        else if checkpoint.backgroundDetails != nil { try requireAlbumAccess() }
        else if checkpoint.folderDetails != nil {
            let command = try checkpoint.reviewMutation()
            try requireAccess(command.space); try requireAccess(command.destinationSpace)
        } else if let edit = checkpoint.photoEditDetails {
            try requireAccess(edit.space)
            for space in Set(edit.targets.map(\.space)) { try requireAccess(space) }
        } else if let frozen = checkpoint.frozenDetails {
            try requireAlbumAccess()
            if let condition = frozen.rebuiltCondition { try requireAccess(condition.space) }
        } else if let condition = checkpoint.conditionDetails { try requireAccess(condition.space) }
        else if let request = checkpoint.requestDetails { try requireAccess(request.space) }
        else { try requireAlbumAccess() }
        guard checkpoint.profileID == profileID, checkpoint.userID == currentUserID, !mutationInFlight else { throw Self.failure(.permissionDenied) }
        let mutation = try checkpoint.reviewMutation()
        if let existing = mutations[checkpoint.operationID] {
            let matches = if let similar = checkpoint.similarDetails {
                existing.restoredSimilar.map { $0 == similar } ?? similar.hasSameIntent(as: existing.mutation)
            } else if let recognition = checkpoint.recognitionDetails {
                existing.restoredRecognition.map { $0 == recognition } ?? recognition.hasSameIntent(as: existing.mutation)
            } else if let administration = checkpoint.administrationDetails {
                administration.hasSameIntent(as: existing.mutation)
            } else if let maintenance = checkpoint.previewMaintenanceDetails {
                maintenance.hasSameIntent(as: existing.mutation, profileID: profileID, userID: checkpoint.userID)
            } else if let preview = checkpoint.previewRegenerationDetails {
                preview.hasSameIntent(as: existing.mutation)
            } else if let preference = checkpoint.preferenceDetails {
                preference.hasSameIntent(as: existing.mutation)
            } else if let sharing = checkpoint.folderSharingDetails {
                existing.restoredFolderSharing.map { $0 == sharing } ?? sharing.hasSameIntent(as: existing.mutation)
            } else if let background = checkpoint.backgroundDetails {
                background.hasSameIntent(as: existing.mutation, profileID: profileID, userID: checkpoint.userID)
            } else if let folder = checkpoint.folderDetails {
                folder.hasSameIntent(as: existing.mutation, profileID: profileID)
            } else if let edit = checkpoint.photoEditDetails {
                existing.restoredPhotoEdit.map { $0 == edit } ?? edit.hasSameIntent(as: existing.mutation)
            } else if let frozen = checkpoint.frozenDetails {
                existing.restoredFrozen.map { $0 == frozen } ?? frozen.hasSameIntent(as: existing.mutation, profileID: profileID, userID: checkpoint.userID)
            } else if let sharing = checkpoint.sharingDetails {
                existing.restoredAlbumSharing.map { $0 == sharing } ?? sharing.hasSameIntent(as: existing.mutation)
            } else if let condition = checkpoint.conditionDetails {
                existing.restoredCondition.map { $0 == condition } ?? condition.hasSameIntent(as: existing.mutation, userID: checkpoint.userID)
            } else if let request = checkpoint.requestDetails {
                existing.restoredPhotoRequest.map { $0 == request } ?? request.hasSameIntent(as: existing.mutation)
            } else {
                switch (existing.mutation, mutation) {
                case (.copyTemporaryAlbum(let id, let name, let original), .copyTemporaryAlbum(let otherID, let otherName, let other)):
                    id == otherID && name == otherName && original.revision == other.revision
                case (.deleteTemporaryAlbum(let id, let original, let copy), .deleteTemporaryAlbum(let otherID, let other, let otherCopy)):
                    id == otherID && original.revision == other.revision && copy == otherCopy
                default: existing.mutation == mutation
                }
            }
            guard matches else { throw Self.failure(.conflict) }
            return
        }
        var record = PhotosMutationRecord(mutation: mutation)
        record.albumID = checkpoint.createdAlbumID
        record.albumMembershipHasFailures = checkpoint.membershipHasFailures
        record.restoredAlbumSharing = checkpoint.sharingDetails
        record.restoredFolderSharing = checkpoint.folderSharingDetails
        record.folderSharingAcknowledged = checkpoint.folderSharingDetails?.acknowledged ?? false
        record.backgroundAttempted = checkpoint.backgroundDetails?.attempted ?? []
        record.backgroundRejected = checkpoint.backgroundDetails?.rejected ?? []
        record.restoredPhotoRequest = checkpoint.requestDetails
        record.restoredFrozen = checkpoint.frozenDetails
        record.usesAlbumRecovery = true
        if let similar = checkpoint.similarDetails {
            record.restoredSimilar = similar; record.similarSubmitted = similar.submitted
            if !similar.submitted { record.result = .init(state: .rejected) }
        }
        if let recognition = checkpoint.recognitionDetails {
            record.restoredRecognition = recognition
            record.personPhotoIDs = recognition.personPhotoIDs
            if let id = recognition.personReceiptID, let name = recognition.personReceiptNameDigest { record.personReceipt = .init(id: id, name: name) }
            if case .personCover(let person) = recognition.intent, let cover = recognition.personCoverID { record.personCoverReceipt = .init(id: person.id, cover: cover) }
            record.visibilityAcknowledged = recognition.visibilityAcknowledged; record.conceptRemovalAcknowledged = recognition.conceptRemovalAcknowledged
            record.manualAddAttempted = recognition.manualAddAttempted; record.manualAddAcknowledged = recognition.manualAddAcknowledged
            record.manualAttempted = recognition.manualAttempted; record.manualThumbnailAttempted = recognition.manualThumbnailAttempted
            record.manualNewIDs = recognition.manualNewIDs; record.manualUploaded = recognition.manualUploaded
            record.manualAcknowledged = recognition.manualAcknowledged; record.manualKnownFailures = recognition.manualKnownFailures
        }
        if let administration = checkpoint.administrationDetails {
            record.memberAttempted = administration.memberAttempted
            record.memberAcknowledged = administration.memberAcknowledged
            record.memberRejected = administration.memberRejected
            record.globalAttempted = administration.globalAttempted
            record.globalAcknowledged = administration.globalAcknowledged
            record.globalRejected = administration.globalRejected
            if case .cache = administration.intent, administration.globalAttempted.isEmpty { record.result = .init(state: .rejected) }
        }
        if let maintenance = checkpoint.previewMaintenanceDetails {
            switch maintenance {
            case .setting: break
            case .codec(let original, _, let acknowledged, let rejected):
                record.codecGenerationAcknowledged = acknowledged; record.codecPromptRejected = rejected
                if acknowledged { codecGenerationAcknowledgedUsers.insert(original.userID) }
            case .library(_, _, let acknowledged): record.libraryMaintenanceAcknowledged = acknowledged
            case .automatic(let value):
                record.automaticPreviewSubmitted = value.submitted; record.automaticPreviewAcknowledged = value.acknowledged
                record.automaticFailureKind = value.failureKind; record.automaticFailureAcknowledged = value.failureAcknowledged
                record.automaticThumbnailDigests = value.thumbnailDigests
                if let encoded = value.videoSignature {
                    let signature = try JSONDecoder().decode(PhotosPreviewVideoSignature.self, from: encoded)
                    try signature.validate(); record.automaticVideoSignature = signature
                }
            }
        }
        if let preview = checkpoint.previewRegenerationDetails {
            for target in preview.targets {
                let id = target.id
                record.regenerationBaseline[id] = target.baseline
                if target.marking { record.regenerationMarking.insert(id) }
                if target.marked { record.regenerationMarked.insert(id) }
                if target.submitted { record.regenerationSubmitted.insert(id) }
                if target.restoring { record.regenerationRestoring.insert(id) }
                if target.generated { record.regenerated.insert(id) }
                if target.recovered { record.regenerationRecovered.insert(id) }
                if target.failed { record.regenerationFailed.insert(id) }
            }
        }
        record.frozenDeletionAttempted = checkpoint.frozenDetails?.deletionAttempted ?? false
        record.frozenDeletionRejected = checkpoint.frozenDetails?.deletionRejected ?? false
        record.restoredCondition = checkpoint.conditionDetails
        record.restoredPhotoEdit = checkpoint.photoEditDetails
        if let folder = checkpoint.folderDetails {
            record.taskID = folder.taskID; record.folderID = folder.createdFolderID
            record.transferTargetVerified = folder.transferTargetVerified; record.transferTotal = folder.transferTotal
            record.folderCoverAcknowledged = folder.coverAcknowledged
        }
        record.passwordUpdateAcknowledged = checkpoint.sharingDetails?.passwordAcknowledged ?? false
        record.enableSharingAttempted = checkpoint.sharingDetails?.enableAttempted ?? false
        record.temporaryAlbumMembers = checkpoint.temporaryMembers.map { values in
            Dictionary(uniqueKeysWithValues: values.map { ($0.id, PhotosAlbumMemberSnapshot(filename: $0.filename, size: $0.size, folderID: $0.folderID, indexedAt: $0.indexedAt)) })
        }
        if checkpoint.rejected { record.result = .init(state: .rejected) }
        mutations[checkpoint.operationID] = record
    }

    private func persistRecoveryCheckpoint(_ record: PhotosMutationRecord, operationID: UUID) throws {
        if let writer = albumCheckpointWriters[operationID] {
            guard let user = currentUserID else { throw Self.failure(.permissionDenied) }
            var checkpoint = try SynologyPhotosAlbumCheckpoint(mutation: record.mutation, operationID: operationID, profileID: profileID, userID: user)
            checkpoint.createdAlbumID = record.albumID
            checkpoint.membershipHasFailures = record.albumMembershipHasFailures
            checkpoint.rejected = record.result.state == .rejected
            if var similar = checkpoint.similarDetails {
                similar.submitted = record.similarSubmitted
                similar.confirmed = record.result.state == .confirmed
                similar.resultingGroup = similar.confirmed ? record.result.similarGroup : nil
                checkpoint.similarDetails = similar
            }
            if var recognition = checkpoint.recognitionDetails {
                recognition.personPhotoIDs = record.personPhotoIDs
                recognition.personReceiptID = record.personReceipt?.id
                recognition.personReceiptNameDigest = record.personReceipt.map { SynologyPhotosAlbumCheckpoint.Recognition.digest($0.name) }
                recognition.personCoverID = record.personCoverReceipt?.cover
                recognition.visibilityAcknowledged = record.visibilityAcknowledged; recognition.conceptRemovalAcknowledged = record.conceptRemovalAcknowledged
                recognition.manualAddAttempted = record.manualAddAttempted; recognition.manualAddAcknowledged = record.manualAddAcknowledged
                recognition.manualAttempted = record.manualAttempted; recognition.manualThumbnailAttempted = record.manualThumbnailAttempted
                recognition.manualNewIDs = record.manualNewIDs; recognition.manualPersonIDs = record.manualPersonReceipts.mapValues(\.id)
                recognition.manualUploaded = record.manualUploaded; recognition.manualAcknowledged = record.manualAcknowledged; recognition.manualKnownFailures = record.manualKnownFailures
                checkpoint.recognitionDetails = recognition
            }
            if var administration = checkpoint.administrationDetails {
                administration.memberAttempted = record.memberAttempted
                administration.memberAcknowledged = record.memberAcknowledged
                administration.memberRejected = record.memberRejected
                administration.globalAttempted = record.globalAttempted
                administration.globalAcknowledged = record.globalAcknowledged
                administration.globalRejected = record.globalRejected
                checkpoint.administrationDetails = administration
            }
            if let maintenance = checkpoint.previewMaintenanceDetails {
                switch maintenance {
                case .setting: break
                case .codec(let original, let generate, _, _):
                    checkpoint.previewMaintenanceDetails = .codec(original, generate: generate,
                        acknowledged: record.codecGenerationAcknowledged, promptRejected: record.codecPromptRejected)
                case .library(let original, let action, _):
                    checkpoint.previewMaintenanceDetails = .library(original, action, acknowledged: record.libraryMaintenanceAcknowledged)
                case .automatic(var value):
                    value.submitted = record.automaticPreviewSubmitted; value.acknowledged = record.automaticPreviewAcknowledged
                    value.failureKind = record.automaticFailureKind; value.failureAcknowledged = record.automaticFailureAcknowledged
                    value.thumbnailDigests = record.automaticThumbnailDigests
                    value.videoSignature = try record.automaticVideoSignature.map { try JSONEncoder().encode($0) }
                    checkpoint.previewMaintenanceDetails = .automatic(value)
                }
            }
            if var preview = checkpoint.previewRegenerationDetails {
                for index in preview.targets.indices {
                    let id = preview.targets[index].id
                    preview.targets[index].baselineUnitID = record.regenerationBaseline[id]?.unitID
                    preview.targets[index].baselineRevision = record.regenerationBaseline[id]?.revision
                    preview.targets[index].marking = record.regenerationMarking.contains(id)
                    preview.targets[index].marked = record.regenerationMarked.contains(id)
                    preview.targets[index].submitted = record.regenerationSubmitted.contains(id)
                    preview.targets[index].restoring = record.regenerationRestoring.contains(id)
                    preview.targets[index].generated = record.regenerated.contains(id)
                    preview.targets[index].recovered = record.regenerationRecovered.contains(id)
                    preview.targets[index].failed = record.regenerationFailed.contains(id)
                }
                checkpoint.previewRegenerationDetails = preview
            }
            if var sharing = checkpoint.folderSharingDetails {
                sharing.acknowledged = record.folderSharingAcknowledged
                checkpoint.folderSharingDetails = sharing
            }
            if var background = checkpoint.backgroundDetails {
                background.attempted = record.backgroundAttempted; background.rejected = record.backgroundRejected
                checkpoint.backgroundDetails = background
            }
            if var folder = checkpoint.folderDetails {
                folder.taskID = record.taskID; folder.createdFolderID = record.folderID
                folder.transferTargetVerified = record.transferTargetVerified; folder.transferTotal = record.transferTotal
                folder.coverAcknowledged = record.folderCoverAcknowledged
                checkpoint.folderDetails = folder
            }
            if var edit = checkpoint.photoEditDetails {
                edit.createdTagID = record.createdTag?.id
                let submitted = record.metadataSubmittedIDs.union(record.shiftedSubmittedIDs)
                edit.attempted = Set(edit.targets.indices.filter { submitted.contains(edit.targets[$0].id) })
                let rejected = record.metadataRejectedIDs.union(record.shiftedRejectedID.map { [$0] } ?? [])
                edit.rejected = Set(edit.targets.indices.filter { rejected.contains(edit.targets[$0].id) })
                edit.reportedFailures = Set(edit.targets.indices.filter { record.metadataFailureReportedIDs.contains(edit.targets[$0].id) })
                edit.tagAdditionAttempted = record.tagAdditionAttempted
                edit.tagAdditionRejected = record.tagAdditionRejected
                checkpoint.photoEditDetails = edit
            }
            checkpoint.temporaryMembers = record.temporaryAlbumMembers?.map { id, value in
                .init(id: id, filename: value.filename, size: value.size, folderID: value.folderID, indexedAt: value.indexedAt)
            }
            if var frozen = checkpoint.frozenDetails {
                frozen.deletionAttempted = record.frozenDeletionAttempted
                frozen.deletionRejected = record.frozenDeletionRejected
                checkpoint.frozenDetails = frozen
            }
            if var sharing = checkpoint.sharingDetails {
                sharing.previousMembers = sharingMembers(record.sharingBefore?.permission)?.map(SynologyPhotosAlbumCheckpoint.Sharing.Member.init)
                sharing.previousExpiration = .init(record.sharingBefore?.expiration)
                sharing.previousHasPassword = record.sharingBefore?.enable_password
                sharing.passwordAcknowledged = record.passwordUpdateAcknowledged
                sharing.enableAttempted = record.enableSharingAttempted
                checkpoint.sharingDetails = sharing
            }
            if var request = checkpoint.requestDetails, request.kind == .create, let id = record.photoRequestID {
                try request.recordCreatedID(id)
                checkpoint.requestDetails = request
            }
            try writer(checkpoint)
        }
        guard let writer = uploadCheckpointWriters[operationID] else { return }
        guard let user = currentUserID else { throw Self.failure(.permissionDenied) }
        var checkpoint = try SynologyPhotosUploadCheckpoint(mutation: record.mutation, operationID: operationID, profileID: profileID, userID: user)
        checkpoint.itemID = record.itemID; checkpoint.folderID = record.folderID
        checkpoint.uploadAction = record.uploadAction; checkpoint.membershipHasFailures = record.albumMembershipHasFailures
        checkpoint.rejected = record.result.state == .rejected
        try writer(checkpoint)
    }

    public func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        if let existing = mutations[operationID] {
            guard existing.mutation == mutation else { throw Self.failure(.conflict) }
            return try await reviewMutation(operationID: operationID)
        }
        guard !mutationInFlight, !mutations.values.contains(where: {
            $0.result.state == .pendingReview && (mutation.feature != .backgroundTasks || $0.mutation.feature == .backgroundTasks)
        }), pendingDeletions.isEmpty, deletionLocks.isEmpty else {
            throw deletionError(.conflict, "photos.manage.pending")
        }
        mutationInFlight = true
        defer { mutationInFlight = false }
        let operationGeneration = accessGeneration
        let preparedTarget = try await prepareMutationTarget(mutation)
        let albumTarget = preparedTarget.albumTarget
        var sharingAlbum: ManagementAlbum?
        var sharingSnapshot: SynologyPhotoSharingState?
        if case .shareAlbum(let id, _, let original, let members, _, _) = mutation {
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
        record.usesAlbumRecovery = albumCheckpointWriters[operationID] != nil
        record.sharingBefore = sharingAlbum?.additional?.sharing_info
        record.regenerationBaseline = preparedTarget.previewBaselines
        if case .copyTemporaryAlbum(let id, _, let original) = mutation {
            record.temporaryAlbumMembers = try await albumMemberSnapshot(id)
            let current = try await managedAlbum(id)
            guard current.temporary_shared == true, current.owner_user_id == currentUserID,
                  try sharingState(current).revision == original.revision else { throw Self.failure(.conflict) }
            try Task.checkCancellation()
            guard operationGeneration == accessGeneration else { throw Self.failure(.permissionDenied) }
        }
        if case .mergePeople(let target, let sources, _) = mutation {
            let generation = accessGeneration
            var photoIDs: Set<Int> = [], checkedFolders: Set<Int> = []
            for person in [target] + sources {
                let photos = try await personPhotos(person.id, in: mutation.space)
                if let count = person.itemCount, count != photos.count { throw Self.failure(.conflict) }
                for photo in photos {
                    if checkedFolders.insert(photo.folderID).inserted { try await requireManagedFolder(photo.folderID, in: mutation.space) }
                    photoIDs.insert(photo.id.unitID)
                }
            }
            try await validatePeople([target] + sources, in: mutation.space)
            record.personPhotoIDs = photoIDs
            try Task.checkCancellation()
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            try requireCategoryAccess(.person, in: mutation.space)
        }
        // 已配置恢复适配器时，写入前必须保存意图；失败时尚未向 NAS 发送请求。
        try persistRecoveryCheckpoint(record, operationID: operationID)
        // 先保留提交记录。提交后的取消、解码失败或断网都不能证明没有执行。
        mutations[operationID] = record
        do {
            let ids = mutation.photos.map(\.id.unitID)
            switch mutation {
            case .cancelBackgroundTask(let original):
                try await managementWrite("SYNO.Foto.BackgroundTask.Info", method: "abort_task", parameters: ["id": .integerArray([original.id])])
            case .clearBackgroundTasks(let originals):
                // 全部清理使用冻结快照逐项提交，不让随后完成的新任务进入清理范围。
                for original in originals {
                    try Task.checkCancellation()
                    guard operationGeneration == accessGeneration else { throw Self.failure(.permissionDenied) }
                    record.backgroundAttempted.insert(original.id); record.backgroundCurrent = original.id
                    do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                    catch { record.backgroundAttempted.remove(original.id); record.backgroundCurrent = nil; throw error }
                    mutations[operationID] = record
                    try await managementWrite("SYNO.Foto.BackgroundTask.Info", method: "clear_completed_task", parameters: ["id": .integer(original.id)])
                    record.backgroundCurrent = nil
                }
            case .respondToCodecPrompt(let original, let generate):
                try Task.checkCancellation()
                guard operationGeneration == accessGeneration else { throw Self.failure(.permissionDenied) }
                if generate {
                    try await managementWrite("SYNO.Foto.Index", method: original.isAdministrator ? "reindex_all_user" : "reindex", parameters: ["type": .string("thumbnail")])
                    record.codecGenerationAcknowledged = true
                    codecGenerationAcknowledgedUsers.insert(original.userID)
                    do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                    catch { record.codecPromptRejected = true; throw error }
                }
                try Task.checkCancellation()
                guard operationGeneration == accessGeneration else { throw Self.failure(.permissionDenied) }
                try await managementWrite("SYNO.Foto.Setting.Wizard", method: "set", parameters: ["prompt": .objectArray([["name": .string("new_codec_installed"), "show": .boolean(false)]])])
            case .maintainLibrary(let original, let action):
                try await managementWrite(api("Index", in: original.space), method: "reindex", parameters: ["type": .string(action.rawValue)])
                record.libraryMaintenanceAcknowledged = true
            case .setSharedMembers(let original, let members, let edits):
                let generation = accessGeneration
                for (index, step) in try sharedMemberSteps(original: original, members: members, edits: edits).enumerated() {
                    try Task.checkCancellation()
                    guard generation == accessGeneration, isPhotosAdministrator else { throw Self.failure(.permissionDenied) }
                    record.memberCurrent = index; record.memberAttempted.insert(index)
                    do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                    catch { record.memberAttempted.remove(index); record.memberCurrent = nil; throw error }
                    mutations[operationID] = record
                    try await managementWrite(step.api, method: step.method, parameters: step.parameters)
                    record.memberAcknowledged.insert(index); record.memberCurrent = nil
                    try persistRecoveryCheckpoint(record, operationID: operationID)
                }
            case .setAutomaticPreview(_, let enabled):
                try await managementWrite("SYNO.Foto.Setting.User", method: "set", parameters: ["auto_generate_thumbnail": .boolean(enabled)])
            case .generateAutomaticPreview(let task, let support):
                try await performAutomaticPreview(task, support: support, operationID: operationID, record: &record, progress: progress)
            case .setGlobalSettings(let original, let enabled, let extensions):
                let target = original.applying(enabled: enabled, excludedExtensions: extensions), generation = accessGeneration
                for (step, name, version, method, parameters) in globalSteps(original, target) {
                    try Task.checkCancellation()
                    guard generation == accessGeneration, isPhotosAdministrator else { throw Self.failure(.permissionDenied) }
                    record.globalCurrent = step; record.globalAttempted.insert(step)
                    do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                    catch { record.globalAttempted.remove(step); record.globalCurrent = nil; throw error }
                    mutations[operationID] = record
                    try await managementWrite(name, version: version, method: method, parameters: parameters)
                    record.globalAcknowledged.insert(step); record.globalCurrent = nil
                    try persistRecoveryCheckpoint(record, operationID: operationID)
                }
            case .clearConversionCache:
                record.globalCurrent = .cache; record.globalAttempted.insert(.cache)
                do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                catch { record.globalAttempted.remove(.cache); record.globalCurrent = nil; throw error }
                mutations[operationID] = record
                try await managementWrite("SYNO.Foto.Download", version: 2, method: "clear_cache", parameters: [:])
                record.globalAcknowledged.insert(.cache); record.globalCurrent = nil
            case .setSharedSpaceEnabled(_, let enabled):
                try await managementWrite("SYNO.Foto.Setting.TeamSpace", method: "set_enable", parameters: ["enabled": .boolean(enabled)])
            case .setSharedSpaceSettings(let original, let enabled):
                var parameters: [String: DsmParameterValue] = [:]
                for kind in original.enabled.symmetricDifference(enabled) { parameters[kind.rawValue] = .boolean(enabled.contains(kind)) }
                try await managementWrite("SYNO.Foto.Setting.TeamSpace", method: "set", parameters: parameters)
            case .setRecognitionSettings(let original, let enabled):
                var parameters: [String: DsmParameterValue] = [:]
                for kind in original.enabled.symmetricDifference(enabled) { parameters[kind.rawValue] = .boolean(enabled.contains(kind)) }
                try await managementWrite("SYNO.Foto.Setting.User", method: "set", parameters: parameters)
            case .setDisplaySettings(let original, let updated):
                var parameters: [String: DsmParameterValue] = [:]
                if original.grouping != updated.grouping { parameters["timeline_group_unit"] = .string(updated.grouping.rawValue) }
                if original.dateFormat != updated.dateFormat { parameters["date_format"] = .string(updated.dateFormat.rawValue) }
                if original.clock != updated.clock { parameters["time_format"] = .string(updated.clock.rawValue) }
                if original.defaultSort.field != updated.defaultSort.field { parameters["item_sort_by"] = .string(updated.defaultSort.field.rawValue) }
                if original.defaultSort.direction != updated.defaultSort.direction { parameters["sort_direction"] = .string(updated.defaultSort.direction.rawValue) }
                if original.showsPreviewInfo != updated.showsPreviewInfo { parameters["show_item_info_in_lightbox"] = .boolean(updated.showsPreviewInfo) }
                try await managementWrite("SYNO.Foto.Setting.User", method: "set", parameters: parameters)
            case .setDuplicateSettings(let original, let updated):
                var parameters: [String: DsmParameterValue] = [:]
                if original.upload != updated.upload { parameters["upload_default_action"] = .string(updated.upload.rawValue) }
                if original.transfer != updated.transfer { parameters["copy_move_default_action"] = .string(updated.transfer.rawValue) }
                try await managementWrite("SYNO.Foto.Setting.User", method: "set", parameters: parameters)
            case .setFolderSharing(let original, let access, let members, let password, let apply):
                var parameters: [String: DsmParameterValue] = ["folder_id": .integer(original.folder.id),
                    "privacy_type": .string(access.rawValue), "set_to_subfolder": .boolean(apply)]
                let changes = try folderSharingMemberChanges(from: original.members, to: members)
                if !changes.isEmpty { parameters["permission"] = .objectArray(changes) }
                // 与既有相册分享相同，只使用连接层已验证的HTTPS，不降级明文连接。
                if let password { parameters["password"] = .string(password) }
                try await managementWrite("SYNO.FotoTeam.Sharing.FolderPermission", method: "update", parameters: parameters)
                record.folderSharingAcknowledged = true
                record.passwordUpdateAcknowledged = password != nil
                try persistRecoveryCheckpoint(record, operationID: operationID)
                if apply != original.appliesToSubfolders {
                    try Task.checkCancellation()
                    try requireAccess(.shared)
                    guard managesSharedSpace else { throw Self.failure(.permissionDenied) }
                    try await managementWrite("SYNO.FotoTeam.Sharing.FolderPermission", method: "set_config", parameters: ["set_to_subfolder": .boolean(apply)])
                }
            case .editSimilarGroup(let detail, let edit):
                try requireCategoryAccess(.similar, in: detail.group.space)
                try Task.checkCancellation()
                guard operationGeneration == accessGeneration else { throw Self.failure(.permissionDenied) }
                record.similarSubmitted = true
                do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                catch { record.similarSubmitted = false; record.result = .init(state: .rejected); throw error }
                mutations[operationID] = record
                let group = detail.group
                let method: String
                var parameters: [String: DsmParameterValue] = ["id": .integer(group.id)]
                switch edit {
                case .topPick(let id): method = "set_top_pick"; parameters["item_id"] = .integer(id)
                case .ungroup: method = "ungroup"; parameters["id"] = .integerArray([group.id])
                case .remove(let ids): method = "remove_item"; parameters["item_id"] = .integerArray(ids)
                case .undo: method = "add_item"; parameters["item_id"] = .integerArray(group.photoIDs); parameters["top_pick"] = .integer(group.topPickID)
                }
                try await managementWrite(api("Browse.Similar", in: group.space), method: method, parameters: parameters)
            case .regeneratePreviews(let photos, let resuming):
                let generation = accessGeneration
                for (index, photo) in photos.enumerated() {
                    record.regenerationAttempted.insert(photo.id)
                    let localFirst = (photo.filename as NSString).pathExtension.lowercased() == "png"
                    var marked = false
                    var prepared: PhotosConvertedPreview?
                    if localFirst {
                        do { prepared = try await prepareLocalPreview(photo, generation: generation) }
                        catch { record.regenerationFailed.formUnion(photos[index...].map(\.id)); break }
                    }
                    if let converted = prepared {
                        try await preparePreviewRegeneration(photo, resuming: resuming, generation: generation, record: &record, operationID: operationID)
                        marked = true
                        try recordPreviewSubmission(photo, record: &record, operationID: operationID)
                        if try await uploadConvertedPreview(converted, photo: photo, generation: generation) {
                            record.regenerated.insert(photo.id)
                            try persistRecoveryCheckpoint(record, operationID: operationID)
                            continue
                        }
                    }
                    let events: SynologyPhotosPreviewEvents
                    do {
                        events = try previewEvents()
                        try await events.subscribe(unitID: photo.id.unitID)
                    } catch {
                        // 事件通道尚未建立，不存在在途NAS转换；本机仍可独立完成预览。
                        if !localFirst {
                            do { prepared = try await prepareLocalPreview(photo, generation: generation) }
                            catch { record.regenerationFailed.formUnion(photos[index...].map(\.id)); break }
                            if let converted = prepared {
                                try await preparePreviewRegeneration(photo, resuming: resuming, generation: generation, record: &record, operationID: operationID)
                                marked = true
                                try recordPreviewSubmission(photo, record: &record, operationID: operationID)
                                if try await uploadConvertedPreview(converted, photo: photo, generation: generation) {
                                    record.regenerated.insert(photo.id)
                                    try persistRecoveryCheckpoint(record, operationID: operationID)
                                    continue
                                }
                            }
                        }
                        // 本机明确失败而NAS尚未发起时，恢复该项标记；未知上传不会进入这里。
                        if marked && !resuming {
                            try Task.checkCancellation()
                            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
                            try recordPreviewRestoration(photo, record: &record, operationID: operationID)
                            try await managementWrite(api("RegeneratePreview", in: photo.id.space), method: "restore_from_regenerating", parameters: ["unit_id": .integerArray([photo.id.unitID])])
                        }
                        record.regenerationFailed.formUnion(photos[index...].map(\.id))
                        break
                    }
                    do {
                        try Task.checkCancellation(); try requirePreviewPhoto(photo)
                        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
                        if !marked { try await preparePreviewRegeneration(photo, resuming: resuming, generation: generation, record: &record, operationID: operationID) }
                        try recordPreviewSubmission(photo, record: &record, operationID: operationID)
                        try await managementWrite(api("RegeneratePreview", in: photo.id.space), method: "regenerate_preview_by_nas", parameters: ["unit_id": .integer(photo.id.unitID)])
                        var success = try await events.completion()
                        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
                        await events.close()
                        if !success, !localFirst, let converted = try await prepareLocalPreview(photo, generation: generation) {
                            try recordPreviewSubmission(photo, record: &record, operationID: operationID)
                            success = try await uploadConvertedPreview(converted, photo: photo, generation: generation)
                        }
                        if success { record.regenerated.insert(photo.id) }
                        else {
                            // 只有明确失败才恢复重建标记；未知结果不重复提交、不抢先清理。
                            try recordPreviewRestoration(photo, record: &record, operationID: operationID)
                            try await managementWrite(api("RegeneratePreview", in: photo.id.space), method: "restore_from_regenerating", parameters: ["unit_id": .integerArray([photo.id.unitID])])
                            record.regenerationFailed.insert(photo.id)
                        }
                        try persistRecoveryCheckpoint(record, operationID: operationID)
                        await events.close()
                    } catch { await events.close(); throw error }
                }
            case .createPhotoRequest(let settings):
                var parameters = photoRequestParameters(settings)
                parameters["passphrase"] = .string("")
                let created: PhotoRequestList.Entry = try await call("SYNO.Foto.PhotoRequest", version: 1, method: "create", parameters: parameters)
                guard !created.passphrase.isEmpty else { throw Self.failure(.invalidResponse) }
                record.photoRequestID = created.passphrase
            case .updatePhotoRequest(let original, let settings):
                let previous = photoRequestParameters(original.settings), desired = photoRequestParameters(settings)
                var parameters = desired.filter { previous[$0.key] != $0.value }
                if settings.space != original.settings.space || settings.folderPath != original.settings.folderPath {
                    parameters["library"] = desired["library"]; parameters["folder_home_path"] = desired["folder_home_path"]
                }
                if settings.albumID != original.settings.albumID || settings.albumPassphrase != original.settings.albumPassphrase {
                    if let passphrase = settings.albumPassphrase { parameters["album_passphrase"] = .string(passphrase); parameters["album_id"] = nil }
                    else { parameters["album_id"] = .integer(settings.albumID ?? -1); parameters["album_passphrase"] = nil }
                }
                if !parameters.isEmpty {
                    parameters["passphrase"] = .string(original.id)
                    try await managementWrite("SYNO.Foto.PhotoRequest", method: "update", parameters: parameters)
                }
            case .deletePhotoRequest(let original):
                try await managementWrite("SYNO.Foto.PhotoRequest", method: "delete", parameters: ["passphrase": .stringArray([original.id])])
            case .editPhotoFaces(let photo, let changes):
                let manualGeneration = accessGeneration
                guard let originalIDs = photoFaceIDs[photo.id] else { throw Self.failure(.conflict) }
                let additions = changes.compactMap { change -> SynologyPhotoNewFace? in if case .add(let face) = change { return face }; return nil }
                if !additions.isEmpty {
                    record.manualAddAttempted = true
                    do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                    catch { record.manualAddAttempted = false; throw error }
                    let receipt: ManualFaceReceipt = try await call(api("Browse.Person", in: mutation.space), version: 3, method: "add_face", parameters: ["id_item": .integer(photo.id.unitID), "face": .objectArray(additions.map(Self.manualFaceParameters))])
                    let requested = Set(additions.map(\.temporaryID))
                    guard receipt.list.allSatisfy({ $0.face_id > 0 && !originalIDs.contains($0.face_id) && requested.contains($0.face_id_temp) }),
                          Set(receipt.list.map(\.face_id)).count == receipt.list.count,
                          Set(receipt.list.map(\.face_id_temp)).count == receipt.list.count else { throw Self.failure(.invalidResponse) }
                    record.manualNewIDs = Dictionary(uniqueKeysWithValues: receipt.list.map { ($0.face_id_temp, $0.face_id) })
                    record.manualAddAcknowledged = true
                    try persistRecoveryCheckpoint(record, operationID: operationID)
                    for face in additions {
                        guard let id = record.manualNewIDs[face.temporaryID] else { record.manualKnownFailures.insert("new-" + face.temporaryID); continue }
                        // 裁剪图只发送给add_face明确返回的编号，绝不按姓名推测。
                        guard manualGeneration == accessGeneration else { throw Self.failure(.permissionDenied) }
                        record.manualCurrent = "new-" + face.temporaryID
                        record.manualThumbnailAttempted.insert(id)
                        do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                        catch { record.manualThumbnailAttempted.remove(id); record.manualCurrent = nil; throw error }
                        try await uploadManualFace(face.jpeg, faceID: id, in: photo.id.space)
                        record.manualUploaded.insert(id); record.manualAcknowledged.insert("new-" + face.temporaryID)
                        record.manualCurrent = nil
                        try persistRecoveryCheckpoint(record, operationID: operationID)
                    }
                }
                if record.manualKnownFailures.isEmpty {
                    for change in changes {
                        try Task.checkCancellation()
                        if photo.albumContext != nil { try requireAccess(photo.id.space) }
                        else { try requirePhoto(photo) }
                        guard manualGeneration == accessGeneration else { throw Self.failure(.permissionDenied) }
                        if case .add = change { continue }
                        record.manualCurrent = change.id; record.manualAttempted.insert(change.id)
                        do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                        catch { record.manualAttempted.remove(change.id); record.manualCurrent = nil; throw error }
                        switch change {
                        case .add: continue
                        case .remove(let original):
                            try await managementWrite(api("Browse.Person", in: mutation.space), method: "delete_face", parameters: ["person_id": .integer(original.personID), "face_id": .integerArray([original.id])])
                        case .reassign(let original, let person, let name):
                            var parameters: [String: DsmParameterValue] = ["face_id": .integerArray([original.id]), "name": .string(name)]
                            if let person { parameters["target_id"] = .integer(person.id) }
                            let receipt: PersonNameReceipt = try await call(api("Browse.Person", in: mutation.space), version: 1, method: "separate", parameters: parameters)
                            guard receipt.id > 0, receipt.name == name, person == nil || person?.id == receipt.id else { throw Self.failure(.invalidResponse) }
                            record.manualPersonReceipts[change.id] = receipt
                        }
                        record.manualAcknowledged.insert(change.id); record.manualCurrent = nil
                        try persistRecoveryCheckpoint(record, operationID: operationID)
                    }
                } else {
                    for change in changes { if case .add = change { continue }; record.manualKnownFailures.insert(change.id) }
                }
            case .setConceptCover(let concept, let photo):
                try await managementWrite(api("Browse.Concept", in: mutation.space), method: "set_cover", parameters: ["id": .integer(concept.id), "photo_id": .integer(photo.id.unitID)])
            case .removeConceptItems(let concept, let photos):
                try await managementWrite(api("Browse.Concept", in: mutation.space), method: "hide_item", parameters: ["id": .integer(concept.id), "item_id": .integerArray(photos.map { $0.id.unitID })])
                record.conceptRemovalAcknowledged = true
            case .setConceptVisibility(let originals, let visible):
                try await managementWrite(api("Browse.Concept", in: mutation.space), version: 2, method: "set_visibility", parameters: ["id": .integerArray(originals.map(\.id)), "visibility": .boolean(visible)])
                record.visibilityAcknowledged = true
            case .setPeopleVisibility(let originals, let visible):
                try await managementWrite(api("Browse.Person", in: mutation.space), method: "show", parameters: ["id": .integerArray(originals.map(\.id)), "show": .boolean(visible)])
                record.visibilityAcknowledged = true
            case .removePersonFaces(let person, let faces):
                try await managementWrite(api("Browse.Person", in: mutation.space), method: "delete_face", parameters: ["person_id": .integer(person.id), "face_id": .integerArray(faces.map(\.id))])
            case .reassignPersonFaces(_, let faces, let target, let name):
                let receipt: PersonNameReceipt = try await call(api("Browse.Person", in: mutation.space), version: 1, method: "separate", parameters: ["name": .string(name), "target_id": .integer(target?.id ?? 0), "face_id": .integerArray(faces.map(\.id))])
                guard receipt.id > 0, receipt.name == name, target == nil || target?.id == receipt.id else { throw Self.failure(.invalidResponse) }
                record.personReceipt = receipt
            case .setPersonCover(let person, let photo):
                let receipt: PersonCoverReceipt = try await call(api("Browse.Person", in: mutation.space), version: 1, method: "set_cover", parameters: ["id": .integer(person.id), "photo_id": .integer(photo.id.unitID)])
                guard receipt.id == person.id, receipt.cover > 0 else { throw Self.failure(.invalidResponse) }
                record.personCoverReceipt = receipt
            case .renamePerson(let person, let name):
                if person.name == name {
                    record.result = .init(state: .confirmed, person: person)
                    mutations[operationID] = record; return record.result
                }
                let receipt: PersonNameReceipt = try await call(api("Browse.Person", in: mutation.space), version: 1, method: "set", parameters: ["id": .integer(person.id), "name": .string(name)])
                guard receipt.id == person.id, receipt.name == name else { throw Self.failure(.invalidResponse) }
                record.personReceipt = receipt
            case .mergePeople(let target, let sources, let name):
                try await managementWrite(api("Browse.Person", in: mutation.space), version: 2, method: "merge", parameters: ["target_id": .integer(target.id), "merged_id": .integerArray(sources.map(\.id)), "name": .string(name)])
            case .rotatePhoto(let photo):
                let receipt: AlbumMembershipReceipt = try await call(api("Browse.Item", in: photo.id.space), version: 2, method: "set", parameters: [
                    "id": .integerArray([photo.id.unitID]), "rotate_action": .string("counter_clockwise")])
                if receipt.error_list?.isEmpty == false {
                    record.result = .init(state: .rejected)
                    mutations[operationID] = record
                    return record.result
                }
            case .edit(let photos, let edit):
                let generation = accessGeneration
                for space in SynologyPhotoSpace.allCases {
                    let group = photos.filter { $0.id.space == space }
                    guard !group.isEmpty else { continue }
                    try Task.checkCancellation()
                    guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
                    _ = try mutationAccessSpace(mutation)
                    var params: [String: DsmParameterValue] = ["id": .integerArray(group.map { $0.id.unitID })]
                    switch edit {
                    case .rating(let value): params["rating"] = .integer(value)
                    case .description(let value): params["description"] = .string(value)
                    case .takenAt(let value): params["time"] = .integer(Int(value.timeIntervalSince1970))
                    }
                    record.metadataCurrentIDs = Set(group.map(\.id))
                    record.metadataSubmittedIDs.formUnion(record.metadataCurrentIDs)
                    do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                    catch {
                        record.metadataSubmittedIDs.subtract(record.metadataCurrentIDs); record.metadataCurrentIDs = []
                        throw error
                    }
                    let receipt: AlbumMembershipReceipt = try await call(api("Browse.Item", in: space), version: 2, method: "set", parameters: params)
                    guard (receipt.error_list?.count ?? 0) <= group.count else { throw Self.failure(.invalidResponse) }
                    if receipt.error_list?.isEmpty == false { record.metadataFailureReportedIDs.formUnion(record.metadataCurrentIDs) }
                    record.metadataCurrentIDs = []
                    try persistRecoveryCheckpoint(record, operationID: operationID)
                }
            case .shiftDates(let photos, let seconds):
                let generation = accessGeneration
                for photo in photos {
                    try Task.checkCancellation()
                    guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
                    _ = try mutationAccessSpace(mutation)
                    record.shiftedSubmittedIDs.insert(photo.id)
                    record.shiftingPhotoID = photo.id
                    do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                    catch { record.shiftedSubmittedIDs.remove(photo.id); record.shiftingPhotoID = nil; throw error }
                    try await managementWrite(api("Browse.Item", in: photo.id.space), version: 2, method: "set", parameters: [
                        "id": .integerArray([photo.id.unitID]), "time": .integer(try shiftedTimestamp(photo, seconds: seconds))])
                    record.shiftingPhotoID = nil
                    try persistRecoveryCheckpoint(record, operationID: operationID)
                }
            case .createTag(let name, let photos, _):
                let created: CreatedManagementTag = try await call(api("Browse.GeneralTag", in: mutation.space), version: 1, method: "create", parameters: ["name": .string(name)])
                guard created.tag.id > 0, created.tag.name == name else { throw Self.failure(.invalidResponse) }
                record.createdTag = created.tag
                try persistRecoveryCheckpoint(record, operationID: operationID)
                if !photos.isEmpty {
                    try Task.checkCancellation()
                    try requireAccess(mutation.space)
                    record.tagAdditionAttempted = true
                    do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                    catch { record.tagAdditionAttempted = false; throw error }
                    try await managementWrite(api("Browse.Item", in: mutation.space), method: "add_tag", parameters: ["id": .integerArray(ids), "tag": .integerArray([created.tag.id])])
                }
            case .addTags(_, let tags), .removeTags(_, let tags):
                let method: String
                if case .addTags = mutation { method = "add_tag" } else { method = "remove_tag" }
                record.metadataSubmittedIDs = Set(mutation.photos.map(\.id))
                do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                catch { record.metadataSubmittedIDs = []; record.result = .init(state: .rejected); throw error }
                try await managementWrite(api("Browse.Item", in: mutation.space), method: method, parameters: ["id": .integerArray(ids), "tag": .integerArray(tags)])
            case .unfreezeAlbum(let original):
                try await managementWrite("SYNO.Foto.Browse.NormalAlbum", version: 1, method: "set_unfreeze", parameters: ["id": .integer(original.album.id)])
            case .rebuildFrozenAlbum(_, let name, let condition):
                let created: CreatedConditionAlbum = try await call("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "create", parameters: ["name": .string(name), "condition": .object(try conditionParameters(condition))])
                guard created.album.id > 0 else { throw Self.failure(.invalidResponse) }
                record.albumID = created.album.id
            case .createConditionAlbum(let name, let condition):
                let created: CreatedConditionAlbum = try await call("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "create", parameters: ["name": .string(name), "condition": .object(try conditionParameters(condition))])
                guard created.album.id > 0 else { throw Self.failure(.invalidResponse) }
                record.albumID = created.album.id
            case .setAlbumCondition(let id, _, let condition):
                try await managementWrite("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "set_condition", parameters: ["id": .integer(id), "condition": .object(try conditionParameters(condition))])
            case .createTemporaryAlbum(let name, _):
                let created: CreatedManagementAlbum = try await call("SYNO.Foto.Browse.NormalAlbum", version: 1, method: "create", parameters: ["name": .string(name), "item": .integerArray(ids), "shared": .boolean(true)])
                guard created.album.id > 0 else { throw Self.failure(.invalidResponse) }
                record.albumID = created.album.id
            case .copyTemporaryAlbum(let id, let name, _):
                let created: CreatedManagementAlbum = try await call("SYNO.Foto.Browse.NormalAlbum", version: 1, method: "copy", parameters: ["name": .string(name), "source_album_id": .integer(id)])
                guard created.album.id > 0, created.album.id != id else { throw Self.failure(.invalidResponse) }
                record.albumID = created.album.id
            case .deleteTemporaryAlbum(let id, _, _):
                try await managementWrite("SYNO.Foto.Browse.Album", method: "delete", parameters: ["id": .integerArray([id])])
            case .createAlbum(let name, _):
                let created: CreatedManagementAlbum = try await call("SYNO.Foto.Browse.NormalAlbum", version: 1, method: "create", parameters: ["name": .string(name), "item": .integerArray(ids)])
                guard created.album.id > 0 else { throw Self.failure(.invalidResponse) }
                record.albumID = created.album.id
            case .createFolder(let parent, let name, let space):
                let created: CreatedManagementFolder = try await call(api("Browse.Folder", in: space), version: 1, method: "create", parameters: [
                    "target_id": .integer(parent), "name": .string(name)])
                guard created.folder.id > 0 else { throw Self.failure(.invalidResponse) }
                record.folderID = created.folder.id
            case .deleteFolderItems(let photos, let folders):
                let task: ManagementTaskReceipt = try await call(api("BackgroundTask.File", in: mutation.space), version: 1, method: "delete",
                    parameters: ["item_id": .integerArray(photos.map { $0.id.unitID }), "folder_id": .integerArray(folders.map(\.id))])
                guard task.task_info.id > 0 else { throw Self.failure(.invalidResponse) }
                record.taskID = task.task_info.id
            case .renameFolder(let folder, let name):
                try await managementWrite(api("Browse.Folder", in: folder.space), version: 1, method: "rename",
                    parameters: ["id": .integer(folder.id), "name": .string(name)])
            case .renameAlbum(let id, let name):
                try await managementWrite("SYNO.Foto.Browse.Album", method: "set_name", parameters: ["id": .integer(id), "name": .string(name)])
            case .deleteAlbum(let id):
                try await managementWrite("SYNO.Foto.Browse.Album", method: "delete", parameters: ["id": .integerArray([id])])
            case .addToAlbum(let id, _), .removeFromAlbum(let id, _):
                let method: String
                if case .addToAlbum = mutation { method = "add_item" } else { method = "delete_item" }
                let receipt: AlbumMembershipReceipt = try await call("SYNO.Foto.Browse.NormalAlbum", version: 1, method: method,
                    parameters: (albumTarget ?? ["id": .integer(id)]).merging(["item": .integerArray(ids)]) { _, new in new })
                guard (receipt.error_list?.count ?? 0) <= ids.count else { throw Self.failure(.invalidResponse) }
                record.albumMembershipHasFailures = receipt.error_list?.isEmpty == false
            case .setAlbumListSort(let scope, _, let sort):
                try await managementWrite("SYNO.Foto.Browse.Album", version: 2, method: "set_album_list_order", parameters: [scope.rawValue + "_sort_by": .string(sort.field.rawValue), scope.rawValue + "_sort_direction": .string(sort.direction.rawValue)])
            case .setAlbumListDisplay(_, let display):
                try await managementWrite("SYNO.Foto.Browse.Album", version: 3, method: "set_album_list_display", parameters: ["album_display_type": .string(display.rawValue)])
            case .setAlbumSort(let id, _, let sort):
                try await managementWrite("SYNO.Foto.Browse.Album", method: "set_order", parameters: ["id": .integer(id), "sort_by": .string(sort.field.rawValue), "sort_direction": .string(sort.direction.rawValue)])
            case .setFolderSort(let folder, let sort):
                try await managementWrite(api("Browse.Folder", in: folder.space), version: 1, method: "set_order", parameters: ["id": .integer(folder.id), "sort_by": .string(sort.field.rawValue), "sort_direction": .string(sort.direction.rawValue)])
            case .setFolderCover(let folder, let photo):
                try await managementWrite(api("Browse.Folder", in: folder.space), version: 2, method: "set_cover", parameters: ["id": .integer(folder.id), "id_item": .integerArray([photo.id.unitID])])
                record.folderCoverAcknowledged = true
            case .setAlbumCover(let id, let photo):
                try await managementWrite("SYNO.Foto.Browse.Album", method: "set_cover", parameters: ["id": .integer(id), "id_item": .integer(photo.id.unitID)])
            case .move(_, let folder, _, _, let duplicate), .copy(_, let folder, _, _, let duplicate):
                let method: String
                if case .move = mutation { method = "move" } else { method = "copy" }
                var parameters: [String: DsmParameterValue] = ["target_folder_id": .integer(folder), "item_id": .integerArray(ids), "folder_id": .integerArray(mutation.transferFolders.map(\.id)), "action": .string(duplicate.rawValue)]
                if case .move = mutation {
                    let info = TransferSourceInfo(version: 2, source_library: mutation.space == .personal ? "personal_space" : "shared_space", source_folder_ids: mutation.transferFolders.first?.parentID.map { [$0] })
                    parameters["extra_info"] = .string(String(decoding: try JSONEncoder().encode(info), as: UTF8.self))
                }
                let task: ManagementTaskReceipt = try await call(api("BackgroundTask.File", in: mutation.space), version: 1, method: method, parameters: parameters)
                guard task.task_info.id > 0 else { throw Self.failure(.invalidResponse) }
                record.taskID = task.task_info.id
                record.transferTargetVerified = transferTargetMatches(task.task_info, mutation: mutation, folderID: folder)
                record.transferTotal = task.task_info.total
            case .uploadToAlbum(let url, let size, let modified, let albumID, let duplicate):
                let passphrase: String? = if case .string(let value) = albumTarget?["passphrase"] { value } else { nil }
                let receipt = try await uploadPhoto(url, size: size, modifiedAt: modified, folderID: nil, space: .personal, albumID: albumID, albumPassphrase: passphrase, duplicate: duplicate, progress: progress)
                record.itemID = receipt.id; record.uploadAction = receipt.action
            case .upload(let url, let size, let modified, let folder, let space, let duplicate):
                let receipt = try await uploadPhoto(url, size: size, modifiedAt: modified, folderID: folder, space: space, duplicate: duplicate, progress: progress)
                record.itemID = receipt.id; record.uploadAction = receipt.action
            case .shareAlbum(let id, let access, _, let members, let expiration, let password):
                guard let album = sharingAlbum, let current = sharingSnapshot else { throw Self.failure(.invalidResponse) }
                let memberChanges = try sharingMemberChanges(from: current.members, to: members)
                let expirationChanged = expiration.map { $0 != current.expiration } ?? false
                if current.access == access, memberChanges.isEmpty, !expirationChanged, password == nil, access == .disabled || current.url != nil {
                    record.result = .init(state: .confirmed, album: album.collection, sharingURL: current.url)
                    mutations[operationID] = record
                    return record.result
                }
                if access == .disabled, memberChanges.isEmpty, !expirationChanged, password == nil {
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
                    if !changes.isEmpty || expirationChanged || password != nil {
                        var parameters: [String: DsmParameterValue] = ["passphrase": .string(passphrase)]
                        if !changes.isEmpty { parameters["permission"] = .objectArray(changes) }
                        if let expiration, expirationChanged { parameters["expiration"] = .integer(expiration) }
                        // 连接层仅允许HTTPS；与官方HTTPS路径一致，不增加明文HTTP降级。
                        if let password { parameters["password"] = .string(password) }
                        try await managementWrite("SYNO.Foto.Sharing.Passphrase", method: "update", parameters: parameters)
                        record.passwordUpdateAcknowledged = password != nil
                        // 设置密码的回执必须先保存，再决定是否开启访问。
                        try persistRecoveryCheckpoint(record, operationID: operationID)
                    }
                    if access != .disabled {
                        try Task.checkCancellation()
                        try requireAccess(.personal)
                        record.enableSharingAttempted = true
                        do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                        catch { record.enableSharingAttempted = false; throw error }
                        try await managementWrite("SYNO.Foto.Sharing.Passphrase", method: "set_shared", parameters: ["policy": .string("album"), "album_id": .integer(id), "enabled": .boolean(true)])
                    }
                }
            }
        } catch {
            let appError: AppError?
            if let networkError = error as? DsmNetworkError { appError = DsmErrorMapper.map(networkError) }
            else { appError = error as? AppError }
            let rejected = appError?.category == .permissionDenied || appError?.category == .authenticationRequired
            let memberFailureReceipt: Bool
            if case DsmNetworkError.api = error { memberFailureReceipt = true } else { memberFailureReceipt = false }
            switch mutation {
            case .unfreezeAlbum, .rebuildFrozenAlbum:
                if rejected || memberFailureReceipt { record.result = .init(state: .rejected) }
            case .cancelBackgroundTask:
                if rejected || memberFailureReceipt { record.result = .init(state: .rejected) }
            case .clearBackgroundTasks:
                if rejected || memberFailureReceipt, let id = record.backgroundCurrent { record.backgroundRejected.insert(id) }
                if record.backgroundAttempted.isEmpty { record.result = .init(state: .rejected) }
            case .respondToCodecPrompt:
                if rejected || memberFailureReceipt {
                    record.codecPromptRejected = true
                    record.result = .init(state: record.codecGenerationAcknowledged ? .partial : .rejected,
                                          completedCount: record.codecGenerationAcknowledged ? 1 : 0)
                }
            case .maintainLibrary:
                if rejected || memberFailureReceipt { record.result = .init(state: .rejected) }
            case .setSharedMembers:
                // 明确的success:false可能伴随部分应用；仍回读实际权限，不能当作全部未执行。
                if rejected || memberFailureReceipt, let step = record.memberCurrent { record.memberRejected.insert(step) }
                if record.memberAttempted.isEmpty { record.result = .init(state: .rejected) }
            case .setGlobalSettings, .clearConversionCache:
                if rejected, let step = record.globalCurrent { record.globalRejected.insert(step) }
                if record.globalAttempted.isEmpty { record.result = .init(state: .rejected) }
            case .generateAutomaticPreview:
                if record.automaticFailureKind != nil {
                    if rejected || memberFailureReceipt { record.result = .init(state: .rejected) }
                } else if !record.automaticPreviewSubmitted { record.result = .init(state: .rejected) }
            case .regeneratePreviews(let photos, let resuming):
                record.regenerationFailed.formUnion(Set(photos.map(\.id)).subtracting(resuming ? record.regenerationSubmitted : record.regenerationAttempted))
                if record.usesAlbumRecovery {
                    for photo in photos where !record.regenerationSubmitted.contains(photo.id) {
                        if !record.regenerationMarking.contains(photo.id) || record.regenerationMarked.contains(photo.id) || rejected || memberFailureReceipt {
                            record.regenerationFailed.insert(photo.id)
                        }
                    }
                }
            case .edit:
                if rejected { record.metadataRejectedIDs.formUnion(record.metadataCurrentIDs) }
            case .shiftDates:
                if rejected { record.shiftedRejectedID = record.shiftingPhotoID }
            case .createTag:
                if rejected, record.createdTag != nil { record.tagAdditionRejected = true }
                else if rejected { record.result = .init(state: .rejected) }
            case .editPhotoFaces(_, let changes):
                if rejected {
                    if !record.usesAlbumRecovery { record.manualKnownFailures.formUnion(changes.map(\.id).filter { !record.manualAcknowledged.contains($0) }) }
                    else if record.manualAddAttempted, !record.manualAddAcknowledged {
                        record.manualKnownFailures.formUnion(changes.map(\.id))
                    } else if let current = record.manualCurrent { record.manualKnownFailures.insert(current) }
                }
            case .editSimilarGroup:
                // 取消或保存失败发生在提交边界之前时，没有需要继续查询的写操作。
                if !record.similarSubmitted || rejected { record.result = .init(state: .rejected) }
            case .shareAlbum: break
            case .setFolderSharing:
                if rejected, !record.folderSharingAcknowledged { record.result = .init(state: .rejected) }
            default:
                if rejected { record.result = .init(state: .rejected) }
            }
            mutations[operationID] = record
            try? persistRecoveryCheckpoint(record, operationID: operationID)
            switch mutation {
            case .cancelBackgroundTask, .clearBackgroundTasks, .respondToCodecPrompt, .maintainLibrary, .setSharedMembers, .setGlobalSettings, .clearConversionCache:
                return (try? await inspectMutation(operationID)) ?? record.result
            case .generateAutomaticPreview where record.automaticPreviewSubmitted || record.automaticFailureKind != nil:
                return (try? await inspectMutation(operationID)) ?? record.result
            case .setFolderSharing where record.folderSharingAcknowledged:
                return (try? await inspectMutation(operationID)) ?? record.result
            case .shiftDates, .editPhotoFaces, .regeneratePreviews:
                return (try? await inspectMutation(operationID)) ?? record.result
            case .edit where record.usesAlbumRecovery || !record.metadataRejectedIDs.isEmpty:
                return (try? await inspectMutation(operationID)) ?? record.result
            case .createTag where record.createdTag != nil:
                return (try? await inspectMutation(operationID)) ?? record.result
            default: return record.result
            }
        }
        mutations[operationID] = record
        // 回执先保存，再进行网络核对；保存失败保留未知状态，不能重发。
        do { try persistRecoveryCheckpoint(record, operationID: operationID) }
        catch { return .init(state: .pendingReview) }
        return (try? await inspectMutation(operationID)) ?? record.result
    }

    private static func matchesRecognitionName(_ actual: String, expected: String, record: PhotosMutationRecord) -> Bool {
        record.restoredRecognition == nil ? actual == expected : SynologyPhotosAlbumCheckpoint.Recognition.digest(actual) == expected
    }

    private static func matchesRecognitionImage(_ actual: Data, changeID: String, original: Data, record: PhotosMutationRecord) -> Bool {
        guard let restored = record.restoredRecognition else { return actual == original }
        guard case .manual(let changes) = restored.intent,
              case .add(_, _, _, _, let digest) = changes.first(where: { $0.id == changeID }) else { return false }
        return SynologyPhotosAlbumCheckpoint.Recognition.digest(actual) == digest
    }

    private func transferTargetMatches(_ task: ManagementTransferTask, mutation: SynologyPhotosMutation, folderID: Int) -> Bool {
        let owner = mutation.destinationSpace == .shared ? 0 : currentUserID
        let validTotal = mutation.transferFolders.isEmpty ? task.total == mutation.photos.count : (task.total.map { $0 >= mutation.photos.count } ?? false)
        return validTotal && task.target_folder?.id == folderID &&
            owner != nil && task.target_folder?.owner_user_id == owner
    }

    private func managementWrite(_ name: String, version: Int = 1, method: String, parameters: [String: DsmParameterValue]) async throws {
        guard let capability = capabilities[name], capability.minVersion <= version, capability.maxVersion >= version, capability.requestFormat == .json else { throw Self.failure(.apiUnavailable) }
        try await client.callVoid(path: capability.path, api: name, version: version, method: method, requestFormat: .json, parameters: parameters, credential: credential)
    }

    public func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        guard let record = mutations[operationID] else { throw Self.failure(.conflict) }
        _ = try mutationAccessSpace(record.mutation)
        if record.result.state != .pendingReview || mutationInFlight { return record.result }
        mutationInFlight = true
        defer { mutationInFlight = false }
        return try await inspectMutation(operationID)
    }

    private func inspectMutation(_ operationID: UUID) async throws -> SynologyPhotosMutationResult {
        guard var record = mutations[operationID] else { throw Self.failure(.conflict) }
        _ = try mutationAccessSpace(record.mutation)
        if let sharing = record.restoredFolderSharing {
            if record.result.state == .rejected { return record.result }
            let current = try await folderSharing(sharing.folder)
            let membersMatch = sharing.members.map { expected in
                current.members.map { sharingMemberRoles($0) == sharingMemberRoles(expected.map(\.grant)) } ?? false
            } ?? true
            let passwordMatch = switch sharing.password {
            case .unchanged: current.hasPassword == sharing.previousHasPassword
            case .remove: current.hasPassword == false
            case .set: sharing.acknowledged && current.hasPassword == true
            }
            if current.access.rawValue == sharing.access, membersMatch, passwordMatch,
               !sharing.appliesToSubfolders || sharing.acknowledged {
                record.result = .init(state: current.appliesToSubfolders == sharing.appliesToSubfolders ? .confirmed : .partial,
                    sharingURL: current.url, folder: current.folder)
                mutations[operationID] = record
            }
            return record.result
        }
        if let edit = record.restoredPhotoEdit {
            let result = try await inspectRecoveredPhotoEdit(edit, record: record)
            record.result = result; mutations[operationID] = record
            return result
        }
        var result = SynologyPhotosMutationResult(state: .pendingReview)
        switch record.mutation {
        case .cancelBackgroundTask(let original):
            if record.result.state == .rejected { return record.result }
            guard original.profileID == profileID, original.userID == currentUserID else { throw Self.failure(.permissionDenied) }
            let current = try await backgroundTasks().first { $0.id == original.id }
            if let current {
                guard current.hasSameIdentity(as: original) else { throw Self.failure(.conflict) }
                if current.status == .done { result = .init(state: .confirmed, completedCount: 1) }
            } else { result = .init(state: .confirmed, completedCount: 1) }
        case .clearBackgroundTasks(let originals):
            guard originals.allSatisfy({ $0.profileID == profileID && $0.userID == currentUserID }) else { throw Self.failure(.permissionDenied) }
            let current = try await backgroundTasks()
            var remaining: Set<Int> = []
            for original in originals {
                if let task = current.first(where: { $0.id == original.id }) {
                    guard task.hasSameIdentity(as: original) else { throw Self.failure(.conflict) }
                    remaining.insert(task.id)
                }
            }
            let completed = originals.count - remaining.count
            if remaining.isEmpty { result = .init(state: .confirmed, completedCount: completed) }
            else if remaining.intersection(record.backgroundAttempted).subtracting(record.backgroundRejected).isEmpty {
                result = .init(state: completed > 0 ? .partial : .rejected, completedCount: completed)
            }
        case .respondToCodecPrompt(let original, let generate):
            if record.result.state == .rejected { return record.result }
            let current = try await codecPrompt()
            guard current.userID == original.userID else { throw Self.failure(.permissionDenied) }
            // 全用户维护无可归因终态；确认的是接收回执和提示已读，不是生成完成。
            if !generate || record.codecGenerationAcknowledged {
                if !current.shouldShow { result = .init(state: .confirmed, completedCount: 1) }
                else if record.codecPromptRejected { result = .init(state: .partial, completedCount: 1) }
            }
        case .maintainLibrary(let original, let action):
            if record.result.state == .rejected { return record.result }
            let current = try await libraryMaintenanceStatus(in: original.space)
            guard current.userID == original.userID else { throw Self.failure(.permissionDenied) }
            // 无任务编号。只有明确接收回执和对应计数归零同时成立才结束核对。
            // 回执丢失时，其他客户端也可能产生任务，不能用计数变化追认或重放。
            if record.libraryMaintenanceAcknowledged, current.pendingCount(for: action) == 0 {
                result = .init(state: .confirmed, completedCount: 1)
            }
        case .setSharedMembers(let original, let members, let edits):
            result = try await inspectSharedMembers(original: original, members: members, edits: edits, record: record)
        case .setAutomaticPreview(_, let enabled):
            if try await automaticPreviewEnabled() == enabled { result = .init(state: .confirmed, completedCount: 1) }
        case .generateAutomaticPreview(let task, _):
            if record.usesAlbumRecovery, !record.automaticPreviewSubmitted, record.automaticFailureKind == nil {
                result = .init(state: .rejected); break
            }
            guard task.profileID == profileID else { throw Self.failure(.permissionDenied) }
            var verifiedSources: [AutomaticPreviewSource]?
            if let photo = task.sourcePhoto {
                let sources = try await automaticPreviewSources(for: photo)
                verifiedSources = sources
                guard photo.id.space == task.space, sources.contains(where: { $0.id == task.unitID && $0.filename == task.filename && $0.video == (task.typeCode != 0) }) else { throw Self.failure(.conflict) }
            } else if task.space == .shared && !managesSharedSpace { throw Self.failure(.permissionDenied) }
            if record.result.state == .rejected { return record.result }
            if let kind = record.automaticFailureKind {
                let recorded: Bool
                if record.automaticFailureAcknowledged { recorded = true }
                else if let sources = verifiedSources {
                    guard let source = sources.first(where: { $0.id == task.unitID && $0.filename == task.filename }) else { throw Self.failure(.conflict) }
                    // 缺字段与UI默认值不构成标记成功；只接受真实尺寸/视频字段的broken。
                    recorded = kind == .photo
                        ? source.additional.thumbnail?.xl == "broken" && source.additional.thumbnail?.sm == "broken"
                        : source.additional.video_convert_status == "broken"
                } else { recorded = false }
                if recorded { result = .init(state: .rejected, automaticPreviewFailureRecorded: true) }
                break
            }
            let matched = record.automaticPreviewAcknowledged ? true : try await automaticPreviewMatches(task, record: record)
            if matched {
                result = .init(state: .confirmed, completedCount: 1)
            }
        case .rotatePhoto(let original):
            let photo = try await details(for: original)
            guard photo.filename == original.filename, photo.sizeBytes == original.sizeBytes,
                  photo.folderID == original.folderID, photo.indexedAt == original.indexedAt,
                  photo.mediaType == original.mediaType else { throw Self.failure(.conflict) }
            // 旋转不可重放；只接受预期方向和尺寸，旧快照不能证明成功。
            if let expected = original.counterClockwiseOrientation, photo.orientation == expected,
               original.width == nil || photo.height == original.width,
               original.height == nil || photo.width == original.height {
                result = .init(state: .confirmed, photos: [photo], completedCount: 1)
            }
        case .setGlobalSettings(let original, let enabled, let extensions):
            let target = original.applying(enabled: enabled, excludedExtensions: extensions)
            let current = try await globalSettings()
            guard current.profileID == original.profileID, current.administratorID == original.administratorID else { throw Self.failure(.permissionDenied) }
            let steps = Set(globalSteps(original, target).map { $0.0 })
            var matched: Set<PhotosGlobalStep> = []
            if original.values.keys.filter({ original.values[$0] != target.values[$0] }).allSatisfy({ current.values[$0] == target.values[$0] }),
               original.excludedExtensions == target.excludedExtensions || current.excludedExtensions == target.excludedExtensions { matched.insert(.admin) }
            if original.personalRecognition.keys.filter({ original.personalRecognition[$0] != target.personalRecognition[$0] }).allSatisfy({ current.personalRecognition[$0] == target.personalRecognition[$0] }) { matched.insert(.personal) }
            if original.sharedRecognition.keys.filter({ original.sharedRecognition[$0] != target.sharedRecognition[$0] }).allSatisfy({ current.sharedRecognition[$0] == target.sharedRecognition[$0] }) { matched.insert(.shared) }
            var cache: SynologyPhotoConversionCache?
            if steps.contains(.cache), record.globalAttempted.contains(.cache) {
                cache = try await conversionCache()
                if let cache, !cache.isClearing, record.globalAcknowledged.contains(.cache) || cache.sizeBytes == 0 { matched.insert(.cache) }
            }
            // 已确认回执仍须满足最终值；未发送的后续步骤只能报告部分完成。
            let finished = steps.intersection(matched).intersection(record.globalAttempted)
            if finished == steps {
                result = .init(state: .confirmed, completedCount: steps.count, globalSettings: current, conversionCache: cache)
            } else if record.globalAttempted.isSubset(of: finished.union(record.globalRejected)) {
                result = .init(state: finished.isEmpty ? .rejected : .partial, completedCount: finished.count,
                               globalSettings: current, conversionCache: cache)
            }
        case .clearConversionCache(let original):
            let current = try await conversionCache()
            guard current.profileID == original.profileID, current.administratorID == original.administratorID else { throw Self.failure(.permissionDenied) }
            if record.globalRejected.contains(.cache) { result = .init(state: .rejected, conversionCache: current) }
            else if !current.isClearing, record.globalAcknowledged.contains(.cache) || current.sizeBytes == 0 {
                result = .init(state: .confirmed, completedCount: 1, conversionCache: current)
            }
        case .setSharedSpaceSettings(let original, let enabled):
            var expected = original
            for kind in expected.values.keys { expected.values[kind] = enabled.contains(kind) }
            let current = try await sharedSpaceSettings()
            if current == expected { result = .init(state: .confirmed, completedCount: 1, sharedSpaceSettings: current) }
        case .setSharedSpaceEnabled(let original, let enabled):
            let current = try await sharedSpaceSettings()
            // 启停可能让套件调整分类默认值；身份和实际访问条件必须保持，分类从回读值更新。
            if current.profileID == original.profileID, current.administratorID == original.administratorID,
               current.isEnabled == enabled, current.personalSpaceEnabled == original.personalSpaceEnabled,
               current.role == original.role {
                result = .init(state: .confirmed, completedCount: 1, sharedSpaceSettings: current)
            }
        case .setRecognitionSettings(let original, let enabled):
            let current = try await recognitionSettings()
            if Set(current.values.keys) == Set(original.values.keys), current.enabled == enabled,
               current.personalSpaceEnabled == original.personalSpaceEnabled, current.globallyEnabled == original.globallyEnabled {
                result = .init(state: .confirmed, completedCount: 1)
            }
        case .setDisplaySettings(_, let updated):
            if try await displaySettings() == updated {
                defaultFolderSort = updated.defaultSort
                result = .init(state: .confirmed, completedCount: 1)
            }
        case .setDuplicateSettings(_, let updated):
            if try await duplicateSettings() == updated { result = .init(state: .confirmed, completedCount: 1) }
        case .setFolderSharing(let original, let access, let members, let password, let apply):
            let current = try await folderSharing(original.folder)
            let expected = members ?? original.members
            let membersMatch = expected.map { expected in current.members.map { sharingMemberRoles($0) == sharingMemberRoles(expected) } ?? false } ?? true
            let passwordMatch = password.map { value in
                value.isEmpty ? current.hasPassword == false : record.passwordUpdateAcknowledged && current.hasPassword == true
            } ?? (current.hasPassword == original.hasPassword)
            // 顶层权限匹配不能证明回执未知时已应用到后代；不自动重发整批权限。
            if current.access == access, membersMatch, passwordMatch, !apply || record.folderSharingAcknowledged {
                result = .init(state: current.appliesToSubfolders == apply ? .confirmed : .partial,
                    sharingURL: current.url, folder: current.folder)
            }
        case .editSimilarGroup(let detail, let edit):
            if let verified = try await inspectSimilarEdit(detail, edit: edit, restored: record.restoredSimilar) { result = verified }
        case .regeneratePreviews(let originals, _):
            let generation = accessGeneration
            if record.usesAlbumRecovery {
                // 最后一次持久化之后不可能越过下一次写前保存；未转换项可重新从队列选择。
                for original in originals where !record.regenerationSubmitted.contains(original.id) && !record.regenerationFailed.contains(original.id) {
                    if !record.regenerationMarking.contains(original.id) || record.regenerationMarked.contains(original.id) {
                        record.regenerationFailed.insert(original.id)
                    } else if let queue = try? await previewRegenerationQueue(in: original.id.space),
                              (try? requireQueuedPreview(original, queue: queue)) != nil {
                        _ = try await validatePreviewRegenerationTarget(original)
                        record.regenerationFailed.insert(original.id)
                    }
                }
            }
            let unresolved = originals.filter { record.regenerationSubmitted.contains($0.id) && !record.regenerated.contains($0.id) && !record.regenerationFailed.contains($0.id) }
            for space in Set(unresolved.map({ $0.id.space })) {
                try Task.checkCancellation()
                // 断网时保留原操作的未知状态；恢复核对失败不改变已有写入结果。
                guard let queue = try? await previewRegenerationQueue(in: space) else { continue }
                for original in unresolved where original.id.space == space && !queue.contains(where: { $0.unit_id == original.id.unitID }) {
                    guard let current = try? await details(for: original) else { continue }
                    guard current.filename == original.filename, current.sizeBytes == original.sizeBytes,
                          current.folderID == original.folderID, current.indexedAt == original.indexedAt, current.mediaType == original.mediaType else { continue }
                    if record.regenerationRestoring.contains(original.id) {
                        // 转换已明确失败，后续清理只改变队列；缺失队列不能转成生成成功。
                        record.regenerationFailed.insert(original.id)
                        continue
                    }
                    if let before = record.regenerationBaseline[original.id], let after = current.thumbnail,
                       before.unitID == after.unitID, !before.revision.isEmpty, !after.revision.isEmpty, before.revision != after.revision {
                        // 版本变化和队列消失共同核对；不把队列空或旧缩略图单独当作完成。
                        if let finalQueue = try? await previewRegenerationQueue(in: space), !finalQueue.contains(where: { $0.unit_id == original.id.unitID }) {
                            record.regenerated.insert(original.id); record.regenerationRecovered.insert(original.id)
                        }
                    }
                }
            }
            var photos: [SynologyPhoto] = []
            for original in originals where record.regenerated.contains(original.id) {
                let photo = try await details(for: original)
                guard photo.filename == original.filename, photo.sizeBytes == original.sizeBytes,
                      photo.folderID == original.folderID, photo.indexedAt == original.indexedAt else { throw Self.failure(.conflict) }
                if record.regenerationRecovered.contains(original.id) {
                    guard let before = record.regenerationBaseline[original.id], let after = photo.thumbnail,
                          before.unitID == after.unitID, !after.revision.isEmpty, before.revision != after.revision else { throw Self.failure(.conflict) }
                }
                photos.append(photo)
            }
            try Task.checkCancellation()
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            let resolved = record.regenerated.union(record.regenerationFailed)
            let state: SynologyPhotosMutationResult.State = resolved.count != originals.count ? .pendingReview
                : (photos.count == originals.count ? .confirmed : (photos.isEmpty ? .rejected : .partial))
            result = .init(state: state, photos: photos, completedCount: photos.count)
        case .createPhotoRequest(let settings):
            if let restored = record.restoredPhotoRequest {
                result = try await inspectRestoredPhotoRequest(restored)
            } else if let id = record.photoRequestID, let request = try await findPhotoRequest(id: id), request.isFolderValid,
               photoRequestMatches(request.settings, settings), request.url != nil {
                result = .init(state: .confirmed, sharingURL: request.url, photoRequest: request)
            }
        case .updatePhotoRequest(let original, let settings):
            if let restored = record.restoredPhotoRequest {
                result = try await inspectRestoredPhotoRequest(restored)
            } else if let request = try await findPhotoRequest(id: original.id), request.isFolderValid,
               photoRequestMatches(request.settings, settings) {
                result = .init(state: .confirmed, sharingURL: request.url, photoRequest: request)
            }
        case .deletePhotoRequest(let original):
            if let restored = record.restoredPhotoRequest { result = try await inspectRestoredPhotoRequest(restored) }
            else if try await findPhotoRequest(id: original.id) == nil { result = .init(state: .confirmed) }
        case .editPhotoFaces(let photo, let changes):
            let generation = accessGeneration
            let faces = try await photoFaces(for: photo)
            var completedIDs: Set<String> = []
            for change in changes {
                switch change {
                case .remove(let original):
                    if !faces.contains(where: { $0.id == original.id }) { completedIDs.insert(change.id) }
                case .reassign(let original, let person, let name):
                    if let id = person?.id ?? record.manualPersonReceipts[change.id]?.id ?? record.restoredRecognition?.manualPersonIDs[change.id],
                       let face = faces.first(where: { $0.id == original.id }), face.personID == id, Self.matchesRecognitionName(face.name, expected: name, record: record),
                       Self.sameFaceBounds(face.bounds, original.bounds) { completedIDs.insert(change.id) }
                case .add(let addition):
                    guard let id = record.manualNewIDs[addition.temporaryID],
                          let face = faces.first(where: { $0.id == id }), face.personID > 0, Self.matchesRecognitionName(face.name, expected: addition.name, record: record),
                          addition.person == nil || face.personID == addition.person?.id,
                          Self.sameFaceBounds(face.bounds, addition.bounds), let thumbnail = face.thumbnail else { continue }
                    if record.manualUploaded.contains(id) { completedIDs.insert(change.id) }
                    else if let data = try? await image(thumbnail: thumbnail, size: nil, type: "face", space: photo.id.space), Self.matchesRecognitionImage(data, changeID: change.id, original: addition.jpeg, record: record) {
                        // 回执丢失时仅接受新编号下与本次裁剪完全一致的图像，不重复上传。
                        completedIDs.insert(change.id)
                    }
                }
            }
            let completed = completedIDs.count
            var knownFailures = record.manualKnownFailures
            if record.usesAlbumRecovery {
                for change in changes {
                    switch change {
                    case .add(let face):
                        if !record.manualAddAttempted || (record.manualAddAcknowledged && record.manualNewIDs[face.temporaryID] == nil) { knownFailures.insert(change.id) }
                        else if let id = record.manualNewIDs[face.temporaryID], !record.manualThumbnailAttempted.contains(id) { knownFailures.insert(change.id) }
                    case .remove, .reassign:
                        if !record.manualAttempted.contains(change.id) { knownFailures.insert(change.id) }
                    }
                }
            }
            if completed == changes.count || completed + knownFailures.subtracting(completedIDs).count == changes.count {
                let detail = try await details(for: photo)
                if let target = record.restoredRecognition?.targets.first, try !target.matchesIdentity(detail) { throw Self.failure(.conflict) }
                guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
                result = .init(state: completed == changes.count ? .confirmed : (completed == 0 && record.manualNewIDs.isEmpty && record.manualAcknowledged.isEmpty ? .rejected : .partial), photos: [detail], completedCount: completed)
            }
        case .setConceptCover(let original, let photo):
            let current = try await conceptState(id: original.id, in: record.mutation.space)
            if current.concept.thumbnail?.unitID == photo.id.unitID {
                result = .init(state: .confirmed, completedCount: 1, conceptVisibility: [current])
            }
        case .removeConceptItems(let original, let photos):
            let current = try await conceptState(id: original.id, in: record.mutation.space)
            let remaining = try await categoryPhotos(.concept, id: original.id, in: record.mutation.space)
            guard let count = current.concept.itemCount, current.displayThreshold != nil,
                  count == remaining.count else { break }
            let present = Set(remaining.map(\.id))
            let removed = photos.filter { !present.contains($0.id) }
            for photo in removed {
                // 分类归属消失还需确认原件身份，不能把原件同时被删除当作仅移出成功。
                let detail = try await details(for: photo)
                if let target = record.restoredRecognition?.targets.first(where: { $0.id == photo.id }) {
                    guard try target.matchesIdentity(detail) else { throw Self.failure(.conflict) }
                } else {
                    guard detail.filename == photo.filename, detail.sizeBytes == photo.sizeBytes,
                          detail.folderID == photo.folderID, detail.indexedAt == photo.indexedAt else { throw Self.failure(.conflict) }
                }
            }
            if removed.count == photos.count || (record.conceptRemovalAcknowledged && !removed.isEmpty) {
                result = .init(state: removed.count == photos.count ? .confirmed : .partial, completedCount: removed.count,
                    conceptVisibility: [current], removedFromConceptPhotoIDs: removed.map(\.id))
            }
        case .setConceptVisibility(let originals, let visible):
            let current = try await conceptVisibility(for: originals.map(\.id), in: record.mutation.space)
            let matching = current.filter { $0.isVisible == visible }
            if matching.count == originals.count {
                result = .init(state: .confirmed, completedCount: matching.count, conceptVisibility: matching)
            } else if record.visibilityAcknowledged, !matching.isEmpty {
                result = .init(state: .partial, completedCount: matching.count, conceptVisibility: matching)
            }
        case .setPeopleVisibility(let originals, let visible):
            let current = try await visibility(for: originals.map(\.id), in: record.mutation.space)
            let matching = current.filter { $0.isVisible == visible }
            if matching.count == originals.count {
                result = .init(state: .confirmed, completedCount: matching.count, personVisibility: matching)
            } else if record.visibilityAcknowledged, !matching.isEmpty {
                result = .init(state: .partial, completedCount: matching.count, personVisibility: matching)
            }
        case .removePersonFaces(let original, let faces), .reassignPersonFaces(let original, let faces, _, _):
            let photos = record.mutation.photos
            let current = try await personFaces(personID: original.id, photos: photos)
            let movedIDs = Set(faces.map(\.id))
            guard movedIDs.isDisjoint(with: Set(current.map(\.id))) else { break }
            if case .reassignPersonFaces(_, _, let target, let name) = record.mutation {
                guard let targetID = target?.id ?? record.personReceipt?.id, targetID != original.id else { break }
                let destination = try await personFaces(personID: targetID, photos: photos)
                guard faces.allSatisfy({ face in destination.contains { $0.id == face.id && $0.photo.id == face.photo.id } }) else { break }
                let details: PersonCoverList = try await call(api("Browse.Person", in: record.mutation.space), version: 1, method: "get", parameters: ["id": .integerArray([targetID])])
                guard details.list.count == 1, details.list.first?.id == targetID, details.list.first.map({ Self.matchesRecognitionName($0.name, expected: name, record: record) }) == true else { break }
            }
            let people = try await managementPeople(in: record.mutation.space)
            let remaining = people.first { $0.id == original.id }
            let stillPresent = Set(current.map { $0.photo.id })
            if record.usesAlbumRecovery {
                // 人物关联消失不能代替原件完整性检查；恢复时也要匹配原始照片身份。
                let recognition = try record.restoredRecognition ?? SynologyPhotosAlbumCheckpoint.Recognition(mutation: record.mutation)
                for target in recognition.targets {
                    let detail = try await details(for: target.queryPhoto)
                    guard try target.matchesIdentity(detail) else { throw Self.failure(.conflict) }
                }
            }
            result = .init(state: .confirmed, person: remaining ?? .init(id: original.id, name: record.restoredRecognition == nil ? original.name : "", space: original.space),
                removedPersonIDs: remaining == nil ? [original.id] : [], removedFromPersonPhotoIDs: photos.map(\.id).filter { !stillPresent.contains($0) })
        case .setPersonCover(let original, _):
            guard let receipt = record.personCoverReceipt else { break }
            let details: PersonCoverList = try await call(api("Browse.Person", in: record.mutation.space), version: 1, method: "get", parameters: ["id": .integerArray([original.id])])
            guard details.list.count == 1, details.list.first?.id == original.id, details.list.first?.cover == receipt.cover else { break }
            if let current = try await managementPeople(in: record.mutation.space).first(where: { $0.id == original.id }) {
                result = .init(state: .confirmed, person: current)
            }
        case .renamePerson(let original, let name):
            let people = try await managementPeople(in: record.mutation.space)
            if let person = people.first(where: { $0.id == original.id }), Self.matchesRecognitionName(person.name, expected: name, record: record) {
                result = .init(state: .confirmed, person: person)
            } else if Self.matchesRecognitionName("", expected: name, record: record), original.itemCount.map({ $0 < 2 }) == true,
                      record.personReceipt?.id == original.id, record.personReceipt?.name == name,
                      !people.contains(where: { $0.id == original.id }) {
                // 官方在少于两张照片的人物清空名称后重新加载；已确认回执与列表隐去共同验证。
                result = .init(state: .confirmed, person: .init(id: original.id, name: "", itemCount: original.itemCount, space: original.space), removedPersonIDs: [original.id])
            }
        case .mergePeople(let target, let sources, let name):
            let people = try await managementPeople(in: record.mutation.space)
            if let person = people.first(where: { $0.id == target.id }), Self.matchesRecognitionName(person.name, expected: name, record: record),
               sources.allSatisfy({ source in !people.contains { $0.id == source.id } }),
               let expected = record.personPhotoIDs,
               Set(try await personPhotos(target.id, in: record.mutation.space).map { $0.id.unitID }) == expected {
                result = .init(state: .confirmed, person: person, removedPersonIDs: sources.map(\.id))
            }
        case .edit(let originals, _), .addTags(let originals, _), .removeTags(let originals, _):
            let generation = accessGeneration
            let isMetadataEdit = if case .edit = record.mutation { true } else { false }
            var updated: [SynologyPhoto] = []
            for original in originals {
                if isMetadataEdit && (!record.metadataSubmittedIDs.contains(original.id) || record.metadataRejectedIDs.contains(original.id)) { continue }
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
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            _ = try mutationAccessSpace(record.mutation)
            var state: SynologyPhotosMutationResult.State = updated.count == originals.count ? .confirmed : .pendingReview
            if isMetadataEdit, state != .confirmed {
                let resolved = Set(updated.map(\.id)).union(record.metadataRejectedIDs).union(record.metadataFailureReportedIDs)
                if record.metadataSubmittedIDs.isSubset(of: resolved) {
                    state = updated.isEmpty && record.metadataRejectedIDs.count == originals.count ? .rejected : .partial
                }
            }
            result = SynologyPhotosMutationResult(state: state, photos: updated, completedCount: updated.count)
        case .shiftDates(let originals, let seconds):
            let generation = accessGeneration
            var updated: [SynologyPhoto] = []
            for original in originals where record.shiftedSubmittedIDs.contains(original.id) {
                let photo = try await details(for: original)
                guard photo.filename == original.filename, photo.sizeBytes == original.sizeBytes,
                      photo.folderID == original.folderID, photo.indexedAt == original.indexedAt else { throw Self.failure(.conflict) }
                if Int(photo.takenAt.timeIntervalSince1970) == (try shiftedTimestamp(original, seconds: seconds)) { updated.append(photo) }
            }
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            _ = try mutationAccessSpace(record.mutation)
            let confirmed = Set(updated.map(\.id))
            let resolved = confirmed.union(record.shiftedRejectedID.map { [$0] } ?? [])
            let state: SynologyPhotosMutationResult.State = updated.count == originals.count ? .confirmed
                : (record.shiftedSubmittedIDs.isSubset(of: resolved) ? .partial : .pendingReview)
            result = .init(state: state, photos: updated, completedCount: updated.count)
        case .createTag(let name, let originals, let space):
            if let tag = record.createdTag, try await verifyTag(tag, in: space) {
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
        case .createTemporaryAlbum(let name, let photos):
            if let id = record.albumID {
                let album = try await managedAlbum(id)
                if album.name == name, album.temporary_shared == true, album.owner_user_id == currentUserID,
                   try await albumMemberSnapshot(id) == Self.memberSnapshot(photos) {
                    result = .init(state: .confirmed, album: album.collection, completedCount: photos.count)
                }
            }
        case .copyTemporaryAlbum(_, let name, _):
            if let id = record.albumID, let expected = record.temporaryAlbumMembers {
                let album = try await managedAlbum(id)
                if album.name == name, album.temporary_shared == false, album.shared == false,
                   album.owner_user_id == currentUserID, try await albumMemberSnapshot(id) == expected {
                    result = .init(state: .confirmed, album: album.collection, completedCount: expected.count)
                }
            }
        case .deleteTemporaryAlbum(let id, _, _):
            let payload: ManagementAlbums = try await call("SYNO.Foto.Browse.Album", version: 4, method: "get", parameters: ["id": .integerArray([id])])
            if payload.list.isEmpty { result = .init(state: .confirmed) }
        case .createAlbum(let name, let photos):
            if let id = record.albumID {
                let album = try await managedAlbum(id)
                if album.name == name, try await verifyAlbumMembership(id, photos: photos, present: true) {
                    result = SynologyPhotosMutationResult(state: .confirmed, album: album.collection, completedCount: photos.count)
                }
            }
        case .unfreezeAlbum(let original):
            guard original.profileID == profileID, original.userID == currentUserID else { throw Self.failure(.permissionDenied) }
            let generation = accessGeneration
            let current = try await managedAlbum(original.album.id)
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            let matches = record.restoredFrozen?.matchesOriginal(current.collection) ??
                (current.name == original.album.name && current.item_count == original.album.itemCount)
            if current.freeze_album == false, current.type != "condition", current.owner_user_id == original.userID, matches {
                result = .init(state: .confirmed, album: current.collection)
            }
        case .rebuildFrozenAlbum(let original, let name, let condition):
            guard original.profileID == profileID, original.userID == currentUserID else { throw Self.failure(.permissionDenied) }
            guard let id = record.albumID, id != original.album.id else { break }
            let generation = accessGeneration
            let created = try await managedAlbum(id)
            let actualCondition = try await albumCondition(id: id)
            let matches: Bool
            if let restored = record.restoredFrozen?.rebuiltCondition {
                matches = try restored.matches(name: created.name, condition: actualCondition, userID: original.userID)
            } else { matches = try created.name == name && conditionParameters(actualCondition) == conditionParameters(condition) }
            guard generation == accessGeneration, created.owner_user_id == original.userID,
                  created.freeze_album != true, created.shared == false, matches else { break }
            let readOnly = record.restoredFrozen != nil || (record.usesAlbumRecovery && albumCheckpointWriters[operationID] == nil)
            if !record.frozenDeletionAttempted && !readOnly {
                let current: SynologyPhotoFrozenAlbum
                do { current = try await frozenAlbum(id: original.album.id) }
                catch let error as AppError where [.conflict, .permissionDenied, .invalidResponse].contains(error.category) {
                    result = .init(state: .partial, album: created.collection); break
                }
                guard current.hasSameState(as: original) else {
                    result = .init(state: .partial, album: created.collection); break
                }
                try Task.checkCancellation()
                guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
                // 新相册已核对，旧相册身份未变；先记录尝试，再发送一次删除。
                record.frozenDeletionAttempted = true
                do { try persistRecoveryCheckpoint(record, operationID: operationID) }
                catch { record.frozenDeletionAttempted = false; throw error }
                mutations[operationID] = record
                do {
                    try await managementWrite("SYNO.Foto.Browse.Album", method: "delete", parameters: ["id": .integerArray([original.album.id])])
                } catch {
                    if case DsmNetworkError.api = error { record.frozenDeletionRejected = true }
                    if let error = error as? AppError, [.permissionDenied, .authenticationRequired].contains(error.category) { record.frozenDeletionRejected = true }
                    mutations[operationID] = record
                    try persistRecoveryCheckpoint(record, operationID: operationID)
                }
            }
            let old: ManagementAlbums = try await call("SYNO.Foto.Browse.Album", version: 4, method: "get", parameters: ["id": .integerArray([original.album.id])])
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            if old.list.isEmpty { result = .init(state: .confirmed, album: created.collection) }
            else if record.frozenDeletionRejected || !record.frozenDeletionAttempted { result = .init(state: .partial, album: created.collection) }
        case .createConditionAlbum(let name, let condition):
            if let id = record.albumID {
                let album = try await managedAlbum(id)
                let current = try await albumCondition(id: id)
                let matches: Bool
                if let restored = record.restoredCondition, let user = currentUserID {
                    matches = try restored.matches(name: album.name, condition: current, userID: user)
                } else { matches = try album.name == name && conditionParameters(current) == conditionParameters(condition) }
                if matches { result = .init(state: .confirmed, album: album.collection) }
            }
        case .setAlbumCondition(let id, _, let condition):
            let current = try await albumCondition(id: id)
            let matches: Bool
            if let restored = record.restoredCondition, let user = currentUserID {
                matches = try restored.matches(name: "", condition: current, userID: user)
            } else { matches = try conditionParameters(current) == conditionParameters(condition) }
            if matches { result = .init(state: .confirmed, album: try await managedAlbum(id).collection) }
        case .renameAlbum(let id, let name):
            let album = try await managedAlbum(id)
            if album.name == name { result = SynologyPhotosMutationResult(state: .confirmed, album: album.collection) }
        case .createFolder(let parent, let name, let space):
            if let id = record.folderID {
                let payload: FolderPayload = try await call(api("Browse.Folder", in: space), version: 2, method: "get", parameters: [
                    "id": .integer(id), "additional": .stringArray(["access_permission"])])
                let folder = payload.folder
                if folder.id == id, folder.parent == parent, folder.collection.name == name,
                   canWriteFolder(folder, in: space, forUpload: space == .shared) {
                    result = .init(state: .confirmed, folder: folder.collection(in: space))
                }
            }
        case .deleteAlbum(let id):
            let payload: ManagementAlbums = try await call("SYNO.Foto.Browse.Album", version: 4, method: "get", parameters: ["id": .integerArray([id])])
            if payload.list.isEmpty { result = SynologyPhotosMutationResult(state: .confirmed) }
        case .addToAlbum(let id, let photos), .removeFromAlbum(let id, let photos):
            let present: Bool
            if case .addToAlbum = record.mutation { present = true } else { present = false }
            let members = try await albumMemberIDs(id, photos: photos)
            let completed = photos.filter { members.contains($0.id) == present }
            if completed.count == photos.count { result = .init(state: .confirmed, completedCount: photos.count) }
            else if record.albumMembershipHasFailures {
                result = .init(state: completed.isEmpty ? .rejected : .partial, photos: completed, completedCount: completed.count)
            }
        case .deleteFolderItems(let photos, let folders):
            if let taskID = record.taskID {
                result = try await inspectFolderDeletion(taskID: taskID, photos: photos, folders: folders)
            }
        case .renameFolder(let folder, let name):
            let path = try renamedFolderPath(folder, name: name)
            let expected = SynologyPhotoCollection(id: folder.id, name: name, path: path, space: folder.space)
            let current = try await readableFolder(expected)
            if canWriteFolder(current, in: folder.space, forUpload: false),
               folder.parentID == nil || folder.parentID == current.parent {
                result = .init(state: .confirmed, folder: current.collection(in: folder.space))
            }
        case .setAlbumListSort(let scope, _, let sort):
            if try await albumListSort(scope) == sort { result = .init(state: .confirmed, completedCount: 1) }
        case .setAlbumListDisplay(_, let display):
            if try await albumListDisplay() == display { result = .init(state: .confirmed, completedCount: 1) }
        case .setAlbumSort(let id, _, let sort):
            if try await readAlbumSort(id: id, requiresExplicit: true) == sort { result = .init(state: .confirmed, completedCount: 1) }
        case .setFolderSort(let folder, let sort):
            let current = try await readableFolder(folder)
            if current.sort == sort { result = .init(state: .confirmed, folder: current.collection(in: folder.space)) }
        case .setFolderCover(let folder, _):
            // 官方未返回封面项目编号：成功回执与重新可读的自定义封面共同确认；丢失回执不得猜测成功。
            if record.folderCoverAcknowledged {
                let current = try await readableFolder(folder)
                if let cover = current.additional?.thumbnail?.first(where: { $0.folder_cover_seq == 0 }) {
                    let data = try await folderCoverImage(cover, folder: current, space: folder.space)
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { throw Self.failure(.invalidResponse) }
                    result = .init(state: .confirmed, folder: current.collection(in: folder.space))
                }
            }
        case .setAlbumCover(let id, let photo):
            let album = try await managedAlbum(id)
            if album.additional?.thumbnail?.unit_id == photo.id.unitID { result = SynologyPhotosMutationResult(state: .confirmed, album: album.collection) }
        case .move(let photos, let folder, _, _, let duplicate), .copy(let photos, let folder, _, _, let duplicate):
            let generation = accessGeneration
            let crossesSpace = record.mutation.destinationSpace != record.mutation.space
            try requireAccess(record.mutation.destinationSpace)
            if let taskID = record.taskID {
                if (crossesSpace || !record.mutation.transferFolders.isEmpty) && !record.transferTargetVerified {
                    // 回执缺字段时只读用户任务列表，不重发，也不猜测跨空间后的照片编号。
                    let listed: ManagementTransferTasks = try await call("SYNO.Foto.BackgroundTask.Info", version: 1, method: "list_user_task", parameters: [:])
                    let matches = listed.list.filter { $0.id == taskID }
                    guard matches.count == 1, let task = matches.first,
                          transferTargetMatches(task, mutation: record.mutation, folderID: folder) else { break }
                    record.transferTargetVerified = true
                    record.transferTotal = task.total
                }
                let tasks: ManagementTaskList = try await call("SYNO.Foto.BackgroundTask.Info", version: 1, method: "get_status", parameters: ["id": .integerArray([taskID])])
                if tasks.list.count == 1, let task = tasks.list.first, task.id == taskID, task.status == "done" {
                    let total = record.mutation.transferFolders.isEmpty ? photos.count : record.transferTotal ?? -1
                    guard total >= 0, task.completion >= 0, task.completion <= total, task.error >= 0, task.error <= total,
                          task.skip >= 0, task.skip <= total, task.overwrite >= 0, task.overwrite <= total,
                          (duplicate == .overwrite || task.overwrite == 0),
                          task.completion == total || task.overwrite <= task.completion else { throw Self.failure(.invalidResponse) }
                    if crossesSpace || !record.mutation.transferFolders.isEmpty { try await requireManagedFolder(folder, in: record.mutation.destinationSpace, forUpload: true) }
                    if task.error > 0 || task.skip > 0 || task.completion < total {
                        result = SynologyPhotosMutationResult(state: .partial, completedCount: max(0, task.completion - task.error))
                    }
                    else {
                        // 纯照片数量固定；目录任务计数沿既有递归任务语义，不能等同顶层选择数。
                        guard !record.mutation.transferFolders.isEmpty || task.completion == total else { throw Self.failure(.invalidResponse) }
                        var updated: [SynologyPhoto] = []
                        if case .move = record.mutation, !crossesSpace {
                            for photo in photos {
                                let moved = try await details(for: photo)
                                guard moved.folderID == folder, moved.sizeBytes == photo.sizeBytes, moved.filename == photo.filename else { throw Self.failure(.conflict) }
                                updated.append(moved)
                            }
                        }
                        if case .move = record.mutation, !crossesSpace {
                            for source in record.mutation.transferFolders {
                                let moved = try await readableFolder(.init(id: source.id, name: source.name, space: source.space))
                                guard moved.parent == folder, (moved.name as NSString).lastPathComponent == source.name else { throw Self.failure(.conflict) }
                            }
                        }
                        result = SynologyPhotosMutationResult(state: .confirmed, photos: updated, completedCount: task.completion)
                    }
                }
            }
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            try requireAccess(record.mutation.space); try requireAccess(record.mutation.destinationSpace)
        case .uploadToAlbum(let source, let size, _, let albumID, _):
            let generation = accessGeneration
            if let id = record.itemID {
                let payload: ItemList = try await call("SYNO.Foto.Browse.Item", version: 5, method: "get", parameters: [
                    "id": .integerArray([id]), "album_id": .integer(albumID), "additional": .stringArray(["thumbnail", "resolution", "orientation", "provider_user_id"])])
                guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
                try requireAlbumAccess()
                guard payload.list.count == 1, let item = payload.list.first, item.id == id,
                      let owner = item.owner_user_id, owner >= 0, item.folder_id > 0 else { throw Self.failure(.invalidResponse) }
                let ignored = record.uploadAction == "ignore"
                if ignored ? item.filename == source.lastPathComponent : (item.filesize == size && item.additional?.provider_user_id == currentUserID) {
                    let photo = SynologyPhoto(id: .init(profileID: profileID, space: owner == 0 ? .shared : .personal, unitID: id),
                        filename: item.filename, sizeBytes: item.filesize, takenAt: Date(timeIntervalSince1970: item.time), indexedAt: Date(timeIntervalSince1970: item.indexed_time),
                        folderID: item.folder_id, mediaType: item.type, thumbnail: item.additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) },
                        width: item.additional?.resolution?.width, height: item.additional?.resolution?.height, orientation: item.additional?.orientation,
                        albumContext: .init(albumID: albumID, ownerUserID: owner, providerUserID: item.additional?.provider_user_id))
                    result = .init(state: .confirmed, photos: [photo], completedCount: ignored ? 0 : 1, skippedCount: ignored ? 1 : 0)
                }
            }
        case .upload(let source, let size, _, let folder, let space, _):
            if let id = record.itemID {
                let placeholder = SynologyPhoto(id: SynologyPhotoID(profileID: profileID, space: space, unitID: id), filename: "", sizeBytes: size, takenAt: .distantPast, indexedAt: .distantPast, folderID: folder ?? 0, mediaType: "")
                let uploaded = try await details(for: placeholder)
                let ignored = record.uploadAction == "ignore"
                if (ignored ? uploaded.filename == source.lastPathComponent : uploaded.sizeBytes == size), folder == nil || uploaded.folderID == folder {
                    result = SynologyPhotosMutationResult(state: .confirmed, photos: [uploaded], completedCount: ignored ? 0 : 1, skippedCount: ignored ? 1 : 0)
                }
            }
        case .shareAlbum(let id, let access, _, let members, let expiration, let password):
            let album = try await managedAlbum(id)
            let currentMembers = sharingMembers(album.additional?.sharing_info?.permission)
            let recovery = record.restoredAlbumSharing
            let expectedMembers = members ?? recovery?.previousMembers?.map(\.grant) ?? sharingMembers(record.sharingBefore?.permission)
            let membersMatch = expectedMembers.map { expected in currentMembers.map { sharingMemberRoles($0) == sharingMemberRoles(expected) } ?? false } ?? true
            let expirationMatch = expiration.map { sharingExpiration(album.additional?.sharing_info?.expiration) == $0 }
                ?? recovery.map { $0.previousExpiration.matches(album.additional?.sharing_info?.expiration) }
                ?? (album.additional?.sharing_info?.expiration == record.sharingBefore?.expiration)
            let passwordIntent = recovery?.password ?? password.map { $0.isEmpty ? .remove : .set } ?? .unchanged
            let passwordMatch: Bool
            switch passwordIntent {
            case .remove: passwordMatch = album.additional?.sharing_info?.enable_password == false
            case .set:
                // 已有密码的true状态不能证明回执丢失时的新密码生效。
                passwordMatch = record.passwordUpdateAcknowledged && album.additional?.sharing_info?.enable_password == true
            case .unchanged:
                passwordMatch = album.additional?.sharing_info?.enable_password == (recovery == nil ? record.sharingBefore?.enable_password : recovery?.previousHasPassword)
            }
            let protectionsMatch = passwordMatch && expirationMatch
            if access == .disabled, album.shared == false, (members == nil && expiration == nil && passwordIntent == .unchanged) || (membersMatch && protectionsMatch) { result = SynologyPhotosMutationResult(state: .confirmed, album: album.collection) }
            else if access != .disabled, !record.enableSharingAttempted, album.shared == false {
                result = SynologyPhotosMutationResult(state: .partial, album: album.collection)
            }
            else if membersMatch, album.shared == true, album.additional?.sharing_info?.privacy_type == (access == .invited ? "private" : "public-\(access.rawValue)"),
                    protectionsMatch,
                    let raw = album.additional?.sharing_info?.sharing_link, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil {
                result = SynologyPhotosMutationResult(state: .confirmed, album: album.collection, sharingURL: url)
            }
        }
        record.result = result
        mutations[operationID] = record
        return result
    }

    private func inspectRecoveredPhotoEdit(_ edit: SynologyPhotosAlbumCheckpoint.PhotoEdit, record: PhotosMutationRecord) async throws -> SynologyPhotosMutationResult {
        if record.result.state == .rejected { return record.result }
        let generation = accessGeneration
        var tag: SynologyPhotoFilterChoice?
        if edit.kind == .createTag {
            guard let id = edit.createdTagID, let current = try await managementTag(id, in: edit.space),
                  try edit.matchesTag(current) else { return .init(state: .pendingReview) }
            tag = current
        }
        var updated: [SynologyPhoto] = [], completed: Set<Int> = []
        for (index, target) in edit.targets.enumerated() {
            if edit.kind != .createTag && (!edit.attempted.contains(index) || edit.rejected.contains(index)) { continue }
            let photo = try await details(for: target.queryPhoto)
            guard try target.matchesIdentity(photo) else { throw Self.failure(.conflict) }
            if try edit.matchesValue(photo, target: target) { updated.append(photo); completed.insert(index) }
        }
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        _ = try mutationAccessSpace(record.mutation)
        let state: SynologyPhotosMutationResult.State
        if updated.count == edit.targets.count { state = .confirmed }
        else if edit.kind == .createTag { state = edit.tagAdditionRejected || !edit.tagAdditionAttempted ? .partial : .pendingReview }
        else if edit.attempted.isSubset(of: completed.union(edit.rejected).union(edit.reportedFailures)) {
            state = edit.rejected.count == edit.targets.count ? .rejected : .partial
        } else { state = .pendingReview }
        return .init(state: state, photos: updated, completedCount: updated.count, tag: tag)
    }

    private func verifyTag(_ tag: SynologyPhotoFilterChoice, in space: SynologyPhotoSpace) async throws -> Bool {
        try await managementTag(tag.id, in: space)?.name == tag.name
    }

    private func managementTag(_ id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoFilterChoice? {
        try requireAccess(space)
        var offset = 0
        while true {
            let payload: AlbumList = try await call(api("Browse.GeneralTag", in: space), version: 1, method: "list", parameters: [
                "offset": .integer(offset), "limit": .integer(500), "additional": .stringArray(["thumbnail"])])
            let page = payload.list
            guard page.count <= 500, page.allSatisfy({ $0.id > 0 }), Set(page.map(\.id)).count == page.count else { throw Self.failure(.invalidResponse) }
            if let match = page.first(where: { $0.id == id }) { return .init(id: match.id, name: match.name) }
            if page.count < 500 { return nil }
            offset += page.count
            try Task.checkCancellation()
        }
    }

    /// 比较完整成员身份，不将选片子集相符或同名相册当成副本完成。
    private static func memberSnapshot(_ photos: [SynologyPhoto]) -> [SynologyPhotoID: PhotosAlbumMemberSnapshot] {
        Dictionary(photos.map { ($0.id, PhotosAlbumMemberSnapshot(filename: $0.filename, size: $0.sizeBytes, folderID: $0.folderID, indexedAt: $0.indexedAt)) }, uniquingKeysWith: { first, _ in first })
    }

    private func albumMemberSnapshot(_ id: Int) async throws -> [SynologyPhotoID: PhotosAlbumMemberSnapshot] {
        var result: [SynologyPhotoID: PhotosAlbumMemberSnapshot] = [:], offset = 0
        while true {
            let page = try await photos(in: allowedSpaces.first ?? .personal, query: .album(id: id), offset: offset, limit: 500)
            guard page.offset == offset, page.nextOffset == offset + page.items.count,
                  Set(page.items.map(\.id)).count == page.items.count,
                  page.items.allSatisfy({ result[$0.id] == nil }) else { throw Self.failure(.invalidResponse) }
            result.merge(Self.memberSnapshot(page.items)) { first, _ in first }
            if !page.hasMore { return result }
            guard !page.items.isEmpty else { throw Self.failure(.invalidResponse) }
            offset = page.nextOffset
            try Task.checkCancellation()
        }
    }

    private func verifyAlbumMembership(_ id: Int, photos targets: [SynologyPhoto], present: Bool) async throws -> Bool {
        let members = try await albumMemberIDs(id, photos: targets)
        return present ? members.count == targets.count : members.isEmpty
    }

    private func albumMemberIDs(_ id: Int, photos targets: [SynologyPhoto]) async throws -> Set<SynologyPhotoID> {
        let wanted = Set(targets.map(\.id))
        var members = Set<SynologyPhotoID>(), offset = 0
        repeat {
            let page = try await photos(in: targets.first?.id.space ?? allowedSpaces.first ?? .personal, query: .album(id: id), offset: offset, limit: 500)
            members.formUnion(page.items.map(\.id).filter { wanted.contains($0) })
            if members.count == wanted.count || !page.hasMore { return members }
            offset = page.nextOffset
            try Task.checkCancellation()
        } while true
    }

}

private struct PhotosAlbumMemberSnapshot: Equatable, Sendable {
    let filename: String
    let size: Int64
    let folderID: Int
    let indexedAt: Date
}

private struct ManagementAlbums: Decodable, Sendable { let list: [ManagementAlbum] }
private struct CreatedManagementTag: Decodable, Sendable { let tag: SynologyPhotoFilterChoice }
private struct CreatedManagementAlbum: Decodable, Sendable {
    let album: Identity
    struct Identity: Decodable, Sendable { let id: Int }
}
private struct CreatedManagementFolder: Decodable, Sendable {
    let folder: Folder
    struct Folder: Decodable, Sendable { let id: Int }
}
private struct ManagementAlbum: Decodable, Sendable {
    let freeze_album: Bool?
    let cant_migrate_condition: [String: SynologyPhotoConditionValue]?
    let sort_by: String?; let sort_direction: String?
    let temporary_shared: Bool?
    let type: String?
    let id: Int; let name: String; let item_count: Int?; let owner_user_id: Int?; let shared: Bool?; let passphrase: String?
    let additional: Additional?
    struct Additional: Decodable, Sendable { let thumbnail: ItemPayload.Thumbnail?; let sharing_info: Sharing?; let condition_object: [String: SynologyPhotoConditionValue]? }
    struct Sharing: Codable, Sendable {
        let privacy_type: String?; let sharing_link: String?; let passphrase: String?
        let enable_password: Bool?; let expiration: SynologyPhotoConditionValue?; let permission: SynologyPhotoConditionValue?
    }
    var collection: SynologyPhotoCollection { SynologyPhotoCollection(id: id, name: name, itemCount: item_count, thumbnail: additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) }, isConditional: type == "condition", isFrozen: freeze_album == true) }
}
private struct ManagementLink: Decodable, Sendable { let passphrase: String? }
private struct TransferSourceInfo: Encodable { let version: Int; let source_library: String; let source_folder_ids: [Int]? }
private struct ManagementTaskReceipt: Decodable, Sendable {
    let task_info: ManagementTransferTask
}
private struct ManagementTransferTasks: Decodable, Sendable { let list: [ManagementTransferTask] }
private struct ManagementTransferTask: Decodable, Sendable {
    let id: Int
    let total: Int?
    let target_folder: Target?
    struct Target: Decodable, Sendable { let id: Int; let owner_user_id: Int }
}
private struct ManagementTaskList: Decodable, Sendable {
    let list: [TaskInfo]
    struct TaskInfo: Decodable, Sendable { let id: Int; let status: String; let completion: Int; let error: Int; let skip: Int; let overwrite: Int }
}

extension SynologyPhotosRepository {
    private func uploadPhoto(_ source: URL, size: Int64, modifiedAt: Date, folderID: Int?, space: SynologyPhotoSpace, albumID: Int? = nil, albumPassphrase: String? = nil, duplicate: SynologyPhotoDuplicateSettings.Upload, progress: @escaping FileTransferProgress) async throws -> PhotosUploadEnvelope.Receipt {
        guard let binaryTransport = transport as? any DsmBinaryHTTPTransport, let capability = capabilities[api("Upload.Item", in: space)] else { throw Self.failure(.apiUnavailable) }
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
                      "duplicate": try json(duplicate.rawValue), "name": try json(source.lastPathComponent), "mtime": String(Int(modifiedAt.timeIntervalSince1970))]
        if let albumPassphrase { fields["passphrase"] = try json(albumPassphrase); fields["folder"] = try json(["PhotoLibrary"]) }
        else if let albumID { fields["album_id"] = String(albumID); fields["folder"] = try json(["PhotoLibrary"]) }
        else if let folderID { fields["target_folder_id"] = String(folderID) }
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
        if albumID != nil { try requireAlbumAccess() } else { try requireAccess(space) }
        let response = try await binaryTransport.upload(request, from: bodyURL, progress: progress)
        guard (200...299).contains(response.statusCode) else { throw Self.failure(.invalidResponse) }
        let envelope = try JSONDecoder().decode(PhotosUploadEnvelope.self, from: response.data)
        guard envelope.success, let receipt = envelope.data, receipt.id > 0,
              receipt.action != "ignore" || duplicate == .ignore else { throw Self.failure(.invalidResponse) }
        return receipt
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
    public func frozenAlbum(id: Int) async throws -> SynologyPhotoFrozenAlbum {
        try requireAlbumAccess()
        guard id > 0 else { throw Self.failure(.invalidResponse) }
        let generation = accessGeneration
        let payload: ManagementAlbums = try await call("SYNO.Foto.Browse.Album", version: 4, method: "get", parameters: [
            "id": .integerArray([id]), "additional": .stringArray(["condition_object", "sharing_info", "thumbnail"])])
        guard generation == accessGeneration, let user = currentUserID, user > 0,
              payload.list.count == 1, let album = payload.list.first, album.id == id,
              album.owner_user_id == user else { throw Self.failure(.permissionDenied) }
        guard album.freeze_album == true else { throw Self.failure(.conflict) }
        guard let raw = album.additional?.condition_object, let unsupported = album.cant_migrate_condition,
              let shared = album.shared else { throw Self.failure(.invalidResponse) }
        let revision = try? sharingState(album).revision
        guard !shared || revision != nil else { throw Self.failure(.invalidResponse) }
        let keys = Set(SynologyPhotoConditionField.allCases.map(\.rawValue) +
            ["user_id", "folder_filter", "item_type", "time", "rating", "keyword_policy", "person_policy", "general_tag_policy", "concept_policy"])
        let fields = raw.filter { keys.contains($0.key) }
        var condition = try? normalizedCondition(fields)
        if fields["user_id"]?.integer != 0 && fields["user_id"]?.integer != user { condition = nil }
        return .init(profileID: profileID, userID: user, album: album.collection, rawCondition: raw,
                     unsupportedConditions: unsupported, rebuildCondition: condition, sharingRevision: revision, isShared: shared)
    }

    private func normalizedCondition(_ fields: [String: SynologyPhotoConditionValue]) throws -> SynologyPhotoAlbumCondition {
        var condition = SynologyPhotoAlbumCondition(fields: fields)
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

    public func albumCondition(id: Int) async throws -> SynologyPhotoAlbumCondition {
        guard !allowedSpaces.isEmpty else { throw Self.failure(.permissionDenied) }
        let generation = accessGeneration
        let album = try await managedAlbum(id)
        guard album.type == "condition", album.freeze_album != true, let user = currentUserID, album.owner_user_id == user else { throw Self.failure(.permissionDenied) }
        let payload: ConditionAlbumList = try await call("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "get", parameters: [
            "id": .integerArray([id]), "additional": .stringArray(["condition_object"])])
        guard payload.list.count == 1, let entry = payload.list.first, entry.id == id,
              generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard let sourceUser = entry.additional.condition_object["user_id"]?.integer, sourceUser == 0 || sourceUser == user else { throw Self.failure(.permissionDenied) }
        let condition = try normalizedCondition(entry.additional.condition_object)
        _ = try conditionSourceUser(in: condition.sourceSpace)
        return condition
    }

    public func conditionSuggestions(keyword: String) async throws -> [String: [SynologyPhotoConditionOption]] {
        try await conditionSuggestions(keyword: keyword, in: .personal)
    }

    public func conditionSuggestions(keyword: String, in space: SynologyPhotoSpace) async throws -> [String: [SynologyPhotoConditionOption]] {
        let user = try conditionSourceUser(in: space)
        let generation = accessGeneration
        let keys = SynologyPhotoConditionField.allCases.filter { ![.keyword, .flash].contains($0) }.map(\.rawValue)
        let raw: [String: SynologyPhotoConditionValue] = try await call("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "suggest", parameters: [
            "keyword": .string(keyword), "user_id": .integer(user), "condition": .stringArray(keys), "additional": .stringArray(["thumbnail"])])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        _ = try conditionSourceUser(in: space)
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
        let generation = accessGeneration
        struct Count: Decodable, Sendable { let count: Int }
        let result: Count = try await call("SYNO.Foto.Browse.ConditionAlbum", version: 3, method: "peek_item_count", parameters: ["condition": .object(try conditionParameters(condition))])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        _ = try conditionSourceUser(in: condition.sourceSpace)
        guard result.count >= 0 else { throw Self.failure(.invalidResponse) }
        return result.count
    }

    private func validateCondition(_ condition: SynologyPhotoAlbumCondition) async throws {
        _ = try conditionParameters(condition)
        for value in condition.values("folder_filter") {
            guard let id = value.integer, id > 0 else { throw Self.failure(.invalidResponse) }
            let folder: FolderPayload = try await call(api("Browse.Folder", in: condition.sourceSpace), version: 2, method: "get", parameters: ["id": .integer(id), "additional": .stringArray(["access_permission"])])
            guard folder.folder.id == id, folder.folder.additional?.access_permission?.view == true else { throw Self.failure(.permissionDenied) }
        }
    }

    private func conditionSourceUser(in space: SynologyPhotoSpace) throws -> Int {
        try requireAccess(space)
        guard let user = currentUserID, user > 0, space != .shared || managesSharedSpace else { throw Self.failure(.permissionDenied) }
        return space == .shared ? 0 : user
    }

    private func conditionParameters(_ condition: SynologyPhotoAlbumCondition) throws -> [String: DsmJSONValue] {
        let user = try conditionSourceUser(in: condition.sourceSpace)
        guard
              condition.fields["user_id"] == nil || condition.fields["user_id"]?.integer == user else { throw Self.failure(.permissionDenied) }
        let fields = condition.fields
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
        return try condition.canonicalFields(sourceUserID: user).mapValues(json)
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
    public func folderSharing(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoFolderSharingState {
        try requireAccess(.shared)
        let generation = accessGeneration
        guard managesSharedSpace, folder.space == .shared, folder.id > 0,
              let path = folder.path, path.hasPrefix("/"), !path.hasSuffix("/"),
              (1...2).contains(path.split(separator: "/").count) else { throw Self.failure(.permissionDenied) }
        let payload: FolderPayload = try await call("SYNO.FotoTeam.Browse.Folder", version: 2, method: "get", parameters: [
            "id": .integer(folder.id), "additional": .stringArray(["sharing_info", "access_permission"])])
        let current = payload.folder
        guard current.id == folder.id, current.name == path, current.parent > 0,
              folder.parentID == nil || current.parent == folder.parentID,
              let shared = current.shared, let info = current.additional?.sharing_info else { throw Self.failure(.conflict) }
        let access: SynologyPhotoFolderSharingState.Access
        if shared {
            guard let raw = info.privacy_type, let value = SynologyPhotoFolderSharingState.Access(rawValue: raw), value != .management else { throw Self.failure(.invalidResponse) }
            access = value
        } else { access = .management }
        var rawLink = info.sharing_link
        if rawLink?.isEmpty != false {
            guard !shared else { throw Self.failure(.invalidResponse) }
            struct Link: Decodable, Sendable { let folder_link: String }
            let link: Link = try await call("SYNO.FotoTeam.Sharing.FolderPermission", version: 1, method: "get_folder_link", parameters: ["folder_id": .integer(folder.id)])
            rawLink = link.folder_link
        }
        guard let rawLink, let url = URL(string: rawLink), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { throw Self.failure(.invalidResponse) }
        struct Config: Decodable, Sendable { let set_to_subfolder: Bool }
        let config: Config = try await call("SYNO.FotoTeam.Sharing.FolderPermission", version: 1, method: "get_config", parameters: [:])
        let parent: FolderPayload = try await call("SYNO.FotoTeam.Browse.Folder", version: 2, method: "get", parameters: ["id": .integer(current.parent)])
        guard parent.folder.id == current.parent, parent.folder.name == (path as NSString).deletingLastPathComponent,
              let parentShared = parent.folder.shared else { throw Self.failure(.conflict) }
        struct Revision: Encodable {
            let profile: UUID; let id: Int; let path: String; let parent: Int; let shared: Bool
            let info: ManagementAlbum.Sharing; let parentShared: Bool; let apply: Bool
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(Revision(profile: profileID, id: current.id, path: current.name,
            parent: current.parent, shared: shared, info: info, parentShared: parentShared, apply: config.set_to_subfolder)))
        try Task.checkCancellation()
        guard generation == accessGeneration, managesSharedSpace else { throw Self.failure(.permissionDenied) }
        try requireAccess(.shared)
        return .init(folder: current.collection(in: .shared), access: access, url: url, hasPassword: info.enable_password,
            members: sharingMembers(info.permission), parentIsShared: parentShared, appliesToSubfolders: config.set_to_subfolder,
            revision: digest.map { String(format: "%02x", $0) }.joined())
    }

    public func albumSharing(id: Int) async throws -> SynologyPhotoSharingState {
        try requireAccess(.personal)
        let album = try await managedAlbum(id)
        guard let user = currentUserID, user > 0, album.owner_user_id == user else { throw Self.failure(.permissionDenied) }
        return try sharingState(album)
    }

    public func sharingRecipients() async throws -> [SynologyPhotoShareRecipient] { try await sharingRecipients(in: .personal) }

    public func folderSharingRecipients() async throws -> [SynologyPhotoShareRecipient] {
        guard managesSharedSpace else { throw Self.failure(.permissionDenied) }
        return try await sharingRecipients(in: .shared)
    }

    private func sharingRecipients(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoShareRecipient] {
        try requireAccess(space)
        let generation = accessGeneration
        struct Payload: Decodable, Sendable { let list: [SynologyPhotoConditionValue] }
        let result: Payload = try await call("SYNO.Foto.Sharing.Misc", version: 1, method: "list_user_group", parameters: ["team_space_sharable_list": .boolean(space == .shared)])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try requireAccess(space)
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

    private func validateSharingMembers(_ members: [SynologyPhotoShareGrant], original: [SynologyPhotoShareGrant], conditional: Bool, folder: Bool = false) throws {
        guard Set(members.map(\.id)).count == members.count, Set(original.map(\.id)).count == original.count else { throw Self.failure(.invalidResponse) }
        let roles = sharingMemberRoles(original)
        for member in members {
            guard ["user", "group"].contains(member.id.type) else { throw Self.failure(.invalidResponse) }
            if roles[member.id] != member.role {
                guard (folder ? ["view", "download", "upload", "manage"] : conditional ? ["view", "download"] : ["view", "download", "upload"]).contains(member.role),
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

    /// 目录接口使用扁平成员，移除项也保留原角色；不复用相册的member嵌套格式。
    private func folderSharingMemberChanges(from original: [SynologyPhotoShareGrant]?, to desired: [SynologyPhotoShareGrant]?) throws -> [[String: DsmJSONValue]] {
        guard let desired else { return [] }
        guard let original else { throw Self.failure(.invalidResponse) }
        let before = sharingMemberRoles(original), after = sharingMemberRoles(desired)
        guard before != after else { return [] }
        func fields(_ member: SynologyPhotoShareGrant, action: String) throws -> [String: DsmJSONValue] {
            let id: DsmJSONValue
            switch member.id.value {
            case .integer(let number): id = .integer(number)
            case .string(let text): id = .string(text)
            default: throw Self.failure(.invalidResponse)
            }
            return ["id": id, "type": .string(member.id.type), "role": .string(member.role), "action": .string(action)]
        }
        return try original.filter { after[$0.id] == nil }.map { try fields($0, action: "delete") } +
            desired.map { try fields($0, action: "update") }
    }

    private func sharingExpiration(_ value: SynologyPhotoConditionValue?) -> Int? {
        switch value {
        case .integer(let seconds) where seconds >= 0: return seconds
        case .decimal(let seconds) where seconds >= 0: return Int(exactly: seconds)
        default: return nil
        }
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
        struct Revision: Encodable { let id: Int; let enabled: Bool?; let temporary: Bool?; let info: ManagementAlbum.Sharing? }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(Revision(id: album.id, enabled: album.shared, temporary: album.temporary_shared, info: info)))
        let revision = digest.map { String(format: "%02x", $0) }.joined()
        let url = info?.sharing_link.flatMap(URL.init(string:)).flatMap { value in
            ["https", "http"].contains(value.scheme?.lowercased() ?? "") && value.host != nil && value.user == nil && value.password == nil ? value : nil
        }
        let expiration = sharingExpiration(info?.expiration)
        let hasExpiration = expiration.map { $0 > 0 }
        return .init(access: access, url: access == .disabled ? nil : url, hasPassword: info?.enable_password,
            hasExpiration: hasExpiration, revision: revision, members: sharingMembers(info?.permission), expiration: expiration, isTemporary: album.temporary_shared)
    }
}


private struct PersonNameReceipt: Decodable, Sendable { let id: Int; let name: String }

extension SynologyPhotosRepository {
    public func managementPeople() async throws -> [SynologyPhotoCollection] { try await managementPeople(in: .personal) }

    public func managementPeople(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoCollection] {
        let generation = accessGeneration
        var people: [SynologyPhotoCollection] = [], seen: Set<Int> = []
        while true {
            try Task.checkCancellation()
            let page = try await categoryItems(.person, in: space, offset: people.count, limit: 500)
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            for person in page {
                guard seen.insert(person.id).inserted else { throw Self.failure(.conflict) }
                people.append(person)
            }
            if page.count < 500 { return people }
        }
    }

    private func validatePeople(_ originals: [SynologyPhotoCollection], in space: SynologyPhotoSpace) async throws {
        guard !originals.isEmpty, originals.allSatisfy({ $0.id > 0 && $0.space == space }), Set(originals.map(\.id)).count == originals.count else { throw Self.failure(.invalidResponse) }
        let current = try await managementPeople(in: space)
        for original in originals {
            guard let person = current.first(where: { $0.id == original.id }), person.name == original.name,
                  original.itemCount == nil || person.itemCount == original.itemCount else { throw Self.failure(.conflict) }
        }
    }

    private func personPhotos(_ id: Int, in space: SynologyPhotoSpace) async throws -> [SynologyPhoto] {
        try await categoryPhotos(.person, id: id, in: space)
    }

    private func categoryPhotos(_ category: SynologyPhotoCategory, id: Int, in space: SynologyPhotoSpace) async throws -> [SynologyPhoto] {
        let generation = accessGeneration
        let days = try await categoryTimeline(category, id: id, in: space)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dates = days.compactMap { calendar.date(from: DateComponents(year: $0.year, month: $0.month, day: $0.day)) }
        guard dates.count == days.count else { throw Self.failure(.invalidResponse) }
        guard let first = dates.min(), let last = dates.max() else { return [] }
        let start = max(0, Int(first.timeIntervalSince1970) - 86_400), end = Int(last.timeIntervalSince1970) + 172_800
        var items: [SynologyPhoto] = [], seen: Set<SynologyPhotoID> = [], offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await photos(in: space, query: .category(category, id: id, startTime: start, endTime: end), offset: offset, limit: 500)
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            for photo in page.items {
                guard seen.insert(photo.id).inserted else { throw Self.failure(.conflict) }
                items.append(photo)
            }
            if !page.hasMore { return items }
            offset = page.nextOffset
        }
    }
}

private struct PersonFaceList: Decodable, Sendable {
    let list: [Face]
    struct Face: Decodable, Sendable {
        let id: Int
        let additional: Additional?
        struct Additional: Decodable, Sendable { let thumbnail: Thumbnail? }
        struct Thumbnail: Decodable, Sendable { let cache_key: String }
    }
}
private struct PersonCoverReceipt: Decodable, Sendable { let id: Int; let cover: Int }
private struct PersonCoverList: Decodable, Sendable {
    let list: [Person]
    struct Person: Decodable, Sendable { let id: Int; let name: String; let cover: Int? }
}

extension SynologyPhotosRepository {
    public func personFaces(personID: Int, photos: [SynologyPhoto]) async throws -> [SynologyPhotoFace] {
        guard let space = photos.first?.id.space else { throw Self.failure(.invalidResponse) }
        try requireCategoryAccess(.person, in: space)
        guard personID > 0, !photos.isEmpty, photos.count <= 100, photos.allSatisfy({ $0.id.space == space }), Set(photos.map(\.id)).count == photos.count else { throw Self.failure(.invalidResponse) }
        let generation = accessGeneration
        var faces: [SynologyPhotoFace] = [], seen: Set<Int> = []
        for photo in photos {
            try requirePhoto(photo)
            let result: PersonFaceList = try await call(api("Browse.Person", in: space), version: 1, method: "list_face", parameters: ["person_id": .integer(personID), "item_id": .integerArray([photo.id.unitID])])
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            try Task.checkCancellation()
            for item in result.list {
                guard item.id > 0, seen.insert(item.id).inserted else { throw Self.failure(.invalidResponse) }
                let face = SynologyPhotoFace(id: item.id, personID: personID, photo: photo,
                    thumbnail: item.additional?.thumbnail.map { .init(unitID: item.id, revision: $0.cache_key) })
                faces.append(face)
            }
        }
        for face in faces { authorizedFaces[space, default: [:]][face.id] = face }
        return faces
    }

    public func thumbnail(for face: SynologyPhotoFace) async throws -> Data {
        try requirePhoto(face.photo)
        guard authorizedFaces[face.photo.id.space]?[face.id] == face, let thumbnail = face.thumbnail else { throw Self.failure(.permissionDenied) }
        return try await image(thumbnail: thumbnail, size: nil, type: "face", space: face.photo.id.space)
    }
}

/// 人物封面可以是照片缩略图，也可以直接以人物编号读取，不能强制解码unit_id。
private struct PersonEntry: Decodable, Sendable {
    let id: Int
    let name: String
    let item_count: Int?
    let show: Bool?
    let additional: Additional?
    struct Additional: Decodable, Sendable { let thumbnail: Thumbnail? }
    struct Thumbnail: Decodable, Sendable { let unit_id: Int?; let cache_key: String }
    var collection: SynologyPhotoCollection { collection(in: .personal) }
    func collection(in space: SynologyPhotoSpace) -> SynologyPhotoCollection {
        .init(id: id, name: name, itemCount: item_count,
              thumbnail: additional?.thumbnail.map { .init(unitID: $0.unit_id ?? id, revision: $0.cache_key) }, space: space)
    }
}
private struct PersonEntries: Decodable, Sendable { let list: [PersonEntry] }

private struct ConceptVisibilityList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable {
        let id: Int; let name: String; let item_count: Int?; let visibility: Bool; let display_threshold: Int?
        let additional: AlbumEntry.Additional?
        func state(in space: SynologyPhotoSpace) -> SynologyPhotoConceptVisibility {
            .init(concept: .init(id: id, name: name, itemCount: item_count,
                thumbnail: additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) }, space: space), isVisible: visibility, displayThreshold: display_threshold)
        }
    }
}

extension SynologyPhotosRepository {
    public func conceptState(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoConceptVisibility {
        guard id > 0 else { throw Self.failure(.invalidResponse) }
        let states = try await conceptVisibility(for: [id], in: space)
        guard let state = states.first else { throw Self.failure(.invalidResponse) }
        return state
    }

    public func conceptVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoConceptVisibility] {
        try requireCategoryAccess(.concept, in: space)
        let generation = accessGeneration
        var concepts: [SynologyPhotoConceptVisibility] = [], seen: Set<Int> = []
        while true {
            try Task.checkCancellation()
            let page: ConceptVisibilityList = try await call(api("Browse.Concept", in: space), version: 2, method: "list", parameters: [
                "offset": .integer(concepts.count), "limit": .integer(500), "show_hidden": .boolean(true), "additional": .stringArray(["thumbnail"])
            ])
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            guard page.list.count <= 500 else { throw Self.failure(.invalidResponse) }
            for item in page.list {
                guard item.id > 0, seen.insert(item.id).inserted else { throw Self.failure(.invalidResponse) }
                concepts.append(item.state(in: space))
            }
            if page.list.count < 500 {
                cacheConceptVisibility(concepts, in: space)
                return concepts
            }
        }
    }

    private func cacheConceptVisibility(_ entries: [SynologyPhotoConceptVisibility], in space: SynologyPhotoSpace) {
        for entry in entries {
            categoryThumbnails[space, default: [:]][.concept, default: [:]][entry.id] = entry.concept.thumbnail
        }
    }

    private func conceptVisibility(for ids: [Int], in space: SynologyPhotoSpace) async throws -> [SynologyPhotoConceptVisibility] {
        try requireCategoryAccess(.concept, in: space)
        let generation = accessGeneration
        let payload: ConceptVisibilityList = try await call(api("Browse.Concept", in: space), version: 2, method: "get", parameters: [
            "id": .integerArray(ids), "additional": .stringArray(["thumbnail"])
        ])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard payload.list.count == ids.count, Set(payload.list.map(\.id)) == Set(ids) else { throw Self.failure(.conflict) }
        let states = payload.list.map { $0.state(in: space) }
        cacheConceptVisibility(states, in: space)
        return states
    }
}


extension SynologyPhotosRepository {
    private func cachePeople(_ entries: [PersonEntry], replacing: Bool, in space: SynologyPhotoSpace = .personal) {
        if replacing { categoryThumbnails[space, default: [:]][.person] = [:]; personThumbnailTypes[space] = [:] }
        for person in entries {
            categoryThumbnails[space, default: [:]][.person, default: [:]][person.id] = person.collection(in: space).thumbnail
            personThumbnailTypes[space, default: [:]][person.id] = person.additional?.thumbnail?.unit_id == nil ? "person" : "unit"
        }
    }

    private func personPage(offset: Int, limit: Int, includingHidden: Bool, in space: SynologyPhotoSpace = .personal) async throws -> [PersonEntry] {
        try requireCategoryAccess(.person, in: space)
        let generation = accessGeneration
        var parameters: [String: DsmParameterValue] = ["offset": .integer(offset), "limit": .integer(limit), "additional": .stringArray(["thumbnail"])]
        if includingHidden { parameters["show_more"] = .boolean(true); parameters["show_hidden"] = .boolean(true) }
        let result: PersonEntries = try await call(api("Browse.Person", in: space), version: 1, method: "list", parameters: parameters)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard result.list.count <= limit, result.list.allSatisfy({ $0.id > 0 }), Set(result.list.map(\.id)).count == result.list.count else { throw Self.failure(.invalidResponse) }
        cachePeople(result.list, replacing: offset == 0, in: space)
        return result.list
    }

    public func peopleVisibility() async throws -> [SynologyPhotoPersonVisibility] { try await peopleVisibility(in: .personal) }

    public func peopleVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoPersonVisibility] {
        let generation = accessGeneration
        var people: [SynologyPhotoPersonVisibility] = [], seen: Set<Int> = []
        while true {
            try Task.checkCancellation()
            let page = try await personPage(offset: people.count, limit: 500, includingHidden: true, in: space)
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            for item in page {
                guard let show = item.show, seen.insert(item.id).inserted else { throw Self.failure(.invalidResponse) }
                people.append(.init(person: item.collection(in: space), isVisible: show))
            }
            if page.count < 500 { return people }
        }
    }

    private func visibility(for ids: [Int], in space: SynologyPhotoSpace) async throws -> [SynologyPhotoPersonVisibility] {
        try requireCategoryAccess(.person, in: space)
        let generation = accessGeneration
        let payload: PersonEntries = try await call(api("Browse.Person", in: space), version: 1, method: "get", parameters: ["id": .integerArray(ids), "additional": .stringArray(["thumbnail"])])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard payload.list.count == ids.count, Set(payload.list.map(\.id)) == Set(ids) else { throw Self.failure(.conflict) }
        let result = try payload.list.map { item in
            guard let show = item.show else { throw Self.failure(.invalidResponse) }
            return SynologyPhotoPersonVisibility(person: item.collection(in: space), isVisible: show)
        }
        cachePeople(payload.list, replacing: false, in: space)
        return result
    }
}


private struct ManualFaceList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable {
        let face_id: Int; let person_id: Int; let name: String
        let face_bounding_box: Box; let additional: Additional?
        struct Additional: Decodable, Sendable { let thumbnail: Thumbnail? }
        struct Thumbnail: Decodable, Sendable { let cache_key: String }
    }
    struct Box: Decodable, Sendable {
        let top_left: Point; let bottom_right: Point
        struct Point: Decodable, Sendable { let x: Double; let y: Double }
        var bounds: SynologyPhotoFaceBounds { .init(x: top_left.x, y: top_left.y, width: bottom_right.x - top_left.x, height: bottom_right.y - top_left.y) }
    }
}
private struct ManualFaceReceipt: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable { let face_id: Int; let face_id_temp: String }
}
private struct FaceUploadEnvelope: Decodable, Sendable {
    let success: Bool; let error: Failure?
    struct Failure: Decodable, Sendable { let code: Int }
}

extension SynologyPhotosRepository {
    public func photoFaces(for photo: SynologyPhoto) async throws -> [SynologyPhotoFaceRegion] {
        if photo.albumContext != nil { _ = try await editableAlbumPhoto(photo) }
        else { try requirePhoto(photo) }
        try requireCategoryAccess(.person, in: photo.id.space)
        let generation = accessGeneration
        let payload: ManualFaceList = try await call(api("Browse.Item", in: photo.id.space), version: 6, method: "list_face", parameters: ["id_item": .integer(photo.id.unitID), "additional": .stringArray(["thumbnail"])])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard Set(payload.list.map(\.face_id)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
        let faces: [SynologyPhotoFaceRegion] = try payload.list.map { face in
            guard face.face_id > 0, face.person_id >= 0, face.face_bounding_box.bounds.isValid else { throw Self.failure(.invalidResponse) }
            return .init(id: face.face_id, personID: face.person_id, name: face.name, bounds: face.face_bounding_box.bounds,
                thumbnail: face.additional?.thumbnail.map { .init(unitID: face.face_id, revision: $0.cache_key) })
        }
        photoFaceIDs[photo.id] = Set(faces.map(\.id))
        return faces
    }

    private static func sameFaceBounds(_ lhs: SynologyPhotoFaceBounds, _ rhs: SynologyPhotoFaceBounds) -> Bool {
        // 归一化坐标的加减转换允许浮点舍入误差，不接受不同的人脸位置。
        zip([lhs.x, lhs.y, lhs.width, lhs.height], [rhs.x, rhs.y, rhs.width, rhs.height]).allSatisfy { abs($0 - $1) < 0.000001 }
    }

    private static func manualFaceParameters(_ face: SynologyPhotoNewFace) -> [String: DsmJSONValue] {
        var values: [String: DsmJSONValue] = ["face_id_temp": .string(face.temporaryID), "face_bounding_box": .object([
            "top_left": .object(["x": .decimal(face.bounds.x), "y": .decimal(face.bounds.y)]),
            "bottom_right": .object(["x": .decimal(face.bounds.x + face.bounds.width), "y": .decimal(face.bounds.y + face.bounds.height)])])]
        if let person = face.person { values["person_id"] = .integer(person.id) } else { values["name"] = .string(face.name) }
        return values
    }

    private func uploadManualFace(_ jpeg: Data, faceID: Int, in space: SynologyPhotoSpace) async throws {
        try Task.checkCancellation()
        try requireCategoryAccess(.person, in: space)
        guard let capability = capabilities[api("Upload.Face", in: space)], capability.minVersion <= 1, capability.maxVersion >= 1 else { throw Self.failure(.apiUnavailable) }
        let generation = accessGeneration, boundary = "LanStash-Face-" + UUID().uuidString
        var body = Data()
        for (key, value) in [("api", capability.name), ("method", "upload"), ("version", "1"), ("face_id", String(faceID))] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"face.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = try DsmRequestBuilder.build(baseURL: baseURL, path: capability.path, api: capability.name, version: 1, method: "upload", requestFormat: .json, parameters: [:], credential: credential)
        request.httpBody = body; request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard (200..<300).contains(response.statusCode) else { throw DsmNetworkError.httpStatus(code: response.statusCode, requestID: UUID()) }
        let envelope = try JSONDecoder().decode(FaceUploadEnvelope.self, from: response.data)
        if let error = envelope.error { throw DsmNetworkError.api(code: error.code, requestID: UUID()) }
        guard envelope.success else { throw Self.failure(.invalidResponse) }
    }
}


private struct ConvertedPreviewUploadEnvelope: Decodable {
    let success: Bool
    let error: Failure?
    struct Failure: Decodable { let code: Int }
}

private struct AutomaticPreviewList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable {
        let unit_id: Int
        let filename: String
        let type: Int
        let need_thumbnail: SynologyPhotoConditionValue
        let need_video: SynologyPhotoConditionValue

        // 官方消费端转为布尔；只接受明确布尔或0/1，不把缺字段/任意字符串猜为关闭。
        func flag(_ value: SynologyPhotoConditionValue) -> Bool? {
            switch value {
            case .boolean(let flag): return flag
            case .integer(0): return false
            case .integer(1): return true
            default: return nil
            }
        }
    }
}

extension SynologyPhotosRepository {
    public func automaticPreviewEnabled() async throws -> Bool {
        try requireAlbumAccess()
        let generation = accessGeneration
        let settings: UserSettings = try await call("SYNO.Foto.Setting.User", version: 1, method: "get")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard let enabled = settings.auto_generate_thumbnail else { throw Self.failure(.invalidResponse) }
        return enabled
    }

    private struct AutomaticPreviewSource {
        let id: Int
        let filename: String
        let video: Bool
        let additional: ItemPayload.Additional
    }

    /// 可见项不依赖后台批次；每次重新读取原照片身份和实际目录权限。
    private func automaticPreviewSources(for photo: SynologyPhoto) async throws -> [AutomaticPreviewSource] {
        try requirePhoto(photo)
        let generation = accessGeneration
        let additional = ["thumbnail", "video_meta", "video_convert"]
        let payload: ItemList = try await call(api("Browse.Item", in: photo.id.space), version: 5, method: "get",
            parameters: ["id": .integerArray([photo.id.unitID]), "additional": .stringArray(additional)])
        guard payload.list.count == 1, let item = payload.list.first,
              item.id == photo.id.unitID, item.filename == photo.filename, item.filesize == photo.sizeBytes,
              item.folder_id == photo.folderID, item.type == photo.mediaType,
              item.indexed_time == photo.indexedAt.timeIntervalSince1970 else { throw Self.failure(.conflict) }
        guard let owner = item.owner_user_id,
              photo.id.space == .shared ? owner == 0 : (owner > 0 && owner == currentUserID) else { throw Self.failure(.permissionDenied) }
        if photo.id.space == .shared && !managesSharedSpace {
            let folder = try await readableFolder(.init(id: item.folder_id, name: "", space: .shared))
            guard folder.additional?.access_permission?.download == true else { throw Self.failure(.permissionDenied) }
        }
        var sources: [AutomaticPreviewSource] = []
        if item.type == "live" {
            let units: UnitPayload = try await call(api("Browse.Unit", in: photo.id.space), version: 1, method: "get",
                parameters: ["id_item": .integerArray([item.id]), "additional": .stringArray(["orientation", "resolution"] + additional)])
            guard units.list.count == 1, let entry = units.list.first, entry.id_item == item.id,
                  !entry.unit.isEmpty, Set(entry.unit.map(\.id)).count == entry.unit.count else { throw Self.failure(.invalidResponse) }
            for unit in entry.unit {
                guard unit.id > 0, ["photo", "video"].contains(unit.live_type), let filename = unit.filename, !filename.isEmpty,
                      let info = unit.additional, info.thumbnail?.unit_id == unit.id else { throw Self.failure(.invalidResponse) }
                sources.append(.init(id: unit.id, filename: filename, video: unit.live_type == "video", additional: info))
            }
        } else {
            guard let info = item.additional, let thumbnail = info.thumbnail, thumbnail.unit_id > 0,
                  photo.thumbnail == nil || photo.thumbnail?.unitID == thumbnail.unit_id else { throw Self.failure(.conflict) }
            sources.append(.init(id: thumbnail.unit_id, filename: item.filename,
                                 video: ["video", "video360"].contains(item.type), additional: info))
        }
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        return sources
    }

    public func automaticPreviewTasks(for photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport) async throws -> [SynologyPhotoAutomaticPreviewTask] {
        guard support.hevc || support.video else { return [] }
        let sources = try await automaticPreviewSources(for: photo)
        return sources.compactMap { source in
            let codec = source.additional.video_meta?.video_codec
            let heic = !source.video && ["heic", "heif", "hif"].contains((source.filename as NSString).pathExtension.lowercased())
            if (heic || (source.video && codec == "hevc")) && !support.hevc { return nil }
            if source.video && (!support.video || (["vc1", "wmv3"].contains(codec ?? "") && !support.vc1)) { return nil }
            let thumbnail = source.additional.thumbnail
            let needsThumbnail = thumbnail?.xl == "ame_defect" || thumbnail?.sm == "ame_defect"
            let needsVideo = source.video && support.video && source.additional.video_convert_status == "ame_defect"
            guard needsThumbnail || needsVideo else { return nil }
            let priority: SynologyPhotoAutomaticPreviewPriority = source.video && ["vc1", "wmv3"].contains(codec ?? "") ? .vc1 :
                (source.video && (codec == "hevc" || photo.mediaType == "live") ? .hevcOrLiveVideo : .standard)
            return .init(profileID: profileID, space: photo.id.space, unitID: source.id, filename: source.filename,
                         typeCode: source.video ? 1 : 0, needsThumbnail: needsThumbnail, needsVideo: needsVideo, sourcePhoto: photo, priority: priority)
        }
    }

    private func validateAutomaticPreview(_ task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport) async throws {
        guard task.profileID == profileID, task.unitID > 0, task.needsThumbnail || task.needsVideo,
              !task.needsVideo || (task.typeCode != 0 && support.video),
              transport is any DsmBinaryHTTPTransport else { throw Self.failure(.invalidResponse) }
        let candidates: [SynologyPhotoAutomaticPreviewTask]
        if let photo = task.sourcePhoto { candidates = try await automaticPreviewTasks(for: photo, support: support) }
        else { candidates = try await automaticPreviewTasks(in: task.space, support: support) }
        guard candidates.contains(task) else { throw Self.failure(.conflict) }
    }

    private func performAutomaticPreview(_ task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport,
        operationID: UUID, record: inout PhotosMutationRecord, progress: @escaping FileTransferProgress) async throws {
        let generation = accessGeneration
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try PhotosPreviewTemporaryFiles.createDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        // AVFoundation识别部分容器依赖扩展名，临时文件保留格式但不使用真实文件名。
        let source = directory.appendingPathComponent("source").appendingPathExtension((task.filename as NSString).pathExtension)
        try await downloadAutomaticPreviewSource(task, support: support, to: source, progress: progress)
        try PhotosPreviewTemporaryFiles.protect(source)
        var thumbnail: PhotosConvertedPreview?
        if task.needsThumbnail {
            do { thumbnail = try await SynologyPhotosPreviewConverter.convert(file: source, mediaType: task.typeCode == 0 ? "photo" : "video") }
            catch {
                guard SynologyPhotosPreviewConverter.shouldRecordFailure(error) else { throw error }
                try await recordAutomaticPreviewFailure(task, kind: .photo, support: support, generation: generation, operationID: operationID, record: &record)
                return
            }
        }
        var video: URL?
        if task.needsVideo {
            let output = directory.appendingPathComponent("preview.mp4")
            do {
                try await SynologyPhotosPreviewConverter.video(file: source, to: output)
                try PhotosPreviewTemporaryFiles.protect(output)
                record.automaticVideoSignature = try await SynologyPhotosPreviewConverter.videoSignature(file: output)
            } catch {
                guard SynologyPhotosPreviewConverter.shouldRecordFailure(error) else { throw error }
                try await recordAutomaticPreviewFailure(task, kind: .video, support: support, generation: generation, operationID: operationID, record: &record)
                return
            }
            video = output
        }
        if let thumbnail {
            record.automaticThumbnailDigests = ["xl": Data(SHA256.hash(data: thumbnail.large)),
                "sm": Data(SHA256.hash(data: thumbnail.small)), "m": Data(SHA256.hash(data: thumbnail.medium))]
        }
        let name = api("Upload.ConvertedFile", in: task.space)
        guard let binary = transport as? any DsmBinaryHTTPTransport, let capability = capabilities[name],
              capability.minVersion <= 3, capability.maxVersion >= 3, capability.requestFormat == .json else { throw Self.failure(.apiUnavailable) }
        let boundary = "LanStash-Preview-" + UUID().uuidString
        let body = directory.appendingPathComponent("upload")
        let length = try Self.writeAutomaticPreviewBody(to: body, boundary: boundary, api: name, unitID: task.unitID, thumbnail: thumbnail, video: video)
        try PhotosPreviewTemporaryFiles.protect(body)
        var request = try DsmRequestBuilder.build(baseURL: baseURL, path: capability.path, api: name, version: 3, method: "upload", requestFormat: .json, parameters: [:], credential: credential)
        request.httpBody = nil
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(String(length), forHTTPHeaderField: "Content-Length")
        // 转换可能耗时较长，提交前重新核对候选，旧候选不能覆盖其他客户端刚生成的结果。
        try await validateAutomaticPreview(task, support: support)
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        record.automaticPreviewSubmitted = true
        do { try persistRecoveryCheckpoint(record, operationID: operationID) }
        catch { record.automaticPreviewSubmitted = false; throw error }
        mutations[operationID] = record
        let response = try await binary.upload(request, from: body, progress: progress)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard (200..<300).contains(response.statusCode) else { throw Self.failure(.invalidResponse) }
        let envelope = try JSONDecoder().decode(ConvertedPreviewUploadEnvelope.self, from: response.data)
        guard envelope.success ? envelope.error == nil : envelope.error != nil else { throw Self.failure(.invalidResponse) }
        // 此接口同步保存转换结果；明确失败可结束，回执不明只能读取核对，不能重放。
        record.automaticPreviewAcknowledged = envelope.success
        if !envelope.success { record.result = .init(state: .rejected) }
    }

    private func recordAutomaticPreviewFailure(_ task: SynologyPhotoAutomaticPreviewTask, kind: PhotosPreviewFailureKind,
        support: SynologyPhotoPreviewConversionSupport, generation: Int, operationID: UUID, record: inout PhotosMutationRecord) async throws {
        // 仅标记本次明确失败的阶段；长转换后重新校对候选、身份与权限，不能覆盖已生成结果。
        try Task.checkCancellation()
        try await validateAutomaticPreview(task, support: support)
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        record.automaticFailureKind = kind
        do { try persistRecoveryCheckpoint(record, operationID: operationID) }
        catch { record.automaticFailureKind = nil; throw error }
        mutations[operationID] = record
        try await managementWrite(api("Upload.ConvertedFile", in: task.space), version: 3, method: "set_broken",
            parameters: ["id": .integerArray([task.unitID]), "type": .stringArray([kind.rawValue])])
        record.automaticFailureAcknowledged = true
    }

    private static func writeAutomaticPreviewBody(to url: URL, boundary: String, api: String, unitID: Int,
        thumbnail: PhotosConvertedPreview?, video: URL?) throws -> UInt64 {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Self.failure(.invalidResponse) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        func write(_ text: String) throws { try output.write(contentsOf: Data(text.utf8)) }
        for (key, value) in [("api", api), ("method", "upload"), ("version", "3"), ("unit_id", String(unitID))] {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n")
        }
        if let thumbnail {
            for (key, data) in [("thumb_xl", thumbnail.large), ("thumb_sm", thumbnail.small), ("thumb_m", thumbnail.medium)] {
                try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"; filename=\"\(key).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n")
                try output.write(contentsOf: data); try write("\r\n")
            }
        }
        if let video {
            try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"film_h264\"; filename=\"preview.mp4\"\r\nContent-Type: video/mp4\r\n\r\n")
            let input = try FileHandle(forReadingFrom: video)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try write("\r\n")
        }
        try write("--\(boundary)--\r\n")
        try output.synchronize()
        return try output.offset()
    }

    private func automaticPreviewMatches(_ task: SynologyPhotoAutomaticPreviewTask, record: PhotosMutationRecord) async throws -> Bool {
        guard record.automaticPreviewSubmitted, let binary = transport as? any DsmBinaryHTTPTransport else { return false }
        let generation = accessGeneration
        // 列表只是一批待处理项目，消失不能证明成功；读取媒体并与本次上传内容比较。
        for size in ["xl", "sm", "m"] where task.needsThumbnail {
            let data = try await image(thumbnail: .init(unitID: task.unitID, revision: ""), size: size, space: task.space)
            guard Data(SHA256.hash(data: data)) == record.automaticThumbnailDigests[size] else { return false }
        }
        if task.needsVideo {
            guard let expected = record.automaticVideoSignature else { return false }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try PhotosPreviewTemporaryFiles.createDirectory(directory)
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("review.mov")
            let request = try mediaRequest(api("Streaming", in: task.space), method: "streaming", parameters: [
                "id": .integer(task.unitID), "type": .string("unit"), "quality": .string("orig_h264"), "use_mov": .boolean(true)])
            let response = try await binary.download(request, to: file, progress: { _, _ in })
            try PhotosPreviewTemporaryFiles.protect(file)
            guard response.statusCode == 200, try await SynologyPhotosPreviewConverter.videoSignature(file: file) == expected else { return false }
        }
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        return true
    }

    public func downloadAutomaticPreviewSource(_ task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        try Task.checkCancellation()
        guard task.profileID == profileID, task.unitID > 0, destination.isFileURL,
              let binary = transport as? any DsmBinaryHTTPTransport else { throw Self.failure(.invalidResponse) }
        let generation = accessGeneration
        try await validateAutomaticPreview(task, support: support)
        guard generation == accessGeneration else { throw Self.failure(.conflict) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let staging = directory.appendingPathComponent("source")
        let request = try mediaRequest(api("Download", in: task.space), method: "download", parameters: ["unit_id": .integerArray([task.unitID])])
        let response = try await binary.download(request, to: staging, progress: progress)
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard response.statusCode == 200 else { throw DsmErrorMapper.map(.httpStatus(code: response.statusCode, requestID: UUID())) }
        let contentType = response.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        guard !contentType.contains("json"), !contentType.contains("html"), !contentType.contains("zip"),
              let size = (try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value,
              size > 0 else { throw Self.failure(.invalidResponse) }
        if let length = response.headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            guard Int64(length) == size else { throw Self.failure(.invalidResponse) }
        }
        // 按原候选来源再次核对身份、权限和需求，不以同名项目或Item编号追认。
        try await validateAutomaticPreview(task, support: support)
        guard generation == accessGeneration else { throw Self.failure(.conflict) }
        try Task.checkCancellation()
        try await DownloadedFileExporter.export(from: staging, to: destination, replaceExisting: false)
    }

    public func automaticPreviewTasks(in space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport) async throws -> [SynologyPhotoAutomaticPreviewTask] {
        try Task.checkCancellation()
        try requireAccess(space)
        // 官方后台扫描共享空间要求管理权；可下载单个目录不等于可扫描整个空间。
        guard space != .shared || managesSharedSpace else { throw Self.failure(.permissionDenied) }
        guard support.hevc || support.video else { return [] }
        let generation = accessGeneration
        let preset = support.vc1 ? (support.hevc ? "windows" : "windows2") : "macos"
        let payload: AutomaticPreviewList = try await call(api("Upload.ConvertedFile", in: space), version: 3, method: "list_convert_needed",
            parameters: ["type": .stringArray(support.hevc ? ["photo", "video", "live_video"] : ["video"]), "preset": .string(preset)])
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard Set(payload.list.map(\.unit_id)).count == payload.list.count,
              payload.list.allSatisfy({ $0.unit_id > 0 && !$0.filename.isEmpty && $0.type >= 0 }) else { throw Self.failure(.invalidResponse) }
        return try payload.list.map { entry in
            guard let thumbnail = entry.flag(entry.need_thumbnail), let video = entry.flag(entry.need_video) else { throw Self.failure(.invalidResponse) }
            return .init(profileID: profileID, space: space, unitID: entry.unit_id, filename: entry.filename, typeCode: entry.type,
                         needsThumbnail: thumbnail, needsVideo: video)
        }
    }

    private func previewRegenerationQueue(in space: SynologyPhotoSpace) async throws -> [PreviewRegeneratingList.Entry] {
        try requireAccess(space)
        guard await managementFeatures(in: space).contains(.previewRegeneration) else { throw Self.failure(.apiUnavailable) }
        let generation = accessGeneration
        let queue: PreviewRegeneratingList = try await call(api("RegeneratePreview", in: space), version: 1, method: "list_regenerating")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        try Task.checkCancellation()
        guard Set(queue.list.map(\.unit_id)).count == queue.list.count,
              queue.list.allSatisfy({ $0.unit_id > 0 && !$0.filename.isEmpty && ["photo", "video", "live"].contains($0.type) }) else { throw Self.failure(.invalidResponse) }
        return queue.list
    }

    private func requireQueuedPreview(_ photo: SynologyPhoto, queue: [PreviewRegeneratingList.Entry]) throws {
        guard queue.contains(where: { $0.unit_id == photo.id.unitID && $0.filename == photo.filename && $0.type == photo.mediaType }) else { throw Self.failure(.conflict) }
    }

    public func pendingPreviewRegenerations(in space: SynologyPhotoSpace) async throws -> [SynologyPhoto] {
        let generation = accessGeneration
        let queue = try await previewRegenerationQueue(in: space)
        var result: [SynologyPhoto] = []
        for entry in queue {
            try Task.checkCancellation()
            let payload: ItemList = try await call(api("Browse.Item", in: space), version: 5, method: "get", parameters: [
                "id": .integerArray([entry.unit_id]), "additional": .stringArray(["thumbnail", "resolution", "orientation"])])
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            guard payload.list.count == 1, let item = payload.list.first, item.id == entry.unit_id,
                  item.filename == entry.filename, item.type == entry.type, item.filesize >= 0, item.folder_id > 0 else { throw Self.failure(.conflict) }
            let photo = SynologyPhoto(id: .init(profileID: profileID, space: space, unitID: item.id), filename: item.filename, sizeBytes: item.filesize,
                takenAt: Date(timeIntervalSince1970: item.time), indexedAt: Date(timeIntervalSince1970: item.indexed_time), folderID: item.folder_id, mediaType: item.type,
                thumbnail: item.additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) },
                width: item.additional?.resolution?.width, height: item.additional?.resolution?.height, orientation: item.additional?.orientation)
            try requirePhoto(photo)
            try await requirePreviewFolder(photo.folderID, in: space)
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            result.append(photo)
        }
        return result
    }

    /// 重建预览不改变原件；相册提供者和普通共享目录下载者有独立资格。
    private func requirePreviewPhoto(_ photo: SynologyPhoto) throws {
        try requireAccess(photo.id.space)
        try requireReadablePhoto(photo)
        guard pendingDeletions[photo.id] == nil else { throw Self.failure(.permissionDenied) }
    }

    private func requirePreviewFolder(_ id: Int, in space: SynologyPhotoSpace) async throws {
        guard id > 0 else { throw Self.failure(.invalidResponse) }
        if space == .personal { try await requireManagedFolder(id, in: space); return }
        let payload: FolderPayload = try await call(api("Browse.Folder", in: space), version: 2, method: "get", parameters: [
            "id": .integer(id), "additional": .stringArray(["access_permission"])])
        let access = payload.folder.additional?.access_permission
        guard payload.folder.id == id, managesSharedSpace ||
            (access?.view == true && (access?.manage == true || access?.download == true)) else { throw Self.failure(.permissionDenied) }
    }

    private func validatePreviewRegenerationTarget(_ photo: SynologyPhoto) async throws -> SynologyPhotoThumbnail? {
        try requirePreviewPhoto(photo)
        let generation = accessGeneration
        var parameters: [String: DsmParameterValue] = ["id": .integerArray([photo.id.unitID]), "additional": .stringArray(["thumbnail"])]
        if photo.albumContext != nil { parameters["additional"] = .stringArray(["thumbnail", "provider_user_id"]) }
        let payload: DeletionItemList = try await call(readAPI("Browse.Item", for: photo), version: 5, method: "get", parameters: readParameters(for: photo, parameters))
        guard payload.list.count == 1, let item = payload.list.first, item.matches(photo) else { throw Self.failure(.conflict) }
        if let context = photo.albumContext {
            guard item.owner_user_id == context.ownerUserID else { throw Self.failure(.conflict) }
            let album = try await managedAlbum(context.albumID)
            guard let user = currentUserID, user > 0 else { throw Self.failure(.permissionDenied) }
            if item.additional?.provider_user_id != user {
                // 相册下载权不能代替原目录管理权；共享原件管理者仍可维护预览。
                if photo.id.space == .personal {
                    guard album.type == "condition" || album.freeze_album == true,
                          context.ownerUserID == user else { throw Self.failure(.permissionDenied) }
                }
                try await requireManagedFolder(photo.folderID, in: photo.id.space)
            }
        } else { try await requirePreviewFolder(photo.folderID, in: photo.id.space) }
        try Task.checkCancellation()
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        return item.additional?.thumbnail.map { .init(unitID: $0.unit_id, revision: $0.cache_key) }
    }

    private func preparePreviewRegeneration(_ photo: SynologyPhoto, resuming: Bool, generation: Int,
                                            record: inout PhotosMutationRecord, operationID: UUID) async throws {
        if !resuming {
            record.regenerationMarking.insert(photo.id)
            do { try persistRecoveryCheckpoint(record, operationID: operationID) }
            catch { record.regenerationMarking.remove(photo.id); throw error }
        }
        if resuming {
            try requirePreviewPhoto(photo)
            let queue = try await previewRegenerationQueue(in: photo.id.space)
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            try requireQueuedPreview(photo, queue: queue)
        } else { try await markPreviewRegenerating(photo, generation: generation) }
        record.regenerationMarked.insert(photo.id)
        try persistRecoveryCheckpoint(record, operationID: operationID)
    }

    private func recordPreviewSubmission(_ photo: SynologyPhoto, record: inout PhotosMutationRecord, operationID: UUID) throws {
        let inserted = record.regenerationSubmitted.insert(photo.id).inserted
        do { try persistRecoveryCheckpoint(record, operationID: operationID) }
        catch { if inserted { record.regenerationSubmitted.remove(photo.id) }; throw error }
    }

    private func recordPreviewRestoration(_ photo: SynologyPhoto, record: inout PhotosMutationRecord, operationID: UUID) throws {
        record.regenerationRestoring.insert(photo.id)
        do { try persistRecoveryCheckpoint(record, operationID: operationID) }
        catch { record.regenerationRestoring.remove(photo.id); throw error }
    }

    private func markPreviewRegenerating(_ photo: SynologyPhoto, generation: Int) async throws {
        try Task.checkCancellation(); try requirePreviewPhoto(photo)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        let queue: PreviewRegeneratingList = try await call(api("RegeneratePreview", in: photo.id.space), version: 1,
            method: "set_regenerating", parameters: ["item_id": .integerArray([photo.id.unitID])])
        guard queue.list.count == 1, let target = queue.list.first, target.unit_id == photo.id.unitID,
              target.filename == photo.filename, target.type == photo.mediaType else { throw Self.failure(.invalidResponse) }
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
    }

    private func prepareLocalPreview(_ photo: SynologyPhoto, generation: Int) async throws -> PhotosConvertedPreview? {
        let name = api("Upload.ConvertedFile", in: photo.id.space)
        guard let capability = capabilities[name], capability.minVersion <= 3, capability.maxVersion >= 3,
              ["photo", "video"].contains(photo.mediaType) else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: directory.path)
        var protectedDirectory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        #endif
        let source = directory.appendingPathComponent("source")
        let converted: PhotosConvertedPreview
        do {
            try await downloadOriginal(photo, to: source) { _, _ in }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: source.path)
            #endif
            converted = try await SynologyPhotosPreviewConverter.convert(file: source, mediaType: photo.mediaType)
        } catch {
            // 读取/解码失败尚未上传，可以继续其他转换方式；取消不能变成后续写请求。
            try Task.checkCancellation()
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            return nil
        }
        try Task.checkCancellation(); try requirePreviewPhoto(photo)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        // 转换可能耗时，发送生成内容前再次核对原件和对应角色资格。
        _ = try await validatePreviewRegenerationTarget(photo)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        return converted
    }

    private func uploadConvertedPreview(_ converted: PhotosConvertedPreview, photo: SynologyPhoto, generation: Int) async throws -> Bool {
        try Task.checkCancellation(); try requirePreviewPhoto(photo)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        let name = api("Upload.ConvertedFile", in: photo.id.space)
        guard let capability = capabilities[name], capability.minVersion <= 3, capability.maxVersion >= 3 else { throw Self.failure(.apiUnavailable) }
        let boundary = "LanStash-Preview-" + UUID().uuidString
        var body = Data()
        for (key, value) in [("api", name), ("method", "upload"), ("version", "3"), ("unit_id", String(photo.id.unitID))] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8))
        }
        for (key, data) in [("thumb_xl", converted.large), ("thumb_sm", converted.small), ("thumb_m", converted.medium)] {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"; filename=\"\(key).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
            body.append(data); body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        var request = try DsmRequestBuilder.build(baseURL: baseURL, path: capability.path, api: name, version: 3, method: "upload", requestFormat: .json, parameters: [:], credential: credential)
        request.httpBody = body; request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request)
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard (200..<300).contains(response.statusCode) else { throw Self.failure(.invalidResponse) }
        let envelope = try JSONDecoder().decode(ConvertedPreviewUploadEnvelope.self, from: response.data)
        guard envelope.success ? envelope.error == nil : envelope.error != nil else { throw Self.failure(.invalidResponse) }
        // 官方转换上传为同步结果；断网/畸形回执抛出后保留未知，不重传也不改发其他转换。
        return envelope.success
    }
}

private struct AlbumPermissionPayload: Decodable, Sendable {
    let permission: Permission
    struct Permission: Decodable, Sendable { let download: Bool?; let upload: Bool? }
}

private extension SynologyPhotosMutation {
    var isAddingAlbumMembers: Bool {
        switch self {
        case .addToAlbum, .createAlbum, .createTemporaryAlbum: true
        default: false
        }
    }

    var isAlbumCollaboration: Bool {
        switch self {
        case .addToAlbum, .removeFromAlbum, .uploadToAlbum: true
        default: false
        }
    }
}

private struct AlbumMembershipReceipt: Decodable, Sendable {
    let error_list: [SynologyPhotoConditionValue]?
}


extension SynologyPhotosRepository {
    /// 统一用户任务入口；不依赖当前个人/共享图库选择。
    public func backgroundTasks() async throws -> [SynologyPhotoBackgroundTask] {
        try requireAlbumAccess()
        guard let user = currentUserID, user > 0 else { throw Self.failure(.permissionDenied) }
        let generation = accessGeneration
        let payload: PhotosBackgroundTaskList = try await call("SYNO.Foto.BackgroundTask.Info", version: 1, method: "list_user_task")
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        guard Set(payload.list.map(\.id)).count == payload.list.count else { throw Self.failure(.invalidResponse) }
        return try payload.list.map { value in
            guard value.id > 0, value.total >= 0, value.completion >= 0, value.completion <= value.total,
                  value.error >= 0, value.error <= value.completion, value.skip >= 0, value.skip <= value.total,
                  value.overwrite >= 0, value.overwrite <= value.total, value.create_time.isFinite,
                  value.create_time >= 0 else { throw Self.failure(.invalidResponse) }
            return .init(profileID: profileID, userID: user, id: value.id, operation: value.operation,
                status: .init(rawValue: value.status) ?? .unknown, total: value.total, completion: value.completion,
                errors: value.error, skipped: value.skip, overwritten: value.overwrite, createdAt: value.create_time,
                targetFolderID: value.target_folder?.id, targetOwnerID: value.target_folder?.owner_user_id)
        }
    }

    private func currentBackgroundTask(_ original: SynologyPhotoBackgroundTask) async throws -> SynologyPhotoBackgroundTask {
        guard original.profileID == profileID, original.userID == currentUserID else { throw Self.failure(.permissionDenied) }
        guard let current = try await backgroundTasks().first(where: { $0.id == original.id }),
              current.hasSameIdentity(as: original) else { throw Self.failure(.conflict) }
        return current
    }

    public func backgroundTaskErrors(_ task: SynologyPhotoBackgroundTask) async throws -> [SynologyPhotoBackgroundTaskError] {
        let generation = accessGeneration
        let current = try await currentBackgroundTask(task)
        guard current.errors > 0 else { return [] }
        let payload: PhotosBackgroundErrorList = try await call("SYNO.Foto.BackgroundTask.Info", version: 1, method: "get_error_detail", parameters: ["id": .integer(task.id)])
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        let result = try payload.list.map { value -> SynologyPhotoBackgroundTaskError in
            guard value.id > 0 else { throw Self.failure(.invalidResponse) }
            return .init(kind: .init(rawValue: value.type) ?? .unknown, itemID: value.id,
                         reason: .init(rawValue: value.reason) ?? .unknown)
        }
        guard Set(result.map(\.id)).count == result.count else { throw Self.failure(.invalidResponse) }
        // 沿官方任务library选择详情路由；权限不足或原件消失时仍保留错误原因。
        guard let space = current.targetSpace, allowedSpaces.contains(space) else { return result }
        var names: [String: (String, String?)] = [:]
        let itemIDs = result.filter { $0.kind == .item }.map(\.itemID)
        for offset in stride(from: 0, to: itemIDs.count, by: 100) {
            try Task.checkCancellation()
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            let ids = Array(itemIDs[offset..<min(offset + 100, itemIDs.count)])
            do {
                let items: PhotosBackgroundErrorItems = try await call(api("Browse.Item", in: space), version: 5, method: "get",
                    parameters: ["id": .integerArray(ids), "additional": .stringArray(["folder"])])
                guard Set(items.list.map(\.id)).count == items.list.count,
                      items.list.allSatisfy({ ids.contains($0.id) }) else { throw Self.failure(.invalidResponse) }
                for item in items.list { names["item:\(item.id)"] = (item.filename, item.additional?.folder) }
            } catch is CancellationError { throw CancellationError() }
            catch { /* 补充名称失败不能隐藏已取得的任务错误。 */ }
        }
        for entry in result where entry.kind == .folder {
            try Task.checkCancellation()
            guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
            do {
                let folder = try await folder(id: entry.itemID, in: space)
                names[entry.id] = (folder.name, folder.path.map { ($0 as NSString).deletingLastPathComponent })
            } catch is CancellationError { throw CancellationError() }
            catch { /* 目录已不存在或不可读时保留错误记录。 */ }
        }
        guard generation == accessGeneration else { throw Self.failure(.permissionDenied) }
        return result.map { entry in
            .init(kind: entry.kind, itemID: entry.itemID, reason: entry.reason,
                  name: names[entry.id]?.0, folderPath: names[entry.id]?.1)
        }
    }
}

private struct PhotosBackgroundErrorItems: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable {
        let id: Int; let filename: String; let additional: Additional?
        struct Additional: Decodable, Sendable { let folder: String? }
    }
}

private struct PhotosBackgroundTaskList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable {
        let id: Int
        let operation: String
        let status: String
        let total: Int
        let completion: Int
        let error: Int
        let skip: Int
        let overwrite: Int
        let create_time: Double
        let target_folder: Target?
        struct Target: Decodable, Sendable { let id: Int; let owner_user_id: Int }
    }
}
private struct PhotosBackgroundErrorList: Decodable, Sendable {
    let list: [Entry]
    struct Entry: Decodable, Sendable { let type: String; let id: Int; let reason: String }
}
