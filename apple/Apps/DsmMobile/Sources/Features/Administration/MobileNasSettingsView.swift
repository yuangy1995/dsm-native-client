import DsmLocalization
import SwiftUI

struct MobileNasSettingsView: View {
    @Bindable var model: MobileAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSection: MobileNasAdministrationDestination = .system

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .onDisappear {
            if model.selectedModule != .nasSettings {
                model.nasDetailsModel.deactivate()
            }
        }
    }

    private var compactLayout: some View {
        List {
            readOnlyNotice
            systemSection
            performanceSection
            storageSection
            updateSection
            detailsNavigationSection
        }
        .listStyle(.insetGrouped)
        .refreshable { await model.nasHealthModel.refresh() }
        .navigationDestination(for: MobileNasAdministrationDestination.self) { destination in
            if destination.isDetails {
                MobileNasDetailsScreen(
                    model: model.nasDetailsModel,
                    destination: destination
                )
            }
        }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            List {
                Section {
                    ForEach(MobileNasAdministrationDestination.health) { destination in
                        navigationButton(destination)
                    }
                }
                Section(L10n.string("mobile.nas-details.group.title")) {
                    ForEach(MobileNasAdministrationDestination.details) { destination in
                        navigationButton(destination)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 300)

            Divider()

            List {
                readOnlyNotice
                selectedDetail
            }
            .listStyle(.insetGrouped)
            .refreshable {
                await model.nasHealthModel.refresh()
                await model.nasDetailsModel.refreshLoadedSections()
            }
        }
    }

    private var detailsNavigationSection: some View {
        Section(L10n.string("mobile.nas-details.group.title")) {
            ForEach(MobileNasAdministrationDestination.details) { destination in
                NavigationLink(value: destination) {
                    Label(destination.title, systemImage: destination.systemImage)
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
        }
    }

    private var readOnlyNotice: some View {
        Section {
            Label(
                L10n.string("mobile.nas-health.read-only.notice"),
                systemImage: "eye"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private func navigationButton(_ destination: MobileNasAdministrationDestination) -> some View {
        let isSelected = selectedSection == destination
        return Button {
            selectedSection = destination
        } label: {
            HStack(spacing: 12) {
                Image(systemName: destination.systemImage)
                Text(destination.title)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var selectedDetail: some View {
        switch selectedSection {
        case .system: systemSection
        case .performance: performanceSection
        case .storage: storageSection
        case .update: updateSection
        case .packages, .scheduledTasks, .logs, .connections:
            MobileNasDetailsSectionView(
                model: model.nasDetailsModel,
                destination: selectedSection
            )
        }
    }

    private var systemSection: some View {
        let section = model.nasHealthModel.state.system
        return Section {
            MobileNasHealthSectionContent(
                section: section,
                loading: L10n.string("mobile.nas-health.loading.system"),
                errorTitle: L10n.string("mobile.nas-health.error.system.title"),
                errorMessage: L10n.string("mobile.nas-health.error.system.message"),
                retry: { Task { await model.nasHealthModel.refresh() } }
            ) { value in
                LabeledContent(L10n.string("mobile.nas-health.system.name"), value: value.serverName)
                optionalRow(L10n.string("mobile.nas-health.system.model"), value.model)
                optionalRow(L10n.string("mobile.nas-health.system.version"), value.version)
                optionalRow(
                    L10n.string("mobile.nas-health.system.uptime"),
                    MobileNasHealthFormatting.duration(value.uptimeSeconds)
                )
                optionalRow(L10n.string("mobile.nas-health.system.processor"), value.cpuModel)
                optionalRow(
                    L10n.string("mobile.nas-health.system.memory"),
                    MobileNasHealthFormatting.bytes(value.memoryBytes, countStyle: .memory)
                )
                LabeledContent(L10n.string("mobile.nas-health.system.temperature")) {
                    HStack(spacing: 8) {
                        Text(
                            MobileNasHealthFormatting.temperature(value.temperatureCelsius)
                                ?? L10n.string("mobile.nas-health.status.unknown")
                        )
                        healthBadge(value.temperatureLevel)
                    }
                }
            }
        } header: {
            sectionHeader(.system, isRefreshing: section.isRefreshing)
        }
    }

    private var performanceSection: some View {
        let section = model.nasHealthModel.state.performance
        return Section {
            MobileNasHealthSectionContent(
                section: section,
                loading: L10n.string("mobile.nas-health.loading.performance"),
                errorTitle: L10n.string("mobile.nas-health.error.performance.title"),
                errorMessage: L10n.string("mobile.nas-health.error.performance.message"),
                retry: { Task { await model.nasHealthModel.refresh() } }
            ) { value in
                LabeledContent(
                    L10n.string("mobile.nas-health.performance.cpu"),
                    value: MobileNasHealthFormatting.percent(value.cpuUsage)
                )
                LabeledContent(
                    L10n.string("mobile.nas-health.performance.memory"),
                    value: MobileNasHealthFormatting.percent(value.memoryUsage)
                )
                LabeledContent(
                    L10n.string("mobile.nas-health.performance.swap"),
                    value: MobileNasHealthFormatting.percent(value.swapUsage)
                )
                LabeledContent(
                    L10n.string("mobile.nas-health.performance.network.receive"),
                    value: MobileNasHealthFormatting.rate(value.networkReceivedBytesPerSecond)
                )
                LabeledContent(
                    L10n.string("mobile.nas-health.performance.network.send"),
                    value: MobileNasHealthFormatting.rate(value.networkSentBytesPerSecond)
                )
                LabeledContent(
                    L10n.string("mobile.nas-health.performance.disk.read"),
                    value: MobileNasHealthFormatting.rate(value.diskReadBytesPerSecond)
                )
                LabeledContent(
                    L10n.string("mobile.nas-health.performance.disk.write"),
                    value: MobileNasHealthFormatting.rate(value.diskWriteBytesPerSecond)
                )
                LabeledContent(
                    L10n.string("mobile.nas-health.performance.volume.read"),
                    value: MobileNasHealthFormatting.rate(value.volumeReadBytesPerSecond)
                )
                LabeledContent(
                    L10n.string("mobile.nas-health.performance.volume.write"),
                    value: MobileNasHealthFormatting.rate(value.volumeWriteBytesPerSecond)
                )
                LabeledContent(
                    L10n.string("mobile.nas-health.performance.disk-utilization"),
                    value: MobileNasHealthFormatting.percent(value.diskUtilization)
                )
            }
        } header: {
            sectionHeader(.performance, isRefreshing: section.isRefreshing)
        } footer: {
            if let value = section.value {
                Text(L10n.string("mobile.nas-health.updated-at", value.recordedAt.formatted()))
            }
        }
    }

    private var storageSection: some View {
        let section = model.nasHealthModel.state.storage
        return Section {
            MobileNasHealthSectionContent(
                section: section,
                loading: L10n.string("mobile.nas-health.loading.storage"),
                emptyTitle: L10n.string("mobile.nas-health.storage.empty.title"),
                emptyMessage: L10n.string("mobile.nas-health.storage.empty.message"),
                errorTitle: L10n.string("mobile.nas-health.error.storage.title"),
                errorMessage: L10n.string("mobile.nas-health.error.storage.message"),
                retry: { Task { await model.nasHealthModel.refresh() } }
            ) { value in
                LabeledContent(L10n.string("mobile.nas-health.storage.overall")) {
                    healthBadge(value.overallHealth)
                }

                if !value.pools.isEmpty {
                    storageGroupTitle("mobile.nas-health.storage.pools", image: "externaldrive.connected.to.line.below")
                    ForEach(Array(value.pools.enumerated()), id: \.offset) { _, pool in
                        poolRows(pool)
                    }
                }

                if !value.volumes.isEmpty {
                    storageGroupTitle("mobile.nas-health.storage.volumes", image: "externaldrive")
                    ForEach(Array(value.volumes.enumerated()), id: \.offset) { _, volume in
                        volumeRows(volume)
                    }
                }

                if !value.disks.isEmpty {
                    storageGroupTitle("mobile.nas-health.storage.drives", image: "internaldrive")
                    ForEach(Array(value.disks.enumerated()), id: \.offset) { _, disk in
                        diskRows(disk)
                    }
                }
            }
        } header: {
            sectionHeader(.storage, isRefreshing: section.isRefreshing)
        }
    }

    private var updateSection: some View {
        let section = model.nasHealthModel.state.update
        return Section {
            MobileNasHealthSectionContent(
                section: section,
                loading: L10n.string("mobile.nas-health.loading.update"),
                errorTitle: L10n.string("mobile.nas-health.error.update.title"),
                errorMessage: L10n.string("mobile.nas-health.error.update.message"),
                retry: { Task { await model.nasHealthModel.refresh() } }
            ) { value in
                Label(
                    L10n.string(
                        value.status == .updateAvailable
                            ? "mobile.nas-health.update.available"
                            : "mobile.nas-health.update.up-to-date"
                    ),
                    systemImage: value.status == .updateAvailable
                        ? "arrow.down.circle.fill"
                        : "checkmark.circle.fill"
                )
                .foregroundStyle(value.status == .updateAvailable ? .orange : .green)
                .accessibilityElement(children: .combine)

                optionalRow(
                    L10n.string("mobile.nas-health.update.current-version"),
                    value.currentVersion
                )
                optionalRow(
                    L10n.string("mobile.nas-health.update.latest-version"),
                    value.latestVersion
                )
                if let releaseNotes = MobileNasHealthFormatting.nonempty(value.releaseNotes) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("mobile.nas-health.update.release-notes"))
                            .font(.headline)
                        Text(releaseNotes)
                            .font(.body)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }
                if value.status == .updateAvailable {
                    Label(
                        L10n.string("mobile.nas-health.update.browser-notice"),
                        systemImage: "safari"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            sectionHeader(.update, isRefreshing: section.isRefreshing)
        }
    }

    private func poolRows(_ pool: MobileNasStoragePoolHealth) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(pool.name).font(.headline)
                Spacer()
                healthBadge(pool.health)
            }
            optionalRow(L10n.string("mobile.nas-health.storage.raid-type"), pool.raidType)
            capacityRows(used: pool.usedBytes, total: pool.totalBytes)
            if pool.isScrubbing {
                Label(
                    L10n.string("mobile.nas-health.storage.scrubbing"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func volumeRows(_ volume: MobileNasVolumeHealth) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(volume.name).font(.headline)
                Spacer()
                healthBadge(volume.health)
            }
            optionalRow(L10n.string("mobile.nas-health.storage.file-system"), volume.fileSystem)
            capacityRows(used: volume.usedBytes, total: volume.totalBytes)
            if volume.isEncrypted {
                Label(
                    L10n.string("mobile.nas-health.storage.encrypted"),
                    systemImage: "lock.fill"
                )
                .font(.footnote)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    private func diskRows(_ disk: MobileNasDiskHealth) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(disk.name).font(.headline)
                Spacer()
                healthBadge(disk.health)
            }
            optionalRow(L10n.string("mobile.nas-health.system.model"), disk.model)
            optionalRow(L10n.string("mobile.nas-health.storage.drive-type"), disk.type)
            optionalRow(
                L10n.string("mobile.nas-health.storage.capacity"),
                MobileNasHealthFormatting.bytes(disk.totalBytes)
            )
            LabeledContent(L10n.string("mobile.nas-health.storage.smart-health")) {
                healthBadge(disk.smartHealth)
            }
            optionalRow(
                L10n.string("mobile.nas-health.system.temperature"),
                MobileNasHealthFormatting.temperature(disk.temperatureCelsius)
            )
            if disk.isSSD {
                optionalRow(
                    L10n.string("mobile.nas-health.storage.ssd-life"),
                    disk.estimatedLifePercent.map { MobileNasHealthFormatting.percent(Double($0)) }
                )
            }
            optionalRow(
                L10n.string("mobile.nas-health.storage.bad-sectors"),
                disk.badSectorCount?.formatted()
            )
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func capacityRows(used: Int64?, total: Int64?) -> some View {
        optionalRow(
            L10n.string("mobile.nas-health.storage.used"),
            MobileNasHealthFormatting.bytes(used)
        )
        optionalRow(
            L10n.string("mobile.nas-health.storage.capacity"),
            MobileNasHealthFormatting.bytes(total)
        )
    }

    private func optionalRow(_ title: String, _ value: String?) -> some View {
        LabeledContent(
            title,
            value: MobileNasHealthFormatting.nonempty(value)
                ?? L10n.string("mobile.nas-health.status.unknown")
        )
    }

    private func storageGroupTitle(_ key: String, image: String) -> some View {
        Label(L10n.string(key), systemImage: image)
            .font(.headline)
            .padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func sectionHeader(
        _ destination: MobileNasAdministrationDestination,
        isRefreshing: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Label(destination.title, systemImage: destination.systemImage)
            if isRefreshing {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(destination.loadingLabel)
            }
        }
    }

    private func healthBadge(_ level: MobileNasHealthLevel) -> some View {
        Label(level.title, systemImage: level.systemImage)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(level.color)
            .accessibilityElement(children: .combine)
    }
}

private extension MobileNasHealthLevel {
    var title: String {
        switch self {
        case .healthy: L10n.string("mobile.nas-health.status.healthy")
        case .warning: L10n.string("mobile.nas-health.status.warning")
        case .critical: L10n.string("mobile.nas-health.status.critical")
        case .unknown: L10n.string("mobile.nas-health.status.unknown")
        }
    }

    var systemImage: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthy: .green
        case .warning: .orange
        case .critical: .red
        case .unknown: .secondary
        }
    }
}

enum MobileNasHealthFormatting {
    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    static func bytes(
        _ value: Int64?,
        countStyle: ByteCountFormatter.CountStyle = .file
    ) -> String? {
        guard let value else { return nil }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: countStyle)
    }

    static func rate(_ value: Int64) -> String {
        L10n.string(
            "mobile.nas-health.accessibility.transfer-rate",
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        )
    }

    static func percent(_ value: Double) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(0)))
    }

    static func temperature(_ value: Double?) -> String? {
        value.map {
            Measurement(value: $0, unit: UnitTemperature.celsius)
                .formatted(.measurement(width: .abbreviated, usage: .weather))
        }
    }

    static func duration(_ seconds: Int64?) -> String? {
        guard let seconds else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds))
    }
}

private struct MobileNasHealthSectionContent<Value: Equatable & Sendable, Content: View>: View {
    let section: MobileNasHealthSection<Value>
    let loading: String
    let emptyTitle: String
    let emptyMessage: String
    let errorTitle: String
    let errorMessage: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    init(
        section: MobileNasHealthSection<Value>,
        loading: String,
        emptyTitle: String = L10n.string("mobile.nas-health.storage.empty.title"),
        emptyMessage: String = L10n.string("mobile.nas-health.storage.empty.message"),
        errorTitle: String,
        errorMessage: String,
        retry: @escaping () -> Void,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.section = section
        self.loading = loading
        self.emptyTitle = emptyTitle
        self.emptyMessage = emptyMessage
        self.errorTitle = errorTitle
        self.errorMessage = errorMessage
        self.retry = retry
        self.content = content
    }

    var body: some View {
        Group {
            if section.hasRefreshError {
                Label(
                    L10n.string("mobile.nas-health.refresh.failed"),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }

            switch section.phase {
            case .idle, .loading:
                HStack(spacing: 12) {
                    ProgressView()
                    Text(loading).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 88, alignment: .center)
                .accessibilityElement(children: .combine)
            case .empty:
                MobileNasHealthRecoveryView(
                    title: emptyTitle,
                    message: emptyMessage,
                    systemImage: "externaldrive.badge.questionmark",
                    retry: retry
                )
            case .error:
                MobileNasHealthRecoveryView(
                    title: errorTitle,
                    message: errorMessage,
                    systemImage: "exclamationmark.triangle",
                    retry: retry
                )
            case .content:
                if let value = section.value { content(value) }
            }
        }
    }
}

private struct MobileNasHealthRecoveryView: View {
    let title: String
    let message: String
    let systemImage: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
            Button(L10n.string("mobile.nas-health.action.retry"), action: retry)
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .padding(.vertical, 8)
    }
}
