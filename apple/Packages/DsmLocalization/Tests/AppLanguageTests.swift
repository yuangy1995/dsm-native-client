import Foundation
import Observation
import Testing
@testable import DsmLocalization

@Test func systemLanguageResolutionUsesEnglishFallback() {
    #expect(AppLocaleResolver.resolveSystemLanguage("en-GB") == .english)
    #expect(AppLocaleResolver.resolveSystemLanguage("zh-Hans-CN") == .simplifiedChinese)
    #expect(AppLocaleResolver.resolveSystemLanguage("zh-CN") == .simplifiedChinese)
    #expect(AppLocaleResolver.resolveSystemLanguage("zh-SG") == .simplifiedChinese)
    #expect(AppLocaleResolver.resolveSystemLanguage("zh-Hant-TW") == .english)
    #expect(AppLocaleResolver.resolveSystemLanguage("ja-JP") == .english)
    #expect(AppLocaleResolver.resolveSystemLanguage(nil) == .english)
}

@Test @MainActor func explicitLanguageOverridesSystemAndPersists() {
    let suite = "AppLanguageTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = AppLanguageStore(
        defaults: defaults,
        preferredLanguages: { ["ja-JP"] },
        observesSystemChanges: false
    )
    #expect(store.resolvedLanguage == .english)
    store.selection = .simplifiedChinese
    #expect(store.resolvedLanguage == .simplifiedChinese)
    #expect(defaults.string(forKey: AppLanguageStore.preferenceKey) == "zh-Hans")
}

@Test @MainActor func localizedResourcesContainBothLanguages() {
    let english = AppLanguageStore(
        defaults: UserDefaults(suiteName: "L10n.en.\(UUID().uuidString)")!,
        preferredLanguages: { ["en-US"] },
        observesSystemChanges: false
    )
    let chinese = AppLanguageStore(
        defaults: UserDefaults(suiteName: "L10n.zh.\(UUID().uuidString)")!,
        preferredLanguages: { ["zh-CN"] },
        observesSystemChanges: false
    )
    #expect(english.string("settings.language.title") == "Language")
    #expect(chinese.string("settings.language.title") == "语言")
}

@Test @MainActor func localizedStringObservationRefreshesImmediately() {
    let suite = "L10n.observation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = AppLanguageStore(
        defaults: defaults,
        preferredLanguages: { ["en-US"] },
        observesSystemChanges: false
    )
    nonisolated(unsafe) var didInvalidate = false
    let initial = withObservationTracking {
        store.string("settings.language.title")
    } onChange: {
        didInvalidate = true
    }

    #expect(initial == "Language")
    store.selection = .simplifiedChinese
    #expect(didInvalidate)
    #expect(store.string("settings.language.title") == "语言")
}

@Test @MainActor func cachedResourceLocationsKeepLanguageAndArgumentsFresh() {
    let suite = "L10n.bundle-cache.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppLanguageStore(defaults: defaults, preferredLanguages: { ["en-US"] }, observesSystemChanges: false)
    for _ in 0..<3 {
        store.selection = .english
        #expect(store.string("settings.language.title") == "Language")
        #expect(store.string("item.share.named", "first-synthetic").contains("first-synthetic"))
        let second = store.string("item.share.named", "second-synthetic")
        #expect(second.contains("second-synthetic"))
        #expect(!second.contains("first-synthetic"))
        store.selection = .simplifiedChinese
        #expect(store.string("settings.language.title") == "语言")
        #expect(store.string("item.share.named", "第三个示例").contains("第三个示例"))
        #expect(store.string("missing.synthetic.key") == "missing.synthetic.key")
    }
}

@Test @MainActor func localDiskMountTerminologyAndRecoveryMessagesAreBilingual() {
    let suite = "L10n.mount.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppLanguageStore(
        defaults: defaults,
        preferredLanguages: { ["en-US"] },
        observesSystemChanges: false
    )
    for language in [AppLanguageSelection.english, .simplifiedChinese] {
        store.selection = language
        for key in [
            "desktopDrive.title", "desktopDrive.add", "desktopDrive.creator.title",
            "desktopDrive.description", "desktopDrive.menu.tooltip",
            "desktopDrive.error.connectionSetup", "desktopDrive.error.sessionSetup",
            "desktopDrive.error.nasAccess", "communityReport.group.desktopDrive",
        ] {
            let text = store.string(key)
            #expect(text != key)
            #expect(!text.contains("云盘"))
            #expect(!text.localizedCaseInsensitiveContains("cloud"))
        }
        #expect(store.string("desktopDrive.title") == (
            language == .english ? "Local disk mounts" : "本地磁盘挂载"
        ))
    }
}
