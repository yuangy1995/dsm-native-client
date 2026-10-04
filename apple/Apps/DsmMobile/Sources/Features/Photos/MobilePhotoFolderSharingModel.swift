import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoFolderSharingModel {
    struct Draft: Identifiable {
        let id = UUID()
        let folder: SynologyPhotoCollection
    }
    private(set) var draft: Draft?
    private(set) var original: SynologyPhotoFolderSharingState?
    private(set) var isLoading = false
    private(set) var loadingRecipients = false
    private(set) var error: String?
    private(set) var recipientError: String?
    private(set) var supportsEditing = false
    private(set) var recipients: [SynologyPhotoShareRecipient] = []
    var access: SynologyPhotoFolderSharingState.Access = .management
    var password = PhotoSharingPasswordDraft()
    var members: [SynologyPhotoShareGrant] = []
    var appliesToSubfolders = false
    var search = ""
    var showsConfirmation = false
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var recipientsTask: Task<Void, Never>?
    @ObservationIgnored private var confirmation: SynologyPhotosMutation?

    init(model: SynologyPhotosModel) { self.model = model }
    func canOpen(_ folder: SynologyPhotoCollection) -> Bool {
        model.isModuleEnabled && model.section == .folders && model.selectedSpace == .shared &&
            model.canInspectFolderSharing(folder) && (model.collections.contains(folder) || model.folderHistory.last == folder)
    }
    func begin(_ folder: SynologyPhotoCollection) {
        guard canOpen(folder) else { return }
        cancel(); draft = .init(folder: folder); load()
    }
    private func isCurrent(_ draft: Draft) -> Bool { self.draft?.id == draft.id && canOpen(draft.folder) }
    func load() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        isLoading = true; original = nil; error = nil; password = .init(); supportsEditing = false
        cancelConfirmation()
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false; self.loadTask = nil } }
            do {
                let value = try await self.model.folderSharing(draft.folder)
                let supported = await self.model.supportsManagement(.folderSharing, in: .shared)
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                self.original = value; self.access = value.access; self.members = value.members ?? []
                self.appliesToSubfolders = value.appliesToSubfolders; self.supportsEditing = supported
                self.recipients = []; self.search = ""; self.recipientError = nil
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.error = L10n.string("photos.folderSharing.readFailed") }
            }
        }
    }
    var editable: Bool {
        guard let draft else { return false }
        return isCurrent(draft) && supportsEditing && original?.inheritsManagementOnly == false &&
            !isLoading && error == nil && model.canStartManagementMutation
    }
    let roles = ["view", "download", "upload", "manage"]
    var availableRecipients: [SynologyPhotoShareRecipient] {
        recipients.filter { candidate in !members.contains { $0.id == candidate.id } &&
            (search.isEmpty || candidate.name.localizedCaseInsensitiveContains(search)) }
    }
    func add(_ recipient: SynologyPhotoShareRecipient) {
        guard editable, availableRecipients.contains(recipient) else { return }
        members.append(.init(recipient: recipient, role: "view"))
    }
    func loadRecipients() {
        guard let draft, isCurrent(draft), original?.members != nil, supportsEditing, !loadingRecipients else { return }
        loadingRecipients = true; recipientError = nil
        recipientsTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.loadingRecipients = false; self.recipientsTask = nil } }
            do {
                let values = try await self.model.folderSharingRecipients()
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                self.recipients = values
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.recipientError = L10n.string("photos.sharing.membersLoadFailed") }
            }
        }
    }
    var mutation: SynologyPhotosMutation? {
        guard editable, let original, password.isValid,
              original.depth == 1 || appliesToSubfolders == original.appliesToSubfolders else { return nil }
        let oldMembers = original.members ?? []
        guard Set(members.map(\.id)).count == members.count,
              members.allSatisfy({ member in
                  if let old = oldMembers.first(where: { $0.id == member.id }) { return old.role == member.role || roles.contains(member.role) }
                  return roles.contains(member.role) && recipients.contains { $0.id == member.id }
              }) else { return nil }
        let passwordChange = password.change(hasPassword: original.hasPassword)
        guard access != original.access || original.members.map({ $0 != members }) == true || passwordChange != nil ||
                appliesToSubfolders != original.appliesToSubfolders || appliesToSubfolders else { return nil }
        return .setFolderSharing(original: original, access: access, members: original.members == nil ? nil : members,
            password: passwordChange, appliesToSubfolders: appliesToSubfolders)
    }
    var needsConfirmation: Bool {
        guard let original else { return false }
        if appliesToSubfolders { return true }
        let rank: [SynologyPhotoFolderSharingState.Access: Int] = [.management: 0, .invited: 1, .view: 2, .download: 3]
        if (rank[access] ?? 0) > (rank[original.access] ?? 0) || password.choice == .remove && original.hasPassword != false { return true }
        let roles = ["view": 1, "download": 2, "upload": 3, "manage": 4]
        return members.contains { member in
            guard let old = original.members?.first(where: { $0.id == member.id }) else { return true }
            return (roles[member.role] ?? 0) > (roles[old.role] ?? 0)
        }
    }
    @discardableResult func save() -> Bool {
        guard let command = mutation else { return false }
        if needsConfirmation { confirmation = command; showsConfirmation = true; return false }
        return submit(command)
    }
    @discardableResult func confirmSave() -> Bool {
        guard let confirmation, mutation == confirmation else { cancelConfirmation(); error = L10n.string("mobile.photos.album.stale"); return false }
        return submit(confirmation)
    }
    private func submit(_ command: SynologyPhotosMutation) -> Bool {
        model.submitMutation(command)
        guard model.isManaging else { return false }
        cancel(); return true
    }
    func cancelConfirmation() { confirmation = nil; showsConfirmation = false }
    func cancel() {
        loadTask?.cancel(); loadTask = nil; recipientsTask?.cancel(); recipientsTask = nil
        draft = nil; original = nil; isLoading = false; loadingRecipients = false; supportsEditing = false
        error = nil; recipientError = nil; recipients = []; members = []; password = .init(); search = ""
        access = .management; appliesToSubfolders = false; cancelConfirmation()
    }
}
