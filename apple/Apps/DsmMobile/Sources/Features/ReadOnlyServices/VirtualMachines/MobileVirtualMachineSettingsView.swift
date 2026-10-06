import DsmCore
import DsmLocalization
import SwiftUI

struct MobileVirtualMachineSettingsRequest: Identifiable {
    let id = UUID()
    let targetID: String
    let activation: UUID
}

struct MobileVirtualMachineSettingsDraft {
    let original: VirtualMachineSettingsState
    var name: String
    var description: String
    var cpuCount: Int?
    var memoryMiB: Int?
    var cpuWeight: Int?
    var startupBehavior: VirtualMachineStartupBehavior?

    init(_ original: VirtualMachineSettingsState) {
        self.original = original; name = original.name; description = original.description ?? ""
        cpuCount = original.cpuCount; memoryMiB = original.memoryMiB; cpuWeight = original.cpuWeight
        startupBehavior = original.startupBehavior
    }
    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasChanges: Bool {
        normalizedName != original.name || description != (original.description ?? "")
            || cpuWeight != original.cpuWeight || startupBehavior != original.startupBehavior
            || (original.canEditHardware && (cpuCount != original.cpuCount || memoryMiB != original.memoryMiB))
    }
    var isValid: Bool {
        !normalizedName.isEmpty && normalizedName.count <= 255
            && !normalizedName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && description.count <= 1024
            && (cpuWeight == original.cpuWeight || cpuWeight.map { [8, 64, 256, 512, 1024].contains($0) } == true)
            && (startupBehavior == original.startupBehavior || startupBehavior != nil)
            && (!original.canEditHardware || ((cpuCount == original.cpuCount || cpuCount.map { (1...64).contains($0) } == true)
                && (memoryMiB == original.memoryMiB || memoryMiB.map { (128...1_048_576).contains($0) } == true)))
    }
    var update: VirtualMachineUpdate {
        .init(name: normalizedName == original.name ? nil : normalizedName,
              description: description == (original.description ?? "") ? nil : description,
              cpuCount: original.canEditHardware && cpuCount != original.cpuCount ? cpuCount : nil,
              memoryMiB: original.canEditHardware && memoryMiB != original.memoryMiB ? memoryMiB : nil,
              cpuWeight: cpuWeight == original.cpuWeight ? nil : cpuWeight,
              startupBehavior: startupBehavior == original.startupBehavior ? nil : startupBehavior)
    }
}

struct MobileVirtualMachineSettingsView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let request: MobileVirtualMachineSettingsRequest
    @Environment(\.dismiss) private var dismiss
    @State private var settings: VirtualMachineSettingsState?
    @State private var failure: MobileVirtualMachineControlModel.Failure?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L10n.string("mobile.virtual-machines.settings.loading"))
                        .fillsAvailableContentArea().accessibilityIdentifier("virtual-machine.settings.loading")
                } else if let settings {
                    MobileVirtualMachineSettingsForm(model: model, target: settings, activation: request.activation)
                } else {
                    ContentUnavailableView {
                        Label(L10n.string("mobile.virtual-machines.settings.unavailable"), systemImage: "exclamationmark.circle")
                            .accessibilityIdentifier("virtual-machine.settings.error")
                    } description: {
                        Text(L10n.string(failureKey))
                    } actions: {
                        if failure != .trust && failure != .denied {
                            Button(L10n.string("mobile.virtual-machines.action.retry")) { Task { await load() } }
                                .accessibilityIdentifier("virtual-machine.settings.retry")
                        }
                    }
                    .fillsAvailableContentArea()
                }
            }
            .navigationTitle(L10n.string("mobile.virtual-machines.settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.virtual-machines.control.cancel")) { dismiss() }
                        .disabled(model.isOperating).accessibilityIdentifier("virtual-machine.settings.cancel")
                }
            }
        }
        .interactiveDismissDisabled(model.isOperating)
        .task { await load() }
        .onChange(of: model.activation) { _, _ in dismiss() }
    }
    private var failureKey: String {
        switch failure {
        case .denied: "mobile.virtual-machines.control.error.denied"
        case .trust: "mobile.virtual-machines.control.error.trust"
        case .changed: "virtual-machine.settings.changed"
        default: "mobile.virtual-machines.settings.error.read"
        }
    }
    private func load() async {
        isLoading = true; failure = nil
        do {
            let value = try await model.loadSettings(id: request.targetID, activation: request.activation)
            try Task.checkCancellation()
            settings = value; isLoading = false
        } catch {
            guard !Task.isCancelled, model.activation == request.activation else { return }
            failure = MobileVirtualMachineControlModel.failure(error); isLoading = false
        }
    }
}

private struct MobileVirtualMachineSettingsForm: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let target: VirtualMachineSettingsState
    let activation: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MobileVirtualMachineSettingsDraft
    @State private var isSaving = false
    @State private var resultID: UUID?
    private enum Field: Hashable { case name, description, cpu, memory }
    @FocusState private var focus: Field?

    init(model: MobileVirtualMachineControlModel, target: VirtualMachineSettingsState, activation: UUID) {
        self.model = model; self.target = target; self.activation = activation
        _draft = State(initialValue: .init(target))
    }
    var body: some View {
        Form {
            if model.error != nil { Section { MobileVirtualMachineControlNotice(model: model) } }
            if let resultID, let item = model.recovery.entry(resultID)?.items.first {
                Section {
                    Text(L10n.string(item.phase == .submitted ? "mobile.virtual-machines.settings.unverified" : failureKey(item.failure)))
                        .foregroundStyle(.secondary).accessibilityIdentifier("virtual-machine.settings.result")
                }
            }
            Section {
                LabeledContent(L10n.string("mobile.virtual-machines.settings.name")) {
                    TextField(L10n.string("mobile.virtual-machines.settings.name"), text: $draft.name)
                        .multilineTextAlignment(.trailing).focused($focus, equals: .name)
                        .accessibilityIdentifier("virtual-machine.settings.name")
                }
            }
            Section(L10n.string("mobile.virtual-machines.settings.description")) {
                TextField(L10n.string("mobile.virtual-machines.settings.description"), text: $draft.description, axis: .vertical)
                    .lineLimit(2...5).focused($focus, equals: .description).accessibilityIdentifier("virtual-machine.settings.description")
            }
            Section {
                LabeledContent(L10n.string("mobile.virtual-machines.settings.cpu")) {
                    TextField(L10n.string("virtual-machine.setting.unknown"), value: $draft.cpuCount, format: .number.locale(L10n.locale))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .focused($focus, equals: .cpu)
                        .accessibilityLabel(L10n.string("mobile.virtual-machines.settings.cpu"))
                        .accessibilityIdentifier("virtual-machine.settings.cpu")
                }
                LabeledContent(L10n.string("mobile.virtual-machines.settings.memory")) {
                    TextField(L10n.string("virtual-machine.setting.unknown"), value: $draft.memoryMiB, format: .number.locale(L10n.locale))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .focused($focus, equals: .memory)
                        .accessibilityLabel(L10n.string("mobile.virtual-machines.settings.memory"))
                        .accessibilityIdentifier("virtual-machine.settings.memory")
                }
            } footer: {
                if !target.canEditHardware { Text(L10n.string("mobile.virtual-machines.settings.shutdown-required")) }
            }
            .disabled(!target.canEditHardware)
            Section {
                Picker(L10n.string("mobile.virtual-machines.settings.priority"), selection: $draft.cpuWeight) {
                    if target.cpuWeight == nil { Text(L10n.string("virtual-machine.setting.unknown")).tag(Int?.none) }
                    if let weight = target.cpuWeight, ![8, 64, 256, 512, 1024].contains(weight) {
                        Text(L10n.string("virtual-machine.priority.current", weight.formatted(.number.locale(L10n.locale)))).tag(Optional(weight))
                    }
                    ForEach([8, 64, 256, 512, 1024], id: \.self) { weight in
                        Text(L10n.string(priorityKey(weight))).tag(Optional(weight))
                    }
                }
                .accessibilityIdentifier("virtual-machine.settings.priority")
                Picker(L10n.string("virtual-machine.startup.title"), selection: $draft.startupBehavior) {
                    if target.startupBehavior == nil { Text(L10n.string("virtual-machine.setting.unknown")).tag(VirtualMachineStartupBehavior?.none) }
                    ForEach(VirtualMachineStartupBehavior.allCases, id: \.self) { value in
                        Text(L10n.string(value.localizationKey)).tag(Optional(value))
                    }
                }
                .accessibilityIdentifier("virtual-machine.settings.startup")
            }
            if !draft.isValid { Section { Text(L10n.string("mobile.virtual-machines.settings.invalid")).foregroundStyle(.secondary) } }
        }
        .disabled(isSaving || activation != model.activation)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("virtual-machine.settings.form")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.string("mobile.nas.service.done")) { focus = nil }
                    .accessibilityIdentifier("virtual-machine.settings.keyboardDone")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.string("mobile.virtual-machines.settings.save")) {
                    guard draft.isValid, draft.hasChanges else { return }
                    focus = nil
                    isSaving = true
                    let id = model.saveSettings(target, configuration: draft.update, activation: activation)
                    resultID = id
                    Task {
                        if let id { await model.waitForOperation(id) }
                        isSaving = false
                        if let id, model.recovery.entry(id)?.items.first?.phase == .succeeded { dismiss() }
                    }
                }
                .disabled(isSaving || !draft.isValid || !draft.hasChanges || !model.canEdit(id: target.id))
                .accessibilityIdentifier("virtual-machine.settings.save")
            }
        }
    }
    private func priorityKey(_ weight: Int) -> String {
        switch weight {
        case 8: "virtual-machine.priority.low"
        case 64: "virtual-machine.priority.below-normal"
        case 512: "virtual-machine.priority.above-normal"
        case 1024: "virtual-machine.priority.high"
        default: "mobile.virtual-machines.settings.priority.normal"
        }
    }
    private func failureKey(_ failure: MobileVirtualMachineControlStore.Failure?) -> String {
        switch failure {
        case .denied: "mobile.virtual-machines.control.error.denied"
        case .unavailable: "mobile.virtual-machines.settings.error.read"
        case .changed: "virtual-machine.settings.changed"
        default: "mobile.virtual-machines.settings.failed"
        }
    }
}
