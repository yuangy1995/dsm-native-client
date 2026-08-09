@testable import DsmMobile
import XCTest

final class MobileSettingsTests: XCTestCase {
    @MainActor
    func test主题和可选模块偏好按设备持久化() {
        let suiteName = "MobileSettingsTests.persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = MobileSettingsStore(defaults: defaults)
        XCTAssertEqual(first.appearance, .system)
        XCTAssertEqual(first.enabledOptionalModules, MobileModule.optionalPreferenceModules)

        first.appearance = .dark
        first.setVisible(false, module: .containers)

        let restored = MobileSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.appearance, .dark)
        XCTAssertFalse(restored.isVisible(.containers))
        XCTAssertTrue(restored.isVisible(.downloads))
    }

    @MainActor
    func test损坏主题和未知模块安全回退() {
        let suiteName = "MobileSettingsTests.invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unknown-theme", forKey: MobileSettingsStore.appearanceKey)
        defaults.set(
            ["unknown-module", MobileModule.virtualMachines.rawValue],
            forKey: MobileSettingsStore.optionalModulesKey
        )

        let store = MobileSettingsStore(defaults: defaults)
        XCTAssertEqual(store.appearance, .system)
        XCTAssertEqual(store.enabledOptionalModules, [.virtualMachines])
    }

    @MainActor
    func test核心模块和设置永远不可隐藏() {
        let suiteName = "MobileSettingsTests.required.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileSettingsStore(defaults: defaults)

        for module in [
            MobileModule.files,
            .photos,
            .chat,
            .transfers,
            .settings,
        ] {
            store.setVisible(false, module: module)
            XCTAssertTrue(store.isVisible(module))
        }
    }

    @MainActor
    func test重复缓存清理请求被合并() {
        let suiteName = "MobileSettingsTests.clear-gate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileSettingsStore(defaults: defaults)

        XCTAssertTrue(store.beginClearingCache())
        XCTAssertFalse(store.beginClearingCache())
        store.finishClearingCache(result: .success, remainingBytes: 0)
        XCTAssertFalse(store.isClearingCache)
        XCTAssertEqual(store.cacheResult, .success)
    }

    func test设置页使用原生控件本地化和可访问触控目标() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceRoot = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let view = try String(
            contentsOf: sourceRoot
                .appendingPathComponent("Features/Settings/MobileSettingsView.swift"),
            encoding: .utf8
        )
        let root = try String(
            contentsOf: sourceRoot.appendingPathComponent("AppShell/MobileRootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(view.contains("Form"))
        XCTAssertTrue(view.contains("Picker("))
        XCTAssertTrue(view.contains("Toggle("))
        XCTAssertTrue(view.contains("confirmationDialog("))
        XCTAssertTrue(view.contains("frame(minHeight: 44)"))
        XCTAssertTrue(root.contains(".preferredColorScheme(model.settingsStore.appearance.colorScheme)"))

        for literal in ["System", "Light", "Dark", "Clear cache", "Cache cleared"] {
            XCTAssertFalse(view.contains("\"\(literal)\""))
        }
    }

    func test新增设置文案仅使用语义资源键() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceRoot = testURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Features/Settings")
        let sources = try ["MobileSettingsState.swift", "MobileSettingsView.swift"]
            .map { try String(contentsOf: sourceRoot.appendingPathComponent($0), encoding: .utf8) }
            .joined(separator: "\n")

        let allowedLegacy = sources
            .replacingOccurrences(of: "L10n.string(\"settings.language.title\")", with: "")
            .replacingOccurrences(of: "L10n.string(\"settings.language.footer\")", with: "")
            .replacingOccurrences(of: "L10n.string(\"ui.3ab8cc15939f3b5c\")", with: "")
        XCTAssertFalse(allowedLegacy.contains("L10n.string(\"ui."))
        XCTAssertFalse(allowedLegacy.contains("L10n.string(\"settings."))
    }
}
