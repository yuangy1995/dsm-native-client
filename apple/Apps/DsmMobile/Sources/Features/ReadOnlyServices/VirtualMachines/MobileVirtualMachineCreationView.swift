import DsmCore
import DsmLocalization
import SwiftUI

struct MobileVirtualMachineCreationRequest: Identifiable {
    let id = UUID()
    let activation: UUID
}

struct MobileVirtualMachineCreationDraft {
    var name = ""
    var description = ""
    var operatingSystem = VirtualMachineOperatingSystem.linux
    var cpuCount: Int? = 1
    var memoryMiB: Int? = 512
    var diskGiB: Int? = 10
    var storageID: String
    var networkID = ""
    var imageID = ""
    var firmware = VirtualMachineFirmware.legacy
    var startupBehavior = VirtualMachineStartupBehavior.off
    var powerOnAfterCreation = false
    init(resources: VirtualMachineCreationResources) { storageID = resources.storages.first(where: \.isAvailable)?.id ?? "" }
    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasValidIdentity: Bool {
        !normalizedName.isEmpty && normalizedName.count <= 255 && description.count <= 1_024
            && !normalizedName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    var hasValidHardware: Bool {
        cpuCount.map { (1...64).contains($0) } == true && memoryMiB.map { (128...1_048_576).contains($0) } == true
            && diskGiB.map { (10...1_048_576).contains($0) } == true && !storageID.isEmpty
    }
    var configuration: VirtualMachineCreation? {
        guard hasValidIdentity, hasValidHardware, let cpuCount, let memoryMiB, let diskGiB else { return nil }
        return .init(name: normalizedName, operatingSystem: operatingSystem, storageID: storageID, networkID: networkID,
            bootImageID: imageID.isEmpty ? nil : imageID, cpuCount: cpuCount, memoryMiB: memoryMiB, diskGiB: diskGiB,
            description: description, firmware: firmware, powerOnAfterCreation: powerOnAfterCreation, startupBehavior: startupBehavior)
    }
}

struct MobileVirtualMachineCreationView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let request: MobileVirtualMachineCreationRequest
    @Environment(\.dismiss) private var dismiss
    @State private var resources: VirtualMachineCreationResources?
    @State private var failure: MobileVirtualMachineControlModel.Failure?
    @State private var isLoading = true
    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView(L10n.string("mobile.virtual-machines.creation.loading"))
                        .fillsAvailableContentArea().accessibilityIdentifier("virtual-machine.creation.loading")
                } else if let resources, resources.storages.contains(where: \.isAvailable) {
                    MobileVirtualMachineCreationForm(model: model, resources: resources, activation: request.activation)
                } else {
                    ContentUnavailableView {
                        Label(L10n.string("mobile.virtual-machines.creation.unavailable"), systemImage: "externaldrive.badge.exclamationmark")
                            .accessibilityIdentifier("virtual-machine.creation.error")
                    } description: {
                        Text(L10n.string(resources == nil ? failureKey : "mobile.virtual-machines.creation.empty"))
                    } actions: {
                        if failure != .trust && failure != .denied {
                            Button(L10n.string("mobile.virtual-machines.action.retry")) { Task { await load() } }
                                .accessibilityIdentifier("virtual-machine.creation.retry")
                        }
                    }
                    .fillsAvailableContentArea()
                }
            }
            .navigationTitle(L10n.string("mobile.virtual-machines.creation.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.virtual-machines.control.cancel")) { dismiss() }
                        .disabled(model.isOperating).accessibilityIdentifier("virtual-machine.creation.cancel")
                }
            }
        }
        .interactiveDismissDisabled(model.isOperating)
        .task { await load() }
        .onChange(of: model.activation) { _, value in if value != request.activation { dismiss() } }
    }
    private var failureKey: String {
        switch failure {
        case .denied: "mobile.virtual-machines.control.error.denied"
        case .trust: "mobile.virtual-machines.control.error.trust"
        case .storage: "mobile.virtual-machines.control.error.storage"
        default: "mobile.virtual-machines.creation.read-error"
        }
    }
    private func load() async {
        isLoading = true; failure = nil
        do {
            let value = try await model.loadCreationResources(activation: request.activation)
            try Task.checkCancellation()
            guard request.activation == model.activation else { return }
            resources = value; isLoading = false
        } catch {
            guard request.activation == model.activation, !Task.isCancelled else { return }
            failure = MobileVirtualMachineControlModel.failure(error); isLoading = false
        }
    }
}

private struct MobileVirtualMachineCreationForm: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let resources: VirtualMachineCreationResources
    let activation: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MobileVirtualMachineCreationDraft
    @State private var step = 0
    @State private var resultID: UUID?
    @State private var isSaving = false
    @FocusState private var focused: String?
    init(model: MobileVirtualMachineControlModel, resources: VirtualMachineCreationResources, activation: UUID) {
        self.model = model; self.resources = resources; self.activation = activation
        _draft = State(initialValue: .init(resources: resources))
    }
    private var stepKeys: [String] { ["mobile.virtual-machines.creation.basics", "mobile.virtual-machines.creation.hardware",
                                    "mobile.virtual-machines.creation.options", "mobile.virtual-machines.creation.summary"] }
    private var protectedResult: Bool { resultID.flatMap { model.creations.entry($0)?.isProtected } == true }
    private var selectableImages: [VirtualMachineCreationImage] {
        let host = resources.storages.first { $0.id == draft.storageID }?.hostID
        return resources.images.filter { $0.storageID == draft.storageID && $0.hostID == host }
    }
    var body: some View {
        Form {
            Section {
                Text(L10n.string("mobile.virtual-machines.creation.step", step + 1, stepKeys.count, L10n.string(stepKeys[step])))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if model.error != nil { Section { MobileVirtualMachineControlNotice(model: model) } }
            if let resultID, let entry = model.creations.entry(resultID) {
                Section {
                    MobileVirtualMachineCreationStatus(entry: entry, isExecuting: model.creations.isExecuting(entry.id))
                    NavigationLink(L10n.string("mobile.virtual-machines.control.records")) { MobileVirtualMachineControlRecordsView(model: model) }
                        .accessibilityIdentifier("virtual-machine.creation.records")
                }
            }
            Group {
                switch step {
                case 0: basics
                case 1: hardware
                case 2: options
                default: summary
                }
            }
            .disabled(isSaving || protectedResult)
        }
        .id(step)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("virtual-machine.creation.form")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L10n.string("mobile.nas.service.done")) { focused = nil }
                    .accessibilityIdentifier("virtual-machine.creation.keyboardDone")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                if step > 0 {
                    Button(L10n.string("mobile.virtual-machines.creation.back")) { focused = nil; step -= 1 }
                        .disabled(isSaving || protectedResult).accessibilityIdentifier("virtual-machine.creation.back")
                }
                Spacer()
                if step < 3 {
                    Button(L10n.string("mobile.virtual-machines.creation.next")) { focused = nil; step += 1 }
                        .disabled(!canContinue || isSaving || protectedResult).accessibilityIdentifier("virtual-machine.creation.next")
                } else {
                    Button(L10n.string("mobile.virtual-machines.creation.submit")) { submit() }
                        .disabled(isSaving || draft.configuration == nil || !model.canCreate(name: draft.normalizedName))
                        .accessibilityIdentifier("virtual-machine.creation.submit")
                }
            }
        }
        .onChange(of: draft.storageID) { _, _ in draft.imageID = "" }
    }
    private var canContinue: Bool {
        switch step {
        case 0: draft.hasValidIdentity && model.canCreate(name: draft.normalizedName)
        case 1: draft.hasValidHardware
        default: true
        }
    }
    private var basics: some View {
        Group {
            Section {
                HStack {
                    Text(L10n.string("mobile.virtual-machines.settings.name")).accessibilityHidden(true).layoutPriority(1)
                    TextField("", text: $draft.name)
                        .multilineTextAlignment(.trailing).focused($focused, equals: "name")
                        .accessibilityLabel(L10n.string("mobile.virtual-machines.settings.name"))
                        .accessibilityIdentifier("virtual-machine.creation.name")
                }
                Picker(L10n.string("mobile.virtual-machines.creation.system"), selection: $draft.operatingSystem) {
                    ForEach(VirtualMachineOperatingSystem.allCases) { value in Text(L10n.string(systemKey(value))).tag(value) }
                }.accessibilityIdentifier("virtual-machine.creation.system")
            }
            Section(L10n.string("mobile.virtual-machines.settings.description")) {
                TextField("", text: $draft.description, axis: .vertical)
                    .lineLimit(2...5).focused($focused, equals: "description")
                    .accessibilityLabel(L10n.string("mobile.virtual-machines.settings.description"))
                    .accessibilityIdentifier("virtual-machine.creation.description")
            }
            if draft.hasValidIdentity && !model.canCreate(name: draft.normalizedName) {
                Section { Text(L10n.string("mobile.virtual-machines.creation.name-unavailable")).foregroundStyle(.secondary) }
            }
        }
    }
    private var hardware: some View {
        Group {
            Section {
                numberField("mobile.virtual-machines.settings.cpu", value: $draft.cpuCount, id: "cpu")
                numberField("mobile.virtual-machines.settings.memory", value: $draft.memoryMiB, id: "memory")
            }
            Section {
                Picker(L10n.string("mobile.virtual-machines.creation.storage"), selection: $draft.storageID) {
                    ForEach(resources.storages.filter(\.isAvailable)) { storage in Text(storage.name).tag(storage.id) }
                }.accessibilityIdentifier("virtual-machine.creation.storage")
                numberField("mobile.virtual-machines.creation.disk", value: $draft.diskGiB, id: "disk")
            }
            if !draft.hasValidHardware {
                Section { Text(L10n.string("mobile.virtual-machines.creation.hardware-invalid")).foregroundStyle(.secondary) }
            }
        }
    }
    private func numberField(_ key: String, value: Binding<Int?>, id: String) -> some View {
        // 可见标签保留，朗读由输入框提供一次，避免组合标签重复。
        HStack {
            Text(L10n.string(key)).accessibilityHidden(true).layoutPriority(1)
            TextField("", value: value, format: .number.locale(L10n.locale))
                .keyboardType(.numberPad).multilineTextAlignment(.trailing).focused($focused, equals: id)
                .frame(minWidth: 72)
                .accessibilityLabel(L10n.string(key)).accessibilityIdentifier("virtual-machine.creation.\(id)")
        }
    }
    private var options: some View {
        Group {
            Section {
                Picker(L10n.string("mobile.virtual-machines.creation.network"), selection: $draft.networkID) {
                    Text(L10n.string("mobile.virtual-machines.creation.disconnected")).tag("")
                    ForEach(resources.networks) { network in Text(network.name).tag(network.id) }
                }.accessibilityIdentifier("virtual-machine.creation.network")
                Picker(L10n.string("mobile.virtual-machines.creation.image"), selection: $draft.imageID) {
                    Text(L10n.string("mobile.virtual-machines.creation.no-image")).tag("")
                    ForEach(selectableImages, id: \.id) { image in Text(image.name).tag(image.id) }
                }.accessibilityIdentifier("virtual-machine.creation.image")
                if !resources.networksAvailable || !resources.imagesAvailable {
                    Text(L10n.string("mobile.virtual-machines.creation.optional-unavailable")).font(.subheadline).foregroundStyle(.secondary)
                }
                Picker(L10n.string("mobile.virtual-machines.creation.firmware"), selection: $draft.firmware) {
                    Text(L10n.string("firmware.legacy_bios")).tag(VirtualMachineFirmware.legacy)
                    Text(L10n.string("firmware.uefi")).tag(VirtualMachineFirmware.uefi)
                }.accessibilityIdentifier("virtual-machine.creation.firmware")
            }
            Section {
                Picker(L10n.string("virtual-machine.startup.title"), selection: $draft.startupBehavior) {
                    ForEach(VirtualMachineStartupBehavior.allCases, id: \.self) { value in Text(L10n.string(value.localizationKey)).tag(value) }
                }.accessibilityIdentifier("virtual-machine.creation.startup")
                Toggle(L10n.string("mobile.virtual-machines.creation.power-on"), isOn: $draft.powerOnAfterCreation)
                    .accessibilityIdentifier("virtual-machine.creation.power-on")
            }
        }
    }
    private var summary: some View {
        Group {
            Section {
                Text(L10n.string(draft.powerOnAfterCreation ? "mobile.virtual-machines.creation.risk-power" : "mobile.virtual-machines.creation.risk-storage"))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("virtual-machine.creation.risk")
            }
            Section {
                LabeledContent(L10n.string("mobile.virtual-machines.settings.name"), value: draft.normalizedName)
                LabeledContent(L10n.string("mobile.virtual-machines.creation.system"), value: L10n.string(systemKey(draft.operatingSystem)))
                if !draft.description.isEmpty { LabeledContent(L10n.string("mobile.virtual-machines.settings.description"), value: draft.description) }
                LabeledContent(L10n.string("mobile.virtual-machines.settings.cpu"), value: number(draft.cpuCount))
                LabeledContent(L10n.string("mobile.virtual-machines.settings.memory"), value: number(draft.memoryMiB))
                LabeledContent(L10n.string("mobile.virtual-machines.creation.disk"), value: number(draft.diskGiB))
                LabeledContent(L10n.string("mobile.virtual-machines.creation.storage"), value: resources.storages.first { $0.id == draft.storageID }?.name ?? "")
                LabeledContent(L10n.string("mobile.virtual-machines.creation.network"), value: resources.networks.first { $0.id == draft.networkID }?.name ?? L10n.string("mobile.virtual-machines.creation.disconnected"))
                LabeledContent(L10n.string("mobile.virtual-machines.creation.image"), value: selectableImages.first { $0.id == draft.imageID }?.name ?? L10n.string("mobile.virtual-machines.creation.no-image"))
                LabeledContent(L10n.string("mobile.virtual-machines.creation.firmware"), value: L10n.string(draft.firmware == .uefi ? "firmware.uefi" : "firmware.legacy_bios"))
                LabeledContent(L10n.string("virtual-machine.startup.title"), value: L10n.string(draft.startupBehavior.localizationKey))
            }
        }
    }
    private func number(_ value: Int?) -> String { value?.formatted(.number.locale(L10n.locale)) ?? "" }
    private func systemKey(_ value: VirtualMachineOperatingSystem) -> String {
        switch value { case .linux: "operating_system.linux"; case .windows: "operating_system.windows"; case .other: "mobile.virtual-machines.creation.other" }
    }
    private func submit() {
        guard let configuration = draft.configuration else { return }
        focused = nil; isSaving = true
        let id = model.create(configuration, resources: resources, activation: activation); resultID = id
        Task {
            if let id { await model.waitForOperation(id) }
            isSaving = false
            if let id, model.creations.entry(id)?.phase == .succeeded { dismiss() }
        }
    }
}

struct MobileVirtualMachineCreationStatus: View {
    let entry: MobileVirtualMachineCreationStore.Entry
    let isExecuting: Bool
    var body: some View {
        Text(L10n.string(key)).font(.subheadline).foregroundStyle(.secondary)
            .accessibilityIdentifier("virtual-machine.creation.result.\(entry.phase.rawValue)")
    }
    private var key: String {
        if isExecuting { return "mobile.virtual-machines.creation.processing" }
        switch entry.phase {
        case .prepared: return "mobile.virtual-machines.creation.processing"
        case .submitted: return entry.tracking?.taskIdentityDigest == nil ? "mobile.virtual-machines.creation.unknown" : "mobile.virtual-machines.creation.accepted"
        case .succeeded: return "mobile.virtual-machines.creation.completed"
        case .failed: return "virtual-machine.creation.failed"
        case .skipped: return "mobile.virtual-machines.control.skipped"
        }
    }
}
