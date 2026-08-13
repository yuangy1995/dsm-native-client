import DsmLocalization
import SwiftUI

struct MobileContainersView: View {
    @Bindable var inventory: MobileContainerInventoryModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if inventory.state.pageState == .loading {
                ProgressView(L10n.string("mobile.containers.loading"))
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
                ForEach(MobileContainerSection.allCases) { section in
                    NavigationLink {
                        MobileContainerSectionView(inventory: inventory, section: section)
                    } label: {
                        MobileContainerSectionRow(
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
                    ForEach(MobileContainerSection.allCases) { section in
                        MobileContainerSectionRow(
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
            MobileContainerSectionView(
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
                    L10n.string("mobile.containers.session-expired"),
                    systemImage: "person.crop.circle.badge.exclamationmark"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }
        } else if inventory.state.hasRefreshError {
            Section {
                Label(
                    L10n.string("mobile.containers.refresh.failed"),
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                )
                .font(.subheadline)
                .foregroundStyle(.orange)
                .accessibilityElement(children: .combine)
            }
        }
        Section {
            Label(L10n.string("mobile.containers.read-only.notice"), systemImage: "eye")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
        }
    }

    private var sectionSelection: Binding<MobileContainerSection?> {
        Binding(
            get: { inventory.state.selectedSection },
            set: { if let section = $0 { inventory.selectSection(section) } }
        )
    }
}

private struct MobileContainerSectionRow: View {
    let section: MobileContainerSection
    let state: MobileReadOnlySectionState
    let count: Int

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.title)
                    .font(.body)
                Text(state.summary(count: count))
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
            L10n.string("mobile.containers.accessibility.section", section.title, state.summary(count: count))
        )
    }
}

private struct MobileContainerSectionView: View {
    @Bindable var inventory: MobileContainerInventoryModel
    let section: MobileContainerSection
    var supportsSelection = false

    var body: some View {
        Group {
            if section == .containers, inventory.state.pageState == .filteredEmpty {
                filteredEmptyView
            } else {
                switch inventory.state.sectionState(section) {
                case .unavailable:
                    unavailableView
                case .failed:
                    failedView
                case .empty:
                    emptyView
                case .content:
                    content
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
            L10n.string("mobile.containers.section.unavailable.title"),
            systemImage: "eye.slash",
            description: Text(L10n.string("mobile.containers.section.unavailable.message"))
        )
    }

    private var failedView: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.containers.section.failed.title"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(
                inventory.state.requiresReconnect
                    ? L10n.string("mobile.containers.session-expired")
                    : L10n.string("mobile.containers.section.failed.message")
            )
        } actions: {
            if !inventory.state.requiresReconnect {
                Button(L10n.string("mobile.containers.action.retry")) {
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
            L10n.string("mobile.containers.section.empty.title", section.title),
            systemImage: section.systemImage,
            description: Text(L10n.string("mobile.containers.section.empty.message"))
        )
    }

    private var filteredEmptyView: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.containers.filtered-empty.title"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } description: {
            Text(L10n.string("mobile.containers.filtered-empty.message"))
        } actions: {
            Button(L10n.string("mobile.containers.action.show-all")) {
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
                        L10n.string("mobile.containers.detail.select.title"),
                        systemImage: "rectangle.split.2x1",
                        description: Text(L10n.string("mobile.containers.detail.select.message"))
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
            case .containers:
                Picker(
                    L10n.string("mobile.containers.filter.label"),
                    selection: Binding(
                        get: { inventory.state.filter },
                        set: { inventory.setFilter($0) }
                    )
                ) {
                    ForEach(MobileContainerFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                ForEach(inventory.state.visibleContainers) { item in itemLink(item.id, selectionMode: selectionMode) { containerRow(item) } }
            case .images:
                ForEach(inventory.state.images) { item in itemLink(item.id, selectionMode: selectionMode) { imageRow(item) } }
            case .networks:
                ForEach(inventory.state.networks) { item in itemLink(item.id, selectionMode: selectionMode) { networkRow(item) } }
            case .projects:
                ForEach(inventory.state.projects) { item in itemLink(item.id, selectionMode: selectionMode) { projectRow(item) } }
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

    private func containerRow(_ item: MobileContainerItem) -> some View {
        MobileReadOnlySummaryRow(
            title: item.name,
            subtitle: item.status.title,
            systemImage: item.status.systemImage,
            color: item.status.color
        )
    }

    private func imageRow(_ item: MobileContainerImageItem) -> some View {
        MobileReadOnlySummaryRow(
            title: item.name,
            subtitle: item.isInUse
                ? L10n.string("mobile.containers.value.in-use")
                : L10n.string("mobile.containers.value.not-in-use"),
            systemImage: "shippingbox"
        )
    }

    private func networkRow(_ item: MobileContainerNetworkItem) -> some View {
        MobileReadOnlySummaryRow(
            title: item.name,
            subtitle: item.driver,
            systemImage: "network"
        )
    }

    private func projectRow(_ item: MobileContainerProjectItem) -> some View {
        MobileReadOnlySummaryRow(
            title: item.name,
            subtitle: item.status.title,
            systemImage: "square.stack.3d.up"
        )
    }

    private func eventRow(_ item: MobileContainerEventItem) -> some View {
        MobileReadOnlySummaryRow(
            title: item.level,
            subtitle: item.timestamp?.formatted(date: .abbreviated, time: .shortened)
                ?? L10n.string("mobile.containers.value.time-unavailable"),
            systemImage: "clock.arrow.circlepath"
        )
    }

    @ViewBuilder
    private func detail(for id: String) -> some View {
        switch section {
        case .containers:
            if let item = inventory.state.containers.first(where: { $0.id == id }) {
                detailForm(title: item.name) {
                    LabeledContent(L10n.string("mobile.containers.field.status"), value: item.status.title)
                    LabeledContent(L10n.string("mobile.containers.field.image"), value: item.image)
                }
            }
        case .images:
            if let item = inventory.state.images.first(where: { $0.id == id }) {
                detailForm(title: item.name) {
                    if let size = item.sizeBytes {
                        LabeledContent(L10n.string("mobile.containers.field.size")) {
                            Text(size, format: .byteCount(style: .file))
                        }
                    }
                    LabeledContent(
                        L10n.string("mobile.containers.field.usage"),
                        value: item.isInUse
                            ? L10n.string("mobile.containers.value.in-use")
                            : L10n.string("mobile.containers.value.not-in-use")
                    )
                }
            }
        case .networks:
            if let item = inventory.state.networks.first(where: { $0.id == id }) {
                detailForm(title: item.name) {
                    LabeledContent(L10n.string("mobile.containers.field.driver"), value: item.driver)
                    LabeledContent(
                        L10n.string("mobile.containers.field.connected-containers"),
                        value: item.connectedContainerCount.formatted()
                    )
                }
            }
        case .projects:
            if let item = inventory.state.projects.first(where: { $0.id == id }) {
                detailForm(title: item.name) {
                    LabeledContent(L10n.string("mobile.containers.field.status"), value: item.status.title)
                    LabeledContent(
                        L10n.string("mobile.containers.field.container-count"),
                        value: item.containerCount.formatted()
                    )
                }
            }
        case .events:
            if let item = inventory.state.events.first(where: { $0.id == id }) {
                detailForm(title: item.level) {
                    LabeledContent(L10n.string("mobile.containers.field.level"), value: item.level)
                    LabeledContent(
                        L10n.string("mobile.containers.field.time"),
                        value: item.timestamp?.formatted(date: .abbreviated, time: .shortened)
                            ?? L10n.string("mobile.containers.value.time-unavailable")
                    )
                }
            }
        }
    }

    private func detailForm<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            Section {
                Label(L10n.string("mobile.containers.read-only.notice"), systemImage: "eye")
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

private struct MobileReadOnlySummaryRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var color: Color = .secondary

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium)).lineLimit(2)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("mobile.containers.accessibility.item", title, subtitle))
    }
}

private extension MobileContainerFilter {
    var title: String {
        switch self {
        case .all: L10n.string("mobile.containers.filter.all")
        case .running: L10n.string("mobile.containers.filter.running")
        case .stopped: L10n.string("mobile.containers.filter.stopped")
        case .attention: L10n.string("mobile.containers.filter.attention")
        }
    }
}

private extension MobileContainerSection {
    var title: String {
        switch self {
        case .containers: L10n.string("mobile.containers.section.containers")
        case .images: L10n.string("mobile.containers.section.images")
        case .networks: L10n.string("mobile.containers.section.networks")
        case .projects: L10n.string("mobile.containers.section.projects")
        case .events: L10n.string("mobile.containers.section.events")
        }
    }

    var systemImage: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .networks: "network"
        case .projects: "folder"
        case .events: "clock.arrow.circlepath"
        }
    }
}

private extension MobileReadOnlySectionState {
    func summary(count: Int) -> String {
        switch self {
        case .unavailable: L10n.string("mobile.containers.section.state.unavailable")
        case .failed: L10n.string("mobile.containers.section.state.failed")
        case .empty: L10n.string("mobile.containers.section.state.empty")
        case .content: L10n.string("mobile.containers.section.state.content", count)
        }
    }
}

private extension MobileContainerStatus {
    var title: String {
        switch self {
        case .running: L10n.string("mobile.containers.status.running")
        case .stopped: L10n.string("mobile.containers.status.stopped")
        case .attention: L10n.string("mobile.containers.status.attention")
        case .unknown: L10n.string("mobile.containers.status.unknown")
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
