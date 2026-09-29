import AppKit
import DsmCore
import DsmLocalization
import SwiftUI

enum PhotoManagementKind: String, CaseIterable {
    case rating, description, date, shiftDates, tagsCreate, tagsAdd, tagsRemove, createAlbum, addAlbum, removeAlbum
    case createConditionAlbum, editConditionAlbum, renameAlbum, deleteAlbum, move, copy, upload, sharing, cover, renamePerson, mergePeople
    static let selectionCases: [Self] = [.addAlbum, .createAlbum, .removeAlbum, .cover, .rating, .description, .date, .shiftDates, .tagsCreate, .tagsAdd, .tagsRemove, .move, .copy]
    static let albumCases: [Self] = [.renameAlbum, .sharing, .deleteAlbum]
    var title: String {
        let key: String
        switch self {
        case .rating: key = "photos.manage.rating"
        case .description: key = "photos.manage.description"
        case .date: key = "photos.manage.date"
        case .shiftDates: key = "photos.manage.shiftDates"
        case .tagsCreate: key = "photos.manage.tagsCreate"
        case .tagsAdd: key = "photos.manage.tagsAdd"
        case .tagsRemove: key = "photos.manage.tagsRemove"
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
        case .renamePerson: key = "photos.people.rename"
        case .mergePeople: key = "photos.people.merge"
        }
        return L10n.string(key)
    }
    var feature: SynologyPhotosManagementFeature {
        switch self {
        case .rating, .description, .date, .shiftDates: .metadata
        case .tagsCreate: .tagCreation
        case .tagsAdd, .tagsRemove: .tags
        case .createAlbum, .addAlbum, .removeAlbum, .renameAlbum, .deleteAlbum, .cover: .albums
        case .createConditionAlbum, .editConditionAlbum: .conditionAlbums
        case .move, .copy: .fileTransfer
        case .upload: .upload
        case .sharing: .sharing
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
    var person: SynologyPhotoCollection? = nil
}

/// 表单持有确认目标快照，选择变化不会改变已打开的操作。
struct PhotoManagementPanel: View {
    @Bindable var model: SynologyPhotosModel
    let sheet: PhotoManagementSheet
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var people: [SynologyPhotoCollection] = []
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
    @State private var linkAccess: SynologyPhotoLinkAccess = .disabled
    @State private var originalSharing: SynologyPhotoSharingState?
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
    @State private var condition = SynologyPhotoAlbumCondition()
    @State private var originalCondition: SynologyPhotoAlbumCondition?
    @State private var suggestions: [String: [SynologyPhotoConditionOption]] = [:]
    @State private var conditionField = SynologyPhotoConditionField.keyword
    @State private var conditionSearch = ""
    @State private var suggestionError: String?
    @State private var isSearchingConditions = false
    @State private var conditionCount: Int?
    @State private var isCounting = false
    @State private var countError: String?
    private var isConditionForm: Bool { [.createConditionAlbum, .editConditionAlbum].contains(sheet.kind) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(sheet.kind.title).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel(L10n.string("photos.media.close"))
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                if let album = sheet.album, sheet.kind != .upload { Text(album.name).font(.headline) }
                if let person = sheet.person {
                    HStack {
                        PhotoAlbumCover(model: model, album: person, category: .person).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(person.name.isEmpty ? L10n.string("photos.people.unnamed") : person.name).font(.headline)
                    }
                }
                if !sheet.photos.isEmpty { Text(L10n.string("photos.selection.count", sheet.photos.count)).foregroundStyle(.secondary) }
                if isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { Task { await load() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sheet.kind == .sharing {
                    ScrollView { VStack(alignment: .leading, spacing: 16) { form }.frame(maxWidth: .infinity, alignment: .leading) }
                } else { form }
            }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.delete.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sheet.kind.title, role: sheet.kind == .deleteAlbum ? .destructive : nil) {
                    if sheet.kind == .upload {
                        model.enqueueUploads(uploadFiles, album: sheet.album,
                            folder: includesUploadDirectory && preservesUploadDirectories ? sheet.folder ?? uploadRootFolder : sheet.folder,
                            preserveDirectories: includesUploadDirectory && preservesUploadDirectories)
                    } else if let mutation { model.submitMutation(mutation) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled((sheet.kind == .upload ? (uploadFiles.isEmpty || model.isLoading ||
                    (includesUploadDirectory && preservesUploadDirectories && !model.managementFeatures.contains(.folders))) : mutation == nil) || isLoading || error != nil || model.isManaging || model.pendingMutationID != nil)
            }.padding(20)
        }
        .frame(width: isConditionForm || sheet.kind == .sharing || sheet.kind == .mergePeople ? 680 : 560, height: isConditionForm || sheet.kind == .sharing || sheet.kind == .mergePeople ? 660 : 470)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await load() }
    }

    @ViewBuilder private var form: some View {
        switch sheet.kind {
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
        case .move, .copy:
            folderPicker
            Text(L10n.string("photos.manage.conflictHint")).font(.callout).foregroundStyle(.secondary)
        case .upload:
            Text(L10n.string("photos.upload.fileCount", uploadFiles.count)).font(.headline)
            Text(L10n.string("photos.upload.destination", sheet.album?.name ?? sheet.folder?.name ??
                (includesUploadDirectory && preservesUploadDirectories ? L10n.string("shared.51fcaa8035fc61e2") : L10n.string("photos.library.timeline"))))
                .foregroundStyle(.secondary)
            if includesUploadDirectory {
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
            if !includesUploadDirectory || !preservesUploadDirectories {
                Text(L10n.string("photos.upload.conflictHint")).font(.callout).foregroundStyle(.secondary)
            }
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
            if originalSharing?.hasExpiration == true {
                Label(L10n.string("photos.sharing.expirationSet"), systemImage: "calendar").foregroundStyle(.secondary)
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
        guard model.managementFeatures.contains(sheet.kind.feature) else { return nil }
        let photos = sheet.photos
        switch sheet.kind {
        case .renamePerson:
            guard let person = sheet.person, text != person.name else { return nil }
            return .renamePerson(person, name: text)
        case .mergePeople:
            guard let target = sheet.person, !mergedPersonIDs.isEmpty else { return nil }
            return .mergePeople(target: target, sources: people.filter { mergedPersonIDs.contains($0.id) }, name: text)
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
            return name.isEmpty ? nil : .createTag(name: name, photos: photos)
        case .tagsAdd: return tags.isEmpty ? nil : .addTags(photos, ids: tags.sorted())
        case .tagsRemove: return tags.isEmpty ? nil : .removeTags(photos, ids: tags.sorted())
        case .createAlbum: return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .createAlbum(name: text, photos: photos)
        case .renameAlbum: return sheet.album.flatMap { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : .renameAlbum(id: $0.id, name: text) }
        case .deleteAlbum: return sheet.album.map { .deleteAlbum(id: $0.id) }
        case .addAlbum: return albumID.map { .addToAlbum(id: $0, photos: photos) }
        case .removeAlbum: return sheet.album.map { .removeFromAlbum(id: $0.id, photos: photos) }
        case .move: return folderPath.last.flatMap { folder in photos.contains { $0.folderID == folder.id } ? nil : .move(photos, folderID: folder.id) }
        case .copy: return folderPath.last.flatMap { folder in photos.contains { $0.folderID == folder.id } ? nil : .copy(photos, folderID: folder.id) }
        case .upload: return nil
        case .cover:
            guard photos.count == 1, let photo = photos.first, let album = sheet.album else { return nil }
            return .setAlbumCover(id: album.id, photo: photo)
        case .sharing:
            guard let originalSharing else { return nil }
            let changedMembers = originalSharing.members.map { $0 != sharingMembers } ?? false
            guard originalSharing.access != linkAccess || changedMembers else { return nil }
            return sheet.album.map { .shareAlbum(id: $0.id, access: linkAccess, original: originalSharing, members: changedMembers ? sharingMembers : nil) }
        }
    }

    private func load() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            switch sheet.kind {
            case .renamePerson: text = sheet.person?.name ?? ""
            case .mergePeople:
                text = sheet.person?.name ?? ""
                people = try await model.managementPeople().filter { $0.id != sheet.person?.id }
            case .createConditionAlbum, .editConditionAlbum:
                if let album = sheet.album {
                    condition = try await model.albumCondition(id: album.id)
                    originalCondition = condition
                }
                let (root, children) = try await model.managementFolders(parentID: nil)
                folderPath = [root]; folders = children
                await searchConditions()
            case .sharing:
                guard let album = sheet.album else { throw CocoaError(.fileReadUnknown) }
                let state = try await model.albumSharing(id: album.id)
                originalSharing = state; linkAccess = state.access; sharingMembers = state.members ?? []
                await loadSharingRecipients()
            case .addAlbum: albums = try await model.managementAlbums().filter { !$0.isConditional }
            case .move, .copy:
                let (root, children) = try await model.managementFolders(parentID: nil)
                folderPath = [root]; folders = children
            case .tagsAdd, .tagsRemove: await model.loadFilterOptions(); error = model.filterOptionsErrorMessage
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
                if prepared.includesDirectory && sheet.folder == nil {
                    uploadRootFolder = try await model.managementFolders(parentID: nil).0
                }
            default: break
            }
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") }
    }

    private var conditionForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if sheet.kind == .createConditionAlbum {
                    TextField(L10n.string("photos.manage.albumName"), text: $text).textFieldStyle(.roundedBorder)
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
    private func searchConditions() async {
        guard !isSearchingConditions else { return }
        isSearchingConditions = true; suggestionError = nil
        defer { isSearchingConditions = false }
        do { suggestions = try await model.conditionSuggestions(keyword: conditionSearch) }
        catch { suggestionError = L10n.string("photos.condition.searchFailed") }
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
        isLoading = true; error = nil
        defer { isLoading = false }
        var path = folderPath
        if goBack { path.removeLast() } else if let folder { path.append(folder) }
        do {
            let (_, children) = try await model.managementFolders(parentID: path.last?.id)
            folderPath = path; folders = children
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed") }
    }
}

struct PhotoUploadQueuePanel: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dismiss) private var dismiss

    private func uploadStateTitle(_ state: PhotoUploadEntry.State) -> String {
        switch state {
        case .queued: L10n.string("photos.upload.state.queued")
        case .uploading: L10n.string("photos.upload.state.uploading")
        case .preparingFolders: L10n.string("photos.upload.state.preparingFolders")
        case .addingToAlbum: L10n.string("photos.upload.state.addingToAlbum")
        case .completed: L10n.string("photos.upload.state.completed")
        case .failed: L10n.string("photos.upload.state.failed")
        case .pendingReview: L10n.string("photos.upload.state.pendingReview")
        case .cancelled: L10n.string("photos.upload.state.cancelled")
        }
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
                        Text(L10n.string("photos.upload.destination", entry.album?.name ?? entry.folder?.name ?? L10n.string("photos.library.timeline")))
                            .font(.caption).foregroundStyle(.secondary)
                        if entry.state == .uploading { ProgressView(value: entry.progress) }
                        if entry.state == .addingToAlbum || entry.state == .preparingFolders { ProgressView().controlSize(.small) }
                        if let error = entry.error { Text(error).font(.callout).foregroundStyle(.red) }
                        if [.failed, .cancelled].contains(entry.state) {
                            Button(L10n.string(entry.uploadedPhoto == nil ? "photos.retry" : "photos.upload.retryAlbum")) { model.retryUpload(entry.id) }
                                .disabled(model.isManaging || model.pendingMutationID != nil)
                        }
                        if entry.state == .pendingReview {
                            Button(L10n.string("photos.selection.retryReview")) { model.reviewPendingMutation() }.disabled(model.isManaging)
                        }
                    }.padding(.vertical, 8)
                }
            }
            Divider()
            HStack {
                Button(L10n.string("photos.upload.clearFinished")) { model.clearFinishedUploads() }
                Spacer()
                if model.isUploading {
                    Button(L10n.string("photos.upload.stopAfterCurrent")) { model.stopUploadQueue() }.disabled(model.stopsAfterCurrentUpload)
                }
                Button(L10n.string("photos.media.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
        }
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
