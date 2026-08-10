import DsmLocalization
import SwiftUI

struct MobileNasDetailsScreen: View {
    @Bindable var model: MobileNasDetailsModel
    let destination: MobileNasAdministrationDestination

    var body: some View {
        List {
            MobileNasDetailsSectionView(model: model, destination: destination)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(destination) }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
}

struct MobileNasDetailsSectionView: View {
    @Bindable var model: MobileNasDetailsModel
    let destination: MobileNasAdministrationDestination

    var body: some View {
        Group {
            privacyNotice
            switch destination {
            case .packages: packagesSection
            case .scheduledTasks: scheduledTasksSection
            case .logs: logsSection
            case .connections: connectionsSection
            case .system, .performance, .storage, .update: EmptyView()
            }
        }
        .task(id: destination) { await model.loadIfNeeded(destination) }
        .onDisappear { model.cancel(destination) }
    }

    private var privacyNotice: some View {
        Section {
            Label(
                L10n.string("mobile.nas-details.read-only.notice"),
                systemImage: "eye"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var packagesSection: some View {
        let section = model.state.packages
        return Section {
            MobileNasDetailsSectionContent(
                section: section,
                loading: destination.loadingLabel,
                emptyTitle: L10n.string("mobile.nas-details.packages.empty.title"),
                emptyMessage: L10n.string("mobile.nas-details.packages.empty.message"),
                retry: retry
            ) { page in
                ForEach(page.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MobileNasDetailsFormatting.nonempty(item.name))
                            .font(.headline)
                        optionalRow(
                            L10n.string("mobile.nas-details.field.version"),
                            item.version
                        )
                        LabeledContent(
                            L10n.string("mobile.nas-details.field.status"),
                            value: item.status.title
                        )
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            sectionHeader(isRefreshing: section.isRefreshing)
        } footer: {
            truncationNotice(section.value)
        }
    }

    private var scheduledTasksSection: some View {
        let section = model.state.scheduledTasks
        return Section {
            MobileNasDetailsSectionContent(
                section: section,
                loading: destination.loadingLabel,
                emptyTitle: L10n.string("mobile.nas-details.scheduled-tasks.empty.title"),
                emptyMessage: L10n.string("mobile.nas-details.scheduled-tasks.empty.message"),
                retry: retry
            ) { page in
                ForEach(page.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MobileNasDetailsFormatting.nonempty(item.name))
                            .font(.headline)
                        Label(
                            item.isEnabled
                                ? L10n.string("mobile.nas-details.task.enabled")
                                : L10n.string("mobile.nas-details.task.disabled"),
                            systemImage: item.isEnabled ? "checkmark.circle.fill" : "pause.circle"
                        )
                        .foregroundStyle(item.isEnabled ? .green : .secondary)
                        optionalRow(
                            L10n.string("mobile.nas-details.field.next-trigger"),
                            item.nextTriggerDescription
                        )
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            sectionHeader(isRefreshing: section.isRefreshing)
        } footer: {
            truncationNotice(section.value)
        }
    }

    private var logsSection: some View {
        let section = model.state.logs
        return Section {
            MobileNasDetailsSectionContent(
                section: section,
                loading: destination.loadingLabel,
                emptyTitle: L10n.string("mobile.nas-details.logs.empty.title"),
                emptyMessage: L10n.string("mobile.nas-details.logs.empty.message"),
                retry: retry
            ) { page in
                ForEach(page.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(item.level.title, systemImage: item.level.systemImage)
                            .font(.headline)
                            .foregroundStyle(item.level.color)
                        optionalRow(
                            L10n.string("mobile.nas-details.field.time"),
                            item.date.map(MobileNasDetailsFormatting.date)
                        )
                        optionalRow(
                            L10n.string("mobile.nas-details.field.source"),
                            item.source
                        )
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            sectionHeader(isRefreshing: section.isRefreshing)
        } footer: {
            truncationNotice(section.value)
        }
    }

    private var connectionsSection: some View {
        let section = model.state.connections
        return Section {
            MobileNasDetailsSectionContent(
                section: section,
                loading: destination.loadingLabel,
                emptyTitle: L10n.string("mobile.nas-details.connections.empty.title"),
                emptyMessage: L10n.string("mobile.nas-details.connections.empty.message"),
                retry: retry
            ) { page in
                ForEach(page.items) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            MobileNasDetailsFormatting.nonempty(item.protocolName),
                            systemImage: "network"
                        )
                        .font(.headline)
                        if item.isCurrentConnection {
                            Label(
                                L10n.string("mobile.nas-details.connection.current"),
                                systemImage: "checkmark.circle.fill"
                            )
                            .foregroundStyle(.green)
                        }
                        optionalRow(
                            L10n.string("mobile.nas-details.field.type"),
                            item.type
                        )
                        optionalRow(
                            L10n.string("mobile.nas-details.field.connected-at"),
                            item.connectedAt.map(MobileNasDetailsFormatting.date)
                        )
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            }
        } header: {
            sectionHeader(isRefreshing: section.isRefreshing)
        } footer: {
            truncationNotice(section.value)
        }
    }

    private var retry: () -> Void {
        { Task { await model.refresh(destination) } }
    }

    private func sectionHeader(isRefreshing: Bool) -> some View {
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

    private func optionalRow(_ title: String, _ value: String?) -> some View {
        LabeledContent(title, value: MobileNasDetailsFormatting.nonempty(value))
    }

    @ViewBuilder
    private func truncationNotice<Item>(_ page: MobileNasBoundedPage<Item>?) -> some View {
        if let page, page.isTruncated {
            Text(
                L10n.string(
                    "mobile.nas-details.partial",
                    page.items.count.formatted(),
                    page.total.formatted()
                )
            )
        }
    }
}

private struct MobileNasDetailsSectionContent<
    Value: Equatable & Sendable,
    Content: View
>: View {
    let section: MobileNasDetailsSection<Value>
    let loading: String
    let emptyTitle: String
    let emptyMessage: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        Group {
            if section.hasRefreshError {
                Label(
                    L10n.string("mobile.nas-details.refresh.failed"),
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
                MobileNasDetailsRecoveryView(
                    title: emptyTitle,
                    message: emptyMessage,
                    systemImage: "tray",
                    retry: retry
                )
            case .error:
                MobileNasDetailsRecoveryView(
                    title: L10n.string("mobile.nas-details.error.title"),
                    message: L10n.string("mobile.nas-details.error.message"),
                    systemImage: "exclamationmark.triangle",
                    retry: retry
                )
            case .unavailable:
                MobileNasDetailsRecoveryView(
                    title: L10n.string("mobile.nas-details.unavailable.title"),
                    message: L10n.string("mobile.nas-details.unavailable.message"),
                    systemImage: "nosign",
                    retry: retry
                )
            case .content:
                if let value = section.value { content(value) }
            }
        }
    }
}

private struct MobileNasDetailsRecoveryView: View {
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

enum MobileNasDetailsFormatting {
    static func nonempty(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return L10n.string("mobile.nas-details.value.unavailable")
        }
        return value
    }

    static func date(_ value: Date) -> String {
        value.formatted(date: .abbreviated, time: .shortened)
    }
}

extension MobileNasAdministrationDestination {
    var title: String {
        switch self {
        case .system: L10n.string("mobile.nas-health.section.system")
        case .performance: L10n.string("mobile.nas-health.section.performance")
        case .storage: L10n.string("mobile.nas-health.section.storage")
        case .update: L10n.string("mobile.nas-health.section.update")
        case .packages: L10n.string("mobile.nas-details.section.packages")
        case .scheduledTasks: L10n.string("mobile.nas-details.section.scheduled-tasks")
        case .logs: L10n.string("mobile.nas-details.section.logs")
        case .connections: L10n.string("mobile.nas-details.section.connections")
        }
    }

    var loadingLabel: String {
        switch self {
        case .system: L10n.string("mobile.nas-health.loading.system")
        case .performance: L10n.string("mobile.nas-health.loading.performance")
        case .storage: L10n.string("mobile.nas-health.loading.storage")
        case .update: L10n.string("mobile.nas-health.loading.update")
        case .packages: L10n.string("mobile.nas-details.loading.packages")
        case .scheduledTasks: L10n.string("mobile.nas-details.loading.scheduled-tasks")
        case .logs: L10n.string("mobile.nas-details.loading.logs")
        case .connections: L10n.string("mobile.nas-details.loading.connections")
        }
    }

    var systemImage: String {
        switch self {
        case .system: "server.rack"
        case .performance: "gauge.with.dots.needle.67percent"
        case .storage: "externaldrive.fill"
        case .update: "arrow.triangle.2.circlepath.circle"
        case .packages: "shippingbox.fill"
        case .scheduledTasks: "calendar.badge.clock"
        case .logs: "doc.text.magnifyingglass"
        case .connections: "network"
        }
    }
}

private extension MobileNasPackageStatus {
    var title: String {
        switch self {
        case .running: L10n.string("mobile.nas-details.package.status.running")
        case .stopped: L10n.string("mobile.nas-details.package.status.stopped")
        case .needsAttention: L10n.string("mobile.nas-details.package.status.needs-attention")
        case .unknown: L10n.string("mobile.nas-details.package.status.unknown")
        }
    }
}

private extension MobileNasLogLevel {
    var title: String {
        switch self {
        case .information: L10n.string("mobile.nas-details.log.level.information")
        case .warning: L10n.string("mobile.nas-details.log.level.warning")
        case .error: L10n.string("mobile.nas-details.log.level.error")
        case .unknown: L10n.string("mobile.nas-details.log.level.unknown")
        }
    }

    var systemImage: String {
        switch self {
        case .information: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .information: .secondary
        case .warning: .orange
        case .error: .red
        case .unknown: .secondary
        }
    }
}
