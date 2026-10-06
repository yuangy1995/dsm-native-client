import DsmLocalization
import SwiftUI

struct MobileContainersView: View {
    @Bindable var inventory: MobileContainerInventoryModel
    @Bindable var controls: MobileContainerControlModel
    @Bindable var imagePulls: MobileContainerImagePullModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsSelection = false
    @State private var showsImagePulls = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if inventory.state.pageState == .loading {
                    ProgressView(L10n.string("mobile.containers.loading"))
                        .fillsAvailableContentArea()
                        .accessibilityIdentifier("container.loading")
                } else if horizontalSizeClass == .regular && geometry.size.width >= 680 && !dynamicTypeSize.isAccessibilitySize {
                    regularLayout(inlineDetails: geometry.size.width >= 1040)
                } else {
                    compactLayout
                }
            }
        }
        .fillsAvailableContentArea(
            alignment: inventory.state.pageState.layout == .topLeading ? .topLeading : .center
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(L10n.string("mobile.containers.control.selection"), systemImage: "checklist") { showsSelection = true }
                    .disabled(!controls.allowed || controls.targets.isEmpty)
                    .accessibilityIdentifier("container.selection")
            }
        }
        .sheet(isPresented: $showsSelection) { MobileContainerSelectionView(model: controls) }
        .sheet(isPresented: $showsImagePulls) { MobileContainerImagePullView(model: imagePulls) }
        .onChange(of: imagePulls.readyCount) { previous, count in
            if count > previous { Task { await inventory.refresh() } }
        }
        .onChange(of: controls.targets) { previous, _ in
            if !previous.isEmpty && !controls.isOperating && controls.error != .trust && controls.error != .denied {
                Task { await inventory.refresh() }
            }
        }
    }

    private var compactLayout: some View {
        List {
            noticeSections
            Section {
                ForEach(MobileContainerSection.allCases) { section in
                    NavigationLink {
                        MobileContainerSectionView(inventory: inventory, controls: controls, section: section)
                    } label: {
                        MobileContainerSectionRow(
                            section: section,
                            state: inventory.state.sectionState(section),
                            count: inventory.state.itemCount(section)
                        )
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("container.section.\(section.rawValue)")
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("container.sections")
        .refreshable { await inventory.refresh(); await controls.refresh() }
    }

    private func regularLayout(inlineDetails: Bool) -> some View {
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
                        .accessibilityIdentifier("container.section.\(section.rawValue)")
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("container.sections")
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            .refreshable { await inventory.refresh(); await controls.refresh() }

            Divider()
            MobileContainerSectionView(
                inventory: inventory,
                controls: controls,
                section: inventory.state.selectedSection,
                supportsSelection: inlineDetails
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
            Button(L10n.string("mobile.containers.pull.title"), systemImage: "arrow.down.circle") { showsImagePulls = true }
                .frame(minHeight: 44).accessibilityIdentifier("image-pull.open")
            MobileContainerControlNotice(model: controls)
            NavigationLink { MobileContainerControlRecordsView(model: controls) } label: {
                Label(L10n.string("mobile.containers.control.records"), systemImage: "clock.arrow.circlepath")
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("container.records.open")
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
    @Bindable var controls: MobileContainerControlModel
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
        .accessibilityIdentifier("container.empty")
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
                .accessibilityIdentifier("container.filter")
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
        .accessibilityIdentifier("container.items")
        .refreshable { await inventory.refresh(); await controls.refresh() }
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
                .accessibilityIdentifier("container.item.\(id)")
        } else {
            NavigationLink { detail(for: id) } label: { label() }
                .frame(minHeight: 44)
                .accessibilityIdentifier("container.item.\(id)")
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
            title: item.message,
            subtitle: item.timestamp?.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))
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
                    if let project = item.project { LabeledContent(L10n.string("mobile.containers.field.project"), value: project) }
                    if let cpu = item.cpuUsage { LabeledContent(L10n.string("mobile.containers.field.cpu"), value: L10n.string("mobile.containers.value.cpu", cpu)) }
                    if let memory = item.memoryBytes {
                        LabeledContent(L10n.string("mobile.containers.field.memory")) { Text(memory, format: .byteCount(style: .memory)) }
                    }
                    MobileContainerControlNotice(model: controls)
                    MobileContainerActions(model: controls, ids: [item.id])
                    NavigationLink(L10n.string("mobile.containers.control.records")) { MobileContainerControlRecordsView(model: controls) }
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
                        value: item.connectedContainerCount.formatted(.number.locale(L10n.locale))
                    )
                }
            }
        case .projects:
            if let item = inventory.state.projects.first(where: { $0.id == id }) {
                detailForm(title: item.name) {
                    LabeledContent(L10n.string("mobile.containers.field.status"), value: item.status.title)
                    LabeledContent(
                        L10n.string("mobile.containers.field.container-count"),
                        value: item.containerCount.formatted(.number.locale(L10n.locale))
                    )
                }
            }
        case .events:
            if let item = inventory.state.events.first(where: { $0.id == id }) {
                detailForm(title: L10n.string("mobile.containers.section.events")) {
                    LabeledContent(L10n.string("mobile.containers.field.level"), value: item.level)
                    LabeledContent(
                        L10n.string("mobile.containers.field.time"),
                        value: item.timestamp?.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))
                            ?? L10n.string("mobile.containers.value.time-unavailable")
                    )
                    if let user = item.user { LabeledContent(L10n.string("mobile.containers.field.user"), value: user) }
                    Text(item.message).textSelection(.enabled)
                }
            }
        }
    }

    private func detailForm<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            Section { content() }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("container.detail")
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
