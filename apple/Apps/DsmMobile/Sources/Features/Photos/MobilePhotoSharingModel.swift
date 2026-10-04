import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoSharingModel {
    struct Draft: Identifiable {
        let id = UUID()
        let album: SynologyPhotoCollection
        let entry: SynologyPhotoSharedEntry?
        let section: SynologyPhotosSection
        let space: SynologyPhotoSpace
        var prepared = false
    }
    enum Risk: String, CaseIterable {
        case publicView, publicDownload, passwordRemoved, memberAccess
        var message: String {
            switch self {
            case .publicView: L10n.string("mobile.photos.sharing.risk.publicView")
            case .publicDownload: L10n.string("mobile.photos.sharing.risk.publicDownload")
            case .passwordRemoved: L10n.string("mobile.photos.sharing.risk.passwordRemoved")
            case .memberAccess: L10n.string("mobile.photos.sharing.risk.memberAccess")
            }
        }
    }
    private(set) var draft: Draft?
    private(set) var original: SynologyPhotoSharingState?
    private(set) var isLoading = false
    private(set) var loadingRecipients = false
    private(set) var error: String?
    private(set) var recipientError: String?
    private(set) var recipients: [SynologyPhotoShareRecipient] = []
    private(set) var confirmationRisks: [Risk] = []
    var showsConfirmation = false
    var showsTemporaryStop = false
    var access: SynologyPhotoLinkAccess = .disabled
    var members: [SynologyPhotoShareGrant] = []
    var expiration = PhotoSharingExpirationDraft()
    var password = PhotoSharingPasswordDraft()
    var search = ""
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var recipientsTask: Task<Void, Never>?
    @ObservationIgnored private var confirmedMutation: SynologyPhotosMutation?

    init(model: SynologyPhotosModel) { self.model = model }

    func canOpen(entry: SynologyPhotoSharedEntry? = nil) -> Bool {
        guard model.canStartManagementMutation, model.managementFeatures.contains(.sharing), model.spaces.contains(.personal) else { return false }
        if let entry { return model.sharingManagementTarget(for: entry) != nil }
        return model.selectedAlbum != nil && model.selectedAlbumAccess?.albumID == model.selectedAlbum?.id && model.selectedAlbumAccess?.isOwner == true
    }

    func begin(entry: SynologyPhotoSharedEntry? = nil) {
        guard canOpen(entry: entry), let album = entry.flatMap({ model.sharingManagementTarget(for: $0) }) ?? model.selectedAlbum else { return }
        cancel()
        draft = .init(album: album, entry: entry, section: model.section, space: model.selectedSpace)
        load()
    }

    func beginPrepared() {
        guard model.canStartManagementMutation, model.managementFeatures.contains(.sharing), let album = model.preparedTemporaryAlbum else { return }
        cancel()
        draft = .init(album: album, entry: nil, section: model.section, space: model.selectedSpace, prepared: true)
        load()
    }

    private func isCurrent(_ value: Draft) -> Bool {
        guard draft?.id == value.id, model.isModuleEnabled else { return false }
        if value.prepared { return model.preparedTemporaryAlbum?.id == value.album.id }
        guard model.section == value.section, model.selectedSpace == value.space else { return false }
        if let entry = value.entry { return model.sharedEntries.contains(entry) && model.sharingManagementTarget(for: entry) == value.album }
        return model.selectedAlbum == value.album && model.selectedAlbumAccess?.isOwner == true
    }

    func load() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        error = nil; original = nil; password = .init(); confirmationRisks = []; confirmedMutation = nil
        isLoading = true
        loadingTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false; self.loadingTask = nil } }
            guard !Task.isCancelled, self.isCurrent(draft) else { return }
            do {
                let value = try await self.model.albumSharing(id: draft.album.id)
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                self.original = value; self.access = value.access; self.members = value.members ?? []
                self.expiration = .init(expiration: value.expiration)
                self.loadRecipients()
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.error = L10n.string("mobile.photos.sharing.loadFailed") }
            }
        }
    }

    func loadRecipients() {
        guard let draft, isCurrent(draft), original?.members != nil, !loadingRecipients else { return }
        loadingRecipients = true; recipientError = nil
        recipientsTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.loadingRecipients = false; self.recipientsTask = nil } }
            guard !Task.isCancelled, self.isCurrent(draft) else { return }
            do {
                let values = try await self.model.sharingRecipients()
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                self.recipients = values
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.recipientError = L10n.string("photos.sharing.membersLoadFailed") }
            }
        }
    }

    var roles: [String] { draft?.album.isConditional == true ? ["view", "download"] : ["view", "download", "upload"] }
    var availableRecipients: [SynologyPhotoShareRecipient] {
        recipients.filter { candidate in !members.contains { $0.id == candidate.id } && (search.isEmpty || candidate.name.localizedCaseInsensitiveContains(search)) }
    }
    func add(_ recipient: SynologyPhotoShareRecipient) {
        guard availableRecipients.contains(recipient) else { return }
        members.append(.init(recipient: recipient, role: "view"))
    }

    var mutation: SynologyPhotosMutation? {
        guard let draft, isCurrent(draft), let original, model.canStartManagementMutation,
              draft.prepared || canOpen(entry: draft.entry), !isLoading, error == nil, expiration.isValid, password.isValid else { return nil }
        let oldMembers = original.members ?? []
        guard Set(members.map(\.id)).count == members.count,
              members.allSatisfy({ member in
                  if let old = oldMembers.first(where: { $0.id == member.id }) { return old.role == member.role || roles.contains(member.role) }
                  return roles.contains(member.role) && recipients.contains { $0.id == member.id }
              }) else { return nil }
        let changedMembers = original.members.map { $0 != members } ?? false
        let changedExpiration = expiration.change(from: original.expiration)
        let changedPassword = password.change(hasPassword: original.hasPassword)
        guard original.isTemporary == true || access != original.access || changedMembers || changedExpiration != nil || changedPassword != nil else { return nil }
        return .shareAlbum(id: draft.album.id, access: access, original: original, members: changedMembers ? members : nil,
                           expiration: changedExpiration, password: changedPassword)
    }

    var risks: [Risk] {
        guard let original else { return [] }
        var values: [Risk] = []
        if access == .view, [.disabled, .invited].contains(original.access) { values.append(.publicView) }
        if access == .download, original.access != .download { values.append(.publicDownload) }
        if password.choice == .remove, original.hasPassword != false { values.append(.passwordRemoved) }
        let rank = ["view": 1, "download": 2, "upload": 3]
        if members.contains(where: { member in
            guard let old = original.members?.first(where: { $0.id == member.id }) else { return true }
            return (rank[member.role] ?? 0) > (rank[old.role] ?? 0)
        }) { values.append(.memberAccess) }
        return values
    }

    @discardableResult func requestSave() -> Bool {
        guard let command = mutation else { return false }
        if original?.isTemporary == true, access == .disabled { showsTemporaryStop = true; return false }
        if !risks.isEmpty { confirmedMutation = command; confirmationRisks = risks; showsConfirmation = true; return false }
        return submit(command)
    }
    @discardableResult func confirmSave() -> Bool {
        guard let command = confirmedMutation, mutation == command else { cancelConfirmation(); error = L10n.string("mobile.photos.album.stale"); return false }
        return submit(command)
    }
    func cancelConfirmation() { confirmationRisks = []; confirmedMutation = nil; showsConfirmation = false }
    @discardableResult func stopTemporary(keepCopy: Bool) -> Bool {
        guard let draft, isCurrent(draft), original?.isTemporary == true,
              model.stopTemporarySharing(draft.album, keepCopy: keepCopy) else { return false }
        cancel(); return true
    }
    @discardableResult func cancelEditing() -> Bool {
        if let draft, draft.prepared, isCurrent(draft), !model.stopTemporarySharing(draft.album, keepCopy: false) { return false }
        cancel(); return true
    }
    private func submit(_ command: SynologyPhotosMutation) -> Bool {
        model.submitMutation(command)
        guard model.isManaging else { return false }
        cancel(); return true
    }
    func cancel() {
        loadingTask?.cancel(); loadingTask = nil; recipientsTask?.cancel(); recipientsTask = nil
        draft = nil; original = nil; isLoading = false; loadingRecipients = false; error = nil; recipientError = nil
        recipients = []; members = []; access = .disabled; expiration = .init(); password = .init(); search = ""
        cancelConfirmation(); showsTemporaryStop = false
    }
}
