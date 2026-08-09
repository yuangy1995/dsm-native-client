import DsmLocalization
import SwiftUI

struct MobileVirtualMachinesView: View {
    @Bindable var inventory: MobileVirtualMachineInventoryModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if inventory.state.pageState == .filteredEmpty {
                filteredEmptyView
            } else {
                MobilePageStateView(
                    state: inventory.state.pageState,
                    labels: stateLabels,
                    emptySystemImage: "desktopcomputer",
                    filteredEmptySystemImage: "line.3.horizontal.decrease.circle",
                    errorSystemImage: "exclamationmark.triangle",
                    retryAction: { Task { await inventory.refresh() } }
                ) {
                    content
                }
            }
        }
        .fillsAvailableContentArea(
            alignment: inventory.state.pageState.layout == .topLeading ? .topLeading : .center
        )
    }

    @ViewBuilder
    private var content: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                machineList(selectionMode: true)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
                Divider()
                if let item = inventory.state.selectedItem {
                    MobileVirtualMachineDetailView(item: item)
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
            machineList(selectionMode: false)
        }
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
        .fillsAvailableContentArea()
    }

    @ViewBuilder
    private func machineList(selectionMode: Bool) -> some View {
        if selectionMode {
            machineListBody(selectionMode: true)
                .listStyle(.sidebar)
                .refreshable { await inventory.refresh() }
        } else {
            machineListBody(selectionMode: false)
                .listStyle(.insetGrouped)
                .refreshable { await inventory.refresh() }
        }
    }

    private func machineListBody(selectionMode: Bool) -> some View {
        List {
            if inventory.state.hasRefreshError {
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
                Label(
                    L10n.string("mobile.virtual-machines.read-only.notice"),
                    systemImage: "eye"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            Section {
                Picker(
                    L10n.string("mobile.virtual-machines.filter.label"),
                    selection: filterBinding
                ) {
                    ForEach(MobileVirtualMachineFilter.allCases, id: \.self) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            }

            Section {
                ForEach(inventory.state.visibleItems) { item in
                    if selectionMode {
                        Button {
                            inventory.select(item.id)
                        } label: {
                            MobileVirtualMachineRow(item: item, showsDisclosure: false)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(
                            inventory.state.selectedID == item.id ? .isSelected : []
                        )
                    } else {
                        NavigationLink {
                            MobileVirtualMachineDetailView(item: item)
                        } label: {
                            MobileVirtualMachineRow(item: item, showsDisclosure: false)
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
    }

    private var filterBinding: Binding<MobileVirtualMachineFilter> {
        Binding(
            get: { inventory.state.filter },
            set: { newValue in
                inventory.setFilter(newValue)
            }
        )
    }

    private var stateLabels: MobilePageStateLabels {
        MobilePageStateLabels(
            loading: L10n.string("mobile.virtual-machines.loading"),
            emptyTitle: L10n.string("mobile.virtual-machines.empty.title"),
            emptyMessage: L10n.string("mobile.virtual-machines.empty.message"),
            filteredEmptyTitle: L10n.string("mobile.virtual-machines.filtered-empty.title"),
            filteredEmptyMessage: L10n.string("mobile.virtual-machines.filtered-empty.message"),
            errorTitle: L10n.string("mobile.virtual-machines.error.title"),
            errorMessage: L10n.string("mobile.virtual-machines.error.message"),
            retryTitle: L10n.string("mobile.virtual-machines.action.retry")
        )
    }
}

private struct MobileVirtualMachineRow: View {
    let item: MobileVirtualMachineItem
    let showsDisclosure: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.status.systemImage)
                .foregroundStyle(item.status.color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(item.status.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if showsDisclosure {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.string("mobile.virtual-machines.accessibility.row", item.name, item.status.title)
        )
    }
}

private struct MobileVirtualMachineDetailView: View {
    let item: MobileVirtualMachineItem

    var body: some View {
        Form {
            Section {
                Label(
                    L10n.string("mobile.virtual-machines.read-only.notice"),
                    systemImage: "eye"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            Section(item.name) {
                LabeledContent(L10n.string("mobile.virtual-machines.field.status")) {
                    Label(item.status.title, systemImage: item.status.systemImage)
                        .foregroundStyle(item.status.color)
                }
                if let cpuCount = item.cpuCount {
                    LabeledContent(
                        L10n.string("mobile.virtual-machines.field.cpu"),
                        value: cpuCount.formatted()
                    )
                }
                if let memoryBytes = item.memoryBytes {
                    LabeledContent(L10n.string("mobile.virtual-machines.field.memory")) {
                        Text(memoryBytes, format: .byteCount(style: .memory))
                    }
                }
                if let storageBytes = item.storageBytes {
                    LabeledContent(L10n.string("mobile.virtual-machines.field.storage")) {
                        Text(storageBytes, format: .byteCount(style: .file))
                    }
                }
                LabeledContent(
                    L10n.string("mobile.virtual-machines.field.auto-start"),
                    value: L10n.string(
                        item.autoStart
                            ? "mobile.virtual-machines.value.enabled"
                            : "mobile.virtual-machines.value.disabled"
                    )
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.name)
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
