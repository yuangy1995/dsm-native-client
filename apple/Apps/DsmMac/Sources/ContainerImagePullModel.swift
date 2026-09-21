import DsmCore
import DsmLocalization
import Foundation
import Observation

@MainActor
@Observable
final class ContainerImagePullModel {
    private(set) var results: [ContainerImagePullProgress] = []
    private(set) var isBusy = false
    private(set) var isAvailable = false
    private(set) var isVisible = false
    private(set) var errorMessage: String?
    private(set) var needsParentRefresh = false
    private var selectedRepository = ""
    private var selectedTag = ""
    private var confirmation: ContainerImagePullRequest?
    @ObservationIgnored private let repository: any ServiceManagementRepository
    @ObservationIgnored private var generation = 0

    init(repository: any ServiceManagementRepository) { self.repository = repository }

    var isConfirmed: Bool { confirmation != nil }
    var canConfirm: Bool {
        let reference = ContainerImagePullRequest.referenceKey(repository: selectedRepository, tag: selectedTag)
        return isVisible && isAvailable && !isBusy &&
            ContainerImagePullRequest.isValidTarget(repository: selectedRepository, tag: selectedTag) &&
            !results.contains { !$0.stage.isTerminal && $0.referenceKey == reference }
    }
    var canSubmit: Bool { canConfirm && confirmation != nil }
    var canReview: Bool { isVisible && !isBusy }
    var hasPollableTasks: Bool { results.contains { $0.stage == .downloading } }

    func setTarget(repository: String, tag: String) {
        let repository = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repository != selectedRepository || tag != selectedTag else { return }
        selectedRepository = repository; selectedTag = tag; confirmation = nil
    }
    func confirm(_ value: Bool) {
        confirmation = value && canConfirm ? ContainerImagePullRequest(repository: selectedRepository, tag: selectedTag, isConfirmed: true) : nil
    }
    private func beginVisibility() -> Int {
        generation += 1; isVisible = true; isBusy = true; isAvailable = false; errorMessage = nil; confirmation = nil
        return generation
    }
    func activate() async { await loadInitial(generation: beginVisibility()) }
    private func loadInitial(generation stamp: Int) async {
        let supported = await repository.canStartContainerImagePull()
        guard current(stamp) else { return }
        isAvailable = supported
        isBusy = false
        await refresh()
    }
    func watch(interval: Duration = .seconds(5)) async {
        let stamp = beginVisibility()
        await loadInitial(generation: stamp)
        guard current(stamp) else { return }
        defer { if current(stamp) { deactivate() } }
        while current(stamp), !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { break }
            if current(stamp), hasPollableTasks { await refresh(automatic: true) }
        }
    }
    func deactivate() { generation += 1; isVisible = false; isBusy = false; confirmation = nil }
    func takeParentRefreshRequest() -> Bool {
        let needed = needsParentRefresh; needsParentRefresh = false; return needed
    }

    func submit() async {
        guard canSubmit, let request = confirmation else { return }
        let stamp = generation; isBusy = true; confirmation = nil; errorMessage = nil; needsParentRefresh = true
        defer { if current(stamp) { isBusy = false } }
        do {
            // 先保留不明结果占位；异常或窗口关闭不能让同一目标变成可重复提交。
            store(try .awaitingReceipt(for: request))
            let result = try await repository.startContainerImagePull(request)
            guard result.id == request.id, result.repository == request.repository, result.tag == request.tag else {
                if current(stamp) { errorMessage = L10n.string("container-image.pull.review-needed") }
                return
            }
            // 模型固定绑定同一仓库；迟到的任务结果仍可入账，但不得覆盖新窗口的忙碌状态。
            store(result)
        } catch { if current(stamp) { errorMessage = L10n.string("container-image.pull.no-receipt") } }
    }

    func refresh(automatic: Bool = false) async {
        guard canReview, !automatic || hasPollableTasks else { return }
        let stamp = generation; isBusy = true; errorMessage = nil
        if !automatic { confirmation = nil }
        defer { if current(stamp) { isBusy = false } }
        do {
            let cached = try await repository.loadContainerImagePulls()
            guard current(stamp), !Task.isCancelled else { return }
            for result in cached { store(result) }
            let pending = results.filter { !$0.stage.isTerminal && (!automatic || $0.stage == .downloading) }
            for item in pending {
                guard current(stamp), !Task.isCancelled else { return }
                if let updated = try await repository.reviewContainerImagePull(id: item.id), updated.id == item.id,
                   updated.repository == item.repository, updated.tag == item.tag {
                    store(updated)
                }
            }
        } catch {
            if current(stamp), !Task.isCancelled { errorMessage = L10n.string("container-image.pull.read-failed") }
        }
    }

    private func store(_ value: ContainerImagePullProgress) {
        if let index = results.firstIndex(where: { $0.id == value.id }) {
            // 同一请求的已确认终态不可被迟到缓存或旧读取降级。
            if results[index].stage.isTerminal { return }
            results[index] = value
        } else { results.append(value) }
        needsParentRefresh = needsParentRefresh || value.outcome.submitted
    }
    private func current(_ stamp: Int) -> Bool { isVisible && generation == stamp }

    static func statusText(_ value: ContainerImagePullProgress) -> String {
        if value.outcome.errorCategory == .authentication { return L10n.string("container-image.pull.sign-in") }
        switch value.stage {
        case .awaitingReceipt: return L10n.string("container-image.pull.no-receipt")
        case .needsReview: return L10n.string("container-image.pull.review-needed")
        case .ready: return L10n.string("container-image.pull.ready")
        case .downloading:
            if let percentage = value.percentage { return L10n.string("container-image.pull.percent", percentage) }
            return L10n.string("container-image.pull.downloading")
        case .rejected:
            return L10n.string(value.outcome.errorCategory == .permission ? "container-image.pull.permission" :
                value.outcome.errorCategory == .conflict ? "container-image.pull.conflict" :
                value.outcome.errorCategory == .unsupported ? "container-image.pull.unsupported" :
                value.outcome.status == .cancelledBeforeSubmission ? "container-image.pull.not-sent" : "container-image.pull.failed")
        }
    }
}
