import Foundation

/// 本地测试包使用稳定的独立命名空间；正式版及移动端沿用原有名称，不迁移数据。
public enum AppStorageNamespace {
    public static let localTestBundleIdentifier =
        "io.github.qwertyuiop1995.dsmnativeclient.macos.localtest"

    public static var isLocalTest: Bool {
        Bundle.main.bundleIdentifier == localTestBundleIdentifier
    }

    public static func name(
        _ productionName: String,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        bundleIdentifier == localTestBundleIdentifier
            ? productionName + "-LocalTest" : productionName
    }
}
