import DsmCore
import DsmLocalization
import SwiftUI

struct MobileContainerNetworkView: View {
    @Bindable var model: MobileContainerNetworkModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var showsRecords = false
    @State private var showsCreation = false
    @State private var confirmation: MobileContainerNetworkModel.Confirmation?
    @State private var sourceActivation: UUID?
    @State private var path: [String] = []
    private var visible: [ContainerNetwork] { model.targets.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                Picker(L10n.string("mobile.containers.network.title"), selection: $showsRecords) {
                    Text(L10n.string("mobile.containers.section.networks")).tag(false)
                    Text(L10n.string("mobile.containers.control.records")).tag(true)
                }.pickerStyle(.segmented).padding().accessibilityIdentifier("network.section")
                if showsRecords { records } else { networks }
            }
            .navigationTitle(L10n.string("mobile.containers.section.networks"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { id in
                if let target = model.targets.first(where: { $0.id == id }) {
                    Form {
                        MobileContainerNetworkDetails(network: target)
                        Section {
                            Button(L10n.string("mobile.containers.network.delete-one"), role: .destructive) {
                                confirmation = model.confirmation(ids: [id])
                            }.disabled(!model.canDelete(ids: [id])).frame(minHeight: 44).accessibilityIdentifier("network.detail.delete")
                        }
                    }.navigationTitle(target.name).navigationBarTitleDisplayMode(.inline).accessibilityIdentifier("network.details")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.string("container-image.pull.close")) { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(L10n.string("mobile.containers.network.create"), systemImage: "plus") { showsCreation = true }
                        .disabled(!model.canOpenCreation).accessibilityIdentifier("network.create.open")
                    Button(L10n.string("container-image.delete.review"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .disabled(model.isRefreshing || model.isOperating).accessibilityIdentifier("network.refresh")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !showsRecords && !model.targets.isEmpty {
                    Button(L10n.string("mobile.containers.network.delete-selected", selection.count), role: .destructive) {
                        confirmation = model.confirmation(ids: selection)
                    }.buttonStyle(.borderedProminent).tint(.red).frame(minHeight: 44)
                        .disabled(sourceActivation != model.activation || !model.canDelete(ids: selection))
                        .accessibilityIdentifier("network.delete.confirm")
                        .frame(maxWidth: .infinity).padding(.horizontal).padding(.vertical, 8).background(.bar)
                }
            }
            .sheet(isPresented: $showsCreation) {
                MobileContainerNetworkCreationView(model: model) { showsRecords = true }
            }
            .sheet(item: $confirmation) { value in
                MobileContainerNetworkDeletionView(model: model, confirmation: value) { selection = []; path = []; showsRecords = true }
            }
        }
        .task { sourceActivation = model.activation; await model.refresh() }
        .onChange(of: model.activation) { _, value in if sourceActivation != value { dismiss() } }
        .onChange(of: model.targets) { _, values in selection.formIntersection(Set(values.map(\.id))) }
        .onDisappear { model.cancelRead() }
    }
    private var networks: some View {
        Group {
            if !model.hasLoaded && model.isRefreshing {
                ProgressView(L10n.string("mobile.containers.network.loading")).accessibilityIdentifier("network.loading")
            } else if let error = model.error, model.targets.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string("mobile.containers.network.load-error"), systemImage: "exclamationmark.triangle")
                } description: { Text(error.message) } actions: {
                    Button(L10n.string("mobile.containers.action.retry")) { Task { await model.refresh() } }
                }.accessibilityIdentifier("network.load-error")
            } else if model.targets.isEmpty {
                ContentUnavailableView(L10n.string("mobile.containers.network.empty"), systemImage: "network",
                    description: Text(L10n.string("mobile.containers.network.empty-help"))).accessibilityIdentifier("network.empty")
            } else if visible.isEmpty {
                ContentUnavailableView.search(text: query).accessibilityIdentifier("network.filtered-empty")
            } else {
                List {
                    if let error = model.error { Text(error.message).foregroundStyle(.secondary) }
                    if model.isRefreshing { ProgressView() }
                    ForEach(visible) { target in
                        HStack(spacing: 12) {
                            Button {
                                if !selection.insert(target.id).inserted { selection.remove(target.id) }
                            } label: {
                                Image(systemName: selection.contains(target.id) ? "checkmark.circle.fill" : "circle").frame(minWidth: 44, minHeight: 44)
                            }.buttonStyle(.borderless)
                                .accessibilityLabel(L10n.string("mobile.containers.network.select", target.name))
                                .accessibilityAddTraits(selection.contains(target.id) ? .isSelected : [])
                                .disabled(!model.canDelete(ids: [target.id])).accessibilityIdentifier("network.select.\(target.name)")
                            NavigationLink(value: target.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(target.name)
                                    if !target.canDelete { Text(L10n.string(target.connectedContainerCount > 0 ? "container.network.delete.inUse" : "container.network.delete.protected")).font(.caption).foregroundStyle(.secondary) }
                                    else if !model.canDelete(ids: [target.id]) && model.allowed && !model.isOperating && !model.isRefreshing {
                                        Text(L10n.string("mobile.containers.network.protected")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }.frame(minHeight: 44)
                            }.accessibilityIdentifier("network.details.\(target.name)")
                        }
                    }
                }.listStyle(.insetGrouped).accessibilityIdentifier("network.list").refreshable { await model.refresh() }
            }
        }.fillsAvailableContentArea(alignment: model.targets.isEmpty || visible.isEmpty ? .center : .topLeading)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("container.network.search"))
    }
    private var records: some View {
        List {
            if let error = model.error { Text(error.message).foregroundStyle(.secondary) }
            if model.isRefreshing { ProgressView() }
            if model.entries.isEmpty {
                ContentUnavailableView(L10n.string("mobile.containers.control.records.empty"), systemImage: "clock.arrow.circlepath",
                    description: Text(L10n.string("mobile.containers.network.records-help")))
            }
            ForEach(model.entries) { entry in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.names[entry.name] ?? L10n.string("mobile.containers.network.record-target")).font(.headline)
                        Text(L10n.string(entry.action == .create ? "mobile.containers.network.create" : "mobile.containers.network.delete"))
                        Text(message(entry)).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("network.record.\(entry.phase.rawValue)")
                    if !entry.isProtected && !model.recovery.isExecuting(entry.id) {
                        Button(L10n.string("mobile.containers.control.record.remove")) { model.removeRecord(entry.id) }.frame(minHeight: 44)
                    }
                } header: { Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute().locale(L10n.locale)) }
            }
        }.listStyle(.insetGrouped).accessibilityIdentifier("network.records").refreshable { await model.refresh() }
    }
    private func message(_ entry: MobileContainerNetworkStore.Entry) -> String {
        if entry.denied { return L10n.string("mobile.containers.network.denied") }
        switch entry.phase {
        case .succeeded: return L10n.string(entry.action == .create ? "mobile.containers.network.created" : "mobile.containers.network.deleted")
        case .existing: return L10n.string("mobile.containers.network.existing")
        case .absent: return L10n.string("mobile.containers.network.absent")
        case .skipped: return L10n.string("mobile.containers.network.not-sent")
        case .rejected: return L10n.string("mobile.containers.network.rejected")
        case .prepared, .submitted: return L10n.string(model.recovery.isExecuting(entry.id) ? "mobile.containers.network.processing" : "mobile.containers.network.unknown")
        }
    }
}

struct MobileContainerNetworkDetails: View {
    let network: ContainerNetwork
    var body: some View {
        LabeledContent(L10n.string("mobile.containers.field.driver"), value: network.driver)
        LabeledContent(L10n.string("mobile.containers.field.connected-containers"), value: network.connectedContainerCount.formatted(.number.locale(L10n.locale)))
        LabeledContent(L10n.string("container.network.subnet"), value: value(network.subnet))
        LabeledContent(L10n.string("container.network.create.range"), value: value(network.ipRange))
        LabeledContent(L10n.string("container.network.gateway"), value: value(network.gateway))
        LabeledContent(L10n.string("container.network.ipv6"), value: L10n.string(network.isIPv6Enabled.map { $0 ? "container.network.enabled" : "container.network.disabled" } ?? "container.network.notProvided"))
        Section(L10n.string("container.network.containers")) {
            if let names = network.connectedContainerNames {
                if names.isEmpty { Text(L10n.string("container.network.noneConnected")).foregroundStyle(.secondary) }
                ForEach(Array(names.enumerated()), id: \.offset) { _, name in Text(name).textSelection(.enabled) }
            } else {
                Text(network.connectedContainerCount.formatted(.number.locale(L10n.locale)))
                Text(L10n.string("container.network.notProvided")).foregroundStyle(.secondary)
            }
        }
    }
    private func value(_ value: String?) -> String { value.flatMap { $0.isEmpty ? nil : $0 } ?? L10n.string("container.network.notProvided") }
}

private struct MobileContainerNetworkCreationView: View {
    @Bindable var model: MobileContainerNetworkModel
    let onSubmitted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var configuration = ContainerNetworkCreation()
    @State private var sourceActivation: UUID?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    field("mobile.containers.network.name", value: $configuration.name, id: "name")
                }
                Section {
                    Toggle(L10n.string("mobile.containers.network.manual-ipv4"), isOn: $configuration.usesManualIPv4).accessibilityIdentifier("network.create.ipv4")
                    if configuration.usesManualIPv4 {
                        field("container.network.subnet", value: $configuration.subnet, id: "subnet")
                        field("container.network.create.range", value: $configuration.ipRange, id: "range")
                        field("container.network.gateway", value: $configuration.gateway, id: "gateway")
                    }
                }
                Section {
                    Toggle(L10n.string("container.network.ipv6"), isOn: $configuration.isIPv6Enabled).accessibilityIdentifier("network.create.ipv6")
                    if configuration.isIPv6Enabled {
                        field("container.network.create.ipv6Subnet", value: $configuration.ipv6Subnet, id: "ipv6-subnet")
                        field("container.network.create.ipv6Range", value: $configuration.ipv6Range, id: "ipv6-range")
                        field("container.network.create.ipv6Gateway", value: $configuration.ipv6Gateway, id: "ipv6-gateway")
                    }
                }
                Section {
                    Toggle(L10n.string("container.network.create.disableMasquerade"), isOn: $configuration.disableMasquerade).accessibilityIdentifier("network.create.masquerade")
                } footer: { Text(L10n.string("mobile.containers.network.masquerade-help")) }
                if !configuration.name.isEmpty {
                    if let issue = configuration.validationIssue { Text(L10n.string(issue.rawValue)).foregroundStyle(.secondary) }
                    else if model.targets.contains(where: { $0.name == configuration.name }) { Text(L10n.string("container.network.creation.nameTaken")).foregroundStyle(.secondary) }
                    else if !model.canCreate(configuration) { Text(L10n.string("mobile.containers.network.protected")).foregroundStyle(.secondary) }
                }
                if let error = model.error { Text(error.message).foregroundStyle(.secondary) }
            }.accessibilityIdentifier("network.create.form")
                .navigationTitle(L10n.string("mobile.containers.network.create"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.containers.control.cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("mobile.containers.network.create-submit")) {
                            guard let sourceActivation, model.create(configuration, activation: sourceActivation) else { return }
                            dismiss(); onSubmitted()
                        }.disabled(sourceActivation != model.activation || !model.canCreate(configuration)).accessibilityIdentifier("network.create.submit")
                    }
                }
        }.onAppear { sourceActivation = model.activation }
            .onChange(of: configuration.usesManualIPv4) { _, manual in if !manual { configuration.subnet = ""; configuration.ipRange = ""; configuration.gateway = "" } }
            .onChange(of: configuration.isIPv6Enabled) { _, enabled in if !enabled { configuration.ipv6Subnet = ""; configuration.ipv6Range = ""; configuration.ipv6Gateway = "" } }
    }
    private func field(_ key: String, value: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string(key)).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("", text: value).accessibilityLabel(L10n.string(key)).textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.asciiCapable).accessibilityIdentifier("network.create.\(id)")
        }
    }
}

private struct MobileContainerNetworkDeletionView: View {
    @Bindable var model: MobileContainerNetworkModel
    let confirmation: MobileContainerNetworkModel.Confirmation
    let onSubmitted: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section { Text(L10n.string("mobile.containers.network.delete-risk")) }
                Section { ForEach(confirmation.targets) { Text($0.name).textSelection(.enabled) } }
                Section {
                    Button(L10n.string("ui.2f9daa828907b93f"), role: .destructive) {
                        guard model.delete(confirmation) else { return }
                        dismiss(); onSubmitted()
                    }.buttonStyle(.borderedProminent).tint(.red).frame(minHeight: 44)
                        .disabled(confirmation.activation != model.activation || !model.canDelete(ids: Set(confirmation.targets.map(\.id))))
                        .accessibilityIdentifier("network.delete.submit")
                }
            }.accessibilityIdentifier("network.delete.form")
                .navigationTitle(L10n.string("mobile.containers.network.delete"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("mobile.containers.control.cancel")) { dismiss() } } }
        }
    }
}

extension MobileContainerNetworkModel.Failure {
    var message: String {
        switch self {
        case .read: L10n.string("mobile.containers.network.read-error")
        case .denied: L10n.string("mobile.containers.network.denied")
        case .unavailable: L10n.string("mobile.containers.network.unavailable")
        case .changed: L10n.string("mobile.containers.network.changed")
        case .storage: L10n.string("mobile.containers.control.error.storage")
        case .trust: L10n.string("mobile.containers.control.error.trust")
        }
    }
}
