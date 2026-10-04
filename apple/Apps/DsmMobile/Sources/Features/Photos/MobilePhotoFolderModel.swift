import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoFolderModel {
    enum Action: String, CaseIterable {
        case create, rename, delete, move, copy, sort, cover
        var title: String {
            switch self {
            case .create: L10n.string("photos.folder.create")
            case .rename: L10n.string("photos.folder.rename")
            case .delete: L10n.string("photos.folder.deleteTitle")
            case .move: L10n.string("photos.manage.move")
            case .copy: L10n.string("photos.manage.copy")
            case .sort: L10n.string("photos.folderSort.title")
            case .cover: L10n.string("photos.folderCover.change")
            }
        }
        var isTransfer: Bool { self == .move || self == .copy }
        var feature: SynologyPhotosManagementFeature {
            switch self {
            case .create, .rename: .folders
            case .delete: .folderDeletion
            case .move, .copy: .fileTransfer
            case .sort: .folderSorting
            case .cover: .folderCover
            }
        }
    }
    struct Draft: Identifiable {
        let id = UUID()
        let action: Action
        let space: SynologyPhotoSpace
        let album: SynologyPhotoCollection?
        let target: SynologyPhotoCollection?
        let photos: [SynologyPhoto]
        let folders: [SynologyPhotoCollection]
    }
    private(set) var draft: Draft?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var path: [SynologyPhotoCollection] = []
    private(set) var children: [SynologyPhotoCollection] = []
    private(set) var coverPhotos: [SynologyPhoto] = []
    private(set) var hasMore = false
    private(set) var isLoadingMore = false
    private(set) var moreError: String?
    private(set) var destinationSpace = SynologyPhotoSpace.personal
    var coverPhoto: SynologyPhoto?
    var name = ""
    var duplicate = SynologyPhotoDuplicateSettings.Transfer.skip
    var sort = SynologyPhotoSort()
    var showsConfirmation = false
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var pageSort = SynologyPhotoSort()
    @ObservationIgnored private var loadedDuplicateDefaults = false

    init(model: SynologyPhotosModel) { self.model = model }

    func allows(_ action: Action, folder: SynologyPhotoCollection? = nil, photos: [SynologyPhoto]? = nil, folders: [SynologyPhotoCollection]? = nil) -> Bool {
        let photos = photos ?? model.selectedPhotos, folders = folders ?? model.selectedFolders
        guard model.canStartManagementMutation, model.managementFeatures.contains(action.feature), photos.count + folders.count <= 100 else { return false }
        switch action {
        case .create: return (folder ?? model.currentCreationFolder) != nil
        case .rename, .sort, .cover:
            guard model.section == .folders, let target = folder ?? model.folderHistory.last,
                  target.space == model.selectedSpace, model.folderHistory.contains(target) || model.collections.contains(target) else { return false }
            return action == .sort || (target.path != nil && target.path != "/")
        case .delete:
            return model.section == .folders && !folders.isEmpty && photos.allSatisfy(model.canModifyOriginal) &&
                folders.allSatisfy { $0.space == model.selectedSpace && $0.path != nil && $0.path != "/" && $0.parentID == model.folderHistory.last?.id }
        case .move, .copy:
            return (!photos.isEmpty || !folders.isEmpty) && model.canTransfer(photos, copying: action == .copy, folders: folders)
        }
    }

    func begin(_ action: Action, folder: SynologyPhotoCollection? = nil, photos: [SynologyPhoto]? = nil,
               folders: [SynologyPhotoCollection]? = nil, destinationPath: [SynologyPhotoCollection]? = nil) {
        let selectedPhotos = photos ?? model.selectedPhotos, selectedFolders = folders ?? model.selectedFolders
        guard allows(action, folder: folder, photos: selectedPhotos, folders: selectedFolders) else { return }
        cancel()
        let target = action.isTransfer || action == .delete ? nil : folder ?? model.folderHistory.last
        draft = .init(action: action, space: model.selectedSpace, album: model.selectedAlbum, target: target,
            photos: action.isTransfer || action == .delete ? selectedPhotos : [],
            folders: action.isTransfer || action == .delete ? selectedFolders : [])
        name = action == .rename ? target?.name ?? "" : ""
        sort = target?.sort ?? .init()
        destinationSpace = destinationPath?.last?.space ?? selectedFolders.first?.space ?? selectedPhotos.first?.id.space ?? model.selectedSpace
        if action.isTransfer { load(path: destinationPath ?? []) }
        else if action == .cover, let target { load(path: [target]) }
        else if action == .sort { loadSort() }
    }

    private func loadSort() {
        guard let draft, isCurrent(draft), let target = draft.target, !isLoading else { return }
        isLoading = true; error = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false } }
            do {
                let value = try await self.model.folderCoverSort(target)
                guard self.isCurrent(draft), !Task.isCancelled else { return }
                self.sort = value
            } catch {
                if self.isCurrent(draft), !Task.isCancelled { self.error = L10n.string("mobile.photos.folder.loadFailed") }
            }
        }
    }

    private func isCurrent(_ draft: Draft) -> Bool {
        guard self.draft?.id == draft.id, model.isModuleEnabled, model.selectedSpace == draft.space, model.selectedAlbum == draft.album else { return false }
        if let target = draft.target, !model.folderHistory.contains(target) && !model.collections.contains(target) { return false }
        return draft.folders.allSatisfy { model.collections.contains($0) } && draft.photos.allSatisfy { photo in
            let same: (SynologyPhoto) -> Bool = { current in
                current.id == photo.id && current.filename == photo.filename && current.sizeBytes == photo.sizeBytes &&
                    current.folderID == photo.folderID && current.indexedAt == photo.indexedAt && current.albumContext == photo.albumContext
            }
            return model.items.contains(where: same) || model.previewPhoto.map(same) == true
        }
    }

    var destinationSpaces: [SynologyPhotoSpace] {
        guard let draft, draft.action.isTransfer else { return [] }
        return model.transferDestinationSpaces(for: draft.photos, copying: draft.action == .copy, folders: draft.folders)
    }
    func changeSpace(_ space: SynologyPhotoSpace) {
        guard destinationSpaces.contains(space), space != destinationSpace else { return }
        destinationSpace = space; load(path: [])
    }
    func open(_ folder: SynologyPhotoCollection) {
        guard children.contains(folder), !isLoading, !path.contains(where: { $0.id == folder.id && $0.space == folder.space }) else { return }
        load(path: path + [folder])
    }
    func goBack(to index: Int? = nil) {
        guard path.count > 1, !isLoading else { return }
        let count = index.map { $0 + 1 } ?? path.count - 1
        guard (1..<path.count).contains(count) else { return }
        load(path: Array(path.prefix(count)))
    }
    func retry() {
        guard let draft else { return }
        if draft.action == .sort { loadSort() }
        else { load(path: path) }
    }

    private func load(path requested: [SynologyPhotoCollection]) {
        guard let draft, isCurrent(draft) else { return }
        task?.cancel(); let id = UUID(); loadID = id
        let space = destinationSpace
        path = requested; children = []; coverPhotos = []; coverPhoto = nil
        error = nil; moreError = nil; isLoading = true; isLoadingMore = false; hasMore = false
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.loadID == id { self.isLoading = false } }
            do {
                if draft.action.isTransfer, !self.loadedDuplicateDefaults, self.model.managementFeatures.contains(.duplicateSettings) {
                    let defaults = try await self.model.duplicateSettings()
                    guard self.loadID == id, self.isCurrent(draft), !Task.isCancelled else { return }
                    self.duplicate = defaults.transfer; self.loadedDuplicateDefaults = true
                }
                let (root, children) = try await self.model.managementFolders(parentID: requested.last?.id, in: space)
                let folder = requested.last ?? root
                let sort = draft.action == .cover ? try await self.model.folderCoverSort(folder) : SynologyPhotoSort()
                let page = draft.action == .cover ? try await self.model.folderCoverPage(folder, offset: 0, sort: sort) : nil
                guard self.loadID == id, self.isCurrent(draft), !Task.isCancelled else { return }
                self.path = requested.isEmpty ? [root] : requested
                self.children = children; self.pageSort = sort
                self.coverPhotos = page?.items ?? []; self.hasMore = page?.hasMore ?? false
            } catch {
                if self.loadID == id, self.isCurrent(draft), !Task.isCancelled {
                    self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("mobile.photos.folder.loadFailed")
                }
            }
        }
    }

    func loadMore() async {
        guard let draft, isCurrent(draft), draft.action == .cover, hasMore, !isLoadingMore, let folder = path.last else { return }
        let id = loadID, offset = coverPhotos.count
        isLoadingMore = true; moreError = nil
        defer { if loadID == id { isLoadingMore = false } }
        do {
            let page = try await model.folderCoverPage(folder, offset: offset, sort: pageSort)
            guard id == loadID, isCurrent(draft), !Task.isCancelled else { return }
            coverPhotos.append(contentsOf: page.items); hasMore = page.hasMore
        } catch {
            if id == loadID, isCurrent(draft), !Task.isCancelled { moreError = L10n.string("photos.folderCover.failed") }
        }
    }

    var mutation: SynologyPhotosMutation? {
        guard let draft, isCurrent(draft), !isLoading, error == nil,
              allows(draft.action, folder: draft.target, photos: draft.photos, folders: draft.folders) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch draft.action {
        case .create: return draft.target.flatMap { SynologyPhotosMutation.isValidFolderName(trimmed) ? .createFolder(parentID: $0.id, name: trimmed, space: $0.space) : nil }
        case .rename: return draft.target.flatMap { SynologyPhotosMutation.isValidFolderName(trimmed) && trimmed != $0.name ? .renameFolder(folder: $0, name: trimmed) : nil }
        case .sort: return draft.target.map { .setFolderSort(folder: $0, sort: sort) }
        case .cover:
            guard let target = draft.target, let photo = coverPhoto, coverPhotos.contains(photo) else { return nil }
            return .setFolderCover(folder: target, photo: photo)
        case .delete: return .deleteFolderItems(photos: draft.photos, folders: draft.folders)
        case .move, .copy:
            guard let folder = path.last, destinationSpaces.contains(folder.space) else { return nil }
            let command: SynologyPhotosMutation = draft.action == .copy
                ? .copy(draft.photos, folderID: folder.id, destinationSpace: folder.space, folders: draft.folders, duplicate: duplicate)
                : .move(draft.photos, folderID: folder.id, destinationSpace: folder.space, folders: draft.folders, duplicate: duplicate)
            return command.acceptsTransferDestination(folder) ? command : nil
        }
    }

    var needsConfirmation: Bool { draft?.action == .delete || (draft?.action.isTransfer == true && duplicate == .overwrite) }
    @discardableResult
    func submit(confirmed: Bool = false) -> Bool {
        guard let mutation else { error = L10n.string("mobile.photos.album.stale"); return false }
        guard !needsConfirmation || confirmed else { showsConfirmation = true; return false }
        model.submitMutation(mutation)
        guard model.isManaging else { error = L10n.string("mobile.photos.album.stale"); return false }
        cancel(); return true
    }
    func cancel() {
        task?.cancel(); task = nil; loadID = UUID(); draft = nil; path = []; children = []; coverPhotos = []; coverPhoto = nil
        isLoading = false; isLoadingMore = false; hasMore = false; error = nil; moreError = nil
        showsConfirmation = false; name = ""; duplicate = .skip; sort = .init()
        loadedDuplicateDefaults = false
    }
}
