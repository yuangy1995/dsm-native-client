#if DEBUG
import CoreGraphics
import DsmCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
    private var frozenValue: SynologyPhotoFrozenAlbum?
    private var conditions: [Int: SynologyPhotoAlbumCondition] = [:]
    private var heldCondition: CheckedContinuation<Void, Never>?
    private(set) var isConditionHeld = false
    private var heldRequest: CheckedContinuation<Void, Never>?
    private(set) var isRequestHeld = false
    private var sharingValue = SynologyPhotoSharingState(access: .disabled, hasPassword: true, hasExpiration: false, revision: "original", members: [], expiration: 0, isTemporary: false)
    private var pending: Bool
    private var nextID = 100
    private var userID = 12
    private var deniesWrites = false
    private var recognitionPeople: [SynologyPhotoSpace: [SynologyPhotoPersonVisibility]] = [:]
    private var recognitionConcepts: [SynologyPhotoSpace: [SynologyPhotoConceptVisibility]] = [:]
    private var recognitionRegions: [SynologyPhotoID: [SynologyPhotoFaceRegion]] = [:]
    private var recognitionResults: [UUID: SynologyPhotosMutationResult] = [:]
    private(set) var deletedPhotoIDs: [SynologyPhotoID] = []
    private(set) var deletionReads = 0
    private var heldSimilar: CheckedContinuation<Void, Never>?
    private(set) var isSimilarHeld = false
    private var heldDeletion: CheckedContinuation<Void, Never>?
    private(set) var isDeletionHeld = false
    private var heldRecognition: CheckedContinuation<Void, Never>?
    private(set) var isRecognitionHeld = false
    private var administrationShared: SynologyPhotoSharedSpaceSettings?
    private var administrationGlobal: SynologyPhotoGlobalSettings?
    private var administrationMembers: SynologyPhotoSharedMembers?
    private var administrationCache: SynologyPhotoConversionCache?
    private var administrationFolders: [SynologyPhotoShareRecipient.ID: [SynologyPhotoMemberFolder]] = [:]
    private var duplicateValue = SynologyPhotoDuplicateSettings(upload: .ignore, transfer: .skip)
    private var displayValue = SynologyPhotoDisplaySettings()
    private var recognitionValue = SynologyPhotoRecognitionSettings(values: [.person: true, .concept: true, .similar: false], globallyEnabled: [.person, .concept, .similar], personalSpaceEnabled: true)
    private var uploaded: [SynologyPhoto] = []
    private var automaticEnabled = false
    private var automaticFinished: Set<Int> = []
    private var codecShown = true
    private var codecSubmitted = false
    private var maintenanceRunning: [SynologyPhotoSpace: SynologyPhotoLibraryMaintenanceStatus.Action] = [:]
    private var repairedPreviews: Set<SynologyPhotoID> = []
    private var tagChoices: [SynologyPhotoFilterChoice] = [.init(id: 8, name: "Sample tag")]
    private var heldEdit: CheckedContinuation<Void, Never>?
    private(set) var isEditHeld = false
    private var heldUpload: CheckedContinuation<Void, Never>?
    private(set) var isUploadHeld = false
    private var folderList: [SynologyPhotoCollection] = []
    private var folderSorts: [String: SynologyPhotoSort] = [:]
    private var heldFolder: CheckedContinuation<Void, Never>?
    private(set) var isFolderHeld = false

    private var folderSharingValues: [Int: SynologyPhotoFolderSharingState] = [:]
    private var taskList: [SynologyPhotoBackgroundTask] = []
    private var heldControl: CheckedContinuation<Void, Never>?
    private(set) var isControlHeld = false

    init(profileID: UUID = UUID(), state: String = "photo-upload") {
        self.profileID = profileID; self.state = state
        pending = ["photo-unknown", "photo-albums-unknown", "photo-sharing-unknown", "photo-temporary-unknown", "photo-request-unknown", "photo-condition-unknown", "photo-frozen-unknown", "photo-edit-unknown", "photo-folders-unknown", "photo-folder-sharing-unknown", "photo-tasks-unknown", "photo-preferences-unknown", "photo-repair-unknown", "photo-preview-unknown", "photo-preview-automatic-unknown", "photo-admin-unknown", "photo-recognition-unknown", "photo-deletion-unknown"].contains(state)
        if state == "photo-similar-unknown" { pending = true }
        if state.hasPrefix("photo-export") {
            uploaded = (1...3).map { index in
                .init(id: .init(profileID: profileID, space: .personal, unitID: index), filename: "Sample \(index).jpg",
                      sizeBytes: Int64(Self.exportImage.count), takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20),
                      folderID: 1, mediaType: "photo", thumbnail: .init(unitID: index, revision: "original"))
            }
        }
        if state.hasPrefix("photo-similar") {
            uploaded = SynologyPhotoSpace.allCases.flatMap { space in (1...9).map { index in
                var photo = SynologyPhoto(id: .init(profileID: profileID, space: space, unitID: index), filename: "Sample \(index).jpg",
                    sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20),
                    folderID: 1, mediaType: "photo", thumbnail: .init(unitID: index, revision: "original"))
                if state != "photo-similar-empty" {
                    let start = ((index - 1) / 3) * 3 + 1
                    photo.similarGroup = .init(profileID: profileID, space: space, id: 31 + (index - 1) / 3,
                        photoIDs: [start, start + 1, start + 2], topPickID: start)
                }
                return photo
            } }
        }
        if state.hasPrefix("photo-albums") || state.hasPrefix("photo-sharing") || state.hasPrefix("photo-temporary") || state.hasPrefix("photo-edit") || (state.hasPrefix("photo-folders") || state.hasPrefix("photo-folder-sharing") || state.hasPrefix("photo-tasks")) {
            uploaded = (1...2).map { index in
                .init(id: .init(profileID: profileID, space: .personal, unitID: index), filename: "Sample \(index).jpg",
                      sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20), folderID: 1, mediaType: "photo")
            }
        }
        if (state.hasPrefix("photo-folders") || state.hasPrefix("photo-folder-sharing") || state.hasPrefix("photo-tasks")) {
            let count = state == "photo-folders-paged" ? 101 : 2
            var initial: [SynologyPhotoCollection] = []
            for space in [SynologyPhotoSpace.personal, .shared] {
                for id in 2..<(count + 2) {
                    let name = id == 2 ? "Source" : id == 3 ? "Destination" : "Folder \(id)"
                    initial.append(.init(id: id, name: name, parentID: 1, path: "/" + name, space: space))
                }
                initial.append(.init(id: 200, name: "Child", parentID: 2, path: "/Source/Child", space: space))
            }
            folderList = initial
            uploaded.append(.init(id: .init(profileID: profileID, space: .personal, unitID: 3), filename: "Cover.jpg",
                sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20), folderID: 200, mediaType: "photo"))
        }
        if state.hasPrefix("photo-tasks"), state != "photo-tasks-empty" {
            for id in 41...43 {
                taskList.append(.init(profileID: profileID, userID: 12, id: id, operation: id == 41 ? "copy" : "move",
                    status: id == 41 ? .processing : .done, total: 5, completion: id == 41 ? 2 : 5,
                    errors: id == 42 ? 1 : 0, skipped: 0, overwritten: 0, createdAt: Double(1_700_000_000 + id), targetFolderID: 3, targetOwnerID: 12))
            }
        }
        if state.hasPrefix("photo-deletion"), !state.hasSuffix("empty") {
            uploaded = SynologyPhotoSpace.allCases.flatMap { space in (1...3).map { index in
                .init(id: .init(profileID: profileID, space: space, unitID: index), filename: "Sample \(index).jpg",
                      sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20),
                      folderID: 1, mediaType: "photo", thumbnail: .init(unitID: index, revision: "original"))
            } }
        }
        if state.hasPrefix("photo-recognition") {
            uploaded = SynologyPhotoSpace.allCases.flatMap { space in (1...2).map { index in
                .init(id: .init(profileID: profileID, space: space, unitID: index), filename: "Sample \(index).jpg",
                      sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20),
                      folderID: 1, mediaType: "photo", thumbnail: .init(unitID: index, revision: "original"))
            } }
        }
        if state.hasPrefix("photo-preview") {
            automaticEnabled = state.contains("automatic")
            codecShown = !state.hasSuffix("empty")
            if state.hasSuffix("running") { maintenanceRunning[.personal] = .previews }
            uploaded = [.init(id: .init(profileID: profileID, space: .personal, unitID: 1), filename: "Sample 1.jpg",
                sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20),
                folderID: 1, mediaType: "photo", thumbnail: .init(unitID: 11, revision: "original"))]
        }
        if state.hasPrefix("photo-repair") {
            uploaded = (1...(state == "photo-repair-many" ? 102 : 2)).map { index in
                .init(id: .init(profileID: profileID, space: .personal, unitID: index), filename: "Sample \(index).jpg",
                    sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20),
                    folderID: 1, mediaType: "photo", thumbnail: .init(unitID: index, revision: "original"))
            }
            uploaded.append(.init(id: .init(profileID: profileID, space: .shared, unitID: 1), filename: "Shared sample.jpg",
                sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20), folderID: 1, mediaType: "photo"))
        }
        if state.hasPrefix("photo-preferences") {
            uploaded = [.init(id: .init(profileID: profileID, space: .personal, unitID: 1), filename: "Sample 1.jpg",
                sizeBytes: 128, takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20),
                folderID: 1, mediaType: "photo", width: 100, height: 80, orientation: 1)]
            if state == "photo-preferences-empty" { recognitionValue = .init(values: [:], globallyEnabled: [], personalSpaceEnabled: true) }
            if state == "photo-preferences-restricted" { recognitionValue = .init(values: [.person: true, .similar: false], globallyEnabled: [.person], personalSpaceEnabled: true) }
        }
        if state.hasPrefix("photo-edit") {
            let initialTags = tagChoices
            uploaded = uploaded.map { photo in
                var result = Self.withDate(photo, date: Date(timeIntervalSince1970: 1_700_000_000 + Double(photo.id.unitID) * 3_600))
                result.description = "Original description"; result.rating = 2; result.tags = initialTags
                return result
            }
        }
        if state.hasPrefix("photo-frozen") {
            let album = SynologyPhotoCollection(id: 21, name: "Sample frozen album", itemCount: 2, isFrozen: true)
            albumList = [album]
            let condition = SynologyPhotoAlbumCondition(fields: ["item_type": .array([]), "keyword": .array([.string("Sample rule")])])
            frozenValue = .init(profileID: profileID, userID: 12, album: album,
                rawCondition: state == "photo-frozen-nohome" ? ["user_id": .integer(0)] : condition.fields,
                unsupportedConditions: ["people": .array([.integer(1)]), "recently_add": .boolean(true)],
                rebuildCondition: state == "photo-frozen-no-condition" ? nil : condition, sharingRevision: "synthetic-revision", isShared: true)
        }
        if state.hasPrefix("photo-condition") {
            albumList = [.init(id: 21, name: "Sample conditional album", isConditional: true)]
            conditions[21] = .init(fields: ["user_id": .integer(12), "item_type": .array([.integer(-3)]),
                "person": .array([.integer(77)]), "person_policy": .string("or"),
                "keyword": .array([.string("Original keyword")]), "keyword_policy": .string("and"),
                "future_empty": .array([]), "future_order": .array([.integer(2), .integer(1)])])
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
    func frozenAlbum(id: Int) async throws -> SynologyPhotoFrozenAlbum {
        let value = frozenValue
        if state == "photo-frozen-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-frozen-held" { isConditionHeld = true; await withCheckedContinuation { heldCondition = $0 } }
        if state == "photo-frozen-error" { throw URLError(.notConnectedToInternet) }
        guard let value, value.album.id == id else { throw CocoaError(.fileReadNoSuchFile) }; return value
    }
    func clearFrozenSnapshot() { frozenValue = nil }
    func seedCondition(_ condition: SynologyPhotoAlbumCondition, id: Int = 21, name: String = "Sample conditional album") {
        conditions[id] = condition
        albumList.removeAll { $0.id == id }; albumList.append(.init(id: id, name: name, isConditional: true))
    }
    func releaseCondition() { heldCondition?.resume(); heldCondition = nil }
    func albumCondition(id: Int) async throws -> SynologyPhotoAlbumCondition {
        let value = conditions[id]
        if state == "photo-condition-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-condition-held" { isConditionHeld = true; await withCheckedContinuation { heldCondition = $0 } }
        if state == "photo-condition-error" { throw URLError(.notConnectedToInternet) }
        guard let value else { throw CocoaError(.fileReadNoSuchFile) }; return value
    }
    func conditionSuggestions(keyword: String, in space: SynologyPhotoSpace) async throws -> [String: [SynologyPhotoConditionOption]] {
        if state == "photo-condition-suggest-held" { isConditionHeld = true; await withCheckedContinuation { heldCondition = $0 } }
        if state == "photo-condition-suggest-error" { throw URLError(.notConnectedToInternet) }
        if state == "photo-condition-empty" || keyword == "no-match" { return [:] }
        return ["person": [.init(name: "Sample person", value: .integer(space == .personal ? 77 : 88))],
            "general_tag": [.init(name: "Sample tag", value: .integer(8))]]
    }
    func conditionItemCount(_ condition: SynologyPhotoAlbumCondition) async throws -> Int {
        if state == "photo-condition-count-held" { isConditionHeld = true; await withCheckedContinuation { heldCondition = $0 } }
        if state == "photo-condition-count-error" { throw URLError(.notConnectedToInternet) }
        return condition.values("keyword").isEmpty ? 12 : 3
    }
    func setPending(_ value: Bool) { pending = value }
    func seedPhotos(_ photos: [SynologyPhoto]) { uploaded = photos }
    func releaseEdit() { heldEdit?.resume(); heldEdit = nil }
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
        return .init(spaces: state == "photo-albums-only" ? [] : ["photo-albums-nohome", "photo-request-nohome", "photo-condition-nohome", "photo-frozen-nohome"].contains(state) ? [.shared] : [.personal, .shared], packageVersion: "synthetic", canManageSharedSpace: state.hasPrefix("photo-similar") || (state.hasPrefix("photo-recognition") && state != "photo-recognition-noaccess") || (state.hasPrefix("photo-condition") && state != "photo-condition-shared-entry") || state == "photo-edit-mixed" || (state.hasPrefix("photo-folder-sharing") && state != "photo-folder-sharing-noaccess"), displaySettings: state.hasPrefix("photo-preferences") ? displayValue : nil, automaticPreviewEnabled: state.hasPrefix("photo-preview") ? automaticEnabled : nil)
    }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> {
        guard !state.hasSuffix("-readonly"), !deniesWrites else { return [] }
        var features: Set<SynologyPhotosManagementFeature> = [.upload, .albums, .folders, .sharing, .photoRequests]
        if state.hasPrefix("photo-similar") { features.insert(.similarGroups) }
        if state.hasPrefix("photo-condition") || (state.hasPrefix("photo-frozen") && state != "photo-frozen-no-condition") { features.insert(.conditionAlbums) }
        if state.hasPrefix("photo-frozen") { features.insert(.frozenAlbums) }
        if state.hasPrefix("photo-edit") { features.formUnion([.metadata, .tags, .tagCreation]) }
        if (state.hasPrefix("photo-folders") || state.hasPrefix("photo-folder-sharing") || state.hasPrefix("photo-tasks")) { features.formUnion([.folders, .fileTransfer, .folderDeletion, .folderSorting, .folderCover]) }
        if state.hasPrefix("photo-folder-sharing"), space == .shared { features.insert(.folderSharing) }
        if state.hasPrefix("photo-tasks") { features.insert(.backgroundTasks) }
        if state == "photo-folders-defaults" { features.insert(.duplicateSettings) }
        if state.hasPrefix("photo-repair") { features.insert(.previewRegeneration) }
        if state.hasPrefix("photo-preview") {
            features.formUnion([.automaticPreviewSettings, .automaticPreview, .codecPrompt])
            if space == .personal || state == "photo-preview-admin" { features.insert(.libraryMaintenance) }
        }
        if state.hasPrefix("photo-recognition") { features.formUnion([.peopleNames, .peopleMerge, .peopleCover, .peopleVisibility, .peopleFaces, .conceptCover, .conceptItems, .conceptVisibility, .manualFaces]) }
        if state.hasPrefix("photo-admin") { features.formUnion([.sharedSpaceSettings, .sharedMembers, .globalSettings, .conversionCache]) }
        if state.hasPrefix("photo-preferences") { features.formUnion([.duplicateSettings, .displaySettings, .recognitionSettings, .rotation]) }
        return features
    }
    private func recognitionRead() async throws {
        if state == "photo-recognition-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-recognition-held" { isRecognitionHeld = true; await withCheckedContinuation { heldRecognition = $0 } }
        if state == "photo-recognition-error" { throw URLError(.notConnectedToInternet) }
    }
    func releaseRecognition() { heldRecognition?.resume(); heldRecognition = nil }
    private func peopleValues(_ space: SynologyPhotoSpace) -> [SynologyPhotoPersonVisibility] {
        recognitionPeople[space] ?? (state == "photo-recognition-empty" ? [] : [
            .init(person: .init(id: 77, name: "Sample person", itemCount: 2, space: space), isVisible: true),
            .init(person: .init(id: 78, name: "Another person", itemCount: 1, space: space), isVisible: true),
            .init(person: .init(id: 79, name: "Hidden person", itemCount: 1, space: space), isVisible: false)])
    }
    private func conceptValues(_ space: SynologyPhotoSpace) -> [SynologyPhotoConceptVisibility] {
        recognitionConcepts[space] ?? (state == "photo-recognition-empty" ? [] : [
            .init(concept: .init(id: 31, name: "Sample topic", itemCount: 2, space: space), isVisible: true, displayThreshold: 2),
            .init(concept: .init(id: 32, name: "Hidden topic", itemCount: 1, space: space), isVisible: false, displayThreshold: 2)])
    }
    private func regions(_ photo: SynologyPhoto) -> [SynologyPhotoFaceRegion] {
        recognitionRegions[photo.id] ?? (state == "photo-recognition-empty" ? [] : [
            .init(id: photo.id.unitID * 100 + 1, personID: 77, name: "Sample person", bounds: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.3)),
            .init(id: photo.id.unitID * 100 + 2, personID: 78, name: "Another person", bounds: .init(x: 0.55, y: 0.5, width: 0.3, height: 0.3))])
    }
    func categories(in space: SynologyPhotoSpace) async throws -> Set<SynologyPhotoCategory> { state.hasPrefix("photo-similar") ? [.similar] : state.hasPrefix("photo-recognition") ? [.person, .concept] : [] }
    func allPhotos() -> [SynologyPhoto] { uploaded }
    func releaseSimilar() { heldSimilar?.resume(); heldSimilar = nil }
    func similarStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoSimilarStatus {
        .init(waitingCount: state == "photo-similar-processing" ? 7 : 0, stage: "running", migrationComplete: true)
    }
    func similarTimeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    private func similarRead() async throws {
        if state == "photo-similar-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-similar-error" { throw URLError(.notConnectedToInternet) }
    }
    func similarPhotos(for photo: SynologyPhoto) async throws -> SynologyPhotoSimilarDetail {
        guard let group = photo.similarGroup, let value = try await similarGroupDetails(group), value.group.photoIDs.contains(photo.id.unitID) else { throw CocoaError(.fileReadNoSuchFile) }
        return value
    }
    func similarGroupDetails(_ original: SynologyPhotoSimilarGroup) async throws -> SynologyPhotoSimilarDetail? {
        try await similarRead()
        guard original.profileID == profileID else { throw CocoaError(.fileReadNoPermission) }
        let remaining = uploaded.filter { $0.id.space == original.space && $0.similarGroup?.id == original.id }
        guard remaining.count >= 2, let old = remaining.first?.similarGroup else { return nil }
        let ids = remaining.map(\.id.unitID)
        let group = SynologyPhotoSimilarGroup(profileID: profileID, space: original.space, id: original.id, photoIDs: ids,
            topPickID: ids.contains(old.topPickID) ? old.topPickID : ids[0])
        let photos = remaining.map { value in var photo = value; photo.similarGroup = group; return photo }
        return .init(group: group, photos: photos)
    }
    private func similarTargets(_ saved: SynologyPhotosAlbumCheckpoint) throws -> [SynologyPhoto] {
        _ = try saved.reviewMutation()
        guard saved.profileID == profileID, saved.userID == userID, let value = saved.similarDetails else { throw CocoaError(.fileReadNoPermission) }
        return try value.targets.map { target in
            guard let photo = uploaded.first(where: { $0.id == target.id }), try target.matchesIdentity(photo) else { throw CocoaError(.fileReadCorruptFile) }
            return photo
        }
    }
    func similarMutationTarget(_ saved: SynologyPhotosAlbumCheckpoint) async throws -> SynologyPhotosMutation {
        try await similarRead()
        guard let value = saved.similarDetails, !value.submitted, !deniesWrites,
              let detail = try await similarGroupDetails(value.group), detail.group == value.group else { throw CocoaError(.fileReadNoPermission) }
        _ = try similarTargets(saved)
        return .editSimilarGroup(detail, value.edit)
    }
    func prepareSimilarUndo(_ saved: SynologyPhotosAlbumCheckpoint) async throws -> SynologyPhotosMutation {
        guard let value = saved.similarDetails, value.canUndo, !deniesWrites else { throw CocoaError(.fileReadNoPermission) }
        let photos = try similarTargets(saved)
        guard photos.allSatisfy({ $0.similarGroup == nil || $0.similarGroup == value.resultingGroup }),
              try await similarGroupDetails(value.group)?.group == value.resultingGroup else { throw CocoaError(.fileReadCorruptFile) }
        let originals = photos.map { item in var photo = item; photo.similarGroup = value.group; return photo }
        return .editSimilarGroup(.init(group: value.group, photos: originals), .undo(saved.operationID))
    }
    private func applySimilar(_ detail: SynologyPhotoSimilarDetail, edit: SynologyPhotoSimilarEdit) {
        let ids: [Int], top: Int
        switch edit {
        case .topPick(let id): ids = detail.group.photoIDs; top = id
        case .remove(let removed): ids = detail.group.photoIDs.filter { !removed.contains($0) }; top = ids.contains(detail.group.topPickID) ? detail.group.topPickID : ids.first ?? 0
        case .ungroup: ids = []; top = 0
        case .undo: ids = detail.group.photoIDs; top = detail.group.topPickID
        }
        let group = ids.count >= 2 ? SynologyPhotoSimilarGroup(profileID: profileID, space: detail.group.space, id: detail.group.id, photoIDs: ids, topPickID: top) : nil
        for index in uploaded.indices where detail.photos.contains(where: { $0.id == uploaded[index].id }) {
            uploaded[index].similarGroup = ids.contains(uploaded[index].id.unitID) ? group : nil
        }
    }
    func categoryItems(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        let values = category == .person ? peopleValues(space).filter(\.isVisible).map(\.person) : conceptValues(space).filter(\.appearsInList).map(\.concept)
        return Array(values.dropFirst(offset).prefix(limit))
    }
    func categoryTimeline(_ category: SynologyPhotoCategory, id: Int, in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func peopleVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoPersonVisibility] { try await recognitionRead(); return peopleValues(space) }
    func managementPeople(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoCollection] { try await recognitionRead(); return peopleValues(space).map(\.person) }
    func conceptVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoConceptVisibility] { try await recognitionRead(); return conceptValues(space) }
    func conceptState(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoConceptVisibility {
        try await recognitionRead(); guard let value = conceptValues(space).first(where: { $0.id == id }) else { throw CocoaError(.fileReadNoSuchFile) }; return value
    }
    func photoFaces(for photo: SynologyPhoto) async throws -> [SynologyPhotoFaceRegion] { try await recognitionRead(); return regions(photo) }
    func personFaces(personID: Int, photos: [SynologyPhoto]) async throws -> [SynologyPhotoFace] {
        try await recognitionRead()
        return photos.flatMap { photo in regions(photo).filter { $0.personID == personID }.map { .init(id: $0.id, personID: personID, photo: photo) } }
    }
    func thumbnail(for collection: SynologyPhotoCollection, category: SynologyPhotoCategory) async throws -> Data { Self.recognitionImage }
    func thumbnail(for face: SynologyPhotoFace) async throws -> Data { Self.recognitionImage }
    private func applyRecognition(_ mutation: SynologyPhotosMutation, saved: inout SynologyPhotosAlbumCheckpoint) -> SynologyPhotosMutationResult {
        let space = mutation.space
        var people = peopleValues(space), concepts = conceptValues(space)
        defer { recognitionPeople[space] = people; recognitionConcepts[space] = concepts }
        switch mutation {
        case .renamePerson(let original, let name), .mergePeople(let original, _, let name):
            let removed: [Int]
            if case .mergePeople(_, let sources, _) = mutation { removed = sources.map(\.id) } else { removed = [] }
            let person = SynologyPhotoCollection(id: original.id, name: name, itemCount: original.itemCount, space: space)
            people.removeAll { $0.id == original.id || removed.contains($0.id) }; people.append(.init(person: person, isVisible: true))
            return .init(state: .confirmed, person: person, removedPersonIDs: removed)
        case .setPersonCover(let person, _): return .init(state: .confirmed, person: person)
        case .setPeopleVisibility(let originals, let visible):
            let ids = Set(originals.prefix(state == "photo-recognition-partial" ? 1 : originals.count).map(\.id))
            people = people.map { .init(person: $0.person, isVisible: ids.contains($0.id) ? visible : $0.isVisible) }
            return .init(state: ids.count == originals.count ? .confirmed : .partial, completedCount: ids.count, personVisibility: people.filter { ids.contains($0.id) })
        case .setConceptVisibility(let originals, let visible):
            let ids = Set(originals.map(\.id)); concepts = concepts.map { .init(concept: $0.concept, isVisible: ids.contains($0.id) ? visible : $0.isVisible, displayThreshold: $0.displayThreshold) }
            return .init(state: .confirmed, completedCount: ids.count, conceptVisibility: concepts.filter { ids.contains($0.id) })
        case .setConceptCover(let concept, _): return .init(state: .confirmed, completedCount: 1, conceptVisibility: [concept])
        case .removeConceptItems(let original, let photos):
            let value = SynologyPhotoConceptVisibility(concept: .init(id: original.id, name: original.concept.name, itemCount: max(0, (original.concept.itemCount ?? 0) - photos.count), space: space), isVisible: original.isVisible, displayThreshold: original.displayThreshold)
            concepts.removeAll { $0.id == original.id }; concepts.append(value)
            return .init(state: .confirmed, completedCount: photos.count, conceptVisibility: [value], removedFromConceptPhotoIDs: photos.map(\.id))
        case .removePersonFaces(let person, let faces), .reassignPersonFaces(let person, let faces, _, _):
            for face in faces {
                var values = regions(face.photo)
                if case .reassignPersonFaces(_, _, let target, let name) = mutation {
                    values = values.map { $0.id == face.id ? .init(id: $0.id, personID: target?.id ?? 90, name: name, bounds: $0.bounds) : $0 }
                } else { values.removeAll { $0.id == face.id } }
                recognitionRegions[face.photo.id] = values
            }
            return .init(state: .confirmed, person: person, removedFromPersonPhotoIDs: mutation.photos.filter { photo in !regions(photo).contains { $0.personID == person.id } }.map(\.id))
        case .editPhotoFaces(let photo, let changes):
            var values = regions(photo)
            if var recovery = saved.recognitionDetails {
                for change in changes {
                    switch change {
                    case .add(let face):
                        nextID += 1; let id = nextID + 1_000
                        values.append(.init(id: id, personID: face.person?.id ?? 90, name: face.name, bounds: face.bounds))
                        recovery.manualAddAttempted = true; recovery.manualAddAcknowledged = true
                        recovery.manualNewIDs[face.temporaryID] = id; recovery.manualThumbnailAttempted.insert(id); recovery.manualUploaded.insert(id)
                    case .remove(let original):
                        values.removeAll { $0.id == original.id }; recovery.manualAttempted.insert(change.id)
                    case .reassign(let original, let person, let name):
                        values = values.map { $0.id == original.id ? .init(id: $0.id, personID: person?.id ?? 90, name: name, bounds: $0.bounds) : $0 }
                        recovery.manualAttempted.insert(change.id); recovery.manualPersonIDs[change.id] = person?.id ?? 90
                    }
                    recovery.manualAcknowledged.insert(change.id)
                }
                saved.recognitionDetails = recovery
            }
            recognitionRegions[photo.id] = values
            return .init(state: .confirmed, photos: [photo], completedCount: changes.count)
        default: return .init(state: .rejected)
        }
    }
    func seedTasks(_ values: [SynologyPhotoBackgroundTask]) { taskList = values }
    func releaseControl() { heldControl?.resume(); heldControl = nil }
    func seedFolderSharing(_ value: SynologyPhotoFolderSharingState) { folderSharingValues[value.folder.id] = value }
    func folderSharing(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoFolderSharingState {
        let value = folderSharingValues[folder.id] ?? .init(folder: folder, access: .invited,
            url: URL(string: "https://example.invalid/folder/fixture")!, hasPassword: true,
            members: state == "photo-folder-sharing-members-unreadable" ? nil : [], parentIsShared: state != "photo-folder-sharing-parent",
            appliesToSubfolders: false, revision: "synthetic-original")
        if state == "photo-folder-sharing-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-folder-sharing-held" { isControlHeld = true; await withCheckedContinuation { heldControl = $0 } }
        if state == "photo-folder-sharing-error" { throw URLError(.notConnectedToInternet) }
        return value
    }
    func folderSharingRecipients() async throws -> [SynologyPhotoShareRecipient] {
        if state == "photo-folder-sharing-members-error" { throw URLError(.notConnectedToInternet) }
        if state == "photo-folder-sharing-members-empty" { return [] }
        return try await sharingRecipients()
    }
    func backgroundTasks() async throws -> [SynologyPhotoBackgroundTask] {
        let values = taskList
        if state == "photo-tasks-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-tasks-held" { isControlHeld = true; await withCheckedContinuation { heldControl = $0 } }
        if state == "photo-tasks-error" { throw URLError(.notConnectedToInternet) }
        return values
    }
    func backgroundTaskErrors(_ task: SynologyPhotoBackgroundTask) async throws -> [SynologyPhotoBackgroundTaskError] {
        if state == "photo-tasks-errors-error" { throw URLError(.notConnectedToInternet) }
        if state == "photo-tasks-errors-empty" { return [] }
        return [.init(kind: .item, itemID: 7, reason: .quota, name: "Sample.jpg", folderPath: "/Source")]
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
    func filteredTimeline(in space: SynologyPhotoSpace, filter: SynologyPhotoFilter) async throws -> [SynologyPhotoDay] {
        state.hasPrefix("photo-recognition") ? try await timeline(in: space) : []
    }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        let values: [SynologyPhoto]
        if case .similar = query {
            try await similarRead()
            values = uploaded.filter { $0.id.space == space && $0.similarGroup?.topPickID == $0.id.unitID }
        } else if case .album(let id, _) = query {
            values = uploaded.filter { members[id, default: []].contains($0.id.unitID) }.map { photo in
                .init(id: photo.id, filename: photo.filename, sizeBytes: photo.sizeBytes, takenAt: photo.takenAt, indexedAt: photo.indexedAt,
                    folderID: photo.folderID, mediaType: photo.mediaType, albumContext: .init(albumID: id, ownerUserID: photo.id.space == .shared ? 0 : userID, providerUserID: userID))
            }
        } else if (state.hasPrefix("photo-folders") || state.hasPrefix("photo-folder-sharing") || state.hasPrefix("photo-tasks")), case .folder(let id, _) = query {
            values = uploaded.filter { $0.id.space == space && $0.folderID == id }
        } else { values = uploaded.filter { $0.id.space == space } }
        return .init(items: Array(values.dropFirst(offset).prefix(limit)), offset: offset, nextOffset: values.count, hasMore: false)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data {
        if state.hasPrefix("photo-export") { return Self.exportImage }
        return state.hasPrefix("photo-recognition") ? Self.recognitionImage : Self.image
    }
    func pendingPreviewRegenerations(in space: SynologyPhotoSpace) async throws -> [SynologyPhoto] {
        if state == "photo-repair-held" { isControlHeld = true; await withCheckedContinuation { heldControl = $0 } }
        if state == "photo-repair-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-repair-error" { throw URLError(.notConnectedToInternet) }
        if state == "photo-repair-empty" { return [] }
        return uploaded.filter { $0.id.space == space && !repairedPreviews.contains($0.id) }
    }
    func previewImage(for photo: SynologyPhoto) async throws -> Data {
        if state.hasPrefix("photo-export") { return Self.exportImage }
        guard state.hasPrefix("photo-preferences") || state.hasPrefix("photo-repair") || state.hasPrefix("photo-preview") || state.hasPrefix("photo-recognition") || state.hasPrefix("photo-deletion") || state.hasPrefix("photo-similar") else { throw CapabilitySelectionError.unsupported(apiName: "Photos.Thumbnail") }
        return state.hasPrefix("photo-recognition") ? Self.recognitionImage : Self.image
    }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto {
        if state.hasPrefix("photo-preferences"), let current = uploaded.first(where: { $0.id == photo.id }) { return current }
        if state == "photo-edit-held" { isEditHeld = true; await withCheckedContinuation { heldEdit = $0 } }
        if state == "photo-edit-error" { throw URLError(.notConnectedToInternet) }
        if state == "photo-edit-loading" { try await Task.sleep(for: .seconds(30)) }
        guard state.hasPrefix("photo-edit"), let current = uploaded.first(where: { $0.id == photo.id }) else { return photo }
        var result = Self.withDate(photo, date: current.takenAt)
        result.description = current.description; result.rating = current.rating; result.tags = current.tags
        return result
    }
    func download(_ photo: SynologyPhoto, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws -> SynologyPhotoDownloadFormat {
        guard state.hasPrefix("photo-export") else { throw CapabilitySelectionError.unsupported(apiName: "Photos.Download") }
        if state == "photo-export-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-export-error" || (state == "photo-export-partial" && photo.id.unitID == 2) { throw URLError(.notConnectedToInternet) }
        try Self.exportImage.write(to: destination); progress(Int64(Self.exportImage.count), Int64(Self.exportImage.count))
        return .original
    }
    func downloadArchive(_ target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        guard state.hasPrefix("photo-export") else { throw CapabilitySelectionError.unsupported(apiName: "Photos.Download.Archive") }
        // 空 ZIP 的标准结束记录；仅供系统面板交接验证，不冒充真实集合下载结果。
        try Data([0x50, 0x4b, 0x05, 0x06] + Array(repeating: UInt8(0), count: 18)).write(to: destination); progress(22, 22)
    }
    func filterOptions(in space: SynologyPhotoSpace) async throws -> SynologyPhotoFilterOptions {
        if state == "photo-edit-tags-error" { throw URLError(.notConnectedToInternet) }
        if state == "photo-edit-tags-loading" { try await Task.sleep(for: .seconds(30)) }
        return .init(people: [], locations: [], tags: state == "photo-edit-tags-empty" ? [] : tagChoices)
    }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: 1, name: "Sample folder", path: "/", space: space) }
    func folder(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection {
        if (state.hasPrefix("photo-folders") || state.hasPrefix("photo-folder-sharing") || state.hasPrefix("photo-tasks")) {
            if id == 1 { return try await rootFolder(in: space) }
            guard let folder = folderList.first(where: { $0.id == id && $0.space == space }) else { throw CocoaError(.fileReadNoSuchFile) }
            return folder
        }
        return .init(id: id, name: "Sample folder", parentID: id == 1 ? nil : 1, path: "/Sample folder", space: space)
    }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        if (state.hasPrefix("photo-folders") || state.hasPrefix("photo-folder-sharing") || state.hasPrefix("photo-tasks")) {
            if state == "photo-folders-error" { throw URLError(.notConnectedToInternet) }
            if state == "photo-folders-loading" { try await Task.sleep(for: .seconds(30)) }
            if state == "photo-folders-held" { isFolderHeld = true; await withCheckedContinuation { heldFolder = $0 } }
            if state == "photo-folders-empty" { return [] }
            return Array(folderList.filter { $0.space == space && $0.parentID == parentID }.dropFirst(offset).prefix(limit))
        }
        if state == "photo-request-folders-error" || state == "photo-condition-folders-error" { throw URLError(.notConnectedToInternet) }
        guard (state.hasPrefix("photo-request") || state.hasPrefix("photo-condition")), parentID == 1 else { return [] }
        let count = ["photo-request-paged", "photo-condition-paged"].contains(state) ? 101 : 1
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
    func folderSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort { folderSorts["\(folder.space):\(folder.id)"] ?? .init() }
    private var sharedAdministrationValue: SynologyPhotoSharedSpaceSettings {
        administrationShared ?? .init(profileID: profileID, administratorID: userID, isEnabled: state != "photo-admin-disabled", personalSpaceEnabled: state != "photo-admin-last",
            role: .management, values: state == "photo-admin-empty" ? [:] : [.person: true, .concept: true, .similar: false, .publicRoot: false], globallyEnabled: [.person, .concept, .similar])
    }
    private var globalAdministrationValue: SynologyPhotoGlobalSettings {
        administrationGlobal ?? .init(profileID: profileID, administratorID: userID,
            values: state == "photo-admin-empty" ? [:] : [.person: true, .concept: true, .similar: false, .userSharing: true, .guestInfo: false, .originalJPEG: true],
            excludedExtensions: state == "photo-admin-empty" ? nil : ["LEGACY"], hasHEVC: state != "photo-admin-restricted",
            personalRecognition: [.person: true, .concept: true, .similar: false], sharedRecognition: [.person: true, .concept: true, .similar: false],
            personalSpaceEnabled: true, sharedSpaceEnabled: sharedAdministrationValue.isEnabled, sharedRole: sharedAdministrationValue.role)
    }
    private var memberAdministrationValue: SynologyPhotoSharedMembers {
        administrationMembers ?? .init(profileID: profileID, administratorID: userID, isEnabled: sharedAdministrationValue.isEnabled, members: state == "photo-admin-empty" ? [] : [
            .init(recipient: .init(id: .init(type: "group", value: .integer(1)), name: "administrators"), role: .management),
            .init(recipient: .init(id: .init(type: "user", value: .integer(12)), name: "Sample member"), role: .entry),
            .init(recipient: .init(id: .init(type: "group", value: .string("fixture-future")), name: "Future group"), role: "future", autoBackup: false)])
    }
    private var cacheAdministrationValue: SynologyPhotoConversionCache {
        administrationCache ?? .init(profileID: profileID, administratorID: userID, sizeBytes: 2048, isClearing: state == "photo-admin-busy")
    }
    private func administrationRead() async throws {
        if state == "photo-admin-held" { isControlHeld = true; await withCheckedContinuation { heldControl = $0 } }
        if state == "photo-admin-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-admin-error" { throw URLError(.notConnectedToInternet) }
    }
    func sharedSpaceSettings() async throws -> SynologyPhotoSharedSpaceSettings { try await administrationRead(); return sharedAdministrationValue }
    func globalSettings() async throws -> SynologyPhotoGlobalSettings { try await administrationRead(); return globalAdministrationValue }
    func conversionCache() async throws -> SynologyPhotoConversionCache { try await administrationRead(); return cacheAdministrationValue }
    func sharedSpaceMembers() async throws -> SynologyPhotoSharedMembers { try await administrationRead(); return memberAdministrationValue }
    func sharedSpaceMemberCandidates() async throws -> [SynologyPhotoShareRecipient] {
        if state == "photo-admin-candidates-error" { throw URLError(.notConnectedToInternet) }
        return memberAdministrationValue.members.map(\.recipient) + [.init(id: .init(type: "user", value: .integer(23)), name: "New member")]
    }
    func sharedSpaceMemberFolderSnapshot(for member: SynologyPhotoShareRecipient.ID) async throws -> [SynologyPhotoMemberFolder] {
        if state == "photo-admin-folders-error" { throw URLError(.notConnectedToInternet) }
        if let value = administrationFolders[member] { return value }
        if state == "photo-admin-empty" { return [] }
        return [
            .init(profileID: profileID, memberID: member, rootID: 1, folder: .init(id: 9, name: "Sample folder", parentID: 1, path: "/Sample folder", space: .shared), depth: 0, privacy: "private", directRole: "view", revision: "fixture-parent"),
            .init(profileID: profileID, memberID: member, rootID: 1, folder: .init(id: 10, name: "Child folder", parentID: 9, path: "/Sample folder/Child folder", space: .shared), depth: 1, privacy: "private", directRole: "download", revision: "fixture-child"),
            .init(profileID: profileID, memberID: member, rootID: 1, folder: .init(id: 11, name: "Public folder", parentID: 1, path: "/Public folder", space: .shared), depth: 0, privacy: "public-download", directRole: nil, revision: "fixture-public")]
    }

    func seedAutomaticEnabled(_ value: Bool) { automaticEnabled = value }
    func finishMaintenance() { maintenanceRunning = [:] }
    private func previewSettingsRead() async throws {
        if state.hasSuffix("held") { isControlHeld = true; await withCheckedContinuation { heldControl = $0 } }
        if state.hasSuffix("loading") { try await Task.sleep(for: .seconds(30)) }
        if state.hasSuffix("error") { throw URLError(.notConnectedToInternet) }
    }
    func automaticPreviewEnabled() async throws -> Bool { try await previewSettingsRead(); return automaticEnabled }
    func codecPrompt() async throws -> SynologyPhotoCodecPrompt {
        try await previewSettingsRead()
        return .init(profileID: profileID, userID: userID, isAdministrator: state == "photo-preview-admin",
            shouldShow: codecShown, personalSpaceEnabled: state != "photo-preview-nohome", generationAlreadySubmitted: codecSubmitted)
    }
    func libraryMaintenanceStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoLibraryMaintenanceStatus {
        try await previewSettingsRead()
        return .init(profileID: profileID, userID: userID, space: space,
            indexingCount: maintenanceRunning[space] == .reindex ? 4 : 0, previewCount: maintenanceRunning[space] == .previews ? 5 : 0,
            supportsPreviewGeneration: state != "photo-preview-unsupported")
    }
    func automaticPreviewTasks(in space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport) async throws -> [SynologyPhotoAutomaticPreviewTask] {
        guard state.hasPrefix("photo-preview"), automaticEnabled else { return [] }
        return uploaded.filter { $0.id.space == space && !automaticFinished.contains($0.thumbnail?.unitID ?? 0) }.map {
            .init(profileID: profileID, space: space, unitID: $0.thumbnail?.unitID ?? 0, filename: $0.filename,
                typeCode: 0, needsThumbnail: true, needsVideo: false, sourcePhoto: $0)
        }
    }
    func automaticPreviewTasks(for photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport) async throws -> [SynologyPhotoAutomaticPreviewTask] {
        try await automaticPreviewTasks(in: photo.id.space, support: support).filter { $0.sourcePhoto?.id == photo.id }
    }
    private func preferenceRead() async throws {
        if state == "photo-preferences-held" { isControlHeld = true; await withCheckedContinuation { heldControl = $0 } }
        if state == "photo-preferences-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-preferences-error" { throw URLError(.notConnectedToInternet) }
    }
    func duplicateSettings() async throws -> SynologyPhotoDuplicateSettings {
        try await preferenceRead()
        return state == "photo-folders-defaults" ? .init(upload: .ignore, transfer: .overwrite) : duplicateValue
    }
    func displaySettings() async throws -> SynologyPhotoDisplaySettings { try await preferenceRead(); return displayValue }
    func recognitionSettings() async throws -> SynologyPhotoRecognitionSettings { try await preferenceRead(); return recognitionValue }
    func seedDisplay(_ value: SynologyPhotoDisplaySettings) { displayValue = value }

    func releaseFolder() { heldFolder?.resume(); heldFolder = nil }
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
    func releaseDeletion() { heldDeletion?.resume(); heldDeletion = nil }
    func prepareDeletion(_ photo: SynologyPhoto) async throws {
        guard state.hasPrefix("photo-deletion") || state.hasPrefix("photo-similar"), photo.id.profileID == profileID,
              !deniesWrites, !state.hasSuffix("-readonly"), state != "photo-deletion-denied" else {
            throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "Deletion is not allowed.")
        }
        if state == "photo-deletion-loading" { try await Task.sleep(for: .seconds(30)) }
        if state == "photo-deletion-error" { throw URLError(.notConnectedToInternet) }
        if state == "photo-deletion-prepare-held" { isDeletionHeld = true; await withCheckedContinuation { heldDeletion = $0 } }
        guard let current = uploaded.first(where: { $0.id == photo.id }), current.filename == photo.filename,
              current.sizeBytes == photo.sizeBytes, current.folderID == photo.folderID, current.takenAt == photo.takenAt,
              current.indexedAt == photo.indexedAt else { throw CocoaError(.fileReadCorruptFile) }
    }
    func performRecoverableDeletion(_ photo: SynologyPhoto, operationID: UUID,
        checkpoint: @escaping @Sendable (SynologyPhotoDeletionCheckpoint) throws -> Void) async throws -> SynologyPhotoDeletionResult {
        try await prepareDeletion(photo)
        try Task.checkCancellation()
        let identity = try await uploadRecoveryIdentity()
        var saved = try SynologyPhotoDeletionCheckpoint(photo: photo, operationID: operationID, identity: identity, state: .submitted)
        try checkpoint(saved)
        deletedPhotoIDs.append(photo.id)
        if state == "photo-deletion-held" { isDeletionHeld = true; await withCheckedContinuation { heldDeletion = $0 } }
        if state == "photo-deletion-partial", photo.id.unitID == 2 {
            saved.state = .rejected; try checkpoint(saved)
            throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "Deletion is not allowed.")
        }
        if pending { return .pendingReview }
        uploaded.removeAll { $0.id == photo.id }
        saved.state = .confirmed; try checkpoint(saved)
        return .confirmed
    }
    func reviewDeletion(_ checkpoint: SynologyPhotoDeletionCheckpoint) async throws -> SynologyPhotoDeletionResult {
        try checkpoint.validate()
        guard checkpoint.identity == (try await uploadRecoveryIdentity()), [.submitted, .confirmed].contains(checkpoint.state) else { throw CocoaError(.fileReadNoPermission) }
        deletionReads += 1
        if pending { return .pendingReview }
        uploaded.removeAll { $0.id == checkpoint.target.id }
        return .confirmed
    }
    func deletionTarget(_ checkpoint: SynologyPhotoDeletionCheckpoint) async throws -> SynologyPhoto {
        try checkpoint.validate()
        guard checkpoint.identity == (try await uploadRecoveryIdentity()), checkpoint.state == .prepared,
              let photo = uploaded.first(where: { $0.id == checkpoint.target.id }) else { throw CocoaError(.fileReadNoPermission) }
        let value = SynologyPhoto(id: photo.id, filename: photo.filename, sizeBytes: photo.sizeBytes, takenAt: photo.takenAt,
            indexedAt: photo.indexedAt, folderID: photo.folderID, mediaType: photo.mediaType, albumContext: checkpoint.target.queryPhoto.albumContext)
        guard try checkpoint.matches(value) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    func uploadRecoveryIdentity() async throws -> String { "\(profileID.uuidString):\(userID)" }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws {
        if deniesWrites { throw CocoaError(.fileWriteNoPermission) }
        if case .editSimilarGroup(let detail, let edit) = mutation {
            let saved = try SynologyPhotosAlbumCheckpoint(mutation: mutation, operationID: UUID(), profileID: profileID, userID: userID)
            _ = try similarTargets(saved)
            if case .undo = edit {} else {
                guard try await similarGroupDetails(detail.group)?.group == detail.group else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
        if case .shareAlbum(_, _, let original, _, _, _) = mutation, original?.revision != sharingValue.revision { throw CocoaError(.fileWriteNoPermission) }
        if case .unfreezeAlbum(let original) = mutation, frozenValue?.hasSameState(as: original) != true { throw CocoaError(.fileWriteNoPermission) }
        if case .rebuildFrozenAlbum(let original, _, _) = mutation, frozenValue?.hasSameState(as: original) != true { throw CocoaError(.fileWriteNoPermission) }
        if case .setAlbumCondition(let id, let original, _) = mutation, original != conditions[id] { throw CocoaError(.fileWriteNoPermission) }
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
        if case .editSimilarGroup(let detail, let edit) = mutation {
            try await prepareMutation(mutation); try Task.checkCancellation()
            var saved = try SynologyPhotosAlbumCheckpoint(mutation: mutation, operationID: operationID, profileID: profileID, userID: userID)
            try checkpoint(saved); saved.similarDetails?.submitted = true; try checkpoint(saved)
            commands.append(mutation)
            if state.hasPrefix("photo-similar-held") { isSimilarHeld = true; await withCheckedContinuation { heldSimilar = $0 } }
            if (state == "photo-similar-partial" && detail.group.id == 32) || state == "photo-similar-held-rejected" { saved.rejected = true }
            else { applySimilar(detail, edit: edit) }
            albumRecords[operationID] = saved; try checkpoint(saved)
            return albumResult(saved)
        }
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
        case .renamePerson, .mergePeople, .setPersonCover, .setPeopleVisibility, .removePersonFaces, .reassignPersonFaces, .setConceptCover, .removeConceptItems, .setConceptVisibility, .editPhotoFaces:
            recognitionResults[operationID] = applyRecognition(mutation, saved: &saved)
        case .setSharedSpaceEnabled(let original, let enabled):
            var value = original; value.isEnabled = enabled; administrationShared = value
        case .setSharedSpaceSettings(let original, let enabled):
            var value = original; for kind in value.values.keys { value.values[kind] = enabled.contains(kind) }; administrationShared = value
        case .setGlobalSettings(let original, let enabled, let excluded):
            var value = original.applying(enabled: enabled, excludedExtensions: excluded)
            if state == "photo-admin-partial" { value.personalRecognition = original.personalRecognition; value.sharedRecognition = original.sharedRecognition }
            administrationGlobal = value
            if var details = saved.administrationDetails {
                if original.values != value.values || original.excludedExtensions != value.excludedExtensions { details.globalAttempted.insert(.admin) }
                if original.personalRecognition != value.personalRecognition { details.globalAttempted.insert(.personal) }
                if original.sharedRecognition != value.sharedRecognition { details.globalAttempted.insert(.shared) }
                if original.values[.originalJPEG] == true && value.values[.originalJPEG] == false {
                    details.globalAttempted.insert(.cache); administrationCache = .init(profileID: profileID, administratorID: userID, sizeBytes: 0, isClearing: false)
                }
                let ordered = [SynologyPhotosAlbumCheckpoint.Administration.GlobalStep.cache, .admin, .personal, .shared].filter(details.globalAttempted.contains)
                details.globalAcknowledged = pending ? Set(ordered.dropLast()) : details.globalAttempted; saved.administrationDetails = details
            }
        case .clearConversionCache:
            administrationCache = .init(profileID: profileID, administratorID: userID, sizeBytes: 0, isClearing: false)
            if var details = saved.administrationDetails {
                details.globalAttempted = [.cache]; details.globalAcknowledged = pending ? [] : [.cache]; saved.administrationDetails = details
            }
        case .setSharedMembers(let original, let target, let edits):
            administrationMembers = .init(profileID: profileID, administratorID: userID, isEnabled: original.isEnabled, members: target)
            for edit in edits {
                administrationFolders[edit.memberID] = edit.original.map { value in
                    .init(profileID: value.profileID, memberID: value.memberID, rootID: value.rootID, folder: value.folder,
                        depth: value.depth, privacy: value.privacy, directRole: edit.expectedRole(for: value), revision: "fixture-updated")
                }
            }
            if var details = saved.administrationDetails {
                let old = Dictionary(uniqueKeysWithValues: original.members.map { ($0.id, $0) }), new = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0) })
                let count = (old == new ? 0 : 1) + edits.reduce(0) { $0 + ($1.batch == nil ? 0 : 1) + ($1.changes.isEmpty ? 0 : 1) }
                details.memberAttempted = Set(0..<count); details.memberAcknowledged = pending ? Set(0..<max(0, count - 1)) : details.memberAttempted; saved.administrationDetails = details
            }
        case .setAutomaticPreview(_, let enabled): automaticEnabled = enabled
        case .respondToCodecPrompt(let original, let generate):
            if generate { codecSubmitted = true }
            let partial = state == "photo-preview-partial" && generate
            if !partial { codecShown = false }
            saved.previewMaintenanceDetails = .codec(original, generate: generate, acknowledged: generate, promptRejected: partial)
        case .maintainLibrary(let original, let action):
            if state.hasSuffix("running") { maintenanceRunning[original.space] = action }
            saved.previewMaintenanceDetails = .library(original, action, acknowledged: !pending)
        case .generateAutomaticPreview(let task, _):
            if state == "photo-preview-automatic-slow" {
                do { try await Task.sleep(for: .seconds(30)) }
                catch {
                    saved.rejected = true; albumRecords[operationID] = saved; try checkpoint(saved)
                    return .init(state: .rejected)
                }
            }
            if case .automatic(var value) = saved.previewMaintenanceDetails {
                value.submitted = true; value.acknowledged = !pending
                value.thumbnailDigests = ["xl": Data(repeating: 1, count: 32), "sm": Data(repeating: 2, count: 32), "m": Data(repeating: 3, count: 32)]
                saved.previewMaintenanceDetails = .automatic(value)
            }
            automaticFinished.insert(task.unitID)
        case .regeneratePreviews(let photos, _):
            if var value = saved.previewRegenerationDetails {
                for index in value.targets.indices {
                    value.targets[index].marking = true; value.targets[index].marked = true; value.targets[index].submitted = true
                    if state == "photo-repair-partial", index > 0 { value.targets[index].failed = true }
                    else { value.targets[index].generated = true; repairedPreviews.insert(photos[index].id) }
                }
                saved.previewRegenerationDetails = value
            }
        case .setDuplicateSettings(_, let updated): duplicateValue = updated
        case .setDisplaySettings(_, let updated): displayValue = updated
        case .setRecognitionSettings(let original, let enabled):
            recognitionValue = .init(values: original.values.mapValues { _ in false }.merging(Dictionary(uniqueKeysWithValues: enabled.map { ($0, true) })) { _, new in new },
                globallyEnabled: original.globallyEnabled, personalSpaceEnabled: original.personalSpaceEnabled)
        case .rotatePhoto(let photo):
            uploaded = uploaded.map { old in
                guard old.id == photo.id else { return old }
                return .init(id: old.id, filename: old.filename, sizeBytes: old.sizeBytes, takenAt: old.takenAt, indexedAt: old.indexedAt,
                    folderID: old.folderID, mediaType: old.mediaType, width: old.height, height: old.width, orientation: old.counterClockwiseOrientation, albumContext: old.albumContext)
            }
        case .setFolderSharing(let original, let access, let members, let password, let apply):
            folderSharingValues[original.folder.id] = .init(folder: original.folder, access: access, url: original.url,
                hasPassword: password.map { !$0.isEmpty } ?? original.hasPassword, members: members ?? original.members,
                parentIsShared: original.parentIsShared, appliesToSubfolders: state == "photo-folder-sharing-partial" ? original.appliesToSubfolders : apply,
                revision: "synthetic-updated")
            if var sharing = saved.folderSharingDetails { sharing.acknowledged = !pending; saved.folderSharingDetails = sharing }
        case .cancelBackgroundTask(let task):
            taskList.removeAll { $0.id == task.id }
            taskList.append(.init(profileID: task.profileID, userID: task.userID, id: task.id, operation: task.operation,
                status: .done, total: task.total, completion: task.completion, errors: task.errors, skipped: task.skipped,
                overwritten: task.overwritten, createdAt: task.createdAt, targetFolderID: task.targetFolderID, targetOwnerID: task.targetOwnerID))
        case .clearBackgroundTasks(let tasks):
            let targets = state == "photo-tasks-partial" ? Array(tasks.prefix(1)) : tasks
            taskList.removeAll { candidate in targets.contains { $0.id == candidate.id } }
            if var control = saved.backgroundDetails { control.attempted = Set(targets.map(\.id)); saved.backgroundDetails = control }
        case .createFolder(let parent, let name, let space):
            nextID += 1
            let ancestor = try await folder(id: parent, in: space)
            let path = ancestor.path == "/" ? "/" + name : (ancestor.path ?? "") + "/" + name
            folderList.append(.init(id: nextID, name: name, parentID: parent, path: path, space: space))
            if var folder = saved.folderDetails { folder.createdFolderID = nextID; saved.folderDetails = folder }
        case .renameFolder(let target, let name):
            let parentPath = ((target.path ?? "") as NSString).deletingLastPathComponent
            let path = (parentPath == "/" ? "/" : parentPath + "/") + name
            if let index = folderList.firstIndex(where: { $0.id == target.id && $0.space == target.space }) {
                folderList[index] = .init(id: target.id, name: name, parentID: target.parentID, path: path, space: target.space)
            }
        case .setFolderSort(let target, let sort): folderSorts["\(target.space):\(target.id)"] = sort
        case .setFolderCover:
            if var folder = saved.folderDetails { folder.coverAcknowledged = true; saved.folderDetails = folder }
        case .deleteFolderItems(let photos, let targets):
            uploaded.removeAll { photo in photos.contains { $0.id == photo.id } }
            folderList.removeAll { folder in targets.contains { $0.id == folder.id && $0.space == folder.space } }
            if var folder = saved.folderDetails { folder.taskID = 88; saved.folderDetails = folder }
        case .move(let photos, let target, _, let sources, _), .copy(let photos, let target, _, let sources, _):
            let copying = if case .copy = mutation { true } else { false }
            let destination = try await folder(id: target, in: mutation.destinationSpace)
            for photo in photos {
                if copying { nextID += 1 }
                let updated = SynologyPhoto(id: .init(profileID: profileID, space: mutation.destinationSpace, unitID: copying ? nextID : photo.id.unitID),
                    filename: photo.filename, sizeBytes: photo.sizeBytes, takenAt: photo.takenAt, indexedAt: photo.indexedAt, folderID: target, mediaType: photo.mediaType)
                if !copying { uploaded.removeAll { $0.id == photo.id } }
                uploaded.append(updated)
            }
            for source in sources {
                if copying { nextID += 1 }
                if !copying { folderList.removeAll { $0.id == source.id && $0.space == source.space } }
                folderList.append(.init(id: copying ? nextID : source.id, name: source.name, parentID: target,
                    path: (destination.path == "/" ? "/" : (destination.path ?? "") + "/") + source.name, space: destination.space))
            }
            if var folder = saved.folderDetails {
                folder.taskID = 88; folder.transferTargetVerified = true; folder.transferTotal = photos.count + sources.count
                saved.folderDetails = folder
            }
        case .edit, .shiftDates, .createTag, .addTags, .removeTags:
            if var summary = saved.photoEditDetails {
                var tag: SynologyPhotoFilterChoice?
                if case .createTag(let name, _, _) = mutation {
                    nextID += 1; tag = .init(id: nextID, name: name); tagChoices.append(tag!)
                    summary.createdTagID = nextID
                    summary.tagAdditionAttempted = !mutation.photos.isEmpty && state != "photo-edit-tag-partial"
                }
                let partial = state == "photo-edit-partial" && rejectsAlbum && mutation.photos.count > 1
                summary.attempted = partial ? [0] : Set(mutation.photos.indices)
                if partial { rejectsAlbum = false }
                for (index, photo) in mutation.photos.enumerated() where summary.attempted.contains(index) {
                    if case .createTag = mutation, !summary.tagAdditionAttempted { continue }
                    var updated = photo
                    switch mutation {
                    case .edit(_, .rating(let value)): updated.rating = value
                    case .edit(_, .description(let value)): updated.description = value
                    case .edit(_, .takenAt(let date)): updated = Self.withDate(photo, date: date)
                    case .shiftDates(_, let seconds): updated = Self.withDate(photo, date: photo.takenAt.addingTimeInterval(Double(seconds)))
                    case .addTags(_, let ids): updated.tags = Array(Set((photo.tags ?? []) + tagChoices.filter { ids.contains($0.id) }))
                    case .removeTags(_, let ids): updated.tags = (photo.tags ?? []).filter { !ids.contains($0.id) }
                    case .createTag: updated.tags = (photo.tags ?? []) + (tag.map { [$0] } ?? [])
                    default: break
                    }
                    if let position = uploaded.firstIndex(where: { $0.id == photo.id }) { uploaded[position] = updated }
                }
                saved.photoEditDetails = summary
            }
        case .unfreezeAlbum(let original):
            albumList.removeAll { $0.id == original.album.id }
            albumList.append(.init(id: original.album.id, name: original.album.name, itemCount: original.album.itemCount))
        case .rebuildFrozenAlbum(let original, let name, let condition):
            nextID += 1; saved.createdAlbumID = nextID
            seedCondition(condition, id: nextID, name: name)
            if state != "photo-frozen-partial" {
                if var value = saved.frozenDetails { value.deletionAttempted = true; saved.frozenDetails = value }
                try checkpoint(saved)
                albumList.removeAll { $0.id == original.album.id }
            }
        case .createConditionAlbum(let name, let condition):
            nextID += 1; saved.createdAlbumID = nextID
            seedCondition(condition, id: nextID, name: name)
        case .setAlbumCondition(let id, _, let condition): conditions[id] = condition
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
        if case .codec(_, _, let acknowledged, _) = checkpoint.previewMaintenanceDetails, acknowledged { codecSubmitted = true }
    }
    private func albumResult(_ saved: SynologyPhotosAlbumCheckpoint) -> SynologyPhotosMutationResult {
        if case .codec(_, true, true, true) = saved.previewMaintenanceDetails {
            return .init(state: codecShown ? .partial : .confirmed, completedCount: 1)
        }
        if pending { return .init(state: .pendingReview) }
        if saved.rejected { return .init(state: .rejected) }
        switch saved.operation {
        case .similar(let value):
            guard value.submitted else { return .init(state: .rejected) }
            guard let photos = try? similarTargets(saved) else { return .init(state: .pendingReview) }
            let current = photos.compactMap(\.similarGroup).first { $0.id == value.group.id }
            let matches: Bool
            switch value.edit {
            case .ungroup: matches = current == nil && photos.allSatisfy { $0.similarGroup?.id != value.group.id }
            case .topPick(let id): matches = current?.topPickID == id && current?.photoIDs == value.group.photoIDs && photos.allSatisfy { $0.similarGroup == current }
            case .remove(let removed):
                let remaining = Set(value.group.photoIDs).subtracting(removed)
                matches = (remaining.count < 2 ? current == nil : current.map { Set($0.photoIDs) == remaining } == true) &&
                    photos.filter { removed.contains($0.id.unitID) }.allSatisfy { $0.similarGroup?.id != value.group.id }
            case .undo: matches = current == value.group && photos.allSatisfy { $0.similarGroup == current }
            }
            return .init(state: matches ? .confirmed : .pendingReview, photos: photos, completedCount: matches ? 1 : 0, similarGroup: current)
        case .recognition: return recognitionResults[saved.operationID] ?? .init(state: .pendingReview)
        case .administration(let value):
            switch value.intent {
            case .sharedEnabled, .sharedSettings: return .init(state: .confirmed, completedCount: 1, sharedSpaceSettings: sharedAdministrationValue)
            case .global: return .init(state: state == "photo-admin-partial" ? .partial : .confirmed, completedCount: value.globalAttempted.count, globalSettings: globalAdministrationValue)
            case .cache: return .init(state: .confirmed, completedCount: 1, conversionCache: cacheAdministrationValue)
            case .members: return .init(state: .confirmed, completedCount: value.memberAttempted.count, sharedSpaceSettings: sharedAdministrationValue, sharedMembers: memberAdministrationValue)
            }
        case .previewMaintenance(let value):
            switch value {
            case .setting(_, let enabled): return .init(state: automaticEnabled == enabled ? .confirmed : .pendingReview, completedCount: 1)
            case .codec(_, let generate, let acknowledged, let rejected):
                return .init(state: generate && acknowledged && rejected ? .partial : .confirmed, completedCount: 1)
            case .library(let original, let action, let acknowledged):
                return .init(state: acknowledged && maintenanceRunning[original.space] != action ? .confirmed : .pendingReview, completedCount: 1)
            case .automatic: return .init(state: .confirmed, completedCount: 1)
            }
        case .previewRegeneration(let value):
            let photos = value.targets.filter { $0.generated }.map { $0.original.photo }
            return .init(state: photos.count == value.targets.count ? .confirmed : photos.isEmpty ? .rejected : .partial,
                photos: photos, completedCount: photos.count)
        case .preference(let value):
            if case .rotation(let original) = value, let photo = uploaded.first(where: { $0.id == original.photo.id }) {
                return .init(state: photo.orientation == original.photo.counterClockwiseOrientation && photo.width == original.photo.height && photo.height == original.photo.width ? .confirmed : .pendingReview, photos: [photo], completedCount: 1)
            }
            return .init(state: .confirmed, completedCount: 1)
        case .folderSharing(let summary):
            guard let value = folderSharingValues[summary.folder.id] else { return .init(state: .pendingReview) }
            return .init(state: state == "photo-folder-sharing-partial" ? .partial : .confirmed, sharingURL: value.url, folder: value.folder)
        case .background(let summary):
            guard let mutation = try? saved.reviewMutation() else { return .init(state: .pendingReview) }
            if case .cancelBackgroundTask(let task) = mutation {
                return .init(state: taskList.first { $0.id == task.id }?.status == .done ? .confirmed : .pendingReview, completedCount: 1)
            }
            if case .clearBackgroundTasks(let tasks) = mutation {
                let done = tasks.filter { original in !taskList.contains { $0.id == original.id } }.count
                return .init(state: done == tasks.count ? .confirmed : summary.attempted.count == done ? .partial : .pendingReview, completedCount: done)
            }
            return .init(state: .pendingReview)
        case .folder(let summary):
            guard let command = try? saved.reviewMutation() else { return .init(state: .pendingReview) }
            switch command {
            case .createFolder:
                guard let id = summary.createdFolderID, let folder = folderList.first(where: { $0.id == id && $0.space == command.space }) else { return .init(state: .pendingReview) }
                return .init(state: .confirmed, folder: folder)
            case .renameFolder(let target, _), .setFolderSort(let target, _), .setFolderCover(let target, _):
                return .init(state: .confirmed, folder: folderList.first { $0.id == target.id && $0.space == target.space } ?? target)
            case .deleteFolderItems(let photos, let targets):
                guard summary.taskID != nil else { return .init(state: .pendingReview) }
                return .init(state: .confirmed, completedCount: photos.count + targets.count, deletedFolders: targets, deletedPhotoIDs: photos.map(\.id))
            case .move, .copy:
                guard summary.taskID != nil else { return .init(state: .pendingReview) }
                return .init(state: state == "photo-folders-partial" ? .partial : .confirmed,
                    photos: uploaded.filter { current in command.photos.contains { $0.id == current.id } }, completedCount: command.photos.count + command.transferFolders.count)
            default: return .init(state: .pendingReview)
            }
        case .photoEdit(let summary):
            let updated = summary.targets.compactMap { target in
                uploaded.first { $0.id == target.id && (try? target.matchesIdentity($0)) == true && (try? summary.matchesValue($0, target: target)) == true }
            }
            let tag = tagChoices.first { (try? summary.matchesTag($0)) == true }
            return .init(state: updated.count == summary.targets.count ? .confirmed : .partial,
                         photos: updated, completedCount: updated.count, tag: tag)
        case .frozen(let summary):
            if let condition = summary.rebuiltCondition {
                guard let id = saved.createdAlbumID, let album = albumList.first(where: { $0.id == id }),
                      let rules = conditions[id], (try? condition.matches(name: album.name, condition: rules, userID: userID)) == true else { return .init(state: .pendingReview) }
                let oldExists = albumList.contains { $0.id == summary.albumID }
                return .init(state: oldExists ? (!summary.deletionAttempted || summary.deletionRejected ? .partial : .pendingReview) : .confirmed, album: album)
            }
            guard let album = albumList.first(where: { $0.id == summary.albumID }), !album.isFrozen,
                  !album.isConditional, summary.matchesOriginal(album) else { return .init(state: .pendingReview) }
            return .init(state: .confirmed, album: album)
        case .condition(let summary):
            guard let id = summary.albumID ?? saved.createdAlbumID, let condition = conditions[id],
                  let album = albumList.first(where: { $0.id == id }),
                  (try? summary.matches(name: album.name, condition: condition, userID: userID)) == true else { return .init(state: .pendingReview) }
            return .init(state: .confirmed, album: album)
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
    // 几何色块作为编辑画布，不包含真实照片或人物。
    static let recognitionImage: Data = {
        let context = CGContext(data: nil, width: 384, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.18, green: 0.3, blue: 0.45, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 384, height: 256))
        context.setFillColor(CGColor(red: 0.96, green: 0.66, blue: 0.28, alpha: 1)); context.fillEllipse(in: CGRect(x: 38, y: 26, width: 114, height: 76))
        context.setFillColor(CGColor(red: 0.35, green: 0.77, blue: 0.71, alpha: 1)); context.fillEllipse(in: CGRect(x: 210, y: 128, width: 114, height: 76))
        let data = NSMutableData()
        let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil); precondition(CGImageDestinationFinalize(output))
        return data as Data
    }()
    static let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jf1sAAAAASUVORK5CYII=")!
    private static let exportImage: Data = {
        let source = CGImageSourceCreateWithData(recognitionImage as CFData, nil)!
        let data = NSMutableData(), image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let output = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, image, nil); precondition(CGImageDestinationFinalize(output))
        return data as Data
    }()
    private static func withDate(_ photo: SynologyPhoto, date: Date) -> SynologyPhoto {
        var value = SynologyPhoto(id: photo.id, filename: photo.filename, sizeBytes: photo.sizeBytes, takenAt: date,
            indexedAt: photo.indexedAt, folderID: photo.folderID, mediaType: photo.mediaType, thumbnail: photo.thumbnail,
            width: photo.width, height: photo.height, orientation: photo.orientation, albumContext: photo.albumContext)
        value.description = photo.description; value.rating = photo.rating; value.tags = photo.tags
        return value
    }
}
#endif
