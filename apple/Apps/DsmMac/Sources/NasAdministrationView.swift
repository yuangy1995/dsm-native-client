import Charts
import DsmCore
import SwiftUI
import DsmLocalization

struct NasSettingsView: View {
    @Bindable var model: NasSettingsModel

    var body: some View {
        NasAdministrationSplitView(
            pages: NasSettingsPage.allCases,
            selection: $model.selectedPage,
            label: pageLabel
        ) {
            settingsPage
        }
        .task(id: model.selectedPage) {
            await model.activate(model.selectedPage)
        }
        .task(id: "\(model.selectedPage.rawValue)-\(model.isLiveUpdatesPaused)") {
            let refreshablePages: Set<NasSettingsPage> = [.overview, .logs, .connections]
            guard refreshablePages.contains(model.selectedPage) else { return }
            if model.selectedPage == .overview, model.isLiveUpdatesPaused { return }
            while !Task.isCancelled, model.isModuleEnabled {
                do {
                    try await Task.sleep(for: .seconds(model.selectedPage == .overview ? 2 : 15))
                } catch {
                    return
                }
                if model.selectedPage == .overview {
                    await model.refreshPerformance()
                } else {
                    await model.activate(force: true)
                }
            }
        }
    }

    @ViewBuilder
    private var settingsPage: some View {
        switch model.selectedPage {
        case .overview:
            AdministrationPageContainer(
                isLoading: model.isLoading(.overview) || model.performanceIsLoading,
                hasLoaded: model.hasLoaded(.overview),
                hasContent: model.overview != nil,
                errorMessage: model.errorMessage(for: .overview),
                emptyTitle: L10n.string("ui.d39ec043f1522ee0"),
                emptyDescription: L10n.string("ui.041c8bf2f9cd31f3"),
                retry: { await model.activate(.overview, force: true) }
            ) {
                PerformanceDashboard(
                    overview: model.overview,
                    history: model.performanceHistory,
                    connections: model.connections,
                    isPaused: $model.isLiveUpdatesPaused,
                    refresh: { await model.activate(.overview, force: true) },
                    onNavigateToConnections: { model.selectedPage = .connections },
                    isPowerActionBusy: model.isPerformingPowerAction,
                    onPerformPowerAction: { action in
                        try await model.performPowerAction(action)
                    },
                    onCheckSystemUpdate: { try await model.checkSystemUpdate() }
                )
            }
        case .storage:
            AdministrationPageContainer(
                isLoading: model.isLoading(.storage),
                hasLoaded: model.hasLoaded(.storage),
                hasContent: model.storage != nil,
                errorMessage: model.errorMessage(for: .storage),
                emptyTitle: L10n.string("ui.aede80dd80411e6d"),
                emptyDescription: L10n.string("ui.8b8547f2f11eaa28"),
                retry: { await model.activate(.storage, force: true) }
            ) {
                UnifiedStorageView(
                    snapshot: model.storage,
                    usageHistory: model.storageUsageHistory,
                    analysis: model.storageAnalysis,
                    analysisProgress: model.storageAnalysisProgress,
                    analysisError: model.storageAnalysisError,
                    isAnalyzing: model.isAnalyzingStorage,
                    testStatuses: model.diskTestStatuses,
                    busyDiskIDs: model.diskOperationIDs,
                    refresh: { await model.activate(.storage, force: true) },
                    beginAnalysis: model.beginStorageAnalysis,
                    cancelAnalysis: model.cancelStorageAnalysis,
                    loadTestStatus: { diskID in
                        _ = try await model.loadDiskTestStatus(diskID: diskID)
                    },
                    startTest: { diskID, type in
                        try await model.startDiskTest(diskID: diskID, type: type)
                    },
                    stopTest: { diskID in
                        try await model.stopDiskTest(diskID: diskID)
                    }
                )
            }
        case .externalStorage:
            AdministrationPageContainer(
                isLoading: model.isLoading(.externalStorage),
                hasLoaded: model.hasLoaded(.externalStorage),
                hasContent: model.externalStorage != nil,
                errorMessage: model.errorMessage(for: .externalStorage),
                emptyTitle: L10n.string("external-storage.empty-title"),
                emptyDescription: L10n.string("external-storage.empty-description"),
                retry: { await model.activate(.externalStorage, force: true) }
            ) {
                if let directory = model.externalStorage {
                    ExternalStorageView(
                        directory: directory,
                        isRefreshing: model.isLoading(.externalStorage),
                        refresh: {
                            await model.activate(.externalStorage, force: true)
                        }
                    )
                }
            }
        case .zram:
            AdministrationPageContainer(
                isLoading: model.isLoading(.zram),
                hasLoaded: model.hasLoaded(.zram),
                hasContent: model.zram.map(hasZRAMContent) ?? false,
                errorMessage: model.errorMessage(for: .zram),
                emptyTitle: L10n.string("zram.empty-title"),
                emptyDescription: L10n.string("zram.empty-description"),
                retry: { await model.activate(.zram, force: true) }
            ) {
                if let snapshot = model.zram {
                    ZRAMView(
                        snapshot: snapshot,
                        isRefreshing: model.isLoading(.zram),
                        refresh: { await model.activate(.zram, force: true) }
                    )
                }
            }
        case .fileServices:
            AdministrationPageContainer(
                isLoading: model.isLoading(.fileServices),
                hasLoaded: model.hasLoaded(.fileServices),
                hasContent: model.fileServices != nil,
                errorMessage: model.errorMessage(for: .fileServices),
                emptyTitle: L10n.string("ui.f0e2dfb1f52b1108"),
                emptyDescription: L10n.string("ui.7ef72eb2313692a3"),
                retry: { await model.activate(.fileServices, force: true) }
            ) {
                if let settings = model.fileServices {
                    FileServiceSettingsView(
                        settings: settings,
                        isSaving: model.isSavingServiceSettings,
                        onSave: { try await model.saveFileServices($0) }
                    )
                    .id(settings)
                }
            }
        case .terminal:
            AdministrationPageContainer(
                isLoading: model.isLoading(.terminal),
                hasLoaded: model.hasLoaded(.terminal),
                hasContent: model.terminal != nil,
                errorMessage: model.errorMessage(for: .terminal),
                emptyTitle: L10n.string("ui.0ea953130a6f50b8"),
                emptyDescription: L10n.string("ui.55b016ae17c67bb3"),
                retry: { await model.activate(.terminal, force: true) }
            ) {
                if let settings = model.terminal {
                    TerminalSettingsView(
                        settings: settings,
                        isSaving: model.isSavingServiceSettings,
                        onSave: { try await model.saveTerminal($0) }
                    )
                    .id(settings)
                }
            }
        case .network:
            AdministrationPageContainer(
                isLoading: model.isLoading(.network),
                hasLoaded: model.hasLoaded(.network),
                hasContent: model.proxy != nil,
                errorMessage: model.errorMessage(for: .network),
                emptyTitle: L10n.string("ui.88097fae00b3d400"),
                emptyDescription: L10n.string("ui.1ed9a37b7b4cdfa5"),
                retry: { await model.activate(.network, force: true) }
            ) {
                if let settings = model.proxy {
                    ProxySettingsView(
                        settings: settings,
                        isSaving: model.isSavingServiceSettings,
                        onSave: { try await model.saveProxy($0) }
                    )
                    .id(settings)
                }
            }
        case .interfaces:
            AdministrationPageContainer(
                isLoading: model.isLoading(.interfaces),
                hasLoaded: model.hasLoaded(.interfaces),
                hasContent: !model.ethernetInterfaces.isEmpty,
                errorMessage: model.errorMessage(for: .interfaces),
                emptyTitle: L10n.string("ui.7854d2b9b333a8b1"),
                emptyDescription: L10n.string("ui.fa76ab3ce1663dbb"),
                retry: { await model.activate(.interfaces, force: true) }
            ) {
                EthernetInterfacesView(
                    interfaces: model.ethernetInterfaces,
                    busyIDs: model.networkOperationIDs,
                    onSave: { try await model.saveEthernetInterface($0) }
                )
            }
        case .hardware:
            AdministrationPageContainer(
                isLoading: model.isLoading(.hardware),
                hasLoaded: model.hasLoaded(.hardware),
                hasContent: model.hardware != nil,
                errorMessage: model.errorMessage(for: .hardware),
                emptyTitle: L10n.string("ui.f94427fd03a0c5ff"),
                emptyDescription: L10n.string("ui.e7b0de9ae1975b01"),
                retry: { await model.activate(.hardware, force: true) }
            ) {
                if let settings = model.hardware {
                    HardwareSettingsView(
                        settings: settings,
                        isSaving: model.isSavingServiceSettings,
                        onSave: { try await model.saveHardware($0) }
                    )
                    .id(settings)
                }
            }
        case .powerSchedule:
            AdministrationPageContainer(
                isLoading: model.isLoading(.powerSchedule),
                hasLoaded: model.hasLoaded(.powerSchedule),
                hasContent: !(model.powerSchedule?.entries.isEmpty ?? true),
                errorMessage: model.errorMessage(for: .powerSchedule),
                emptyTitle: L10n.string("power-schedule.empty-title"),
                emptyDescription: L10n.string("power-schedule.empty-description"),
                retry: { await model.activate(.powerSchedule, force: true) }
            ) {
                if let snapshot = model.powerSchedule {
                    PowerScheduleView(
                        snapshot: snapshot,
                        isRefreshing: model.isLoading(.powerSchedule),
                        refresh: { await model.activate(.powerSchedule, force: true) }
                    )
                }
            }
        case .remoteAccess:
            AdministrationPageContainer(
                isLoading: model.isLoading(.remoteAccess),
                hasLoaded: model.hasLoaded(.remoteAccess),
                hasContent: model.remoteAccess != nil,
                errorMessage: model.errorMessage(for: .remoteAccess),
                emptyTitle: L10n.string("ui.9887ff7ba209ca16"),
                emptyDescription: L10n.string("ui.9b9725c4100073a4"),
                retry: { await model.activate(.remoteAccess, force: true) }
            ) {
                if let settings = model.remoteAccess {
                    RemoteAccessSettingsView(
                        settings: settings,
                        isSaving: model.isSavingServiceSettings,
                        onSave: { try await model.saveRemoteAccess($0) }
                    )
                    .id(settings)
                }
            }
        case .security:
            AdministrationPageContainer(
                isLoading: model.isLoading(.security),
                hasLoaded: model.hasLoaded(.security),
                hasContent: model.security != nil,
                errorMessage: model.errorMessage(for: .security),
                emptyTitle: L10n.string("ui.d596c8dbd465788e"),
                emptyDescription: L10n.string("ui.1ab98de4a8545b85"),
                retry: { await model.activate(.security, force: true) }
            ) {
                if let settings = model.security {
                    SecuritySettingsView(
                        settings: settings,
                        isSaving: model.isSavingServiceSettings,
                        onSave: { try await model.saveSecurity($0) }
                    )
                    .id(settings)
                }
            }
        case .region:
            AdministrationPageContainer(
                isLoading: model.isLoading(.region),
                hasLoaded: model.hasLoaded(.region),
                hasContent: model.region != nil,
                errorMessage: model.errorMessage(for: .region),
                emptyTitle: L10n.string("ui.c3ad62ad1f7a1ab0"),
                emptyDescription: L10n.string("ui.f6e66a9bcbb3091e"),
                retry: { await model.activate(.region, force: true) }
            ) {
                if let settings = model.region {
                    RegionSettingsView(
                        settings: settings,
                        isSaving: model.isSavingServiceSettings,
                        onSave: { try await model.saveRegion($0) }
                    )
                    .id(settings)
                }
            }
        case .ddns:
            AdministrationPageContainer(
                isLoading: model.isLoading(.ddns),
                hasLoaded: model.hasLoaded(.ddns),
                hasContent: model.ddns != nil,
                errorMessage: model.errorMessage(for: .ddns),
                emptyTitle: L10n.string("ui.d22b2fd0eecfd121"),
                emptyDescription: L10n.string("ui.293c3b515139c342"),
                retry: { await model.activate(.ddns, force: true) }
            ) {
                if let directory = model.ddns {
                    DDNSSettingsView(
                        directory: directory,
                        busyIDs: model.ddnsOperationIDs,
                        onTest: { _ = try await model.testDDNS($0) },
                        onSave: { try await model.saveDDNS($0) },
                        onDelete: { try await model.deleteDDNS($0) },
                        onRefresh: { try await model.refreshDDNS() }
                    )
                    .id(directory)
                }
            }
        case .packages:
            AdministrationPageContainer(
                isLoading: model.isLoading(.packages),
                hasLoaded: model.hasLoaded(.packages),
                hasContent: !model.packages.isEmpty,
                errorMessage: model.errorMessage(for: .packages),
                emptyTitle: L10n.string("ui.11479f1067001e82"),
                emptyDescription: L10n.string("ui.3b75e4e910ab2c64"),
                retry: { await model.activate(.packages, force: true) }
            ) {
                PackageList(
                    packages: model.packages,
                    title: L10n.string("ui.7467e8310073e980"),
                    busyPackageIDs: model.packageOperationIDs,
                    onControlPackage: { id, action in
                        _ = try await model.controlPackage(id: id, action: action)
                    }
                )
            }
        case .tasks:
            AdministrationPageContainer(
                isLoading: model.isLoading(.tasks),
                hasLoaded: model.hasLoaded(.tasks),
                hasContent: !model.tasks.isEmpty,
                errorMessage: model.errorMessage(for: .tasks),
                emptyTitle: L10n.string("ui.c9cb0f813cc56383"),
                emptyDescription: L10n.string("ui.b9dc7b6c1ebbe871"),
                retry: { await model.activate(.tasks, force: true) }
            ) {
                ScheduledTaskList(
                    tasks: model.tasks,
                    busyTaskIDs: model.taskOperationIDs,
                    loadDraft: { task in try await model.loadTaskDraft(task) },
                    loadResults: { task in try await model.loadTaskResults(task) },
                    loadResultOutput: { task, resultID in
                        try await model.loadTaskResultOutput(task: task, resultID: resultID)
                    },
                    onSave: { draft in try await model.saveTask(draft) },
                    onSetEnabled: { task, enabled in
                        try await model.setTaskEnabled(task, enabled: enabled)
                    },
                    onRun: { task in try await model.runTask(task) },
                    onDelete: { task in try await model.deleteTask(task) }
                )
            }
        case .accounts:
            AdministrationPageContainer(
                isLoading: model.isLoading(.accounts),
                hasLoaded: model.hasLoaded(.accounts),
                hasContent: model.accounts.map { !$0.users.isEmpty || !$0.groups.isEmpty } ?? false,
                errorMessage: model.errorMessage(for: .accounts),
                emptyTitle: L10n.string("ui.e0e9deb2554cf77c"),
                emptyDescription: L10n.string("ui.58bfa48693373928"),
                retry: { await model.activate(.accounts, force: true) }
            ) {
                AccountDirectoryView(
                    directory: model.accounts,
                    busyAccountIDs: model.accountOperationIDs,
                    onSave: { draft in try await model.saveAccount(draft) },
                    onDelete: { account in try await model.deleteAccount(account) },
                    onSaveGroup: { draft in try await model.saveGroup(draft) },
                    onDeleteGroup: { group in try await model.deleteGroup(group) }
                )
            }
        case .shareAccess:
            AdministrationPageContainer(
                isLoading: model.isLoading(.shareAccess),
                hasLoaded: model.hasLoaded(.shareAccess),
                hasContent: !(model.shareAccess?.shares.isEmpty ?? true),
                errorMessage: model.errorMessage(for: .shareAccess),
                emptyTitle: L10n.string("share-access.empty-title"),
                emptyDescription: L10n.string("share-access.empty-description"),
                retry: { await model.activate(.shareAccess, force: true) }
            ) {
                if let directory = model.shareAccess {
                    ShareAccessView(directory: directory)
                }
            }
        case .processes:
            AdministrationPageContainer(
                isLoading: model.isLoading(.processes),
                hasLoaded: model.hasLoaded(.processes),
                hasContent: model.processDirectory.map {
                    !$0.processes.isEmpty || !$0.groups.isEmpty
                } ?? false,
                errorMessage: model.errorMessage(for: .processes),
                emptyTitle: L10n.string("processes.empty-title"),
                emptyDescription: L10n.string("processes.empty-description"),
                retry: { await model.activate(.processes, force: true) }
            ) {
                if let directory = model.processDirectory {
                    ProcessActivityView(
                        directory: directory,
                        isRefreshing: model.isLoading(.processes),
                        refresh: { await model.activate(.processes, force: true) }
                    )
                }
            }
        case .logs:
            AdministrationPageContainer(
                isLoading: model.isLoading(.logs),
                hasLoaded: model.hasLoaded(.logs),
                hasContent: !(model.logs?.entries.isEmpty ?? true),
                errorMessage: model.errorMessage(for: .logs),
                emptyTitle: L10n.string("ui.755c9c9b40dcab11"),
                emptyDescription: L10n.string("ui.cdadc6755931def3"),
                retry: { await model.activate(.logs, force: true) }
            ) {
                LogEntryList(
                    page: model.logs,
                    currentPage: model.logCurrentPage,
                    pageSize: model.logPageSize,
                    onFetchPage: { page, size in
                        await model.fetchLogs(page: page, pageSize: size)
                    }
                )
            }
        case .connections:
            AdministrationPageContainer(
                isLoading: model.isLoading(.connections),
                hasLoaded: model.hasLoaded(.connections),
                hasContent: !(model.connections?.connections.isEmpty ?? true),
                errorMessage: model.errorMessage(for: .connections),
                emptyTitle: L10n.string("ui.6927c3e0155db6ab"),
                emptyDescription: L10n.string("ui.b2e04250be336577"),
                retry: { await model.activate(.connections, force: true) }
            ) {
                ConnectionList(
                    page: model.connections,
                    busyConnectionIDs: model.connectionOperationIDs,
                    onDisconnect: { connection in
                        try await model.disconnectConnection(connection)
                    }
                )
            }
        }
    }

    private func pageLabel(_ page: NasSettingsPage) -> (String, String) {
        switch page {
        case .overview: (L10n.string("ui.582da2581a0cd0ee"), "gauge.with.dots.needle.67percent")
        case .storage: (L10n.string("ui.0e41f8e3d59ec47b"), "internaldrive")
        case .externalStorage: (
            L10n.string("external-storage.navigation-title"),
            "externaldrive"
        )
        case .zram: (L10n.string("zram.navigation-title"), "memorychip")
        case .fileServices: (L10n.string("ui.f771e808e831f599"), "folder.badge.gearshape")
        case .terminal: (L10n.string("ui.678b783fb578172b"), "terminal")
        case .network: (L10n.string("ui.841fb4ce271a4e64"), "network")
        case .interfaces: (L10n.string("ui.f4964357f24503a7"), "cable.connector")
        case .hardware: (L10n.string("ui.64979ca5c76a8342"), "powerplug")
        case .powerSchedule: (
            L10n.string("power-schedule.navigation-title"),
            "calendar.badge.clock"
        )
        case .remoteAccess: (L10n.string("ui.ce5a7298821d8644"), "network.badge.shield.half.filled")
        case .security: (L10n.string("ui.e09822e61214bb5f"), "lock.shield")
        case .region: (L10n.string("ui.6038c1b4b9e464f1"), "clock.badge.checkmark")
        case .ddns: (L10n.string("ui.fcea58116389894b"), "globe.badge.chevron.backward")
        case .packages: (L10n.string("ui.58be5abb3cf57752"), "shippingbox")
        case .tasks: (L10n.string("ui.b61129b1fbb2deea"), "calendar.badge.clock")
        case .accounts: (L10n.string("ui.4dc833d6dbb9f615"), "person.2")
        case .shareAccess: (L10n.string("share-access.navigation-title"), "folder.badge.person.crop")
        case .processes: (L10n.string("processes.navigation-title"), "gearshape.2")
        case .logs: (L10n.string("ui.366ada1d2fcfc4b3"), "doc.text.magnifyingglass")
        case .connections: (L10n.string("ui.e403ba5798ba13a4"), "network")
        }
    }
}

private func hasZRAMContent(_ snapshot: NasZRAMSnapshot) -> Bool {
    snapshot.isEnabled != nil
        || snapshot.configuredBytes != nil
        || snapshot.algorithm != .unknown
}

private struct ZRAMView: View {
    let snapshot: NasZRAMSnapshot
    let isRefreshing: Bool
    let refresh: () async -> Void

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("zram.title"))
                                .font(.title2.weight(.semibold))
                            Text(L10n.string("zram.description"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button {
                            Task { await refresh() }
                        } label: {
                            HStack(spacing: 6) {
                                if isRefreshing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text(L10n.string("zram.refresh"))
                            }
                        }
                        .disabled(isRefreshing)
                        .help(L10n.string("zram.refresh-help"))
                    }
                    Label(L10n.string("zram.read-only"), systemImage: "eye")
                        .font(.caption.weight(.medium))
                }
                .padding(.vertical, 4)
            }

            Section(L10n.string("zram.details-title")) {
                detailRow(
                    title: L10n.string("zram.status-title"),
                    value: statusText,
                    icon: statusIcon
                )
                detailRow(
                    title: L10n.string("zram.capacity-title"),
                    value: capacityText,
                    icon: "memorychip"
                )
                detailRow(
                    title: L10n.string("zram.algorithm-title"),
                    value: algorithmText,
                    icon: "archivebox"
                )
            }

            Section {
                Label(
                    L10n.string("zram.manage-in-dsm"),
                    systemImage: "info.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    private func detailRow(title: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("zram.row-accessibility", title, value))
    }

    private var statusText: String {
        switch snapshot.isEnabled {
        case .some(true): L10n.string("zram.status-enabled")
        case .some(false): L10n.string("zram.status-disabled")
        case .none: L10n.string("zram.value-unavailable")
        }
    }

    private var statusIcon: String {
        switch snapshot.isEnabled {
        case .some(true): "checkmark.circle"
        case .some(false): "pause.circle"
        case .none: "questionmark.circle"
        }
    }

    private var capacityText: String {
        snapshot.configuredBytes.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory)
        } ?? L10n.string("zram.value-unavailable")
    }

    private var algorithmText: String {
        switch snapshot.algorithm {
        case .lz4: L10n.string("zram.algorithm-lz4")
        case .lzo: L10n.string("zram.algorithm-lzo")
        case .zstd: L10n.string("zram.algorithm-zstd")
        case .unknown: L10n.string("zram.value-unavailable")
        }
    }
}

private struct ExternalStorageView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case usb
        case eSATA

        var id: Self { self }
    }

    let directory: NasExternalStorageDirectory
    let isRefreshing: Bool
    let refresh: () async -> Void

    @State private var filter: Filter = .all

    private var filteredDevices: [NasExternalStorageDevice] {
        switch filter {
        case .all:
            directory.devices
        case .usb:
            directory.devices.filter { $0.connection == .usb }
        case .eSATA:
            directory.devices.filter { $0.connection == .eSATA }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if directory.devices.isEmpty {
                ContentUnavailableView(
                    L10n.string("external-storage.empty-title"),
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text(
                        L10n.string("external-storage.empty-description")
                    )
                )
                .fillsAvailableContentArea()
            } else if filteredDevices.isEmpty {
                ContentUnavailableView(
                    L10n.string("external-storage.filtered-empty-title"),
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(
                        L10n.string("external-storage.filtered-empty-description")
                    )
                )
                .fillsAvailableContentArea()
            } else {
                List {
                    Section(L10n.string("external-storage.list-title")) {
                        ForEach(filteredDevices) { device in
                            deviceRow(device)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("external-storage.title"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.string("external-storage.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    Task { await refresh() }
                } label: {
                    HStack(spacing: 6) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(L10n.string("external-storage.refresh"))
                    }
                }
                .disabled(isRefreshing)
                .help(L10n.string("external-storage.refresh-help"))
            }

            HStack(spacing: 8) {
                Label(
                    L10n.string("external-storage.read-only"),
                    systemImage: "eye"
                )
                .font(.caption.weight(.medium))

                Text(
                    L10n.string(
                        "external-storage.count",
                        String(describing: directory.total)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Picker(
                L10n.string("external-storage.filter-title"),
                selection: $filter
            ) {
                ForEach(Filter.allCases) { item in
                    Text(filterLabel(item)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            if directory.isTruncated {
                warningLabel(
                    L10n.string("external-storage.truncated"),
                    systemImage: "list.bullet.rectangle"
                )
            }

            if !directory.unavailableConnections.isEmpty {
                warningLabel(
                    L10n.string(
                        "external-storage.partial-unavailable",
                        directory.unavailableConnections
                            .map(connectionLabel)
                            .joined(separator: L10n.string("external-storage.separator"))
                    ),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .padding(16)
    }

    private func warningLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func filterLabel(_ value: Filter) -> String {
        switch value {
        case .all: L10n.string("external-storage.filter-all")
        case .usb: L10n.string("external-storage.connection-usb")
        case .eSATA: L10n.string("external-storage.connection-esata")
        }
    }

    private func deviceRow(_ device: NasExternalStorageDevice) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: device.connection == .usb ? "externaldrive" : "externaldrive.connected.to.line.below")
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName ?? L10n.string("external-storage.unnamed-device"))
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Text(capacityDescription(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Label(statusText(device.status), systemImage: statusIcon(device.status))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(connectionLabel(device.connection))
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.string(
                "external-storage.row-accessibility",
                device.displayName ?? L10n.string("external-storage.unnamed-device"),
                connectionLabel(device.connection),
                statusText(device.status),
                capacityDescription(device)
            )
        )
    }

    private func connectionLabel(_ connection: NasExternalStorageConnection) -> String {
        switch connection {
        case .usb: L10n.string("external-storage.connection-usb")
        case .eSATA: L10n.string("external-storage.connection-esata")
        }
    }

    private func statusText(_ status: NasExternalStorageStatus) -> String {
        switch status {
        case .ready: L10n.string("external-storage.status-ready")
        case .busy: L10n.string("external-storage.status-busy")
        case .unavailable: L10n.string("external-storage.status-unavailable")
        case .unknown: L10n.string("external-storage.status-unknown")
        }
    }

    private func statusIcon(_ status: NasExternalStorageStatus) -> String {
        switch status {
        case .ready: "checkmark.circle"
        case .busy: "clock"
        case .unavailable: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }

    private func capacityDescription(_ device: NasExternalStorageDevice) -> String {
        guard let capacity = device.capacityBytes else {
            return L10n.string("external-storage.capacity-unavailable")
        }
        if let used = device.usedBytes {
            return L10n.string(
                "external-storage.capacity-used",
                byteCount(used),
                byteCount(capacity)
            )
        }
        return L10n.string("external-storage.capacity-total", byteCount(capacity))
    }

    private func byteCount(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: value)
    }
}

private struct PowerScheduleView: View {
    private enum Filter: String, CaseIterable, Identifiable {
        case all
        case enabled
        case disabled

        var id: Self { self }
    }

    let snapshot: NasPowerScheduleSnapshot
    let isRefreshing: Bool
    let refresh: () async -> Void

    @State private var filter: Filter = .all

    private var filteredEntries: [NasPowerScheduleEntry] {
        switch filter {
        case .all:
            snapshot.entries
        case .enabled:
            snapshot.entries.filter { $0.isEnabled == true }
        case .disabled:
            snapshot.entries.filter { $0.isEnabled == false }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    L10n.string("power-schedule.filtered-empty-title"),
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text(
                        L10n.string("power-schedule.filtered-empty-description")
                    )
                )
                .fillsAvailableContentArea()
            } else {
                List {
                    Section(L10n.string("power-schedule.list-title")) {
                        ForEach(filteredEntries) { entry in
                            scheduleRow(entry)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("power-schedule.title"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.string("power-schedule.description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    Task { await refresh() }
                } label: {
                    HStack(spacing: 6) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(L10n.string("power-schedule.refresh"))
                    }
                }
                .disabled(isRefreshing)
                .help(L10n.string("power-schedule.refresh-help"))
            }

            HStack(spacing: 8) {
                Label(
                    L10n.string("power-schedule.read-only"),
                    systemImage: "eye"
                )
                .font(.caption.weight(.medium))

                Text(
                    L10n.string(
                        "power-schedule.count",
                        String(describing: snapshot.total)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Divider()
                    .frame(height: 12)
                    .accessibilityHidden(true)

                Text(timeZoneDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Picker(L10n.string("power-schedule.filter-title"), selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text(filterLabel(item)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            if snapshot.isTruncated {
                Label(
                    L10n.string("power-schedule.truncated"),
                    systemImage: "list.bullet.rectangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private var timeZoneDescription: String {
        if let timeZoneIdentifier = snapshot.timeZoneIdentifier {
            return L10n.string("power-schedule.time-zone", timeZoneIdentifier)
        }
        return L10n.string("power-schedule.time-zone-unavailable")
    }

    private func filterLabel(_ filter: Filter) -> String {
        switch filter {
        case .all: L10n.string("power-schedule.filter-all")
        case .enabled: L10n.string("power-schedule.filter-enabled")
        case .disabled: L10n.string("power-schedule.filter-disabled")
        }
    }

    private func scheduleRow(_ entry: NasPowerScheduleEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: actionIcon(entry.action))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(actionLabel(entry.action))
                    .font(.body.weight(.medium))
                Text(recurrenceLabel(entry.recurrence))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(timeLabel(hour: entry.hour, minute: entry.minute))
                .font(.body.monospacedDigit().weight(.medium))

            statusLabel(entry.isEnabled)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.string(
                "power-schedule.row-accessibility",
                actionLabel(entry.action),
                timeLabel(hour: entry.hour, minute: entry.minute),
                recurrenceLabel(entry.recurrence),
                statusText(entry.isEnabled)
            )
        )
    }

    private func actionIcon(_ action: NasPowerScheduleAction) -> String {
        switch action {
        case .startup: "power"
        case .shutdown: "power.circle"
        case .restart: "arrow.clockwise.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private func actionLabel(_ action: NasPowerScheduleAction) -> String {
        switch action {
        case .startup: L10n.string("power-schedule.action-startup")
        case .shutdown: L10n.string("power-schedule.action-shutdown")
        case .restart: L10n.string("power-schedule.action-restart")
        case .unknown: L10n.string("power-schedule.action-unknown")
        }
    }

    private func statusLabel(_ enabled: Bool?) -> some View {
        Label(statusText(enabled), systemImage: statusIcon(enabled))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private func statusText(_ enabled: Bool?) -> String {
        switch enabled {
        case .some(true): L10n.string("power-schedule.status-enabled")
        case .some(false): L10n.string("power-schedule.status-disabled")
        case .none: L10n.string("power-schedule.status-unknown")
        }
    }

    private func statusIcon(_ enabled: Bool?) -> String {
        switch enabled {
        case .some(true): "checkmark.circle"
        case .some(false): "pause.circle"
        case .none: "questionmark.circle"
        }
    }

    private func recurrenceLabel(_ recurrence: NasPowerScheduleRecurrence) -> String {
        switch recurrence {
        case .daily:
            return L10n.string("power-schedule.recurrence-daily")
        case .weekly(let weekdays):
            return weekdays.map(weekdayLabel).joined(
                separator: L10n.string("power-schedule.weekday-separator")
            )
        case .once(let date):
            return dateLabel(date)
        case .unknown:
            return L10n.string("power-schedule.recurrence-unknown")
        }
    }

    private func weekdayLabel(_ weekday: NasWeekday) -> String {
        switch weekday {
        case .monday: L10n.string("power-schedule.weekday-monday")
        case .tuesday: L10n.string("power-schedule.weekday-tuesday")
        case .wednesday: L10n.string("power-schedule.weekday-wednesday")
        case .thursday: L10n.string("power-schedule.weekday-thursday")
        case .friday: L10n.string("power-schedule.weekday-friday")
        case .saturday: L10n.string("power-schedule.weekday-saturday")
        case .sunday: L10n.string("power-schedule.weekday-sunday")
        }
    }

    private func timeLabel(hour: Int, minute: Int) -> String {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = 2001
        components.month = 1
        components.day = 1
        components.hour = hour
        components.minute = minute
        guard let date = components.date else {
            return String(format: "%02d:%02d", hour, minute)
        }
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
            .locale(AppLanguageStore.shared.locale)
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }

    private func dateLabel(_ value: NasPowerScheduleDate) -> String {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = value.year
        components.month = value.month
        components.day = value.day
        guard let date = components.date else {
            return L10n.string("power-schedule.recurrence-unknown")
        }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
            .locale(AppLanguageStore.shared.locale)
        style.timeZone = TimeZone(secondsFromGMT: 0)!
        return date.formatted(style)
    }
}

private struct ProcessActivityView: View {
    let directory: NasProcessDirectory
    let isRefreshing: Bool
    let refresh: () async -> Void

    @State private var searchText = ""

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredProcesses: [NasSystemProcess] {
        guard !normalizedSearch.isEmpty else { return directory.processes }
        return directory.processes.filter { process in
            [
                process.name,
                process.processID,
                process.status,
                process.groupID
            ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(normalizedSearch) }
        }
    }

    private var filteredGroups: [NasProcessGroup] {
        guard !normalizedSearch.isEmpty else { return directory.groups }
        return directory.groups.filter { group in
            [group.name, group.id, group.status]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(normalizedSearch) }
        }
    }

    private var hasFilteredContent: Bool {
        !filteredProcesses.isEmpty || !filteredGroups.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            processHeader
            Divider()

            if hasFilteredContent {
                List {
                    if !filteredGroups.isEmpty {
                        Section(L10n.string("processes.groups-title")) {
                            ForEach(filteredGroups) { group in
                                processGroupRow(group)
                            }
                        }
                    }

                    if !filteredProcesses.isEmpty {
                        Section(L10n.string("processes.list-title")) {
                            ForEach(filteredProcesses) { process in
                                processRow(process)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                ContentUnavailableView(
                    L10n.string("processes.filtered-empty-title"),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.string("processes.filtered-empty-description"))
                )
                .fillsAvailableContentArea()
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: L10n.string("processes.search-prompt")
        )
    }

    private var processHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("processes.title"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.string("processes.privacy-description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    Task { await refresh() }
                } label: {
                    HStack(spacing: 6) {
                        if isRefreshing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(L10n.string("processes.refresh"))
                    }
                }
                .disabled(isRefreshing)
                .help(L10n.string("processes.refresh-help"))
            }

            HStack(spacing: 8) {
                Label(
                    L10n.string("processes.read-only"),
                    systemImage: "eye"
                )
                .font(.caption.weight(.medium))

                Text(
                    L10n.string(
                        "processes.count",
                        String(describing: directory.total)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if directory.isTruncated {
                processNotice(
                    L10n.string("processes.truncated"),
                    systemImage: "list.bullet.rectangle"
                )
            }

            if directory.groupsAreUnavailable {
                processNotice(
                    L10n.string("processes.groups-unavailable"),
                    systemImage: "info.circle"
                )
            }
        }
        .padding(16)
    }

    private func processNotice(
        _ message: String,
        systemImage: String
    ) -> some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }

    private func processRow(_ process: NasSystemProcess) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "gearshape")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(process.name)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Text(
                        L10n.string(
                            "processes.process-id",
                            String(describing: process.processID)
                        )
                    )
                    if let groupID = process.groupID {
                        Text(
                            L10n.string(
                                "processes.group-name",
                                String(describing: groupID)
                            )
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }

            Spacer()

            if let status = process.status {
                processStatus(status)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func processGroupRow(_ group: NasProcessGroup) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                if let processCount = group.processCount {
                    Text(
                        L10n.string(
                            "processes.group-count",
                            String(describing: processCount)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let status = group.status {
                processStatus(status)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func processStatus(_ status: String) -> some View {
        Text(status)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
            .textSelection(.enabled)
    }
}

private struct ShareAccessView: View {
    let directory: NasShareAccessDirectory

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        L10n.string("share-access.scope-title"),
                        systemImage: "person.crop.circle.badge.checkmark"
                    )
                    .font(.headline)
                    Text(L10n.string("share-access.scope-description"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section(L10n.string("share-access.list-title")) {
                ForEach(directory.shares) { share in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: icon(for: share.accessLevel))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(share.name)
                                .font(.body.weight(.medium))
                                .textSelection(.enabled)
                            Text(accessText(for: share.accessLevel))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        if share.canDelete {
                            Label(
                                L10n.string("share-access.can-delete"),
                                systemImage: "trash"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(for: share))
                }
            }
        }
        .listStyle(.inset)
        .fillsAvailableContentArea(alignment: .topLeading)
    }

    private func icon(for accessLevel: NasShareAccessLevel) -> String {
        switch accessLevel {
        case .readWrite: "pencil.and.outline"
        case .readOnly: "eye"
        case .unknown: "questionmark.circle"
        }
    }

    private func accessText(for accessLevel: NasShareAccessLevel) -> String {
        switch accessLevel {
        case .readWrite: L10n.string("share-access.read-write")
        case .readOnly: L10n.string("share-access.read-only")
        case .unknown: L10n.string("share-access.unknown")
        }
    }

    private func accessibilityLabel(for share: NasShareAccessEntry) -> String {
        let key = share.canDelete
            ? "share-access.row-accessibility-delete"
            : "share-access.row-accessibility"
        return L10n.string(key, share.name, accessText(for: share.accessLevel))
    }
}

private struct EthernetInterfacesView: View {
    let interfaces: [NasEthernetInterface]
    let busyIDs: Set<String>
    let onSave: (NasEthernetInterface) async throws -> Void
    @State private var editing: NasEthernetInterface?

    var body: some View {
        List(interfaces) { interface in
            HStack(spacing: 14) {
                Image(systemName: "cable.connector")
                    .font(.title3)
                    .foregroundStyle(interface.status == "connected" ? .green : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(interface.displayName)
                        .font(.headline)
                    Text(interface.usesDHCP
                        ? L10n.string(
                            "network.address.automatic",
                            interface.address.isEmpty
                                ? L10n.string("network.address.unassigned")
                                : interface.address
                        )
                        : "\(interface.address) · \(interface.subnetMask)")
                        .foregroundStyle(.secondary)
                    Text("MTU \(interface.mtu)"
                        + (interface.isVLANEnabled ? " · VLAN \(interface.vlanID ?? 0)" : ""))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(busyIDs.contains("network:\(interface.id)") ? 1 : 0)
                Button(L10n.string("ui.051836569928a9f9")) { editing = interface }
                    .disabled(busyIDs.contains("network:\(interface.id)"))
            }
            .padding(.vertical, 5)
        }
        .sheet(isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            if let interface = editing {
                EthernetInterfaceEditor(
                    interface: interface,
                    onCancel: { editing = nil },
                    onSave: {
                        try await onSave($0)
                        editing = nil
                    }
                )
            }
        }
    }
}

private struct EthernetInterfaceEditor: View {
    @State private var draft: NasEthernetInterface
    @State private var isSaving = false
    @State private var isConfirming = false
    @State private var errorMessage: String?
    let original: NasEthernetInterface
    let onCancel: () -> Void
    let onSave: (NasEthernetInterface) async throws -> Void

    init(
        interface: NasEthernetInterface,
        onCancel: @escaping () -> Void,
        onSave: @escaping (NasEthernetInterface) async throws -> Void
    ) {
        _draft = State(initialValue: interface)
        original = interface
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(draft.displayName) {
                    Toggle(L10n.string("ui.6696d7df7fecf6fc"), isOn: $draft.usesDHCP)
                    TextField(L10n.string("ui.572c01ee2bf2cf56"), text: $draft.address)
                        .disabled(draft.usesDHCP)
                    TextField(L10n.string("ui.b1e9e13ef0a4010a"), text: $draft.subnetMask)
                        .disabled(draft.usesDHCP)
                    TextField(L10n.string("ui.38f36ed30008bc7c"), text: $draft.gateway)
                        .disabled(draft.usesDHCP)
                    TextField(L10n.string("ui.0b3ee5cb92329693"), text: $draft.dnsServers)
                        .disabled(draft.usesDHCP)
                    Toggle(L10n.string("ui.bd46ead425c7ecf0"), isOn: $draft.isDefaultGateway)
                    TextField("MTU", value: $draft.mtu, format: .number)
                    Toggle(L10n.string("ui.d8ec4504b07e9f5a"), isOn: $draft.isVLANEnabled)
                    if draft.isVLANEnabled {
                        TextField(
                            "VLAN ID",
                            value: Binding(
                                get: { draft.vlanID ?? 1 },
                                set: { draft.vlanID = $0 }
                            ),
                            format: .number
                        )
                    }
                }
                Section {
                    Text(L10n.string("ui.e6d5eb02942b2f21"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), action: onCancel)
                Button(L10n.string("ui.4a0c1b27983768cd")) { isConfirming = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == original || isSaving)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 520)
        .confirmationDialog(
            L10n.string("ui.54bd203067659d00"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.2d734836adb06ab0"), role: .destructive) { save() }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.77afa142d59f95b7"))
        }
        .alert(L10n.string("ui.fdc385364ed4d811"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.string("ui.f867f34178594f89")) {}
        } message: {
            Text(errorMessage ?? L10n.string("ui.ac93ffd4a4a2780b"))
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await onSave(draft)
            } catch {
                errorMessage = userMessage(
                    for: error,
                    fallback: L10n.string("ui.8a62fa61185c60e1")
                )
            }
        }
    }
}

private struct DDNSSettingsView: View {
    let directory: NasDDNSDirectory
    let busyIDs: Set<String>
    let onTest: (NasDDNSDraft) async throws -> Void
    let onSave: (NasDDNSDraft) async throws -> Void
    let onDelete: (NasDDNSRecord) async throws -> Void
    let onRefresh: () async throws -> Void
    @State private var presentedDraft: NasDDNSDraft?
    @State private var deleteTarget: NasDDNSRecord?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.fcea58116389894b"))
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    refresh()
                } label: {
                    if busyIDs.contains("refresh") {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                L10n.string("ddns.refresh.updating")
                            )
                    }
                    Label(L10n.string("ui.12487befb4ba483c"), systemImage: "arrow.clockwise")
                }
                .disabled(!busyIDs.isEmpty || directory.records.isEmpty)
                Button {
                    guard let provider = availableProviders.first else { return }
                    presentedDraft = NasDDNSDraft(
                        providerID: provider.id,
                        hostname: "",
                        username: ""
                    )
                } label: {
                    Label(L10n.string("ui.50ef2f4cf6a46924"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(availableProviders.isEmpty || !busyIDs.isEmpty)
            }
            .padding()

            if directory.records.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.072c6f7a8e0c6c14"),
                    systemImage: "globe",
                    description: Text(
                        availableProviders.isEmpty
                            ? L10n.string("ui.72b5cd5e33471211")
                            : L10n.string("ui.6096aa8a39da4197")
                    )
                )
            } else {
                List(directory.records) { record in
                    HStack(spacing: 14) {
                        Image(systemName: record.isEnabled ? "globe.badge.checkmark" : "globe")
                            .foregroundStyle(record.isEnabled ? .green : .secondary)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.hostname)
                                .font(.headline)
                            Text([record.providerName, record.address, record.status]
                                .compactMap { $0 }
                                .joined(separator: " · "))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            if let updated = record.lastUpdated, !updated.isEmpty {
                                Text(L10n.string("ui.d3c58fe20693dfea", String(describing: updated)))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                            .opacity(busyIDs.contains(record.id) ? 1 : 0)
                        Button(L10n.string("ui.051836569928a9f9")) {
                            presentedDraft = draft(from: record)
                        }
                        .disabled(!busyIDs.isEmpty)
                        Button(L10n.string("ui.2f9daa828907b93f"), role: .destructive) {
                            deleteTarget = record
                        }
                        .disabled(!busyIDs.isEmpty)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .sheet(isPresented: draftPresentation) {
            if let draft = presentedDraft {
                DDNSRecordEditor(
                    draft: draft,
                    providers: directory.providers,
                    onCancel: { presentedDraft = nil },
                    onTest: onTest,
                    onSave: { value in
                        try await onSave(value)
                        presentedDraft = nil
                    }
                )
            }
        }
        .confirmationDialog(
            L10n.string("ui.bb81e8ba64bbedcf"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.f2cf9101bb2d8816"), role: .destructive) {
                guard let target = deleteTarget else { return }
                deleteTarget = nil
                Task {
                    do {
                        try await onDelete(target)
                    } catch {
                        errorMessage = userMessage(
                            for: error,
                            fallback: L10n.string("ui.236aff02c50d2036")
                        )
                    }
                }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.886b616f4fb0d8d3"))
        }
        .alert(L10n.string("ui.1f0a01abb1908f19"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.string("ui.f867f34178594f89")) {}
        } message: {
            Text(errorMessage ?? L10n.string("ui.efc81ced18eb3bb0"))
        }
    }

    private var availableProviders: [NasDDNSProvider] {
        let used = Set(directory.records.map(\.providerID))
        return directory.providers.filter { !used.contains($0.id) }
    }

    private var draftPresentation: Binding<Bool> {
        Binding(
            get: { presentedDraft != nil },
            set: { if !$0 { presentedDraft = nil } }
        )
    }

    private func draft(from record: NasDDNSRecord) -> NasDDNSDraft {
        NasDDNSDraft(
            originalProviderID: record.providerID,
            providerID: record.providerID,
            hostname: record.hostname,
            username: record.username ?? "",
            isEnabled: record.isEnabled,
            networkType: record.networkType ?? "auto",
            ipv4: record.ipv4 ?? "0.0.0.0",
            ipv6: record.ipv6 ?? "0:0:0:0:0:0:0:0",
            interfaceV4: record.interfaceV4 ?? "",
            interfaceV6: record.interfaceV6 ?? "",
            heartbeat: record.heartbeat
        )
    }

    private func refresh() {
        Task {
            do {
                try await onRefresh()
            } catch {
                errorMessage = userMessage(for: error, fallback: L10n.string("ui.0f2a476025ef80bb"))
            }
        }
    }
}

private struct DDNSRecordEditor: View {
    @State private var draft: NasDDNSDraft
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var testSucceeded = false
    @State private var errorMessage: String?
    private let originalDraft: NasDDNSDraft
    let providers: [NasDDNSProvider]
    let onCancel: () -> Void
    let onTest: (NasDDNSDraft) async throws -> Void
    let onSave: (NasDDNSDraft) async throws -> Void

    init(
        draft: NasDDNSDraft,
        providers: [NasDDNSProvider],
        onCancel: @escaping () -> Void,
        onTest: @escaping (NasDDNSDraft) async throws -> Void,
        onSave: @escaping (NasDDNSDraft) async throws -> Void
    ) {
        _draft = State(initialValue: draft)
        originalDraft = draft
        self.providers = providers
        self.onCancel = onCancel
        self.onTest = onTest
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.string("ui.b6093c02f3fa3a8e")) {
                    Toggle(L10n.string("ui.e6c04a64954aa920"), isOn: $draft.isEnabled)
                    Picker(L10n.string("ui.a573affa93895101"), selection: $draft.providerID) {
                        ForEach(providers) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    .disabled(draft.originalProviderID != nil)
                    TextField(L10n.string("ui.bc96b2e90db406b4"), text: $draft.hostname)
                    if !draft.normalizedHostname.isEmpty,
                       !NasDDNSDraft.isValidHostname(draft.normalizedHostname) {
                        validationMessage("ddns.editor.hostname-invalid")
                    }
                    TextField(L10n.string("ui.311bb313fdeca6aa"), text: $draft.username)
                    if !draft.normalizedHostname.isEmpty,
                       draft.normalizedUsername.isEmpty {
                        validationMessage("ddns.editor.username-required")
                    }
                    if draft.providerID != "Synology" {
                        SecureField(
                            draft.originalProviderID == nil ? L10n.string("ui.24c5488c934b87c5") : L10n.string("ui.5eaa08672ba4bc26"),
                            text: $draft.password
                        )
                        if draft.originalProviderID == nil,
                           !draft.normalizedHostname.isEmpty,
                           draft.password.isEmpty {
                            validationMessage("ddns.editor.password-required")
                        }
                    } else {
                        Text(L10n.string("ui.69dc28bba545cf6b"))
                            .foregroundStyle(.secondary)
                    }
                    Toggle(L10n.string("ui.0db7eb6a90823c63"), isOn: $draft.heartbeat)
                    if testSucceeded {
                        Label(
                            L10n.string("ddns.test.completed"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        .accessibilityLabel(
                            L10n.string("ddns.test.completed")
                        )
                    }
                }
                Section {
                    Text(L10n.string("ddns.editor.privacy-note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if isTesting || isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(
                            L10n.string(
                                isTesting
                                    ? "ddns.test.testing"
                                    : "ddns.save.saving"
                            )
                        )
                }
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), action: onCancel)
                    .disabled(isTesting || isSaving)
                Button(L10n.string("ddns.test.action")) { testConnection() }
                    .disabled(isTesting || isSaving || !draft.isValidForSubmission)
                Button(L10n.string("ui.a3030bf8f16dc63c")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isTesting || isSaving || !hasChanges || !draft.isValidForSubmission)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 420)
        .onChange(of: draft) {
            testSucceeded = false
        }
        .alert(L10n.string("ui.57f2ad2106e6d63e"), isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button(L10n.string("ui.f867f34178594f89")) {}
        } message: {
            Text(errorMessage ?? L10n.string("ui.ac93ffd4a4a2780b"))
        }
    }

    private var hasChanges: Bool {
        normalized(draft) != normalized(originalDraft)
    }

    private func normalized(_ value: NasDDNSDraft) -> NasDDNSDraft {
        var result = value
        result.providerID = value.normalizedProviderID
        result.hostname = value.normalizedHostname
        result.username = value.normalizedUsername
        return result
    }

    private func testConnection() {
        guard !isTesting, !isSaving else { return }
        isTesting = true
        testSucceeded = false
        Task {
            defer { isTesting = false }
            do {
                try await onTest(normalized(draft))
                testSucceeded = true
            } catch {
                errorMessage = userMessage(
                    for: error,
                    fallback: L10n.string("ddns.test.failed")
                )
            }
        }
    }

    private func save() {
        guard !isTesting, !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await onSave(normalized(draft))
            } catch {
                errorMessage = userMessage(for: error, fallback: L10n.string("ui.dc241cd7d0e88310"))
            }
        }
    }

    private func validationMessage(_ key: String) -> some View {
        Text(L10n.string(key))
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityLabel(L10n.string(key))
    }
}

private struct RegionSettingsView: View {
    @State private var draft: NasRegionSettings
    @State private var serverText: String
    @State private var hasEditedManualDate = false
    @State private var isConfirming = false
    @State private var errorMessage: String?
    let original: NasRegionSettings
    let isSaving: Bool
    let onSave: (NasRegionSettings) async throws -> Void

    init(
        settings: NasRegionSettings,
        isSaving: Bool,
        onSave: @escaping (NasRegionSettings) async throws -> Void
    ) {
        _draft = State(initialValue: settings)
        _serverText = State(initialValue: settings.timeServers.joined(separator: ", "))
        original = settings
        self.isSaving = isSaving
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section(L10n.string("ui.d7f9a4bfc466ae21")) {
                TextField(L10n.string("ui.7530fa1a195df77e"), text: $draft.dateFormat)
                if draft.normalizedDateFormat.isEmpty {
                    validationMessage("region.settings.format-required")
                }
                TextField(L10n.string("ui.1a83bdb917697ede"), text: $draft.timeFormat)
                if draft.normalizedTimeFormat.isEmpty {
                    validationMessage("region.settings.format-required")
                }
                Picker(L10n.string("ui.b5d72c5c00f2d88e"), selection: $draft.timeZone) {
                    ForEach(draft.timeZones) { zone in
                        Text(zone.displayName).tag(zone.id)
                    }
                }
            }
            Section(L10n.string("ui.917e4afc231cb1b0")) {
                Toggle(L10n.string("ui.bb068322c815fb25"), isOn: $draft.isNetworkTimeEnabled)
                if draft.isNetworkTimeEnabled {
                    TextField(L10n.string("ui.daca4b0bb4ba448d"), text: $serverText)
                    Text(L10n.string("ui.4a467d3c2e8fdeda"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !serversAreValid {
                        validationMessage("region.settings.server-invalid")
                    }
                } else {
                    DatePicker(
                        L10n.string("ui.18f2e0e937c97c4c"),
                        selection: Binding(
                            get: { draft.manualDate ?? Date() },
                            set: {
                                draft.manualDate = $0
                                hasEditedManualDate = true
                            }
                        )
                    )
                    if draft.manualDate == nil {
                        validationMessage("region.settings.manual-date-required")
                    }
                    Text(L10n.string("ui.1a85229361b0dc6d"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                HStack {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                L10n.string("region.settings.saving")
                            )
                    }
                    Spacer()
                    Button(L10n.string("ui.e0534b8a4e46a0cb")) {
                        draft = original
                        serverText = original.timeServers.joined(separator: ", ")
                        hasEditedManualDate = false
                    }
                    .disabled(!hasChanges || isSaving)
                    Button(L10n.string("ui.741f0c0de7ebbbf8")) { isConfirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(!hasChanges || isSaving || !isValid)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            draft.isNetworkTimeEnabled ? L10n.string("ui.e17dc95b314b227b") : L10n.string("ui.b730f9f47f97929c"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(draft.isNetworkTimeEnabled ? L10n.string("ui.741f0c0de7ebbbf8") : L10n.string("ui.5f1e8d1d17bf2a07"), role: .destructive) {
                save()
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(
                draft.isNetworkTimeEnabled
                    ? L10n.string("region.settings.ntp-warning")
                    : L10n.string("ui.f4537a9c032bbfff")
            )
        }
        .alert(L10n.string("ui.22a52843f39a768e"), isPresented: errorBinding) {
            Button(L10n.string("ui.f867f34178594f89")) {}
        } message: {
            Text(errorMessage ?? L10n.string("ui.efc81ced18eb3bb0"))
        }
    }

    private var normalizedServers: [String] {
        serverText
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var serversAreValid: Bool {
        !normalizedServers.isEmpty
            && normalizedServers.count <= 3
            && normalizedServers.allSatisfy(
                NasRegionSettings.isValidTimeServer
            )
    }

    private var isValid: Bool {
        var candidate = draft
        candidate.timeServers = normalizedServers
        return candidate.isValidForSaving
    }

    private var hasChanges: Bool {
        var candidate = draft
        candidate.timeServers = normalizedServers
        return candidate != original
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        Task {
            do {
                var candidate = draft
                candidate.timeServers = normalizedServers
                if !candidate.isNetworkTimeEnabled,
                   !hasEditedManualDate {
                    // 未编辑手动时间时由 Repository 使用刚回读的 NAS 时间，避免回写旧秒数。
                    candidate.manualDate = nil
                }
                try await onSave(candidate)
            } catch {
                errorMessage = userMessage(for: error, fallback: L10n.string("ui.f8f49516c226e6b7"))
            }
        }
    }

    private func validationMessage(_ key: String) -> some View {
        Text(L10n.string(key))
            .font(.caption)
            .foregroundStyle(.red)
    }
}

private struct SecuritySettingsView: View {
    @State private var draft: NasSecuritySettings
    @State private var expiresAutomatically: Bool
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    let original: NasSecuritySettings
    let isSaving: Bool
    let onSave: (NasSecuritySettings) async throws -> Void

    init(
        settings: NasSecuritySettings,
        isSaving: Bool,
        onSave: @escaping (NasSecuritySettings) async throws -> Void
    ) {
        _draft = State(initialValue: settings)
        _expiresAutomatically = State(initialValue: settings.expirationDays != nil)
        original = settings
        self.isSaving = isSaving
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section(L10n.string("ui.37c24b911b27dc13")) {
                Toggle(L10n.string("ui.70847756a3a1af23"), isOn: $draft.isAutoBlockEnabled)
                Stepper(
                    L10n.string("ui.d723a22033ba0cf8", String(describing: draft.failedAttempts)),
                    value: $draft.failedAttempts,
                    in: 1...9_999
                )
                .disabled(!draft.isAutoBlockEnabled)
                Stepper(
                    L10n.string("ui.641881a0f3be5aaa", String(describing: draft.withinMinutes)),
                    value: $draft.withinMinutes,
                    in: 1...9_999_999
                )
                .disabled(!draft.isAutoBlockEnabled)
                Toggle(L10n.string("ui.cdd39de701b5dfd5"), isOn: $expiresAutomatically)
                    .disabled(!draft.isAutoBlockEnabled)
                    .onChange(of: expiresAutomatically) { _, enabled in
                        draft.expirationDays = enabled ? max(1, draft.expirationDays ?? 1) : nil
                    }
                if expiresAutomatically {
                    Stepper(
                        L10n.string("ui.9b69b08c6b4dacd3", String(describing: draft.expirationDays ?? 1)),
                        value: Binding(
                            get: { draft.expirationDays ?? 1 },
                            set: { draft.expirationDays = $0 }
                        ),
                        in: 1...999
                    )
                    .disabled(!draft.isAutoBlockEnabled)
                }
            }
            if !draft.dosProtection.isEmpty {
                Section(L10n.string("ui.e8cf8cff709d1f9b")) {
                    ForEach(draft.dosProtection.indices, id: \.self) { index in
                        Toggle(
                            L10n.string("ui.24cef3738252401f", String(describing: draft.dosProtection[index].displayName)),
                            isOn: $draft.dosProtection[index].isEnabled
                        )
                    }
                    Text(L10n.string("ui.f5c9004f2f02f198"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if draft.isFirewallEnabled != nil
                || draft.isPortScanProtectionEnabled != nil {
                Section(L10n.string("ui.eee30e9d97ca1e61")) {
                    if draft.isFirewallEnabled != nil {
                        Toggle(
                            L10n.string("ui.8c603369c2c12ca3"),
                            isOn: Binding(
                                get: { draft.isFirewallEnabled ?? false },
                                set: { draft.isFirewallEnabled = $0 }
                            )
                        )
                        if let profile = draft.firewallProfileName, !profile.isEmpty {
                            LabeledContent(L10n.string("ui.283a7f514f66bd17"), value: profile)
                        }
                    }
                    if draft.isPortScanProtectionEnabled != nil {
                        Toggle(
                            L10n.string("ui.25c087444118705f"),
                            isOn: Binding(
                                get: { draft.isPortScanProtectionEnabled ?? false },
                                set: { draft.isPortScanProtectionEnabled = $0 }
                            )
                        )
                        .disabled(draft.isFirewallEnabled == false)
                    }
                    Text(L10n.string("ui.80e98ae428ea94e4"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text(L10n.string("ui.edd8f7a8fbe466ab"))
                    .foregroundStyle(.secondary)
                if let successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                }
                HStack {
                    Spacer()
                    Button(L10n.string("ui.e0534b8a4e46a0cb")) {
                        draft = original
                        expiresAutomatically = original.expirationDays != nil
                        successMessage = nil
                    }
                    .disabled(draft == original || isSaving)
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(L10n.string("security.settings.saving"))
                    }
                    Button(L10n.string("ui.741f0c0de7ebbbf8")) { isConfirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == original || isSaving)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            L10n.string("ui.2f33995ca5d7a41e"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.741f0c0de7ebbbf8")) { save() }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.bf843d78254c6bf7"))
        }
        .alert(L10n.string("ui.22a52843f39a768e"), isPresented: errorBinding) {
            Button(L10n.string("ui.f867f34178594f89")) {}
        } message: {
            Text(errorMessage ?? L10n.string("ui.efc81ced18eb3bb0"))
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        Task {
            successMessage = nil
            do {
                try await onSave(draft)
                guard !Task.isCancelled else { return }
                successMessage = L10n.string("security.settings.completed")
            } catch {
                errorMessage = userMessage(for: error, fallback: L10n.string("ui.f8f49516c226e6b7"))
            }
        }
    }
}

private struct RemoteAccessSettingsView: View {
    @State private var draft: NasRemoteAccessSettings
    @State private var isConfirming = false
    @State private var errorMessage: String?
    let original: NasRemoteAccessSettings
    let isSaving: Bool
    let onSave: (NasRemoteAccessSettings) async throws -> Void

    init(
        settings: NasRemoteAccessSettings,
        isSaving: Bool,
        onSave: @escaping (NasRemoteAccessSettings) async throws -> Void
    ) {
        _draft = State(initialValue: settings)
        original = settings
        self.isSaving = isSaving
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section(L10n.string("remote-access.section.quickconnect")) {
                if draft.isRelayEnabled != nil {
                    Toggle(
                        L10n.string("ui.c228914d93ed28bd"),
                        isOn: Binding(
                            get: { draft.isRelayEnabled ?? false },
                            set: { draft.isRelayEnabled = $0 }
                        )
                    )
                    .disabled(!draft.canDisableRelay && draft.isRelayEnabled == true)
                    if !draft.canDisableRelay {
                        Text(L10n.string("ui.897bd9e724c0b06c"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if draft.isRouterConfigurationEnabled != nil {
                    Toggle(
                        L10n.string("ui.e60e66f63ab0fd13"),
                        isOn: Binding(
                            get: { draft.isRouterConfigurationEnabled ?? false },
                            set: { draft.isRouterConfigurationEnabled = $0 }
                        )
                    )
                }
            }
            Section {
                Text(L10n.string("ui.ace40ffe0474ce20"))
                    .foregroundStyle(.secondary)
                HStack {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                L10n.string("remote-access.settings.saving")
                            )
                    }
                    Spacer()
                    Button(L10n.string("ui.e0534b8a4e46a0cb")) { draft = original }
                        .disabled(draft == original || isSaving)
                    Button(L10n.string("ui.741f0c0de7ebbbf8")) { isConfirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == original || isSaving)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            L10n.string("ui.8b407f60394498f2"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.741f0c0de7ebbbf8")) { save() }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.0e34c65bf1c9b2b7"))
        }
        .alert(L10n.string("ui.22a52843f39a768e"), isPresented: errorBinding) {
            Button(L10n.string("ui.f867f34178594f89")) {}
        } message: {
            Text(errorMessage ?? L10n.string("ui.efc81ced18eb3bb0"))
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        Task {
            do {
                try await onSave(draft)
            } catch {
                errorMessage = userMessage(for: error, fallback: L10n.string("ui.f8f49516c226e6b7"))
            }
        }
    }
}

private struct HardwareSettingsView: View {
    @State private var draft: NasHardwareSettings
    @State private var isConfirming = false
    @State private var errorMessage: String?
    let original: NasHardwareSettings
    let isSaving: Bool
    let onSave: (NasHardwareSettings) async throws -> Void

    init(
        settings: NasHardwareSettings,
        isSaving: Bool,
        onSave: @escaping (NasHardwareSettings) async throws -> Void
    ) {
        _draft = State(initialValue: settings)
        original = settings
        self.isSaving = isSaving
        self.onSave = onSave
    }

    var body: some View {
        Form {
            if draft.restartsAfterPowerFailure != nil {
                Section(L10n.string("ui.6ad3f1579827e17e")) {
                    Toggle(
                        L10n.string("ui.ffdb53bb11165394"),
                        isOn: Binding(
                            get: { draft.restartsAfterPowerFailure ?? false },
                            set: { draft.restartsAfterPowerFailure = $0 }
                        )
                    )
                }
            }
            if let range = draft.ledBrightnessRange,
               draft.ledBrightness != nil {
                Section(L10n.string("ui.f340aef6e9e2edbe")) {
                    Stepper(
                        L10n.string("ui.d582553b18b8f98c", String(describing: draft.ledBrightness ?? range.lowerBound)),
                        value: Binding(
                            get: { draft.ledBrightness ?? range.lowerBound },
                            set: { draft.ledBrightness = $0 }
                        ),
                        in: range
                    )
                }
            }
            if draft.fanMode != nil {
                Section(L10n.string("ui.02bc400b18f1258f")) {
                    Picker(
                        L10n.string("ui.25252048254441c8"),
                        selection: Binding(
                            get: { draft.fanMode ?? "coolfan" },
                            set: { draft.fanMode = $0 }
                        )
                    ) {
                        Text(L10n.string("ui.390ea09574f38da3")).tag("highfan")
                        Text(L10n.string("ui.0949910fb8c4e07f")).tag("lowfan")
                        Text(L10n.string("ui.f327f82035eeb44c")).tag("fullfan")
                        Text(L10n.string("ui.844749143a0da5a0")).tag("coolfan")
                        Text(L10n.string("ui.5b31e21cdb562f6a")).tag("quietfan")
                        Text(L10n.string("ui.1b3589f9dbf18de9")).tag("quietstopfan")
                    }
                }
            }
            if draft.isFanFailureAlertEnabled != nil
                || draft.isVolumeFailureAlertEnabled != nil
                || draft.isPowerOnSoundEnabled != nil
                || draft.isPowerOffSoundEnabled != nil
                || draft.isResetSoundEnabled != nil {
                Section(L10n.string("ui.fdd8ff337f90943e")) {
                    optionalHardwareToggle(
                        L10n.string("ui.d27bea3fb648a93b"),
                        value: $draft.isFanFailureAlertEnabled
                    )
                    optionalHardwareToggle(
                        L10n.string("ui.de67d20cb4a50dca"),
                        value: $draft.isVolumeFailureAlertEnabled
                    )
                    optionalHardwareToggle(
                        L10n.string("ui.be0b881e8f500acb"),
                        value: $draft.isPowerOnSoundEnabled
                    )
                    optionalHardwareToggle(
                        L10n.string("ui.c7e4c29ba726a639"),
                        value: $draft.isPowerOffSoundEnabled
                    )
                    optionalHardwareToggle(
                        L10n.string("ui.97995bc03cbe4d14"),
                        value: $draft.isResetSoundEnabled
                    )
                }
            }
            if draft.isExternalDriveDeepSleepEnabled != nil
                || draft.isWakeUpLogEnabled != nil
                || draft.isSATASleepEnabled != nil
                || draft.ignoresNetworkDiscoveryDuringSleep != nil
                || draft.isAutomaticPowerOffEnabled != nil {
                Section(L10n.string("ui.8a4a54b78e56cc0e")) {
                    optionalHardwareToggle(
                        L10n.string("ui.8292c5b4a1591f60"),
                        value: $draft.isExternalDriveDeepSleepEnabled
                    )
                    optionalHardwareToggle(
                        L10n.string("ui.79ee2c731e5f0162"),
                        value: $draft.isWakeUpLogEnabled
                    )
                    optionalHardwareToggle(
                        L10n.string("ui.9a5a924761affd44"),
                        value: $draft.isSATASleepEnabled
                    )
                    optionalHardwareToggle(
                        L10n.string("ui.1d18b4496d03940e"),
                        value: $draft.ignoresNetworkDiscoveryDuringSleep
                    )
                    optionalHardwareToggle(
                        L10n.string("ui.d8577cf2d181ec6d"),
                        value: $draft.isAutomaticPowerOffEnabled
                    )
                }
            }
            if draft.ups != nil {
                Section(L10n.string("ui.57a20e0e41013b7a")) {
                    Toggle(
                        L10n.string("ui.b096bfe5e2d9f5b0"),
                        isOn: Binding(
                            get: { draft.ups?.isEnabled ?? false },
                            set: { draft.ups?.isEnabled = $0 }
                        )
                    )
                    Picker(
                        L10n.string("ui.485a26050ce57431"),
                        selection: Binding(
                            get: { draft.ups?.mode ?? "USB" },
                            set: { draft.ups?.mode = $0 }
                        )
                    ) {
                        Text(L10n.string("connection.usb")).tag("USB")
                        Text(L10n.string("ui.2403e129b2155129")).tag("SLAVE")
                        Text(L10n.string("connection.snmp_ups")).tag("SNMP")
                    }
                    .disabled(draft.ups?.isEnabled != true)
                    if draft.ups?.mode == "SLAVE" {
                        TextField(
                            L10n.string("ui.5b8c6d3919913aa1"),
                            text: Binding(
                                get: { draft.ups?.networkServerAddress ?? "" },
                                set: { draft.ups?.networkServerAddress = $0 }
                            )
                        )
                        .disabled(draft.ups?.isEnabled != true)
                    }
                    if draft.ups?.mode == "SNMP" {
                        TextField(
                            L10n.string("ui.7a6414b016dbdb29"),
                            text: Binding(
                                get: { draft.ups?.snmpServerAddress ?? "" },
                                set: { draft.ups?.snmpServerAddress = $0 }
                            )
                        )
                        .disabled(draft.ups?.isEnabled != true)
                    }
                    if draft.ups?.waitsUntilLowBattery != nil {
                        Toggle(
                            L10n.string("ui.1ec8115ce215ba9e"),
                            isOn: Binding(
                                get: { draft.ups?.waitsUntilLowBattery ?? false },
                                set: { draft.ups?.waitsUntilLowBattery = $0 }
                            )
                        )
                        .disabled(draft.ups?.isEnabled != true)
                    }
                    if draft.ups?.safeModeDelaySeconds != nil,
                       draft.ups?.waitsUntilLowBattery != true {
                        TextField(
                            L10n.string("ui.e0f51bbce02654e3"),
                            value: Binding(
                                get: { draft.ups?.safeModeDelaySeconds ?? 0 },
                                set: { draft.ups?.safeModeDelaySeconds = $0 }
                            ),
                            format: .number
                        )
                        .disabled(draft.ups?.isEnabled != true)
                    }
                    if draft.ups?.shutsDownUPSAfterSafeMode != nil {
                        Toggle(
                            L10n.string("ui.4d1f3d962d8e694a"),
                            isOn: Binding(
                                get: { draft.ups?.shutsDownUPSAfterSafeMode ?? false },
                                set: { draft.ups?.shutsDownUPSAfterSafeMode = $0 }
                            )
                        )
                        .disabled(draft.ups?.isEnabled != true)
                    }
                    Text(L10n.string("ui.d34c79c4ecbe48f6"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Text(L10n.string("ui.8c76e485f46f5a7c"))
                    .foregroundStyle(.secondary)
                HStack {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                L10n.string("hardware.settings.saving")
                            )
                    }
                    Spacer()
                    Button(L10n.string("ui.e0534b8a4e46a0cb")) { draft = original }
                        .disabled(draft == original || isSaving)
                    Button(L10n.string("ui.741f0c0de7ebbbf8")) { isConfirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == original || isSaving)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            L10n.string("ui.1553d0e4266fec45"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.741f0c0de7ebbbf8")) { save() }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.b772378791d88c9a"))
        }
        .alert(L10n.string("ui.22a52843f39a768e"), isPresented: errorBinding) {
            Button(L10n.string("ui.f867f34178594f89")) {}
        } message: {
            Text(errorMessage ?? L10n.string("ui.efc81ced18eb3bb0"))
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @ViewBuilder
    private func optionalHardwareToggle(_ title: String, value: Binding<Bool?>) -> some View {
        if value.wrappedValue != nil {
            Toggle(
                title,
                isOn: Binding(
                    get: { value.wrappedValue ?? false },
                    set: { value.wrappedValue = $0 }
                )
            )
        }
    }

    private func save() {
        Task {
            do {
                try await onSave(draft)
            } catch {
                errorMessage = userMessage(for: error, fallback: L10n.string("ui.f8f49516c226e6b7"))
            }
        }
    }
}

private struct ProxySettingsView: View {
    @State private var draft: NasProxySettings
    @State private var isConfirming = false
    @State private var errorMessage: String?
    let original: NasProxySettings
    let isSaving: Bool
    let onSave: (NasProxySettings) async throws -> Void

    init(
        settings: NasProxySettings,
        isSaving: Bool,
        onSave: @escaping (NasProxySettings) async throws -> Void
    ) {
        _draft = State(initialValue: settings)
        original = settings
        self.isSaving = isSaving
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section(L10n.string("ui.a7f07cdbba10843c")) {
                Toggle(L10n.string("ui.66cd771d3bbc9335"), isOn: $draft.isEnabled)
                TextField(L10n.string("ui.d3716cc5a2f5a810"), text: $draft.host)
                    .disabled(!draft.isEnabled)
                if draft.isEnabled,
                   !NasProxySettings.isValidHost(draft.normalizedHost) {
                    Text(L10n.string("proxy.settings.host-invalid"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                TextField(
                    L10n.string("ui.e71ac32b544b0ebf"),
                    value: $draft.port,
                    format: .number
                )
                .disabled(!draft.isEnabled)
                if draft.isEnabled,
                   draft.port.map({ (1...65_535).contains($0) }) != true {
                    Text(L10n.string("proxy.settings.port-invalid"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text(L10n.string("ui.0bdd80480ee76860"))
                    .foregroundStyle(.secondary)
                HStack {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                L10n.string("proxy.settings.saving")
                            )
                    }
                    Spacer()
                    Button(L10n.string("ui.e0534b8a4e46a0cb")) { draft = original }
                        .disabled(draft == original || isSaving)
                    Button(L10n.string("ui.741f0c0de7ebbbf8")) { isConfirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            draft == original
                                || isSaving
                                || !draft.isValidForSaving
                        )
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            L10n.string("ui.ee21795e5c0ba467"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.741f0c0de7ebbbf8")) { save() }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.764a8de38e9081f7"))
        }
        .alert(L10n.string("ui.22a52843f39a768e"), isPresented: errorBinding) {
            Button(L10n.string("ui.f867f34178594f89")) {}
        } message: {
            Text(errorMessage ?? L10n.string("ui.efc81ced18eb3bb0"))
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        Task {
            do {
                try await onSave(draft)
            } catch {
                errorMessage = userMessage(for: error, fallback: L10n.string("ui.f8f49516c226e6b7"))
            }
        }
    }
}

private struct FileServiceSettingsView: View {
    @State private var draft: NasFileServiceSettings
    @State private var isConfirming = false
    @State private var errorMessage: String?
    let original: NasFileServiceSettings
    let isSaving: Bool
    let onSave: (NasFileServiceSettings) async throws -> Void

    init(
        settings: NasFileServiceSettings,
        isSaving: Bool,
        onSave: @escaping (NasFileServiceSettings) async throws -> Void
    ) {
        _draft = State(initialValue: settings)
        original = settings
        self.isSaving = isSaving
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section(L10n.string("ui.6424af044d400e74")) {
                optionalToggle(L10n.string("ui.8a8a49d2fa4b099f"), value: $draft.isSMBEnabled)
                optionalToggle(L10n.string("ui.3d4ef43e8def6e66"), value: $draft.isNFSEnabled)
            }
            Section(L10n.string("ui.f3c32e652f6592d1")) {
                optionalToggle("FTP", value: $draft.isFTPEnabled)
                optionalToggle(L10n.string("ui.d0b9d702115fa28d"), value: $draft.isFTPSEnabled)
                optionalPort(L10n.string("ui.4e685f7722bd0d8b"), value: $draft.ftpPort)
                optionalToggle("SFTP", value: $draft.isSFTPEnabled)
                optionalPort(L10n.string("ui.bc665cd348c4f6ce"), value: $draft.sftpPort)
            }
            if draft.isSSDPEnabled != nil
                || draft.isBonjourEnabled != nil
                || draft.isSMBTimeMachineEnabled != nil {
                Section(L10n.string("ui.e25e85e8bdee7232")) {
                    optionalToggle(L10n.string("ui.b5d04e41c41138ee"), value: $draft.isSSDPEnabled)
                    optionalToggle(L10n.string("ui.52065b753b2e22aa"), value: $draft.isBonjourEnabled)
                    optionalToggle(
                        L10n.string("ui.c7355ca3ccf1da39"),
                        value: $draft.isSMBTimeMachineEnabled
                    )
                }
            }
            Section {
                Text(L10n.string("ui.4bd325bd22926e87"))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                L10n.string("file-services.settings.saving")
                            )
                    }
                    Button(L10n.string("ui.e0534b8a4e46a0cb")) { draft = original }
                        .disabled(draft == original || isSaving)
                    Button(L10n.string("ui.741f0c0de7ebbbf8")) { isConfirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == original || isSaving)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            L10n.string("ui.2496baae26a2c1e4"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.741f0c0de7ebbbf8")) { save() }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.f0436f46dd161383"))
        }
        .alert(L10n.string("ui.22a52843f39a768e"), isPresented: errorBinding) {
            Button(L10n.string("ui.f867f34178594f89")) {}
        } message: {
            Text(errorMessage ?? L10n.string("ui.efc81ced18eb3bb0"))
        }
    }

    @ViewBuilder
    private func optionalToggle(_ title: String, value: Binding<Bool?>) -> some View {
        if value.wrappedValue != nil {
            Toggle(title, isOn: Binding(
                get: { value.wrappedValue ?? false },
                set: { value.wrappedValue = $0 }
            ))
        }
    }

    @ViewBuilder
    private func optionalPort(_ title: String, value: Binding<Int?>) -> some View {
        if value.wrappedValue != nil {
            TextField(title, value: Binding(
                get: { value.wrappedValue ?? 0 },
                set: { value.wrappedValue = $0 }
            ), format: .number)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func save() {
        Task {
            do {
                try await onSave(draft)
            } catch {
                errorMessage = userMessage(for: error, fallback: L10n.string("ui.f8f49516c226e6b7"))
            }
        }
    }
}

private struct TerminalSettingsView: View {
    @State private var draft: NasTerminalSettings
    @State private var isConfirming = false
    @State private var errorMessage: String?
    let original: NasTerminalSettings
    let isSaving: Bool
    let onSave: (NasTerminalSettings) async throws -> Void

    init(
        settings: NasTerminalSettings,
        isSaving: Bool,
        onSave: @escaping (NasTerminalSettings) async throws -> Void
    ) {
        _draft = State(initialValue: settings)
        original = settings
        self.isSaving = isSaving
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section(L10n.string("ui.678b783fb578172b")) {
                Toggle(L10n.string("ui.e07f0d5f213bcc57"), isOn: $draft.isSSHEnabled)
                Toggle(L10n.string("ui.ead7ad3c36f86eb8"), isOn: $draft.isTelnetEnabled)
                if draft.sshPort != nil {
                    TextField(L10n.string("ui.1c22cc57aee8c65a"), value: Binding(
                        get: { draft.sshPort ?? 0 },
                        set: { draft.sshPort = $0 }
                    ), format: .number)
                    if isPortInvalid {
                        Text(L10n.string("terminal.settings.port-invalid"))
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityLabel(
                                L10n.string("terminal.settings.port-invalid")
                            )
                    }
                }
            }
            Section {
                Text(L10n.string("ui.5ec51d41f6ba329f"))
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(
                                L10n.string("terminal.settings.saving")
                            )
                    }
                    Button(L10n.string("ui.e0534b8a4e46a0cb")) { draft = original }
                        .disabled(draft == original || isSaving)
                    Button(L10n.string("ui.741f0c0de7ebbbf8")) { isConfirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(draft == original || isSaving || isPortInvalid)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            L10n.string("ui.6625229f10ed7976"),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.741f0c0de7ebbbf8")) { save() }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.53e6c0f8afdb1609"))
        }
        .alert(L10n.string("ui.22a52843f39a768e"), isPresented: errorBinding) {
            Button(L10n.string("ui.f867f34178594f89")) {}
        } message: {
            Text(errorMessage ?? L10n.string("ui.efc81ced18eb3bb0"))
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private var isPortInvalid: Bool {
        guard let port = draft.sshPort else { return false }
        return !(1...65_535).contains(port)
    }

    private func save() {
        Task {
            do {
                try await onSave(draft)
            } catch {
                errorMessage = userMessage(for: error, fallback: L10n.string("ui.f8f49516c226e6b7"))
            }
        }
    }
}

private struct NasAdministrationSplitView<Page: Hashable, Content: View>: View {
    let pages: [Page]
    @Binding var selection: Page
    let label: (Page) -> (String, String)
    @ViewBuilder let content: () -> Content

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(pages, id: \.self, selection: $selection) { page in
                    let item = label(page)
                    Label(item.0, systemImage: item.1)
                        .tag(page)
                        .padding(.vertical, 3)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct AdministrationPageContainer<Content: View>: View {
    let isLoading: Bool
    let hasLoaded: Bool
    let hasContent: Bool
    let errorMessage: String?
    let emptyTitle: String
    let emptyDescription: String
    let retry: () async -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            if hasContent {
                content()
            } else if isLoading || !hasLoaded, errorMessage == nil {
                LoadingAdministrationView()
            } else if let errorMessage {
                AdministrationErrorView(message: errorMessage) {
                    Task { await retry() }
                }
            } else {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: "tray",
                    description: Text(emptyDescription)
                )
            }

            if isLoading, hasContent {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 10)
                    .accessibilityLabel(L10n.string("ui.2336147a7f843985"))
            }
        }
    }
}



private struct SystemInfoBadge: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(label + ":")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
        }
    }
}

private struct PerformanceChartCard<ChartContent: View>: View {
    let title: String
    let subtitle: String
    let unit: String
    let chart: ChartContent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(unit)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }
            chart.frame(height: 140)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 215, maxHeight: 215, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct MetricCard: View {
    let title: String
    let value: String
    let icon: String
    var progress: Double?
    var tint: Color = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.bold))
                .contentTransition(.numericText())
                .monospacedDigit()
                .foregroundStyle(.primary)

            Spacer(minLength: 0)

            if let progress {
                ProgressView(value: min(100, max(0, progress)), total: 100)
                    .tint(tint)
                    .controlSize(.small)
                    .accessibilityLabel(title)
                    .accessibilityValue(value)
            } else {
                Color.clear.frame(height: 6)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private enum UnifiedStorageSection: String, CaseIterable, Identifiable {
    case overview = "ui.a33db573055626c5"
    case analysis = "ui.90438f3b6e413299"
    case hardware = "ui.418342623fc30942"

    var id: Self { self }
}

private enum StorageReportSection: String, CaseIterable, Identifiable {
    case shares = "ui.8df2fa80a06c49b5"
    case types = "ui.9a8457b3dc844478"
    case largeFiles = "ui.7400f5fabb559999"
    case duplicates = "ui.3b0db02d8063b59f"
    case owners = "ui.43a7f4b4c5c88a2a"
    case activity = "ui.d913a95d6c9599d9"

    var id: Self { self }
}

private struct UnifiedStorageView: View {
    let snapshot: NasStorageSnapshot?
    let usageHistory: [StorageUsagePoint]
    let analysis: StorageAnalysisSnapshot?
    let analysisProgress: StorageAnalysisProgress?
    let analysisError: String?
    let isAnalyzing: Bool
    let testStatuses: [String: NasDiskTestStatus]
    let busyDiskIDs: Set<String>
    let refresh: () async -> Void
    let beginAnalysis: () -> Void
    let cancelAnalysis: () -> Void
    let loadTestStatus: (String) async throws -> Void
    let startTest: (String, NasDiskTestType) async throws -> Void
    let stopTest: (String) async throws -> Void

    @State private var section: UnifiedStorageSection = .overview

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(L10n.string("ui.ceebdfc7f13d0429"), selection: $section) {
                    ForEach(UnifiedStorageSection.allCases) { item in
                        Text(L10n.string(item.rawValue)).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520, alignment: .leading)

                Spacer()

                Button {
                    Task { await refresh() }
                } label: {
                    Label(L10n.string("ui.aee88743413144a2"), systemImage: "arrow.clockwise")
                }
                .help(L10n.string("ui.562868f9b8372a48"))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            Divider()

            switch section {
            case .overview:
                StorageOverviewDashboard(
                    snapshot: snapshot,
                    usageHistory: usageHistory,
                    analysis: analysis,
                    showAnalysis: { section = .analysis },
                    showHardware: { section = .hardware }
                )
            case .analysis:
                StorageAnalysisView(
                    snapshot: analysis,
                    progress: analysisProgress,
                    errorMessage: analysisError,
                    isAnalyzing: isAnalyzing,
                    beginAnalysis: beginAnalysis,
                    cancelAnalysis: cancelAnalysis
                )
            case .hardware:
                StorageView(
                    snapshot: snapshot,
                    testStatuses: testStatuses,
                    busyDiskIDs: busyDiskIDs,
                    loadTestStatus: loadTestStatus,
                    startTest: startTest,
                    stopTest: stopTest
                )
            }
        }
    }
}

private struct StorageOverviewDashboard: View {
    let snapshot: NasStorageSnapshot?
    let usageHistory: [StorageUsagePoint]
    let analysis: StorageAnalysisSnapshot?
    let showAnalysis: () -> Void
    let showHardware: () -> Void

    private var totalBytes: Int64 {
        snapshot?.volumes.reduce(Int64(0)) { $0 + max($1.totalBytes ?? 0, 0) } ?? 0
    }

    private var usedBytes: Int64 {
        snapshot?.volumes.reduce(Int64(0)) { $0 + max($1.usedBytes ?? 0, 0) } ?? 0
    }

    private var availableBytes: Int64 {
        max(totalBytes - usedBytes, 0)
    }

    private var hasWarning: Bool {
        isWarning(snapshot?.overallStatus)
            || (snapshot?.disks.contains { isWarning($0.status) || isWarning($0.smartStatus) } ?? false)
            || (snapshot?.pools.contains { isWarning($0.status) } ?? false)
            || (snapshot?.volumes.contains { isWarning($0.status) } ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(
                    L10n.string("ui.d8fdd9c0f38cc267"),
                    systemImage: "square.grid.2x2"
                )
                .font(.callout)
                .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    StorageMetricCard(
                        title: L10n.string("ui.9e4972cf66420340"),
                        value: byteCount(totalBytes),
                        detail: L10n.string("ui.ead16b41c57b5f4e", String(describing: snapshot?.volumes.count ?? 0)),
                        icon: "externaldrive.fill",
                        tint: .blue
                    )
                    StorageMetricCard(
                        title: L10n.string("ui.9845c165151daee3"),
                        value: byteCount(usedBytes),
                        detail: totalBytes > 0
                            ? "\((Double(usedBytes) / Double(totalBytes) * 100).formatted(.number.precision(.fractionLength(1))))%"
                            : L10n.string("ui.e57bc250f8a812ba"),
                        icon: "chart.pie.fill",
                        tint: .indigo
                    )
                    StorageMetricCard(
                        title: L10n.string("ui.cec82ccb6e81e727"),
                        value: byteCount(availableBytes),
                        detail: L10n.string("ui.e313f1a4fe87ede0"),
                        icon: "internaldrive",
                        tint: .teal
                    )
                    StorageMetricCard(
                        title: L10n.string("ui.f7b9a497c88ea2bc"),
                        value: hasWarning ? L10n.string("ui.f121ab742cefcb8e") : L10n.string("ui.cfea0dce5c5d6d72"),
                        detail: L10n.string("ui.0454b8cb1913f89f", String(describing: snapshot?.pools.count ?? 0), String(describing: snapshot?.disks.count ?? 0)),
                        icon: hasWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                        tint: hasWarning ? .orange : .green
                    )
                }

                if !usageHistory.isEmpty {
                    GroupBox(L10n.string("ui.ca367d74342bb4f8")) {
                        Chart(usageHistory) { point in
                            LineMark(
                                x: .value(L10n.string("ui.8b6ff498515bcc2f"), point.recordedAt),
                                y: .value(L10n.string("ui.9845c165151daee3"), point.usedBytes)
                            )
                            .foregroundStyle(by: .value(L10n.string("ui.26de3dd933ce00e3"), point.volumeName))
                            PointMark(
                                x: .value(L10n.string("ui.8b6ff498515bcc2f"), point.recordedAt),
                                y: .value(L10n.string("ui.9845c165151daee3"), point.usedBytes)
                            )
                            .foregroundStyle(by: .value(L10n.string("ui.26de3dd933ce00e3"), point.volumeName))
                        }
                        .chartYAxis {
                            AxisMarks(format: .byteCount(style: .file))
                        }
                        .frame(height: 220)
                        .padding(.top, 8)
                        .accessibilityLabel(L10n.string("ui.1d0f6982184475a5"))
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    StorageOverviewActionCard(
                        title: L10n.string("ui.90438f3b6e413299"),
                        description: analysis.map {
                            L10n.string("ui.ce6a94d231c1d9a5", String(describing: $0.generatedAt.formatted(date: .abbreviated, time: .shortened)), String(describing: $0.scannedFileCount.formatted()))
                        } ?? L10n.string("ui.292d1de321ab8029"),
                        icon: "chart.bar.xaxis",
                        actionTitle: analysis == nil ? L10n.string("ui.7e732df3bd81d015") : L10n.string("ui.a08bfa0c50e2895f"),
                        action: showAnalysis
                    )
                    StorageOverviewActionCard(
                        title: L10n.string("ui.418342623fc30942"),
                        description: L10n.string("ui.1d7b08c73e628019"),
                        icon: "internaldrive",
                        actionTitle: L10n.string("ui.2e1f1effcaa9b7b4"),
                        action: showHardware
                    )
                }
            }
            .padding(24)
        }
    }
}

private struct StorageMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let icon: String
    let tint: Color

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 34, height: 34)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
        }
    }
}

private struct StorageOverviewActionCard: View {
    let title: String
    let description: String
    let icon: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(title, systemImage: icon)
                    .font(.headline)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                Button(actionTitle, action: action)
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct StorageAnalysisView: View {
    let snapshot: StorageAnalysisSnapshot?
    let progress: StorageAnalysisProgress?
    let errorMessage: String?
    let isAnalyzing: Bool
    let beginAnalysis: () -> Void
    let cancelAnalysis: () -> Void

    @State private var reportSection: StorageReportSection = .shares

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string("ui.90438f3b6e413299"))
                            .font(.title2.weight(.semibold))
                        Text(L10n.string("ui.8df9cc3ad1bfa54f"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isAnalyzing {
                        Button(L10n.string("ui.546be3ab7e6722e7"), role: .cancel, action: cancelAnalysis)
                    } else {
                        Button {
                            beginAnalysis()
                        } label: {
                            Label(snapshot == nil ? L10n.string("ui.b2be5f83c9490950") : L10n.string("ui.734b1551161f6b46"), systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if isAnalyzing {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(progress?.title ?? L10n.string("ui.bde2834d4917ecf8"))
                                .font(.headline)
                            if let fraction = progress?.fraction {
                                ProgressView(value: fraction)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            if let progress, progress.total > 0 {
                                Text("\(min(progress.completed + 1, progress.total)) / \(progress.total)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                if let snapshot {
                    analysisContent(snapshot)
                } else if !isAnalyzing {
                    ContentUnavailableView {
                        Label(L10n.string("ui.f2ff8c0767cf59b5"), systemImage: "chart.bar.doc.horizontal")
                    } description: {
                        Text(L10n.string("ui.003ebad73cce017f"))
                    } actions: {
                        Button(L10n.string("ui.b2be5f83c9490950"), action: beginAnalysis)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func analysisContent(_ snapshot: StorageAnalysisSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            StorageMetricCard(
                title: L10n.string("ui.2649fbc02a65cef6"),
                value: snapshot.scannedFileCount.formatted(),
                detail: L10n.string("ui.5171196ff6661c1c"),
                icon: "doc.on.doc",
                tint: .blue
            )
            StorageMetricCard(
                title: L10n.string("ui.c8c21b6589b1eabe"),
                value: byteCount(snapshot.scannedBytes),
                detail: L10n.string("ui.472411affcce59ba"),
                icon: "chart.pie.fill",
                tint: .indigo
            )
            StorageMetricCard(
                title: L10n.string("ui.8df2fa80a06c49b5"),
                value: snapshot.shares.count.formatted(),
                detail: L10n.string("ui.44238dab0c531162"),
                icon: "folder.fill",
                tint: .teal
            )
            StorageMetricCard(
                title: L10n.string("ui.1756e99530b969c9"),
                value: byteCount(snapshot.duplicateGroups.reduce(Int64(0)) { $0 + $1.reclaimableBytes }),
                detail: L10n.string("ui.7344d54a0f940dec", String(describing: snapshot.duplicateGroups.count)),
                icon: "square.on.square",
                tint: .orange
            )
        }

        HStack {
            Picker(L10n.string("ui.cde63c6e590dba29"), selection: $reportSection) {
                ForEach(StorageReportSection.allCases) { item in
                    Text(L10n.string(item.rawValue)).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer()
            Text(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        switch reportSection {
        case .shares:
            StorageUsageBars(
                title: L10n.string("ui.142497611cf2f7d0"),
                rows: snapshot.shares.map { ($0.name, $0.usedBytes, $0.fileCount) }
            )
        case .types:
            StorageUsageBars(
                title: L10n.string("ui.c9a138d4dfdd880c"),
                rows: snapshot.categories.map { ($0.name, $0.usedBytes, $0.fileCount) }
            )
        case .largeFiles:
            StorageFileList(title: L10n.string("ui.a8977ce1b8649ad3"), files: snapshot.largeFiles, dateKind: nil)
        case .duplicates:
            StorageDuplicateList(snapshot: snapshot)
        case .owners:
            StorageUsageBars(
                title: L10n.string("ui.17429e6e0200d5e9"),
                rows: snapshot.owners.map { ($0.name, $0.usedBytes, $0.fileCount) }
            )
        case .activity:
            VStack(alignment: .leading, spacing: 16) {
                StorageFileList(
                    title: L10n.string("ui.ad3bf1eea84b70e4"),
                    files: snapshot.recentlyModifiedFiles,
                    dateKind: .modified
                )
                StorageFileList(
                    title: L10n.string("ui.b9044c43503f4a1c"),
                    files: snapshot.leastRecentlyAccessedFiles,
                    dateKind: .accessed
                )
            }
        }
    }
}

private struct StorageUsageBars: View {
    let title: String
    let rows: [(name: String, bytes: Int64, count: Int)]

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 14) {
                if rows.isEmpty {
                    Text(L10n.string("ui.1c77a8adce30a16e"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    Chart(Array(rows.prefix(12)), id: \.name) { row in
                        BarMark(
                            x: .value(L10n.string("ui.c0aa76aebce68788"), row.bytes),
                            y: .value(L10n.string("ui.79f326be4409d51f"), row.name)
                        )
                        .foregroundStyle(.blue.gradient)
                    }
                    .chartXAxis {
                        AxisMarks(format: .byteCount(style: .file))
                    }
                    .frame(height: max(220, CGFloat(min(rows.count, 12)) * 30))
                    .accessibilityLabel(title)

                    Divider()

                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        HStack {
                            Text(row.name)
                                .lineLimit(1)
                            Spacer()
                            Text(L10n.string("ui.057c1760db06e516", String(describing: row.count.formatted())))
                                .foregroundStyle(.secondary)
                            Text(byteCount(row.bytes))
                                .monospacedDigit()
                                .frame(minWidth: 90, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                }
            }
            .padding(6)
        }
    }
}

private enum StorageFileDateKind {
    case modified
    case accessed
}

private struct StorageFileList: View {
    let title: String
    let files: [FileItem]
    let dateKind: StorageFileDateKind?

    var body: some View {
        GroupBox(title) {
            LazyVStack(spacing: 0) {
                if files.isEmpty {
                    Text(L10n.string("ui.76ada2f67941689e"))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    ForEach(files) { file in
                        HStack(spacing: 10) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .lineLimit(1)
                                Text(file.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            if let date = date(for: file) {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(byteCount(file.sizeBytes))
                                .font(.callout.monospacedDigit())
                                .frame(minWidth: 90, alignment: .trailing)
                        }
                        .padding(.vertical, 8)
                        if file.id != files.last?.id {
                            Divider()
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    private func date(for file: FileItem) -> Date? {
        switch dateKind {
        case .modified: file.times?.modifiedAt
        case .accessed: file.times?.accessedAt
        case nil: nil
        }
    }
}

private struct StorageDuplicateList: View {
    let snapshot: StorageAnalysisSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.duplicateCheckUnavailable {
                Label(
                    L10n.string("ui.51029dff33be8570"),
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
            } else if snapshot.duplicateCheckWasLimited {
                Label(
                    L10n.string("ui.39981e1118b2a80c"),
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
            }

            if snapshot.duplicateGroups.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.a5c90c9e9d138455"),
                    systemImage: "checkmark.circle",
                    description: Text(L10n.string("ui.31eafc88cde6f593"))
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ForEach(snapshot.duplicateGroups) { group in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L10n.string("ui.9f9ad98d5023adfc", String(describing: group.files.count)))
                                    .font(.headline)
                                Spacer()
                                Text(L10n.string("ui.397c2c34dd163883", String(describing: byteCount(group.reclaimableBytes))))
                                    .foregroundStyle(.orange)
                            }
                            ForEach(group.files) { file in
                                HStack {
                                    Text(file.path)
                                        .lineLimit(1)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Text(byteCount(file.sizeBytes))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .font(.callout)
                            }
                        }
                        .padding(4)
                    }
                }
            }
        }
    }
}

private struct StorageView: View {
    let snapshot: NasStorageSnapshot?
    let testStatuses: [String: NasDiskTestStatus]
    let busyDiskIDs: Set<String>
    let loadTestStatus: (String) async throws -> Void
    let startTest: (String, NasDiskTestType) async throws -> Void
    let stopTest: (String) async throws -> Void

    @State private var selection: StorageDetailSelection?

    var body: some View {
        ScrollView {
            if let snapshot {
                VStack(alignment: .leading, spacing: 22) {
                    SectionHeader(title: L10n.string("ui.26de3dd933ce00e3"), count: snapshot.volumes.count)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(snapshot.volumes) { volume in
                            Button {
                                selection = .volume(volume)
                            } label: {
                                CapacityCard(
                                    title: volume.name,
                                    subtitle: [volume.fileSystem, storageStatusText(volume.status)]
                                        .compactMap { $0 }
                                        .joined(separator: " · "),
                                    used: volume.usedBytes,
                                    total: volume.totalBytes,
                                    icon: "externaldrive"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(L10n.string("ui.9485a9c23c18d624"))
                        }
                    }

                    SectionHeader(title: L10n.string("ui.ba380b79ff47c4c2"), count: snapshot.pools.count)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                        ForEach(snapshot.pools) { pool in
                            Button {
                                selection = .pool(pool)
                            } label: {
                                CapacityCard(
                                    title: pool.name,
                                    subtitle: [pool.raidType, storageStatusText(pool.status)]
                                        .compactMap { $0 }
                                        .joined(separator: " · "),
                                    used: pool.usedBytes,
                                    total: pool.totalBytes,
                                    icon: "square.stack.3d.up"
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(L10n.string("ui.bd724d9515edda8a"))
                        }
                    }

                    SectionHeader(title: L10n.string("ui.1e7098fe0f6eaae2"), count: snapshot.disks.count)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(snapshot.disks) { disk in
                            Button {
                                selection = .disk(disk)
                            } label: {
                                DiskCard(disk: disk, testStatus: testStatuses[disk.id])
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(L10n.string("ui.e5ad27587f394f41"))
                        }
                    }
                }
                .padding(24)
            }
        }
        .sheet(item: $selection) { selection in
            StorageDetailSheet(
                selection: selection,
                snapshot: snapshot,
                testStatus: {
                    guard case .disk(let disk) = selection else { return nil }
                    return testStatuses[disk.id]
                }(),
                isDiskBusy: {
                    guard case .disk(let disk) = selection else { return false }
                    return busyDiskIDs.contains(disk.id)
                }(),
                loadTestStatus: loadTestStatus,
                startTest: startTest,
                stopTest: stopTest
            )
        }
    }
}

private enum DisplayMode: String, CaseIterable, Identifiable {
    case list = "ui.aedd6814ff8c516c"
    case grid = "ui.fb5640f8e12e3337"
    var id: Self { self }

    var icon: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        }
    }
}

private enum StorageDetailSelection: Identifiable {
    case volume(NasVolume)
    case pool(NasStoragePool)
    case disk(NasDisk)

    var id: String {
        switch self {
        case .volume(let volume): "volume:\(volume.id)"
        case .pool(let pool): "pool:\(pool.id)"
        case .disk(let disk): "disk:\(disk.id)"
        }
    }
}

private struct CapacityCard: View {
    let title: String
    let subtitle: String
    let used: Int64?
    let total: Int64?
    let icon: String

    private var ratio: Double? {
        guard let used, let total, total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Label(title, systemImage: icon)
                        .font(.headline)
                    Spacer()
                    Label(L10n.string("ui.a748cc074f78de00"), systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text(used.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L10n.string("ui.4d8c1c5b42830791"))
                    Spacer()
                    Text(total.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L10n.string("ui.4d8c1c5b42830791"))
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                if let ratio {
                    ProgressView(value: ratio)
                        .accessibilityLabel(title)
                        .accessibilityValue(L10n.string("ui.cb1758dd87db4aae", String(describing: (ratio * 100).formatted(.number.precision(.fractionLength(0))))))
                }
            }
            .padding(6)
            .contentShape(Rectangle())
        }
    }
}

private struct DiskCard: View {
    let disk: NasDisk
    let testStatus: NasDiskTestStatus?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Label(disk.name, systemImage: disk.isSSD ? "memorychip" : "internaldrive")
                        .font(.headline)
                    Spacer()
                    HStack(spacing: 8) {
                        StatusPill(
                            text: storageStatusText(disk.status) ?? L10n.string("ui.93e474c68ed55647"),
                            isWarning: isWarning(disk.status)
                        )
                        Label(L10n.string("ui.a748cc074f78de00"), systemImage: "chevron.right")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let model = disk.model {
                    Text([disk.vendor, model].compactMap { $0 }.joined(separator: " "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 6) {
                    HStack {
                        Text(L10n.string("ui.d8272b3c5f197b58")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(byteCount(disk.totalBytes)).font(.caption.weight(.medium))
                    }
                    HStack {
                        Text(L10n.string("storage.smart")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(
                            testStatus?.isRunning == true
                                ? L10n.string("ui.2b5941013cfefb7a")
                                : storageStatusText(disk.smartStatus)
                                    ?? (disk.supportsSmartTest ? L10n.string("ui.9f0d1751bf3d4c46") : L10n.string("ui.756762e293f2aaff"))
                        ).font(.caption.weight(.medium))
                    }
                    if let temperature = disk.temperatureCelsius {
                        HStack {
                            Text(L10n.string("ui.3732e264dfa95cae")).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(temperature.formatted(.number.precision(.fractionLength(0))))℃")
                                .font(.caption.weight(.medium))
                        }
                    }
                }
            }
            .padding(6)
            .contentShape(Rectangle())
        }
    }
}

private struct StorageDetailSheet: View {
    let selection: StorageDetailSelection
    let snapshot: NasStorageSnapshot?
    let testStatus: NasDiskTestStatus?
    let isDiskBusy: Bool
    let loadTestStatus: (String) async throws -> Void
    let startTest: (String, NasDiskTestType) async throws -> Void
    let stopTest: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingTestType: NasDiskTestType?
    @State private var showStopTestConfirm = false
    @State private var isLoadingStatus = false
    @State private var message: String?
    @State private var testStatusError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selection {
                    case .volume(let volume):
                        volumeDetails(volume)
                    case .pool(let pool):
                        poolDetails(pool)
                    case .disk(let disk):
                        diskDetails(disk)
                    }
                }
                .padding(24)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("ui.3fd47edce45b3603")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 480, idealHeight: 580)
        .confirmationDialog(
            pendingTestType == .extended ? L10n.string("ui.2af894351735b6b2") : L10n.string("ui.4a1b05399e6f67e5"),
            isPresented: Binding(
                get: { pendingTestType != nil },
                set: { if !$0 { pendingTestType = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingTestType {
                Button(pendingTestType == .extended ? L10n.string("ui.8e633fa28061f170") : L10n.string("ui.c09a70021eb37cd0")) {
                    beginTest(pendingTestType)
                }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(testConfirmationMessage)
        }
        .confirmationDialog(
            L10n.string("ui.1b9c2c6c1c1184d8"),
            isPresented: $showStopTestConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.c94345e7ee036366"), role: .cancel) {}
            Button(L10n.string("ui.605fca0de8478944"), role: .destructive) {
                stopCurrentTest()
            }
        } message: {
            Text(L10n.string("ui.d0b8762f8066116a"))
        }
    }

    private var title: String {
        switch selection {
        case .volume(let volume): volume.name
        case .pool(let pool): pool.name
        case .disk(let disk): L10n.string("ui.e2adcced2dca9394", String(describing: disk.name))
        }
    }

    @ViewBuilder
    private func volumeDetails(_ volume: NasVolume) -> some View {
        detailHeader(
            icon: "externaldrive",
            title: volume.name,
            status: volume.status
        )
        DetailSection(title: L10n.string("ui.d8272b3c5f197b58")) {
            DetailValueRow(title: L10n.string("ui.9845c165151daee3"), value: byteCount(volume.usedBytes))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.9e4972cf66420340"), value: byteCount(volume.totalBytes))
            Divider().opacity(0.4)
            DetailValueRow(
                title: L10n.string("ui.21e4406096127b26"),
                value: byteCount(availableBytes(used: volume.usedBytes, total: volume.totalBytes))
            )
        }
        DetailSection(title: L10n.string("ui.e7028601e7da793d")) {
            DetailValueRow(title: L10n.string("ui.47b6174788b64db5"), value: volume.fileSystem ?? L10n.string("ui.756762e293f2aaff"))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.64a316a3dda35b2a"), value: poolName(for: volume.poolID) ?? L10n.string("ui.756762e293f2aaff"))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.1fb4d574da92f1c1"), value: volume.path ?? L10n.string("ui.756762e293f2aaff"))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.320c254572c48488"), value: volume.isEncrypted ? L10n.string("ui.b66975fbd35fa85d") : L10n.string("ui.7c568abbd672a29b"))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.02899fd66a4138da"), value: volume.isWritable ? L10n.string("ui.b00028289a40061a") : L10n.string("ui.3b5ec3533b0e4485"))
        }
    }

    @ViewBuilder
    private func poolDetails(_ pool: NasStoragePool) -> some View {
        detailHeader(
            icon: "square.stack.3d.up",
            title: pool.name,
            status: pool.status
        )
        DetailSection(title: L10n.string("ui.d8272b3c5f197b58")) {
            DetailValueRow(title: L10n.string("ui.9845c165151daee3"), value: byteCount(pool.usedBytes))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.9e4972cf66420340"), value: byteCount(pool.totalBytes))
            Divider().opacity(0.4)
            DetailValueRow(
                title: L10n.string("ui.21e4406096127b26"),
                value: byteCount(availableBytes(used: pool.usedBytes, total: pool.totalBytes))
            )
        }
        DetailSection(title: L10n.string("ui.148d195e21b05db5")) {
            DetailValueRow(title: L10n.string("ui.f0ce89906e42d561"), value: pool.raidType ?? L10n.string("ui.756762e293f2aaff"))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.02899fd66a4138da"), value: pool.isWritable ? L10n.string("ui.b00028289a40061a") : L10n.string("ui.3b5ec3533b0e4485"))
            Divider().opacity(0.4)
            DetailValueRow(
                title: L10n.string("ui.e19a4386e921ddda"),
                value: pool.supportsMultipleVolumes.map { $0 ? L10n.string("ui.d93373f81363e3cc") : L10n.string("ui.7c5378606570020b") } ?? L10n.string("ui.756762e293f2aaff")
            )
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.1e7098fe0f6eaae2"), value: diskNames(for: pool.diskIDs))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.10068c390c1b7106"), value: diskNames(for: pool.spareDiskIDs))
            if pool.isScrubbing {
                Divider().opacity(0.4)
                DetailValueRow(title: L10n.string("ui.b69ac4021aeb68bd"), value: L10n.string("ui.055da4d50c7e6524"))
            } else if let date = pool.nextScrubbingDate {
                Divider().opacity(0.4)
                DetailValueRow(
                    title: L10n.string("ui.b4f2550d09b20994"),
                    value: date.formatted(date: .abbreviated, time: .shortened)
                )
            }
        }
    }

    @ViewBuilder
    private func diskDetails(_ disk: NasDisk) -> some View {
        detailHeader(
            icon: disk.isSSD ? "memorychip" : "internaldrive",
            title: disk.name,
            status: disk.status
        )

        if let message {
            Label(message, systemImage: "info.circle.fill")
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .combine)
        }

        DetailSection(title: L10n.string("ui.f1a586cb6b297efe")) {
            DetailValueRow(
                title: L10n.string("ui.322408c53beda26b"),
                value: diskModelDescription(disk)
            )
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.ba40014ff496f64e"), value: disk.type ?? (disk.isSSD ? "SSD" : "HDD"))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.d8272b3c5f197b58"), value: byteCount(disk.totalBytes))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.1fb4d574da92f1c1"), value: disk.location ?? L10n.string("ui.756762e293f2aaff"))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.7394a2e11d9d511d"), value: poolName(for: disk.usedBy) ?? L10n.string("ui.52496e5aeff43353"))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.94854c89ae715c4d"), value: disk.serialNumber ?? L10n.string("ui.756762e293f2aaff"))
            Divider().opacity(0.4)
            DetailValueRow(title: L10n.string("ui.e5b17aa7b4420a59"), value: disk.firmwareVersion ?? L10n.string("ui.756762e293f2aaff"))
            Divider().opacity(0.4)
            DetailValueRow(
                title: L10n.string("ui.a2bcbaab777f5f33"),
                value: disk.is4KNative.map { $0 ? L10n.string("ui.b5141d3d19e9a048") : L10n.string("ui.0c70665b6eb65f1a") } ?? L10n.string("ui.756762e293f2aaff")
            )
        }

        DetailSection(title: L10n.string("ui.85788192fbeb1559")) {
            DetailValueRow(
                title: "S.M.A.R.T.",
                value: storageStatusText(disk.smartStatus) ?? L10n.string("ui.756762e293f2aaff")
            )
            if let temperature = disk.temperatureCelsius {
                Divider().opacity(0.4)
                DetailValueRow(
                    title: L10n.string("ui.3732e264dfa95cae"),
                    value: "\(temperature.formatted(.number.precision(.fractionLength(0))))℃"
                )
            }
            if let estimatedLifePercent = disk.estimatedLifePercent {
                Divider().opacity(0.4)
                DetailValueRow(title: L10n.string("ui.084cdd3bd691b577"), value: "\(estimatedLifePercent)%")
            }
            if let badSectorCount = disk.badSectorCount {
                Divider().opacity(0.4)
                DetailValueRow(title: L10n.string("ui.59276986a35a5ee8"), value: badSectorCount.formatted())
            }
        }

        smartTestSection(disk)
            .task(id: disk.id) {
                await refreshTestStatus(disk.id, reportsError: true)
            }
            .task(id: testStatus?.isRunning) {
                while testStatus?.isRunning == true, !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(4))
                    } catch {
                        return
                    }
                    await refreshTestStatus(disk.id, reportsError: false)
                }
            }
    }

    @ViewBuilder
    private func smartTestSection(_ disk: NasDisk) -> some View {
        DetailSection(title: L10n.string("ui.56407b34cf24fff9")) {
            if let testStatusError {
                Label(testStatusError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else if isLoadingStatus, testStatus == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.string("ui.f648f64ea3808f65"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else if testStatus?.isRunning == true {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(testStatus?.runningType == .extended ? L10n.string("ui.5348d00e4c4f4e24") : L10n.string("ui.a11397d11730995b"))
                            .font(.subheadline.weight(.medium))
                        if let progress = testStatus?.progressDescription, !progress.isEmpty {
                            Text(progress).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else if testStatus?.isBusyWithOtherTest == true {
                Label(
                    L10n.string("ui.05237464f2f31ef4"),
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }

            if let testStatus {
                if testStatus.isHistoryAvailable {
                    DetailValueRow(
                        title: L10n.string("ui.785c6da4969257b2"),
                        value: smartTestTimeText(testStatus.lastQuickTest)
                    )
                    Divider().opacity(0.4)
                    DetailValueRow(
                        title: L10n.string("ui.49b365c501f835cb"),
                        value: smartTestTimeText(testStatus.lastExtendedTest)
                    )
                } else {
                    Label(
                        L10n.string("ui.a35aaa5ca137e151"),
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            }
            if let result = testStatus?.lastResult {
                Divider().opacity(0.4)
                DetailValueRow(title: L10n.string("ui.8f0ef3b2b86d2fb3"), value: smartResultText(result))
            }

            Divider().opacity(0.4).padding(.vertical, 2)

            HStack(spacing: 10) {
                if testStatus?.isRunning == true {
                    Button(L10n.string("ui.f26a82f0afc23414"), role: .destructive) {
                        showStopTestConfirm = true
                    }
                    .disabled(isLoadingStatus || isDiskBusy)
                    .accessibilityHint(L10n.string("ui.f13df6406802a1d9"))
                } else {
                    Button(L10n.string("ui.6e9caf206065b778")) {
                        pendingTestType = .quick
                    }
                    .disabled(!canStartTest(disk))
                    .accessibilityHint(L10n.string("ui.380485dd92387bc2"))

                    Button(L10n.string("ui.5554d06b7b8152c6")) {
                        pendingTestType = .extended
                    }
                    .disabled(!canStartTest(disk))
                    .accessibilityHint(L10n.string("ui.bc3c58ae8d17d7f4"))
                }

                Spacer()

                Button {
                    Task { await refreshTestStatus(disk.id, reportsError: true) }
                } label: {
                    Label(L10n.string("ui.802a407c774302aa"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoadingStatus || isDiskBusy)
                .accessibilityHint(L10n.string("ui.c535140a29494034"))
            }
            .padding(.top, 4)

            if !disk.supportsSmartTest {
                Text(L10n.string("ui.affdb1b5d9e5b288"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    private func detailHeader(icon: String, title: String, status: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.bold))
                StatusPill(
                    text: storageStatusText(status) ?? L10n.string("ui.93e474c68ed55647"),
                    isWarning: isWarning(status)
                )
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func poolName(for id: String?) -> String? {
        guard let id else { return nil }
        return snapshot?.pools.first(where: { $0.id == id })?.name
    }

    private func diskNames(for ids: [String]) -> String {
        guard !ids.isEmpty else { return L10n.string("ui.484d55613910eb8c") }
        let names = ids.map { id in
            snapshot?.disks.first(where: { $0.id == id })?.name ?? id
        }
        return names.joined(separator: "、")
    }

    private func diskModelDescription(_ disk: NasDisk) -> String {
        let value = [disk.vendor, disk.model].compactMap { $0 }.joined(separator: " ")
        return value.isEmpty ? L10n.string("ui.756762e293f2aaff") : value
    }

    private func smartTestTimeText(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return L10n.string("ui.46ca86da52b3db5c") }
        let date: Date?
        if let timestamp = Double(value) {
            date = Date(
                timeIntervalSince1970: timestamp > 10_000_000_000
                    ? timestamp / 1_000
                    : timestamp
            )
        } else {
            date = ISO8601DateFormatter().date(from: value)
        }
        return date?.formatted(date: .abbreviated, time: .standard) ?? value
    }

    private func canStartTest(_ disk: NasDisk) -> Bool {
        disk.supportsSmartTest
            && testStatus != nil
            && testStatusError == nil
            && testStatus?.isRunning != true
            && testStatus?.isBusyWithOtherTest != true
            && !isLoadingStatus
            && !isDiskBusy
    }

    private var testConfirmationMessage: String {
        if pendingTestType == .extended {
            return L10n.string("ui.f9ce1451d7fa633a")
        }
        return L10n.string("ui.ab28f3ef53f07e77")
    }

    private func beginTest(_ type: NasDiskTestType) {
        guard case .disk(let disk) = selection else { return }
        pendingTestType = nil
        message = nil
        Task {
            do {
                try await startTest(disk.id, type)
                guard !Task.isCancelled else { return }
                message = type == .extended ? L10n.string("ui.13f8e4d6e493f0e2") : L10n.string("ui.7ca7666a8802812b")
            } catch {
                message = (error as? AppError)?.safeUserMessage
                    ?? L10n.string("ui.2283e70152a7033f")
            }
        }
    }

    private func stopCurrentTest() {
        guard case .disk(let disk) = selection else { return }
        message = nil
        Task {
            do {
                try await stopTest(disk.id)
                guard !Task.isCancelled else { return }
                message = L10n.string("ui.8ac5fb00b1e6f4cd")
            } catch {
                message = (error as? AppError)?.safeUserMessage
                    ?? L10n.string("ui.623aa2293401b4a5")
            }
        }
    }

    private func refreshTestStatus(_ diskID: String, reportsError: Bool) async {
        guard !isLoadingStatus else { return }
        isLoadingStatus = true
        if reportsError {
            testStatusError = nil
        }
        defer { isLoadingStatus = false }
        do {
            try await loadTestStatus(diskID)
            testStatusError = nil
        } catch is CancellationError {
            return
        } catch {
            if reportsError {
                testStatusError = (error as? AppError)?.safeUserMessage
                    ?? L10n.string("ui.82e9fcbc8d0b608b")
            }
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            Spacer(minLength: 16)

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

private struct PerformanceDashboard: View {
    let overview: NasSystemOverview?
    let history: [NasPerformanceSnapshot]
    let connections: NasConnectionPage?
    @Binding var isPaused: Bool
    let refresh: () async -> Void
    let onNavigateToConnections: () -> Void
    let isPowerActionBusy: Bool
    let onPerformPowerAction: (
        (NasPowerAction) async throws -> MutationResult
    )?
    let onCheckSystemUpdate: (() async throws -> NasSystemUpdateInfo)?

    @State private var showShutdownConfirm = false
    @State private var showRebootConfirm = false
    @State private var isCheckingSystemUpdate = false
    @State private var powerActionAlertTitle = ""
    @State private var powerActionAlertMessage = ""
    @State private var showPowerActionAlert = false
    @State private var updateAlertTitle: String = L10n.string("ui.101da319b2a7ef1c")
    @State private var updateAlertMessage: String? = nil
    @State private var showUpdateAlert = false

    private var latest: NasPerformanceSnapshot? { history.last }

    private let mainDashboardColumns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                dashboardHeader

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)], spacing: 12) {
                    MetricCard(title: L10n.string("ui.43b8de30fe4bab74"), value: percent(latest?.cpuUsage), icon: "cpu", progress: latest?.cpuUsage, tint: .blue)
                    MetricCard(title: L10n.string("ui.7d8f8c37ec7885bc"), value: percent(latest?.memoryUsage), icon: "memorychip", progress: latest?.memoryUsage, tint: .purple)
                    MetricCard(title: L10n.string("ui.686e07a16801ddf2"), value: speed(latest?.networkReceivedBytesPerSecond), icon: "arrow.down", tint: .green)
                    MetricCard(title: L10n.string("ui.a40f7cba9a03065c"), value: speed(latest?.networkSentBytesPerSecond), icon: "arrow.up", tint: .teal)
                    MetricCard(title: L10n.string("ui.374ea05318d9c904"), value: speed(latest?.diskReadBytesPerSecond), icon: "internaldrive", tint: .orange)
                    MetricCard(title: L10n.string("ui.aa6da089e94a6b9f"), value: speed(latest?.diskWriteBytesPerSecond), icon: "internaldrive.fill", tint: .indigo)
                }

                if history.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(L10n.string("ui.3e89d0dc0208a69c"))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    LazyVGrid(columns: mainDashboardColumns, spacing: 16) {
                        PerformanceChartCard(
                            title: L10n.string("ui.02e204b5df587f2b"),
                            subtitle: L10n.string("ui.7f5cc0a851ac4208"),
                            unit: "%",
                            chart: percentageChart
                        )
                        PerformanceChartCard(
                            title: L10n.string("ui.b2341108e587a772"),
                            subtitle: L10n.string("ui.aa9feeb265adaebf"),
                            unit: L10n.string("ui.bb04885264dcd5f0"),
                            chart: networkChart
                        )
                        PerformanceChartCard(
                            title: L10n.string("ui.66058307ba084ef2"),
                            subtitle: L10n.string("ui.7578dff495c79979"),
                            unit: L10n.string("ui.bb04885264dcd5f0"),
                            chart: storageChart
                        )
                        ActiveConnectionsCard(
                            connections: connections,
                            onNavigate: onNavigateToConnections
                        )
                    }
                }
            }
            .padding(20)
        }
        .confirmationDialog(L10n.string("ui.8195cd7121749f82"), isPresented: $showShutdownConfirm, titleVisibility: .visible) {
            Button(L10n.string("ui.bc9f788c6c9933bd"), role: .destructive) {
                performPowerAction(.shutdown)
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.1883fa0694806094"))
        }
        .confirmationDialog(L10n.string("ui.6a46e64958540614"), isPresented: $showRebootConfirm, titleVisibility: .visible) {
            Button(L10n.string("ui.4a7dfba7106183fc"), role: .destructive) {
                performPowerAction(.reboot)
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            Text(L10n.string("ui.2d2b6c1494a654d7"))
        }
        .alert(powerActionAlertTitle, isPresented: $showPowerActionAlert) {
            Button(L10n.string("ui.fac2a67ad87807c4"), role: .cancel) {}
        } message: {
            Text(powerActionAlertMessage)
        }
        .alert(updateAlertTitle, isPresented: $showUpdateAlert) {
            Button(L10n.string("ui.fac2a67ad87807c4"), role: .cancel) {}
        } message: {
            if let updateAlertMessage {
                Text(updateAlertMessage)
            }
        }
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(overview?.serverName ?? "NAS")
                            .font(.title.weight(.bold))
                            .textSelection(.enabled)

                        if let model = overview?.model {
                            Text(model)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }

                        if let version = overview?.version {
                            Text(version)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()

                HStack(spacing: 8) {
                    Button {
                        checkSystemUpdate()
                    } label: {
                        Label(
                            L10n.string("ui.48954b3a9a918624"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isCheckingSystemUpdate)

                    Menu {
                        Button(role: .destructive) {
                            showRebootConfirm = true
                        } label: {
                            Label(L10n.string("ui.301353687f12cedf"), systemImage: "arrow.clockwise.circle")
                        }

                        Button(role: .destructive) {
                            showShutdownConfirm = true
                        } label: {
                            Label(L10n.string("ui.5acf2082d7fd4f9e"), systemImage: "power")
                        }
                    } label: {
                        if isPowerActionBusy {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(L10n.string("power.action.sending"))
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(
                                L10n.string("power.action.sending")
                            )
                        } else {
                            Label(
                                L10n.string("ui.ec8d59ceec9ed48e"),
                                systemImage: "power"
                            )
                        }
                    }
                    .menuStyle(.borderedButton)
                    .controlSize(.small)
                    .disabled(isPowerActionBusy || isCheckingSystemUpdate)

                    Button {
                        isPaused.toggle()
                    } label: {
                        Label(isPaused ? L10n.string("ui.a6d2451928165b24") : L10n.string("ui.8c78e736df180bf3"), systemImage: isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(isPaused ? L10n.string("ui.55a1c68a11cec535") : L10n.string("ui.3520cd6a732829bb"))

                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(L10n.string("ui.aee88743413144a2"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if let overview {
                HStack(spacing: 16) {
                    SystemInfoBadge(icon: "cpu", label: L10n.string("ui.43b8de30fe4bab74"), value: [overview.cpuModel, overview.cpuCoreCount.map { L10n.string("ui.d28a48164279209f", String(describing: $0)) }].compactMap { $0 }.joined(separator: " · "))
                    if let memory = overview.memoryBytes {
                        SystemInfoBadge(icon: "memorychip", label: L10n.string("ui.7d8f8c37ec7885bc"), value: ByteCountFormatter.string(fromByteCount: memory, countStyle: .memory))
                    }
                    if let temperature = overview.temperatureCelsius {
                        SystemInfoBadge(icon: "thermometer.medium", label: L10n.string("ui.3732e264dfa95cae"), value: "\(temperature.formatted(.number.precision(.fractionLength(0))))℃")
                    }
                    if let uptime = overview.uptimeSeconds {
                        SystemInfoBadge(icon: "clock", label: L10n.string("ui.1add43f798162a38"), value: uptimeDescription(uptime))
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func powerActionError(_ error: Error) -> String {
        (error as? AppError)?.safeUserMessage
            ?? L10n.string("ui.115497be67470c77")
    }

    private func performPowerAction(_ action: NasPowerAction) {
        guard !isPowerActionBusy, let onPerformPowerAction else { return }
        Task {
            do {
                let result = try await onPerformPowerAction(action)
                powerActionAlertTitle = switch result.status {
                case .confirmedSuccess:
                    L10n.string("power.action.accepted-title")
                case .submittedButUnverified,
                     .cancellationRequestedAfterSubmission,
                     .partialSuccess:
                    L10n.string("power.action.attention-title")
                case .cancelledBeforeSubmission:
                    L10n.string("power.action.cancelled-title")
                case .confirmedFailure, .permissionDenied, .unsupported:
                    L10n.string("power.action.failed-title")
                }
                powerActionAlertMessage = L10n.string(
                    result.localizationKey ?? "power.action.rejected"
                )
            } catch {
                powerActionAlertTitle = L10n.string(
                    "power.action.failed-title"
                )
                powerActionAlertMessage = powerActionError(error)
            }
            showPowerActionAlert = true
        }
    }

    private func checkSystemUpdate() {
        guard !isCheckingSystemUpdate, let onCheckSystemUpdate else { return }
        isCheckingSystemUpdate = true
        Task {
            defer { isCheckingSystemUpdate = false }
            do {
                let info = try await onCheckSystemUpdate()
                if info.isUpdateAvailable {
                    updateAlertTitle = L10n.string("ui.ac217e4d1ca410f1")
                    let version = info.latestVersion
                        ?? L10n.string("system-update.version-unknown")
                    if let releaseNotes = info.releaseNotes {
                        updateAlertMessage = L10n.string(
                            "system-update.available-with-notes",
                            version,
                            releaseNotes
                        )
                    } else {
                        updateAlertMessage = L10n.string(
                            "system-update.available",
                            version
                        )
                    }
                } else if let current = info.currentVersion {
                    updateAlertTitle = L10n.string("ui.bc310480b4ce9236")
                    updateAlertMessage = L10n.string("ui.2744a3e4d928c6d6", String(describing: current))
                } else {
                    updateAlertTitle = L10n.string("ui.101da319b2a7ef1c")
                    updateAlertMessage = L10n.string("ui.0d8f9e8efd964bef")
                }
            } catch {
                updateAlertTitle = L10n.string("ui.d07abfb11e7e0d48")
                updateAlertMessage = (error as? AppError)?.safeUserMessage
                    ?? L10n.string("ui.e3b91993e9c3f67e")
            }
            showUpdateAlert = true
        }
    }

    private var percentageChart: some View {
        Chart(history) { point in
            AreaMark(
                x: .value(L10n.string("ui.8b6ff498515bcc2f"), point.recordedAt),
                y: .value(L10n.string("ui.9746ae777abb6dbf"), point.cpuUsage)
            )
            .foregroundStyle(by: .value(L10n.string("ui.b87e67c7dae03991"), L10n.string("ui.43b8de30fe4bab74")))

            AreaMark(
                x: .value(L10n.string("ui.8b6ff498515bcc2f"), point.recordedAt),
                y: .value(L10n.string("ui.9746ae777abb6dbf"), point.memoryUsage)
            )
            .foregroundStyle(by: .value(L10n.string("ui.b87e67c7dae03991"), L10n.string("ui.7d8f8c37ec7885bc")))
        }
        .chartYScale(domain: 0...100)
    }

    private var networkChart: some View {
        Chart(history) { point in
            LineMark(
                x: .value(L10n.string("ui.8b6ff498515bcc2f"), point.recordedAt),
                y: .value(L10n.string("ui.a918a345eb435745"), Double(point.networkReceivedBytesPerSecond) / 1_024)
            )
            .foregroundStyle(by: .value(L10n.string("ui.1121471a0ff440f8"), L10n.string("ui.6e684586884ebee6")))

            LineMark(
                x: .value(L10n.string("ui.8b6ff498515bcc2f"), point.recordedAt),
                y: .value(L10n.string("ui.a918a345eb435745"), Double(point.networkSentBytesPerSecond) / 1_024)
            )
            .foregroundStyle(by: .value(L10n.string("ui.1121471a0ff440f8"), L10n.string("ui.edecf0ae6e5144f9")))
        }
    }

    private var storageChart: some View {
        Chart(history) { point in
            LineMark(
                x: .value(L10n.string("ui.8b6ff498515bcc2f"), point.recordedAt),
                y: .value(L10n.string("ui.a918a345eb435745"), Double(point.diskReadBytesPerSecond) / 1_024)
            )
            .foregroundStyle(by: .value(L10n.string("ui.ed31fbb483ee1b0a"), L10n.string("ui.534cb3fa8fbf373f")))

            LineMark(
                x: .value(L10n.string("ui.8b6ff498515bcc2f"), point.recordedAt),
                y: .value(L10n.string("ui.a918a345eb435745"), Double(point.diskWriteBytesPerSecond) / 1_024)
            )
            .foregroundStyle(by: .value(L10n.string("ui.ed31fbb483ee1b0a"), L10n.string("ui.5c783c4679655185")))
        }
    }
}

private struct PackageList: View {
    private struct PendingControl {
        let package: NasPackage
        let action: NasPackageAction
    }

    let packages: [NasPackage]
    let title: String
    let busyPackageIDs: Set<String>
    let onControlPackage: ((String, NasPackageAction) async throws -> Void)?

    init(
        packages: [NasPackage],
        title: String,
        busyPackageIDs: Set<String> = [],
        onControlPackage: ((String, NasPackageAction) async throws -> Void)? = nil
    ) {
        self.packages = packages
        self.title = title
        self.busyPackageIDs = busyPackageIDs
        self.onControlPackage = onControlPackage
    }

    private enum DisplayMode: String, CaseIterable, Identifiable {
        case grid = "grid"
        case list = "list"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
        var label: String {
            switch self {
            case .grid: return L10n.string("ui.fb5640f8e12e3337")
            case .list: return L10n.string("ui.aedd6814ff8c516c")
            }
        }
    }

    @State private var searchText = ""
    @State private var packageToUninstall: NasPackage? = nil
    @State private var pendingControl: PendingControl? = nil
    @State private var actionError: String? = nil
    @AppStorage("packageDisplayMode") private var displayModeRaw: String = DisplayMode.grid.rawValue

    private var displayMode: DisplayMode {
        get { DisplayMode(rawValue: displayModeRaw) ?? .grid }
        set { displayModeRaw = newValue.rawValue }
    }

    private var filtered: [NasPackage] {
        guard !searchText.isEmpty else { return packages }
        return packages.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.id.localizedCaseInsensitiveContains(searchText)
                || ($0.packageDescription?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 14)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.9b8d987fe9376800", String(describing: filtered.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker(L10n.string("ui.9f8f3cc264bae3ce"), selection: $displayModeRaw) {
                    ForEach(DisplayMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.icon).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 90)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(L10n.string("ui.47938644fb53e315"), systemImage: "shippingbox", description: Text(L10n.string("ui.db67c6383ce3e747")))
                    .frame(maxHeight: .infinity)
            } else {
                switch displayMode {
                case .grid:
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(filtered) { package in
                                PackageCard(
                                    package: package,
                                    isBusy: busyPackageIDs.contains(package.id),
                                    onControl: { action in
                                        handleAction(package: package, action: action)
                                    }
                                )
                            }
                        }
                        .padding(16)
                    }
                case .list:
                    List(filtered) { package in
                        PackageRow(
                            package: package,
                            isBusy: busyPackageIDs.contains(package.id),
                            onControl: { action in
                                handleAction(package: package, action: action)
                            }
                        )
                    }
                    .listStyle(.inset)
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $searchText, prompt: L10n.string("ui.30f6e9928347c1d6"))
        .alert(L10n.string("ui.bcdf89eee8276d3f"), isPresented: Binding(
            get: { packageToUninstall != nil },
            set: { if !$0 { packageToUninstall = nil } }
        )) {
            Button(L10n.string("ui.4fec200ac3f7fc85"), role: .destructive) {
                if let pkg = packageToUninstall {
                    packageToUninstall = nil
                    Task {
                        do {
                            try await onControlPackage?(pkg.id, .uninstall)
                        } catch {
                            actionError = packageActionError(
                                error,
                                packageName: pkg.name,
                                actionText: L10n.string("ui.06bc14b60f3598a3")
                            )
                        }
                    }
                }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            if let pkg = packageToUninstall {
                Text(L10n.string("ui.f1ff4c701fff6787", String(describing: pkg.name)))
            }
        }
        .alert(controlConfirmationTitle, isPresented: Binding(
            get: { pendingControl != nil },
            set: { if !$0 { pendingControl = nil } }
        )) {
            if let pendingControl {
                Button(
                    controlConfirmationButton(pendingControl.action),
                    role: pendingControl.action == .stop ? .destructive : nil
                ) {
                    self.pendingControl = nil
                    performControl(
                        package: pendingControl.package,
                        action: pendingControl.action
                    )
                }
            }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: {
            if let pendingControl {
                Text(
                    L10n.string(
                        pendingControl.action == .start
                            ? "package.start.confirm-message"
                            : "package.stop.confirm-message",
                        String(describing: pendingControl.package.name)
                    )
                )
            }
        }
        .alert(L10n.string("ui.e147727c86db353b"), isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button(L10n.string("ui.fac2a67ad87807c4"), role: .cancel) {}
        } message: {
            if let actionError {
                Text(actionError)
            }
        }
    }

    private func handleAction(package: NasPackage, action: NasPackageAction) {
        if action == .uninstall {
            packageToUninstall = package
            return
        }
        if action == .upgrade {
            performControl(package: package, action: action)
            return
        }
        pendingControl = PendingControl(package: package, action: action)
    }

    private func performControl(
        package: NasPackage,
        action: NasPackageAction
    ) {
        Task {
            do {
                try await onControlPackage?(package.id, action)
            } catch {
                let actionText = action == .stop ? L10n.string("ui.8d12fc0d4eb26021") : (action == .start ? L10n.string("ui.56410fc65314dfb5") : L10n.string("ui.3055a035f0eb7a8b"))
                actionError = packageActionError(
                    error,
                    packageName: package.name,
                    actionText: actionText
                )
            }
        }
    }

    private var controlConfirmationTitle: String {
        guard let pendingControl else { return "" }
        return L10n.string(
            pendingControl.action == .start
                ? "package.start.confirm-title"
                : "package.stop.confirm-title"
        )
    }

    private func controlConfirmationButton(
        _ action: NasPackageAction
    ) -> String {
        L10n.string(
            action == .start
                ? "package.start.confirm-button"
                : "package.stop.confirm-button"
        )
    }

    private func packageActionError(
        _ error: Error,
        packageName: String,
        actionText: String
    ) -> String {
        let message = (error as? AppError)?.safeUserMessage
            ?? L10n.string("ui.3c311955d51d6210")
        return L10n.string("ui.f9e493557350b30d", String(describing: actionText), String(describing: packageName), String(describing: message))
    }
}

private struct PackageCard: View {
    let package: NasPackage
    let isBusy: Bool
    let onControl: (NasPackageAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                PackageIconView(package: package)

                VStack(alignment: .leading, spacing: 2) {
                    Text(package.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text([package.version, package.installType].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if let description = package.packageDescription, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            } else {
                Spacer()
                    .frame(height: 32)
            }

            HStack(alignment: .center) {
                StatusPill(
                    text: package.statusDescription ?? package.status ?? L10n.string("ui.40fae00b7c6d8ac0"),
                    isWarning: isWarning(package.status)
                )

                if package.isUpgradeAvailable {
                    PackageUpgradeAvailabilityLabel()
                }

                Spacer()

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(
                            L10n.string("package.control.in-progress")
                        )
                } else {
                    HStack(spacing: 6) {
                        if package.canUpgrade {
                            Button {
                                triggerAction(.upgrade)
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(L10n.string("ui.5dafce9fd14a5c3d"))
                        }

                        if package.canStop {
                            Button {
                                triggerAction(.stop)
                            } label: {
                                Label(L10n.string("ui.8d12fc0d4eb26021"), systemImage: "pause.fill")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else if package.canStart {
                            Button {
                                triggerAction(.start)
                            } label: {
                                Label(L10n.string("ui.56410fc65314dfb5"), systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contextMenu {
            if package.canStart {
                Button { triggerAction(.start) } label: {
                    Label(L10n.string("ui.15e634f8040489f5"), systemImage: "play.fill")
                }
            }
            if package.canStop {
                Button { triggerAction(.stop) } label: {
                    Label(L10n.string("ui.eba40655c00d97e6"), systemImage: "pause.fill")
                }
            }
            if package.canUpgrade {
                Button { triggerAction(.upgrade) } label: {
                    Label(L10n.string("ui.5dafce9fd14a5c3d"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if package.canUninstall {
                Divider()
                Button(role: .destructive) { triggerAction(.uninstall) } label: {
                    Label(L10n.string("ui.330dc1fd06685f18"), systemImage: "trash")
                }
            }
        }
        .disabled(isBusy)
        .accessibilityElement(children: .combine)
    }

    private func triggerAction(_ action: NasPackageAction) {
        guard !isBusy else { return }
        onControl(action)
    }
}

private struct PackageRow: View {
    let package: NasPackage
    let isBusy: Bool
    let onControl: (NasPackageAction) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            PackageIconView(package: package, size: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(package.name).font(.body.weight(.medium))
                if let description = package.packageDescription, !description.isEmpty {
                    Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text([package.version, package.installType].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()

            StatusPill(
                text: package.statusDescription ?? package.status ?? L10n.string("ui.40fae00b7c6d8ac0"),
                isWarning: isWarning(package.status)
            )

            if package.isUpgradeAvailable {
                PackageUpgradeAvailabilityLabel()
            }

            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(
                        L10n.string("package.control.in-progress")
                    )
            } else {
                HStack(spacing: 6) {
                    if package.canUpgrade {
                        Button {
                            triggerAction(.upgrade)
                        } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help(L10n.string("ui.5dafce9fd14a5c3d"))
                    }

                    if package.canStop {
                        Button(L10n.string("ui.8d12fc0d4eb26021")) { triggerAction(.stop) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    } else if package.canStart {
                        Button(L10n.string("ui.56410fc65314dfb5")) { triggerAction(.start) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if package.canStart {
                Button { triggerAction(.start) } label: {
                    Label(L10n.string("ui.15e634f8040489f5"), systemImage: "play.fill")
                }
            }
            if package.canStop {
                Button { triggerAction(.stop) } label: {
                    Label(L10n.string("ui.eba40655c00d97e6"), systemImage: "pause.fill")
                }
            }
            if package.canUpgrade {
                Button { triggerAction(.upgrade) } label: {
                    Label(L10n.string("ui.5dafce9fd14a5c3d"), systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if package.canUninstall {
                Divider()
                Button(role: .destructive) { triggerAction(.uninstall) } label: {
                    Label(L10n.string("ui.330dc1fd06685f18"), systemImage: "trash")
                }
            }
        }
        .disabled(isBusy)
        .accessibilityElement(children: .combine)
    }

    private func triggerAction(_ action: NasPackageAction) {
        guard !isBusy else { return }
        onControl(action)
    }
}

private struct PackageUpgradeAvailabilityLabel: View {
    var body: some View {
        Label(
            L10n.string("package.upgrade.available-in-dsm"),
            systemImage: "arrow.triangle.2.circlepath"
        )
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .help(L10n.string("package.upgrade.read-only-help"))
        .accessibilityLabel(L10n.string("package.upgrade.available-in-dsm"))
        .accessibilityHint(L10n.string("package.upgrade.read-only-help"))
    }
}

private struct PackageIconView: View {
    let package: NasPackage
    var size: CGFloat = 40

    var body: some View {
        if let iconData = package.iconData,
           let image = NSImage(data: iconData) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size > 36 ? 10 : 8, style: .continuous))
                .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)
                .accessibilityHidden(true)
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size > 36 ? 10 : 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: size, height: size)
            Image(systemName: serviceIcon(package))
                .font(size > 36 ? .title3 : .body)
                .foregroundStyle(Color.accentColor)
        }
        .accessibilityHidden(true)
    }
}


private struct ScheduledTaskList: View {
    let tasks: [NasScheduledTask]
    let busyTaskIDs: Set<String>
    let loadDraft: (NasScheduledTask?) async throws -> NasScheduledTaskDraft
    let loadResults: (NasScheduledTask) async throws -> [NasScheduledTaskResult]
    let loadResultOutput: (
        NasScheduledTask,
        String
    ) async throws -> NasScheduledTaskResultOutput
    let onSave: (NasScheduledTaskDraft) async throws -> Void
    let onSetEnabled: (NasScheduledTask, Bool) async throws -> Void
    let onRun: (NasScheduledTask) async throws -> Void
    let onDelete: (NasScheduledTask) async throws -> Void
    @State private var displayMode: DisplayMode = .list
    @State private var editorDraft: NasScheduledTaskDraft?
    @State private var editorIsReadOnly = false
    @State private var resultsTask: NasScheduledTask?
    @State private var pendingRun: NasScheduledTask?
    @State private var pendingDelete: NasScheduledTask?
    @State private var operationError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.6d98ee97c17222de", String(describing: tasks.count)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                Picker(L10n.string("ui.a9fd468be9c085d6"), selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Label(L10n.string(mode.rawValue), systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Button {
                    openEditor(for: nil, readOnly: false)
                } label: {
                    Label(L10n.string("ui.6bee2372805a2fd7"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(busyTaskIDs.contains("new"))
            }
            .padding()

            if displayMode == .list {
                listContent
            } else {
                gridContent
            }
        }
        .sheet(
            isPresented: Binding(
                get: { editorDraft != nil },
                set: { if !$0 { editorDraft = nil } }
            )
        ) {
            if let editorDraft {
                ScheduledTaskEditor(
                    initialDraft: editorDraft,
                    isReadOnly: editorIsReadOnly,
                    onCancel: { self.editorDraft = nil },
                    onSave: { draft in
                        do {
                            try await onSave(draft)
                            self.editorDraft = nil
                            return nil
                        } catch {
                            return userMessage(
                                for: error,
                                fallback: L10n.string("ui.e36b82a7a05a4b9c")
                            )
                        }
                    }
                )
            }
        }
        .sheet(item: $resultsTask) { task in
            ScheduledTaskResultsSheet(
                task: task,
                loadResults: { try await loadResults(task) },
                loadOutput: { resultID in
                    try await loadResultOutput(task, resultID)
                }
            )
        }
        .confirmationDialog(
            L10n.string("task.run.confirm", pendingRun?.name ?? ""),
            isPresented: Binding(
                get: { pendingRun != nil },
                set: { if !$0 { pendingRun = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { pendingRun = nil }
            Button(L10n.string("ui.04eb539709cf130d")) {
                guard let task = pendingRun else { return }
                pendingRun = nil
                perform { try await onRun(task) }
            }
        } message: {
            Text(L10n.string("ui.385f09791aa95b34"))
        }
        .confirmationDialog(
            L10n.string("task.delete.confirm", pendingDelete?.name ?? ""),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { pendingDelete = nil }
            Button(L10n.string("ui.29dfebea0fdac1f6"), role: .destructive) {
                guard let task = pendingDelete else { return }
                pendingDelete = nil
                perform { try await onDelete(task) }
            }
        } message: {
            Text(L10n.string("ui.29e4c1ab37ce8a20"))
        }
        .alert(
            L10n.string("ui.7d6b5b294bc1297d"),
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button(L10n.string("ui.fac2a67ad87807c4")) { operationError = nil }
        } message: {
            Text(operationError ?? L10n.string("ui.5448ceb91a80e260"))
        }
    }

    private var listContent: some View {
        List(tasks) { task in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: task.isEnabled ? "checkmark.circle.fill" : "pause.circle")
                    .foregroundStyle(task.isEnabled ? .green : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.name).font(.body.weight(.medium))
                    Text([task.owner, task.type].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let action = task.action, !action.isEmpty {
                        Text(action).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    StatusPill(text: task.isEnabled ? L10n.string("ui.dfb802238b38fbd4") : L10n.string("ui.a8c3698b5b8c485d"), isWarning: false)
                    if let next = task.nextTriggerDescription {
                        Text(next).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if busyTaskIDs.contains(task.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        taskMenu(for: task)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(L10n.string("ui.f357af26f77463eb", String(describing: task.name)))
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .contextMenu {
                taskMenu(for: task)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                ForEach(tasks) { task in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: task.isEnabled ? "checkmark.circle.fill" : "pause.circle")
                                .foregroundStyle(task.isEnabled ? .green : .secondary)
                                .font(.headline)
                            Text(task.name)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            StatusPill(text: task.isEnabled ? L10n.string("ui.dfb802238b38fbd4") : L10n.string("ui.a8c3698b5b8c485d"), isWarning: false)
                        }

                        Text([task.owner, task.type].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if let action = task.action, !action.isEmpty {
                            Text(action)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                        }

                        Divider().padding(.vertical, 2)

                        HStack {
                            if let next = task.nextTriggerDescription {
                                Text(next)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if busyTaskIDs.contains(task.id) {
                                ProgressView().controlSize(.small)
                            } else {
                                Menu {
                                    taskMenu(for: task)
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .contentShape(Rectangle())
                    .contextMenu {
                        taskMenu(for: task)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func taskMenu(for task: NasScheduledTask) -> some View {
        Button(L10n.string("ui.a748cc074f78de00")) {
            openEditor(for: task, readOnly: true)
        }
        Button(L10n.string("ui.6e55e0f207bfd2e0")) {
            resultsTask = task
        }
        if task.canEdit {
            Button(L10n.string("ui.1eff9b7d894c0ff9")) {
                openEditor(for: task, readOnly: false)
            }
            Button(task.isEnabled ? L10n.string("ui.4e6fd0e28c55860b") : L10n.string("ui.f4f0ead1116b5b62")) {
                perform {
                    try await onSetEnabled(task, !task.isEnabled)
                }
            }
        }
        if task.canRun {
            Divider()
            Button(L10n.string("ui.b8fcaa5efdab00ed")) { pendingRun = task }
        }
        if task.canEdit {
            Divider()
            Button(L10n.string("ui.0552e329ccf875fb"), role: .destructive) {
                pendingDelete = task
            }
        }
    }

    private func openEditor(for task: NasScheduledTask?, readOnly: Bool) {
        Task {
            do {
                let draft = try await loadDraft(task)
                editorIsReadOnly = readOnly || (task != nil && task?.canEdit == false)
                editorDraft = draft
            } catch {
                operationError = userMessage(
                    for: error,
                    fallback: L10n.string("ui.38245f0b3e213b62")
                )
            }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                operationError = userMessage(
                    for: error,
                    fallback: L10n.string("ui.5a0bab31173d86c4")
                )
            }
        }
    }
}

private struct ScheduledTaskResultsSheet: View {
    let task: NasScheduledTask
    let loadResults: () async throws -> [NasScheduledTaskResult]
    let loadOutput: (String) async throws -> NasScheduledTaskResultOutput

    @Environment(\.dismiss) private var dismiss
    @State private var results: [NasScheduledTaskResult] = []
    @State private var selectedResultID: String?
    @State private var output: NasScheduledTaskResultOutput?
    @State private var isLoading = false
    @State private var isLoadingOutput = false
    @State private var errorMessage: String?

    private var selectedResult: NasScheduledTaskResult? {
        results.first { $0.id == selectedResultID }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header 模态顶栏
            HStack(alignment: .center) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("ui.8900caeb81733b85", String(describing: task.name)))
                        .font(.title3.weight(.bold))
                    Text(L10n.string("ui.73aeeae6e000c78c"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Button {
                    Task { await refreshResults() }
                } label: {
                    Label(L10n.string("ui.aee88743413144a2"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isLoading || isLoadingOutput)

                Button(L10n.string("ui.3fd47edce45b3603")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.small)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // 内容展示区
            Group {
                if isLoading, results.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(L10n.string("ui.ffd6030d3f286b7d"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary.opacity(0.6))

                        VStack(spacing: 6) {
                            Text(L10n.string("ui.35d7a7756ff23adf"))
                                .font(.headline)
                            Text(errorMessage ?? L10n.string("ui.50ddbbbaf7f947a1"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 400)
                        }

                        Button {
                            Task { await refreshResults() }
                        } label: {
                            Label(L10n.string("ui.df7392cc96bedc51"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                    )
                    .padding(24)
                } else {
                    HSplitView {
                        List(results, selection: $selectedResultID) { result in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Image(systemName: result.exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(result.exitCode == 0 ? .green : .red)
                                        .accessibilityHidden(true)
                                    Text(result.startedAt?.formatted(date: .abbreviated, time: .standard) ?? L10n.string("ui.664939a1fa2ef755"))
                                        .font(.body.weight(.medium))
                                }
                                HStack {
                                    StatusPill(text: result.exitCode == 0 ? L10n.string("ui.ae3fb35412112cf9") : L10n.string("ui.9344597efd4950cc"), isWarning: result.exitCode != 0)
                                    if let code = result.exitCode {
                                        Text(L10n.string("ui.331de778c25359db", String(describing: code))).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                }
                            }
                            .tag(result.id)
                            .padding(.vertical, 4)
                        }
                        .frame(minWidth: 230, idealWidth: 250, maxWidth: 290)

                        resultDetails
                            .frame(minWidth: 430, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 720, idealWidth: 800, minHeight: 480, maxHeight: 680)
        .task {
            await refreshResults()
        }
        .task(id: selectedResultID) {
            await refreshOutput()
        }
    }

    @ViewBuilder
    private var resultDetails: some View {
        if let result = selectedResult {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DetailSection(title: L10n.string("ui.0020a684697fef9d")) {
                        DetailValueRow(
                            title: L10n.string("ui.6a9906c79f26c0ba"),
                            value: result.startedAt?.formatted(date: .long, time: .standard) ?? L10n.string("ui.756762e293f2aaff")
                        )
                        Divider().opacity(0.4)
                        DetailValueRow(
                            title: L10n.string("ui.f50276449943286c"),
                            value: result.stoppedAt?.formatted(date: .long, time: .standard) ?? L10n.string("ui.756762e293f2aaff")
                        )
                        Divider().opacity(0.4)
                        DetailValueRow(
                            title: L10n.string("ui.de6e7e6afacd538e"),
                            value: result.exitCode.map(String.init) ?? result.exitType ?? L10n.string("ui.756762e293f2aaff")
                        )
                        if let trigger = result.triggerEvent, !trigger.isEmpty {
                            Divider().opacity(0.4)
                            DetailValueRow(title: L10n.string("ui.3c7b79b734942877"), value: trigger)
                        }
                    }

                    if isLoadingOutput {
                        ProgressView(L10n.string("ui.518c7ce82817a812"))
                    } else if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        TaskOutputSection(title: L10n.string("ui.7007f0b16e77f041"), text: output?.command)
                        TaskOutputSection(title: L10n.string("ui.d144838a957a3066"), text: output?.output)
                    }
                }
                .padding(20)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text(L10n.string("ui.434c1311b62a64fd"))
                    .font(.headline)
                Text(L10n.string("ui.8bdde5a2fb782204"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func refreshResults() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await loadResults()
            results = loaded
            if selectedResultID == nil || !loaded.contains(where: { $0.id == selectedResultID }) {
                selectedResultID = loaded.first?.id
            }
        } catch is CancellationError {
            return
        } catch {
            results = []
            errorMessage = userMessage(
                for: error,
                fallback: L10n.string("ui.1c556eade5e0c59b")
            )
        }
    }

    private func refreshOutput() async {
        guard let selectedResultID, !isLoadingOutput else {
            output = nil
            return
        }
        isLoadingOutput = true
        output = nil
        errorMessage = nil
        defer { isLoadingOutput = false }
        do {
            output = try await loadOutput(selectedResultID)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = userMessage(
                for: error,
                fallback: L10n.string("ui.a2ba336ac157d73a")
            )
        }
    }
}

private struct TaskOutputSection: View {
    let title: String
    let text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if let text, !text.isEmpty {
                    Text(L10n.string("ui.9068bbe511dfd9d8", String(describing: text.components(separatedBy: .newlines).count)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ScrollView([.horizontal, .vertical]) {
                    Text(text.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.string("ui.10be5c3635676eb7"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(text?.isEmpty == false ? Color.primary : Color.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
            .frame(minHeight: 80, maxHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ScheduledTaskEditor: View {
    @State private var draft: NasScheduledTaskDraft
    @State private var isSaving = false
    @State private var saveError: String?
    let isReadOnly: Bool
    let onCancel: () -> Void
    let onSave: (NasScheduledTaskDraft) async -> String?

    init(
        initialDraft: NasScheduledTaskDraft,
        isReadOnly: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (NasScheduledTaskDraft) async -> String?
    ) {
        _draft = State(initialValue: initialDraft)
        self.isReadOnly = isReadOnly
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏 Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isReadOnly ? L10n.string("ui.56b3909705f355fc") : (draft.id == nil ? L10n.string("ui.6bee2372805a2fd7") : L10n.string("ui.b1ff92551ca54adb")))
                        .font(.title3.weight(.bold))
                    Text(isReadOnly ? L10n.string("ui.0c77558bf9193a4f") : L10n.string("ui.00508bcf3ddc6a49"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isReadOnly {
                    Toggle(L10n.string("ui.f4f0ead1116b5b62"), isOn: $draft.isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // 内容区 ScrollView
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    // 卡片1：基础配置
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.string("ui.d4743efb124c5c38"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                Text(L10n.string("ui.2479560deb339bea"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                TextField(L10n.string("ui.00fab97819af9321"), text: $draft.name)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text(L10n.string("ui.548203cd46ba4d4d"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                TextField("root / admin", text: $draft.owner)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )

                    // 卡片2：调度策略
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.string("ui.dc462e060ee7c1c6"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 16) {
                            HStack(spacing: 6) {
                                Image(systemName: "clock")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(L10n.string("ui.45e03e436ed0f697"))
                                    .font(.subheadline)
                            }

                            HStack(spacing: 4) {
                                Picker(L10n.string("ui.3b6fefc50febace4"), selection: $draft.schedule.hour) {
                                    ForEach(0..<24, id: \.self) { hour in
                                        Text(String(format: L10n.string("ui.15508e7440ce6517"), hour)).tag(hour)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()

                                Picker(L10n.string("ui.bd957bc497aa1a41"), selection: $draft.schedule.minute) {
                                    ForEach(0..<60, id: \.self) { minute in
                                        Text(String(format: L10n.string("ui.e370c4e9dd79a3e9"), minute)).tag(minute)
                                    }
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.string("ui.6cd078d899dbed72"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            WeekdaySelector(selection: $draft.schedule.weekDays)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )

                    // 卡片3：命令编辑器
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L10n.string("ui.be12f84c407f5a53"))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Label(L10n.string("ui.e07741f9a580b023"), systemImage: "terminal")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .textBackgroundColor))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                )

                            TextEditor(text: $draft.script)
                                .font(.system(.body, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 120, maxHeight: 200)

                            if draft.script.isEmpty {
                                Text(L10n.string("ui.c2e9a19e629c31b5"))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 13)
                                    .padding(.leading, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // 卡片4：高级选项 (通知设置)
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle(L10n.string("ui.fc1f341d48da5901"), isOn: $draft.notifyOnError)
                                .toggleStyle(.checkbox)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(L10n.string("ui.045a035d525fa22f"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("admin@example.com", text: $draft.notificationEmails)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label(L10n.string("ui.247ca01ae2808bf7"), systemImage: "bell")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                    )

                    // 风险警告 Alert Box
                    if !isReadOnly {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.body)

                            Text(L10n.string("ui.547f14499475c8e7"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.orange.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.orange.opacity(0.25), lineWidth: 1)
                                )
                        )
                    }

                    if let saveError {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(saveError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 28)
            }
            .disabled(isReadOnly || isSaving)

            Divider()

            // 底栏 Footer
            HStack {
                Spacer()
                Button(isReadOnly ? L10n.string("ui.3fd47edce45b3603") : L10n.string("ui.2cd0f3be8738a86c"), action: onCancel)
                    .keyboardShortcut(.cancelAction)

                if !isReadOnly {
                    Button {
                        isSaving = true
                        Task {
                            saveError = await onSave(draft)
                            isSaving = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(L10n.string("ui.a3030bf8f16dc63c"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        isSaving
                            || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draft.owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || draft.script.isEmpty
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 520, maxHeight: 720)
    }
}

private struct WeekdaySelector: View {
    @Binding var selection: String
    private let days = [
        (0, L10n.string("ui.85217f7aff778414"), L10n.string("ui.7e06f3148f70f58c")),
        (1, L10n.string("ui.51a75f4634dfa859"), L10n.string("ui.56451fdf19c23fb6")),
        (2, L10n.string("ui.084b42f6e95e4e65"), L10n.string("ui.8621c00d3b2c45f7")),
        (3, L10n.string("ui.a4c3313deb180960"), L10n.string("ui.23ae0a11ac5bab27")),
        (4, L10n.string("ui.754a9d5828d502f1"), L10n.string("ui.478911d29ab88b95")),
        (5, L10n.string("ui.c9b87f516a38ea36"), L10n.string("ui.6e5969e50e4df390")),
        (6, L10n.string("ui.de07b5383874b2a3"), L10n.string("ui.7bb2f5ecaa1dc683"))
    ]

    private var selectedDays: Set<Int> {
        Set(selection.split(separator: ",").compactMap { Int($0) })
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(days, id: \.0) { day in
                let isSelected = selectedDays.contains(day.0)
                Button {
                    var updated = selectedDays
                    if isSelected {
                        if updated.count > 1 {
                            updated.remove(day.0)
                        }
                    } else {
                        updated.insert(day.0)
                    }
                    selection = updated.sorted().map(String.init).joined(separator: ",")
                } label: {
                    Text(day.1)
                        .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                        )
                        .foregroundColor(isSelected ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.2)
            }
        }
    }
}

private struct AccountDirectoryView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case users = "ui.311bb313fdeca6aa"
        case groups = "ui.f3f8bcf3f57de41f"
        var id: Self { self }
    }

    enum DisplayMode: String, CaseIterable, Identifiable {
        case list = "ui.aedd6814ff8c516c"
        case grid = "ui.fb5640f8e12e3337"
        var id: Self { self }
        var icon: String { self == .list ? "list.bullet" : "square.grid.2x2" }
    }

    let directory: NasAccountDirectory?
    let busyAccountIDs: Set<String>
    let onSave: (NasAccountDraft) async throws -> Void
    let onDelete: (NasAccount) async throws -> Void
    let onSaveGroup: (NasGroupDraft) async throws -> Void
    let onDeleteGroup: (NasAccount) async throws -> Void
    @State private var scope: Scope = .users
    @State private var searchText = ""
    @State private var editorDraft: NasAccountDraft?
    @State private var groupEditorDraft: NasGroupDraft?
    @State private var pendingDelete: NasAccount?
    @State private var operationError: String?
    @State private var displayMode: DisplayMode = .list

    private var accounts: [NasAccount] {
        let source = scope == .users ? directory?.users ?? [] : directory?.groups ?? []
        guard !searchText.isEmpty else { return source }
        return source.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.description?.localizedCaseInsensitiveContains(searchText) ?? false)
                || ($0.email?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L10n.string("ui.de90186fc66371a8"), selection: $scope) {
                    ForEach(Scope.allCases) { scope in
                        Text("\(L10n.string(scope.rawValue)) \(count(scope))").tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Picker(L10n.string("ui.a9fd468be9c085d6"), selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Label(L10n.string(mode.rawValue), systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()
                if scope == .users {
                    Button {
                        editorDraft = NasAccountDraft(
                            groups: directory?.groups.contains {
                                $0.name.caseInsensitiveCompare("users") == .orderedSame
                            } == true ? ["users"] : nil
                        )
                    } label: {
                        Label(L10n.string("ui.3afa11aa32529cb9"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(busyAccountIDs.contains("new"))
                } else {
                    Button {
                        groupEditorDraft = NasGroupDraft()
                    } label: {
                        Label(L10n.string("ui.65435939fefcf576"), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(busyAccountIDs.contains("new-group"))
                }
            }
            .padding()

            if displayMode == .list {
                listContent
            } else {
                gridContent
            }
        }
        .sheet(
            isPresented: Binding(
                get: { editorDraft != nil },
                set: { if !$0 { editorDraft = nil } }
            )
        ) {
            if let editorDraft {
                AccountEditor(
                    initialDraft: editorDraft,
                    availableGroups: directory?.groups.map(\.name) ?? [],
                    onCancel: { self.editorDraft = nil },
                    onSave: { draft in
                        do {
                            try await onSave(draft)
                            self.editorDraft = nil
                            return nil
                        } catch {
                            return userMessage(
                                for: error,
                                fallback: L10n.string("ui.4e175f38276efa53")
                            )
                        }
                    }
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { groupEditorDraft != nil },
                set: { if !$0 { groupEditorDraft = nil } }
            )
        ) {
            if let groupEditorDraft {
                GroupEditor(
                    initialDraft: groupEditorDraft,
                    onCancel: { self.groupEditorDraft = nil },
                    onSave: { draft in
                        do {
                            try await onSaveGroup(draft)
                            self.groupEditorDraft = nil
                            return nil
                        } catch {
                            return userMessage(
                                for: error,
                                fallback: L10n.string("ui.19b98ccdabc60873")
                            )
                        }
                    }
                )
            }
        }
        .confirmationDialog(
            L10n.string(
                "account.delete.confirm",
                pendingDelete?.kind == .group
                    ? L10n.string("account.type.group")
                    : L10n.string("account.type.user"),
                pendingDelete?.name ?? ""
            ),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { pendingDelete = nil }
            Button(pendingDelete?.kind == .group ? L10n.string("ui.39dc22ae05f9eb06") : L10n.string("ui.cd3266d91ae10abc"), role: .destructive) {
                guard let item = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    do {
                        if item.kind == .group {
                            try await onDeleteGroup(item)
                        } else {
                            try await onDelete(item)
                        }
                    } catch {
                        operationError = userMessage(
                            for: error,
                            fallback: L10n.string("ui.e0e2682d4801f7db")
                        )
                    }
                }
            }
        } message: {
            if pendingDelete?.kind == .group {
                Text(L10n.string("ui.dafbb926cc945ae1"))
            } else {
                Text(L10n.string("ui.d20250eee2ac6caa"))
            }
        }
        .alert(
            L10n.string("ui.7d6b5b294bc1297d"),
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button(L10n.string("ui.fac2a67ad87807c4")) { operationError = nil }
        } message: {
            if let operationError {
                Text(operationError)
            }
        }
    }

    private var listContent: some View {
        List(accounts) { account in
            HStack(spacing: 12) {
                Image(systemName: account.kind == .user ? "person.circle.fill" : "person.2.circle.fill")
                    .font(.title2)
                    .foregroundStyle(account.isExpired ? Color.secondary : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name).font(.body.weight(.medium)).textSelection(.enabled)
                    Text([account.email, account.description].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if account.isExpired {
                    StatusPill(text: L10n.string("ui.a8c3698b5b8c485d"), isWarning: true)
                }
                if let id = account.numericID {
                    Text("#\(id)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                }
                if busyAccountIDs.contains(account.id) {
                    ProgressView().controlSize(.small)
                } else if account.kind == .user, account.canEdit || account.canDelete {
                    Menu {
                        accountMenu(for: account)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(L10n.string("ui.f357af26f77463eb", String(describing: account.name)))
                } else if account.kind == .group, account.canEdit || account.canDelete {
                    Menu {
                        accountMenu(for: account)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(L10n.string("ui.f357af26f77463eb", String(describing: account.name)))
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .contextMenu {
                accountMenu(for: account)
            }
            .accessibilityElement(children: .combine)
        }
        .searchable(text: $searchText, prompt: L10n.string("ui.0f201cb88b5f99a3", L10n.string(scope.rawValue)))
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: account.kind == .user ? "person.circle.fill" : "person.2.circle.fill")
                                .font(.title2)
                                .foregroundStyle(account.isExpired ? Color.secondary : Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(.body.weight(.medium))
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                if let id = account.numericID {
                                    Text("#\(id)").font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                                }
                            }
                            Spacer()
                            if account.isExpired {
                                StatusPill(text: L10n.string("ui.a8c3698b5b8c485d"), isWarning: true)
                            }
                        }

                        let info = [account.email, account.description].compactMap({ $0 }).joined(separator: " · ")
                        if !info.isEmpty {
                            Text(info)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Divider().padding(.vertical, 2)

                        HStack {
                            Spacer()
                            if busyAccountIDs.contains(account.id) {
                                ProgressView().controlSize(.small)
                            } else if account.canEdit || account.canDelete {
                                Menu {
                                    accountMenu(for: account)
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .contentShape(Rectangle())
                    .contextMenu {
                        accountMenu(for: account)
                    }
                }
            }
            .padding(20)
        }
        .searchable(text: $searchText, prompt: L10n.string("ui.0f201cb88b5f99a3", L10n.string(scope.rawValue)))
    }

    @ViewBuilder
    private func accountMenu(for account: NasAccount) -> some View {
        if account.kind == .user {
            if account.canEdit {
                Button(L10n.string("ui.1eff9b7d894c0ff9")) {
                    openUserEditor(for: account)
                }
            }
            if account.canDelete {
                Button(L10n.string("ui.0552e329ccf875fb"), role: .destructive) {
                    pendingDelete = account
                }
            }
        } else {
            if account.canEdit {
                Button(L10n.string("ui.1eff9b7d894c0ff9")) {
                    openGroupEditor(for: account)
                }
            }
            if account.canDelete {
                Button(L10n.string("ui.0552e329ccf875fb"), role: .destructive) {
                    pendingDelete = account
                }
            }
        }
    }

    private func openUserEditor(for account: NasAccount) {
        editorDraft = NasAccountDraft(
            originalName: account.name,
            name: account.name,
            description: account.description ?? "",
            email: account.email ?? "",
            isExpired: account.isExpired,
            groups: account.groups
        )
    }

    private func openGroupEditor(for account: NasAccount) {
        groupEditorDraft = NasGroupDraft(
            originalName: account.name,
            name: account.name,
            description: account.description ?? ""
        )
    }

    private func count(_ scope: Scope) -> Int {
        scope == .users ? directory?.users.count ?? 0 : directory?.groups.count ?? 0
    }
}

private struct AccountEditor: View {
    @State private var draft: NasAccountDraft
    @State private var isSaving = false
    @State private var saveError: String?
    let availableGroups: [String]
    let onCancel: () -> Void
    let onSave: (NasAccountDraft) async -> String?

    init(
        initialDraft: NasAccountDraft,
        availableGroups: [String],
        onCancel: @escaping () -> Void,
        onSave: @escaping (NasAccountDraft) async -> String?
    ) {
        _draft = State(initialValue: initialDraft)
        self.availableGroups = availableGroups
        self.onCancel = onCancel
        self.onSave = onSave
    }

    private var passwordMismatch: Bool {
        !draft.password.isEmpty && !draft.passwordConfirmation.isEmpty && draft.password != draft.passwordConfirmation
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.originalName == nil ? L10n.string("ui.3afa11aa32529cb9") : L10n.string("ui.324b13154e4e60fc"))
                        .font(.title3.weight(.bold))
                    Text(draft.originalName == nil ? L10n.string("ui.e8aa54377d97effc") : L10n.string("ui.74eaeed6953c8a0e"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            // Scrollable Content
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    // 卡片1：常规信息
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L10n.string("ui.5376ca741c1f56ad"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                Text(L10n.string("ui.19779e66852f82fc"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField(L10n.string("ui.937c0bce7323331f"), text: $draft.name)
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(draft.originalName != nil)
                                    if draft.originalName != nil {
                                        Text(L10n.string("ui.8782d898e26733e5"))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            GridRow {
                                Text(L10n.string("ui.fa1d3771541290d6"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                TextField("user@example.com", text: $draft.email)
                                    .textFieldStyle(.roundedBorder)
                                    .textContentType(.emailAddress)
                            }
                            GridRow {
                                Text(L10n.string("ui.f7180079550edc42"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                TextField(L10n.string("ui.c0150cdbacc2c217"), text: $draft.description)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        Divider().padding(.vertical, 4)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.string("ui.5549fd9845d7fcfc"))
                                    .font(.subheadline.weight(.medium))
                                Text(L10n.string("ui.e79ab23a5b386675"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $draft.isExpired)
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )

                    // 卡片2：所属群组
                    if draft.groups != nil, !availableGroups.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(availableGroups, id: \.self) { group in
                                    Toggle(
                                        group,
                                        isOn: Binding(
                                            get: { draft.groups?.contains(group) == true },
                                            set: { isMember in
                                                var groups = draft.groups ?? []
                                                if isMember, !groups.contains(group) {
                                                    groups.append(group)
                                                } else if !isMember {
                                                    groups.removeAll { $0 == group }
                                                }
                                                draft.groups = groups
                                            }
                                        )
                                    )
                                    .toggleStyle(.checkbox)
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            Label(L10n.string("ui.09c442dcc4bc1b43"), systemImage: "person.3")
                                .font(.subheadline.weight(.medium))
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                                )
                        )
                    }

                    // 卡片3：密码安全
                    VStack(alignment: .leading, spacing: 12) {
                        Text(draft.originalName == nil ? L10n.string("ui.d353cf2a684e1f27") : L10n.string("ui.3f0492dd3c0bd817"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                            GridRow {
                                Text(L10n.string("ui.fb5bbea8d049c01d"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                SecureField(draft.originalName == nil ? L10n.string("ui.739d1cc26c305520") : L10n.string("ui.fa81e66107f6ec3d"), text: $draft.password)
                                    .textFieldStyle(.roundedBorder)
                                    .textContentType(.newPassword)
                            }
                            GridRow {
                                Text(L10n.string("ui.d0c9a0e81079a7b2"))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                SecureField(L10n.string("ui.090c778dd910a7ac"), text: $draft.passwordConfirmation)
                                    .textFieldStyle(.roundedBorder)
                                    .textContentType(.newPassword)
                            }
                        }

                        if passwordMismatch {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .font(.caption)
                                Text(L10n.string("ui.58807745708ed726"))
                                    .font(.caption)
                            }
                            .foregroundStyle(.red)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )

                    if let saveError {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(saveError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(24)
            }
            .disabled(isSaving)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button {
                    isSaving = true
                    Task {
                        saveError = await onSave(draft)
                        isSaving = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(L10n.string("ui.a3030bf8f16dc63c"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isSaving
                        || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (draft.originalName == nil && draft.password.isEmpty)
                        || draft.password != draft.passwordConfirmation
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 540, height: 560)
    }
}

private struct GroupEditor: View {
    @State private var draft: NasGroupDraft
    @State private var isSaving = false
    @State private var saveError: String?
    let onCancel: () -> Void
    let onSave: (NasGroupDraft) async -> String?

    init(
        initialDraft: NasGroupDraft,
        onCancel: @escaping () -> Void,
        onSave: @escaping (NasGroupDraft) async -> String?
    ) {
        _draft = State(initialValue: initialDraft)
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.originalName == nil ? L10n.string("ui.65435939fefcf576") : L10n.string("ui.631d7d2c234092f2"))
                        .font(.title3.weight(.bold))
                    Text(L10n.string("ui.9473c7977cee8c09"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.string("ui.53742a9ca2c94390"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                        GridRow {
                            Text(L10n.string("ui.7f7f88883c30b3d1"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            TextField(L10n.string("ui.ee9f98e0db8dca19"), text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                                .disabled(draft.originalName != nil)
                        }
                        GridRow {
                            Text(L10n.string("ui.f7180079550edc42"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            TextField(L10n.string("ui.8773eadcd92b77fd"), text: $draft.description)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )

                if let saveError {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Spacer()
            }
            .padding(24)
            .disabled(isSaving)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button {
                    isSaving = true
                    Task {
                        saveError = await onSave(draft)
                        isSaving = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(L10n.string("ui.a3030bf8f16dc63c"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isSaving
                        || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 480, height: 320)
    }
}

private struct ActiveConnectionsCard: View {
    let connections: NasConnectionPage?
    let onNavigate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(L10n.string("ui.e403ba5798ba13a4"), systemImage: "network")
                    .font(.headline)
                Spacer()
                Button {
                    onNavigate()
                } label: {
                    HStack(spacing: 3) {
                        Text(L10n.string("ui.fa2ff3c379a7c988"))
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            if let page = connections, !page.connections.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(page.connections.count)")
                            .font(.title2.weight(.bold))
                            .monospacedDigit()
                        Text(L10n.string("ui.d345a56ab5f39042"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(page.connections.prefix(5))) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.isCurrentConnection ? "laptopcomputer.and.arrow.down" : "person.fill")
                                    .font(.caption2)
                                    .foregroundStyle(item.isCurrentConnection ? Color.green : Color.accentColor)
                                Text(item.account)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                if let proto = item.protocolName {
                                    Text(proto)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
                                }
                                Spacer()
                                if let ip = item.source {
                                    Text(ip)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                            }
                        }

                        if page.connections.count > 5 {
                            Text(L10n.string("ui.e6aace8c08efbfbf", String(describing: page.connections.count - 5)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 2)
                        }
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Text(L10n.string("ui.51c4d3852f4b0d44"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 215, maxHeight: 215, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct LogEntryList: View {
    let page: NasLogPage?
    let currentPage: Int
    let pageSize: Int
    let onFetchPage: (Int, Int) async -> Void

    enum LogFilter: String, CaseIterable, Identifiable {
        case all = "ui.5c55a67935af8f45"
        case error = "ui.0bc1fb72ae1be5c5"
        case warning = "ui.a8b7a4480407ac8a"
        case info = "ui.e7028601e7da793d"

        var id: Self { self }
    }

    @State private var selectedFilter: LogFilter = .all
    @State private var searchText = ""

    private var filteredEntries: [NasLogEntry] {
        guard let source = page?.entries else { return [] }
        return source.filter { entry in
            let matchesFilter: Bool
            switch selectedFilter {
            case .all: matchesFilter = true
            case .error: matchesFilter = isError(entry.level)
            case .warning: matchesFilter = isWarning(entry.level) && !isError(entry.level)
            case .info: matchesFilter = !isError(entry.level) && !isWarning(entry.level)
            }
            guard matchesFilter else { return false }
            guard !searchText.isEmpty else { return true }
            return entry.message.localizedCaseInsensitiveContains(searchText)
                || (entry.source?.localizedCaseInsensitiveContains(searchText) ?? false)
                || (entry.account?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    private var totalPages: Int {
        guard let page, page.total > 0 else { return 1 }
        return max(1, Int(ceil(Double(page.total) / Double(pageSize))))
    }

    var body: some View {
        VStack(spacing: 0) {
            filterHeaderBar
            Divider()

            List(filteredEntries) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        StatusPill(text: entry.level ?? L10n.string("ui.e7028601e7da793d"), isWarning: isWarning(entry.level))
                        Text(entry.source ?? L10n.string("ui.5b50d7c4b5950dc5")).font(.caption.weight(.semibold))
                        if let account = entry.account { Text(account).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        if let date = entry.date {
                            Text(date, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(entry.message).textSelection(.enabled)
                }
                .padding(.vertical, 5)
                .accessibilityElement(children: .combine)
            }
            .searchable(text: $searchText, prompt: L10n.string("ui.1b9b75f51d2061d7"))

            Divider()
            paginationBar
        }
    }

    private var filterHeaderBar: some View {
        HStack(spacing: 10) {
            FilterChipButton(
                title: L10n.string(
                    "nas.logs.total_count",
                    page?.total.formatted() ?? "0"
                ),
                icon: "doc.text",
                isSelected: selectedFilter == .all,
                badgeColor: .accentColor
            ) {
                selectedFilter = .all
            }

            FilterChipButton(
                title: L10n.string("ui.8c04c080fcc61432", String(describing: page?.errorCount ?? 0)),
                icon: "xmark.octagon.fill",
                isSelected: selectedFilter == .error,
                badgeColor: .red
            ) {
                selectedFilter = .error
            }

            FilterChipButton(
                title: L10n.string("ui.d8f4ace8370f7001", String(describing: page?.warningCount ?? 0)),
                icon: "exclamationmark.triangle.fill",
                isSelected: selectedFilter == .warning,
                badgeColor: .orange
            ) {
                selectedFilter = .warning
            }

            FilterChipButton(
                title: L10n.string("ui.e7028601e7da793d"),
                icon: "info.circle.fill",
                isSelected: selectedFilter == .info,
                badgeColor: .blue
            ) {
                selectedFilter = .info
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.4))
    }

    private var paginationBar: some View {
        HStack(spacing: 12) {
            Text(L10n.string("ui.8c932f987c21bf0a"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("", selection: Binding(
                get: { pageSize },
                set: { newSize in
                    Task { await onFetchPage(1, newSize) }
                }
            )) {
                Text(L10n.string("ui.14118b6919402a94")).tag(50)
                Text(L10n.string("ui.5bcf252872463a5a")).tag(100)
                Text(L10n.string("ui.4b9fea4d5f57c2c3")).tag(200)
            }
            .pickerStyle(.menu)
            .fixedSize()

            Spacer()

            Text(L10n.string("ui.cbe23459337a9228", String(describing: currentPage), String(describing: totalPages), String(describing: page?.total ?? 0)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            HStack(spacing: 6) {
                Button {
                    guard currentPage > 1 else { return }
                    Task { await onFetchPage(currentPage - 1, pageSize) }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(currentPage <= 1)
                .help(L10n.string("ui.c9b9ae7a61444ab7"))

                Button {
                    guard currentPage < totalPages else { return }
                    Task { await onFetchPage(currentPage + 1, pageSize) }
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(currentPage >= totalPages)
                .help(L10n.string("ui.8a8542f6964852dc"))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private func isError(_ level: String?) -> Bool {
        guard let level = level?.lowercased() else { return false }
        return level.contains("err") || level.contains("fatal") || level.contains("critical") || level.contains("error")
    }
}

private struct FilterChipButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let badgeColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .white : badgeColor)
                Text(title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isSelected ? badgeColor : Color.primary.opacity(0.05),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ConnectionList: View {
    let page: NasConnectionPage?
    let busyConnectionIDs: Set<String>
    let onDisconnect: (NasConnection) async throws -> Void
    @State private var displayMode: DisplayMode = .list
    @State private var pendingDisconnect: NasConnection?
    @State private var operationError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.33adfa1b256632d5", String(describing: page?.connections.count ?? 0)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                Picker(L10n.string("ui.a9fd468be9c085d6"), selection: $displayMode) {
                    ForEach(DisplayMode.allCases) { mode in
                        Label(L10n.string(mode.rawValue), systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding()

            if displayMode == .list {
                listContent
            } else {
                gridContent
            }
        }
        .confirmationDialog(
            L10n.string(
                "nas.connections.disconnect.confirm",
                pendingDisconnect?.account ?? L10n.string("ui.38e4b6b38c8a8eec")
            ),
            isPresented: Binding(
                get: { pendingDisconnect != nil },
                set: { if !$0 { pendingDisconnect = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { pendingDisconnect = nil }
            Button(L10n.string("ui.a33f3804768e68ee"), role: .destructive) {
                guard let connection = pendingDisconnect else { return }
                pendingDisconnect = nil
                Task {
                    do {
                        try await onDisconnect(connection)
                    } catch {
                        operationError = userMessage(
                            for: error,
                            fallback: L10n.string("ui.7f7201fdd7e5afec")
                        )
                    }
                }
            }
        } message: {
            if pendingDisconnect?.isCurrentConnection == true {
                Text(L10n.string("ui.bfbc568f4cd9c80d"))
            } else {
                Text(L10n.string("ui.faf68aeb4c262b5c"))
            }
        }
        .alert(
            L10n.string("ui.8811c5f235420b04"),
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button(L10n.string("ui.fac2a67ad87807c4")) { operationError = nil }
        } message: {
            Text(operationError ?? L10n.string("ui.5448ceb91a80e260"))
        }
    }

    private var listContent: some View {
        List(page?.connections ?? []) { connection in
            HStack(spacing: 12) {
                Image(systemName: connection.isCurrentConnection ? "laptopcomputer.and.arrow.down" : "network")
                    .foregroundStyle(connection.isCurrentConnection ? Color.green : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(connection.account).font(.body.weight(.medium))
                        if connection.isCurrentConnection {
                            Text(L10n.string("ui.e403ba5798ba13a4")).font(.caption2).foregroundStyle(.green)
                        }
                    }
                    Text([connection.protocolName, connection.source, connection.location].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let description = connection.description {
                        Text(description).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if let date = connection.connectedAt {
                    Text(date, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if busyConnectionIDs.contains(connection.id) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.string("ui.dc6ee00a278a45f5"))
                } else if connection.canDisconnect {
                    Button(L10n.string("ui.f33ac04eece6a6a6")) {
                        pendingDisconnect = connection
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(L10n.string("ui.719814130cbc3162"))
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .contextMenu {
                connectionMenu(for: connection)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                ForEach(page?.connections ?? []) { connection in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: connection.isCurrentConnection ? "laptopcomputer.and.arrow.down" : "network")
                                .font(.title3)
                                .foregroundStyle(connection.isCurrentConnection ? Color.green : Color.accentColor)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(connection.account)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                if connection.isCurrentConnection {
                                    Text(L10n.string("ui.e403ba5798ba13a4"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            Spacer()
                        }

                        Text([connection.protocolName, connection.source, connection.location].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        if let description = connection.description {
                            Text(description)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }

                        Divider().padding(.vertical, 2)

                        HStack {
                            if let date = connection.connectedAt {
                                Text(date, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if busyConnectionIDs.contains(connection.id) {
                                ProgressView().controlSize(.small)
                            } else if connection.canDisconnect {
                                Button(L10n.string("ui.f33ac04eece6a6a6")) {
                                    pendingDisconnect = connection
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    )
                    .contentShape(Rectangle())
                    .contextMenu {
                        connectionMenu(for: connection)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func connectionMenu(for connection: NasConnection) -> some View {
        if connection.canDisconnect {
            Button(L10n.string("ui.19715691e1f046cb"), role: .destructive) {
                pendingDisconnect = connection
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title).font(.title2.weight(.semibold))
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StatusPill: View {
    let text: String
    let isWarning: Bool

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(isWarning ? .orange : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background((isWarning ? Color.orange : Color.secondary).opacity(0.1), in: Capsule())
    }
}

private struct LoadingAdministrationView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.string("ui.318846938ad187ec"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct AdministrationErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(L10n.string("ui.9482c10d4833f834"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button(L10n.string("ui.7bdd5ce1e298a972"), action: retry)
        }
    }
}

private func percent(_ value: Double?) -> String {
    value.map { "\($0.formatted(.number.precision(.fractionLength(0))))%" } ?? L10n.string("ui.2d1341db7717c694")
}

private func speed(_ value: Int64?) -> String {
    guard let value else { return L10n.string("ui.2d1341db7717c694") }
    return L10n.string("ui.3b14d1af77ab3e3e", String(describing: ByteCountFormatter.string(fromByteCount: value, countStyle: .file)))
}

private func byteCount(_ value: Int64?) -> String {
    value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L10n.string("ui.4d8c1c5b42830791")
}

private func availableBytes(used: Int64?, total: Int64?) -> Int64? {
    guard let used, let total else { return nil }
    return max(0, total - used)
}

private func storageStatusText(_ status: String?) -> String? {
    guard let status, !status.isEmpty else { return nil }
    switch status.lowercased() {
    case "normal", "healthy", "good", "smart_complete":
        return L10n.string("ui.cfea0dce5c5d6d72")
    case "background":
        return L10n.string("ui.d85ff08f9141848c")
    case "attention", "warning":
        return L10n.string("ui.47a6e46e0880c994")
    case "not_use":
        return L10n.string("ui.07564e6524ba73ad")
    case "sys_partition_normal":
        return L10n.string("ui.c6d125d5b7100f6f")
    case "error", "failed", "critical", "abnormal":
        return L10n.string("ui.428fb8bfeecf7f91")
    default:
        return status
    }
}

private func smartResultText(_ result: String) -> String {
    storageStatusText(result) ?? L10n.string("ui.756762e293f2aaff")
}

private func isWarning(_ status: String?) -> Bool {
    guard let status = status?.lowercased() else { return false }
    return ["error", "warning", "critical", "failed", "abnormal", "crashed", "expired"].contains {
        status.contains($0)
    }
}

private func serviceIcon(_ package: NasPackage) -> String {
    let value = "\(package.id) \(package.name)".lowercased()
    if value.contains("backup") { return "externaldrive.badge.timemachine" }
    if value.contains("surveillance") || value.contains("camera") { return "video" }
    if value.contains("monitor") { return "waveform.path.ecg" }
    if value.contains("drive") || value.contains("cloud") { return "icloud" }
    return "shippingbox"
}

private func uptimeDescription(_ seconds: Int64) -> String {
    let days = seconds / 86_400
    let hours = seconds % 86_400 / 3_600
    let minutes = seconds % 3_600 / 60
    if days > 0 { return L10n.string("ui.ce52dbf8c0d2406e", String(describing: days), String(describing: hours)) }
    if hours > 0 { return L10n.string("ui.8cf1ab2084092e4e", String(describing: hours), String(describing: minutes)) }
    return L10n.string("ui.6885cad929bb5eae", String(describing: minutes))
}
