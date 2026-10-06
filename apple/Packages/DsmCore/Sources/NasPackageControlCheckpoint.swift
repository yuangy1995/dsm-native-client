import Foundation

public enum NasPackageControlCheckpoint: Sendable { case willSubmit, accepted }

public extension NasPackage {
    /// 图标与说明变化不改变安装身份；版本、安装类别和原安装时间必须保持一致。
    func isSameInstallation(as original: NasPackage) -> Bool {
        id == original.id && version == original.version && installType == original.installType
            && installedAt == original.installedAt
    }

    func matchesControlBaseline(_ original: NasPackage) -> Bool {
        isSameInstallation(as: original) && status == original.status && dsmApps == original.dsmApps
            && canStart == original.canStart && canStop == original.canStop && canUninstall == original.canUninstall
    }

    func allowsControl(_ action: NasPackageAction) -> Bool {
        switch action {
        case .start: canStart && dsmApps != nil
        case .stop: canStop
        case .uninstall: canUninstall && dsmApps != nil
        case .upgrade: false
        }
    }

    func matchesControlResult(_ action: NasPackageAction, original: NasPackage) -> Bool {
        guard isSameInstallation(as: original) else { return false }
        let value = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch action {
        case .start: return value == "running" || value == "active"
        case .stop: return value == "stopped" || value == "inactive" || value == "disabled"
        case .uninstall, .upgrade: return false
        }
    }
}
