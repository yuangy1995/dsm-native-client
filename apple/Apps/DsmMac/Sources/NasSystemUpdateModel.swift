import DsmCore
import DsmLocalization
import Foundation
import Observation

@MainActor @Observable
final class NasSystemUpdateModel {
    enum Phase: Equatable {
        case unchecked, current, available, downloading, ready, installing, reconnecting, completed, attention
    }
    private(set) var phase: Phase = .unchecked
    private(set) var info: NasSystemUpdateInfo?
    private(set) var percent: Double?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var canInstall = false
    private(set) var installationSubmitted = false
    private(set) var plan: NasSystemUpdatePlan?
    @ObservationIgnored private let repository: any NasSettingsRepository

    init(repository: any NasSettingsRepository) { self.repository = repository }

    var shouldPoll: Bool { [.downloading, .installing, .reconnecting].contains(phase) }
    var blocksPowerActions: Bool { (installationSubmitted && phase != .completed) || isBusy || shouldPoll }

    func refresh() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            if installationSubmitted {
                let status = try await repository.loadSystemUpdateStatus()
                percent = status.percent
                switch status.phase {
                case .completed:
                    info = .init(isUpdateAvailable: false, currentVersion: status.installedVersion, latestVersion: plan?.version)
                    phase = .completed; percent = nil; installationSubmitted = false; plan = nil
                case .installing: phase = status.percent == 100 ? .reconnecting : .installing
                case .idle: phase = .reconnecting
                default: phase = .attention; errorMessage = L10n.string("system-update.status-unknown")
                }
            } else {
                let latest: NasSystemUpdateInfo
                if phase == .downloading, let info { latest = info }
                else { latest = try await repository.checkSystemUpdate() }
                info = latest
                do {
                    let status = try await repository.loadSystemUpdateStatus()
                    percent = status.percent
                    canInstall = status.canInstall
                    switch status.phase {
                    case .idle:
                        if latest.currentVersion == nil && !latest.isUpdateAvailable {
                            phase = .attention; errorMessage = L10n.string("system-update.read-failed")
                        } else { phase = latest.isUpdateAvailable ? .available : .current }
                    case .downloading: phase = .downloading
                    case .ready: phase = .ready
                    case .installing: phase = status.percent == 100 ? .reconnecting : .installing
                    case .completed: phase = .completed
                    case .unknown: phase = .attention; errorMessage = L10n.string("system-update.status-unknown")
                    }
                } catch let error as AppError where [.apiUnavailable, .versionUnsupported].contains(error.category) {
                    // 旧 DSM 仍可检查版本；缺少生命周期接口时不显示安装入口。
                    phase = latest.isUpdateAvailable ? .attention : .current
                    canInstall = false
                    if latest.isUpdateAvailable { errorMessage = L10n.string("system-update.use-dsm") }
                }
            }
        } catch { handle(error) }
    }

    func download() async {
        guard !isBusy, !installationSubmitted, phase == .available, let version = info?.latestVersion else { return }
        isBusy = true; errorMessage = nil
        do {
            try await repository.downloadSystemUpdate(expectedVersion: version)
            phase = .downloading; percent = nil
        } catch {
            // 下载请求断线也先回读，避免重复提交。
            phase = .attention; handle(error)
            isBusy = false
            if let error = error as? AppError, [.networkUnavailable, .timeout, .unknown].contains(error.category) { await refresh() }
            return
        }
        isBusy = false
        await refresh()
    }

    func prepareInstallation() async -> Bool {
        guard !isBusy, !installationSubmitted, phase == .ready, canInstall, let version = info?.latestVersion else { return false }
        isBusy = true; errorMessage = nil; plan = nil
        defer { isBusy = false }
        do { plan = try await repository.prepareSystemUpdate(expectedVersion: version); return true }
        catch { handle(error); return false }
    }

    func install() async {
        guard !isBusy, !installationSubmitted, phase == .ready, let plan else { return }
        isBusy = true; errorMessage = nil; percent = nil
        do {
            let result = try await repository.installSystemUpdate(plan: plan)
            // 接受或结果未知后只读跟踪；预检拒绝可以在处理原因后重新确认。
            installationSubmitted = true
            phase = result == .accepted ? .installing : .reconnecting
            if result == .uncertain { errorMessage = L10n.string("system-update.submission-unknown") }
        } catch { handle(error) }
        isBusy = false
    }

    func monitor() async {
        for _ in 0..<480 {
            guard shouldPoll, !Task.isCancelled else { return }
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await refresh()
        }
        if shouldPoll { phase = .attention; errorMessage = L10n.string("system-update.wait-long") }
    }

    private func handle(_ error: Error) {
        let category = (error as? AppError)?.category
        percent = nil
        if installationSubmitted, category == .networkUnavailable || category == .timeout {
            phase = .reconnecting
            errorMessage = L10n.string("system-update.reconnecting-detail")
        } else {
            phase = .attention
            errorMessage = category == .authenticationRequired ? L10n.string("system-update.sign-in") :
                (error as? AppError)?.safeUserMessage ?? L10n.string("system-update.read-failed")
        }
    }

}
