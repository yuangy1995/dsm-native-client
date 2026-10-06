import DsmCore
import DsmLocalization
import SwiftUI
import UniformTypeIdentifiers

struct MobilePackageCatalogScreen: View {
    @Bindable var model: MobilePackageInstallationModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var category = ""
    @State private var filter = Filter.all
    @State private var showsInstallation = false
    @State private var importsFile = false
    @State private var fileSelectionActivation: UUID?
    private enum Filter: String, CaseIterable {
        case all, updates, beta, community
        var title: String {
            let key = switch self { case .all: "package.center.section.all"; case .updates: "package.center.section.updates"; case .beta: "package.center.section.beta"; case .community: "package.center.section.community" }
            return L10n.string(key)
        }
    }
    private var filtered: [NasPackageCatalogEntry] {
        (model.catalog.value?.entries ?? []).filter { value in
            let inFilter = switch filter { case .all: true; case .updates: value.isUpdateAvailable; case .beta: value.isBeta; case .community: !value.isOfficial }
            return inFilter && (category.isEmpty || value.categories.contains(category))
                && MobileNasReadFormatting.matches(query, values: [value.name, value.packageID, value.publisher, value.description])
        }
    }
    var body: some View {
        List {
            Section {
                TextField(L10n.string("package.center.search"), text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("mobile.package.catalog.search")
                Picker(L10n.string("package.center.display"), selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.title).tag($0) } }
                    .accessibilityIdentifier("mobile.package.catalog.filter")
                if let categories = model.catalog.value?.categories, !categories.isEmpty {
                    Picker(L10n.string("package.center.category"), selection: $category) {
                        Text(L10n.string("package.center.all-categories")).tag("")
                        ForEach(categories) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("mobile.package.catalog.category")
                }
            }
            switch model.catalog.phase {
            case .idle, .loading:
                Section { ProgressView(L10n.string("package.center.loading")).accessibilityIdentifier("mobile.package.catalog.loading") }
            case .error, .unavailable:
                Section {
                    ContentUnavailableView(L10n.string("package.center.load-failed"), systemImage: "shippingbox", description: Text(model.message ?? model.error?.mobilePackageMessage ?? L10n.string("package.center.catalog-failed")))
                    Button(L10n.string("package.center.refresh")) { Task { await model.refresh() } }.accessibilityIdentifier("mobile.package.catalog.retry")
                }
            case .content, .empty:
                if model.catalog.value?.communityAvailable == false {
                    Section { Text(L10n.string("package.center.community-unavailable")).accessibilityIdentifier("mobile.package.catalog.communityError") }
                }
                if filtered.isEmpty {
                    Section {
                        ContentUnavailableView(L10n.string(query.isEmpty && category.isEmpty ? "package.center.empty.all" : "package.center.no-matches"), systemImage: "shippingbox",
                            description: Text(L10n.string("package.center.search-help"))).accessibilityIdentifier("mobile.package.catalog.empty")
                    }
                }
                ForEach(filtered) { value in
                    NavigationLink { MobilePackageCatalogDetail(model: model, value: value) { token in prepare([value], activation: token) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(value.name).font(.headline)
                            Text(value.version).foregroundStyle(.secondary)
                            if value.isUpdateAvailable { Text(L10n.string("package.center.update")).font(.caption) }
                            if value.isBeta { Text(L10n.string("package.center.section.beta")).font(.caption) }
                        }
                    }.accessibilityIdentifier("mobile.package.catalog.row.\(value.id)")
                }
                if filter == .updates, !filtered.isEmpty {
                    Section { Button(L10n.string("package.center.update-all")) { prepare(filtered) }.disabled(!model.canStart).accessibilityIdentifier("mobile.package.catalog.updateAll") }
                }
            }
            MobilePackageInstallationActivity(model: model)
        }
        .listStyle(.insetGrouped).accessibilityIdentifier("mobile.package.catalog.list")
        .navigationTitle(L10n.string("package.center.section.all")).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { fileSelectionActivation = model.activation; importsFile = true } label: { Label(L10n.string("mobile.package.selectUpload"), systemImage: "square.and.arrow.up") }
                    .disabled(!model.canUpload).accessibilityIdentifier("mobile.package.install.upload")
                if model.isBusy || model.plan != nil || model.progress != nil || !model.entries.isEmpty {
                    Button { showsInstallation = true } label: { Label(L10n.string("mobile.package.install.progress"), systemImage: "clock.arrow.circlepath") }
                        .accessibilityIdentifier("mobile.package.install.showProgress")
                }
            }
        }
        .task(id: model.activation) { await model.loadIfNeeded() }.refreshable { await model.refresh() }
        .onDisappear { model.cancelRead() }
        .onChange(of: scenePhase) { _, value in model.setForeground(value == .active) }
        .onChange(of: model.activation) { _, _ in showsInstallation = false; importsFile = false; fileSelectionActivation = nil; query = ""; category = "" }
        .sheet(isPresented: $showsInstallation) { MobilePackageInstallationSheet(model: model) { showsInstallation = false } }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [UTType(filenameExtension: "spk") ?? .data]) { result in
            if let token = fileSelectionActivation, model.selectFile(result, activation: token) { showsInstallation = true }
            fileSelectionActivation = nil
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
    private func prepare(_ entries: [NasPackageCatalogEntry], activation: UUID? = nil) {
        let token = activation ?? model.activation
        guard token == model.activation else { return }
        showsInstallation = true
        Task { await model.prepare(entries, activation: token) }
    }
}

private struct MobilePackageCatalogDetail: View {
    @Bindable var model: MobilePackageInstallationModel
    let value: NasPackageCatalogEntry
    let install: (UUID) -> Void
    @State private var sourceActivation: UUID
    init(model: MobilePackageInstallationModel, value: NasPackageCatalogEntry, install: @escaping (UUID) -> Void) {
        self.model = model; self.value = value; self.install = install
        _sourceActivation = State(initialValue: model.activation)
    }
    var body: some View {
        List {
            Section {
                Text(value.name).font(.title2.bold())
                LabeledContent(L10n.string("package.center.available-version"), value: value.version)
                if let installed = value.installedVersion { LabeledContent(L10n.string("package.center.installed-version"), value: installed) }
                LabeledContent(L10n.string("package.center.source"), value: value.isOfficial ? L10n.string("package.center.official") : value.publisher)
                if let size = value.sizeBytes { LabeledContent(L10n.string("package.center.size"), value: MobileNasReadFormatting.bytes(size)) }
                if value.isBeta { Text(L10n.string("package.center.beta-warning")).foregroundStyle(.orange) }
            }
            if !value.description.isEmpty { Section { Text(mobilePackagePlainText(value.description)).textSelection(.enabled) } }
            if !value.releaseNotes.isEmpty { Section(L10n.string("package.center.release-notes")) { Text(mobilePackagePlainText(value.releaseNotes)).textSelection(.enabled) } }
            if value.installedVersion == nil || value.isUpdateAvailable {
                Section { Button(L10n.string(value.installedVersion == nil ? "package.center.install" : "package.center.update")) { install(sourceActivation) }
                    .disabled(sourceActivation != model.activation || !model.canStart || model.catalog.value?.entries.contains(value) != true).accessibilityIdentifier("mobile.package.install.prepare") }
            }
            if let error = model.error { Section { Text(model.message ?? error.mobilePackageMessage) } }
        }
        .listStyle(.insetGrouped).navigationTitle(value.name).navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("mobile.package.catalog.detail").fillsAvailableContentArea(alignment: .topLeading)
    }
}

struct MobilePackageInstallationSheet: View {
    @Bindable var model: MobilePackageInstallationModel
    let close: () -> Void
    @Environment(\.locale) private var locale
    @State private var sourceActivation: UUID
    init(model: MobilePackageInstallationModel, close: @escaping () -> Void) {
        self.model = model; self.close = close; _sourceActivation = State(initialValue: model.activation)
    }
    var body: some View {
        NavigationStack {
            Group {
                if model.isPreparing {
                    ProgressView(L10n.string("package.center.preparing")).accessibilityIdentifier("mobile.package.install.preparing")
                        .fillsAvailableContentArea()
                } else if let plan = model.plan {
                    MobilePackageInstallPlanForm(model: model, plan: plan).id(plan.id)
                } else if let progress = model.progress, let configuration = progress.configuration, progress.phase == .needsOptions {
                    MobilePackageInstallOptionsForm(model: model, configuration: configuration).id(progress.packageName + configuration.version)
                } else {
                    List {
                        if let progress = model.progress {
                            Section {
                                Text(progress.packageName).font(.headline)
                                Text(progress.phase.mobileInstallTitle).accessibilityIdentifier("mobile.package.install.phase.\(progress.phase.rawValue)")
                                if progress.phase.isActive { ProgressView(value: progress.fraction) }
                                Text(L10n.string("package.center.queue-progress", progress.completedCount.formatted(.number.locale(locale)), progress.totalCount.formatted(.number.locale(locale))))
                                if let key = progress.messageKey {
                                    Text(L10n.string(key)).textSelection(.enabled)
                                }
                            }
                            if progress.phase == .unverified {
                                Section { Button(L10n.string("package.center.check-status")) { Task { await model.resume() } }
                                    .disabled(model.isBusy).accessibilityIdentifier("mobile.package.install.refresh") }
                            }
                            if progress.canCancel {
                                Section { Button(L10n.string("package.center.cancel-download"), role: .destructive) { model.cancel(activation: sourceActivation) }
                                    .disabled(!model.canCancel || sourceActivation != model.activation).accessibilityIdentifier("mobile.package.install.cancel") }
                            }
                        } else if model.isBusy { Section { ProgressView(L10n.string("package.center.preparing")) } }
                        MobilePackageInstallationError(model: model)
                        MobilePackageInstallationActivity(model: model, excluding: model.progress == nil ? nil : model.currentEntryID)
                    }.listStyle(.insetGrouped).accessibilityIdentifier("mobile.package.install.progress")
                }
            }
            .navigationTitle(L10n.string("package.center.installation-title")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string(model.isPreparing || model.plan != nil ? "ui.2cd0f3be8738a86c" : "package.center.close")) { if sourceActivation == model.activation { model.discardPlan() }; close() }
                    .accessibilityIdentifier("mobile.package.install.close")
            } }
        }
        .onDisappear { if sourceActivation == model.activation { model.discardPlan() } }
        .onChange(of: model.activation) { _, _ in close() }
    }
}

private struct MobilePackageInstallPlanForm: View {
    @Bindable var model: MobilePackageInstallationModel
    let plan: NasPackageInstallPlan
    @State private var volumes: [String: String] = [:]
    @State private var start = true
    @State private var sourceActivation: UUID
    init(model: MobilePackageInstallationModel, plan: NasPackageInstallPlan) {
        self.model = model; self.plan = plan; _sourceActivation = State(initialValue: model.activation)
    }
    private var valid: Bool {
        plan.items.allSatisfy { item in
            let selected = volumes[item.id] ?? item.defaultVolumeID
            return item.volumes.isEmpty || item.volumes.contains { $0.id == selected }
        }
    }
    var body: some View {
        Form {
            ForEach(plan.items) { item in
                Section(item.package.name) {
                    LabeledContent(L10n.string(item.package.installedVersion == nil ? "package.center.install" : "package.center.update"), value: item.package.version)
                    if item.package.isBeta { Text(L10n.string("package.center.beta-warning")).foregroundStyle(.orange) }
                    if item.volumes.count > 1 {
                        Picker(L10n.string("package.center.volume"), selection: Binding(get: { volumes[item.id] ?? item.defaultVolumeID }, set: { volumes[item.id] = $0 })) {
                            if item.defaultVolumeID.isEmpty { Text(L10n.string("package.center.choose-volume")).tag("") }
                            ForEach(item.volumes) { Text($0.name).tag($0.id) }
                        }.accessibilityIdentifier("mobile.package.install.volume.\(item.package.packageID)")
                    } else if let volume = item.volumes.first { LabeledContent(L10n.string("package.center.volume"), value: volume.name) }
                }
            }
            if !plan.affectedPackages.isEmpty { Section(L10n.string("package.center.affected")) { ForEach(plan.affectedPackages, id: \.self) { Text($0) } } }
            Section {
                Toggle(L10n.string("package.center.start-after"), isOn: $start)
                Text(L10n.string("package.center.install-warning"))
                Button(L10n.string("package.center.confirm-install")) { model.start(planID: plan.id, volumes: volumes, startAfterInstall: start, activation: sourceActivation) }
                    .disabled(!valid || !model.canStart || sourceActivation != model.activation).accessibilityIdentifier("mobile.package.install.confirm")
            }
            MobilePackageInstallationError(model: model)
        }.accessibilityIdentifier("mobile.package.install.plan").fillsAvailableContentArea(alignment: .topLeading)
    }
}

private struct MobilePackageInstallOptionsForm: View {
    @Bindable var model: MobilePackageInstallationModel
    let configuration: NasPackageInstallConfiguration
    @State private var volume: String
    @State private var start: Bool
    @State private var agreed = false
    @State private var values: [String: NasPackageOptionValue]
    @State private var sourceActivation: UUID
    @FocusState private var focusedField: String?
    init(model: MobilePackageInstallationModel, configuration: NasPackageInstallConfiguration) {
        self.model = model; self.configuration = configuration
        _sourceActivation = State(initialValue: model.activation)
        _volume = State(initialValue: configuration.defaultVolumeID); _start = State(initialValue: configuration.canStart)
        _values = State(initialValue: Dictionary(uniqueKeysWithValues: configuration.fields.filter { $0.kind != .description }.map { ($0.id, $0.defaultValue) }))
    }
    private var valid: Bool { configuration.accepts(values) && (configuration.license == nil || agreed) && (configuration.volumes.isEmpty || !volume.isEmpty) }
    var body: some View {
        Form {
            Section(configuration.packageName) { LabeledContent(L10n.string("package.center.available-version"), value: configuration.version) }
            if let license = configuration.license {
                Section(L10n.string("package.center.license")) {
                    Text(mobilePackagePlainText(license)).textSelection(.enabled)
                    Toggle(L10n.string("package.center.accept-license"), isOn: $agreed).accessibilityIdentifier("mobile.package.install.license")
                }
            }
            Section { ForEach(configuration.fields) { option($0) } }
            Section {
                if configuration.volumes.count > 1 {
                    Picker(L10n.string("package.center.volume"), selection: $volume) {
                        if configuration.defaultVolumeID.isEmpty { Text(L10n.string("package.center.choose-volume")).tag("") }
                        ForEach(configuration.volumes) { Text($0.name).tag($0.id) }
                    }.accessibilityIdentifier("mobile.package.install.optionVolume")
                } else if let volume = configuration.volumes.first { LabeledContent(L10n.string("package.center.volume"), value: volume.name) }
                if configuration.canStart { Toggle(L10n.string("package.center.start-after"), isOn: $start) }
                if configuration.requiresRestart { Text(L10n.string("package.center.restart-required")).foregroundStyle(.orange) }
                Text(L10n.string("package.center.install-warning"))
                Button(L10n.string("package.center.confirm-install")) {
                    model.configure(volume: volume, startAfterInstall: start, licenseAccepted: agreed, values: values, activation: sourceActivation)
                    if model.isBusy { values.removeAll() }
                }.disabled(!valid || !model.canConfigure || sourceActivation != model.activation).accessibilityIdentifier("mobile.package.install.confirmOptions")
                Button(L10n.string("mobile.package.install.discard"), role: .destructive) { values.removeAll(); model.cancel(activation: sourceActivation) }
                    .disabled(!model.canCancel).accessibilityIdentifier("mobile.package.install.discard")
            }
            MobilePackageInstallationError(model: model)
        }.disabled(model.isBusy || sourceActivation != model.activation).scrollDismissesKeyboard(.interactively)
        .toolbar { ToolbarItemGroup(placement: .keyboard) {
            Spacer(); Button(L10n.string("mobile.nas.service.done")) { focusedField = nil }.accessibilityIdentifier("mobile.package.install.keyboardDone")
        } }
        .accessibilityIdentifier("mobile.package.install.options").fillsAvailableContentArea(alignment: .topLeading)
        .onDisappear { values.removeAll() }
    }
    @ViewBuilder private func option(_ field: NasPackageInstallField) -> some View {
        let label = mobilePackagePlainText(field.label)
        Group {
            switch field.kind {
            case .description: Text(label).textSelection(.enabled)
            case .text:
                VStack(alignment: .leading, spacing: 6) {
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                    TextField("", text: text(field)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel(label).accessibilityIdentifier("mobile.package.install.field.\(field.id)")
                        .focused($focusedField, equals: field.id).submitLabel(.done).onSubmit { focusedField = nil }
                }
            case .password:
                VStack(alignment: .leading, spacing: 6) {
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                    SecureField("", text: text(field)).textContentType(.newPassword)
                        .accessibilityLabel(label).accessibilityIdentifier("mobile.package.install.field.\(field.id)")
                        .focused($focusedField, equals: field.id).submitLabel(.done).onSubmit { focusedField = nil }
                }
            case .toggle: Toggle(label, isOn: Binding(get: { values[field.id] == .flag(true) }, set: { values[field.id] = .flag($0) }))
            case .radio:
                Button { for item in configuration.fields where item.group == field.group { values[item.id] = .flag(item.id == field.id) } } label: {
                    Label(label, systemImage: values[field.id] == .flag(true) ? "largecircle.fill.circle" : "circle")
                }.accessibilityAddTraits(values[field.id] == .flag(true) ? [.isSelected] : [])
            case .choice: Picker(label, selection: text(field)) { ForEach(field.choices) { Text(mobilePackagePlainText($0.name)).tag($0.id) } }
            }
        }.accessibilityIdentifier("mobile.package.install.field.\(field.id)")
    }
    private func text(_ field: NasPackageInstallField) -> Binding<String> {
        Binding(get: { if case .text(let text) = values[field.id] ?? field.defaultValue { text } else { "" } }, set: { values[field.id] = .text($0) })
    }
}

struct MobilePackageInstallationActivity: View {
    @Bindable var model: MobilePackageInstallationModel
    var excluding: UUID? = nil
    @Environment(\.locale) private var locale
    var body: some View {
        let entries = model.entries.filter { $0.id != excluding }
        if !entries.isEmpty {
            Section(L10n.string("mobile.package.install.progress")) {
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        let names = names(entry)
                        if !names.isEmpty { ForEach(names, id: \.self) { Text($0).font(.headline) } }
                        else { Text(L10n.string(entry.isUpload ? "package.center.manual" : "package.center.installation-title")).font(.headline) }
                        Text(entry.phase.mobileInstallTitle).accessibilityIdentifier("mobile.package.install.record.\(entry.phase.rawValue)")
                        Text(L10n.string("package.center.queue-progress", entry.completedCount.formatted(.number.locale(locale)), entry.totalCount.formatted(.number.locale(locale))))
                        Text(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))).font(.caption).foregroundStyle(.secondary)
                        if entry.phase == .interrupted { Text(L10n.string("mobile.package.install.interruptedHelp")) }
                        if entry.phase == .partial { Text(L10n.string("mobile.package.install.partialHelp")) }
                        if entry.isProtected {
                            Button(L10n.string("package.center.check-status")) { Task { await model.resume() } }.disabled(model.isBusy)
                                .accessibilityIdentifier("mobile.package.install.refresh")
                        } else {
                            Button(L10n.string("mobile.nas.service.removeRecord")) { model.remove(entry.id) }
                                .disabled(model.recovery.isExecuting(entry.id)).accessibilityIdentifier("mobile.package.install.remove")
                        }
                    }
                }
            }
        }
    }
    private func names(_ entry: MobilePackageInstallationStore.Entry) -> [String] {
        let targets = Set(entry.steps.compactMap { $0.target?.packageID })
        let values = (model.catalog.value?.entries ?? []).filter { targets.contains(MobilePackageOperationStore.digest($0.packageID)) }.map(\.name)
        return Array(Set(values)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

private struct MobilePackageInstallationError: View {
    @Bindable var model: MobilePackageInstallationModel
    var body: some View {
        if let error = model.error { Section { Text(model.message ?? error.mobilePackageMessage).accessibilityIdentifier("mobile.package.install.error") } }
    }
}

extension NasPackageInstallProgress.Phase {
    var mobileInstallTitle: String {
        let key = switch self { case .downloading: "package.center.phase.downloading"; case .installing: "package.center.phase.installing"; case .needsOptions: "package.center.phase.needsOptions"; case .completed: "package.center.phase.completed"; case .failed: "package.center.phase.failed"; case .unverified: "package.center.phase.unverified"; case .cancelled: "package.center.phase.cancelled" }
        return L10n.string(key)
    }
}
extension MobilePackageInstallationStore.Phase {
    var mobileInstallTitle: String {
        let key = switch self { case .prepared: "package.center.preparing"; case .active: "mobile.package.install.active"; case .completed: "package.center.phase.completed"; case .partial: "mobile.package.install.partial"; case .failed: "package.center.phase.failed"; case .cancelled: "package.center.phase.cancelled"; case .interrupted: "mobile.package.install.interrupted" }
        return L10n.string(key)
    }
}

/// 只呈现文字，不执行套件说明、许可或标签中的网页内容。
func mobilePackagePlainText(_ value: String) -> String {
    value.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|li|div|h[1-6])>", with: "\n", options: .regularExpression)
        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
}
