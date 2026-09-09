import XCTest
@testable import DsmCore

final class AppStorageNamespaceTests: XCTestCase {
    func test正式版移动端和无应用标识的工具保持原名称() {
        for bundleID in [nil, "io.github.qwertyuiop1995.dsmnativeclient.macos", "io.github.qwertyuiop1995.dsmnativeclient.ios"] {
            XCTAssertEqual(AppStorageNamespace.name("LanStashSecureStore", bundleIdentifier: bundleID), "LanStashSecureStore")
        }
    }

    func test测试版固定目录和密钥名称均独立且跨版本稳定() {
        for name in ["LanStashSecureStore", "LanStashPreview", "LanStashTextEdit", "lanstash-photo-cache", "lanstash-photo-thumbnails", "io.github.qwertyuiop1995.dsmnativeclient.local-secure-store.master-key.v1"] {
            let testName = AppStorageNamespace.name(name, bundleIdentifier: AppStorageNamespace.localTestBundleIdentifier)
            XCTAssertEqual(testName, name + "-LocalTest")
            XCTAssertNotEqual(testName, AppStorageNamespace.name(name, bundleIdentifier: "io.github.qwertyuiop1995.dsmnativeclient.macos"))
        }
    }
}
