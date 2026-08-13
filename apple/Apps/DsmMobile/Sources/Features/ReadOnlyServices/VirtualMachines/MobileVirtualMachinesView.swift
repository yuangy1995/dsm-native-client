import DsmLocalization
import SwiftUI

struct MobileVirtualMachinesView: View {
    @Bindable var inventory: MobileVirtualMachineInventoryModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if inventory.state.pageState == .loading {
                ProgressView(L10n.string("mobile.virtual-machines.loading"))
                    .fillsAvailableContentArea()
            } else if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .fillsAvailableContentArea(
            alignment: inventory.state.pageState.layout == .topLeading ? .topLeading : .center
        )
    }

    private var compactLayout: some View {
        List {
            noticeSections
            Section {
                ForEach(MobileVirtualMachineSection.allCases) { section in
                    NavigationLink {
                        MobileVirtualMachineSectionView(inventory: inventory, section: section)
                    } label: {
                        MobileVirtualMachineSectionRow(
                            section: section,
                            state: inventory.state.sectionState(section),
                            count: inventory.state.itemCount(section)
                        )
                    }
                    .frame(minHeight: 44)
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await inventory.refresh() }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            List(selection: sectionSelection) {
                noticeSections
                Section {
                    ForEach(MobileVirtualMachineSection.allCases) { section in
                        MobileVirtualMachineSectionRow(
                            section: section,
                            state: inventory.state.sectionState(section),
                            count: inventory.state.itemCount(section)
                        )
                        .tag(section)
                        .frame(minHeight: 44)
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            .refreshable { await inventory.refresh() }

            Divider()
            MobileVirtualMachineSectionView(
                inventory: inventory,
                section: inventory.state.selectedSection,
                supportsSelection: true
            )
        }
    }

    @ViewBuilder
    private var noticeSections: some View {
        if inventory.state.requiresReconnect {
            Section {
                Label(
                    L10n.string("mobile.virtual-machines.session-expired"),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }
        } else if inventory.state.hasRefreshError {
            Section {
                Label(
                    L10n.string("mobile.virtual-machines.refresh.failed"),
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }
        }
        Section {
            Label(L10n.string("mobile.virtual-machines.read-only.notice"), systemImage: "eye")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        }
    }

    private var sectionSelection: Binding<MobileVirtualMachineSection?> {
        Binding(
            get: { inventory.state.selectedSection },
            set: { if let section = $0 { inventory.selectSection(section) } }
        )
    }
}

private struct MobileVirtualMachineSectionRow: View {
    let section: MobileVirtualMachineSection
    let state: MobileReadOnlySectionState
    let count: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title).font(.body)
                Text(state.virtualMachineSummary(count: count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: section.systemImage)
                .foregroundStyle(state == .failed ? .orange : .secondary)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.string(
                "mobile.virtual-machines.accessibility.section",
                section.title,
                state.virtualMachineSummary(count: count)
            )
        )
    }
}

private struct MobileVirtualMachineSectionView: View {
    @Bindable var inventory: MobileVirtualMachineInventoryModel
    let section: MobileVirtualMachineSection
    var supportsSelection = false

    var body: some View {
        Group {
            if section == .machines, inventory.state.pageState == .filteredEmpty {
                filteredEmptyView
            } else {
                switch inventory.state.sectionState(section) {
                case .unavailable: unavailableView
                case .failed: failedView
                case .empty: emptyView
                case .content: content
                }
            }
        }
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(
            alignment: inventory.state.sectionState(section) == .content ? .topLeading : .center
        )
    }

    private var unavailableView: some View {
        ContentUnavailableView(
            L10n.string("mobile.virtual-machines.section.unavailable.title"),
            systemImage: "eye.slash",
            description: Text(L10n.string("mobile.virtual-machines.section.unavailable.message"))
        )
    }

    private var failedView: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.virtual-machines.section.failed.title"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(
                inventory.state.requiresReconnect
                    ? L10n.string("mobile.virtual-machines.session-expired")
                    : L10n.string("mobile.virtual-machines.section.failed.message")
            )
        } actions: {
            if !inventory.state.requiresReconnect {
                Button(L10n.string("mobile.virtual-machines.action.retry")) {
                    Task { await inventory.refresh() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minWidth: 44, minHeight: 44)
            }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            L10n.string("mobile.virtual-machines.section.empty.title", section.title),
            systemImage: section.systemImage,
            description: Text(L10n.string("mobile.virtual-machines.section.empty.message"))
        )
    }

    private var filteredEmptyView: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.virtual-machines.filtered-empty.title"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } description: {
            Text(L10n.string("mobile.virtual-machines.filtered-empty.message"))
        } actions: {
            Button(L10n.string("mobile.virtual-machines.action.show-all")) {
                inventory.setFilter(.all)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
        }
    }

    @ViewBuilder
    private var content: some View {
        if supportsSelection {
            HStack(spacing: 0) {
                itemList(selectionMode: true)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 420)
                Divider()
                if let selectedID = inventory.state.selectedItemID {
                    detail(for: selectedID)
                } else {
                    ContentUnavailableView(
                        L10n.string("mobile.virtual-machines.detail.select.title"),
                        systemImage: "rectangle.split.2x1",
                        description: Text(L10n.string("mobile.virtual-machines.detail.select.message"))
                    )
                    .fillsAvailableContentArea()
                }
            }
        } else {
            itemList(selectionMode: false)
        }
    }

    private func itemList(selectionMode: Bool) -> some View {
        List {
            switch section {
            case .machines:
                Picker(
                    L10n.string("mobile.virtual-machines.filter.label"),
                    selection: Binding(
                        get: { inventory.state.filter },
                        set: { inventory.setFilter($0) }
                    )
                ) {
                    ForEach(MobileVirtualMachineFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                ForEach(inventory.state.visibleMachines) { item in itemLink(item.id, selectionMode: selectionMode) { machineRow(item) } }
            case .hosts:
                ForEach(inventory.state.hosts) { item in itemLink(item.id, selectionMode: selectionMode) { resourceRow(item) } }
            case .storages:
                ForEach(inventory.state.storages) { item in itemLink(item.id, selectionMode: selectionMode) { resourceRow(item) } }
            case .networks:
                ForEach(inventory.state.networks) { item in itemLink(item.id, selectionMode: selectionMode) { resourceRow(item) } }
            case .images:
                ForEach(inventory.state.images) { item in itemLink(item.id, selectionMode: selectionMode) { resourceRow(item) } }
            case .protection:
                ForEach(inventory.state.protection) { item in itemLink(item.id, selectionMode: selectionMode) { protectionRow(item) } }
            case .events:
                ForEach(inventory.state.events) { item in itemLink(item.id, selectionMode: selectionMode) { eventRow(item) } }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await inventory.refresh() }
    }

    @ViewBuilder
    private func itemLink<Label: View>(
        _ id: String,
        selectionMode: Bool,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if selectionMode {
            Button { inventory.selectItem(id) } label: { label() }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityAddTraits(inventory.state.selectedItemID == id ? .isSelected : [])
        } else {
            NavigationLink { detail(for: id) } label: { label() }
                .frame(minHeight: 44)
        }
    }

    private func machineRow(_ item: MobileVirtualMachineItem) -> some View {
        summaryRow(item.name, item.status.title, item.status.systemImage, item.status.color)
    }

    private func resourceRow(_ item: MobileVirtualizationResourceItem) -> some View {
        summaryRow(item.name, item.status.title, section.systemImage, item.status.color)
    }

    private func protectionRow(_ item: MobileProtectionItem) -> some View {
        summaryRow(item.name, item.kind.title, "lock.shield", item.status.color)
    }

    private func eventRow(_ item: MobileVirtualMachineEventItem) -> some View {
        summaryRow(
            item.level,
            item.timestamp?.formatted(date: .abbreviated, time: .shortened)
                ?? L10n.string("mobile.virtual-machines.value.time-unavailable"),
            "clock.arrow.circlepath",
            .secondary
        )
    }

    private func summaryRow(
        _ title: String,
        _ subtitle: String,
        _ systemImage: String,
        _ color: Color
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color).accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.string("mobile.virtual-machines.accessibility.item", title, subtitle)
        )
    }

    @ViewBuilder
    private func detail(for id: String) -> some View {
        switch section {
        case .machines:
            if let item = inventory.state.machines.first(where: { $0.id == id }) {
                detailForm(title: item.name) {
                    LabeledContent(L10n.string("mobile.virtual-machines.field.status"), value: item.status.title)
                    if let cpu = item.cpuCount {
                        LabeledContent(L10n.string("mobile.virtual-machines.field.cpu"), value: cpu.formatted())
                    }
                    if let memory = item.memoryBytes {
                        LabeledContent(L10n.string("mobile.virtual-machines.field.memory")) {
                            Text(memory, format: .byteCount(style: .memory))
                        }
                    }
                    if let storage = item.storageBytes {
                        LabeledContent(L10n.string("mobile.virtual-machines.field.storage")) {
                            Text(storage, format: .byteCount(style: .file))
                        }
                    }
                    LabeledContent(
                        L10n.string("mobile.virtual-machines.field.auto-start"),
                        value: item.autoStart
                            ? L10n.string("mobile.virtual-machines.value.enabled")
                            : L10n.string("mobile.virtual-machines.value.disabled")
                    )
                }
            }
        case .hosts, .storages, .networks, .images:
            if let item = resources.first(where: { $0.id == id }) {
                detailForm(title: item.name) {
                    LabeledContent(L10n.string("mobile.virtual-machines.field.status"), value: item.status.title)
                    if let allocated = item.allocatedBytes {
                        LabeledContent(L10n.string("mobile.virtual-machines.field.allocated")) {
                            Text(allocated, format: .byteCount(style: .file))
                        }
                    }
                    if let capacity = item.capacityBytes {
                        LabeledContent(L10n.string("mobile.virtual-machines.field.capacity")) {
                            Text(capacity, format: .byteCount(style: .file))
                        }
                    }
                }
            }
        case .protection:
            if let item = inventory.state.protection.first(where: { $0.id == id }) {
                detailForm(title: item.name) {
                    LabeledContent(L10n.string("mobile.virtual-machines.field.kind"), value: item.kind.title)
                    LabeledContent(L10n.string("mobile.virtual-machines.field.status"), value: item.status.title)
                }
            }
        case .events:
            if let item = inventory.state.events.first(where: { $0.id == id }) {
                detailForm(title: item.level) {
                    LabeledContent(L10n.string("mobile.virtual-machines.field.level"), value: item.level)
                    LabeledContent(
                        L10n.string("mobile.virtual-machines.field.time"),
                        value: item.timestamp?.formatted(date: .abbreviated, time: .shortened)
                            ?? L10n.string("mobile.virtual-machines.value.time-unavailable")
                    )
                }
            }
        }
    }

    private var resources: [MobileVirtualizationResourceItem] {
        switch section {
        case .hosts: inventory.state.hosts
        case .storages: inventory.state.storages
        case .networks: inventory.state.networks
        case .images: inventory.state.images
        default: []
        }
    }

    private func detailForm<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            Section {
                Label(L10n.string("mobile.virtual-machines.read-only.notice"), systemImage: "eye")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section(title) { content() }
        }
        .formStyle(.grouped)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(alignment: .topLeading)
    }
}

private extension MobileVirtualMachineFilter {
    var title: String {
        switch self {
        case .all: L10n.string("mobile.virtual-machines.filter.all")
        case .running: L10n.string("mobile.virtual-machines.filter.running")
        case .stopped: L10n.string("mobile.virtual-machines.filter.stopped")
        case .attention: L10n.string("mobile.virtual-machines.filter.attention")
        }
    }
}

private extension MobileVirtualMachineSection {
    var title: String {
        switch self {
        case .machines: L10n.string("mobile.virtual-machines.section.machines")
        case .hosts: L10n.string("mobile.virtual-machines.section.hosts")
        case .storages: L10n.string("mobile.virtual-machines.section.storages")
        case .networks: L10n.string("mobile.virtual-machines.section.networks")
        case .images: L10n.string("mobile.virtual-machines.section.images")
        case .protection: L10n.string("mobile.virtual-machines.section.protection")
        case .events: L10n.string("mobile.virtual-machines.section.events")
        }
    }

    var systemImage: String {
        switch self {
        case .machines: "desktopcomputer"
        case .hosts: "server.rack"
        case .storages: "externaldrive"
        case .networks: "network"
        case .images: "opticaldisc"
        case .protection: "lock.shield"
        case .events: "clock.arrow.circlepath"
        }
    }
}

private extension MobileReadOnlySectionState {
    func virtualMachineSummary(count: Int) -> String {
        switch self {
        case .unavailable: L10n.string("mobile.virtual-machines.section.state.unavailable")
        case .failed: L10n.string("mobile.virtual-machines.section.state.failed")
        case .empty: L10n.string("mobile.virtual-machines.section.state.empty")
        case .content: L10n.string("mobile.virtual-machines.section.state.content", count)
        }
    }
}

private extension MobileVirtualMachineStatus {
    var title: String {
        switch self {
        case .running: L10n.string("mobile.virtual-machines.status.running")
        case .stopped: L10n.string("mobile.virtual-machines.status.stopped")
        case .attention: L10n.string("mobile.virtual-machines.status.attention")
        case .unknown: L10n.string("mobile.virtual-machines.status.unknown")
        }
    }

    var systemImage: String {
        switch self {
        case .running: "play.circle.fill"
        case .stopped: "stop.circle"
        case .attention: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .stopped, .unknown: .secondary
        case .attention: .orange
        }
    }
}

private extension MobileProtectionKind {
    var title: String {
        switch self {
        case .plan: L10n.string("mobile.virtual-machines.protection.plan")
        case .schedule: L10n.string("mobile.virtual-machines.protection.schedule")
        case .retention: L10n.string("mobile.virtual-machines.protection.retention")
        }
    }
}
