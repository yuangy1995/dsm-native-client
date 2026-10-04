#if DEBUG
import DsmCore
import Foundation

/// Photos 管理与恢复的合成服务；不持有连接、凭据或真实媒体。
actor MobilePhotosUIService: SynologyPhotosServing {
    nonisolated let profileID: UUID
    let state: String
    private(set) var commands: [SynologyPhotosMutation] = []
    private(set) var reviews = 0
    private var records: [UUID: SynologyPhotosUploadCheckpoint] = [:]
    private var albumRecords: [UUID: SynologyPhotosAlbumCheckpoint] = [:]
    private var albumList: [SynologyPhotoCollection] = [.init(id: 21, name: "Sample album")]
    private var members: [Int: Set<Int>] = [21: [1, 2]]
    private var rejectsAlbum = true
    private var rejectsSharing = true
    private var temporaryAlbumIDs: Set<Int> = []
    private var requestList: [SynologyPhotoRequest] = []
    private var heldRequest: CheckedContinuation<Void, Never>?
    private(set) var isRequestHeld = false
    private var sharingValue = SynologyPhotoSharingState(access: .disabled, hasPassword: true, hasExpiration: false, revision: "original", members: [], expiration: 0, isTemporary: false)
    private var pending: Bool
    private var nextID = 100
    private var userID = 12
    private var deniesWrites = false
    private var uploaded: [SynologyPhoto] = []
    private var heldUpload: CheckedContinuation<Void, Never>?
    private(set) var isUploadHeld = false

    init(profileID: UUID = UUID(), state: String = "photo-upload") {
        self.profileID = profileID; self.state = state
        pending = ["photo-unknown", "photo-albums-unknown", "photo-sharing-unknown", "photo-temporary-unknown", "photo-request-unknown"].contains(state)
        if state.hasPrefix("photo-albums") || state.hasPrefix("photo-sharing") || state.hasPrefix("photo-temporary") {
            uploaded = (1...2).map { index in
                .init(id: .init(profileID: profileID, space: .personal, unitID: index), filename: "Sample \(index).jpg",
                      sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20), folderID: 1, mediaType: "photo")
            }
        }
        if state == "photo-sharing-conditional" { albumList = [.init(id: 21, name: "Sample album", isConditional: true)] }
        if state == "photo-sharing-existing" {
            sharingValue = .init(access: .invited, url: URL(string: "https://example.invalid/shared/fixture"), hasPassword: true, hasExpiration: false, revision: "original", members: [], expiration: 0, isTemporary: false)
        }
        if state == "photo-sharing-members-unknown" { sharingValue = .init(access: .disabled, hasPassword: nil, revision: "original") }
        if state == "photo-sharing-temporary" { sharingValue = .init(access: .invited, revision: "original", members: [], isTemporary: true) }
        if state.hasPrefix("photo-temporary-existing") {
            temporaryAlbumIDs = [21]
            sharingValue = .init(access: .invited, revision: "original", members: [], expiration: 0, isTemporary: true)
        }
        if state.hasPrefix("photo-request") {
            requestList = [.init(id: "synthetic-request", profileID: profileID,
                settings: .init(subject: "Sample request", description: "Sample description", space: state == "photo-request-nohome" ? .shared : .personal,
                    folderPath: "/Sample folder", folderID: 2, albumID: 21, expiration: 2_000_000_007, sizeLimit: 1_234_567),
                albumName: "Sample album", isFolderValid: state != "photo-request-invalid-folder", url: URL(string: "https://example.invalid/request/fixture"))]
        }
    }
    func setPending(_ value: Bool) { pending = value }
    func seedTemporaryAlbum(_ album: SynologyPhotoCollection) {
        albumList.append(album); temporaryAlbumIDs.insert(album.id); members[album.id] = Set(uploaded.map { $0.id.unitID })
        sharingValue = .init(access: .invited, revision: "created", members: [], expiration: 0, isTemporary: true)
    }
    func setUser(_ value: Int) { userID = value }
    func denyWrites() { deniesWrites = true }
    func releaseUpload() { heldUpload?.resume(); heldUpload = nil }
    func releaseRequest() { heldRequest?.resume(); heldRequest = nil }
    func seedRequest(_ request: SynologyPhotoRequest) { requestList = [request] }
    func access() async throws -> SynologyPhotosAccess {
        if state == "photo-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-error" { throw URLError(.notConnectedToInternet) }
        return .init(spaces: state == "photo-albums-only" ? [] : ["photo-albums-nohome", "photo-request-nohome"].contains(state) ? [.shared] : [.personal, .shared], packageVersion: "synthetic")
    }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> {
        state.hasSuffix("-readonly") || deniesWrites ? [] : [.upload, .albums, .folders, .sharing, .photoRequests]
    }
    func changeSharing(_ value: SynologyPhotoSharingState) { sharingValue = value }
    func albumSharing(id: Int) async throws -> SynologyPhotoSharingState {
        if state == "photo-sharing-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-sharing-error" || state.hasSuffix("-contributor") || deniesWrites { throw URLError(.notConnectedToInternet) }
        return sharingValue
    }
    func sharingRecipients() async throws -> [SynologyPhotoShareRecipient] {
        if state == "photo-sharing-members-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-sharing-members-error" { throw URLError(.notConnectedToInternet) }
        if state == "photo-sharing-members-empty" { return [] }
        return [.init(id: .init(type: "user", value: .integer(31)), name: "Sample member"),
                .init(id: .init(type: "group", value: .string("31")), name: "Sample group")]
    }
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int) async throws -> [SynologyPhotoSharedEntry] {
        if scope == .requests {
            return requestList.dropFirst(offset).prefix(limit).map { .init(id: $0.id, title: $0.settings.subject, url: $0.url) }
        }
        guard scope == .withOthers, sharingValue.access != .disabled, offset == 0 else { return [] }
        let id = temporaryAlbumIDs.sorted().last ?? 21
        return [.init(id: "shared-album", title: albumList.first { $0.id == id }?.name ?? "Sample album", albumID: id, url: sharingValue.url)]
    }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let groups = Dictionary(grouping: uploaded.filter { $0.id.space == space }) { calendar.startOfDay(for: $0.takenAt) }
        return groups.keys.sorted(by: >).map { date in
            let values = calendar.dateComponents([.year, .month, .day], from: date)
            return .init(year: values.year!, month: values.month!, day: values.day!, itemCount: groups[date]!.count)
        }
    }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { [] }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        let values: [SynologyPhoto]
        if case .album(let id, _) = query {
            values = uploaded.filter { members[id, default: []].contains($0.id.unitID) }.map { photo in
                .init(id: photo.id, filename: photo.filename, sizeBytes: photo.sizeBytes, takenAt: photo.takenAt, indexedAt: photo.indexedAt,
                    folderID: photo.folderID, mediaType: photo.mediaType, albumContext: .init(albumID: id, ownerUserID: userID, providerUserID: userID))
            }
        } else { values = uploaded.filter { $0.id.space == space } }
        return .init(items: Array(values.dropFirst(offset).prefix(limit)), offset: offset, nextOffset: values.count, hasMore: false)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Self.image }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto { photo }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: 1, name: "Sample folder", path: "/", space: space) }
    func folder(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: id, name: "Sample folder", parentID: id == 1 ? nil : 1, path: "/Sample folder", space: space) }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        if state == "photo-request-folders-error" { throw URLError(.notConnectedToInternet) }
        guard state.hasPrefix("photo-request"), parentID == 1 else { return [] }
        let count = state == "photo-request-paged" ? 101 : 1
        return Array((0..<count).dropFirst(offset).prefix(limit)).map { index in
            .init(id: index + 2, name: index == 0 ? "Sample folder" : "Folder \(index)", parentID: 1,
                  path: index == 0 ? "/Sample folder" : "/Folder \(index)", space: space)
        }
    }
    func photoRequest(id: String) async throws -> SynologyPhotoRequest {
        let value = requestList.first { $0.id == id }
        if state == "photo-request-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-request-held" { isRequestHeld = true; await withCheckedContinuation { heldRequest = $0 } }
        if state == "photo-request-error" { throw URLError(.notConnectedToInternet) }
        guard let value else { throw CocoaError(.fileReadNoSuchFile) }
        return value
    }
    func photoRequestAlbums() async throws -> [SynologyPhotoRequestAlbum] {
        if state == "photo-request-albums-error" { throw URLError(.notConnectedToInternet) }
        if state == "photo-request-albums-empty" { return [] }
        return albumList.map { .init(albumID: $0.id, name: $0.name, shared: false) }
            + [.init(passphrase: "synthetic-shared-album", name: "Shared sample album", shared: true)]
    }
    func folderSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort { .init() }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { Array(albumList.dropFirst(offset).prefix(limit)) }
    func addableAlbums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        if state == "photo-albums-empty" { return [] }
        if state == "photo-albums-error" { throw URLError(.notConnectedToInternet) }
        if state == "photo-albums-loading" { try await Task.sleep(for: .seconds(30)) }
        return Array(albumList.dropFirst(offset).prefix(limit))
    }
    func albumSort(id: Int) async throws -> SynologyPhotoSort { .init() }
    func albumAccess(id: Int) async throws -> SynologyPhotoAlbumAccess {
        .init(albumID: id, currentUserID: userID, isOwner: !state.hasSuffix("-contributor"), canDownload: true, canContribute: !state.hasSuffix("-readonly") && !deniesWrites)
    }
    func uploadRecoveryIdentity() async throws -> String { "\(profileID.uuidString):\(userID)" }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws {
        if deniesWrites { throw CocoaError(.fileWriteNoPermission) }
        if case .shareAlbum(_, _, let original, _, _, _) = mutation, original?.revision != sharingValue.revision { throw CocoaError(.fileWriteNoPermission) }
    }
    func performRecoverableUpload(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress,
                                  checkpoint: @escaping @Sendable (SynologyPhotosUploadCheckpoint) throws -> Void) async throws -> SynologyPhotosMutationResult {
        var record = try SynologyPhotosUploadCheckpoint(mutation: mutation, operationID: operationID, profileID: profileID, userID: userID)
        try checkpoint(record)
        commands.append(mutation)
        switch mutation {
        case .upload, .uploadToAlbum: nextID += 1; record.itemID = nextID
        case .createFolder: nextID += 1; record.folderID = nextID
        case .addToAlbum:
            if state == "photo-album-failure", rejectsAlbum { record.rejected = true; rejectsAlbum = false }
        default: break
        }
        records[operationID] = record
        try checkpoint(record)
        if state == "photo-held" {
            isUploadHeld = true
            await withCheckedContinuation { heldUpload = $0 }
        }
        return result(record)
    }
    func restoreUploadMutation(_ checkpoint: SynologyPhotosUploadCheckpoint) async throws {
        guard checkpoint.profileID == profileID, checkpoint.userID == userID else { throw CocoaError(.fileReadNoPermission) }
        records[checkpoint.operationID] = checkpoint
    }
    func performRecoverableAlbumMutation(_ mutation: SynologyPhotosMutation, operationID: UUID,
                                        checkpoint: @escaping @Sendable (SynologyPhotosAlbumCheckpoint) throws -> Void) async throws -> SynologyPhotosMutationResult {
        if deniesWrites { throw CocoaError(.fileWriteNoPermission) }
        var saved = try SynologyPhotosAlbumCheckpoint(mutation: mutation, operationID: operationID, profileID: profileID, userID: userID)
        if var sharing = saved.sharingDetails {
            sharing.previousMembers = sharingValue.members?.map(SynologyPhotosAlbumCheckpoint.Sharing.Member.init)
            sharing.previousHasPassword = sharingValue.hasPassword
            sharing.previousExpiration = .init(sharingValue.expiration.map(SynologyPhotoConditionValue.integer))
            saved.sharingDetails = sharing
        }
        try checkpoint(saved)
        commands.append(mutation)
        if var sharing = saved.sharingDetails {
            sharing.passwordAcknowledged = sharing.password != .unchanged && !pending
            sharing.enableAttempted = sharing.access != "disabled" && state != "photo-sharing-partial"
            saved.sharingDetails = sharing
        }
        switch mutation {
        case .createPhotoRequest(let settings):
            nextID += 1
            let id = "synthetic-created-\(nextID)"
            if var request = saved.requestDetails { try request.recordCreatedID(id); saved.requestDetails = request }
            requestList.append(.init(id: id, profileID: profileID, settings: settings, isFolderValid: true, url: URL(string: "https://example.invalid/request/new")))
        case .updatePhotoRequest(let original, let settings):
            requestList.removeAll { $0.id == original.id }
            requestList.append(.init(id: original.id, profileID: profileID, settings: settings, albumName: original.albumName, isFolderValid: true, url: original.url))
        case .deletePhotoRequest(let original): requestList.removeAll { $0.id == original.id }
        case .createAlbum, .createTemporaryAlbum, .copyTemporaryAlbum:
            nextID += 1; saved.createdAlbumID = nextID
            if case .copyTemporaryAlbum = mutation {
                if state == "photo-temporary-existing-copy-unknown" { pending = true }
                if state == "photo-temporary-existing-copy-rejected", rejectsAlbum { saved.rejected = true; rejectsAlbum = false }
            }
        default: break
        }
        if state == "photo-albums-partial", rejectsAlbum, mutation.photos.count > 1 {
            saved.membershipHasFailures = true; rejectsAlbum = false
        }
        albumRecords[operationID] = saved
        try checkpoint(saved)
        return albumResult(saved)
    }
    func restoreAlbumMutation(_ checkpoint: SynologyPhotosAlbumCheckpoint) async throws {
        guard checkpoint.profileID == profileID, checkpoint.userID == userID else { throw CocoaError(.fileReadNoPermission) }
        _ = try checkpoint.reviewMutation()
        albumRecords[checkpoint.operationID] = checkpoint
    }
    private func albumResult(_ saved: SynologyPhotosAlbumCheckpoint) -> SynologyPhotosMutationResult {
        if pending { return .init(state: .pendingReview) }
        if saved.rejected { return .init(state: .rejected) }
        switch saved.operation {
        case .request(let summary):
            guard summary.targetDigest != nil else { return .init(state: .pendingReview) }
            let request = requestList.first { summary.matchesTarget($0.id) }
            if summary.kind == .delete { return .init(state: request == nil ? .confirmed : .pendingReview) }
            guard let request, (try? summary.matchesSettings(request.settings)) == true else { return .init(state: .pendingReview) }
            return .init(state: .confirmed, sharingURL: request.url, photoRequest: request)
        case .createTemporary(let name, let photos):
            guard let id = saved.createdAlbumID else { return .init(state: .pendingReview) }
            let album = SynologyPhotoCollection(id: id, name: name)
            if !albumList.contains(where: { $0.id == id }) { albumList.append(album) }
            temporaryAlbumIDs.insert(id); members[id] = Set(photos.map(\.unitID))
            sharingValue = .init(access: .invited, revision: "created", members: [], expiration: 0, isTemporary: true)
            return .init(state: .confirmed, album: album, completedCount: photos.count)
        case .copyTemporary(let source, let name, _):
            guard let id = saved.createdAlbumID else { return .init(state: .pendingReview) }
            let album = SynologyPhotoCollection(id: id, name: name)
            if !albumList.contains(where: { $0.id == id }) { albumList.append(album) }
            members[id] = members[source]
            return .init(state: .confirmed, album: album, completedCount: members[id]?.count ?? 0)
        case .deleteTemporary(let id, _, _):
            albumList.removeAll { $0.id == id }; members.removeValue(forKey: id); temporaryAlbumIDs.remove(id)
            return .init(state: .confirmed)
        case .create(let name, let photos):
            guard let id = saved.createdAlbumID else { return .init(state: .pendingReview) }
            let album = SynologyPhotoCollection(id: id, name: name)
            if !albumList.contains(where: { $0.id == id }) { albumList.append(album) }
            members[id] = Set(photos.map(\.unitID))
            return .init(state: .confirmed, album: album, completedCount: photos.count)
        case .rename(let id, let name):
            let album = SynologyPhotoCollection(id: id, name: name)
            if let row = albumList.firstIndex(where: { $0.id == id }) { albumList[row] = album }
            return .init(state: .confirmed, album: album)
        case .delete(let id):
            albumList.removeAll { $0.id == id }; members.removeValue(forKey: id)
            return .init(state: .confirmed)
        case .add(let id, let photos):
            members[id, default: []].formUnion(photos.map(\.unitID))
            return .init(state: .confirmed, completedCount: photos.count)
        case .remove(let id, let photos):
            let completed = saved.membershipHasFailures ? Array(photos.prefix(1)) : photos
            members[id, default: []].subtract(completed.map(\.unitID))
            return .init(state: saved.membershipHasFailures ? .partial : .confirmed, photos: completed.map(\.photo), completedCount: completed.count)
        case .cover(let id, _): return .init(state: .confirmed, album: albumList.first { $0.id == id })
        case .sharing(let settings):
            let partial = state == "photo-sharing-partial" && rejectsSharing
            rejectsSharing = false
            let access = partial ? SynologyPhotoLinkAccess.disabled : SynologyPhotoLinkAccess(rawValue: settings.access) ?? .disabled
            let protected = settings.password == .unchanged ? settings.previousHasPassword : settings.password == .set
            let grants = settings.members?.map(\.grant) ?? sharingValue.members
            let expiry = settings.expiration ?? sharingValue.expiration
            sharingValue = .init(access: access, url: access == .disabled ? nil : URL(string: "https://example.invalid/shared/fixture"),
                hasPassword: protected, hasExpiration: expiry.map { $0 > 0 }, revision: saved.operationID.uuidString,
                members: grants, expiration: expiry, isTemporary: temporaryAlbumIDs.contains(settings.albumID) || sharingValue.isTemporary == true)
            return .init(state: partial ? .partial : .confirmed, album: albumList.first { $0.id == settings.albumID }, sharingURL: sharingValue.url)
        }
    }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        reviews += 1
        if let saved = albumRecords[operationID] { return albumResult(saved) }
        guard let record = records[operationID] else { return .init(state: .pendingReview) }
        return result(record)
    }
    private func result(_ record: SynologyPhotosUploadCheckpoint) -> SynologyPhotosMutationResult {
        if pending { return .init(state: .pendingReview) }
        if record.rejected { return .init(state: .rejected) }
        switch record.operation {
        case .upload(let name, let size, let date, let folder, let space, _):
            let photo = SynologyPhoto(id: .init(profileID: profileID, space: space, unitID: record.itemID ?? 100), filename: name,
                sizeBytes: size, takenAt: date, indexedAt: date, folderID: folder ?? 1, mediaType: "photo")
            if !uploaded.contains(where: { $0.id == photo.id }) { uploaded.append(photo) }
            return .init(state: .confirmed, photos: [photo])
        case .uploadToAlbum(let name, let size, let date, let album, _):
            return .init(state: .confirmed, photos: [.init(id: .init(profileID: profileID, space: .personal, unitID: record.itemID ?? 100),
                filename: name, sizeBytes: size, takenAt: date, indexedAt: date, folderID: 1, mediaType: "photo",
                albumContext: .init(albumID: album, ownerUserID: 99, providerUserID: userID))])
        case .addToAlbum(_, let photo): return .init(state: .confirmed, photos: [photo.photo])
        case .createFolder(let parent, let name, let space): return .init(state: .confirmed, folder: .init(id: record.folderID ?? 100, name: name, parentID: parent, space: space))
        }
    }
    static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1sAAAAASUVORK5CYII=")!
}
#endif
