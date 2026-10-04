import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoRequestModel {
    struct Draft: Identifiable {
        let id = UUID()
        let entry: SynologyPhotoSharedEntry?
        let deleting: Bool
        let section: SynologyPhotosSection
        let space: SynologyPhotoSpace
        let scope: SynologyPhotoShareScope
        var title: String { L10n.string(deleting ? "photos.request.delete" : entry == nil ? "photos.request.create" : "photos.request.edit") }
    }
    private(set) var draft: Draft?
    private(set) var original: SynologyPhotoRequest?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var albums: [SynologyPhotoRequestAlbum] = []
    private(set) var albumError: String?
    private(set) var loadingAlbums = false
    private(set) var canCreateAlbum = false
    private(set) var folders: [SynologyPhotoCollection] = []
    private(set) var folderPath: [SynologyPhotoCollection] = []
    private(set) var folderError: String?
    private(set) var loadingFolders = false
    var settings = SynologyPhotoRequestSettings()
    var usesDefaultFolder = true
    var expiration = PhotoSharingExpirationDraft()
    var limitsSize = false
    var sizeMiB = 25
    var sizeEdited = false
    var newAlbumName = ""
    var showsDeleteConfirmation = false
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var albumsTask: Task<Void, Never>?
    @ObservationIgnored private var foldersTask: Task<Void, Never>?
    @ObservationIgnored private var folderGeneration = UUID()

    init(model: SynologyPhotosModel) { self.model = model }

    func canOpen(entry: SynologyPhotoSharedEntry? = nil) -> Bool {
        guard model.canStartManagementMutation, model.managementFeatures.contains(.photoRequests), !model.spaces.isEmpty else { return false }
        if let entry { return model.section == .sharing && model.shareScope == .requests && model.sharedEntries.contains(entry) }
        return true
    }
    func begin(entry: SynologyPhotoSharedEntry? = nil, deleting: Bool = false) {
        guard canOpen(entry: entry), !deleting || entry != nil else { return }
        cancel()
        draft = .init(entry: entry, deleting: deleting, section: model.section, space: model.selectedSpace, scope: model.shareScope)
        load()
    }
    private func isCurrent(_ value: Draft) -> Bool {
        draft?.id == value.id && model.isModuleEnabled && model.section == value.section && model.selectedSpace == value.space &&
            model.shareScope == value.scope && (value.entry.map { model.sharedEntries.contains($0) } ?? true)
    }

    func load() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        isLoading = true; error = nil; original = nil
        loadingTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false; self.loadingTask = nil } }
            guard !Task.isCancelled, self.isCurrent(draft) else { return }
            do {
                if let entry = draft.entry {
                    let value = try await self.model.photoRequest(id: entry.id)
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.original = value; self.settings = value.settings; self.usesDefaultFolder = false
                } else {
                    let space = self.model.defaultPhotoRequestSpace ?? self.model.selectedSpace
                    self.settings = .init(space: space)
                    self.usesDefaultFolder = self.model.canUseDefaultRequestFolder(in: space)
                }
                self.expiration = .init(expiration: self.settings.expiration)
                self.limitsSize = self.settings.sizeLimit > 0
                self.sizeMiB = self.limitsSize ? max(1, Int(self.settings.sizeLimit / 1_048_576)) : 25
                self.sizeEdited = false
                if !draft.deleting { self.loadAlbums() }
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.error = L10n.string("mobile.photos.request.loadFailed") }
            }
        }
    }

    var preparedSettings: SynologyPhotoRequestSettings? {
        var value = settings
        value.subject = value.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model.spaces.contains(value.space), !value.subject.isEmpty, value.subject.utf16.count <= 50, value.description.utf16.count <= 100,
              expiration.isValid, !limitsSize || (1...3000).contains(sizeMiB) else { return nil }
        if usesDefaultFolder {
            guard model.canUseDefaultRequestFolder(in: value.space) else { return nil }
            value.folderID = nil; value.folderPath = SynologyPhotoRequestSettings.defaultFolderPath(subject: value.subject)
        } else {
            guard let folderID = value.folderID, folderID > 0, !value.folderPath.isEmpty else { return nil }
            if original?.isFolderValid == false, value.space == original?.settings.space, folderID == original?.settings.folderID { return nil }
        }
        value.expiration = expiration.change(from: value.expiration) ?? value.expiration
        if sizeEdited || original == nil { value.sizeLimit = limitsSize ? Int64(sizeMiB) * 1_048_576 : 0 }
        return value
    }
    var mutation: SynologyPhotosMutation? {
        guard let draft, isCurrent(draft), canOpen(entry: draft.entry), !isLoading, error == nil else { return nil }
        if draft.deleting { return original.map(SynologyPhotosMutation.deletePhotoRequest) }
        guard let value = preparedSettings else { return nil }
        if let original { return value == original.settings ? nil : .updatePhotoRequest(original: original, settings: value) }
        return .createPhotoRequest(value)
    }
    @discardableResult func submit(confirmedDeletion: Bool = false) -> Bool {
        guard let mutation, draft?.deleting != true || confirmedDeletion else { return false }
        model.submitMutation(mutation)
        guard model.isManaging else { return false }
        cancel(); return true
    }

    func changeSpace(_ space: SynologyPhotoSpace) {
        guard model.spaces.contains(space), settings.space != space else { return }
        settings.space = space; settings.folderID = nil; settings.folderPath = ""
        usesDefaultFolder = model.canUseDefaultRequestFolder(in: space)
        resetFolders()
    }
    func loadFolders(path: [SynologyPhotoCollection] = []) {
        guard let draft, isCurrent(draft), path.allSatisfy({ $0.space == settings.space }) else { return }
        foldersTask?.cancel(); let request = UUID(), space = settings.space
        folderGeneration = request; loadingFolders = true; folderError = nil; folders = []; folderPath = path
        foldersTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.folderGeneration == request { self.loadingFolders = false; self.foldersTask = nil } }
            guard !Task.isCancelled, self.isCurrent(draft) else { return }
            do {
                let (root, children) = try await self.model.managementFolders(parentID: path.last?.id, in: space)
                guard !Task.isCancelled, self.isCurrent(draft), self.folderGeneration == request, self.settings.space == space else { return }
                self.folderPath = path.isEmpty ? [root] : path; self.folders = children
            } catch {
                if !Task.isCancelled, self.isCurrent(draft), self.folderGeneration == request { self.folderError = L10n.string("photos.request.folderReadFailed") }
            }
        }
    }
    @discardableResult func chooseFolder() -> Bool {
        guard let draft, isCurrent(draft), !loadingFolders, folderError == nil,
              let folder = folderPath.last, folder.space == settings.space, let path = folder.path else { return false }
        settings.folderID = folder.id; settings.folderPath = path; usesDefaultFolder = false
        return true
    }
    private func resetFolders() {
        foldersTask?.cancel(); foldersTask = nil; folderGeneration = UUID()
        folders = []; folderPath = []; loadingFolders = false; folderError = nil
    }

    var selectedAlbumID: String {
        get { settings.albumPassphrase.map { "shared:" + $0 } ?? settings.albumID.map { "owned:\($0)" } ?? "" }
        set {
            if newValue.isEmpty { settings.albumID = nil; settings.albumPassphrase = nil }
            else if let album = albums.first(where: { $0.id == newValue }) { settings.albumID = album.albumID; settings.albumPassphrase = album.passphrase }
        }
    }
    func loadAlbums() {
        guard let draft, isCurrent(draft), !loadingAlbums else { return }
        loadingAlbums = true; albumError = nil
        albumsTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.loadingAlbums = false; self.albumsTask = nil } }
            guard !Task.isCancelled, self.isCurrent(draft) else { return }
            let canCreate = await self.model.supportsManagement(.albums, in: .personal)
            guard !Task.isCancelled, self.isCurrent(draft) else { return }
            self.canCreateAlbum = canCreate
            do {
                let values = try await self.model.photoRequestAlbums()
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                self.albums = values
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.albumError = L10n.string("photos.request.albumReadFailed") }
            }
        }
    }
    func createAlbum() {
        let name = newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let draft, isCurrent(draft), canCreateAlbum, model.canStartManagementMutation, !name.isEmpty else { return }
        model.submitMutation(.createAlbum(name: name, photos: [])) { [weak self] result in
            guard let self, self.isCurrent(draft), result.state == .confirmed, let album = result.album else { return }
            self.albums.removeAll { $0.albumID == album.id }
            self.albums.append(.init(albumID: album.id, name: album.name, shared: false))
            self.settings.albumID = album.id; self.settings.albumPassphrase = nil; self.newAlbumName = ""
        }
    }
    func cancel() {
        loadingTask?.cancel(); loadingTask = nil; albumsTask?.cancel(); albumsTask = nil; resetFolders()
        draft = nil; original = nil; settings = .init(); albums = []; isLoading = false; error = nil
        albumError = nil; loadingAlbums = false; canCreateAlbum = false; newAlbumName = ""; showsDeleteConfirmation = false
        expiration = .init(); usesDefaultFolder = true; limitsSize = false; sizeMiB = 25; sizeEdited = false
    }
}
