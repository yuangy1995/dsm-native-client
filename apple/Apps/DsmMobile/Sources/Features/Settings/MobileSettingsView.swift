import DsmCore
import DsmLocalization
import SwiftUI

struct MobileSettingsView: View {
    @Bindable var model: MobileAppModel
    @State private var confirmsCacheClear = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section(L10n.string("settings.language.title")) {
                AppLanguagePicker()
                Text(L10n.string("settings.language.footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.isModuleVisible(.chat) {
                Section {
                    Toggle(L10n.string("mobile.chat.notification.enable"), isOn: Binding(
                        get: { model.chatModel.notifications.enabled },
                        set: { enabled in Task {
                            await model.chatModel.notifications.setEnabled(enabled)
                            if enabled { await model.chatModel.reloadConversations() }
                        } }
                    ))
                    .frame(minHeight: 44).disabled(model.chatModel.notifications.isChangingPermission)
                    .accessibilityIdentifier("chat-notifications-enabled")
                    if model.chatModel.notifications.authorization == .denied {
                        Text(L10n.string("mobile.chat.notification.denied"))
                        Button(L10n.string("mobile.chat.voice.settings")) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }.frame(minHeight: 44).accessibilityIdentifier("chat-notifications-settings")
                    } else if let key = model.chatModel.notifications.errorKey {
                        Text(L10n.string(key)).foregroundStyle(.secondary)
                    }
                } header: { Text(L10n.string("mobile.chat.notification.title")) }
                footer: { Text(L10n.string("mobile.chat.notification.footer")) }
            }

            Section {
                Picker(
                    L10n.string("mobile.settings.appearance.title"),
                    selection: Binding(
                        get: { model.settingsStore.appearance },
                        set: { model.settingsStore.appearance = $0 }
                    )
                ) {
                    ForEach(MobileAppearancePreference.allCases) { appearance in
                        Text(L10n.string(appearance.titleKey)).tag(appearance)
                    }
                }
            } header: {
                Text(L10n.string("mobile.settings.appearance.title"))
            } footer: {
                Text(L10n.string("mobile.settings.appearance.footer"))
            }

            Section {
                if model.isLoadingModuleAccess {
                    ProgressView(L10n.string("mobile.settings.modules.loading"))
                }
                if model.moduleAccessLookupFailed {
                    Text(L10n.string("mobile.settings.modules.failed"))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mobile.settings.modules.failed")
                } else if !model.isLoadingModuleAccess, model.optionalModulesAvailableForPreference().isEmpty {
                    Text(L10n.string("mobile.settings.modules.empty"))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mobile.settings.modules.empty")
                }
                ForEach(
                    model.optionalModulesAvailableForPreference()
                ) { module in
                    Toggle(
                        isOn: Binding(
                            get: { model.settingsStore.isVisible(module) },
                            set: { model.setModule(module, isVisible: $0) }
                        )
                    ) {
                        Label(module.title, systemImage: module.systemImage)
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("mobile.settings.module.\(module.rawValue)")
                }
                Button(L10n.string("mobile.settings.modules.refresh")) {
                    Task { await model.refreshModuleAccess() }
                }
                .disabled(model.isLoadingModuleAccess)
                .accessibilityIdentifier("mobile.settings.modules.refresh")
            } header: {
                Text(L10n.string("mobile.settings.modules.title"))
            } footer: {
                Text(L10n.string("mobile.settings.modules.footer"))
            }

            Section {
                LabeledContent(L10n.string("mobile.settings.cache.photoThumbnails")) {
                    Text(cacheSizeText)
                }
                Button {
                    confirmsCacheClear = true
                } label: {
                    if model.settingsStore.isClearingCache {
                        Label(
                            L10n.string("mobile.settings.cache.clearing"),
                            systemImage: "hourglass"
                        )
                    } else {
                        Label(
                            L10n.string("mobile.settings.cache.clear"),
                            systemImage: "trash"
                        )
                    }
                }
                .frame(minHeight: 44)
                .disabled(
                    model.settingsStore.isClearingCache
                        || model.settingsStore.photoThumbnailCacheBytes == 0
                )
            } header: {
                Text(L10n.string("mobile.settings.cache.title"))
            } footer: {
                Text(L10n.string("mobile.settings.cache.footer"))
            }

            Section {
                NavigationLink {
                    MobileFilesSettingsView(app: model)
                } label: {
                    Label(L10n.string("mobile.files-location.title"), systemImage: "folder.badge.gearshape")
                }.accessibilityIdentifier("mobile.files-location.settings")
            }

            Section(L10n.string("mobile.settings.privacy.title")) {
                Label(
                    L10n.string("mobile.settings.privacy.summary"),
                    systemImage: "lock.shield"
                )
                if let error = model.extensionAccessError {
                    Text(error).foregroundStyle(.secondary)
                        .accessibilityIdentifier("mobile.extensions.error")
                }
            }
            Section {
                Button(L10n.string("ui.3ab8cc15939f3b5c"), role: .destructive) {
                    model.logout()
                }
            }
        }
        .accessibilityIdentifier("mobile.settings.page")
        .task {
            await model.refreshModuleAccess()
            await model.chatModel.notifications.refreshAuthorization()
            if model.chatModel.notifications.enabled { await model.chatModel.reloadConversations() }
            await model.refreshSettingsCacheSummary()
        }
        .confirmationDialog(
            L10n.string("mobile.settings.cache.clearConfirmTitle"),
            isPresented: $confirmsCacheClear,
            titleVisibility: .visible
        ) {
            Button(L10n.string("mobile.settings.cache.clear"), role: .destructive) {
                Task { await model.clearRegenerableCaches() }
            }
            Button(L10n.string("mobile.settings.cache.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("mobile.settings.cache.clearConfirmMessage"))
        }
        .alert(
            cacheResultTitle,
            isPresented: Binding(
                get: { model.settingsStore.cacheResult != nil },
                set: { if !$0 { model.settingsStore.cacheResult = nil } }
            )
        ) {
            Button(L10n.string("mobile.settings.cache.dismiss")) {
                model.settingsStore.cacheResult = nil
            }
        }
    }

    private var cacheSizeText: String {
        model.settingsStore.photoThumbnailCacheBytes.formatted(
            .byteCount(style: .file).locale(L10n.locale)
        )
    }

    private var cacheResultTitle: String {
        switch model.settingsStore.cacheResult {
        case .success: L10n.string("mobile.settings.cache.clearSuccess")
        case .failure: L10n.string("mobile.settings.cache.clearFailed")
        case nil: ""
        }
    }
}
