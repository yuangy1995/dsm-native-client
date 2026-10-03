import DsmCore
import DsmLocalization
import SwiftUI

struct PackageInstallationSheet: View {
    @Bindable var model: NasSettingsModel
    let onClose: () -> Void
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("package.center.installation-title")).font(.title2.bold())
            if model.isPreparingPackageInstallation {
                ProgressView(L10n.string("package.center.preparing"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Spacer()
                    if model.canCancelPackagePreparation {
                        Button(L10n.string("ui.2cd0f3be8738a86c")) {
                            model.cancelPackageInstallationPreparation()
                            onClose()
                        }.keyboardShortcut(.cancelAction)
                    } else {
                        Button(L10n.string("package.center.continue-background"), action: onClose)
                            .keyboardShortcut(.cancelAction)
                    }
                }
            } else if let plan = model.packageInstallPlan {
                PackageInstallPlanView(plan: plan, isBusy: model.isAdvancingPackageInstallation,
                    onCancel: { model.discardPackageInstallPlan(); onClose() }, onConfirm: { volumes, start in
                        Task {
                            do { try await model.startPackageInstallation(volumes: volumes, startAfterInstall: start) }
                            catch { self.error = safeMessage(error) }
                        }
                    })
            } else if let progress = model.packageInstallProgress {
                if let configuration = progress.configuration, progress.phase == .needsOptions {
                    PackageInstallOptionsView(configuration: configuration, isBusy: model.isAdvancingPackageInstallation,
                        onCancel: { cancel() }, onConfirm: { volume, start, agreed, values in
                            Task {
                                do { try await model.configurePackageInstallation(volumeID: volume, startAfterInstall: start, licenseAccepted: agreed, values: values) }
                                catch { self.error = safeMessage(error) }
                            }
                        })
                    .id(progress.packageName + configuration.version)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(progress.packageName).font(.headline)
                        Text(progress.phase.packageCenterTitle)
                        if progress.phase.isActive { ProgressView(value: progress.fraction) }
                        Text(L10n.string("package.center.queue-progress", String(progress.completedCount), String(progress.totalCount)))
                            .font(.callout).foregroundStyle(.secondary)
                        if let key = progress.messageKey { Text(L10n.string(key)).textSelection(.enabled) }
                        if let message = model.packageInstallationError { Text(message).foregroundStyle(.secondary) }
                        Spacer()
                        HStack {
                            if progress.canCancel {
                                Button(L10n.string(progress.phase == .downloading ? "package.center.cancel-download" : "ui.2cd0f3be8738a86c"), role: .destructive) { cancel() }
                                    .disabled(model.isAdvancingPackageInstallation)
                            }
                            if progress.phase == .unverified {
                                Button(L10n.string("package.center.check-status")) { Task { await model.resumePackageInstallationMonitoring() } }
                                    .disabled(model.isAdvancingPackageInstallation)
                            }
                            Spacer()
                            Button(L10n.string(progress.phase.isActive ? "package.center.continue-background" : "package.center.close"), action: onClose)
                                .keyboardShortcut(.cancelAction)
                        }
                    }
                }
            } else {
                ContentUnavailableView(L10n.string("package.center.preparing"), systemImage: "shippingbox")
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .padding(24).frame(width: 620, height: 600)
        .interactiveDismissDisabled(model.isPreparingPackageInstallation || model.isAdvancingPackageInstallation)
        .onDisappear { model.cancelPackageInstallationPreparation() }
    }
    private func cancel() {
        Task {
            do { try await model.cancelPackageInstallation(); if model.packageInstallProgress?.phase == .cancelled { onClose() } }
            catch { self.error = safeMessage(error) }
        }
    }
    private func safeMessage(_ error: Error) -> String { (error as? AppError)?.safeUserMessage ?? L10n.string("package.center.failed") }
}

struct PackageInstallPlanView: View {
    let plan: NasPackageInstallPlan
    let isBusy: Bool
    let onCancel: () -> Void
    let onConfirm: ([String: String], Bool) -> Void
    @State private var volumes: [String: String] = [:]
    @State private var startAfterInstall = true
    private var valid: Bool {
        plan.items.allSatisfy { item in item.volumes.isEmpty || !(volumes[item.id] ?? item.defaultVolumeID).isEmpty }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(plan.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.package.name).font(.headline)
                            LabeledContent(L10n.string(item.package.installedVersion == nil ? "package.center.install" : "package.center.update"), value: item.package.version)
                            if item.package.isBeta { Text(L10n.string("package.center.beta-warning")).foregroundStyle(.orange) }
                            if !item.volumes.isEmpty {
                                Picker(L10n.string("package.center.volume"), selection: Binding(get: { volumes[item.id] ?? item.defaultVolumeID }, set: { volumes[item.id] = $0 })) {
                                    if item.defaultVolumeID.isEmpty { Text(L10n.string("package.center.choose-volume")).tag("") }
                                    ForEach(item.volumes) { Text($0.name).tag($0.id) }
                                }
                            }
                        }
                        Divider()
                    }
                    if !plan.affectedPackages.isEmpty {
                        Text(L10n.string("package.center.affected")).font(.headline)
                        ForEach(plan.affectedPackages, id: \.self) { Text($0) }
                    }
                    Toggle(L10n.string("package.center.start-after"), isOn: $startAfterInstall)
                    Text(L10n.string("package.center.install-warning")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L10n.string("package.center.confirm-install")) { onConfirm(volumes, startAfterInstall) }
                    .buttonStyle(.borderedProminent).disabled(isBusy || !valid)
            }
        }.disabled(isBusy)
    }
}

struct PackageInstallOptionsView: View {
    let configuration: NasPackageInstallConfiguration
    let isBusy: Bool
    let onCancel: () -> Void
    let onConfirm: (String, Bool, Bool, [String: NasPackageOptionValue]) -> Void
    @State private var volume: String
    @State private var startAfterInstall: Bool
    @State private var licenseAccepted = false
    @State private var values: [String: NasPackageOptionValue]
    init(configuration: NasPackageInstallConfiguration, isBusy: Bool, onCancel: @escaping () -> Void,
         onConfirm: @escaping (String, Bool, Bool, [String: NasPackageOptionValue]) -> Void) {
        self.configuration = configuration; self.isBusy = isBusy; self.onCancel = onCancel; self.onConfirm = onConfirm
        _volume = State(initialValue: configuration.defaultVolumeID)
        _startAfterInstall = State(initialValue: configuration.canStart)
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: configuration.fields.filter { $0.kind != .description }.map { ($0.id, $0.defaultValue) }))
    }
    private var valid: Bool {
        configuration.accepts(values) && (configuration.license == nil || licenseAccepted)
            && (configuration.volumes.isEmpty || !volume.isEmpty)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(configuration.packageName).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent(L10n.string("package.center.available-version"), value: configuration.version)
                    if let license = configuration.license {
                        Text(L10n.string("package.center.license")).font(.headline)
                        Text(packagePlainText(license)).font(.callout).textSelection(.enabled)
                        Toggle(L10n.string("package.center.accept-license"), isOn: $licenseAccepted)
                    }
                    ForEach(configuration.fields) { field in option(field) }
                    if !configuration.volumes.isEmpty {
                        Picker(L10n.string("package.center.volume"), selection: $volume) {
                            if configuration.defaultVolumeID.isEmpty { Text(L10n.string("package.center.choose-volume")).tag("") }
                            ForEach(configuration.volumes) { Text($0.name).tag($0.id) }
                        }
                    }
                    if configuration.canStart { Toggle(L10n.string("package.center.start-after"), isOn: $startAfterInstall) }
                    if configuration.requiresRestart { Text(L10n.string("package.center.restart-required")).foregroundStyle(.orange) }
                    Text(L10n.string("package.center.install-warning")).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), action: onCancel).keyboardShortcut(.cancelAction)
                Button(L10n.string("package.center.confirm-install")) { onConfirm(volume, startAfterInstall, licenseAccepted, values) }
                    .buttonStyle(.borderedProminent).disabled(!valid)
            }
        }.disabled(isBusy)
    }
    @ViewBuilder private func option(_ field: NasPackageInstallField) -> some View {
        let label = packagePlainText(field.label)
        switch field.kind {
        case .description: Text(label).font(.callout).textSelection(.enabled)
        case .text: TextField(label, text: textBinding(field)).textFieldStyle(.roundedBorder)
        case .password: SecureField(label, text: textBinding(field)).textFieldStyle(.roundedBorder)
        case .toggle: Toggle(label, isOn: flagBinding(field))
        case .radio:
            Button {
                for item in configuration.fields where item.group == field.group { values[item.id] = .flag(item.id == field.id) }
            } label: {
                Label(label, systemImage: values[field.id] == .flag(true) ? "largecircle.fill.circle" : "circle")
            }.buttonStyle(.plain).accessibilityAddTraits(values[field.id] == .flag(true) ? [.isSelected] : [])
        case .choice:
            Picker(label, selection: textBinding(field)) { ForEach(field.choices) { Text(packagePlainText($0.name)).tag($0.id) } }
        }
    }
    private func textBinding(_ field: NasPackageInstallField) -> Binding<String> {
        Binding(get: { if case .text(let text) = values[field.id] ?? field.defaultValue { text } else { "" } }, set: { values[field.id] = .text($0) })
    }
    private func flagBinding(_ field: NasPackageInstallField) -> Binding<Bool> {
        Binding(get: { values[field.id] == .flag(true) }, set: { values[field.id] = .flag($0) })
    }
}

extension NasPackageInstallProgress.Phase {
    var packageCenterTitle: String {
        switch self {
        case .downloading: L10n.string("package.center.phase.downloading")
        case .installing: L10n.string("package.center.phase.installing")
        case .needsOptions: L10n.string("package.center.phase.needsOptions")
        case .completed: L10n.string("package.center.phase.completed")
        case .failed: L10n.string("package.center.phase.failed")
        case .unverified: L10n.string("package.center.phase.unverified")
        case .cancelled: L10n.string("package.center.phase.cancelled")
        }
    }
}
