import Foundation
import Observation

@MainActor
@Observable
final class MobileSettingsStore {
    static let appearanceKey = "lanstash.mobile.settings.appearance.v1"
    static let optionalModulesKey = "lanstash.mobile.settings.optional-modules.v1"

    private let defaults: UserDefaults

    var appearance: MobileAppearancePreference {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
        }
    }

    private(set) var enabledOptionalModules: Set<MobileModule>
    private(set) var photoThumbnailCacheBytes = 0
    private(set) var isClearingCache = false
    var cacheResult: MobileSettingsCacheResult?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Self.appearanceKey)
            .flatMap(MobileAppearancePreference.init(rawValue:))
            ?? .system

        let savedValues = defaults.stringArray(forKey: Self.optionalModulesKey)
        if let savedValues {
            enabledOptionalModules = Set(savedValues.compactMap(MobileModule.init(rawValue:)))
                .intersection(MobileModule.optionalPreferenceModules)
        } else {
            enabledOptionalModules = MobileModule.optionalPreferenceModules
        }
    }

    func isVisible(_ module: MobileModule) -> Bool {
        !module.isOptionalPreference || enabledOptionalModules.contains(module)
    }

    func setVisible(_ isVisible: Bool, module: MobileModule) {
        guard module.isOptionalPreference else { return }
        if isVisible {
            enabledOptionalModules.insert(module)
        } else {
            enabledOptionalModules.remove(module)
        }
        defaults.set(
            enabledOptionalModules.map(\.rawValue).sorted(),
            forKey: Self.optionalModulesKey
        )
    }

    func setPhotoThumbnailCacheBytes(_ bytes: Int) {
        photoThumbnailCacheBytes = max(0, bytes)
    }

    func beginClearingCache() -> Bool {
        guard !isClearingCache else { return false }
        isClearingCache = true
        cacheResult = nil
        return true
    }

    func finishClearingCache(result: MobileSettingsCacheResult, remainingBytes: Int) {
        photoThumbnailCacheBytes = max(0, remainingBytes)
        isClearingCache = false
        cacheResult = result
    }
}
