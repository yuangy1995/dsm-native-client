import DsmCore
import DsmLocalization
import Foundation
import Observation

@MainActor @Observable
final class MobileShareTransferRecovery {
    struct Job: Identifiable {
        let record: MobileShareTransfer
        let queue: MobileFileUploadQueue?
        let lease: MobileShareTransferLease?
        var id: UUID { record.id }
    }

    private let store: MobileShareTransferStore?
    private let backgroundExecution: (any MobileTransferBackgroundManaging)?
    private var profile: NasProfile?
    private var repository: (any FileRepository)?
    private var generation = UUID()
    private(set) var isConfiguring = false
    private(set) var jobs: [Job] = []
    private(set) var error: String?

    init(store: MobileShareTransferStore?, backgroundExecution: (any MobileTransferBackgroundManaging)? = nil) {
        self.store = store; self.backgroundExecution = backgroundExecution
    }

    func configure(profile: NasProfile?, repository: (any FileRepository)?) {
        var retiring = jobs
        for job in retiring {
            for batch in job.queue?.batches ?? [] { batch.pause() }
        }
        jobs = []; self.profile = profile; self.repository = repository; error = nil
        let current = UUID(); generation = current; isConfiguring = true
        Task {
            // 不能取消这个清理任务，否则队列尚未停止就会释放跨进程所有权。
            while retiring.contains(where: { $0.queue?.batches.contains(where: \.isRunning) == true }) {
                try? await Task.sleep(for: .milliseconds(20))
            }
            retiring.removeAll()
            guard generation == current else { return }
            isConfiguring = false
            refresh()
        }
    }

    func refresh() {
        guard !isConfiguring, let store, let profile, let repository else { return }
        do {
            let context = MobileWorkspaceIdentity(profile).storageIdentifier
            let records = try store.records().filter { $0.context == context && $0.profileID == profile.id }
            var refreshed: [Job] = []
            for record in records {
                if let existing = jobs.first(where: { $0.id == record.id && $0.queue != nil }) {
                    refreshed.append(existing)
                    continue
                }
                do {
                    let lease = try store.claim(record)
                    let queue = MobileFileUploadQueue(rootURL: store.queueURL(record.id), backgroundExecution: backgroundExecution,
                        expectedContext: record.context)
                    queue.configure(profile: profile, repository: repository)
                    refreshed.append(.init(record: record, queue: queue, lease: lease))
                } catch MobileShareTransferLease.LeaseError.alreadyOwned {
                    refreshed.append(.init(record: record, queue: nil, lease: nil))
                }
            }
            jobs = refreshed; error = nil
        } catch { self.error = L10n.string("mobile.activity.recovery-error") }
    }

    func removeEmpty(_ job: Job) {
        guard let store, let current = jobs.first(where: { $0.id == job.id }),
              let queue = current.queue, !queue.isConfiguring, queue.batches.isEmpty,
              queue.recoveryError == nil, let lease = current.lease else { return }
        do {
            try store.remove(current.record, lease: lease)
            jobs.removeAll { $0.id == current.id }
            error = nil
        } catch { self.error = L10n.string("mobile.activity.recovery-error") }
    }
}
