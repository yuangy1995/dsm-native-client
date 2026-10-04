import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoConditionModel {
    struct Draft: Identifiable {
        let id = UUID()
        let editing: Bool
        let album: SynologyPhotoCollection?
        let section: SynologyPhotosSection
        let space: SynologyPhotoSpace
    }
    private(set) var draft: Draft?
    private(set) var original: SynologyPhotoAlbumCondition?
    var name = ""
    var condition = SynologyPhotoAlbumCondition() {
        didSet { countTask?.cancel(); countGeneration = UUID(); isCounting = false; count = nil; countError = nil }
    }
    var field: SynologyPhotoConditionField = .keyword
    var search = "" {
        didSet { if search != oldValue { clearSuggestions() } }
    }
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var suggestions: [String: [SynologyPhotoConditionOption]] = [:]
    private(set) var isSearching = false
    private(set) var suggestionError: String?
    private(set) var isCounting = false
    private(set) var count: Int?
    private(set) var countError: String?
    private(set) var folders: [SynologyPhotoCollection] = []
    private(set) var folderPath: [SynologyPhotoCollection] = []
    private(set) var loadingFolders = false
    private(set) var folderError: String?
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var sourceDrafts: [SynologyPhotoSpace: SynologyPhotoAlbumCondition] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var countTask: Task<Void, Never>?
    @ObservationIgnored private var folderTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = UUID()
    @ObservationIgnored private var countGeneration = UUID()
    @ObservationIgnored private var folderGeneration = UUID()

    init(model: SynologyPhotosModel) { self.model = model }
    func canOpen(editing: Bool = false) -> Bool {
        guard model.canStartManagementMutation, model.managementFeatures.contains(.conditionAlbums), !model.conditionSourceSpaces.isEmpty else { return false }
        if !editing { return true }
        return model.selectedAlbum?.isConditional == true && model.selectedAlbum?.isFrozen == false &&
            model.selectedAlbumAccess?.albumID == model.selectedAlbum?.id && model.selectedAlbumAccess?.isOwner == true
    }
    func begin(editing: Bool = false) {
        guard canOpen(editing: editing) else { return }
        cancel()
        draft = .init(editing: editing, album: model.selectedAlbum, section: model.section, space: model.selectedSpace)
        if let space = model.conditionSourceSpaces.first(where: { $0 == model.selectedSpace }) ?? model.conditionSourceSpaces.first {
            condition = Self.empty(in: space)
        }
        load()
    }
    private static func empty(in space: SynologyPhotoSpace) -> SynologyPhotoAlbumCondition {
        .init(fields: space == .shared ? ["user_id": .integer(0), "item_type": .array([])] : ["item_type": .array([])])
    }
    private func isCurrent(_ value: Draft) -> Bool {
        draft?.id == value.id && model.isModuleEnabled && model.section == value.section &&
            model.selectedSpace == value.space && model.selectedAlbum == value.album
    }
    func load() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        error = nil
        guard draft.editing, let album = draft.album else { return }
        isLoading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false; self.loadTask = nil } }
            do {
                let value = try await self.model.albumCondition(id: album.id)
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                guard self.model.conditionSourceSpaces.contains(value.sourceSpace) else { throw CocoaError(.fileReadNoPermission) }
                self.original = value; self.condition = value
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.error = L10n.string("mobile.photos.condition.readFailed") }
            }
        }
    }
    var datesValid: Bool {
        condition.values("time").allSatisfy {
            guard let object = $0.object else { return false }
            let start = object["start_time"]?.integer, end = object["end_time"]?.integer
            return (start != nil || end != nil) && (start.map { $0 >= 0 } ?? true) &&
                (end.map { $0 >= 0 } ?? true) && (start == nil || end == nil || start! <= end!)
        }
    }
    var mutation: SynologyPhotosMutation? {
        guard let draft, isCurrent(draft), canOpen(editing: draft.editing), !isLoading, error == nil,
              datesValid, model.conditionSourceSpaces.contains(condition.sourceSpace) else { return nil }
        if draft.editing {
            guard let album = draft.album, let original, original.fields != condition.fields else { return nil }
            return .setAlbumCondition(id: album.id, original: original, condition: condition)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : .createConditionAlbum(name: trimmed, condition: condition)
    }
    @discardableResult func submit() -> Bool {
        guard let mutation else { return false }
        model.submitMutation(mutation)
        guard model.isManaging else { return false }
        cancel(); return true
    }
    func switchSource(_ space: SynologyPhotoSpace) {
        guard let draft, isCurrent(draft), space != condition.sourceSpace, model.conditionSourceSpaces.contains(space) else { return }
        sourceDrafts[condition.sourceSpace] = condition
        condition = sourceDrafts[space] ?? Self.empty(in: space)
        search = ""; clearSuggestions(); resetFolders()
    }
    func add(_ option: SynologyPhotoConditionOption, key: String) {
        var value = condition, values = value.values(key)
        if !values.contains(option.value) { values.append(option.value) }
        value.setValues(values, for: key)
        value.names[key, default: []].removeAll { $0.value == option.value }
        value.names[key, default: []].append(option)
        if SynologyPhotoConditionField(rawValue: key)?.supportsPolicy == true, value.fields[key + "_policy"] == nil {
            value.fields[key + "_policy"] = .string("or")
        }
        condition = value
    }
    func remove(_ value: SynologyPhotoConditionValue, key: String) { condition.setValues(condition.values(key).filter { $0 != value }, for: key) }
    func addKeyword() {
        let value = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        add(.init(name: value, value: .string(value)), key: "keyword"); search = ""
    }
    func dateObject(_ index: Int) -> [String: SynologyPhotoConditionValue]? {
        let values = condition.values("time")
        return values.indices.contains(index) ? values[index].object : nil
    }
    func updateDate(_ index: Int, key: String, date: Date?) {
        var values = condition.values("time")
        guard values.indices.contains(index), var object = values[index].object else { return }
        object[key] = date.map { .integer(Int($0.timeIntervalSince1970)) }
        values[index] = .object(object)
        condition.setValues(values.filter { $0.object?.isEmpty != true }, for: "time")
    }
    func findSuggestions() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        searchTask?.cancel(); searchGeneration = UUID()
        let generation = searchGeneration, keyword = search, space = condition.sourceSpace
        isSearching = true; suggestionError = nil; suggestions = [:]
        searchTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.searchGeneration == generation { self.isSearching = false; self.searchTask = nil } }
            do {
                let values = try await self.model.conditionSuggestions(keyword: keyword, in: space)
                guard !Task.isCancelled, self.isCurrent(draft), self.searchGeneration == generation else { return }
                self.suggestions = values
            } catch {
                if !Task.isCancelled, self.isCurrent(draft), self.searchGeneration == generation { self.suggestionError = L10n.string("photos.condition.searchFailed") }
            }
        }
    }
    func preview() {
        guard let draft, isCurrent(draft), !isLoading, datesValid, !isCounting else { return }
        countGeneration = UUID()
        let generation = countGeneration, snapshot = condition
        isCounting = true; countError = nil
        countTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.countGeneration == generation { self.isCounting = false; self.countTask = nil } }
            do {
                let value = try await self.model.conditionItemCount(snapshot)
                guard !Task.isCancelled, self.isCurrent(draft), self.countGeneration == generation else { return }
                self.count = value
            } catch {
                if !Task.isCancelled, self.isCurrent(draft), self.countGeneration == generation { self.countError = L10n.string("photos.condition.countFailed") }
            }
        }
    }
    func loadFolders(path: [SynologyPhotoCollection] = []) {
        guard let draft, isCurrent(draft), !loadingFolders else { return }
        let space = condition.sourceSpace, generation = UUID()
        folderGeneration = generation; loadingFolders = true; folderError = nil
        folderTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.folderGeneration == generation { self.loadingFolders = false; self.folderTask = nil } }
            do {
                let (root, children) = try await self.model.managementFolders(parentID: path.last?.id, in: space)
                guard !Task.isCancelled, self.isCurrent(draft), self.folderGeneration == generation else { return }
                self.folderPath = path.isEmpty ? [root] : path; self.folders = children
            } catch {
                if !Task.isCancelled, self.isCurrent(draft), self.folderGeneration == generation { self.folderError = L10n.string("photos.request.folderReadFailed") }
            }
        }
    }
    @discardableResult func chooseFolder() -> Bool {
        guard let draft, isCurrent(draft), !loadingFolders, folderError == nil,
              let folder = folderPath.last, folder.space == condition.sourceSpace else { return false }
        add(.init(name: folder.name, value: .integer(folder.id)), key: "folder_filter"); return true
    }
    private func clearSuggestions() {
        searchTask?.cancel(); searchTask = nil; searchGeneration = UUID()
        isSearching = false; suggestions = [:]; suggestionError = nil
    }
    private func resetFolders() {
        folderTask?.cancel(); folderTask = nil; folderGeneration = UUID()
        folders = []; folderPath = []; loadingFolders = false; folderError = nil
    }
    func cancel() {
        loadTask?.cancel(); loadTask = nil; searchTask?.cancel(); searchTask = nil; countTask?.cancel(); countTask = nil
        resetFolders(); draft = nil; original = nil; name = ""; condition = .init(); sourceDrafts = [:]
        field = .keyword; search = ""; clearSuggestions(); isLoading = false; error = nil
    }
}
