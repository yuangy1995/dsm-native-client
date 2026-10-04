#if DEBUG
import DsmCore
import Foundation

/// Photos 上传与恢复的合成服务；不持有连接、凭据或真实媒体。
actor MobilePhotosUIService: SynologyPhotosServing {
    nonisolated let profileID: UUID
    let state: String
    private(set) var commands: [SynologyPhotosMutation] = []
    private(set) var reviews = 0
    private var records: [UUID: SynologyPhotosUploadCheckpoint] = [:]
    private var rejectsAlbum = true
    private var pending: Bool
    private var nextID = 100
    private var userID = 12
    private var deniesWrites = false
    private var uploaded: [SynologyPhoto] = []
    private var heldUpload: CheckedContinuation<Void, Never>?
    private(set) var isUploadHeld = false

    init(profileID: UUID = UUID(), state: String = "photo-upload") {
        self.profileID = profileID; self.state = state; pending = state == "photo-unknown"
    }
    func setPending(_ value: Bool) { pending = value }
    func setUser(_ value: Int) { userID = value }
    func denyWrites() { deniesWrites = true }
    func releaseUpload() { heldUpload?.resume(); heldUpload = nil }
    func access() async throws -> SynologyPhotosAccess {
        if state == "photo-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-error" { throw URLError(.notConnectedToInternet) }
        return .init(spaces: [.personal, .shared], packageVersion: "synthetic")
    }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> {
        state == "photo-readonly" || deniesWrites ? [] : [.upload, .albums, .folders]
    }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { [] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { [] }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        .init(items: Array(uploaded.filter { $0.id.space == space }.dropFirst(offset).prefix(limit)), offset: offset, nextOffset: uploaded.count, hasMore: false)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Self.image }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto { photo }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: 1, name: "Sample folder", path: "/", space: space) }
    func folder(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: id, name: "Sample folder", parentID: id == 1 ? nil : 1, path: "/Sample folder", space: space) }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { [] }
    func folderSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort { .init() }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { offset == 0 ? [.init(id: 21, name: "Sample album")] : [] }
    func albumAccess(id: Int) async throws -> SynologyPhotoAlbumAccess {
        .init(albumID: id, currentUserID: userID, isOwner: state != "photo-contributor", canDownload: true, canContribute: state != "photo-readonly" && !deniesWrites)
    }
    func uploadRecoveryIdentity() async throws -> String { "\(profileID.uuidString):\(userID)" }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws {
        if deniesWrites { throw CocoaError(.fileWriteNoPermission) }
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
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        reviews += 1
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
