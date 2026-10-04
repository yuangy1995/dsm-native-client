import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoTasksModel {
    enum Filter: CaseIterable { case all, active, finished }
    var isPresented = false
    var filter: Filter = .all
    private(set) var tasks: [SynologyPhotoBackgroundTask] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var errorTask: SynologyPhotoBackgroundTask?
    private(set) var entries: [SynologyPhotoBackgroundTaskError] = []
    private(set) var loadingErrors = false
    private(set) var errorsFailure: String?
    private(set) var confirmation: SynologyPhotosMutation?
    var showsConfirmation = false
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var errorsGeneration = UUID()
    @ObservationIgnored private var errorsTask: Task<Void, Never>?

    init(model: SynologyPhotosModel) { self.model = model }
    var canOpen: Bool { model.isModuleEnabled && model.managementFeatures.contains(.backgroundTasks) }
    var canControl: Bool { canOpen && model.canControlBackgroundTasks && error == nil }
    func begin() { guard canOpen else { return }; cancel(); isPresented = true }
    var visibleTasks: [SynologyPhotoBackgroundTask] {
        tasks.filter { filter == .all || (filter == .active ? [.waiting, .processing, .aborting].contains($0.status) : $0.status == .done) }
    }
    func refresh() async {
        guard isPresented, canOpen, !isLoading else { return }
        isLoading = true; let current = generation
        defer { if current == generation { isLoading = false } }
        do {
            let values = try await model.backgroundTasks()
            guard current == generation, isPresented, !Task.isCancelled, canOpen else { return }
            tasks = values; error = nil
        } catch {
            if current == generation, isPresented, !Task.isCancelled, canOpen { self.error = L10n.string("photos.tasks.loadFailedHint") }
        }
    }
    func requestCancel(_ task: SynologyPhotoBackgroundTask) {
        guard canControl, tasks.contains(task), task.canCancel else { return }
        confirmation = .cancelBackgroundTask(task); showsConfirmation = true
    }
    func requestClear(_ task: SynologyPhotoBackgroundTask? = nil) {
        guard canControl else { return }
        let targets = task.map { tasks.contains($0) && $0.canClear ? [$0] : [] } ?? tasks.filter(\.canClear)
        guard !targets.isEmpty else { return }
        confirmation = .clearBackgroundTasks(targets); showsConfirmation = true
    }
    var cancelling: Bool { if case .cancelBackgroundTask = confirmation { true } else { false } }
    @discardableResult func confirm() -> Bool {
        guard canControl, let confirmation else { return false }
        let targets: [SynologyPhotoBackgroundTask]
        switch confirmation {
        case .cancelBackgroundTask(let value): targets = [value]
        case .clearBackgroundTasks(let values): targets = values
        default: return false
        }
        guard targets.allSatisfy({ original in tasks.contains { $0.hasSameIdentity(as: original) && (cancelling ? $0.canCancel : $0.canClear) } }) else {
            cancelConfirmation(); error = L10n.string("mobile.photos.tasks.changed"); return false
        }
        model.submitMutation(confirmation)
        guard model.isManagingBackgroundTask else { return false }
        cancelConfirmation(); return true
    }
    func cancelConfirmation() { confirmation = nil; showsConfirmation = false }
    func showErrors(_ task: SynologyPhotoBackgroundTask) {
        guard isPresented, canOpen, tasks.contains(task), task.errors > 0 else { return }
        closeErrors(); errorTask = task; loadErrors()
    }
    func loadErrors() {
        guard isPresented, canOpen, let task = errorTask, !loadingErrors else { return }
        loadingErrors = true; errorsFailure = nil; let current = errorsGeneration
        errorsTask = Task { [weak self] in
            guard let self else { return }
            defer { if current == self.errorsGeneration { self.loadingErrors = false; self.errorsTask = nil } }
            do {
                let values = try await self.model.backgroundTaskErrors(task)
                guard current == self.errorsGeneration, self.isPresented, !Task.isCancelled, self.canOpen else { return }
                self.entries = values
            } catch {
                if current == self.errorsGeneration, self.isPresented, !Task.isCancelled, self.canOpen { self.errorsFailure = L10n.string("photos.tasks.errorsFailedHint") }
            }
        }
    }
    func closeErrors() { errorsGeneration = UUID(); errorsTask?.cancel(); errorsTask = nil; errorTask = nil; entries = []; loadingErrors = false; errorsFailure = nil }
    func canOpenDestination(_ task: SynologyPhotoBackgroundTask) -> Bool {
        task.isTransfer && task.status == .done && (task.isCancelled || task.errors == 0 || task.errors < task.completion) &&
            task.targetSpace.map { model.spaces.contains($0) } == true && (task.targetFolderID ?? 0) > 0
    }
    func openDestination(_ task: SynologyPhotoBackgroundTask) async -> Bool {
        guard isPresented, canOpenDestination(task), tasks.contains(task), !model.isOpeningBackgroundDestination else { return false }
        let current = generation
        let opened = await model.openBackgroundTask(task)
        guard current == generation, isPresented, !Task.isCancelled else { return false }
        if opened { cancel() }; return opened
    }
    func cancel() { generation = UUID(); isPresented = false; tasks = []; filter = .all; isLoading = false; error = nil; cancelConfirmation(); closeErrors() }
}
