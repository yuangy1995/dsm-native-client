import SwiftUI

public struct AppLanguagePicker: View {
    @Bindable private var store: AppLanguageStore

    public init(store: AppLanguageStore = .shared) {
        self.store = store
    }

    public var body: some View {
        #if os(macOS)
        Menu {
            languagePicker
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            Text(store.string(selectionTitleKey))
        }
        .accessibilityLabel(store.string("settings.language.title"))
        .accessibilityValue(store.string(selectionTitleKey))
        #else
        languagePicker
        #endif
    }

    private var selectionTitleKey: String {
        switch store.selection {
        case .system: "language.follow_system"
        case .english: "language.english"
        case .simplifiedChinese: "language.simplified_chinese"
        }
    }

    private var languagePicker: some View {
        Picker(store.string("settings.language.title"), selection: $store.selection) {
            Text(store.string("language.follow_system"))
                .tag(AppLanguageSelection.system)
            Text(store.string("language.english"))
                .tag(AppLanguageSelection.english)
            Text(store.string("language.simplified_chinese"))
                .tag(AppLanguageSelection.simplifiedChinese)
        }
        .accessibilityLabel(store.string("settings.language.title"))
    }
}
