import DsmCore
import DsmNetwork
import Foundation
import Observation

@MainActor
@Observable
final class MobileDownloadSettingsModel {
    let recovery: MobileDownloadSettingsStore
    private(set) var context = ""
    private(set) var activation = UUID()
    private(set) var snapshot: DownloadSettingsSnapshot?
    private(set) var draft: [DownloadSettingsField: DownloadSettingsValue] = [:]
    private(set) var isLoading = false
    private(set) var isSaving = false
    var errorKey: String?
    @ObservationIgnored private var repository: DsmServiceManagementRepository?
    @ObservationIgnored private var readGeneration: UInt64 = 0
    @ObservationIgnored private(set) var operation: Task<Void, Never>?

    init(root: URL?) { recovery = MobileDownloadSettingsStore(root: root) }
    var entry: MobileDownloadSettingsStore.Entry? { recovery.entries.last { $0.context == context } }
    var canEdit: Bool { snapshot?.isManager == true && !isLoading && !isSaving && entry?.unfinished != true && !recovery.failed }
    var canSave: Bool { canEdit && !changes.isEmpty }
    var changes: [DownloadSettingsChange] {
        guard let snapshot else { return [] }
        return DownloadSettingsField.Group.allCases.compactMap { group in
            var keys = Set(snapshot.values.keys.filter { $0.group == group && draft[$0] != snapshot.values[$0] })
            if keys.contains(.httpDownload) || keys.contains(.ftpDownload) { keys.formUnion([.httpDownload, .ftpDownload]) }
            let original = snapshot.values.filter { keys.contains($0.key) }, desired = draft.filter { keys.contains($0.key) }
            let change = DownloadSettingsChange(group: group, original: original, desired: desired)
            return change.isValid ? change : nil
        }
    }
    func configure(profile: NasProfile?, repository: DsmServiceManagementRepository?) {
        let next = profile.map { MobileWorkspaceIdentity($0).storageIdentifier } ?? ""
        guard next != context || repository.map(ObjectIdentifier.init) != self.repository.map(ObjectIdentifier.init) else { return }
        activation = UUID(); readGeneration &+= 1; operation?.cancel(); operation = nil
        context = next; self.repository = repository; snapshot = nil; draft = [:]
        isLoading = false; isSaving = false; errorKey = nil
    }
    func set(_ field: DownloadSettingsField, to value: DownloadSettingsValue) {
        guard canEdit, snapshot?.values[field] != nil, field.accepts(value) else { return }
        if field == .httpDownload || field == .ftpDownload {
            guard snapshot?.values[.httpDownload] == snapshot?.values[.ftpDownload], snapshot?.values[.httpDownload] != nil else { return }
            draft[.httpDownload] = value; draft[.ftpDownload] = value
        } else { draft[field] = value }
    }
    func chooseFolder(_ path: String, activation expected: UUID) {
        guard expected == activation, path.hasPrefix("/"), path.count > 1 else { return }
        set(.destination, to: .text(String(path.dropFirst())))
    }
    func load() async {
        guard !isSaving, let repository, !context.isEmpty else { return }
        readGeneration &+= 1
        let generation = readGeneration, token = activation
        isLoading = true; errorKey = nil
        defer { if token == activation, generation == readGeneration { isLoading = false } }
        do {
            let current = try await repository.loadDownloadSettingsSnapshot()
            guard token == activation, generation == readGeneration, !Task.isCancelled else { return }
            snapshot = current; draft = current.values; isLoading = false
            if entry?.hasSubmitted == true { run(continuePlanned: false) }
        } catch {
            guard token == activation, generation == readGeneration else { return }
            isLoading = false
            if !(error is CancellationError) { errorKey = Self.errorKey(error) }
        }
    }
    func save() {
        guard canSave else { return }
        do {
            let entry = MobileDownloadSettingsStore.Entry(id: UUID(), context: context, createdAt: Date(),
                steps: changes.map { .init(change: $0) })
            try recovery.reserve(entry); run(continuePlanned: true)
        } catch { errorKey = "download.settings.storage-error" }
    }
    func cancelRemaining() {
        guard let entry else { return }
        do { try recovery.cancelRemaining(entry.id) } catch { errorKey = "download.settings.storage-error" }
    }
    func run(continuePlanned: Bool) {
        guard !isSaving, let repository, let entry, entry.unfinished, recovery.begin(entry.id) else { return }
        let token = activation, store = recovery
        let allowNew = continuePlanned && !entry.hasSubmitted
        isSaving = true; errorKey = nil; readGeneration &+= 1; isLoading = false
        operation = Task { [weak self] in
            defer {
                store.end(entry.id)
                if let self, self.activation == token { self.isSaving = false; self.operation = nil }
            }
            for step in entry.steps {
                guard let self, self.activation == token, !Task.isCancelled,
                      let current = store.entry(entry.id)?.steps.first(where: { $0.id == step.id }) else { break }
                do {
                    if current.phase == .submitted {
                        if try await repository.reviewDownloadSettings(current.change) {
                            try store.progress(entry.id, group: step.id, phase: .complete)
                            self.applyConfirmed(current.change, activation: token)
                        } else { break }
                    } else if current.phase == .planned && allowNew {
                        let outcome = try await repository.changeDownloadSettings(current.change) { [weak self] in
                            try await MainActor.run {
                                guard let self, self.activation == token, !Task.isCancelled,
                                      store.entry(entry.id)?.steps.first(where: { $0.id == step.id })?.phase == .planned else { throw CancellationError() }
                                try store.progress(entry.id, group: step.id, phase: .submitted)
                            }
                        }
                        switch outcome {
                        case .complete:
                            try store.progress(entry.id, group: step.id, phase: .complete)
                            self.applyConfirmed(current.change, activation: token)
                        case .pending: break
                        case .denied: try store.progress(entry.id, group: step.id, phase: .failed, failure: .denied)
                        case .rejected: try store.progress(entry.id, group: step.id, phase: .failed, failure: .unavailable)
                        case .cancelledBeforeSubmission: try store.progress(entry.id, group: step.id, phase: .cancelled)
                        }
                        if outcome != .complete { break }
                    }
                } catch {
                    // 持久结果属于原账号；迟到 UI 只能在原激活实例显示。
                    if store.entry(entry.id)?.steps.first(where: { $0.id == step.id })?.phase == .planned {
                        if error is CancellationError { try? store.progress(entry.id, group: step.id, phase: .cancelled) }
                        else {
                            let category = (error as? AppError)?.category
                            try? store.progress(entry.id, group: step.id, phase: .failed,
                                failure: category == .permissionDenied ? .denied : category == .conflict ? .changed : .unavailable)
                        }
                    }
                    if self.activation == token, !(error is CancellationError) {
                        self.errorKey = store.failed ? "download.settings.storage-error" : Self.errorKey(error)
                    }
                    break
                }
            }
            guard let self, self.activation == token, !Task.isCancelled else { return }
            // 最后一次读取只刷新展示，不继续任何尚未提交的分区。
            if let current = try? await repository.loadDownloadSettingsSnapshot(), self.activation == token, !Task.isCancelled {
                self.snapshot = current; self.draft = current.values
            }
        }
    }
    private func applyConfirmed(_ change: DownloadSettingsChange, activation expected: UUID) {
        guard activation == expected, let snapshot else { return }
        // 已回读成功的字段立即成为新基线；附加刷新失败也不能让同一修改重新出现在保存按钮中。
        self.snapshot = .init(isManager: snapshot.isManager, values: snapshot.values.merging(change.desired) { _, new in new })
        draft.merge(change.desired) { _, new in new }
    }
    static func errorKey(_ error: Error) -> String {
        switch (error as? AppError)?.category {
        case .permissionDenied: "download.settings.permission"
        case .conflict: "download.settings.changed"
        default: "download.settings.load-error"
        }
    }
}
