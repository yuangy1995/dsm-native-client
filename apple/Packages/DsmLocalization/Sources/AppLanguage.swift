import Foundation
import Observation

public enum AppLanguageSelection: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }
}

public enum SupportedAppLanguage: String, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    fileprivate var resourceName: String {
        switch self {
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        }
    }
}

public enum AppLocaleResolver {
    public static func resolve(
        selection: AppLanguageSelection,
        primaryPreferredLanguage: String?
    ) -> SupportedAppLanguage {
        switch selection {
        case .english:
            return .english
        case .simplifiedChinese:
            return .simplifiedChinese
        case .system:
            return resolveSystemLanguage(primaryPreferredLanguage)
        }
    }

    public static func resolveSystemLanguage(_ identifier: String?) -> SupportedAppLanguage {
        guard let identifier, !identifier.isEmpty else {
            return .english
        }
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        let parts = normalized.split(separator: "-").map { $0.lowercased() }
        guard let language = parts.first else {
            return .english
        }
        if language == "en" {
            return .english
        }
        guard language == "zh" else {
            return .english
        }
        if parts.contains("hant")
            || parts.contains("tw")
            || parts.contains("hk")
            || parts.contains("mo") {
            return .english
        }
        if parts.contains("hans")
            || parts.contains("cn")
            || parts.contains("sg") {
            return .simplifiedChinese
        }
        return .english
    }
}

@MainActor
@Observable
public final class AppLanguageStore {
    public static let shared = AppLanguageStore()
    public static let preferenceKey = "lanstash.app-language.v1"

    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]
    private var localeObserver: NSObjectProtocol?

    public var selection: AppLanguageSelection {
        didSet {
            defaults.set(selection.rawValue, forKey: Self.preferenceKey)
            refresh()
        }
    }

    public private(set) var resolvedLanguage: SupportedAppLanguage

    public var locale: Locale {
        resolvedLanguage.locale
    }

    public init(
        defaults: UserDefaults = .standard,
        preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
        observesSystemChanges: Bool = true
    ) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        let saved = defaults.string(forKey: Self.preferenceKey)
            .flatMap(AppLanguageSelection.init(rawValue:))
            ?? .system
        selection = saved
        resolvedLanguage = AppLocaleResolver.resolve(
            selection: saved,
            primaryPreferredLanguage: preferredLanguages().first
        )
        if observesSystemChanges {
            localeObserver = NotificationCenter.default.addObserver(
                forName: NSLocale.currentLocaleDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    public func refresh() {
        resolvedLanguage = AppLocaleResolver.resolve(
            selection: selection,
            primaryPreferredLanguage: preferredLanguages().first
        )
    }

    public func string(_ key: String, _ arguments: CVarArg...) -> String {
        string(key, arguments: arguments)
    }

    public func string(_ key: String, arguments: [CVarArg]) -> String {
        let mainValue = AppLocalizedBundles.main(for: resolvedLanguage)
            .localizedString(forKey: key, value: key, table: nil)
        let format = mainValue == key
            ? AppLocalizedBundles.module(for: resolvedLanguage)
                .localizedString(forKey: key, value: key, table: nil)
            : mainValue
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: locale, arguments: arguments)
    }

}

public enum L10n {
    private static let preferenceKey = "lanstash.app-language.v1"

    public static func string(_ key: String, _ arguments: CVarArg...) -> String {
        // SwiftUI 的 body 在主线程计算。这里读取可观察的共享语言状态，
        // 让所有通过 L10n 生成的文案在用户切换语言后立即重新计算。
        if Thread.isMainThread {
            let language = MainActor.assumeIsolated {
                AppLanguageStore.shared.resolvedLanguage
            }
            return localizedString(key, arguments: arguments, language: language)
        }

        let saved = UserDefaults.standard.string(forKey: preferenceKey)
            .flatMap(AppLanguageSelection.init(rawValue:))
            ?? .system
        let language = AppLocaleResolver.resolve(
            selection: saved,
            primaryPreferredLanguage: Locale.preferredLanguages.first
        )
        return localizedString(key, arguments: arguments, language: language)
    }

    private static func localizedString(
        _ key: String,
        arguments: [CVarArg],
        language: SupportedAppLanguage
    ) -> String {
        let mainValue = AppLocalizedBundles.main(for: language)
            .localizedString(forKey: key, value: key, table: nil)
        let format = mainValue == key
            ? AppLocalizedBundles.module(for: language)
                .localizedString(forKey: key, value: key, table: nil)
            : mainValue
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: language.locale, arguments: arguments)
    }

    public static var locale: Locale {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                AppLanguageStore.shared.locale
            }
        }

        let saved = UserDefaults.standard.string(forKey: preferenceKey)
            .flatMap(AppLanguageSelection.init(rawValue:))
            ?? .system
        return AppLocaleResolver.resolve(
            selection: saved,
            primaryPreferredLanguage: Locale.preferredLanguages.first
        ).locale
    }

}

/// 随 App 发布的语言目录不会在运行中变化。只缓存资源包位置，语言选择和格式化仍逐次解析。
private enum AppLocalizedBundles {
    private static let mainEnglish = resolve(.english, in: .main)
    private static let mainChinese = resolve(.simplifiedChinese, in: .main)
    private static let moduleEnglish = resolve(.english, in: .module)
    private static let moduleChinese = resolve(.simplifiedChinese, in: .module)

    static func main(for language: SupportedAppLanguage) -> Bundle {
        switch language {
        case .english: mainEnglish
        case .simplifiedChinese: mainChinese
        }
    }

    static func module(for language: SupportedAppLanguage) -> Bundle {
        switch language {
        case .english: moduleEnglish
        case .simplifiedChinese: moduleChinese
        }
    }

    private static func resolve(
        _ language: SupportedAppLanguage,
        in baseBundle: Bundle
    ) -> Bundle {
        let resourceNames = [
            language.resourceName,
            language.resourceName.lowercased(),
        ]
        guard let path = resourceNames.lazy.compactMap({
            baseBundle.path(forResource: $0, ofType: "lproj")
        }).first,
        let bundle = Bundle(path: path) else {
            return baseBundle
        }
        return bundle
    }
}
