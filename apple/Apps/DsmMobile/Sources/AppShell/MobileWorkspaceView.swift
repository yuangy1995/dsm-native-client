import DsmCore
import DsmLocalization
import SwiftUI

struct MobileWorkspaceView: View {
    @Bindable var model: MobileAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var profileToRemove: NasProfile?

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularWorkspace
            } else {
                compactWorkspace
            }
        }
        .overlay(alignment: .top) {
            if model.actionInProgress {
                ProgressView()
                    .controlSize(.small)
                    .padding(10)
                    .background(.regularMaterial, in: .capsule)
                    .padding(.top, 8)
                    .accessibilityLabel(L10n.string("ui.36b7dfe53cf9b5df"))
            }
        }
        .alert(
            L10n.string("ui.f56c6c82203b33f6"),
            isPresented: Binding(
                get: { model.message != nil },
                set: { if !$0 { model.message = nil } }
            )
        ) {
            Button(L10n.string("ui.f867f34178594f89")) {
                model.message = nil
            }
        } message: {
            Text(model.message ?? "")
        }
        .confirmationDialog(
            L10n.string(
                "profile.remove.confirm",
                profileToRemove?.displayName ?? ""
            ),
            isPresented: Binding(
                get: { profileToRemove != nil },
                set: { if !$0 { profileToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.6135d4159e892541"), role: .destructive) {
                if let profileToRemove {
                    model.removeProfile(profileToRemove)
                }
                profileToRemove = nil
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {
                profileToRemove = nil
            }
        } message: {
            Text(L10n.string("ui.1a6ef7d4ed0db37d"))
        }
    }

    private var compactWorkspace: some View {
        TabView(selection: topLevelSelection) {
            primaryTab(.files)
            primaryTab(.photos)
            primaryTab(.chat)
            groupedTab(.activity)
            groupedTab(.more)
        }
    }

    private var regularWorkspace: some View {
        NavigationSplitView {
            List {
                ForEach(MobileTopLevelDestination.allCases) { destination in
                    Button {
                        model.selectTopLevel(destination)
                    } label: {
                        Label(destination.title, systemImage: destination.systemImage)
                    }
                    .foregroundStyle(model.selectedTopLevel == destination ? .blue : .primary)
                    .accessibilityAddTraits(model.selectedTopLevel == destination ? .isSelected : [])
                }
            }
            .navigationTitle(
                model.activeProfile?.displayName ?? L10n.string("ui.4aeb6d92cbbff699")
            )
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    profileMenu
                }
            }
        } detail: {
            destinationContent(model.selectedTopLevel)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private func primaryTab(_ destination: MobileTopLevelDestination) -> some View {
        NavigationStack {
            moduleDetail(destination.defaultModule)
                .navigationTitle(destination.title)
                .navigationBarTitleDisplayMode(.inline)
        }
        .tabItem {
            Label(destination.title, systemImage: destination.systemImage)
        }
        .tag(destination)
    }

    private func groupedTab(_ destination: MobileTopLevelDestination) -> some View {
        NavigationStack {
            childModuleList(destination)
                .navigationTitle(destination.title)
                .navigationDestination(for: MobileModule.self) { module in
                    moduleDetail(module)
                        .navigationTitle(module.title)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        profileMenu
                    }
                }
        }
        .tabItem {
            Label(destination.title, systemImage: destination.systemImage)
        }
        .tag(destination)
    }

    @ViewBuilder
    private func destinationContent(_ destination: MobileTopLevelDestination) -> some View {
        switch destination {
        case .files, .photos, .chat:
            moduleDetail(destination.defaultModule)
                .navigationTitle(destination.title)
        case .activity, .more:
            NavigationStack {
                childModuleList(destination)
                    .navigationTitle(destination.title)
                    .navigationDestination(for: MobileModule.self) { module in
                        moduleDetail(module)
                            .navigationTitle(module.title)
                    }
            }
        }
    }

    private func childModuleList(_ destination: MobileTopLevelDestination) -> some View {
        List {
            ForEach(model.visibleChildModules(for: destination)) { module in
                NavigationLink(value: module) {
                    Label(module.title, systemImage: module.systemImage)
                }
                .simultaneousGesture(TapGesture().onEnded {
                    model.selectModule(module)
                })
            }
        }
    }

    private var topLevelSelection: Binding<MobileTopLevelDestination> {
        Binding(
            get: { model.selectedTopLevel },
            set: { model.selectTopLevel($0) }
        )
    }

    private var profileMenu: some View {
        Menu {
            Section(L10n.string("ui.df2b9b2dc2e69cf5")) {
                ForEach(model.profiles) { profile in
                    Button {
                        model.switchProfile(profile)
                    } label: {
                        if profile.id == model.activeProfile?.id {
                            Label(profile.displayName, systemImage: "checkmark")
                        } else {
                            Text(profile.displayName)
                        }
                    }
                    .disabled(profile.id == model.activeProfile?.id)
                }
            }
            Button {
                model.beginNewProfile()
            } label: {
                Label(L10n.string("mobile.profile.add"), systemImage: "plus")
            }
            Menu {
                ForEach(model.profiles) { profile in
                    Button(profile.displayName, role: .destructive) {
                        profileToRemove = profile
                    }
                }
            } label: {
                Label(
                    L10n.string("ui.06a972a9c2683c33"),
                    systemImage: "trash"
                )
            }
            Divider()
            Button(role: .destructive) {
                model.logout()
            } label: {
                Label(
                    L10n.string("ui.3ab8cc15939f3b5c"),
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
            }
        } label: {
            Label(
                model.activeProfile?.displayName ?? L10n.string("ui.df2b9b2dc2e69cf5"),
                systemImage: "externaldrive.connected.to.line.below"
            )
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    @ViewBuilder
    private func moduleDetail(_ module: MobileModule) -> some View {
        ZStack {
            switch module {
            case .files:
                MobileFileBrowser(model: model)
            case .photos:
                MobilePhotosView(model: model)
            case .chat:
                MobileChatView(model: model)
            case .downloads:
                MobileDownloadsView(model: model)
            case .containers:
                MobileContainersView(inventory: model.containerInventoryModel)
            case .virtualMachines:
                MobileVirtualMachinesView(inventory: model.virtualMachineInventoryModel)
            case .nasSettings:
                MobileNasSettingsView(model: model)
            case .transfers:
                MobileActivityView(model: model)
            case .settings:
                MobileSettingsView(model: model)
            }
            if model.isLoading,
               module != .chat,
               module != .nasSettings,
               module != .containers {
                ProgressView(L10n.string("ui.86b6d0d63062ba81"))
                    .padding(20)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
            }
        }
        .toolbar {
            if horizontalSizeClass != .regular {
                ToolbarItem(placement: .topBarLeading) {
                    profileMenu
                }
            }
            if module != .chat, module != .settings, module != .transfers {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if module == .nasSettings {
                            Task { await model.nasHealthModel.refresh() }
                        } else if module == .containers {
                            Task { await model.containerInventoryModel.refresh() }
                        } else if module == .virtualMachines {
                            Task { await model.virtualMachineInventoryModel.refresh() }
                        } else {
                            model.selectModule(module)
                        }
                    } label: {
                        if module == .containers,
                           (model.containerInventoryModel.state.pageState == .loading ||
                            model.containerInventoryModel.state.isRefreshing) {
                            ProgressView()
                                .accessibilityHidden(true)
                        } else if module == .virtualMachines,
                                  model.virtualMachineInventoryModel.state.isRefreshing {
                            ProgressView()
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(
                        (module == .containers &&
                            (model.containerInventoryModel.state.pageState == .loading ||
                             model.containerInventoryModel.state.isRefreshing)) ||
                        (module == .virtualMachines &&
                            model.virtualMachineInventoryModel.state.isRefreshing)
                    )
                    .accessibilityLabel(L10n.string("ui.aee88743413144a2"))
                    .accessibilityValue(
                        module == .containers &&
                            (model.containerInventoryModel.state.pageState == .loading ||
                             model.containerInventoryModel.state.isRefreshing)
                            ? L10n.string("mobile.containers.loading")
                            : ""
                    )
                }
            }
        }
    }
}
