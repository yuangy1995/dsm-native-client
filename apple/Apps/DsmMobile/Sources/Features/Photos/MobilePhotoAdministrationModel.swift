import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

/// 管理员表单与目录子页均为本机会话草稿；最终保存才改变 NAS。
@MainActor
@Observable
final class MobilePhotoAdministrationModel {
    enum Page: String, CaseIterable {
        case shared, global, members
        var title: String {
            switch self {
            case .shared: L10n.string("photos.sharedSettings.title")
            case .global: L10n.string("photos.global.title")
            case .members: L10n.string("photos.members.title")
            }
        }
    }
    struct Draft: Identifiable { let id = UUID(); let page: Page }
    struct FolderTarget: Identifiable { let id = UUID(); let member: SynologyPhotoSharedMember }
    private(set) var draft: Draft?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var originalShared: SynologyPhotoSharedSpaceSettings?
    private(set) var originalGlobal: SynologyPhotoGlobalSettings?
    private(set) var originalMembers: SynologyPhotoSharedMembers?
    private(set) var cache: SynologyPhotoConversionCache?
    private(set) var cacheLoading = false
    private(set) var cacheError: String?
    private(set) var candidates: [SynologyPhotoShareRecipient] = []
    private(set) var candidatesLoading = false
    private(set) var candidatesError: String?
    private(set) var members: [SynologyPhotoSharedMember] = []
    private(set) var folderEdits: [SynologyPhotoShareRecipient.ID: SynologyPhotoMemberFolderEdit] = [:]
    private(set) var folderTarget: FolderTarget?
    private(set) var folderDraft: SynologyPhotoMemberFolderEdit?
    private(set) var folderLoading = false
    private(set) var folderError: String?
    var sharedEnabled: Set<SynologyPhotoSharedSpaceSettings.Kind> = []
    var globalEnabled: Set<SynologyPhotoGlobalSettings.Kind> = []
    var excluded: Set<String>?
    var search = ""
    var candidateSearch = ""
    var folderSearch = ""
    var showsCandidates = false
    var showsConfirmation = false
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var cacheTask: Task<Void, Never>?
    @ObservationIgnored private var candidatesTask: Task<Void, Never>?
    @ObservationIgnored private var folderTask: Task<Void, Never>?
    @ObservationIgnored private var confirmation: SynologyPhotosMutation?

    init(model: SynologyPhotosModel) { self.model = model }
    func canOpen(_ page: Page) -> Bool {
        guard model.isModuleEnabled else { return false }
        switch page {
        case .shared: return model.managementFeatures.contains(.sharedSpaceSettings)
        case .global: return !model.managementFeatures.isDisjoint(with: [.globalSettings, .conversionCache])
        case .members: return model.managementFeatures.contains(.sharedMembers)
        }
    }
    private func isCurrent(_ draft: Draft) -> Bool { self.draft?.id == draft.id && canOpen(draft.page) }
    func begin(_ page: Page) {
        guard canOpen(page) else { return }
        cancel(); draft = .init(page: page); model.setAutomaticPreviewSettingsVisible(true); load()
    }
    func load() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        isLoading = true; error = nil; originalShared = nil; originalGlobal = nil; originalMembers = nil
        cancelConfirmation(); cancelFolders()
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false; self.task = nil } }
            do {
                switch draft.page {
                case .shared:
                    let value = try await self.model.sharedSpaceSettings()
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.originalShared = value; self.sharedEnabled = value.enabled
                case .global:
                    if self.model.managementFeatures.contains(.globalSettings) {
                        let value = try await self.model.globalSettings()
                        guard !Task.isCancelled, self.isCurrent(draft) else { return }
                        self.originalGlobal = value; self.globalEnabled = value.enabled; self.excluded = value.excludedExtensions
                    }
                    self.loadCache()
                case .members:
                    let value = try await self.model.sharedSpaceMembers()
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.originalMembers = value; self.members = value.members; self.folderEdits = [:]
                    if value.isEnabled { self.loadCandidates() }
                }
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) {
                    self.error = L10n.string(draft.page == .members ? "photos.members.loadFailed" : "mobile.photos.preferences.loadFailed")
                }
            }
        }
    }
    func loadCache() {
        guard let draft, isCurrent(draft), draft.page == .global, !cacheLoading,
              model.managementFeatures.contains(.conversionCache), !showsConfirmation else { return }
        cacheLoading = true; cacheError = nil
        cacheTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.cacheLoading = false; self.cacheTask = nil } }
            do {
                let value = try await self.model.conversionCache()
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                self.cache = value
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.cache = nil; self.cacheError = L10n.string("photos.global.cacheFailed") }
            }
        }
    }
    func loadCandidates() {
        guard let draft, isCurrent(draft), draft.page == .members, !candidatesLoading, originalMembers?.isEnabled == true else { return }
        candidatesLoading = true; candidatesError = nil
        candidatesTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.candidatesLoading = false; self.candidatesTask = nil } }
            do {
                let value = try await self.model.sharedSpaceMemberCandidates()
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                self.candidates = value
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.candidates = []; self.candidatesError = L10n.string("photos.members.loadFailed") }
            }
        }
    }
    var editable: Bool {
        guard let draft else { return false }
        return isCurrent(draft) && !isLoading && error == nil && model.canStartManagementMutation
    }
    var filteredMembers: [SynologyPhotoSharedMember] { members.filter { search.isEmpty || $0.recipient.name.localizedStandardContains(search) } }
    var availableCandidates: [SynologyPhotoShareRecipient] {
        candidates.filter { value in !members.contains(where: { $0.id == value.id }) &&
            !(value.id.type == "group" && value.name == "administrators") &&
            (candidateSearch.isEmpty || value.name.localizedStandardContains(candidateSearch)) }
    }
    var mutation: SynologyPhotosMutation? {
        guard editable, let draft, folderTarget == nil else { return nil }
        switch draft.page {
        case .shared:
            guard let originalShared, originalShared.canSave(sharedEnabled) else { return nil }
            return .setSharedSpaceSettings(original: originalShared, enabled: sharedEnabled)
        case .global:
            guard let originalGlobal, originalGlobal.canSave(enabled: globalEnabled, excludedExtensions: excluded) else { return nil }
            return .setGlobalSettings(original: originalGlobal, enabled: globalEnabled, excludedExtensions: excluded)
        case .members:
            guard let originalMembers else { return nil }
            let edits = members.compactMap { folderEdits[$0.id] }.filter(\.canSave)
            guard originalMembers.canSave(members, candidates: candidates, allowsUnchanged: !edits.isEmpty) else { return nil }
            return .setSharedMembers(original: originalMembers, members: members, folderEdits: edits)
        }
    }
    @discardableResult func save() -> Bool {
        guard let mutation else { return false }
        if case .setSharedSpaceSettings(let original, let target) = mutation,
           original.enabled.contains(.publicRoot) == target.contains(.publicRoot) { return submit(mutation) }
        if case .setGlobalSettings = mutation, globalConfirmationKeys(mutation).isEmpty { return submit(mutation) }
        confirmation = mutation; showsConfirmation = true; return false
    }
    func confirmSharedSwitch() {
        guard editable, let originalShared, originalShared.canSetEnabled(!originalShared.isEnabled) else { return }
        confirmation = .setSharedSpaceEnabled(original: originalShared, enabled: !originalShared.isEnabled); showsConfirmation = true
    }
    func confirmClearCache() {
        guard editable, !cacheLoading, cacheError == nil, let cache, cache.canClear else { return }
        confirmation = .clearConversionCache(cache); showsConfirmation = true
    }
    @discardableResult func confirmSave() -> Bool {
        guard editable, let confirmation else { return false }
        let current: Bool
        switch confirmation {
        case .setSharedSpaceEnabled(let original, let enabled): current = originalShared == original && original.canSetEnabled(enabled)
        case .clearConversionCache(let original): current = cache == original && original.canClear && !cacheLoading && cacheError == nil
        default: current = mutation == confirmation
        }
        guard current else { cancelConfirmation(); error = L10n.string("mobile.photos.album.stale"); return false }
        return submit(confirmation)
    }
    private func submit(_ command: SynologyPhotosMutation) -> Bool {
        model.submitMutation(command)
        guard model.isManaging else { return false }
        cancel(); return true
    }
    var confirmationTitle: String {
        L10n.string(draft?.page == .members ? "photos.members.confirmTitle" : draft?.page == .shared ? "photos.sharedSettings.confirmTitle" : "photos.global.confirmTitle")
    }
    var confirmationAction: String {
        if case .setSharedSpaceEnabled(_, let enabled) = confirmation { return L10n.string(enabled ? "photos.sharedSettings.enable" : "photos.sharedSettings.disable") }
        return L10n.string(confirmation?.feature == .conversionCache ? "photos.global.clearCache" : "mobile.photos.edit.save")
    }
    var confirmationMessage: String {
        switch confirmation {
        case .setSharedSpaceEnabled(_, let enabled): return L10n.string(enabled ? "photos.sharedSettings.enableConfirm" : "photos.sharedSettings.disableConfirm")
        case .setSharedSpaceSettings(_, let enabled): return L10n.string(enabled.contains(.publicRoot) ? "photos.sharedSettings.publicConfirm" : "photos.sharedSettings.privateConfirm")
        case .clearConversionCache: return L10n.string("photos.global.clearConfirm")
        case .setSharedMembers: return L10n.string("photos.members.confirmMessage")
        case .setGlobalSettings: return globalConfirmationKeys(confirmation).map { L10n.string($0) }.joined(separator: "\n\n")
        default: return ""
        }
    }
    private func globalConfirmationKeys(_ mutation: SynologyPhotosMutation?) -> [String] {
        guard case .setGlobalSettings(let original, let enabled, let excluded) = mutation else { return [] }
        var keys: [String] = []
        let target = original.applying(enabled: enabled, excludedExtensions: excluded)
        if !original.enabled.subtracting(enabled).intersection([.person, .concept, .similar]).isEmpty ||
           original.personalRecognition != target.personalRecognition || original.sharedRecognition != target.sharedRecognition { keys.append("photos.global.recognitionConfirm") }
        if original.values[.userSharing] == true, !enabled.contains(.userSharing) { keys.append("photos.global.sharingConfirm") }
        if original.values[.guestInfo] == false, enabled.contains(.guestInfo) { keys.append("photos.global.guestConfirm") }
        if original.excludedExtensions != excluded { keys.append("photos.global.excludedConfirm") }
        if original.values[.originalJPEG] == true, !enabled.contains(.originalJPEG) { keys.append("photos.global.clearConfirm") }
        return keys
    }
    func changeRole(_ member: SynologyPhotoSharedMember, to role: SynologyPhotoSharedMember.Role) {
        guard editable, let index = members.firstIndex(where: { $0 == member }), member.canEdit else { return }
        let changed = member.changingRole(to: role)
        if role == .entry { beginFolders(changed) }
        else { members[index] = changed; folderEdits[member.id] = nil }
    }
    func setBackup(_ member: SynologyPhotoSharedMember, enabled: Bool) {
        guard editable, let index = members.firstIndex(where: { $0.id == member.id }), members[index].canEdit, members[index].role == "entry" else { return }
        members[index].autoBackup = enabled
    }
    func setAllBackup(_ enabled: Bool) { for member in members { setBackup(member, enabled: enabled) } }
    func remove(_ member: SynologyPhotoSharedMember) {
        guard editable, member.canEdit, members.contains(member) else { return }
        members.removeAll { $0.id == member.id }; folderEdits[member.id] = nil
    }
    func add(_ candidate: SynologyPhotoShareRecipient, role: SynologyPhotoSharedMember.Role) {
        guard editable, availableCandidates.contains(candidate) else { return }
        let member = SynologyPhotoSharedMember(recipient: candidate, role: role)
        showsCandidates = false
        if role == .entry { beginFolders(member) } else { members.append(member) }
    }
    func beginFolders(_ member: SynologyPhotoSharedMember) {
        guard editable, member.canEdit, member.role == "entry", members.contains(where: { $0.id == member.id }) || candidates.contains(member.recipient) else { return }
        cancelFolders(); folderTarget = .init(member: member); loadFolders()
    }
    func loadFolders() {
        guard let draft, let target = folderTarget, isCurrent(draft), !folderLoading else { return }
        if let value = folderEdits[target.member.id] { folderDraft = value; return }
        folderLoading = true; folderError = nil
        folderTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.folderTarget?.id == target.id { self.folderLoading = false; self.folderTask = nil } }
            do {
                let value = try await self.model.sharedSpaceMemberFolderSnapshot(for: target.member.id)
                guard !Task.isCancelled, self.isCurrent(draft), self.folderTarget?.id == target.id else { return }
                self.folderDraft = .init(memberID: target.member.id, original: value)
            } catch {
                if !Task.isCancelled, self.isCurrent(draft), self.folderTarget?.id == target.id { self.folderError = L10n.string("photos.members.folderLoadFailed") }
            }
        }
    }
    func setFolderRole(_ role: SynologyPhotoFolderMemberRole?, for folder: SynologyPhotoMemberFolder) {
        guard editable, !folderLoading, folderError == nil, folderDraft?.original.contains(folder) == true else { return }
        folderDraft?.setDraftRole(role, for: folder)
    }
    func applyFolderBatch(_ batch: SynologyPhotoMemberFolderEdit.Batch) {
        guard editable, !folderLoading, folderError == nil else { return }
        folderDraft?.applyDraftBatch(batch)
    }
    @discardableResult func finishFolders() -> Bool {
        guard editable, !folderLoading, folderError == nil, let target = folderTarget, let value = folderDraft else { return false }
        if let index = members.firstIndex(where: { $0.id == target.member.id }) { members[index] = target.member }
        else { members.append(target.member) }
        folderEdits[target.member.id] = value.canSave ? value : nil; cancelFolders(); return true
    }
    func cancelFolders() {
        folderTask?.cancel(); folderTask = nil; folderTarget = nil; folderDraft = nil
        folderLoading = false; folderError = nil; folderSearch = ""
    }
    func cancelConfirmation() { confirmation = nil; showsConfirmation = false }
    func cancel() {
        task?.cancel(); task = nil; cacheTask?.cancel(); cacheTask = nil; candidatesTask?.cancel(); candidatesTask = nil
        cancelFolders(); cancelConfirmation(); draft = nil; isLoading = false; error = nil
        originalShared = nil; originalGlobal = nil; originalMembers = nil; cache = nil; cacheLoading = false; cacheError = nil
        candidates = []; candidatesLoading = false; candidatesError = nil; members = []; folderEdits = [:]
        sharedEnabled = []; globalEnabled = []; excluded = nil; search = ""; candidateSearch = ""; showsCandidates = false
        model.setAutomaticPreviewSettingsVisible(false)
    }
}
