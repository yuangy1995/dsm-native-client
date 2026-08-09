import DsmLocalization
import SwiftUI

struct MobileContainersView: View {
    @Bindable var inventory: MobileContainerInventoryModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if inventory.state.pageState == .filteredEmpty {
                filteredEmptyView
            } else {
                MobilePageStateView(
                    state: inventory.state.pageState,
                    labels: stateLabels,
                    emptySystemImage: "shippingbox",
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
                containerList(selectionMode: true)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
                Divider()
                if let item = inventory.state.selectedItem {
                    MobileContainerDetailView(item: item)
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
            containerList(selectionMode: false)
        }
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
        .fillsAvailableContentArea()
    }

    @ViewBuilder
    private func containerList(selectionMode: Bool) -> some View {
        if selectionMode {
            containerListBody(selectionMode: true)
                .listStyle(.sidebar)
                .refreshable { await inventory.refresh() }
        } else {
            containerListBody(selectionMode: false)
                .listStyle(.insetGrouped)
                .refreshable { await inventory.refresh() }
        }
    }

    private func containerListBody(selectionMode: Bool) -> some View {
        List {
            if inventory.state.hasRefreshError {
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
                Label(
                    L10n.string("mobile.containers.read-only.notice"),
                    systemImage: "eye"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            Section {
                Picker(
                    L10n.string("mobile.containers.filter.label"),
                    selection: filterBinding
                ) {
                    ForEach(MobileContainerFilter.allCases, id: \.self) { filter in
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
                            MobileContainerRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityAddTraits(
                            inventory.state.selectedID == item.id ? .isSelected : []
                        )
                    } else {
                        NavigationLink {
                            MobileContainerDetailView(item: item)
                        } label: {
                            MobileContainerRow(item: item)
                        }
                        .frame(minHeight: 44)
                    }
                }
            }
        }
    }

    private var filterBinding: Binding<MobileContainerFilter> {
        Binding(
            get: { inventory.state.filter },
            set: { inventory.setFilter($0) }
        )
    }

    private var stateLabels: MobilePageStateLabels {
        MobilePageStateLabels(
            loading: L10n.string("mobile.containers.loading"),
            emptyTitle: L10n.string("mobile.containers.empty.title"),
            emptyMessage: L10n.string("mobile.containers.empty.message"),
            filteredEmptyTitle: L10n.string("mobile.containers.filtered-empty.title"),
            filteredEmptyMessage: L10n.string("mobile.containers.filtered-empty.message"),
            errorTitle: L10n.string("mobile.containers.error.title"),
            errorMessage: L10n.string("mobile.containers.error.message"),
            retryTitle: L10n.string("mobile.containers.action.retry")
        )
    }
}

private struct MobileContainerRow: View {
    let item: MobileContainerItem

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
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            L10n.string("mobile.containers.accessibility.row", item.name, item.status.title)
        )
    }
}

private struct MobileContainerDetailView: View {
    let item: MobileContainerItem

    var body: some View {
        Form {
            Section {
                Label(
                    L10n.string("mobile.containers.read-only.notice"),
                    systemImage: "eye"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            }

            Section(item.name) {
                LabeledContent(L10n.string("mobile.containers.field.status")) {
                    Label(item.status.title, systemImage: item.status.systemImage)
                        .foregroundStyle(item.status.color)
                }
                LabeledContent(
                    L10n.string("mobile.containers.field.image"),
                    value: item.image ?? L10n.string("mobile.containers.value.image-unavailable")
                )
            }
        }
        .formStyle(.grouped)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(alignment: .topLeading)
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
