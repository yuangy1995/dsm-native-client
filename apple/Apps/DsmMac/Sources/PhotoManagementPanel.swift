import AppKit
import DsmCore
import DsmLocalization
import SwiftUI

enum PhotoManagementKind: String, CaseIterable {
    case regeneratePreviews, createFolder, renameFolder, deleteFolders
    case conceptCover, removeConceptItems, conceptVisibility, peopleVisibility, removeFaces, reassignFaces, personCover
    case createRequest, editRequest, deleteRequest
    case rating, description, date, shiftDates, tagsCreate, tagsAdd, tagsRemove, createAlbum, addAlbum, removeAlbum
    case restoreFrozenAlbum, createConditionAlbum, editConditionAlbum, renameAlbum, deleteAlbum, move, copy, upload, sharing, cover, renamePerson, mergePeople
    static let selectionCases: [Self] = [.addAlbum, .createAlbum, .removeAlbum, .cover, .rating, .description, .date, .shiftDates, .tagsCreate, .tagsAdd, .tagsRemove, .move, .copy, .regeneratePreviews]
    static let albumCases: [Self] = [.renameAlbum, .sharing, .deleteAlbum]
    var title: String {
        let key: String
        switch self {
        case .deleteFolders: key = "photos.folder.deleteTitle"
        case .createFolder: key = "photos.folder.create"
        case .renameFolder: key = "photos.folder.rename"
        case .regeneratePreviews: key = "photos.preview.rebuild"
        case .createRequest: key = "photos.request.create"
        case .editRequest: key = "photos.request.edit"
        case .deleteRequest: key = "photos.request.delete"
        case .rating: key = "photos.manage.rating"
        case .description: key = "photos.manage.description"
        case .date: key = "photos.manage.date"
        case .shiftDates: key = "photos.manage.shiftDates"
        case .tagsCreate: key = "photos.manage.tagsCreate"
        case .tagsAdd: key = "photos.manage.tagsAdd"
        case .tagsRemove: key = "photos.manage.tagsRemove"
        case .restoreFrozenAlbum: key = "photos.frozen.restore"
        case .createConditionAlbum: key = "photos.condition.create"
        case .editConditionAlbum: key = "photos.condition.edit"
        case .createAlbum: key = "photos.manage.createAlbum"
        case .addAlbum: key = "photos.manage.addAlbum"
        case .removeAlbum: key = "photos.manage.removeAlbum"
        case .renameAlbum: key = "photos.manage.renameAlbum"
        case .deleteAlbum: key = "photos.manage.deleteAlbum"
        case .move: key = "photos.manage.move"
        case .copy: key = "photos.manage.copy"
        case .upload: key = "photos.manage.upload"
        case .sharing: key = "photos.manage.sharing"
        case .cover: key = "photos.manage.cover"
        case .removeFaces: key = "photos.people.removeFaces"
        case .reassignFaces: key = "photos.people.reassignFaces"
        case .personCover: key = "photos.people.cover"
        case .conceptCover: key = "photos.concepts.cover"
        case .removeConceptItems: key = "photos.concepts.remove"
        case .conceptVisibility: key = "photos.concepts.visibility"
        case .peopleVisibility: key = "photos.people.visibility"
        case .renamePerson: key = "photos.people.rename"
        case .mergePeople: key = "photos.people.merge"
        }
        return L10n.string(key)
    }
    var feature: SynologyPhotosManagementFeature {
        switch self {
        case .deleteFolders: .folderDeletion
        case .createFolder, .renameFolder: .folders
        case .regeneratePreviews: .previewRegeneration
        case .createRequest, .editRequest, .deleteRequest: .photoRequests
        case .rating, .description, .date, .shiftDates: .metadata
        case .tagsCreate: .tagCreation
        case .tagsAdd, .tagsRemove: .tags
        case .createAlbum, .addAlbum, .removeAlbum, .renameAlbum, .deleteAlbum, .cover: .albums
        case .restoreFrozenAlbum: .frozenAlbums
        case .createConditionAlbum, .editConditionAlbum: .conditionAlbums
        case .move, .copy: .fileTransfer
        case .upload: .upload
        case .sharing: .sharing
        case .removeFaces, .reassignFaces: .peopleFaces
        case .personCover: .peopleCover
        case .conceptCover: .conceptCover
        case .removeConceptItems: .conceptItems
        case .conceptVisibility: .conceptVisibility
        case .peopleVisibility: .peopleVisibility
        case .renamePerson: .peopleNames
        case .mergePeople: .peopleMerge
        }
    }
}

struct PhotoManagementSheet: Identifiable {
    let id = UUID()
    let kind: PhotoManagementKind
    let photos: [SynologyPhoto]
    var album: SynologyPhotoCollection? = nil
    var files: [URL] = []
    var folder: SynologyPhotoCollection? = nil
    var folders: [SynologyPhotoCollection] = []
    var concept: SynologyPhotoCollection? = nil
    var person: SynologyPhotoCollection? = nil
    var requestID: String? = nil
    var space: SynologyPhotoSpace = .personal
    var transferPath: [SynologyPhotoCollection] = []

    func initialRequestSettings(defaultSpace: SynologyPhotoSpace? = nil, now: Date = Date()) -> SynologyPhotoRequestSettings {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return .init(subject: L10n.string("photos.request.defaultSubject", formatter.string(from: now)),
                     space: folder == nil ? defaultSpace ?? space : space, folderPath: folder?.path ?? "", folderID: folder?.path == nil ? nil : folder?.id,
                     albumID: album?.acceptsManualMembers == true ? album?.id : nil)
    }
}

/// 创建临时分享后在同一窗口配置；取消由模型继续清理，不遗失已提交操作。
struct PhotoSelectionSharingPanel: View {
    @Bindable var model: SynologyPhotosModel
    let photos: [SynologyPhoto]
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var album: SynologyPhotoCollection?
    @State private var isLoading = true
    @State private var isAllowed = false
    @State private var creationStarted = false
    @State private var error: String?

    var body: some View {
        Group {
            if let album {
                PhotoManagementPanel(model: model, sheet: .init(kind: .sharing, photos: [], album: album), onCancel: {
                    if model.stopTemporarySharing(album, keepCopy: false) { dismiss() }
                })
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text(L10n.string("photos.selectionShare.title")).font(.title2.bold())
                        Spacer()
                        Button { cancel() } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
                    }.padding(20)
                    Divider()
                    VStack(alignment: .leading, spacing: 16) {
                        if isLoading {
                            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if !isAllowed {
                            ContentUnavailableView {
                                Label(L10n.string("photos.selectionShare.title"), systemImage: "link")
                            } description: { Text(L10n.string("photos.selectionShare.unavailable")) } actions: {
                                Button(L10n.string("photos.retry")) { Task { await load() } }
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            Text(L10n.string("photos.selection.count", photos.count)).foregroundStyle(.secondary)
                            TextField(L10n.string("photos.manage.albumName"), text: $name)
                                .textFieldStyle(.roundedBorder).disabled(creationStarted)
                            Text(L10n.string("photos.selectionShare.hint")).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if creationStarted {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.string("photos.selectionShare.preparing"))
                                }
                            } else if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                        }
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    Divider()
                    HStack {
                        Spacer()
                        Button(L10n.string("photos.delete.cancel")) { cancel() }.keyboardShortcut(.cancelAction)
                        Button(L10n.string("photos.selectionShare.configure")) { createAlbum() }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .disabled(isLoading || !isAllowed || creationStarted || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                      model.isManaging || model.hasTemporarySharingCleanup || model.pendingMutationID != nil || model.isDeleting || model.isCheckingDeletion)
                    }.padding(20)
                }.frame(width: 580, height: 330)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .interactiveDismissDisabled()
        .task { await load() }
        .onChange(of: model.isManaging) { _, managing in
            guard !managing, creationStarted, album == nil, model.pendingMutationID == nil else { return }
            creationStarted = false
            error = model.managementMessage ?? L10n.string("photos.manage.failed")
        }
    }

    private func load() async {
        isLoading = true
        let supportsAlbums = await model.supportsManagement(.albums, in: photos.first?.id.space ?? .personal)
        let supportsSharing = await model.supportsManagement(.sharing, in: .personal)
        guard !Task.isCancelled else { return }
        isAllowed = supportsAlbums && supportsSharing && !photos.isEmpty && photos.count <= 100 && model.canAddToAlbum(photos)
        isLoading = false
    }

    private func cancel() {
        if creationStarted { model.cancelTemporaryAlbumCreation() }
        dismiss()
    }

    private func createAlbum() {
        guard isAllowed, !creationStarted, model.canAddToAlbum(photos) else { return }
        error = nil
        model.submitMutation(.createTemporaryAlbum(name: name.trimmingCharacters(in: .whitespacesAndNewlines), photos: photos)) { result in
            guard result.state == .confirmed, let created = result.album else { return }
            album = created
        }
        creationStarted = model.isManaging
        if !creationStarted { error = L10n.string("photos.manage.failed") }
    }
}

/// 表单持有确认目标快照，选择变化不会改变已打开的操作。
struct PhotoManagementPanel: View {
    @Bindable var model: SynologyPhotosModel
    let sheet: PhotoManagementSheet
    var onCancel: (() -> Void)? = nil
    @State private var confirmsTemporaryStop = false
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var people: [SynologyPhotoCollection] = []
    @State private var originalConcept: SynologyPhotoConceptVisibility?
    @State private var conceptVisibility: [SynologyPhotoConceptVisibility] = []
    @State private var peopleVisibility: [SynologyPhotoPersonVisibility] = []
    @State private var visibilitySelection: Set<Int> = []
    @State private var visibilityDesired = true
    @State private var peopleSearch = ""
    @State private var faces: [SynologyPhotoFace] = []
    @State private var selectedFaceIDs: Set<Int> = []
    @State private var targetPersonID = 0
    @State private var mergedPersonIDs: Set<Int> = []
    @State private var rating = 0
    @State private var date = Date()
    @State private var shiftAmount = 1
    @State private var shiftUnit = PhotoTimeShiftUnit.hours
    @State private var shiftForward = true
    @State private var tags: Set<Int> = []
    @State private var albums: [SynologyPhotoCollection] = []
    @State private var albumID: Int?
    @State private var folders: [SynologyPhotoCollection] = []
    @State private var folderPath: [SynologyPhotoCollection] = []
    @State private var transferDuplicate = SynologyPhotoDuplicateSettings.Transfer.skip
    @State private var uploadDuplicate = SynologyPhotoDuplicateSettings.Upload.rename
    @State private var loadedDuplicateDefaults = false
    @State private var confirmedTransfer: SynologyPhotosMutation?
    @State private var showsOverwriteConfirmation = false
    @State private var transferSpace: SynologyPhotoSpace?
    private var isTransferForm: Bool { sheet.kind == .move || sheet.kind == .copy }
    private var transferDestination: SynologyPhotoSpace { transferSpace ?? sheet.transferPath.last?.space ?? sheet.folders.first?.space ?? sheet.photos.first?.id.space ?? sheet.space }
    @State private var linkAccess: SynologyPhotoLinkAccess = .disabled
    @State private var originalSharing: SynologyPhotoSharingState?
    @State private var sharingAllowed = false
    @State private var sharingExpiration = PhotoSharingExpirationDraft()
    @State private var requestSettings = SynologyPhotoRequestSettings()
    @State private var originalRequest: SynologyPhotoRequest?
    @State private var requestAlbums: [SynologyPhotoRequestAlbum] = []
    @State private var requestAlbumError: String?
    @State private var requestDefaultFolder = true
    @State private var showsRequestFolders = false
    @State private var requestSizeEdited = false
    @State private var requestSizeEnabled = false
    @State private var requestSizeMiB = 25
    @State private var requestExpiration = PhotoSharingExpirationDraft(expiration: 0)
    @State private var requestFolderError: String?
    @State private var newRequestAlbumName = ""
    @State private var showsNewRequestAlbum = false
    @State private var requestAlbumCreationStarted = false
    @State private var canCreateRequestAlbum = false
    private var isRequestForm: Bool { [.createRequest, .editRequest, .deleteRequest].contains(sheet.kind) }
    private var usesLargeForm: Bool { isConditionForm || sheet.kind == .sharing || [.conceptVisibility, .peopleVisibility, .mergePeople, .removeFaces, .reassignFaces].contains(sheet.kind) || isRequestForm }
    @State private var sharingPassword = PhotoSharingPasswordDraft()
    @State private var sharingMembers: [SynologyPhotoShareGrant] = []
    @State private var sharingRecipients: [SynologyPhotoShareRecipient] = []
    @State private var recipientID: SynologyPhotoShareRecipient.ID?
    @State private var recipientRole = "view"
    @State private var recipientSearch = ""
    @State private var recipientError: String?
    @State private var loadingRecipients = false
    @State private var isLoading = false
    @State private var error: String?
    @State private var uploadFiles: [PhotoUploadFile] = []
    @State private var skippedUploadCount = 0
    @State private var includesUploadDirectory = false
    @State private var preservesUploadDirectories = true
    @State private var uploadRootFolder: SynologyPhotoCollection?
    @State private var frozenAlbum: SynologyPhotoFrozenAlbum?
    @State private var rebuildFrozen = false
    @State private var canRebuildFrozen = false
    @State private var condition = SynologyPhotoAlbumCondition()
    @State private var originalCondition: SynologyPhotoAlbumCondition?
    @State private var conditionDrafts: [SynologyPhotoSpace: SynologyPhotoAlbumCondition] = [:]
    @State private var suggestions: [String: [SynologyPhotoConditionOption]] = [:]
    @State private var conditionField = SynologyPhotoConditionField.keyword
    @State private var conditionSearch = ""
    @State private var suggestionError: String?
    @State private var isSearchingConditions = false
    @State private var conditionCount: Int?
    @State private var isCounting = false
    @State private var countError: String?
    private var isConditionForm: Bool { [.restoreFrozenAlbum, .createConditionAlbum, .editConditionAlbum].contains(sheet.kind) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheet.kind.title).font(.title2.bold())
                Spacer()
                Button { cancelForm() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                if let album = sheet.album, sheet.kind != .upload { Text(frozenAlbum?.album.name ?? album.name).font(.headline) }
                if let concept = sheet.concept { Text(concept.name).font(.headline) }
                if let person = sheet.person {
                    HStack {
                        PhotoAlbumCover(model: model, album: person, category: .person).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(person.name.isEmpty ? L10n.string("photos.people.unnamed") : person.name).font(.headline)
                    }
                }
                if (!sheet.photos.isEmpty || !sheet.folders.isEmpty) && sheet.kind != .deleteFolders { Text(L10n.string("photos.selection.count", sheet.photos.count + sheet.folders.count)).foregroundStyle(.secondary) }
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sheet.kind == .sharing || isRequestForm {
                    ScrollView { VStack(alignment: .leading, spacing: 16) { form }.frame(maxWidth: .infinity, alignment: .leading) }
                } else { form }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { cancelForm() }.keyboardShortcut(.cancelAction)
                Button(sheet.kind == .restoreFrozenAlbum ? L10n.string(rebuildFrozen ? "photos.frozen.rebuild" : "photos.frozen.saveOrdinary") : [.peopleVisibility, .conceptVisibility].contains(sheet.kind) ? L10n.string("photos.people.applyVisibility") : sheet.kind.title, role: [.deleteAlbum, .deleteRequest, .removeFaces, .deleteFolders, .removeConceptItems].contains(sheet.kind) ? .destructive : nil) {
                    if sheet.kind == .upload {
                        model.enqueueUploads(uploadFiles, album: sheet.album,
                            folder: includesUploadDirectory && preservesUploadDirectories ? sheet.folder ?? uploadRootFolder : sheet.folder,
                            preserveDirectories: includesUploadDirectory && preservesUploadDirectories, space: sheet.space, duplicate: uploadDuplicate)
                    } else if let mutation {
                        if sheet.kind == .sharing, originalSharing?.isTemporary == true, linkAccess == .disabled {
                            confirmsTemporaryStop = true
                            return
                        }
                        if isTransferForm && transferDuplicate == .overwrite {
                            confirmedTransfer = mutation; showsOverwriteConfirmation = true
                            return
                        }
                        model.submitMutation(mutation)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled((sheet.kind == .upload ? (uploadFiles.isEmpty || model.isLoading ||
                    (includesUploadDirectory && preservesUploadDirectories && !model.managementFeatures.contains(.folders))) : mutation == nil) || isLoading || error != nil || model.isManaging || model.pendingMutationID != nil)
            }.padding(20)
        }
        .alert(L10n.string("photos.duplicates.overwriteTitle"), isPresented: $showsOverwriteConfirmation) {
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { confirmedTransfer = nil }
            Button(L10n.string("photos.duplicates.overwriteConfirm"), role: .destructive) {
                if let command = confirmedTransfer { model.submitMutation(command); dismiss() }
                confirmedTransfer = nil
            }
        } message: { Text(L10n.string("photos.duplicates.overwriteWarning")) }
        .alert(L10n.string("photos.temporary.stopTitle"), isPresented: $confirmsTemporaryStop) {
            Button(L10n.string("photos.temporary.stop"), role: .destructive) { stopTemporary(keepCopy: false) }
            Button(L10n.string("photos.temporary.keep")) { stopTemporary(keepCopy: true) }
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { }
        } message: { Text(L10n.string("photos.temporary.stopHint")) }
        .interactiveDismissDisabled(onCancel != nil)
        .frame(width: usesLargeForm ? 680 : 560, height: sheet.kind == .createFolder ? 270 : sheet.kind == .renameFolder ? 220 : (sheet.kind == .deleteFolders ? 360 : (usesLargeForm ? 660 : 470)))
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await load() }
        .onChange(of: rebuildFrozen) { _, value in
            if value { Task { await loadConditionFolders(); await searchConditions() } }
        }
        .onDisappear { sharingPassword.password = "" }
    }

    private func cancelForm() {
        if let onCancel { onCancel() } else { dismiss() }
    }

    private func stopTemporary(keepCopy: Bool) {
        guard let album = sheet.album else { return }
        if model.stopTemporarySharing(album, keepCopy: keepCopy) { dismiss() }
    }

    private var visibilityEntries: [(collection: SynologyPhotoCollection, isVisible: Bool)] {
        if sheet.kind == .conceptVisibility { return conceptVisibility.map { ($0.concept, $0.isVisible) } }
        return peopleVisibility.map { ($0.person, $0.isVisible) }
    }

    private var filteredVisibilityEntries: [(collection: SynologyPhotoCollection, isVisible: Bool)] {
        let query = peopleSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return visibilityEntries.filter { query.isEmpty || $0.collection.name.localizedStandardContains(query) }
    }

    @ViewBuilder private var visibilityForm: some View {
        let isConcept = sheet.kind == .conceptVisibility
        Picker(L10n.string("photos.people.visibilityAction"), selection: $visibilityDesired) {
            Text(L10n.string(isConcept ? "photos.concepts.show" : "photos.people.show")).tag(true)
            Text(L10n.string(isConcept ? "photos.concepts.hide" : "photos.people.hide")).tag(false)
        }.pickerStyle(.segmented)
        TextField(L10n.string(isConcept ? "photos.concepts.search" : "photos.people.search"), text: $peopleSearch).textFieldStyle(.roundedBorder)
        Text(L10n.string(isConcept ? "photos.concepts.visibilityHint" : "photos.people.visibilityHint")).foregroundStyle(.secondary)
        if filteredVisibilityEntries.isEmpty {
            ContentUnavailableView(L10n.string(isConcept ? "photos.concepts.visibilityEmpty" : "photos.people.visibilityEmpty"), systemImage: isConcept ? "square.grid.2x2" : "person.2",
                description: Text(L10n.string(isConcept ? "photos.concepts.visibilityEmptyHint" : (visibilityEntries.isEmpty ? "photos.people.visibilityEmptyHint" : "photos.people.searchEmptyHint"))))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(filteredVisibilityEntries, id: \.collection.id) { entry in
                        Toggle(isOn: Binding(get: { visibilitySelection.contains(entry.collection.id) }, set: { selected in
                            if selected { visibilitySelection.insert(entry.collection.id) } else { visibilitySelection.remove(entry.collection.id) }
                        })) {
                            HStack {
                                PhotoAlbumCover(model: model, album: entry.collection, category: isConcept ? .concept : .person)
                                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                                Text(entry.collection.name.isEmpty ? L10n.string("photos.people.unnamed") : entry.collection.name)
                                Spacer()
                                Text(L10n.string(entry.isVisible ? "photos.people.visible" : "photos.people.hidden")).foregroundStyle(.secondary)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }.padding(4)
            }
        }
        Text(L10n.string(isConcept ? "photos.concepts.visibilityCount" : "photos.people.visibilityCount", visibilitySelection.count)).foregroundStyle(.secondary)
    }

    @ViewBuilder private var faceForm: some View {
        Text(L10n.string("photos.people.facesHint")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if sheet.kind == .reassignFaces {
            Picker(L10n.string("photos.people.destination"), selection: $targetPersonID) {
                Text(L10n.string("photos.people.newPerson")).tag(0)
                ForEach(people) { person in
                    Text(person.name.isEmpty ? L10n.string("photos.people.unnamed") : person.name).tag(person.id)
                }
            }
            if targetPersonID == 0 {
                TextField(L10n.string("photos.people.name"), text: $text).textFieldStyle(.roundedBorder)
            }
        }
        if faces.isEmpty {
            ContentUnavailableView(L10n.string("photos.people.noFaces"), systemImage: "person.crop.rectangle",
                description: Text(L10n.string("photos.people.noFacesHint")))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text(L10n.string("photos.people.faceCount", selectedFaceIDs.count)).foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135))], spacing: 16) {
                    ForEach(faces) { face in
                        Toggle(isOn: Binding(get: { selectedFaceIDs.contains(face.id) }, set: { selected in
                            if selected { selectedFaceIDs.insert(face.id) } else { selectedFaceIDs.remove(face.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 6) {
                                PhotoFaceThumbnail(model: model, face: face).frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(face.photo.filename).lineLimit(2).font(.caption)
                            }
                        }.toggleStyle(.checkbox)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var form: some View {
        switch sheet.kind {
        case .conceptCover:
            Text(L10n.string("photos.concepts.coverHint")).foregroundStyle(.secondary)
            if let photo = sheet.photos.first { Text(photo.filename).lineLimit(2) }
        case .removeConceptItems:
            Text(L10n.string("photos.concepts.removeHint")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let state = originalConcept, let count = state.concept.itemCount, let threshold = state.displayThreshold,
               count - sheet.photos.count < threshold {
                Text(L10n.string("photos.concepts.belowThreshold")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) { ForEach(sheet.photos) { photo in Text(photo.filename).lineLimit(2) } }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .conceptVisibility, .peopleVisibility: visibilityForm
        case .removeFaces, .reassignFaces: faceForm
        case .personCover:
            Text(L10n.string("photos.people.coverHint")).foregroundStyle(.secondary)
            if let photo = sheet.photos.first { Text(photo.filename).lineLimit(2) }
        case .createRequest, .editRequest, .deleteRequest: requestForm
        case .renamePerson:
            TextField(L10n.string("photos.people.name"), text: $text).textFieldStyle(.roundedBorder)
            Text(L10n.string("photos.people.clearNameHint")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .mergePeople:
            TextField(L10n.string("photos.people.name"), text: $text).textFieldStyle(.roundedBorder)
            Text(L10n.string("photos.people.mergeHint")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if people.isEmpty {
                ContentUnavailableView(L10n.string("photos.people.noOthers"), systemImage: "person.2", description: Text(L10n.string("photos.people.noOthersHint")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(people) { person in
                            Toggle(isOn: Binding(get: { mergedPersonIDs.contains(person.id) }, set: { selected in
                                if selected { mergedPersonIDs.insert(person.id) } else { mergedPersonIDs.remove(person.id) }
                            })) {
                                HStack {
                                    PhotoAlbumCover(model: model, album: person, category: .person).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading) {
                                        Text(person.name.isEmpty ? L10n.string("photos.people.unnamed") : person.name)
                                        if let count = person.itemCount { Text(L10n.string("photos.people.photoCount", Int64(count))).foregroundStyle(.secondary) }
                                    }
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .restoreFrozenAlbum:
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("photos.frozen.hint")).foregroundStyle(.secondary)
                if let frozenAlbum, !frozenAlbum.unsupportedConditions.isEmpty {
                    Text(L10n.string("photos.frozen.unsupported")).font(.headline)
                    Text(frozenAlbum.unsupportedConditions.keys.sorted().map(frozenConditionTitle).joined(separator: L10n.string("photos.frozen.separator")))
                        .foregroundStyle(.secondary)
                }
                if canRebuildFrozen {
                    Picker(L10n.string("photos.frozen.action"), selection: $rebuildFrozen) {
                        Text(L10n.string("photos.frozen.saveOrdinary")).tag(false)
                        Text(L10n.string("photos.frozen.rebuild")).tag(true)
                    }.pickerStyle(.radioGroup)
                } else { Text(L10n.string("photos.frozen.saveOrdinary")).font(.headline) }
                Text(L10n.string(rebuildFrozen ? "photos.frozen.rebuildHint" : "photos.frozen.ordinaryHint")).foregroundStyle(.secondary)
                if rebuildFrozen { conditionForm }
                else { Spacer(minLength: 0) }
            }
        case .createConditionAlbum, .editConditionAlbum:
            conditionForm
        case .rating:
            Picker(L10n.string("photos.manage.rating"), selection: $rating) {
                Text(L10n.string("photos.manage.unrated")).tag(0)
                ForEach(1...5, id: \.self) { value in Text(String(repeating: "★", count: value)).tag(value) }
            }.pickerStyle(.radioGroup)
        case .description:
            TextEditor(text: $text).frame(minHeight: 140).accessibilityLabel(sheet.kind.title)
        case .date:
            DatePicker(L10n.string("photos.manage.date"), selection: $date).environment(\.locale, L10n.locale)
            Text(L10n.string("photos.manage.dateHint")).foregroundStyle(.secondary)
        case .shiftDates:
            Picker(L10n.string("photos.manage.shiftDirection"), selection: $shiftForward) {
                Text(L10n.string("photos.manage.shiftLater")).tag(true)
                Text(L10n.string("photos.manage.shiftEarlier")).tag(false)
            }.pickerStyle(.segmented)
            HStack {
                TextField(L10n.string("photos.manage.shiftAmount"), value: $shiftAmount, format: .number.locale(L10n.locale)).textFieldStyle(.roundedBorder)
                Picker(L10n.string("photos.manage.shiftUnit"), selection: $shiftUnit) {
                    ForEach(PhotoTimeShiftUnit.allCases, id: \.self) { unit in Text(unit.title).tag(unit) }
                }.labelsHidden()
            }
            Text(L10n.string("photos.manage.shiftHint")).foregroundStyle(.secondary)
            if let photo = sheet.photos.first, let seconds = shiftSeconds {
                let style = Date.FormatStyle(date: .numeric, time: .standard).locale(L10n.locale)
                Text(L10n.string("photos.manage.shiftPreview", photo.takenAt.formatted(style),
                    photo.takenAt.addingTimeInterval(Double(seconds)).formatted(style)))
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .tagsCreate:
            TextField(L10n.string("photos.manage.tagName"), text: $text).textFieldStyle(.roundedBorder)
            if !sheet.photos.isEmpty { Text(L10n.string("photos.manage.createTagHint")).foregroundStyle(.secondary) }
        case .deleteFolders:
            Text(L10n.string("photos.folder.deleteConfirm", sheet.folders.count, sheet.photos.count))
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(sheet.folders) { folder in Label(folder.name, systemImage: "folder") }
                    ForEach(sheet.photos) { photo in Label(photo.filename, systemImage: "photo") }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        case .createFolder, .renameFolder:
            if sheet.kind == .createFolder, let folder = sheet.folder {
                Label(folder.name, systemImage: "folder").font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            TextField(L10n.string("photos.folder.name"), text: $text).textFieldStyle(.roundedBorder)
            if !text.isEmpty && !SynologyPhotosMutation.isValidFolderName(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                Text(L10n.string("photos.folder.invalidName")).font(.callout).foregroundStyle(.secondary)
            }
        case .createAlbum, .renameAlbum:
            TextField(L10n.string("photos.manage.albumName"), text: $text).textFieldStyle(.roundedBorder)
        case .addAlbum:
            if albums.isEmpty { Text(L10n.string("photos.manage.noAlbums")).foregroundStyle(.secondary) }
            else {
                List(albums, selection: $albumID) { album in Text(album.name).tag(album.id) }
            }
        case .removeAlbum:
            Text(L10n.string("photos.manage.removeHint"))
        case .deleteAlbum:
            Text(L10n.string("photos.manage.deleteAlbumHint"))
        case .cover:
            Text(sheet.photos.first?.filename ?? "").lineLimit(2)
            Text(L10n.string("photos.manage.coverHint")).foregroundStyle(.secondary)
        case .tagsAdd, .tagsRemove:
            if model.options.tags.isEmpty { Text(L10n.string("photos.manage.noTags")).foregroundStyle(.secondary) }
            else {
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(model.options.tags) { tag in
                            Toggle(tag.name, isOn: Binding(get: { tags.contains(tag.id) }, set: { if $0 { tags.insert(tag.id) } else { tags.remove(tag.id) } }))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .regeneratePreviews:
            Text(L10n.string("photos.preview.rebuildHint"))
        case .move, .copy:
            if model.transferDestinationSpaces(for: sheet.photos, copying: sheet.kind == .copy, folders: sheet.folders).count > 1 {
                Picker(L10n.string("photos.transfer.destination"), selection: Binding(get: { transferDestination }, set: { space in
                    transferSpace = space; folderPath = []; folders = []
                    Task { await load() }
                })) {
                    ForEach(model.transferDestinationSpaces(for: sheet.photos, copying: sheet.kind == .copy, folders: sheet.folders), id: \.self) { space in
                        Text(L10n.string(space == .personal ? "shared.51fcaa8035fc61e2" : "shared.17d2e16862f16829")).tag(space)
                    }
                }.pickerStyle(.segmented)
            }
            folderPicker
            PhotoTransferDuplicatePicker(selection: $transferDuplicate)
            if transferDuplicate == .overwrite { Text(L10n.string("photos.duplicates.overwriteWarning")).font(.callout).foregroundStyle(.secondary) }
        case .upload:
            Text(L10n.string("photos.upload.fileCount", uploadFiles.count)).font(.headline)
            if !directAlbumUpload, sheet.space == .shared {
                Text(L10n.string("shared.17d2e16862f16829"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(L10n.string("photos.upload.destination", sheet.album?.name ?? sheet.folder?.name ??
                (includesUploadDirectory && preservesUploadDirectories ? L10n.string(sheet.space == .personal ? "shared.51fcaa8035fc61e2" : "shared.17d2e16862f16829") : L10n.string("photos.library.timeline"))))
                .foregroundStyle(.secondary)
            if includesUploadDirectory && !directAlbumUpload {
                Toggle(L10n.string("photos.upload.preserveDirectories"), isOn: $preservesUploadDirectories)
                Text(L10n.string(preservesUploadDirectories ? "photos.upload.preserveHint" : "photos.upload.directoryHint"))
                    .font(.callout).foregroundStyle(.secondary)
                if preservesUploadDirectories && !model.managementFeatures.contains(.folders) {
                    Text(L10n.string("photos.manage.unavailable")).foregroundStyle(.secondary)
                }
            }
            if skippedUploadCount > 0 { Text(L10n.string("photos.upload.skippedCount", skippedUploadCount)).font(.callout).foregroundStyle(.secondary) }
            if uploadFiles.isEmpty { Text(L10n.string("photos.upload.noMedia")).foregroundStyle(.secondary) }
            List(uploadFiles) { file in
                HStack {
                    Text((preservesUploadDirectories ? file.directoryComponents + [file.url.lastPathComponent] : [file.url.lastPathComponent]).joined(separator: "/"))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(file.size.formatted(.byteCount(style: .file).locale(L10n.locale))).foregroundStyle(.secondary)
                }
            }
            PhotoUploadDuplicatePicker(selection: $uploadDuplicate)
        case .sharing:
            Picker(L10n.string("photos.manage.linkAccess"), selection: $linkAccess) {
                ForEach(SynologyPhotoLinkAccess.allCases, id: \.self) { access in
                    Text(linkTitle(access)).tag(access)
                }
            }.pickerStyle(.radioGroup)
            if linkAccess == .invited { Text(L10n.string("photos.sharing.invitedHint")).foregroundStyle(.secondary) }
            else if linkAccess != .disabled { Text(L10n.string("photos.manage.shareHint")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if originalSharing?.hasPassword == true {
                Label(L10n.string("photos.sharing.passwordProtected"), systemImage: "lock.fill").foregroundStyle(.secondary)
            }
            Picker(L10n.string("photos.sharing.password"), selection: $sharingPassword.choice) {
                Text(L10n.string("photos.sharing.passwordKeep")).tag(PhotoSharingPasswordDraft.Choice.unchanged)
                Text(L10n.string("photos.sharing.passwordSet")).tag(PhotoSharingPasswordDraft.Choice.newPassword)
                Text(L10n.string("photos.sharing.passwordRemove")).tag(PhotoSharingPasswordDraft.Choice.remove)
            }
            if sharingPassword.choice == .newPassword {
                SecureField(L10n.string("photos.sharing.passwordPlaceholder"), text: $sharingPassword.password)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("photos.sharing.password.input")
            }
            Picker(L10n.string("photos.sharing.expiration"), selection: Binding(get: { sharingExpiration.choice }, set: {
                sharingExpiration.choice = $0; sharingExpiration.edited = true
            })) {
                if originalSharing?.expiration == nil {
                    Text(L10n.string("photos.sharing.expirationKeep")).tag(PhotoSharingExpirationDraft.Choice.unchanged)
                }
                Text(L10n.string("photos.sharing.expirationUnlimited")).tag(PhotoSharingExpirationDraft.Choice.unlimited)
                Text(L10n.string("photos.sharing.expirationDate")).tag(PhotoSharingExpirationDraft.Choice.date)
            }
            if sharingExpiration.choice == .date {
                DatePicker(L10n.string("photos.sharing.expirationDate"), selection: Binding(get: { sharingExpiration.date }, set: {
                    sharingExpiration.date = $0; sharingExpiration.edited = true
                }), displayedComponents: .date)
                if !sharingExpiration.isValid {
                    Text(L10n.string("photos.sharing.expirationPast")).foregroundStyle(.red)
                }
            }
            if let url = originalSharing?.url {
                HStack {
                    Text(url.absoluteString).lineLimit(2).textSelection(.enabled)
                    Button(L10n.string("photos.sharing.copyLink")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                }
            }
            Divider()
            sharingMemberEditor

        }
    }

    private var directAlbumUpload: Bool { model.uploadsDirectlyToAlbum(sheet.album, space: sheet.space) }

    private var sharingRoles: [String] { sheet.album?.isConditional == true ? ["view", "download"] : ["view", "download", "upload"] }
    private var availableRecipients: [SynologyPhotoShareRecipient] {
        sharingRecipients.filter { recipient in
            !sharingMembers.contains { $0.id == recipient.id } &&
                (recipientSearch.isEmpty || recipient.name.localizedCaseInsensitiveContains(recipientSearch))
        }
    }

    @ViewBuilder private var sharingMemberEditor: some View {
        Text(L10n.string("photos.sharing.members")).font(.headline)
        if originalSharing?.members == nil {
            Text(L10n.string("photos.sharing.membersUnreadable")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            if sharingMembers.isEmpty {
                Text(L10n.string("photos.sharing.noMembers")).foregroundStyle(.secondary)
            }
            ForEach($sharingMembers) { $member in
                HStack {
                    Label(member.recipient.name, systemImage: member.id.type == "group" ? "person.2" : "person")
                        .lineLimit(1).help(member.recipient.name)
                    Spacer()
                    Picker(L10n.string("photos.sharing.role"), selection: $member.role) {
                        if !sharingRoles.contains(member.role) { Text(member.role).tag(member.role) }
                        ForEach(sharingRoles, id: \.self) { role in Text(sharingRoleTitle(role)).tag(role) }
                    }.labelsHidden().frame(width: 230)
                    Button { sharingMembers.removeAll { $0.id == member.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.sharing.removeMember", member.recipient.name))
                }
            }
            if loadingRecipients { ProgressView().controlSize(.small) }
            else if let recipientError {
                Text(recipientError).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.string("photos.retry")) { Task { await loadSharingRecipients() } }
            } else {
                TextField(L10n.string("photos.sharing.searchMembers"), text: $recipientSearch).textFieldStyle(.roundedBorder)
                if availableRecipients.isEmpty {
                    Text(L10n.string("photos.sharing.noAvailableMembers")).foregroundStyle(.secondary)
                }
                HStack {
                    Picker(L10n.string("photos.sharing.member"), selection: $recipientID) {
                        Text(L10n.string("photos.sharing.chooseMember")).tag(Optional<SynologyPhotoShareRecipient.ID>.none)
                        ForEach(availableRecipients) { recipient in
                            Label(recipient.name, systemImage: recipient.id.type == "group" ? "person.2" : "person").tag(Optional(recipient.id))
                        }
                    }.labelsHidden()
                    Picker(L10n.string("photos.sharing.role"), selection: $recipientRole) {
                        ForEach(sharingRoles, id: \.self) { role in Text(sharingRoleTitle(role)).tag(role) }
                    }.labelsHidden().frame(width: 230)
                    Button(L10n.string("photos.sharing.addMember")) {
                        if let recipient = availableRecipients.first(where: { $0.id == recipientID }) {
                            sharingMembers.append(.init(recipient: recipient, role: recipientRole)); recipientID = nil
                        }
                    }.disabled(!availableRecipients.contains { $0.id == recipientID })
                }
                .onChange(of: recipientSearch) { _, _ in
                    if !availableRecipients.contains(where: { $0.id == recipientID }) { recipientID = nil }
                }
            }
        }
    }

    private func sharingRoleTitle(_ role: String) -> String {
        switch role {
        case "view": L10n.string("photos.sharing.role.view")
        case "download": L10n.string("photos.sharing.role.download")
        case "upload": L10n.string("photos.sharing.role.upload")
        default: role
        }
    }

    private func loadSharingRecipients() async {
        loadingRecipients = true; recipientError = nil
        defer { loadingRecipients = false }
        do { sharingRecipients = try await model.sharingRecipients() }
        catch { recipientError = L10n.string("photos.sharing.membersLoadFailed") }
    }

    private func linkTitle(_ access: SynologyPhotoLinkAccess) -> String {
        switch access {
        case .disabled: L10n.string("photos.manage.link.disabled")
        case .invited: L10n.string("photos.sharing.invited")
        case .view: L10n.string("photos.manage.link.view")
        case .download: L10n.string("photos.manage.link.download")
        }
    }

    private var preparedRequestSettings: SynologyPhotoRequestSettings? {
        var value = requestSettings
        value.subject = value.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.subject.isEmpty, value.subject.utf16.count <= 50, value.description.utf16.count <= 100,
              requestExpiration.isValid, !requestSizeEnabled || (1...3000).contains(requestSizeMiB) else { return nil }
        if requestDefaultFolder {
            guard model.canUseDefaultRequestFolder(in: value.space) else { return nil }
            value.folderID = nil; value.folderPath = SynologyPhotoRequestSettings.defaultFolderPath(subject: value.subject)
        }
        guard !value.folderPath.isEmpty else { return nil }
        value.expiration = requestExpiration.change(from: value.expiration) ?? value.expiration
        if requestSizeEdited || originalRequest == nil { value.sizeLimit = requestSizeEnabled ? Int64(requestSizeMiB) * 1_048_576 : 0 }
        return value
    }

    @ViewBuilder private var requestForm: some View {
        if sheet.kind == .deleteRequest {
            Text(originalRequest?.settings.subject ?? "").font(.headline)
            Text(L10n.string("photos.request.deleteConfirm")).fixedSize(horizontal: false, vertical: true)
        } else {
            TextField(L10n.string("photos.request.subject"), text: $requestSettings.subject)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("photos.request.subject")
            TextField(L10n.string("photos.request.description"), text: $requestSettings.description, axis: .vertical)
                .lineLimit(2...3).textFieldStyle(.roundedBorder)
            if requestSettings.subject.utf16.count > 50 || requestSettings.description.utf16.count > 100 {
                Text(L10n.string("photos.request.lengthLimit")).foregroundStyle(.red)
            }
            if let url = originalRequest?.url {
                Text(url.absoluteString).lineLimit(2).textSelection(.enabled)
            }
            Divider()
            if model.spaces.count > 1 {
                Picker(L10n.string("photos.library.space"), selection: Binding(get: { requestSettings.space }, set: { space in
                    guard space != requestSettings.space else { return }
                    requestSettings.space = space
                    requestSettings.folderID = nil; requestSettings.folderPath = ""
                    requestDefaultFolder = model.canUseDefaultRequestFolder(in: space)
                    showsRequestFolders = !requestDefaultFolder
                    Task { await loadRequestFolders() }
                })) {
                    ForEach(model.spaces, id: \.self) { space in
                        Text(L10n.string(space == .personal ? "shared.51fcaa8035fc61e2" : "shared.17d2e16862f16829")).tag(space)
                    }
                }
            }
            if model.canUseDefaultRequestFolder(in: requestSettings.space) {
                Toggle(L10n.string("photos.request.defaultFolder"), isOn: $requestDefaultFolder)
                    .onChange(of: requestDefaultFolder) { _, usesDefault in if !usesDefault { showsRequestFolders = true } }
            }
            if requestDefaultFolder || !requestSettings.folderPath.isEmpty {
                Text(requestDefaultFolder ? SynologyPhotoRequestSettings.defaultFolderPath(subject: requestSettings.subject) : requestSettings.folderPath)
                    .font(.callout).textSelection(.enabled).lineLimit(3)
            } else {
                Text(L10n.string("photos.request.selectFolderHint")).font(.callout).foregroundStyle(.secondary)
            }
            if originalRequest?.isFolderValid == false, !requestDefaultFolder,
               requestSettings.folderID == originalRequest?.settings.folderID {
                Text(L10n.string("photos.request.invalidFolder")).foregroundStyle(.red)
            }
            DisclosureGroup(L10n.string("photos.request.chooseFolder"), isExpanded: $showsRequestFolders) {
                if let requestFolderError {
                    Text(requestFolderError).foregroundStyle(.secondary)
                    Button(L10n.string("photos.retry")) { Task { await loadRequestFolders() } }
                } else {
                    folderPicker.frame(height: 140)
                    if let folder = folderPath.last, let path = folder.path {
                        Button(L10n.string("photos.request.useFolder")) {
                            requestSettings.folderPath = path; requestSettings.folderID = folder.id; requestDefaultFolder = false
                        }
                    }
                }
            }
            Divider()
            Picker(L10n.string("photos.request.album"), selection: Binding(get: {
                requestSettings.albumPassphrase.map { "shared:" + $0 } ?? requestSettings.albumID.map { "owned:\($0)" } ?? ""
            }, set: { id in
                if let choice = requestAlbums.first(where: { $0.id == id }) {
                    requestSettings.albumID = choice.albumID; requestSettings.albumPassphrase = choice.passphrase
                } else if id.isEmpty { requestSettings.albumID = nil; requestSettings.albumPassphrase = nil }
            })) {
                Text(L10n.string("photos.request.noAlbum")).tag("")
                ForEach(requestAlbums) { album in Text(album.name).tag(album.id) }
                if let originalRequest, let name = originalRequest.albumName, !name.isEmpty {
                    let id = originalRequest.settings.albumPassphrase.map { "shared:" + $0 } ?? originalRequest.settings.albumID.map { "owned:\($0)" } ?? ""
                    if !id.isEmpty, !requestAlbums.contains(where: { $0.id == id }) { Text(name).tag(id) }
                } else if let album = sheet.album, !requestAlbums.contains(where: { $0.albumID == album.id }) {
                    Text(album.name).tag("owned:\(album.id)")
                }
            }
            if let requestAlbumError {
                Text(requestAlbumError).foregroundStyle(.secondary)
                Button(L10n.string("photos.retry")) { Task { await loadRequestAlbums() } }
            }
            DisclosureGroup(L10n.string("photos.manage.createAlbum"), isExpanded: $showsNewRequestAlbum) {
                HStack {
                    TextField(L10n.string("photos.manage.albumName"), text: $newRequestAlbumName)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("photos.request.newAlbumName")
                        .onSubmit { createRequestAlbum() }
                    Button(L10n.string("photos.manage.createAlbum")) { createRequestAlbum() }
                        .disabled(!canCreateRequestAlbum || newRequestAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isManaging || model.pendingMutationID != nil)
                }
                if requestAlbumCreationStarted, let message = model.managementMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                    if model.isManaging { ProgressView().controlSize(.small) }
                    else if model.pendingMutationID != nil {
                        Button(L10n.string("photos.selection.retryReview")) { model.reviewPendingMutation() }
                    }
                }
            }
            if requestAlbums.contains(where: { $0.albumID == requestSettings.albumID && $0.passphrase == requestSettings.albumPassphrase && !$0.shared }) {
                Text(L10n.string("photos.request.privateAlbumHint")).font(.callout).foregroundStyle(.secondary)
            }
            Toggle(L10n.string("photos.request.limitSize"), isOn: Binding(get: { requestSizeEnabled }, set: { requestSizeEnabled = $0; requestSizeEdited = true }))
            if requestSizeEnabled {
                HStack {
                    TextField(L10n.string("photos.request.sizeMiB"), value: Binding(get: { requestSizeMiB }, set: { requestSizeMiB = $0; requestSizeEdited = true }), format: .number.locale(L10n.locale))
                        .textFieldStyle(.roundedBorder).frame(width: 100)
                    Text(L10n.string("photos.request.sizeRange"))
                }
            }
            Picker(L10n.string("photos.sharing.expiration"), selection: Binding(get: { requestExpiration.choice }, set: {
                requestExpiration.choice = $0; requestExpiration.edited = true
            })) {
                Text(L10n.string("photos.sharing.expirationUnlimited")).tag(PhotoSharingExpirationDraft.Choice.unlimited)
                Text(L10n.string("photos.sharing.expirationDate")).tag(PhotoSharingExpirationDraft.Choice.date)
            }
            if requestExpiration.choice == .date {
                DatePicker(L10n.string("photos.sharing.expirationDate"), selection: Binding(get: { requestExpiration.date }, set: {
                    requestExpiration.date = $0; requestExpiration.edited = true
                }), displayedComponents: .date)
            }
            Text(L10n.string("photos.request.createHint")).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func loadRequestFolders() async {
        let space = requestSettings.space
        folderPath = []; folders = []
        requestFolderError = nil
        do {
            let (root, children) = try await model.managementFolders(parentID: nil, in: space)
            guard space == requestSettings.space else { return }
            folderPath = [root]; folders = children
        } catch { if space == requestSettings.space { requestFolderError = L10n.string("photos.request.folderReadFailed") } }
    }

    private func createRequestAlbum() {
        let name = newRequestAlbumName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canCreateRequestAlbum, !name.isEmpty, !model.isManaging, model.pendingMutationID == nil else { return }
        requestAlbumCreationStarted = true
        model.submitMutation(.createAlbum(name: name, photos: [])) { result in
            guard result.state == .confirmed, let album = result.album else { return }
            requestAlbums.removeAll { $0.albumID == album.id }
            requestAlbums.append(.init(albumID: album.id, name: album.name, shared: false))
            requestSettings.albumID = album.id; requestSettings.albumPassphrase = nil
            newRequestAlbumName = ""; showsNewRequestAlbum = false
        }
    }

    private func loadRequestAlbums() async {
        requestAlbumError = nil
        canCreateRequestAlbum = await model.supportsManagement(.albums, in: .personal)
        do { requestAlbums = try await model.photoRequestAlbums() }
        catch { requestAlbumError = L10n.string("photos.request.albumReadFailed") }
    }

    private var folderPicker: some View {
        VStack(alignment: .leading) {
            HStack {
                Button { Task { await openFolder(nil, goBack: true) } } label: { Image(systemName: "chevron.left") }
                    .disabled(folderPath.count <= 1).accessibilityLabel(L10n.string("photos.library.back"))
                Text(folderPath.last?.name ?? "").lineLimit(1)
            }
            List(folders) { folder in
                Button { Task { await openFolder(folder) } } label: { Label(folder.name, systemImage: "folder") }.buttonStyle(.plain)
            }
        }
    }

    private var shiftSeconds: Int? {
        guard shiftAmount > 0 else { return nil }
        let (seconds, overflow) = shiftAmount.multipliedReportingOverflow(by: shiftUnit.seconds)
        guard !overflow else { return nil }
        let value = shiftForward ? seconds : -seconds
        guard sheet.photos.allSatisfy({
            let original = $0.takenAt.timeIntervalSince1970
            guard original.isFinite, original >= 0, original <= Double(Int.max / 2) else { return false }
            let (target, overflow) = Int(original).addingReportingOverflow(value)
            return !overflow && target >= 0 && target <= Int.max / 2
        }) else { return nil }
        return value
    }

    private var mutation: SynologyPhotosMutation? {
        guard sheet.kind == .sharing ? sharingAllowed : model.managementFeatures.contains(sheet.kind.feature) else { return nil }
        let photos = sheet.photos
        switch sheet.kind {
        case .createRequest, .editRequest:
            guard let settings = preparedRequestSettings else { return nil }
            if sheet.kind == .createRequest { return .createPhotoRequest(settings) }
            guard let originalRequest, settings != originalRequest.settings else { return nil }
            return .updatePhotoRequest(original: originalRequest, settings: settings)
        case .deleteRequest: return originalRequest.map { .deletePhotoRequest($0) }
        case .conceptCover:
            guard let originalConcept, photos.count == 1, let photo = photos.first else { return nil }
            return .setConceptCover(concept: originalConcept, photo: photo)
        case .removeConceptItems:
            guard let originalConcept, !photos.isEmpty else { return nil }
            return .removeConceptItems(concept: originalConcept, photos: photos)
        case .conceptVisibility:
            let selected = conceptVisibility.filter { visibilitySelection.contains($0.id) && $0.isVisible != visibilityDesired }
            guard !selected.isEmpty else { return nil }
            return .setConceptVisibility(selected, visible: visibilityDesired)
        case .peopleVisibility:
            let selected = peopleVisibility.filter { visibilitySelection.contains($0.id) && $0.isVisible != visibilityDesired }
            guard !selected.isEmpty, selected.count <= 100 else { return nil }
            return .setPeopleVisibility(selected, visible: visibilityDesired)
        case .removeFaces, .reassignFaces:
            guard let person = sheet.person, !selectedFaceIDs.isEmpty else { return nil }
            let selected = faces.filter { selectedFaceIDs.contains($0.id) }
            guard !selected.isEmpty else { return nil }
            if sheet.kind == .removeFaces { return .removePersonFaces(person: person, faces: selected) }
            let target = people.first { $0.id == targetPersonID }
            guard targetPersonID == 0 || target != nil else { return nil }
            return .reassignPersonFaces(person: person, faces: selected, target: target, name: target?.name ?? text.trimmingCharacters(in: .whitespacesAndNewlines))
        case .personCover:
            guard let person = sheet.person, photos.count == 1, let photo = photos.first else { return nil }
            return .setPersonCover(person: person, photo: photo)
        case .renamePerson:
            guard let person = sheet.person, text != person.name else { return nil }
            return .renamePerson(person, name: text)
        case .mergePeople:
            guard let target = sheet.person, !mergedPersonIDs.isEmpty else { return nil }
            return .mergePeople(target: target, sources: people.filter { mergedPersonIDs.contains($0.id) }, name: text)
        case .restoreFrozenAlbum:
            guard let frozenAlbum else { return nil }
            if rebuildFrozen {
                let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard canRebuildFrozen, !name.isEmpty, conditionDatesValid else { return nil }
                return .rebuildFrozenAlbum(frozenAlbum, name: name, condition: condition)
            }
            return .unfreezeAlbum(frozenAlbum)
        case .createConditionAlbum:
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !conditionDatesValid ? nil : .createConditionAlbum(name: text, condition: condition)
        case .editConditionAlbum:
            guard let album = sheet.album, let originalCondition, conditionDatesValid else { return nil }
            return .setAlbumCondition(id: album.id, original: originalCondition, condition: condition)
        case .rating: return .edit(photos, .rating(rating))
        case .description: return .edit(photos, .description(text))
        case .date: return .edit(photos, .takenAt(date))
        case .shiftDates: return shiftSeconds.flatMap { photos.isEmpty ? nil : .shiftDates(photos, seconds: $0) }
        case .tagsCreate:
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : .createTag(name: name, photos: photos, space: sheet.space)
        case .tagsAdd: return tags.isEmpty ? nil : .addTags(photos, ids: tags.sorted())
        case .tagsRemove: return tags.isEmpty ? nil : .removeTags(photos, ids: tags.sorted())
        case .createAlbum: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .createAlbum(name: text, photos: photos)
        case .deleteFolders:
            return sheet.folders.isEmpty ? nil : .deleteFolderItems(photos: sheet.photos, folders: sheet.folders)
        case .createFolder:
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return sheet.folder.flatMap { SynologyPhotosMutation.isValidFolderName(name) ? .createFolder(parentID: $0.id, name: name, space: $0.space) : nil }
        case .renameFolder:
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return sheet.folder.flatMap { name == $0.name || !SynologyPhotosMutation.isValidFolderName(name) ? nil : .renameFolder(folder: $0, name: name) }
        case .renameAlbum: return sheet.album.flatMap { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .renameAlbum(id: $0.id, name: text) }
        case .deleteAlbum: return sheet.album.map { .deleteAlbum(id: $0.id) }
        case .addAlbum: return albumID.map { .addToAlbum(id: $0, photos: photos) }
        case .removeAlbum: return sheet.album.map { .removeFromAlbum(id: $0.id, photos: photos) }
        case .regeneratePreviews: return photos.isEmpty ? nil : .regeneratePreviews(photos)
        case .move, .copy:
            guard let folder = folderPath.last, !photos.isEmpty || !sheet.folders.isEmpty else { return nil }
            let command: SynologyPhotosMutation = sheet.kind == .move
                ? .move(photos, folderID: folder.id, destinationSpace: transferDestination, folders: sheet.folders, duplicate: transferDuplicate)
                : .copy(photos, folderID: folder.id, destinationSpace: transferDestination, folders: sheet.folders, duplicate: transferDuplicate)
            return command.acceptsTransferDestination(folder) ? command : nil
        case .upload: return nil
        case .cover:
            guard photos.count == 1, let photo = photos.first, let album = sheet.album else { return nil }
            return .setAlbumCover(id: album.id, photo: photo)
        case .sharing:
            guard let originalSharing, sharingExpiration.isValid, sharingPassword.isValid else { return nil }
            let changedMembers = originalSharing.members.map { $0 != sharingMembers } ?? false
            let expiration = sharingExpiration.change(from: originalSharing.expiration)
            let password = sharingPassword.change(hasPassword: originalSharing.hasPassword)
            guard originalSharing.isTemporary == true || originalSharing.access != linkAccess || changedMembers || expiration != nil || password != nil else { return nil }
            return sheet.album.map { .shareAlbum(id: $0.id, access: linkAccess, original: originalSharing, members: changedMembers ? sharingMembers : nil, expiration: expiration, password: password) }
        }
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            if !loadedDuplicateDefaults && (isTransferForm || sheet.kind == .upload) && model.managementFeatures.contains(.duplicateSettings) {
                let defaults = try await model.duplicateSettings()
                transferDuplicate = defaults.transfer; uploadDuplicate = defaults.upload
                loadedDuplicateDefaults = true
            }
            switch sheet.kind {
            case .createRequest, .editRequest, .deleteRequest:
                if let id = sheet.requestID {
                    let request = try await model.photoRequest(id: id)
                    originalRequest = request; requestSettings = request.settings; requestDefaultFolder = false
                    requestExpiration = PhotoSharingExpirationDraft(expiration: request.settings.expiration)
                    requestSizeEnabled = request.settings.sizeLimit > 0
                    requestSizeMiB = requestSizeEnabled ? Int(request.settings.sizeLimit / 1_048_576) : 25
                } else {
                    requestSettings = sheet.initialRequestSettings(defaultSpace: model.defaultPhotoRequestSpace)
                    requestDefaultFolder = requestSettings.folderID == nil && model.canUseDefaultRequestFolder(in: requestSettings.space)
                }
                showsRequestFolders = !requestDefaultFolder && requestSettings.folderID == nil
                if sheet.kind != .deleteRequest { await loadRequestFolders(); await loadRequestAlbums() }
            case .removeFaces, .reassignFaces:
                guard let person = sheet.person else { return }
                faces = try await model.personFaces(personID: person.id, photos: sheet.photos)
                selectedFaceIDs = Set(faces.map(\.id))
                if sheet.kind == .reassignFaces { people = try await model.managementPeople(in: person.space).filter { $0.id != person.id } }
            case .conceptCover, .removeConceptItems:
                guard let concept = sheet.concept else { throw CocoaError(.fileReadCorruptFile) }
                let state = try await model.conceptState(concept)
                guard state.concept.name == concept.name else { throw CocoaError(.fileReadCorruptFile) }
                if sheet.kind == .removeConceptItems {
                    guard let count = state.concept.itemCount, let threshold = state.displayThreshold,
                          count >= sheet.photos.count, threshold >= 0 else { throw CocoaError(.fileReadCorruptFile) }
                }
                originalConcept = state
            case .conceptVisibility:
                conceptVisibility = try await model.conceptVisibility(in: sheet.concept?.space ?? sheet.space)
                if let concept = sheet.concept, let entry = conceptVisibility.first(where: { $0.id == concept.id }) {
                    visibilitySelection = [concept.id]
                    visibilityDesired = !entry.isVisible
                }
            case .peopleVisibility:
                peopleVisibility = try await model.peopleVisibility(in: sheet.person?.space ?? sheet.space)
                if let person = sheet.person {
                    visibilitySelection = [person.id]
                    visibilityDesired = false
                }
            case .personCover: break
            case .renamePerson: text = sheet.person?.name ?? ""
            case .mergePeople:
                text = sheet.person?.name ?? ""
                people = try await model.managementPeople(in: sheet.person?.space ?? sheet.space).filter { $0.id != sheet.person?.id }
            case .restoreFrozenAlbum:
                guard let album = sheet.album else { throw CocoaError(.fileReadUnknown) }
                let snapshot = try await model.frozenAlbum(id: album.id)
                frozenAlbum = snapshot; text = snapshot.album.name; rebuildFrozen = false
                if let candidate = snapshot.rebuildCondition, snapshot.canRebuild,
                   model.conditionSourceSpaces.contains(candidate.sourceSpace),
                   await model.supportsManagement(.conditionAlbums, in: candidate.sourceSpace) {
                    canRebuildFrozen = true; condition = candidate
                } else { canRebuildFrozen = false }
            case .createConditionAlbum, .editConditionAlbum:
                if let album = sheet.album {
                    condition = try await model.albumCondition(id: album.id)
                    originalCondition = condition
                } else if sheet.space == .shared {
                    condition.fields["user_id"] = .integer(0)
                }
                await loadConditionFolders()
                await searchConditions()
            case .sharing:
                sharingAllowed = await model.supportsManagement(.sharing, in: .personal)
                guard sharingAllowed else { error = L10n.string("photos.selectionShare.unavailable"); return }
                guard let album = sheet.album else { throw CocoaError(.fileReadUnknown) }
                let state = try await model.albumSharing(id: album.id)
                originalSharing = state; linkAccess = state.access; sharingMembers = state.members ?? []
                sharingExpiration = PhotoSharingExpirationDraft(expiration: state.expiration)
                await loadSharingRecipients()
            case .addAlbum: albums = try await model.managementAlbums().filter(\.acceptsManualMembers)
            case .move, .copy:
                let destination = transferDestination
                let initialPath = transferSpace == nil ? sheet.transferPath : []
                let (root, children) = try await model.managementFolders(parentID: initialPath.last?.id, in: destination)
                guard destination == transferDestination else { return }
                guard initialPath.isEmpty || (initialPath.first?.id == root.id && initialPath.allSatisfy { $0.space == destination }) else { throw CocoaError(.fileReadUnknown) }
                folderPath = initialPath.isEmpty ? [root] : initialPath; folders = children
            case .tagsAdd, .tagsRemove: await model.loadFilterOptions(); error = model.filterOptionsErrorMessage
            case .renameFolder: text = sheet.folder?.name ?? ""
            case .renameAlbum: text = sheet.album?.name ?? ""
            case .description: text = sheet.photos.count == 1 ? sheet.photos.first?.description ?? "" : ""
            case .rating: rating = sheet.photos.first?.rating ?? 0
            case .date: date = sheet.photos.first?.takenAt ?? Date()
            case .upload:
                let sources = sheet.files
                let work = Task.detached { try PhotoUploadPreparation.prepare(sources) }
                let prepared = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                try Task.checkCancellation()
                uploadFiles = prepared.files
                skippedUploadCount = prepared.skippedCount
                includesUploadDirectory = prepared.includesDirectory
                if directAlbumUpload { preservesUploadDirectories = false }
                if prepared.includesDirectory && sheet.folder == nil && !directAlbumUpload {
                    uploadRootFolder = try await model.managementFolders(parentID: nil, in: sheet.space).0
                }
            default: break
            }
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") }
    }

    private func frozenConditionTitle(_ key: String) -> String {
        switch key {
        case "recently_add": L10n.string("photos.frozen.recentlyAdded")
        case "recently_comment": L10n.string("photos.frozen.recentlyCommented")
        case "update_time": L10n.string("photos.frozen.updated")
        case "people": L10n.string("photos.frozen.people")
        case "geocoding": L10n.string("photos.frozen.location")
        case "rating": L10n.string("photos.frozen.rating")
        case "camera": L10n.string("photos.frozen.camera")
        case "lens": L10n.string("photos.frozen.lens")
        case "flash": L10n.string("photos.frozen.flash")
        default: L10n.string("photos.frozen.other")
        }
    }

    private var conditionForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sheet.kind == .createConditionAlbum || sheet.kind == .restoreFrozenAlbum {
                    TextField(L10n.string("photos.manage.albumName"), text: $text).textFieldStyle(.roundedBorder)
                }
                if model.conditionSourceSpaces.count > 1 {
                    Picker(L10n.string("photos.condition.source"), selection: Binding(get: { condition.sourceSpace }, set: { switchConditionSource($0) })) {
                        ForEach(model.conditionSourceSpaces, id: \.self) { space in
                            Text(L10n.string(space == .personal ? "shared.51fcaa8035fc61e2" : "shared.17d2e16862f16829")).tag(space)
                        }
                    }
                    .disabled(isSearchingConditions || isLoading)
                }
                Picker(L10n.string("photos.condition.media"), selection: Binding(get: {
                    let values = condition.values("item_type")
                    return values.isEmpty ? 0 : values == [.integer(-1)] ? -1 : values == [.integer(-2)] ? -2 : -3
                }, set: { if $0 != -3 { condition.setValues($0 == 0 ? [] : [.integer($0)], for: "item_type") } })) {
                    Text(L10n.string("photos.condition.allMedia")).tag(0)
                    Text(L10n.string("photos.condition.photos")).tag(-1)
                    Text(L10n.string("photos.condition.videos")).tag(-2)
                    if ![[], [.integer(-1)], [.integer(-2)]].contains(condition.values("item_type")) {
                        Text(L10n.string("photos.condition.existingMedia")).tag(-3)
                    }
                }
                conditionDates
                DisclosureGroup(L10n.string("photos.condition.folders")) {
                    VStack(alignment: .leading) {
                        selectedConditionValues("folder_filter")
                        folderPicker.frame(height: 150)
                        if let folder = folderPath.last {
                            Button(L10n.string("photos.condition.addFolder")) {
                                addConditionOption(.init(name: folder.name, value: .integer(folder.id)), key: "folder_filter")
                            }
                        }
                    }
                }
                HStack {
                    Text(L10n.string("photos.manage.rating"))
                    ForEach(0...5, id: \.self) { value in
                        Toggle(value == 0 ? L10n.string("photos.manage.unrated") : String(repeating: "★", count: value), isOn: Binding(get: {
                            condition.values("rating").contains(.integer(value))
                        }, set: { selected in
                            var values = condition.values("rating").filter { $0 != .integer(value) }
                            if selected { values.append(.integer(value)) }
                            condition.setValues(values, for: "rating")
                        })).toggleStyle(.button)
                    }
                }.controlSize(.small)
                Divider()
                ForEach(SynologyPhotoConditionField.allCases, id: \.self) { field in
                    if !condition.values(field.rawValue).isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(conditionTitle(field)).font(.headline)
                                Spacer()
                                if field.supportsPolicy {
                                    Picker(L10n.string("photos.condition.match"), selection: Binding(get: {
                                        condition.fields[field.rawValue + "_policy"]?.string ?? "or"
                                    }, set: { condition.fields[field.rawValue + "_policy"] = .string($0) })) {
                                        Text(L10n.string("photos.condition.matchAll")).tag("and")
                                        Text(L10n.string("photos.condition.matchAny")).tag("or")
                                    }.frame(width: 225)
                                }
                            }
                            selectedConditionValues(field.rawValue)
                        }
                    }
                }
                HStack {
                    Picker(L10n.string("photos.condition.addRule"), selection: $conditionField) {
                        ForEach(SynologyPhotoConditionField.allCases.filter { $0 != .flash }, id: \.self) { field in
                            Text(conditionTitle(field)).tag(field)
                        }
                    }
                    TextField(L10n.string("photos.condition.search"), text: $conditionSearch)
                        .textFieldStyle(.roundedBorder).onSubmit { Task { await searchConditions() } }
                    if conditionField == .keyword {
                        Button(L10n.string("photos.condition.add")) {
                            let keyword = conditionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
                            addConditionOption(.init(name: keyword, value: .string(keyword)), key: "keyword")
                            conditionSearch = ""
                        }.disabled(conditionSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button(L10n.string("photos.condition.find")) { Task { await searchConditions() } }.disabled(isSearchingConditions)
                    }
                }
                if conditionField != .keyword {
                    if isSearchingConditions { ProgressView().controlSize(.small) }
                    if let suggestionError { Text(suggestionError).foregroundStyle(.red) }
                    let choices = suggestions[conditionField.rawValue] ?? []
                    if choices.isEmpty && !isSearchingConditions && suggestionError == nil {
                        Text(L10n.string("photos.condition.noSuggestions")).foregroundStyle(.secondary)
                    }
                    ForEach(choices) { choice in
                        Button { addConditionOption(choice, key: conditionField.rawValue) } label: {
                            Label(choice.name, systemImage: condition.values(conditionField.rawValue).contains(choice.value) ? "checkmark.circle.fill" : "plus.circle")
                        }.buttonStyle(.plain)
                    }
                }
                if let countError { Text(countError).foregroundStyle(.red) }
                HStack {
                    Button(L10n.string("photos.condition.preview")) { Task { await previewConditionCount() } }
                        .disabled(isCounting || !conditionDatesValid)
                    if isCounting { ProgressView().controlSize(.small) }
                    if let conditionCount { Text(L10n.string("photos.condition.count", conditionCount)).foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.onChange(of: condition) { _, _ in conditionCount = nil; countError = nil }
    }

    private var conditionDates: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(condition.values("time").indices, id: \.self) { index in
                HStack {
                    conditionDateBoundary(index: index, key: "start_time", title: "photos.condition.start")
                    conditionDateBoundary(index: index, key: "end_time", title: "photos.condition.end")
                    Button {
                        var times = condition.values("time"); times.remove(at: index); condition.setValues(times, for: "time")
                    } label: { Image(systemName: "minus.circle") }.accessibilityLabel(L10n.string("photos.condition.remove"))
                }
            }
            if condition.values("time").isEmpty {
                Button(L10n.string("photos.condition.addDate")) {
                    condition.setValues([.object(["start_time": .integer(Int(Date().timeIntervalSince1970))])], for: "time")
                }
            }
            if !conditionDatesValid { Text(L10n.string("photos.condition.invalidDates")).foregroundStyle(.red) }
        }
    }

    private func conditionDateBoundary(index: Int, key: String, title: String) -> some View {
        VStack(alignment: .leading) {
            Toggle(L10n.string(title), isOn: Binding(get: {
                conditionDateObject(index)?[key] != nil
            }, set: { enabled in updateConditionDate(index, key: key, date: enabled ? Date() : nil) }))
            if let seconds = conditionDateObject(index)?[key]?.integer {
                DatePicker(L10n.string(title), selection: Binding(get: { Date(timeIntervalSince1970: Double(seconds)) }, set: {
                    updateConditionDate(index, key: key, date: $0)
                })).labelsHidden().environment(\.locale, L10n.locale)
            }
        }
    }

    private func conditionDateObject(_ index: Int) -> [String: SynologyPhotoConditionValue]? {
        let times = condition.values("time")
        return times.indices.contains(index) ? times[index].object : nil
    }
    private func updateConditionDate(_ index: Int, key: String, date: Date?) {
        var times = condition.values("time")
        guard times.indices.contains(index), var value = times[index].object else { return }
        value[key] = date.map { .integer(Int($0.timeIntervalSince1970)) }
        times[index] = .object(value)
        condition.setValues(times.filter { $0.object?.isEmpty != true }, for: "time")
    }

    private var conditionDatesValid: Bool {
        condition.values("time").allSatisfy {
            let start = $0.object?["start_time"]?.integer, end = $0.object?["end_time"]?.integer
            return (start.map { $0 >= 0 } ?? true) && (end.map { $0 >= 0 } ?? true) && (start == nil || end == nil || start! <= end!)
        }
    }

    private func selectedConditionValues(_ key: String) -> some View {
        ForEach(condition.values(key), id: \.self) { value in
            HStack {
                Text(condition.names[key]?.first(where: { $0.value == value })?.name ?? conditionValueTitle(value)).lineLimit(2)
                Spacer()
                Button { condition.setValues(condition.values(key).filter { $0 != value }, for: key) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.condition.remove"))
            }
        }
    }

    private func conditionTitle(_ field: SynologyPhotoConditionField) -> String {
        switch field {
        case .keyword: L10n.string("photos.condition.field.keyword")
        case .person: L10n.string("photos.condition.field.person")
        case .concept: L10n.string("photos.condition.field.concept")
        case .general_tag: L10n.string("photos.condition.field.general_tag")
        case .camera: L10n.string("photos.condition.field.camera")
        case .lens: L10n.string("photos.condition.field.lens")
        case .aperture: L10n.string("photos.condition.field.aperture")
        case .iso: L10n.string("photos.condition.field.iso")
        case .geocoding: L10n.string("photos.condition.field.geocoding")
        case .focal_length_group: L10n.string("photos.condition.field.focal_length_group")
        case .exposure_time_group: L10n.string("photos.condition.field.exposure_time_group")
        case .flash: L10n.string("photos.condition.field.flash")
        }
    }
    private func conditionValueTitle(_ value: SynologyPhotoConditionValue) -> String {
        if let text = value.string { return text }
        if let id = value.integer { return L10n.string("photos.condition.missingReference", id) }
        func number(_ value: SynologyPhotoConditionValue?) -> String {
            if let integer = value?.integer { return integer.formatted(.number.locale(L10n.locale)) }
            if case .decimal(let number) = value { return number.formatted(.number.locale(L10n.locale)) }
            if let fraction = value?.object, let num = fraction["num"]?.integer, let den = fraction["den"]?.integer { return "\(num)/\(den)" }
            return "—"
        }
        return L10n.string("photos.condition.range", number(value.object?["start"]), number(value.object?["end"]))
    }
    private func addConditionOption(_ option: SynologyPhotoConditionOption, key: String) {
        var values = condition.values(key)
        if !values.contains(option.value) { values.append(option.value) }
        condition.setValues(values, for: key)
        condition.names[key, default: []].removeAll { $0.value == option.value }
        condition.names[key, default: []].append(option)
        if SynologyPhotoConditionField(rawValue: key)?.supportsPolicy == true && condition.fields[key + "_policy"] == nil {
            condition.fields[key + "_policy"] = .string("or")
        }
    }
    private func switchConditionSource(_ space: SynologyPhotoSpace) {
        guard space != condition.sourceSpace, model.conditionSourceSpaces.contains(space) else { return }
        conditionDrafts[condition.sourceSpace] = condition
        condition = conditionDrafts[space] ?? SynologyPhotoAlbumCondition(fields: space == .shared ? ["user_id": .integer(0), "item_type": .array([])] : ["item_type": .array([])])
        suggestions = [:]; suggestionError = nil; folderPath = []; folders = []
        Task { await loadConditionFolders(); await searchConditions() }
    }

    private func loadConditionFolders() async {
        let space = condition.sourceSpace
        isLoading = true
        defer { isLoading = false }
        do {
            let (root, children) = try await model.managementFolders(parentID: nil, in: space)
            guard space == condition.sourceSpace else { return }
            folderPath = [root]; folders = children
        } catch { if space == condition.sourceSpace { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") } }
    }

    private func searchConditions() async {
        guard !isSearchingConditions else { return }
        isSearchingConditions = true; suggestionError = nil
        defer { isSearchingConditions = false }
        let space = condition.sourceSpace
        do {
            let values = try await model.conditionSuggestions(keyword: conditionSearch, in: space)
            if space == condition.sourceSpace { suggestions = values }
        } catch { if space == condition.sourceSpace { suggestionError = L10n.string("photos.condition.searchFailed") } }
    }
    private func previewConditionCount() async {
        isCounting = true; countError = nil
        let snapshot = condition
        defer { isCounting = false }
        do {
            let count = try await model.conditionItemCount(snapshot)
            if snapshot == condition { conditionCount = count }
        } catch { if snapshot == condition { countError = L10n.string("photos.condition.countFailed") } }
    }

    private func openFolder(_ folder: SynologyPhotoCollection?, goBack: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        var path = folderPath
        if goBack { path.removeLast() } else if let folder { path.append(folder) }
        do {
            let (_, children) = try await model.managementFolders(parentID: path.last?.id, in: isRequestForm ? requestSettings.space : (isConditionForm ? condition.sourceSpace : (isTransferForm ? transferDestination : sheet.space)))
            folderPath = path; folders = children
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") }
    }
}

struct PhotoUploadQueuePanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var unresolvedUploadID: UUID?
    @State private var showsClearUnresolved = false

    private func reselectSource(_ id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { result in
            if result == .OK, let url = panel.url { model.reselectUploadSource(id, url: url) }
        }
    }

    private func uploadStateTitle(_ state: PhotoUploadEntry.State) -> String {
        switch state {
        case .queued: L10n.string("photos.upload.state.queued")
        case .uploading: L10n.string("photos.upload.state.uploading")
        case .preparingFolders: L10n.string("photos.upload.state.preparingFolders")
        case .addingToAlbum: L10n.string("photos.upload.state.addingToAlbum")
        case .completed: L10n.string("photos.upload.state.completed")
        case .skipped: L10n.string("photos.upload.state.skipped")
        case .failed: L10n.string("photos.upload.state.failed")
        case .pendingReview: L10n.string("photos.upload.state.pendingReview")
        case .cancelled: L10n.string("photos.upload.state.cancelled")
        }
    }

    private var navigationDisabled: Bool {
        model.isOpeningUploadDestination || model.isLoading || model.isDeleting || model.isCheckingDeletion || model.isBrowsingBlocked
    }

    private func open(_ id: UUID, destination: SynologyPhotosModel.UploadDestination) {
        Task { if await model.openUpload(id, destination: destination) { dismiss() } }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.upload.queue")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            if model.uploadQueue.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string("photos.upload.empty"), systemImage: "square.and.arrow.up")
                } description: { Text(L10n.string("photos.upload.emptyHint")) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.uploadQueue) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.file.url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Text(uploadStateTitle(entry.state)).foregroundStyle(.secondary)
                        }
                        if entry.space == .shared {
                            Text(L10n.string("shared.17d2e16862f16829")).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(L10n.string("photos.upload.destination", entry.album?.name ?? entry.folder?.name ?? L10n.string("photos.library.timeline")))
                            .font(.caption).foregroundStyle(.secondary)
                        if entry.state == .uploading { ProgressView(value: entry.progress) }
                        if entry.state == .addingToAlbum || entry.state == .preparingFolders { ProgressView().controlSize(.small) }
                        if let error = entry.error { Text(error).font(.callout).foregroundStyle(.red) }
                        if [.failed, .cancelled].contains(entry.state) {
                            if entry.uploadedPhoto == nil && entry.file.requiresSourceSelection {
                                Text(L10n.string("photos.upload.recovery.sourceNeeded")).font(.callout).foregroundStyle(.secondary)
                                Button(L10n.string("photos.upload.recovery.reselect")) { reselectSource(entry.id) }
                                    .disabled(model.isManaging || model.pendingMutationID != nil)
                            } else {
                                Button(L10n.string(entry.uploadedPhoto == nil ? "photos.retry" : "photos.upload.retryAlbum")) { model.retryUpload(entry.id) }
                                    .disabled(model.isManaging || model.pendingMutationID != nil || model.uploadPersistenceError != nil)
                            }
                        }
                        if entry.state == .pendingReview {
                            Button(L10n.string("photos.selection.retryReview")) { model.reviewPendingMutation() }.disabled(model.isManaging)
                            Button(L10n.string("photos.upload.recovery.clearUnresolved")) {
                                unresolvedUploadID = entry.id; showsClearUnresolved = true
                            }.disabled(model.isManaging)
                        }
                        HStack {
                            if model.canOpenUpload(entry.id, destination: .folder) {
                                Button(L10n.string("photos.upload.openFolder")) { open(entry.id, destination: .folder) }
                                    .disabled(navigationDisabled)
                                    .accessibilityIdentifier("photos.upload.openFolder")
                            }
                            if model.canOpenUpload(entry.id, destination: .album) {
                                Button(L10n.string("photos.upload.openAlbum")) { open(entry.id, destination: .album) }
                                    .disabled(navigationDisabled)
                                    .accessibilityIdentifier("photos.upload.openAlbum")
                            }
                            Spacer()
                            if model.canCancelUpload(entry.id) {
                                Button(L10n.string("photos.upload.cancelQueued")) { model.cancelUpload(entry.id) }
                                    .accessibilityIdentifier("photos.upload.cancelQueued")
                            }
                            if model.canClearUpload(entry.id) {
                                Button(L10n.string("photos.upload.clearEntry")) { model.clearUpload(entry.id) }
                                    .accessibilityIdentifier("photos.upload.clearEntry")
                            }
                        }
                    }.padding(.vertical, 8)
                }
            }
            if let error = model.uploadPersistenceError {
                HStack {
                    Text(error).font(.callout).foregroundStyle(.red)
                    Button(L10n.string("photos.retry")) { Task { await model.retryUploadPersistence() } }.disabled(model.isManaging)
                }.padding(.horizontal, 20).padding(.vertical, 8)
            }
            if model.isOpeningUploadDestination { ProgressView().controlSize(.small).padding(8) }
            if let error = model.uploadNavigationError {
                Text(error).font(.callout).foregroundStyle(.red).padding(.horizontal, 20).padding(.bottom, 8)
            }
            Divider()
            HStack {
                Button(L10n.string("photos.upload.clearFinished")) { model.clearFinishedUploads() }
                Spacer()
                if model.canResumeUploads {
                    Button(L10n.string("photos.upload.recovery.resume")) { model.resumeUploads() }
                }
                if model.isUploading {
                    Button(L10n.string("photos.upload.stopAfterCurrent")) { model.stopUploadQueue() }.disabled(model.stopsAfterCurrentUpload)
                }
                Button(L10n.string("photos.media.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
        }
        .confirmationDialog(L10n.string("photos.upload.recovery.clearTitle"), isPresented: $showsClearUnresolved) {
            if let id = unresolvedUploadID {
                Button(L10n.string("photos.upload.recovery.clearConfirmed")) { Task { await model.clearUnresolvedUploadAfterChecking(id) } }
            }
            Button(L10n.string("photos.delete.cancel"), role: .cancel) {}
        } message: { Text(L10n.string("photos.upload.recovery.clearMessage")) }
        .frame(width: 620, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private enum PhotoTimeShiftUnit: CaseIterable {
    case days, hours, minutes, seconds
    var seconds: Int {
        switch self { case .days: 86_400; case .hours: 3_600; case .minutes: 60; case .seconds: 1 }
    }
    var title: String {
        switch self {
        case .days: L10n.string("photos.manage.shiftDays")
        case .hours: L10n.string("photos.manage.shiftHours")
        case .minutes: L10n.string("photos.manage.shiftMinutes")
        case .seconds: L10n.string("photos.manage.shiftSeconds")
        }
    }
}

/// 未触碰日期时保留原始秒数；主动修改才按所选本地日末保存，兼容夏令时日长。
struct PhotoSharingExpirationDraft {
    enum Choice: Hashable { case unchanged, unlimited, date }
    var choice: Choice
    var date: Date
    var edited = false

    init(expiration: Int? = nil) {
        choice = expiration.map { $0 == 0 ? .unlimited : .date } ?? .unchanged
        date = expiration.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil } ?? Date()
    }

    func change(from original: Int?, calendar: Calendar = .current) -> Int? {
        guard edited else { return nil }
        let value: Int?
        switch choice {
        case .unchanged: value = nil
        case .unlimited: value = 0
        case .date: value = calendar.dateInterval(of: .day, for: date).flatMap { Int(exactly: $0.end.timeIntervalSince1970 - 1) }
        }
        return value == original ? nil : value
    }

    var isValid: Bool {
        guard edited, choice == .date else { return true }
        return change(from: nil).map { Double($0) > Date().timeIntervalSince1970 } ?? false
    }
}


/// 不读取旧密码；nil保留，空字符串清除，主动设置时完整保留空格和Unicode。
struct PhotoSharingPasswordDraft {
    enum Choice: Hashable { case unchanged, newPassword, remove }
    var choice: Choice = .unchanged
    var password = ""
    var isValid: Bool { choice != .newPassword || !password.isEmpty }
    func change(hasPassword: Bool?) -> String? {
        switch choice {
        case .unchanged: nil
        case .newPassword: password.isEmpty ? nil : password
        case .remove: hasPassword == false ? nil : ""
        }
    }
}

private struct PhotoFaceThumbnail: View {
    let model: SynologyPhotosModel
    let face: SynologyPhotoFace
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Color.secondary.opacity(0.1)
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Image(systemName: "person.crop.rectangle").foregroundStyle(.secondary) }
        }.clipped().task(id: face) {
            image = nil
            if let data = try? await model.faceThumbnail(face) { image = NSImage(data: data) }
        }
    }
}

/// 编辑目标保留打开时的照片及图像，预览切图不会改变待保存内容。
struct PhotoFaceEditorTarget: Identifiable {
    var id: SynologyPhotoID { photo.id }
    let photo: SynologyPhoto
    let data: Data
}

struct PhotoFaceDraft: Identifiable {
    let id: String
    let original: SynologyPhotoFaceRegion?
    var bounds: SynologyPhotoFaceBounds
    var personID: Int
    var name: String
    var removed = false
}

/// 裁剪和变化计算独立于视图，合成图片可验证坐标、方向和保存快照。
enum PhotoFaceEditing {
    enum Failure: Error { case invalidImage, invalidSelection }

    static func jpeg(_ image: CGImage, bounds: SynologyPhotoFaceBounds) throws -> Data {
        guard bounds.isValid else { throw Failure.invalidSelection }
        let rect = CGRect(x: bounds.x * Double(image.width), y: bounds.y * Double(image.height),
                          width: bounds.width * Double(image.width), height: bounds.height * Double(image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let crop = image.cropping(to: rect), crop.width > 0, crop.height > 0 else { throw Failure.invalidImage }
        let scale = min(1, 256 / Double(max(crop.width, crop.height)))
        let width = max(1, Int((Double(crop.width) * scale).rounded()))
        let height = max(1, Int((Double(crop.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.invalidImage }
        context.interpolationQuality = .high
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage(), let data = NSBitmapImageRep(cgImage: result).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { throw Failure.invalidImage }
        return data
    }

    static func changes(photo: SynologyPhoto, image: CGImage, drafts: [PhotoFaceDraft], people: [SynologyPhotoCollection]) throws -> [SynologyPhotoFaceChange] {
        var changes: [SynologyPhotoFaceChange] = []
        for (index, draft) in drafts.enumerated() {
            if draft.removed {
                if let original = draft.original { changes.append(.remove(original)) }
                continue
            }
            if let original = draft.original, original.bounds == draft.bounds, original.personID == draft.personID, original.name == draft.name { continue }
            let person = people.first { $0.id == draft.personID }
            let name = person?.name ?? draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard person != nil || !name.isEmpty else { throw Failure.invalidSelection }
            if let original = draft.original, original.bounds == draft.bounds {
                if original.personID != draft.personID || original.name != name { changes.append(.reassign(original, person: person, name: name)) }
            } else {
                if let original = draft.original { changes.append(.remove(original)) }
                changes.append(.add(.init(temporaryID: "\(photo.id.unitID)-\(index)", bounds: draft.bounds, person: person, name: name,
                    jpeg: try jpeg(image, bounds: draft.bounds))))
            }
        }
        return changes
    }

    static func square(from start: CGPoint, to end: CGPoint, in size: CGSize) -> SynologyPhotoFaceBounds? {
        guard size.width > 0, size.height > 0 else { return nil }
        let x = min(size.width, max(0, start.x)), y = min(size.height, max(0, start.y))
        let right = end.x >= x, down = end.y >= y
        let side = min(max(abs(end.x - x), abs(end.y - y)), right ? size.width - x : x, down ? size.height - y : y)
        guard side >= min(36, min(size.width, size.height)) else { return nil }
        return .init(x: (right ? x : x - side) / size.width, y: (down ? y : y - side) / size.height,
                     width: side / size.width, height: side / size.height)
    }
}

struct PhotoFaceEditor: View {
    @Bindable var model: SynologyPhotosModel
    let target: PhotoFaceEditorTarget
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [PhotoFaceDraft] = []
    @State private var people: [SynologyPhotoCollection] = []
    @State private var selectedID: String?
    @State private var isLoading = true
    @State private var error: String?
    @State private var image: CGImage?
    @State private var isDrawing = false
    @State private var newBounds: SynologyPhotoFaceBounds?
    @State private var dragOrigin: SynologyPhotoFaceBounds?
    private var selectedIndex: Int? { drafts.firstIndex { $0.id == selectedID } }
    private var canSave: Bool {
        guard !isLoading, error == nil, image != nil, !model.isManaging, model.pendingMutationID == nil else { return false }
        let changed = drafts.contains { draft in
            guard let original = draft.original else { return !draft.removed }
            return draft.removed || draft.bounds != original.bounds || draft.personID != original.personID || draft.name != original.name
        }
        return changed && drafts.filter { !$0.removed }.allSatisfy { draft in
            if let original = draft.original, original.bounds == draft.bounds, original.personID == draft.personID, original.name == draft.name { return true }
            return draft.personID > 0 || !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.faces.edit")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let error {
                ContentUnavailableView { Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle") }
                    description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { Task { await load() } } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Button { isDrawing.toggle(); newBounds = nil } label: { Label(L10n.string("photos.faces.add"), systemImage: "plus.viewfinder") }
                                .buttonStyle(MacToolbarButtonStyle(selected: isDrawing))
                            Text(L10n.string(isDrawing ? "photos.faces.drawHint" : "photos.faces.editHint")).font(.callout).foregroundStyle(.secondary)
                        }
                        canvas(image)
                    }.padding(16)
                    Divider()
                    inspector.frame(width: 250).padding(16)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(L10n.string("photos.faces.keepPhotos")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("photos.faces.save")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canSave)
            }.padding(20)
        }.frame(width: 1040, height: 720)
            .background(Color(nsColor: .windowBackgroundColor)).task { await load() }
    }

    private func canvas(_ image: CGImage) -> some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / CGFloat(image.width), geometry.size.height / CGFloat(image.height))
            let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                ForEach(drafts.filter { !$0.removed }) { draft in
                    faceBox(draft, size: size)
                }
                if let box = newBounds {
                    Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5]))
                        .frame(width: box.width * size.width, height: box.height * size.height)
                        .offset(x: box.x * size.width, y: box.y * size.height).allowsHitTesting(false)
                }
                if isDrawing {
                    Color.clear.frame(width: size.width, height: size.height).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 3)
                        .onChanged { newBounds = PhotoFaceEditing.square(from: $0.startLocation, to: $0.location, in: size) }
                        .onEnded { value in
                            guard let bounds = PhotoFaceEditing.square(from: value.startLocation, to: value.location, in: size) else { newBounds = nil; return }
                            let id = UUID().uuidString
                            drafts.append(.init(id: id, original: nil, bounds: bounds, personID: 0, name: ""))
                            selectedID = id; newBounds = nil; isDrawing = false
                        })
                }
            }.frame(width: size.width, height: size.height)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }.clipped().accessibilityLabel(L10n.string("photos.faces.canvas"))
    }

    private func faceBox(_ draft: PhotoFaceDraft, size: CGSize) -> some View {
        let selected = selectedID == draft.id
        return Rectangle().fill(Color.black.opacity(0.08))
            .overlay(Rectangle().strokeBorder(selected ? Color.accentColor : Color.white, lineWidth: selected ? 3 : 1))
            .overlay(alignment: .topLeading) {
                Text(draft.name.isEmpty ? L10n.string("photos.people.unnamed") : draft.name).font(.caption).padding(3)
                    .foregroundStyle(.white).background(.black.opacity(0.7)).allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if selected {
                    Circle().fill(Color.accentColor).frame(width: 14, height: 14).contentShape(Rectangle())
                        .gesture(DragGesture().onChanged { value in
                            guard let index = selectedIndex else { return }
                            if dragOrigin == nil { dragOrigin = drafts[index].bounds }
                            guard let origin = dragOrigin else { return }
                            let side = min(max(10, max(origin.width * size.width + value.translation.width, origin.height * size.height + value.translation.height)),
                                           (1 - origin.x) * size.width, (1 - origin.y) * size.height)
                            drafts[index].bounds.width = side / size.width; drafts[index].bounds.height = side / size.height
                        }.onEnded { _ in dragOrigin = nil })
                        .accessibilityLabel(L10n.string("photos.faces.resize"))
                }
            }
            .frame(width: draft.bounds.width * size.width, height: draft.bounds.height * size.height)
            .offset(x: draft.bounds.x * size.width, y: draft.bounds.y * size.height)
            .onTapGesture { selectedID = draft.id }
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                selectedID = draft.id
                guard let index = selectedIndex else { return }
                if dragOrigin == nil { dragOrigin = drafts[index].bounds }
                guard let origin = dragOrigin else { return }
                drafts[index].bounds.x = min(1 - origin.width, max(0, origin.x + value.translation.width / size.width))
                drafts[index].bounds.y = min(1 - origin.height, max(0, origin.y + value.translation.height / size.height))
            }.onEnded { _ in dragOrigin = nil })
            .accessibilityLabel(draft.name.isEmpty ? L10n.string("photos.people.unnamed") : draft.name)
            .accessibilityAddTraits(.isButton).accessibilityAction { selectedID = draft.id }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 12) {
            if drafts.isEmpty {
                ContentUnavailableView(L10n.string("photos.people.noFaces"), systemImage: "person.crop.rectangle",
                    description: Text(L10n.string("photos.faces.emptyHint")))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(drafts) { draft in
                            Button { selectedID = draft.id } label: {
                                HStack {
                                    Image(systemName: draft.removed ? "minus.circle" : "person.crop.square")
                                    Text(draft.name.isEmpty ? L10n.string("photos.people.unnamed") : draft.name).lineLimit(2)
                                    Spacer()
                                    if selectedID == draft.id { Image(systemName: "checkmark") }
                                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 210)
            }
            if let index = selectedIndex {
                Divider()
                if drafts[index].removed {
                    Button(L10n.string("photos.faces.undoRemove")) { drafts[index].removed = false }
                } else {
                    Picker(L10n.string("photos.people.destination"), selection: $drafts[index].personID) {
                        Text(L10n.string("photos.people.newPerson")).tag(0)
                        ForEach(people) { person in Text(person.name.isEmpty ? L10n.string("photos.people.unnamed") : person.name).tag(person.id) }
                    }.onChange(of: drafts[index].personID) { _, id in
                        drafts[index].name = people.first { $0.id == id }?.name ?? ""
                    }
                    if drafts[index].personID == 0 { TextField(L10n.string("photos.people.name"), text: $drafts[index].name).textFieldStyle(.roundedBorder) }
                    // 数值控件为键盘和辅助功能提供等价的画框入口。
                    Slider(value: $drafts[index].bounds.x, in: 0...max(0.000001, 1 - drafts[index].bounds.width)) { Text(L10n.string("photos.faces.horizontal")) }
                    Slider(value: $drafts[index].bounds.y, in: 0...max(0.000001, 1 - drafts[index].bounds.height)) { Text(L10n.string("photos.faces.vertical")) }
                    if let image {
                        let maximum = max(1, min((1 - drafts[index].bounds.x) * Double(image.width), (1 - drafts[index].bounds.y) * Double(image.height)))
                        Slider(value: Binding(get: { min(maximum, max(1, drafts[index].bounds.width * Double(image.width))) }, set: { side in
                            drafts[index].bounds.width = side / Double(image.width)
                            drafts[index].bounds.height = side / Double(image.height)
                        }), in: 1...maximum) { Text(L10n.string("photos.faces.size")) }
                    }
                    Button(L10n.string("photos.faces.remove"), role: .destructive) {
                        if drafts[index].original == nil { drafts.remove(at: index); selectedID = nil }
                        else { drafts[index].removed = true }
                    }
                }
            }
            Spacer()
            Button(L10n.string("photos.faces.addCentered")) {
                guard let image else { return }
                let side = Double(min(image.width, image.height)) * 0.25
                let width = side / Double(image.width), height = side / Double(image.height), id = UUID().uuidString
                drafts.append(.init(id: id, original: nil, bounds: .init(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height), personID: 0, name: ""))
                selectedID = id; isDrawing = false
            }
        }
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            guard let decoded = NSImage(data: target.data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw PhotoFaceEditing.Failure.invalidImage }
            let faces = try await model.photoFaces(for: target.photo)
            var candidates = try await model.peopleVisibility(in: target.photo.id.space).map(\.person)
            for face in faces where face.personID > 0 && !candidates.contains(where: { $0.id == face.personID }) {
                candidates.append(.init(id: face.personID, name: face.name, space: target.photo.id.space))
            }
            try Task.checkCancellation()
            image = decoded; people = candidates
            drafts = faces.map { .init(id: "face-\($0.id)", original: $0, bounds: $0.bounds, personID: $0.personID, name: $0.name) }
            selectedID = drafts.first?.id
        } catch is CancellationError { }
        catch { self.error = L10n.string("photos.faces.failed") }
    }

    private func save() {
        guard canSave, let image else { return }
        do {
            let changes = try PhotoFaceEditing.changes(photo: target.photo, image: image, drafts: drafts, people: people)
            guard !changes.isEmpty else { return }
            model.submitMutation(.editPhotoFaces(photo: target.photo, changes: changes)); dismiss()
        } catch { self.error = L10n.string("photos.faces.failed") }
    }
}


/// 恢复列表来自NAS；关闭应用不丢失任务来源，确认时固定本次所选原件快照。
struct PhotoPreviewRecoveryPanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var space: SynologyPhotoSpace
    @State private var photos: [SynologyPhoto] = []
    @State private var selected: Set<SynologyPhotoID> = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var loadID = UUID()

    init(model: SynologyPhotosModel, initialSpace: SynologyPhotoSpace) {
        self.model = model; _space = State(initialValue: initialSpace)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.preview.recovery.title")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            if model.spaces.count > 1 {
                Picker(L10n.string("photos.library.space"), selection: $space) {
                    ForEach(model.spaces, id: \.self) { item in
                        Text(L10n.string(item == .personal ? "shared.51fcaa8035fc61e2" : "shared.17d2e16862f16829")).tag(item)
                    }
                }.pickerStyle(.segmented).padding(16)
            }
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }
                } else if photos.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.string("photos.preview.recovery.empty"), systemImage: "checkmark.circle")
                    } description: { Text(L10n.string("photos.preview.recovery.emptyHint")) } actions: {
                        Button(L10n.string("photos.library.refresh")) { Task { await load() } }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L10n.string("photos.selection.count", selected.count))
                            Spacer()
                            Button(L10n.string("photos.selection.loaded")) { selected = Set(photos.prefix(100).map(\.id)) }
                            Button(L10n.string("photos.preview.recovery.clear")) { selected = [] }
                        }.padding(.horizontal, 16)
                        Text(L10n.string("photos.preview.recovery.confirm")).foregroundStyle(.secondary).padding(.horizontal, 16)
                        if photos.count > 100 { Text(L10n.string("photos.preview.recovery.limit")).foregroundStyle(.secondary).padding(.horizontal, 16) }
                        List(photos, selection: $selected) { photo in
                            Text(photo.filename).lineLimit(1).truncationMode(.middle).tag(photo.id)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("photos.preview.recovery.resume")) {
                    let targets = photos.filter { selected.contains($0.id) }
                    guard !targets.isEmpty, targets.count <= 100 else { return }
                    model.submitMutation(.regeneratePreviews(targets, resuming: true))
                    dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isLoading || error != nil || selected.isEmpty || selected.count > 100 || model.isManaging || model.pendingMutationID != nil)
            }.padding(16)
        }.frame(width: 640, height: 540)
            .background(Color(nsColor: .windowBackgroundColor))
            .task(id: space) { await load() }
    }

    private func load() async {
        let id = UUID(), requestedSpace = space
        loadID = id; isLoading = true; error = nil; photos = []; selected = []
        defer { if loadID == id { isLoading = false } }
        do {
            let pending = try await model.pendingPreviewRegenerations(in: requestedSpace)
            guard loadID == id, space == requestedSpace, !Task.isCancelled else { return }
            photos = pending; selected = Set(pending.prefix(100).map(\.id))
        } catch is CancellationError { }
        catch {
            guard loadID == id, space == requestedSpace, !Task.isCancelled else { return }
            self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.preview.recovery.failed")
        }
    }
}

struct PhotoFolderCoverTarget: Identifiable {
    let id = UUID()
    let folder: SynologyPhotoCollection
    var photo: SynologyPhoto? = nil
}

/// 选择器始终以目标文件夹为根，浏览子目录不改变最终设置目标。
struct PhotoFolderCoverPanel: View {
    let model: SynologyPhotosModel
    let target: PhotoFolderCoverTarget
    @Environment(\.dismiss) private var dismiss
    @State private var history: [SynologyPhotoCollection] = []
    @State private var children: [SynologyPhotoCollection] = []
    @State private var photos: [SynologyPhoto] = []
    @State private var selected: SynologyPhoto?
    @State private var offset = 0
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var error: String?
    @State private var submitted = false
    @State private var sort = SynologyPhotoSort()
    @State private var loadID = UUID()
    @State private var isVisible = false
    private var current: SynologyPhotoCollection { history.last ?? target.folder }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("photos.folderCover.change")).font(.title2.bold())
                    Text(target.folder.name).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(L10n.string("photos.media.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            HStack {
                Button { history.removeLast() } label: { Image(systemName: "chevron.left") }
                    .disabled(history.isEmpty || model.isManaging || model.pendingMutationID != nil).accessibilityLabel(L10n.string("photos.folderCover.back"))
                Text(current.name).lineLimit(1)
                Spacer()
                PhotoFolderSortMenu(sort: sort, changeSort: changeSort)
                    .disabled(isLoading || selected != nil || model.isManaging || model.pendingMutationID != nil || !model.managementFeatures.contains(.folderSorting))
                if let selected { Text(selected.filename).lineLimit(1).foregroundStyle(.secondary) }
            }.padding(12)
            if isLoading && photos.isEmpty && children.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, photos.isEmpty && children.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button(L10n.string("photos.retry")) { Task { await load(reset: true) } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if photos.isEmpty && children.isEmpty {
                ContentUnavailableView(L10n.string("photos.folderCover.empty"), systemImage: "photo", description: Text(L10n.string("photos.folderCover.emptyHint")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 170))], spacing: 12) {
                        ForEach(children) { folder in
                            Button { selected = nil; history.append(folder) } label: {
                                VStack {
                                    Image(systemName: "folder.fill").font(.system(size: 34)).foregroundStyle(.tint).frame(height: 80)
                                    Text(folder.name).lineLimit(2)
                                }.frame(maxWidth: .infinity).frame(height: 128)
                            }.buttonStyle(.plain).disabled(model.isManaging || model.pendingMutationID != nil)
                        }
                        ForEach(photos) { photo in
                            Button { selected = selected?.id == photo.id ? nil : photo } label: {
                                VStack(spacing: 4) {
                                    SynologyPhotoCell(photo: photo, model: model, showsSimilarBadge: false).frame(height: 100).clipped()
                                    Text(photo.filename).lineLimit(1)
                                }.padding(4).background(selected?.id == photo.id ? Color.accentColor.opacity(0.2) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                    .overlay(alignment: .topTrailing) { if selected?.id == photo.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor) } }
                            }.buttonStyle(.plain).disabled(model.isManaging || model.pendingMutationID != nil).accessibilityAddTraits(selected?.id == photo.id ? .isSelected : [])
                        }
                    }.padding(16)
                    if let error {
                        Text(error).foregroundStyle(.secondary)
                        Button(L10n.string("photos.retry")) { Task { await load(reset: false) } }
                    } else if hasMore {
                        Button(L10n.string("photos.folderCover.more")) { Task { await load(reset: false) } }.disabled(isLoading || model.isManaging || model.pendingMutationID != nil)
                    }
                    if isLoading { ProgressView() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if submitted {
                HStack {
                    if model.isManaging { ProgressView().controlSize(.small) }
                    if let message = model.managementMessage { Text(message).font(.callout) }
                    if model.pendingMutationID != nil && !model.isManaging {
                        Button(L10n.string("photos.selection.retryReview")) { model.reviewPendingMutation() }
                    }
                }.padding(8)
            }
            Divider()
            HStack {
                Text(L10n.string("photos.folderCover.hint")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }
                Button(L10n.string("photos.folderCover.set")) {
                    if let selected {
                        submitted = true
                        model.submitMutation(.setFolderCover(folder: target.folder, photo: selected)) { result in
                            if result.state == .confirmed { dismiss() }
                        }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selected == nil || isLoading || error != nil || model.isManaging || model.pendingMutationID != nil)
            }.padding(16)
        }.frame(width: 680, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; loadID = UUID() }
        .task(id: current) { await load(reset: true) }
    }

    private func changeSort(_ value: SynologyPhotoSort) {
        guard value != sort, selected == nil, !isLoading else { return }
        let folder = current
        submitted = true
        model.submitMutation(.setFolderSort(folder: folder, sort: value)) { result in
            guard result.state == .confirmed, isVisible, current == folder else { return }
            sort = value
            Task { await load(reset: true, readsSort: false) }
        }
    }

    private func load(reset: Bool, readsSort: Bool = true) async {
        let folder = current, id = UUID()
        loadID = id
        isLoading = true; error = nil
        if reset { photos = []; children = []; offset = 0; hasMore = false; selected = history.isEmpty ? target.photo : nil }
        defer { if loadID == id { isLoading = false } }
        do {
            if reset {
                if readsSort {
                    let value = try await model.folderCoverSort(folder)
                    guard loadID == id, current == folder, !Task.isCancelled else { return }
                    sort = value
                }
                let value = try await model.folderCoverChildren(folder, direction: sort.direction)
                guard loadID == id, current == folder, !Task.isCancelled else { return }
                children = value
            }
            let page = try await model.folderCoverPage(folder, offset: offset, sort: sort)
            guard loadID == id, current == folder, !Task.isCancelled else { return }
            guard page.offset == offset, page.nextOffset == offset + page.items.count,
                  page.items.allSatisfy({ $0.id.space == target.folder.space && $0.folderID == folder.id }),
                  !page.hasMore || !page.items.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            photos.append(contentsOf: page.items.filter { photo in !photos.contains(where: { $0.id == photo.id }) })
            offset = page.nextOffset; hasMore = page.hasMore
        } catch is CancellationError { }
        catch { if loadID == id, current == folder { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.folderCover.failed") } }
    }
}

private extension SynologyPhotoSort.Field {
    var folderSortTitle: String {
        switch self {
        case .filename: L10n.string("photos.folderSort.filename")
        case .filesize: L10n.string("photos.folderSort.filesize")
        case .itemType: L10n.string("photos.folderSort.item_type")
        case .takenTime: L10n.string("photos.folderSort.takentime")
        }
    }
}

/// 图库与封面选择器共用同一组排序字段和方向。
extension SynologyPhotoAlbumDisplay {
    var albumListTitle: String {
        switch self {
        case .all: L10n.string("photos.albumList.all_album")
        case .mine: L10n.string("photos.albumList.my_album")
        }
    }
}
extension SynologyPhotoAlbumListSort.Field {
    var albumListTitle: String {
        switch self {
        case .name: L10n.string("photos.albumList.album_name")
        case .type: L10n.string("photos.albumList.album_type")
        case .startTime: L10n.string("photos.albumList.start_time")
        case .created: L10n.string("photos.albumList.create_time")
        case .sharing: L10n.string("photos.albumList.share_status")
        case .shareModified: L10n.string("photos.albumList.share_modify_time")
        }
    }
}

struct PhotoAlbumListControls: View {
    @Bindable var model: SynologyPhotosModel
    var body: some View {
        HStack {
            if model.albumListScope == .albums, let display = model.albumListDisplay {
                Menu {
                    ForEach(SynologyPhotoAlbumDisplay.allCases, id: \.self) { value in
                        Button { model.changeAlbumListDisplay(value) } label: {
                            Label(value.albumListTitle, systemImage: display == value ? "checkmark" : "")
                        }
                    }
                } label: { Text(display.albumListTitle) }
                .accessibilityIdentifier("photos.albumList.display")
            }
            Spacer()
            if let scope = model.albumListScope, let sort = model.albumListSort {
                Menu {
                    ForEach(scope.fields, id: \.self) { field in
                        Button { model.changeAlbumListSort(.init(field: field, direction: sort.direction)) } label: {
                            Label(field.albumListTitle, systemImage: sort.field == field ? "checkmark" : "")
                        }
                    }
                    Divider()
                    ForEach(SynologyPhotoSort.Direction.allCases, id: \.self) { direction in
                        Button { model.changeAlbumListSort(.init(field: sort.field, direction: direction)) } label: {
                            Label(L10n.string(direction == .ascending ? "workspace.sort.ascending" : "workspace.sort.descending"), systemImage: sort.direction == direction ? "checkmark" : "")
                        }
                    }
                } label: { Label(L10n.string("photos.folderSort.title"), systemImage: "arrow.up.arrow.down") }
                .accessibilityIdentifier("photos.albumList.sort")
            }
        }.disabled(model.isLoading || model.isManaging || model.pendingMutationID != nil || model.isDeleting || model.isCheckingDeletion)
    }
}

struct PhotoFolderSortMenu: View {
    var accessibilityID = "photos.folderSort"
    let sort: SynologyPhotoSort
    let changeSort: (SynologyPhotoSort) -> Void
    var body: some View {
        Menu {
            ForEach(SynologyPhotoSort.Field.allCases, id: \.self) { field in
                Button { changeSort(.init(field: field, direction: sort.direction)) } label: {
                    Label(field.folderSortTitle, systemImage: sort.field == field ? "checkmark" : "")
                }
            }
            Divider()
            ForEach(SynologyPhotoSort.Direction.allCases, id: \.self) { direction in
                Button { changeSort(.init(field: sort.field, direction: direction)) } label: {
                    Label(L10n.string(direction == .ascending ? "workspace.sort.ascending" : "workspace.sort.descending"), systemImage: sort.direction == direction ? "checkmark" : "")
                }
            }
        } label: { Label(L10n.string("photos.folderSort.title"), systemImage: "arrow.up.arrow.down") }
            .accessibilityIdentifier(accessibilityID)
    }
}


/// 共享目录打开时只读现状；保存固定快照经统一确认、去重和自动结果核对。
struct PhotoFolderSharingPanel: View {
    let model: SynologyPhotosModel
    let folder: SynologyPhotoCollection
    @Environment(\.dismiss) private var dismiss
    @State private var state: SynologyPhotoFolderSharingState?
    @State private var error: String?
    @State private var isLoading = false

    @State private var access: SynologyPhotoFolderSharingState.Access = .management
    @State private var members: [SynologyPhotoShareGrant] = []
    @State private var password = PhotoSharingPasswordDraft()
    @State private var apply = false
    @State private var supportsEditing = false
    @State private var confirmation: SynologyPhotosMutation?
    @State private var showsRecipients = false
    @State private var recipients: [SynologyPhotoShareRecipient] = []
    @State private var recipientID: SynologyPhotoShareRecipient.ID?
    @State private var recipientSearch = ""
    @State private var recipientRole = "view"
    @State private var recipientError: String?
    @State private var loadingRecipients = false
    private let roles = ["view", "download", "upload", "manage"]

    private var busy: Bool { isLoading || model.isManaging || model.isDeleting || model.isCheckingDeletion || model.pendingMutationID != nil }
    private var editable: Bool { supportsEditing && state?.inheritsManagementOnly == false && !busy }
    private var availableRecipients: [SynologyPhotoShareRecipient] {
        recipients.filter { recipient in !members.contains { $0.id == recipient.id } &&
            (recipientSearch.isEmpty || recipient.name.localizedCaseInsensitiveContains(recipientSearch)) }
    }
    private var command: SynologyPhotosMutation? {
        guard let state, editable, password.isValid else { return nil }
        let change = password.change(hasPassword: state.hasPassword)
        guard state.access != access || state.members.map({ $0 != members }) == true || change != nil || state.appliesToSubfolders != apply || apply else { return nil }
        return .setFolderSharing(original: state, access: access, members: state.members == nil ? nil : members,
            password: change, appliesToSubfolders: apply)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("photos.folderSharing.title")).font(.title2.bold())
                    Text(folder.name).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView { Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle") }
                    description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { Task { await load() } } }
                } else if let state {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Picker(L10n.string("photos.manage.linkAccess"), selection: $access) {
                                ForEach(SynologyPhotoFolderSharingState.Access.allCases, id: \.self) { value in Text(accessTitle(value)).tag(value) }
                            }.disabled(!editable).accessibilityIdentifier("photos.folderSharing.access")
                            if state.inheritsManagementOnly {
                                Label(L10n.string("photos.folderSharing.parentRestricted"), systemImage: "folder.badge.gearshape").foregroundStyle(.secondary)
                            }
                            HStack {
                                Text(state.url.absoluteString).lineLimit(2).textSelection(.enabled)
                                Spacer()
                                Button(L10n.string("photos.sharing.copyLink")) {
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(state.url.absoluteString, forType: .string)
                                }
                            }
                            LabeledContent(L10n.string("photos.sharing.password"), value: L10n.string(state.hasPassword == true ? "photos.folderSharing.protected" : state.hasPassword == false ? "photos.folderSharing.unprotected" : "photos.folderSharing.unknown"))
                            Divider()
                            if supportsEditing {
                                Picker(L10n.string("photos.sharing.password"), selection: $password.choice) {
                                    Text(L10n.string("photos.sharing.passwordKeep")).tag(PhotoSharingPasswordDraft.Choice.unchanged)
                                    Text(L10n.string("photos.sharing.passwordSet")).tag(PhotoSharingPasswordDraft.Choice.newPassword)
                                    Text(L10n.string("photos.sharing.passwordRemove")).tag(PhotoSharingPasswordDraft.Choice.remove)
                                }.disabled(!editable)
                                if password.choice == .newPassword {
                                    SecureField(L10n.string("photos.sharing.passwordPlaceholder"), text: $password.password).textFieldStyle(.roundedBorder).disabled(!editable)
                                }
                            }
                            memberEditor.disabled(!editable)
                            if state.depth == 1 {
                                Toggle(L10n.string("photos.folderSharing.apply"), isOn: $apply).disabled(!editable)
                                    .accessibilityIdentifier("photos.folderSharing.apply")
                            }

                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button(L10n.string("photos.library.refresh")) { Task { await load() } }.disabled(busy)
                Spacer()
                Button(L10n.string("photos.media.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                if supportsEditing {
                    Button(L10n.string("photos.folderSharing.save")) { confirmation = command }
                        .keyboardShortcut(.defaultAction).disabled(command == nil).accessibilityIdentifier("photos.folderSharing.save")
                }
            }.padding(20)
        }.frame(width: 620, height: 540).background(Color(nsColor: .windowBackgroundColor))
            .task { await load() }
            .onDisappear { password = .init(); confirmation = nil }
            .alert(L10n.string("photos.folderSharing.confirmTitle"), isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), presenting: confirmation) { confirmed in
                Button(L10n.string("photos.delete.cancel"), role: .cancel) { confirmation = nil }
                Button(L10n.string("photos.folderSharing.save")) {
                    guard !busy else { return }
                    model.submitMutation(confirmed); password = .init(); confirmation = nil; dismiss()
                }
            } message: { confirmed in
                if case .setFolderSharing(let original, _, _, _, let applies) = confirmed {
                    Text(L10n.string(applies ? "photos.folderSharing.confirmChildren" : "photos.folderSharing.confirm", original.folder.name))
                }
            }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true; error = nil; state = nil
        defer { isLoading = false }
        do {
            let loaded = try await model.folderSharing(folder)
            let supported = await model.supportsManagement(.folderSharing, in: .shared)
            try Task.checkCancellation()
            state = loaded; access = loaded.access; members = loaded.members ?? []; apply = loaded.appliesToSubfolders
            password = .init(); supportsEditing = supported; showsRecipients = false; recipients = []; recipientID = nil
        }
        catch is CancellationError { }
        catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.folderSharing.readFailed") }
    }

    @ViewBuilder private var memberEditor: some View {
        Text(L10n.string("photos.sharing.members")).font(.headline)
        if state?.members == nil {
            Text(L10n.string("photos.sharing.membersUnreadable")).foregroundStyle(.secondary)
        } else {
            if members.isEmpty { Text(L10n.string("photos.sharing.noMembers")).foregroundStyle(.secondary) }
            ForEach($members) { $member in
                HStack {
                    Label(member.recipient.name, systemImage: member.id.type == "group" ? "person.2" : "person").lineLimit(1).help(member.recipient.name)
                    Spacer()
                    if supportsEditing {
                        Picker(L10n.string("photos.sharing.role"), selection: $member.role) {
                            if !roles.contains(member.role) { Text(member.role).tag(member.role) }
                            ForEach(roles, id: \.self) { role in Text(roleTitle(role)).tag(role) }
                        }.labelsHidden().frame(width: 185)
                        Button { members.removeAll { $0.id == member.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.sharing.removeMember", member.recipient.name))
                    } else { Text(roleTitle(member.role)).foregroundStyle(.secondary) }
                }
            }
            if supportsEditing {
                if !showsRecipients {
                    Button(L10n.string("photos.sharing.addMember")) { showsRecipients = true; Task { await loadRecipients() } }
                } else if loadingRecipients { ProgressView().controlSize(.small) }
                else if let recipientError {
                    Text(recipientError).foregroundStyle(.secondary)
                    Button(L10n.string("photos.retry")) { Task { await loadRecipients() } }
                } else {
                    TextField(L10n.string("photos.sharing.searchMembers"), text: $recipientSearch).textFieldStyle(.roundedBorder)
                    if availableRecipients.isEmpty { Text(L10n.string("photos.sharing.noAvailableMembers")).foregroundStyle(.secondary) }
                    HStack {
                        Picker(L10n.string("photos.sharing.member"), selection: $recipientID) {
                            Text(L10n.string("photos.sharing.chooseMember")).tag(Optional<SynologyPhotoShareRecipient.ID>.none)
                            ForEach(availableRecipients) { recipient in Text(recipient.name).tag(Optional(recipient.id)) }
                        }
                        Picker(L10n.string("photos.sharing.role"), selection: $recipientRole) {
                            ForEach(roles, id: \.self) { role in Text(roleTitle(role)).tag(role) }
                        }.frame(width: 185)
                        Button(L10n.string("photos.sharing.addMember")) {
                            guard let recipient = availableRecipients.first(where: { $0.id == recipientID }) else { return }
                            members.append(.init(recipient: recipient, role: recipientRole)); recipientID = nil
                        }.disabled(!availableRecipients.contains { $0.id == recipientID })
                    }
                }
            }
        }
    }

    private func loadRecipients() async {
        loadingRecipients = true; recipientError = nil
        defer { loadingRecipients = false }
        do { recipients = try await model.folderSharingRecipients() }
        catch is CancellationError { }
        catch { recipientError = L10n.string("photos.sharing.membersLoadFailed") }
    }

    private func accessTitle(_ access: SynologyPhotoFolderSharingState.Access) -> String {
        switch access {
        case .management: L10n.string("photos.folderSharing.management")
        case .invited: L10n.string("photos.sharing.invited")
        case .view: L10n.string("photos.manage.link.view")
        case .download: L10n.string("photos.manage.link.download")
        }
    }
    private func roleTitle(_ role: String) -> String {
        switch role {
        case "view": L10n.string("photos.sharing.role.view")
        case "download": L10n.string("photos.sharing.role.download")
        case "upload": L10n.string("photos.sharing.role.upload")
        case "manage": L10n.string("photos.folderSharing.role.manage")
        default: role
        }
    }
}

struct PhotoUploadDuplicatePicker: View {
    @Binding var selection: SynologyPhotoDuplicateSettings.Upload
    var body: some View {
        Picker(L10n.string("photos.duplicates.upload"), selection: $selection) {
            Text(L10n.string("photos.duplicates.ignore")).tag(SynologyPhotoDuplicateSettings.Upload.ignore)
            Text(L10n.string("photos.duplicates.rename")).tag(SynologyPhotoDuplicateSettings.Upload.rename)
        }.accessibilityIdentifier("photos.duplicates.upload")
    }
}

struct PhotoTransferDuplicatePicker: View {
    @Binding var selection: SynologyPhotoDuplicateSettings.Transfer
    var body: some View {
        Picker(L10n.string("photos.duplicates.transfer"), selection: $selection) {
            Text(L10n.string("photos.duplicates.skip")).tag(SynologyPhotoDuplicateSettings.Transfer.skip)
            Text(L10n.string("photos.duplicates.overwrite")).tag(SynologyPhotoDuplicateSettings.Transfer.overwrite)
        }.accessibilityIdentifier("photos.duplicates.transfer")
    }
}

struct PhotoDuplicateSettingsPanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: SynologyPhotoDuplicateSettings?
    @State private var upload = SynologyPhotoDuplicateSettings.Upload.rename
    @State private var transfer = SynologyPhotoDuplicateSettings.Transfer.skip
    @State private var isLoading = true
    @State private var error: String?
    @State private var confirmedSettings: SynologyPhotosMutation?
    @State private var showsOverwriteConfirmation = false

    private var mutation: SynologyPhotosMutation? {
        let updated = SynologyPhotoDuplicateSettings(upload: upload, transfer: transfer)
        return original.flatMap { $0 == updated ? nil : .setDuplicateSettings(original: $0, updated: updated) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.duplicates.title")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PhotoUploadDuplicatePicker(selection: $upload)
                    PhotoTransferDuplicatePicker(selection: $transfer)
                    if transfer == .overwrite {
                        Text(L10n.string("photos.duplicates.defaultOverwriteWarning")).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("photos.duplicates.save")) {
                    guard let mutation else { return }
                    if original?.transfer != .overwrite && transfer == .overwrite {
                        confirmedSettings = mutation; showsOverwriteConfirmation = true
                    } else { model.submitMutation(mutation); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isLoading || error != nil || mutation == nil || model.isManaging || model.pendingMutationID != nil)
            }.padding(20)
        }
        .frame(width: 560, height: 340)
        .background(MacGlassSurface(role: .content))
        .task { await load() }
        .alert(L10n.string("photos.duplicates.overwriteTitle"), isPresented: $showsOverwriteConfirmation) {
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { confirmedSettings = nil }
            Button(L10n.string("photos.duplicates.save"), role: .destructive) {
                if let command = confirmedSettings { model.submitMutation(command); dismiss() }
                confirmedSettings = nil
            }
        } message: { Text(L10n.string("photos.duplicates.defaultOverwriteWarning")) }
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let settings = try await model.duplicateSettings()
            try Task.checkCancellation()
            original = settings; upload = settings.upload; transfer = settings.transfer
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") }
    }
}


struct PhotoDisplaySettingsPanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: SynologyPhotoDisplaySettings?
    @State private var value = SynologyPhotoDisplaySettings()
    @State private var isLoading = true
    @State private var error: String?
    @State private var confirmation: SynologyPhotosMutation?
    @State private var showsSortConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.display.title")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        Picker(L10n.string("photos.display.grouping"), selection: $value.grouping) {
                            Text(L10n.string("photos.display.day")).tag(SynologyPhotoDisplaySettings.Grouping.day)
                            Text(L10n.string("photos.display.month")).tag(SynologyPhotoDisplaySettings.Grouping.month)
                        }.accessibilityIdentifier("photos.display.grouping")
                        Picker(L10n.string("photos.display.date"), selection: $value.dateFormat) {
                            ForEach(SynologyPhotoDisplaySettings.DateFormat.allCases, id: \.self) { format in
                                Text(format.rawValue.replacingOccurrences(of: "yyyy", with: "2019").replacingOccurrences(of: "mm", with: "12").replacingOccurrences(of: "dd", with: "31")).tag(format)
                            }
                        }.accessibilityIdentifier("photos.display.date")
                        Picker(L10n.string("photos.display.time"), selection: $value.clock) {
                            Text(L10n.string("photos.display.clock12")).tag(SynologyPhotoDisplaySettings.Clock.twelve)
                            Text(L10n.string("photos.display.clock24")).tag(SynologyPhotoDisplaySettings.Clock.twentyFour)
                        }
                        Picker(L10n.string("photos.display.sort"), selection: $value.defaultSort.field) {
                            ForEach(SynologyPhotoSort.Field.allCases, id: \.self) { field in Text(field.folderSortTitle).tag(field) }
                        }
                        Picker(L10n.string("photos.folderSort.title"), selection: $value.defaultSort.direction) {
                            Text(L10n.string("workspace.sort.ascending")).tag(SynologyPhotoSort.Direction.ascending)
                            Text(L10n.string("workspace.sort.descending")).tag(SynologyPhotoSort.Direction.descending)
                        }
                        Text(L10n.string("photos.display.sortHint")).font(.caption).foregroundStyle(.secondary)
                        Toggle(L10n.string("photos.display.previewInfo"), isOn: $value.showsPreviewInfo)
                            .accessibilityIdentifier("photos.display.previewInfo")
                    }.formStyle(.grouped)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("photos.duplicates.save")) {
                    guard let original, original != value else { return }
                    let command = SynologyPhotosMutation.setDisplaySettings(original: original, updated: value)
                    if original.defaultSort != value.defaultSort {
                        confirmation = command; showsSortConfirmation = true
                    } else { model.submitMutation(command); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isLoading || error != nil || original == nil || original == value || model.isManaging || model.pendingMutationID != nil)
            }.padding(20)
        }.frame(width: 600, height: 500).background(MacGlassSurface(role: .content))
        .task { await load() }
        .alert(L10n.string("photos.display.sortConfirmTitle"), isPresented: $showsSortConfirmation) {
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { confirmation = nil }
            Button(L10n.string("photos.duplicates.save")) {
                guard let confirmation else { return }
                model.submitMutation(confirmation); dismiss()
            }
        } message: {
            if case .setDisplaySettings(_, let target) = confirmation {
                Text(L10n.string("photos.display.sortConfirmMessage", target.defaultSort.field.folderSortTitle,
                    L10n.string(target.defaultSort.direction == .ascending ? "workspace.sort.ascending" : "workspace.sort.descending")))
            }
        }
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let settings = try await model.displaySettings()
            try Task.checkCancellation()
            original = settings; value = settings
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") }
    }
}


struct PhotoRecognitionSettingsPanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: SynologyPhotoRecognitionSettings?
    @State private var enabled: Set<SynologyPhotoRecognitionSettings.Kind> = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.recognition.title")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let original, !original.values.isEmpty {
                    Form {
                        if !original.personalSpaceEnabled { Text(L10n.string("photos.recognition.homeRequired")).foregroundStyle(.secondary) }
                        ForEach(SynologyPhotoRecognitionSettings.Kind.allCases, id: \.self) { kind in
                            if original.values[kind] != nil {
                                Toggle(kind.recognitionTitle, isOn: Binding(get: { enabled.contains(kind) }, set: { value in
                                    if value { enabled.insert(kind) } else { enabled.remove(kind) }
                                }))
                                .disabled(!original.editable.contains(kind))
                                .accessibilityIdentifier("photos.recognition." + kind.rawValue)
                                if original.personalSpaceEnabled && !original.globallyEnabled.contains(kind) {
                                    Text(L10n.string("photos.recognition.adminRequired")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.formStyle(.grouped)
                } else {
                    ContentUnavailableView(L10n.string("photos.recognition.empty"), systemImage: "sparkles",
                        description: Text(L10n.string("photos.recognition.emptyHint")))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("photos.duplicates.save")) {
                    guard let original, original.canSave(enabled) else { return }
                    model.submitMutation(.setRecognitionSettings(original: original, enabled: enabled)); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isLoading || error != nil || original?.canSave(enabled) != true || model.isManaging || model.pendingMutationID != nil)
            }.padding(20)
        }.frame(width: 560, height: 380).background(MacGlassSurface(role: .content))
        .task { await load() }
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let settings = try await model.recognitionSettings()
            try Task.checkCancellation()
            original = settings; enabled = settings.enabled
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") }
    }
}


private extension SynologyPhotoRecognitionSettings.Kind {
    var recognitionTitle: String {
        switch self {
        case .person: L10n.string("photos.recognition.enable_person")
        case .concept: L10n.string("photos.recognition.enable_concept")
        case .similar: L10n.string("photos.recognition.enable_similar")
        }
    }
}


struct PhotoCodecPromptPanel: View {
    @Bindable var model: SynologyPhotosModel
    let initial: SynologyPhotoCodecPrompt?
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: SynologyPhotoCodecPrompt?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.codec.title")).font(.title2.bold())
                Spacer()
            }.padding(20)
            Divider()
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }
                } else if let prompt {
                    VStack(alignment: .leading, spacing: 16) {
                        if !prompt.shouldShow { Text(L10n.string("photos.codec.none")) }
                        else if prompt.generationAlreadySubmitted { Text(L10n.string("photos.codec.submitted")) }
                        else {
                            Text(L10n.string(prompt.isAdministrator ? "photos.codec.allUsers" : "photos.codec.personal"))
                            if !prompt.canGenerate { Text(L10n.string("photos.codec.unavailable")).foregroundStyle(.secondary) }
                        }
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                if let prompt, prompt.shouldShow, error == nil, !isLoading {
                    Button(L10n.string(prompt.generationAlreadySubmitted ? "photos.codec.dismiss" : "photos.codec.later")) {
                        respond(prompt, generate: false)
                    }.keyboardShortcut(.cancelAction)
                    Button(L10n.string("photos.codec.generate")) { respond(prompt, generate: true) }
                        .buttonStyle(.borderedProminent).disabled(!prompt.canGenerate)
                } else {
                    Button(L10n.string("photos.media.close")) { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }.padding(20).disabled(model.isManaging || model.pendingMutationID != nil)
        }.frame(width: 580, height: 300).background(MacGlassSurface(role: .content))
        .task {
            if let initial { prompt = initial; isLoading = false }
            else { await load() }
        }
        .onAppear { model.setAutomaticPreviewSettingsVisible(true) }
        .onDisappear { model.setAutomaticPreviewSettingsVisible(false) }
    }

    private func respond(_ prompt: SynologyPhotoCodecPrompt, generate: Bool) {
        model.submitMutation(.respondToCodecPrompt(prompt, generate: generate)); dismiss()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let value = try await model.codecPrompt()
            try Task.checkCancellation()
            prompt = value; error = nil
        } catch is CancellationError { }
        catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.codec.readFailed") }
    }
}

struct PhotoLibraryMaintenancePanel: View {
    @Bindable var model: SynologyPhotosModel
    let space: SynologyPhotoSpace
    @Environment(\.dismiss) private var dismiss
    @State private var status: SynologyPhotoLibraryMaintenanceStatus?
    @State private var isLoading = true
    @State private var error: String?
    @State private var confirmation: SynologyPhotosMutation?
    @State private var showsConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.maintenance.title")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let status {
                    VStack(alignment: .leading, spacing: 24) {
                        if space == .shared { Text(L10n.string("photos.maintenance.shared")).font(.headline) }
                        maintenanceRow(.reindex, status: status)
                        Divider()
                        maintenanceRow(.previews, status: status)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Button(L10n.string("photos.library.refresh")) { Task { await load() } }.disabled(isLoading)
                Spacer()
                Button(L10n.string("photos.media.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
        }.frame(width: 620, height: 400).background(MacGlassSurface(role: .content))
        .task {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard !showsConfirmation else { continue }
                await load(showsLoading: false)
            }
        }
        .alert(L10n.string("photos.maintenance.confirmTitle"), isPresented: $showsConfirmation) {
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { confirmation = nil }
            Button(L10n.string("photos.maintenance.start")) {
                guard let confirmation else { return }
                model.submitMutation(confirmation); dismiss()
            }
        } message: {
            if case .maintainLibrary(let original, let action) = confirmation {
                Text(L10n.string(action == .reindex ? "photos.maintenance.confirmReindex" : "photos.maintenance.confirmPreviews",
                    L10n.string(original.space == .personal ? "photos.maintenance.personal" : "photos.maintenance.shared")))
            }
        }
    }

    private func maintenanceRow(_ action: SynologyPhotoLibraryMaintenanceStatus.Action, status: SynologyPhotoLibraryMaintenanceStatus) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string(action == .reindex ? "photos.maintenance.reindex" : "photos.maintenance.previews")).font(.headline)
                Text(L10n.string(action == .reindex ? "photos.maintenance.reindexDescription" : "photos.maintenance.previewsDescription"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if action == .previews && !status.supportsPreviewGeneration {
                    Text(L10n.string("photos.maintenance.previewUnavailable")).font(.callout).foregroundStyle(.secondary)
                } else if status.pendingCount(for: action) > 0 {
                    Label(L10n.string("photos.maintenance.running"), systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button(L10n.string("photos.maintenance.start")) {
                confirmation = .maintainLibrary(status, action); showsConfirmation = true
            }.accessibilityIdentifier(action == .reindex ? "photos.maintenance.reindex" : "photos.maintenance.previews")
                .disabled(!status.canStart(action) || model.isManaging || model.pendingMutationID != nil)
        }
    }

    private func load(showsLoading: Bool = true) async {
        if showsLoading { isLoading = true }
        defer { isLoading = false }
        do {
            let value = try await model.libraryMaintenanceStatus(in: space)
            try Task.checkCancellation()
            status = value; error = nil
        } catch is CancellationError { }
        catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.maintenance.readFailed") }
    }
}

struct PhotoAutomaticPreviewSettingsPanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: Bool?
    @State private var enabled = false
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.automatic.title")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Form {
                        Toggle(L10n.string("photos.automatic.enabled"), isOn: $enabled)
                            .accessibilityIdentifier("photos.automatic.enabled")
                        Text(L10n.string("photos.automatic.description")).font(.callout).foregroundStyle(.secondary)
                        if !model.automaticPreviewSupported { Text(L10n.string("photos.automatic.unsupported")).foregroundStyle(.secondary) }
                        if model.isGeneratingAutomaticPreview {
                            Button(L10n.string("photos.automatic.pause")) { model.pauseAutomaticPreviews() }
                        }
                    }.formStyle(.grouped)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("photos.duplicates.save")) {
                    guard let original, original != enabled else { return }
                    model.submitMutation(.setAutomaticPreview(original: original, enabled: enabled)); dismiss()
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isLoading || error != nil || original == nil || original == enabled || model.isManaging || model.pendingMutationID != nil)
            }.padding(20)
        }.frame(width: 560, height: 340).background(MacGlassSurface(role: .content))
        .onAppear { model.setAutomaticPreviewSettingsVisible(true) }
        .onDisappear { model.setAutomaticPreviewSettingsVisible(false) }
        .task { await load() }
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            original = try await model.automaticPreviewSetting()
            try Task.checkCancellation()
            enabled = original ?? false
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") }
    }
}

struct PhotoSharedSpaceSettingsPanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: SynologyPhotoSharedSpaceSettings?
    @State private var enabled: Set<SynologyPhotoSharedSpaceSettings.Kind> = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var confirmation: SynologyPhotosMutation?
    @State private var showsConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.sharedSettings.title")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let original {
                    Form {
                        Section {
                            LabeledContent(L10n.string("photos.sharedSettings.status"), value: L10n.string(original.isEnabled ? "photos.sharedSettings.on" : "photos.sharedSettings.off"))
                            Button(L10n.string(original.isEnabled ? "photos.sharedSettings.disable" : "photos.sharedSettings.enable")) {
                                confirm(.setSharedSpaceEnabled(original: original, enabled: !original.isEnabled))
                            }.disabled(!original.canSetEnabled(!original.isEnabled) || model.isManaging || model.pendingMutationID != nil)
                            if original.isEnabled && !original.personalSpaceEnabled {
                                Text(L10n.string("photos.sharedSettings.lastSpace")).font(.caption).foregroundStyle(.secondary)
                            } else if !original.isEnabled && original.disabledBySharedFolder == true {
                                Text(L10n.string("photos.sharedSettings.folderDisabled")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if original.isEnabled {
                            Section(L10n.string("photos.sharedSettings.preferences")) {
                                ForEach(SynologyPhotoSharedSpaceSettings.Kind.allCases, id: \.self) { kind in
                                    if original.values[kind] != nil {
                                        Toggle(kind.sharedSettingsTitle, isOn: Binding(get: { enabled.contains(kind) }, set: { value in
                                            if value { enabled.insert(kind) } else { enabled.remove(kind) }
                                        })).disabled(!original.editable.contains(kind))
                                            .accessibilityIdentifier("photos.sharedSettings." + kind.rawValue)
                                    }
                                }
                                if original.values.isEmpty {
                                    Text(L10n.string("photos.sharedSettings.empty")).foregroundStyle(.secondary)
                                } else if !Set(original.values.keys).subtracting([.publicRoot]).isSubset(of: original.globallyEnabled) {
                                    Text(L10n.string("photos.sharedSettings.globalRequired")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }.formStyle(.grouped)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("photos.duplicates.save")) {
                    guard let original, original.canSave(enabled) else { return }
                    let command = SynologyPhotosMutation.setSharedSpaceSettings(original: original, enabled: enabled)
                    if original.enabled.contains(.publicRoot) != enabled.contains(.publicRoot) { confirm(command) }
                    else { model.submitMutation(command); dismiss() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isLoading || error != nil || original?.canSave(enabled) != true || model.isManaging || model.pendingMutationID != nil)
            }.padding(20)
        }.frame(width: 580, height: 480).background(MacGlassSurface(role: .content))
        .task { await load() }
        .alert(L10n.string("photos.sharedSettings.confirmTitle"), isPresented: $showsConfirmation) {
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { confirmation = nil }
            Button(L10n.string("photos.duplicates.save")) {
                guard let confirmation else { return }
                model.submitMutation(confirmation); dismiss()
            }
        } message: { Text(confirmationMessage) }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .setSharedSpaceEnabled(_, let enabled): L10n.string(enabled ? "photos.sharedSettings.enableConfirm" : "photos.sharedSettings.disableConfirm")
        case .setSharedSpaceSettings(_, let enabled): L10n.string(enabled.contains(.publicRoot) ? "photos.sharedSettings.publicConfirm" : "photos.sharedSettings.privateConfirm")
        default: ""
        }
    }
    private func confirm(_ command: SynologyPhotosMutation) { confirmation = command; showsConfirmation = true }
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let settings = try await model.sharedSpaceSettings()
            try Task.checkCancellation()
            original = settings; enabled = settings.enabled
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") }
    }
}

private extension SynologyPhotoSharedSpaceSettings.Kind {
    var sharedSettingsTitle: String {
        switch self {
        case .person: L10n.string("photos.sharedSettings.person")
        case .concept: L10n.string("photos.sharedSettings.concept")
        case .similar: L10n.string("photos.sharedSettings.similar")
        case .publicRoot: L10n.string("photos.sharedSettings.publicRoot")
        }
    }
}


struct PhotoGlobalSettingsPanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: SynologyPhotoGlobalSettings?
    @State private var enabled: Set<SynologyPhotoGlobalSettings.Kind> = []
    @State private var excluded: Set<String>?
    @State private var cache: SynologyPhotoConversionCache?
    @State private var isLoading = true
    @State private var cacheLoading = false
    @State private var error: String?
    @State private var cacheError: String?
    @State private var confirmation: SynologyPhotosMutation?
    @State private var showsConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.global.title")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let original {
                    Form {
                        Section(L10n.string("photos.global.recognition")) {
                            settingsToggles([.person, .concept, .similar], original: original)
                        }
                        Section(L10n.string("photos.global.sharing")) {
                            settingsToggles([.userSharing, .guestInfo], original: original)
                        }
                        if original.values.isEmpty && original.excludedExtensions == nil {
                            Text(L10n.string("photos.global.empty")).foregroundStyle(.secondary)
                        }
                        if excluded != nil {
                            Section {
                                DisclosureGroup(L10n.string("photos.global.excluded")) {
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 5), alignment: .leading) {
                                        ForEach(SynologyPhotoGlobalSettings.supportedExtensions.union(original.excludedExtensions ?? []).sorted(), id: \.self) { value in
                                            Toggle(isOn: Binding(get: { excluded?.contains(value) == true }, set: { checked in
                                                if checked { excluded?.insert(value) } else { excluded?.remove(value) }
                                            })) { Text(verbatim: value) }.toggleStyle(.checkbox)
                                        }
                                    }.padding(.top, 8)
                                }
                            }
                        }
                        if original.values[.originalJPEG] != nil || model.managementFeatures.contains(.conversionCache) {
                            Section(L10n.string("photos.global.conversion")) {
                                settingsToggles([.originalJPEG], original: original)
                                if original.values[.originalJPEG] != nil && original.hasHEVC != true {
                                    Text(L10n.string("photos.global.codecRequired")).font(.caption).foregroundStyle(.secondary)
                                }
                                if model.managementFeatures.contains(.conversionCache) {
                                    HStack {
                                        Text(L10n.string("photos.global.cache"))
                                        Spacer()
                                        if cacheLoading { ProgressView().controlSize(.small) }
                                        else if let cache {
                                            Text(cache.sizeBytes.formatted(.byteCount(style: .file).locale(L10n.locale))).foregroundStyle(.secondary)
                                        }
                                        Button { Task { await loadCache() } } label: { Image(systemName: "arrow.clockwise") }
                                            .accessibilityLabel(L10n.string("photos.library.refresh"))
                                            .disabled(cacheLoading)
                                    }
                                    if let cacheError {
                                        Text(cacheError).foregroundStyle(.red).font(.callout)
                                    } else if cache?.isClearing == true {
                                        Label(L10n.string("photos.global.clearing"), systemImage: "clock").foregroundStyle(.secondary)
                                    }
                                    Button(L10n.string("photos.global.clearCache")) {
                                        guard let cache else { return }
                                        confirm(.clearConversionCache(cache))
                                    }.disabled(cache?.canClear != true || cacheLoading || model.isManaging || model.pendingMutationID != nil)
                                }
                            }
                        }
                    }.formStyle(.grouped)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("photos.duplicates.save")) {
                    guard let original else { return }
                    confirm(.setGlobalSettings(original: original, enabled: enabled, excludedExtensions: excluded))
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isLoading || error != nil || original?.canSave(enabled: enabled, excludedExtensions: excluded) != true || model.isManaging || model.pendingMutationID != nil)
            }.padding(20)
        }.frame(width: 620, height: 680).background(MacGlassSurface(role: .content))
        .task { await load() }
        .task(id: cache?.isClearing) {
            while cache?.isClearing == true, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await loadCache()
            }
        }
        .alert(L10n.string("photos.global.confirmTitle"), isPresented: $showsConfirmation) {
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { confirmation = nil }
            Button(L10n.string(confirmation?.feature == .conversionCache ? "photos.global.clearCache" : "photos.duplicates.save")) {
                guard let confirmation else { return }
                model.submitMutation(confirmation); dismiss()
            }
        } message: { Text(confirmationMessage) }
    }

    @ViewBuilder private func settingsToggles(_ kinds: [SynologyPhotoGlobalSettings.Kind], original: SynologyPhotoGlobalSettings) -> some View {
        ForEach(kinds, id: \.self) { kind in
            if original.values[kind] != nil {
                Toggle(kind.globalTitle, isOn: Binding(get: { enabled.contains(kind) }, set: { value in
                    if value { enabled.insert(kind) } else { enabled.remove(kind) }
                })).disabled(!original.editable.contains(kind))
                    .accessibilityIdentifier("photos.global." + kind.rawValue)
            }
        }
    }
    private var confirmationMessage: String {
        if case .clearConversionCache = confirmation { return L10n.string("photos.global.clearConfirm") }
        guard case .setGlobalSettings(let original, let enabled, let excluded) = confirmation else { return "" }
        var messages = [L10n.string("photos.global.saveConfirm")]
        if !original.enabled.subtracting(enabled).intersection([.person, .concept, .similar]).isEmpty { messages.append(L10n.string("photos.global.recognitionConfirm")) }
        if original.values[.userSharing] == true, !enabled.contains(.userSharing) { messages.append(L10n.string("photos.global.sharingConfirm")) }
        if original.values[.guestInfo] == false, enabled.contains(.guestInfo) { messages.append(L10n.string("photos.global.guestConfirm")) }
        if original.excludedExtensions != excluded { messages.append(L10n.string("photos.global.excludedConfirm")) }
        if original.values[.originalJPEG] == true, !enabled.contains(.originalJPEG) { messages.append(L10n.string("photos.global.clearConfirm")) }
        return messages.joined(separator: "\n\n")
    }
    private func confirm(_ mutation: SynologyPhotosMutation) { confirmation = mutation; showsConfirmation = true }
    private func load() async {
        isLoading = true; error = nil
        do {
            let settings = try await model.globalSettings()
            try Task.checkCancellation()
            original = settings; enabled = settings.enabled; excluded = settings.excludedExtensions
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") }
        isLoading = false
        if original != nil, model.managementFeatures.contains(.conversionCache) { await loadCache() }
    }
    private func loadCache() async {
        guard !cacheLoading else { return }
        cacheLoading = true; cacheError = nil
        defer { cacheLoading = false }
        do { cache = try await model.conversionCache() }
        catch { cache = nil; cacheError = L10n.string("photos.global.cacheFailed") }
    }
}

private extension SynologyPhotoGlobalSettings.Kind {
    var globalTitle: String {
        switch self {
        case .person: L10n.string("photos.global.person")
        case .concept: L10n.string("photos.global.concept")
        case .similar: L10n.string("photos.global.similar")
        case .userSharing: L10n.string("photos.global.userSharing")
        case .guestInfo: L10n.string("photos.global.guestInfo")
        case .originalJPEG: L10n.string("photos.global.originalJPEG")
        }
    }
}

/// 成员和目录修改均为窗口内草稿，只有主窗口最终确认才提交。
struct PhotoSharedMembersPanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var original: SynologyPhotoSharedMembers?
    @State private var members: [SynologyPhotoSharedMember] = []
    @State private var candidates: [SynologyPhotoShareRecipient] = []
    @State private var edits: [SynologyPhotoShareRecipient.ID: SynologyPhotoMemberFolderEdit] = [:]
    @State private var search = ""
    @State private var candidateSearch = ""
    @State private var isLoading = true
    @State private var candidatesLoading = false
    @State private var error: String?
    @State private var candidatesError: String?
    @State private var showsAdd = false
    @State private var folderTarget: SynologyPhotoSharedMember?
    @State private var confirmation: SynologyPhotosMutation?
    @State private var showsConfirmation = false

    private var filtered: [SynologyPhotoSharedMember] {
        members.filter { search.isEmpty || $0.recipient.name.localizedStandardContains(search) }
    }
    private var available: [SynologyPhotoShareRecipient] {
        candidates.filter { candidate in
            !members.contains(where: { $0.id == candidate.id }) &&
                !(candidate.id.type == "group" && candidate.name == "administrators") &&
                (candidateSearch.isEmpty || candidate.name.localizedStandardContains(candidateSearch))
        }
    }
    private var command: SynologyPhotosMutation? {
        guard let original else { return nil }
        let changes = members.compactMap { edits[$0.id] }.filter(\.canSave)
        guard original.canSave(members, candidates: candidates, allowsUnchanged: !changes.isEmpty) else { return nil }
        return .setSharedMembers(original: original, members: members, folderEdits: changes)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.members.title")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }
                } else if original?.isEnabled == false {
                    ContentUnavailableView(L10n.string("photos.members.disabled"), systemImage: "person.2.slash",
                        description: Text(L10n.string("photos.members.enableFirst")))
                } else {
                    memberContent
                }
            }.fillsAvailableContentArea(alignment: .topLeading)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("photos.duplicates.save")) { confirmation = command; showsConfirmation = confirmation != nil }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("photos.members.save")
                    .disabled(isLoading || error != nil || command == nil || model.isManaging || model.pendingMutationID != nil)
            }.padding(20)
        }.frame(width: 780, height: 620).background(MacGlassSurface(role: .content))
        .task { await load() }
        .sheet(item: $folderTarget) { member in
            PhotoMemberFolderPermissionsPanel(model: model, member: member, initial: edits[member.id]) { edit in
                if let index = members.firstIndex(where: { $0.id == member.id }) { members[index] = member }
                else { members.append(member) }
                edits[member.id] = edit
            }
        }
        .alert(L10n.string("photos.members.confirmTitle"), isPresented: $showsConfirmation) {
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { confirmation = nil }
            Button(L10n.string("photos.duplicates.save")) {
                guard let confirmation else { return }
                model.submitMutation(confirmation); dismiss()
            }
        } message: { Text(L10n.string("photos.members.confirmMessage")) }
    }

    private var memberContent: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L10n.string("photos.members.search"), text: $search).textFieldStyle(.roundedBorder)
                Button { showsAdd = true } label: { Label(L10n.string("photos.members.add"), systemImage: "plus") }
                    .accessibilityIdentifier("photos.members.add")
                    .popover(isPresented: $showsAdd) { candidatePicker }
                Menu {
                    Button(L10n.string("photos.members.backupAll")) { setBackupForAll(true) }
                    Button(L10n.string("photos.members.backupNone")) { setBackupForAll(false) }
                } label: { Label(L10n.string("photos.members.backup"), systemImage: "arrow.clockwise.icloud") }
                    .disabled(!members.contains { $0.canEdit && $0.role == "entry" })
            }.padding(16)
            if filtered.isEmpty {
                ContentUnavailableView(L10n.string(members.isEmpty ? "photos.members.empty" : "photos.members.noMatches"),
                    systemImage: "person.2", description: Text(L10n.string(members.isEmpty ? "photos.members.emptyHint" : "photos.members.searchHint")))
            } else {
                List(filtered) { member in memberRow(member).padding(.vertical, 6) }.listStyle(.inset)
            }
        }
    }

    private func memberRow(_ member: SynologyPhotoSharedMember) -> some View {
        HStack(spacing: 12) {
            Image(systemName: member.id.type == "group" ? "person.2" : "person")
                .accessibilityLabel(L10n.string(member.id.type == "group" ? "photos.members.group" : "photos.members.user"))
            VStack(alignment: .leading, spacing: 4) {
                Text(member.recipient.name).lineLimit(2)
                if member.isProtected { Text(L10n.string("photos.members.protected")).font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if member.canEdit {
                Picker(L10n.string("photos.members.role"), selection: Binding(get: { member.role }, set: { role in
                    guard let target = SynologyPhotoSharedMember.Role(rawValue: role) else { return }
                    let changed = member.changingRole(to: target)
                    if target == .entry { folderTarget = changed }
                    else if let index = members.firstIndex(where: { $0.id == member.id }) {
                        members[index] = changed; edits.removeValue(forKey: member.id)
                    }
                })) {
                    Text(L10n.string("photos.members.role.entry")).tag("entry")
                    Text(L10n.string("photos.members.role.management")).tag("management")
                }.labelsHidden().frame(width: 132)
                Toggle(L10n.string("photos.members.backup"), isOn: Binding(get: { member.autoBackup }, set: { value in
                    if let index = members.firstIndex(where: { $0.id == member.id }) { members[index].autoBackup = value }
                })).disabled(member.role == "management")
                Button { folderTarget = member } label: { Image(systemName: "folder.badge.person.crop") }
                    .help(L10n.string("photos.members.folders")).accessibilityLabel(L10n.string("photos.members.folders"))
                    .disabled(member.role != "entry")
                Button(role: .destructive) {
                    members.removeAll { $0.id == member.id }; edits.removeValue(forKey: member.id)
                } label: { Image(systemName: "minus.circle") }
                    .help(L10n.string("photos.members.remove")).accessibilityLabel(L10n.string("photos.members.remove"))
            } else {
                Text(L10n.string(member.role == "management" ? "photos.members.role.management" : "photos.members.unknownRole"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var candidatePicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("photos.members.add")).font(.headline)
            TextField(L10n.string("photos.members.search"), text: $candidateSearch).textFieldStyle(.roundedBorder)
            if candidatesLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let candidatesError {
                Text(candidatesError).foregroundStyle(.secondary)
                Button(L10n.string("photos.retry")) { Task { await loadCandidates() } }
                Spacer()
            } else if available.isEmpty {
                ContentUnavailableView(L10n.string("photos.members.noMatches"), systemImage: "person.crop.circle.badge.questionmark",
                    description: Text(L10n.string("photos.members.candidateHint")))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(available) { candidate in
                            Menu {
                                Button(L10n.string("photos.members.role.entry")) {
                                    showsAdd = false
                                    folderTarget = SynologyPhotoSharedMember(recipient: candidate, role: .entry)
                                }
                                Button(L10n.string("photos.members.role.management")) {
                                    members.append(.init(recipient: candidate, role: .management)); showsAdd = false
                                }
                            } label: {
                                Label(candidate.name, systemImage: candidate.id.type == "group" ? "person.2" : "person")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.menuStyle(.borderlessButton)
                        }
                    }
                }
            }
        }.padding(16).frame(width: 360, height: 330)
    }

    private func setBackupForAll(_ value: Bool) {
        for index in members.indices where members[index].canEdit && members[index].role == "entry" { members[index].autoBackup = value }
    }
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let result = try await model.sharedSpaceMembers(); try Task.checkCancellation()
            original = result; members = result.members; edits = [:]
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.members.loadFailed"); return }
        await loadCandidates()
    }
    private func loadCandidates() async {
        candidatesLoading = true; candidatesError = nil
        defer { candidatesLoading = false }
        do { let result = try await model.sharedSpaceMemberCandidates(); try Task.checkCancellation(); candidates = result }
        catch { candidatesError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.members.loadFailed") }
    }
}

struct PhotoMemberFolderPermissionsPanel: View {
    @Bindable var model: SynologyPhotosModel
    let member: SynologyPhotoSharedMember
    let initial: SynologyPhotoMemberFolderEdit?
    let onDone: (SynologyPhotoMemberFolderEdit?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: SynologyPhotoMemberFolderEdit?
    @State private var expanded: Set<Int> = []
    @State private var search = ""
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("photos.members.folders")).font(.title2.bold())
                    Text(member.recipient.name).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(20)
            Divider()
            Group {
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }
                } else if let draft { folderContent(draft) }
            }.fillsAvailableContentArea(alignment: .topLeading)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.string("photos.members.done")) { onDone(draft?.canSave == true ? draft : nil); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(isLoading || error != nil || draft == nil)
            }.padding(20)
        }.frame(width: 700, height: 570).background(MacGlassSurface(role: .content))
        .task { await load() }
    }

    private func folderContent(_ edit: SynologyPhotoMemberFolderEdit) -> some View {
        let roots = edit.original.filter { root in
            root.depth == 0 && (search.isEmpty || root.folder.name.localizedStandardContains(search) ||
                edit.original.contains { $0.folder.parentID == root.id && $0.folder.name.localizedStandardContains(search) })
        }
        return VStack(spacing: 0) {
            HStack {
                TextField(L10n.string("photos.members.folderSearch"), text: $search).textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(SynologyPhotoFolderMemberRole.allCases, id: \.self) { role in
                        Menu(role.memberFolderTitle) {
                            Button(L10n.string("photos.members.grantAll")) { applyBatch(.init(action: .checkAll, role: role)) }
                            Button(L10n.string("photos.members.revokeAll")) { applyBatch(.init(action: .uncheckAll, role: role)) }
                        }
                    }
                } label: { Text(L10n.string("photos.members.allFolders")) }
                    .disabled(edit.original.isEmpty || !edit.original.allSatisfy(\.hasKnownPermissions))
            }.padding(16)
            if roots.isEmpty {
                ContentUnavailableView(L10n.string(edit.original.isEmpty ? "photos.members.noFolders" : "photos.members.noMatches"),
                    systemImage: "folder", description: Text(L10n.string(edit.original.isEmpty ? "photos.members.noFoldersHint" : "photos.members.searchHint")))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(roots) { root in
                            folderRow(root, edit: edit)
                            if expanded.contains(root.id) || !search.isEmpty {
                                ForEach(edit.original.filter { $0.depth == 1 && $0.folder.parentID == root.id &&
                                    (search.isEmpty || root.folder.name.localizedStandardContains(search) || $0.folder.name.localizedStandardContains(search)) }) { child in
                                    folderRow(child, edit: edit)
                                }
                            }
                        }
                    }.padding(.horizontal, 16)
                }
            }
        }
    }

    private func folderRow(_ folder: SynologyPhotoMemberFolder, edit: SynologyPhotoMemberFolderEdit) -> some View {
        HStack(spacing: 10) {
            if folder.depth == 0 {
                Button {
                    if expanded.contains(folder.id) { expanded.remove(folder.id) } else { expanded.insert(folder.id) }
                } label: { Image(systemName: expanded.contains(folder.id) ? "chevron.down" : "chevron.right") }
                    .buttonStyle(.plain).frame(width: 16)
                    .accessibilityLabel(L10n.string(expanded.contains(folder.id) ? "photos.members.collapse" : "photos.members.expand"))
            } else { Color.clear.frame(width: 32, height: 1) }
            Image(systemName: "folder")
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.folder.name).lineLimit(2)
                if let publicRole = folder.publicRole {
                    Text(L10n.string("photos.members.publicMinimum", publicRole.memberFolderTitle)).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if folder.hasKnownPermissions {
                Picker(L10n.string("photos.members.folderRole"), selection: Binding(get: { edit.expectedRole(for: folder) ?? "" }, set: { role in
                    draft?.setDraftRole(SynologyPhotoFolderMemberRole(rawValue: role), for: folder)
                })) {
                    Text(L10n.string("photos.members.noDirectGrant")).tag("")
                    ForEach(SynologyPhotoFolderMemberRole.allCases, id: \.self) { role in Text(role.memberFolderTitle).tag(role.rawValue) }
                }.labelsHidden().frame(width: 175).disabled(!edit.canEditFolder(folder))
            } else { Text(L10n.string("photos.members.unknownRole")).foregroundStyle(.secondary) }
        }.padding(.vertical, 10)
    }

    private func applyBatch(_ batch: SynologyPhotoMemberFolderEdit.Batch) { draft?.applyDraftBatch(batch) }
    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        if let initial { draft = initial; return }
        do {
            let folders = try await model.sharedSpaceMemberFolderSnapshot(for: member.id); try Task.checkCancellation()
            draft = .init(memberID: member.id, original: folders)
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.members.folderLoadFailed") }
    }
}

extension SynologyPhotoMemberFolderEdit {
    func canEditFolder(_ folder: SynologyPhotoMemberFolder) -> Bool {
        guard folder.hasKnownPermissions else { return false }
        if folder.depth == 0 { return true }
        guard let parent = original.first(where: { $0.id == folder.folder.parentID }), parent.hasKnownPermissions else { return false }
        return parent.publicRole != nil || expectedRole(for: parent) != nil
    }

    mutating func setDraftRole(_ role: SynologyPhotoFolderMemberRole?, for folder: SynologyPhotoMemberFolder) {
        guard canEditFolder(folder) else { return }
        changes.removeAll { $0.folderID == folder.id }
        changes.append(.init(folderID: folder.id, role: role))
        if folder.depth == 0, folder.privacy == "private", role == nil {
            let children = Set(original.filter { $0.folder.parentID == folder.id }.map(\.id))
            changes.removeAll { children.contains($0.folderID) }
        }
    }

    mutating func applyDraftBatch(_ next: Batch) {
        guard original.allSatisfy(\.hasKnownPermissions) else { return }
        // 连续批量操作作用于当前草稿；用最后一批加逐项差异表达，不能丢掉前一批结果。
        let desired = original.map { ($0.id, next.applying(to: expectedRole(for: $0))) }
        batch = next; changes = []
        for (id, value) in desired {
            guard let folder = original.first(where: { $0.id == id }), value != next.applying(to: folder.directRole) else { continue }
            changes.append(.init(folderID: id, role: value.flatMap(SynologyPhotoFolderMemberRole.init(rawValue:))))
        }
        let blocked = Set(original.filter { $0.depth == 1 && !canEditFolder($0) }.map(\.id))
        changes.removeAll { blocked.contains($0.folderID) }
    }
}

private extension SynologyPhotoFolderMemberRole {
    var memberFolderTitle: String {
        switch self {
        case .view: L10n.string("photos.members.folderRole.view")
        case .download: L10n.string("photos.members.folderRole.download")
        case .upload: L10n.string("photos.members.folderRole.upload")
        case .manage: L10n.string("photos.members.folderRole.manage")
        }
    }
}

/// NAS后台任务与本机上传队列分别展示，关闭窗口只停止查看。
struct PhotoBackgroundTasksPanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @State private var tasks: [SynologyPhotoBackgroundTask] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var filter = 0
    @State private var confirmation: SynologyPhotosMutation?
    @State private var showsConfirmation = false
    @State private var errorTask: SynologyPhotoBackgroundTask?

    private var visibleTasks: [SynologyPhotoBackgroundTask] {
        tasks.filter { filter == 0 || (filter == 1 ? [.waiting, .processing, .aborting].contains($0.status) : $0.status == .done) }
    }
    private var busy: Bool { model.isManagingBackgroundTask || model.pendingBackgroundMutationID != nil || model.isDeleting || model.isCheckingDeletion }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.tasks.title")).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            HStack {
                Picker(L10n.string("photos.tasks.filter"), selection: $filter) {
                    Text(L10n.string("photos.tasks.all")).tag(0)
                    Text(L10n.string("photos.tasks.active")).tag(1)
                    Text(L10n.string("photos.tasks.finished")).tag(2)
                }.pickerStyle(.segmented).frame(maxWidth: 330)
                Spacer()
                Button(L10n.string("photos.library.refresh")) { Task { await refresh() } }.disabled(isLoading)
            }.padding(.horizontal, 20).padding(.bottom, 12)
            Divider()
            if isLoading && tasks.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error, tasks.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string("photos.tasks.loadFailed"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button(L10n.string("photos.library.refresh")) { Task { await refresh() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleTasks.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string(tasks.isEmpty ? "photos.tasks.empty" : "photos.tasks.filterEmpty"), systemImage: "list.bullet.rectangle")
                } description: { Text(L10n.string(tasks.isEmpty ? "photos.tasks.emptyHint" : "photos.tasks.filterEmptyHint")) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleTasks) { task in taskRow(task).padding(.vertical, 6) }
            }
            if let error, !tasks.isEmpty { Text(error).font(.callout).foregroundStyle(.secondary).padding(12) }
            if let error = model.backgroundNavigationError { Text(error).font(.callout).foregroundStyle(.secondary).padding(12) }
            if let message = model.backgroundTaskMessage { Text(message).font(.callout).padding(12) }
            Divider()
            HStack {
                Button(L10n.string("photos.tasks.clearCompleted")) {
                    confirmation = .clearBackgroundTasks(tasks.filter(\.canClear)); showsConfirmation = true
                }.disabled(busy || !tasks.contains(where: \.canClear))
                if model.pendingBackgroundMutationID != nil {
                    Button(L10n.string("photos.tasks.checkResult")) { model.reviewBackgroundMutation() }.disabled(model.isManagingBackgroundTask)
                }
                Spacer()
                Button(L10n.string("photos.media.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
        }
        .frame(minWidth: 600, idealWidth: 680, minHeight: 460, idealHeight: 580)
        .fillsAvailableContentArea(alignment: .topLeading)
        .task {
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            } while !Task.isCancelled && model.isModuleEnabled
        }
        .onChange(of: model.backgroundTaskRevision) { _, _ in Task { await refresh() } }
        .sheet(item: $errorTask) { PhotoBackgroundTaskErrorsPanel(model: model, task: $0) }
        .confirmationDialog(L10n.string(isCancelConfirmation ? "photos.tasks.cancelTitle" : "photos.tasks.clearTitle"), isPresented: $showsConfirmation, titleVisibility: .visible) {
            Button(L10n.string(isCancelConfirmation ? "photos.tasks.cancel" : "photos.tasks.clear"), role: .destructive) {
                if let confirmation { model.submitMutation(confirmation) }
                confirmation = nil
            }
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { confirmation = nil }
        } message: {
            Text(L10n.string(isCancelConfirmation ? "photos.tasks.cancelHint" : "photos.tasks.clearHint"))
        }
    }

    private var isCancelConfirmation: Bool {
        if case .cancelBackgroundTask = confirmation { return true }
        return false
    }

    private func taskRow(_ task: SynologyPhotoBackgroundTask) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(L10n.string(task.operation == "copy" ? "photos.tasks.copy" : task.operation == "move" ? "photos.tasks.move" : "photos.tasks.other"), systemImage: task.operation == "move" ? "folder" : "doc.on.doc")
                    .font(.headline)
                Spacer()
                Text(model.formattedPhotoDate(Date(timeIntervalSince1970: task.createdAt), includesTime: true))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(statusTitle(task))
            if task.status == .processing && task.total > 0 {
                ProgressView(value: Double(task.completion), total: Double(task.total))
                    .accessibilityLabel(L10n.string("photos.tasks.progress", task.completion, task.total))
            }
            Text(L10n.string("photos.tasks.counts", task.completion, task.total, task.errors, task.skipped, task.overwritten))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if task.canCancel {
                    Button(L10n.string("photos.tasks.cancel")) { confirmation = .cancelBackgroundTask(task); showsConfirmation = true }.disabled(busy)
                }
                if task.canClear {
                    Button(L10n.string("photos.tasks.clear")) { confirmation = .clearBackgroundTasks([task]); showsConfirmation = true }.disabled(busy)
                }
                if task.errors > 0 {
                    Button(L10n.string("photos.tasks.errors")) { errorTask = task }
                }
                if task.isTransfer, task.status == .done, task.isCancelled || task.errors == 0 || task.errors < task.completion, let space = task.targetSpace,
                   model.spaces.contains(space), (task.targetFolderID ?? 0) > 0 {
                    Button(L10n.string("photos.upload.openFolder")) {
                        Task { if await model.openBackgroundTask(task) { dismiss() } }
                    }.disabled(busy || model.isLoading || model.isOpeningBackgroundDestination)
                }
            }.controlSize(.small)
        }
    }

    private func statusTitle(_ task: SynologyPhotoBackgroundTask) -> String {
        switch task.status {
        case .waiting: L10n.string("photos.tasks.waiting")
        case .processing: L10n.string("photos.tasks.processing")
        case .aborting: L10n.string("photos.tasks.aborting")
        case .unknown: L10n.string("photos.tasks.unknown")
        case .done:
            if task.isCancelled { L10n.string("photos.tasks.cancelled") }
            else if task.errors > 0 { L10n.string(task.successfulCount == 0 ? "photos.tasks.failed" : "photos.tasks.partial") }
            else { L10n.string("photos.tasks.done") }
        }
    }

    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await model.backgroundTasks()
            guard !Task.isCancelled else { return }
            tasks = result; error = nil
        } catch is CancellationError { return }
        catch { if !Task.isCancelled { self.error = L10n.string("photos.tasks.loadFailedHint") } }
    }
}

struct PhotoBackgroundTaskErrorsPanel: View {
    let model: SynologyPhotosModel
    let task: SynologyPhotoBackgroundTask
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SynologyPhotoBackgroundTaskError] = []
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.tasks.errors")).font(.title2.bold())
                Spacer()
                Button(L10n.string("photos.media.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            Divider()
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if failed {
                ContentUnavailableView {
                    Label(L10n.string("photos.tasks.loadFailed"), systemImage: "exclamationmark.triangle")
                } description: { Text(L10n.string("photos.tasks.errorsFailedHint")) } actions: {
                    Button(L10n.string("photos.library.refresh")) { Task { await load() } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string("photos.tasks.noErrors"), systemImage: "checkmark.circle")
                } description: { Text(L10n.string("photos.tasks.noErrorsHint")) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.name ?? kindTitle(entry.kind)).font(.headline)
                        if let path = entry.folderPath { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        Text(reasonTitle(entry.reason))
                    }.padding(.vertical, 6)
                }
            }
        }.frame(minWidth: 520, idealWidth: 600, minHeight: 340, idealHeight: 460)
            .fillsAvailableContentArea(alignment: .topLeading)
            .task { await load() }
    }

    private func kindTitle(_ kind: SynologyPhotoBackgroundTaskError.Kind) -> String {
        switch kind {
        case .item: L10n.string("photos.tasks.errorKind.item")
        case .folder: L10n.string("photos.tasks.errorKind.folder")
        case .unknown: L10n.string("photos.tasks.errorKind.unknown")
        }
    }
    private func reasonTitle(_ reason: SynologyPhotoBackgroundTaskError.Reason) -> String {
        switch reason {
        case .quota: L10n.string("photos.tasks.reason.quota_full")
        case .space: L10n.string("photos.tasks.reason.space_full")
        case .subfolder: L10n.string("photos.tasks.reason.skipped")
        case .missing: L10n.string("photos.tasks.reason.not_existed")
        case .targetMissing: L10n.string("photos.tasks.reason.target_not_existed")
        case .excluded: L10n.string("photos.tasks.reason.excluded_extension")
        case .unknown: L10n.string("photos.tasks.reason.unknown")
        }
    }

    private func load() async {
        loading = true; failed = false
        defer { loading = false }
        do { entries = try await model.backgroundTaskErrors(task) }
        catch is CancellationError { return }
        catch { if !Task.isCancelled { failed = true } }
    }
}
