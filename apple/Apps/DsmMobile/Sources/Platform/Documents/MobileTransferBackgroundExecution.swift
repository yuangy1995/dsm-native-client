import BackgroundTasks
import DsmLocalization
import Foundation
import Observation
import UIKit

enum MobileTransferBackgroundMode: Equatable, Sendable {
    case continuous
    case limited
    case unavailable
}

@MainActor
protocol MobileTransferBackgroundLease: AnyObject {
    func update(completed: Int64, total: Int64?)
    func finish(success: Bool)
}

/// 系统执行时间与网络传输分离，测试可复现系统拒绝、取消及迟到回调。
@MainActor
protocol MobileTransferBackgroundDriving: AnyObject {
    func beginLimited(expiration: @escaping @MainActor @Sendable () async -> Void) -> (any MobileTransferBackgroundLease)?
    func submit(identifier: String, direction: MobileTransferDirection,
                started: @escaping @MainActor @Sendable (any MobileTransferBackgroundLease) -> Void,
                expiration: @escaping @MainActor @Sendable () async -> Void) throws -> Bool
    func cancelPending(identifier: String)
}

/// 每次执行拥有独立系统身份；旧回调不能取消或结束用户后来继续的传输。
@MainActor @Observable
final class MobileTransferBackgroundExecution: MobileTransferBackgroundManaging {
    private struct Execution {
        let taskID: UUID
        let identifier: String
        let expiration: @MainActor @Sendable () async -> Void
        var limited: (any MobileTransferBackgroundLease)?
        var continuous: (any MobileTransferBackgroundLease)?
        var completed: Int64 = 0
        var total: Int64?
    }

    private let driver: any MobileTransferBackgroundDriving
    private let identifierPrefix: String
    @ObservationIgnored private var executions: [UUID: Execution] = [:]
    private(set) var modes: [UUID: MobileTransferBackgroundMode] = [:]

    init(driver: any MobileTransferBackgroundDriving,
         identifierPrefix: String = "io.github.qwertyuiop1995.dsmnativeclient.mobile.transfer") {
        self.driver = driver
        self.identifierPrefix = identifierPrefix
    }

    @discardableResult
    func begin(taskID: UUID, direction: MobileTransferDirection,
               expiration: @escaping @MainActor @Sendable () async -> Void) -> UUID {
        let token = UUID()
        let identifier = identifierPrefix + "." + token.uuidString
        let expire: @MainActor @Sendable () async -> Void = { [weak self] in await self?.expire(token) }
        let limited = driver.beginLimited { [weak self] in
            guard self?.executions[token]?.continuous == nil else { return }
            await self?.expire(token)
        }
        executions[token] = Execution(taskID: taskID, identifier: identifier, expiration: expiration, limited: limited)
        modes[taskID] = limited == nil ? .unavailable : .limited
        do {
            _ = try driver.submit(identifier: identifier, direction: direction, started: { [weak self] lease in
                guard let self, var execution = executions[token] else {
                    lease.finish(success: false)
                    return
                }
                execution.limited?.finish(success: true)
                execution.limited = nil
                execution.continuous = lease
                executions[token] = execution
                modes[execution.taskID] = .continuous
                lease.update(completed: execution.completed, total: execution.total)
            }, expiration: expire)
        } catch {
            // 系统不接受持续任务时仍使用已申请的有限时间，不创建新的网络请求。
        }
        return token
    }

    func update(_ token: UUID, completed: Int64, total: Int64?) {
        guard var execution = executions[token] else { return }
        execution.completed = max(0, completed)
        execution.total = total.flatMap { $0 > 0 ? $0 : nil }
        executions[token] = execution
        execution.continuous?.update(completed: execution.completed, total: execution.total)
    }

    func finish(_ token: UUID, success: Bool) {
        guard let execution = executions.removeValue(forKey: token) else { return }
        release(execution, success: success)
        removeModeIfFinished(execution.taskID)
    }

    private func expire(_ token: UUID) async {
        guard let execution = executions.removeValue(forKey: token) else { return }
        removeModeIfFinished(execution.taskID)
        // 先取消网络并保存恢复状态，再归还系统时间；迟到回调不能重复取消。
        await execution.expiration()
        release(execution, success: false)
    }

    private func removeModeIfFinished(_ taskID: UUID) {
        if !executions.values.contains(where: { $0.taskID == taskID }) { modes.removeValue(forKey: taskID) }
    }

    private func release(_ execution: Execution, success: Bool) {
        if execution.continuous == nil { driver.cancelPending(identifier: execution.identifier) }
        execution.continuous?.finish(success: success)
        execution.limited?.finish(success: success)
    }
}

@MainActor
final class MobileSystemTransferBackgroundDriver: MobileTransferBackgroundDriving {
    func beginLimited(expiration: @escaping @MainActor @Sendable () async -> Void) -> (any MobileTransferBackgroundLease)? {
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "File transfer") {
            Task { @MainActor in await expiration() }
        }
        guard identifier != .invalid else { return nil }
        return LimitedLease(identifier: identifier)
    }

    func submit(identifier: String, direction: MobileTransferDirection,
                started: @escaping @MainActor @Sendable (any MobileTransferBackgroundLease) -> Void,
                expiration: @escaping @MainActor @Sendable () async -> Void) throws -> Bool {
        guard #available(iOS 26.0, *), UIApplication.shared.applicationState == .active else { return false }
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            // 注册明确指定主队列；系统句柄只在主线程创建和使用。
            MainActor.assumeIsolated {
                guard let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                task.expirationHandler = { Task { @MainActor in await expiration() } }
                started(ContinuedLease(task: task))
            }
        }
        guard registered else { return false }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: L10n.string(direction == .upload ? "mobile.transfer.background.upload" : "mobile.transfer.background.download"),
            subtitle: L10n.string("mobile.transfer.background.progress"))
        request.strategy = .fail
        try BGTaskScheduler.shared.submit(request)
        return true
    }

    func cancelPending(identifier: String) {
        if #available(iOS 26.0, *) { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
    }

    private final class LimitedLease: MobileTransferBackgroundLease {
        private var identifier: UIBackgroundTaskIdentifier
        init(identifier: UIBackgroundTaskIdentifier) { self.identifier = identifier }
        func update(completed: Int64, total: Int64?) {}
        func finish(success: Bool) {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }

    @available(iOS 26.0, *)
    private final class ContinuedLease: MobileTransferBackgroundLease {
        private let task: BGContinuedProcessingTask
        private var ended = false
        init(task: BGContinuedProcessingTask) { self.task = task }
        func update(completed: Int64, total: Int64?) {
            guard !ended else { return }
            // 未知总量使用不确定进度；网络字节到齐仍须等待现有结果校验，不提前显示完成。
            if let total, total > 0 {
                task.progress.totalUnitCount = total
                task.progress.completedUnitCount = min(max(0, completed), max(0, total - 1))
            } else {
                task.progress.totalUnitCount = -1
                task.progress.completedUnitCount = max(0, completed)
            }
        }
        func finish(success: Bool) {
            guard !ended else { return }
            ended = true
            if success {
                task.progress.totalUnitCount = max(1, task.progress.totalUnitCount)
                task.progress.completedUnitCount = task.progress.totalUnitCount
            }
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        }
    }
}
