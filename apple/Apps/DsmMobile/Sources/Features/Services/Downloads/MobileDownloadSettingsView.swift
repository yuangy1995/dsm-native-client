import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDownloadSettingsView: View {
    @Bindable var model: MobileDownloadSettingsModel
    let fileRepository: (any MobileFileBrowsing)?
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false
    @State private var pickerActivation = UUID()
    @State private var inputs: [DownloadSettingsField: String] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading && model.snapshot == nil {
                    ProgressView(L10n.string("download.settings.loading"))
                } else if model.snapshot == nil {
                    ContentUnavailableView {
                        Label(L10n.string("ui.f988df886e7d7e73"), systemImage: "gearshape")
                    } description: {
                        Text(L10n.string(model.errorKey ?? "download.settings.load-error"))
                    } actions: {
                        Button(L10n.string("ui.b8784c8dd5636ff2")) { Task { await model.load() } }
                    }
                } else if model.snapshot?.values.isEmpty == true && model.entry == nil {
                    ContentUnavailableView {
                        Label(L10n.string("ui.f988df886e7d7e73"), systemImage: "gearshape")
                    } description: {
                        Text(L10n.string("download.settings.empty"))
                    } actions: {
                        Button(L10n.string("ui.aee88743413144a2")) { Task { await model.load() } }
                    }
                } else {
                    form
                }
            }
            .fillsAvailableContentArea(alignment: .topLeading)
            .navigationTitle(L10n.string("ui.f988df886e7d7e73"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.accessibilityIdentifier("downloads.settings.close")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("ui.991bb7cfe5a81550")) { model.save() }
                        .disabled(!model.canSave || invalidLimits)
                        .accessibilityIdentifier("downloads.settings.save")
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .sheet(isPresented: $choosingFolder) {
                if let fileRepository {
                    MobileFileFolderPicker(repository: fileRepository) { path in model.chooseFolder(path, activation: pickerActivation) }
                }
            }
            .task { await model.load(); syncInputs() }
            .onChange(of: model.snapshot) { _, _ in syncInputs() }
        }
    }

    private var form: some View {
        ScrollViewReader { proxy in
            Form {
                if let entry = model.entry {
                    Section(L10n.string("download.settings.recent")) {
                        ForEach(entry.steps) { step in
                            LabeledContent(L10n.string(step.id == .general ? "download.settings.general" : "download.settings.schedule")) {
                                Text(L10n.string(statusKey(step))).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("downloads.settings.result." + step.id.rawValue)
                            }
                            .id("settings.result." + step.id.rawValue)
                        }
                        if model.isSaving { ProgressView(L10n.string("download.settings.saving")) }
                        if entry.hasSubmitted && !model.isSaving {
                            Text(L10n.string("download.settings.pending")).foregroundStyle(.secondary)
                            Button(L10n.string("ui.aee88743413144a2")) { model.run(continuePlanned: false) }
                                .disabled(model.isSaving).accessibilityIdentifier("downloads.settings.refresh")
                        } else if !entry.hasSubmitted && entry.hasPlanned {
                            Button(L10n.string("download.settings.continue")) { model.run(continuePlanned: true) }
                                .disabled(model.isSaving).accessibilityIdentifier("downloads.settings.continue")
                        }
                        if entry.hasPlanned {
                            Button(L10n.string("download.settings.cancel-remaining")) { model.cancelRemaining() }
                                .accessibilityIdentifier("downloads.settings.cancel-remaining")
                        }
                    }
                }
                if model.recovery.failed || model.errorKey != nil {
                    Section {
                        Text(L10n.string(model.recovery.failed ? "download.settings.storage-error" : model.errorKey!))
                            .foregroundStyle(.secondary)
                        Button(L10n.string("ui.aee88743413144a2")) { Task { await model.load() } }.disabled(model.isSaving)
                    }
                }
                if model.snapshot?.isManager != true {
                    Section {
                        Text(L10n.string(model.snapshot?.isManager == false ? "download.settings.permission" : "download.settings.permission-unknown"))
                            .foregroundStyle(.secondary)
                    }
                }
                Section(L10n.string("download.settings.general")) {
                    if let destination = model.draft[.destination]?.text {
                        LabeledContent(L10n.string("ui.22939a4ebb0b8d00")) {
                            Button {
                                pickerActivation = model.activation; choosingFolder = true
                            } label: {
                                Label(destination.isEmpty ? L10n.string("mobile.files.choose-folder") : destination, systemImage: "folder")
                                    .lineLimit(2).truncationMode(.middle)
                            }
                            .disabled(!model.canEdit || fileRepository == nil)
                            .accessibilityIdentifier("downloads.settings.destination")
                        }
                    } else { unavailable("ui.22939a4ebb0b8d00") }
                    flag(.emule, title: "ui.36ec0018d6d2e3cf")
                    flag(.autoExtract, title: "ui.1ec1e57766d7769a")
                }
                Section {
                    speed(.btDownload, title: "ui.72f4d786f20ef7d0")
                    speed(.btUpload, title: "ui.4475d765a50bb50e")
                    if model.draft[.httpDownload] != nil && model.draft[.httpDownload] == model.draft[.ftpDownload] {
                        speed(.ftpDownload, title: "ui.6669be0cf447b7bc")
                    } else { unavailable("ui.6669be0cf447b7bc") }
                    speed(.nzbDownload, title: "ui.810040fd1925dbd0")
                    speed(.emuleDownload, title: "ui.9d6bf94d4704e700")
                    speed(.emuleUpload, title: "ui.6c4096f61b5a084f")
                    if invalidLimits { Text(L10n.string("download.settings.invalid-limit")).foregroundStyle(.secondary) }
                } header: {
                    Text(L10n.string("download.settings.limits"))
                } footer: {
                    Text(L10n.string("download.settings.limit-help"))
                }
                Section(L10n.string("download.settings.schedule")) {
                    flag(.schedule, title: "download.settings.schedule-enabled")
                    flag(.emuleSchedule, title: "download.settings.emule-schedule-enabled", additionalDisabled: model.draft[.schedule]?.flag != true)
                }
            }
            .accessibilityIdentifier("downloads.settings.form")
            .refreshable { await model.load() }
            .onChange(of: model.entry?.id) { _, _ in scrollToResult(proxy) }
            .onChange(of: model.isSaving) { _, saving in if !saving { scrollToResult(proxy) } }
        }
    }
    private func scrollToResult(_ proxy: ScrollViewProxy) {
        if let step = model.entry?.steps.first { proxy.scrollTo("settings.result." + step.id.rawValue, anchor: .top) }
    }
    private func flag(_ field: DownloadSettingsField, title: String, additionalDisabled: Bool = false) -> some View {
        Group {
            if let value = model.draft[field]?.flag {
                Toggle(L10n.string(title), isOn: Binding(get: { model.draft[field]?.flag ?? value }, set: { model.set(field, to: .flag($0)) }))
                    .disabled(!model.canEdit || additionalDisabled)
                    .accessibilityIdentifier("downloads.settings." + field.rawValue)
            } else { unavailable(title) }
        }
    }
    private func speed(_ field: DownloadSettingsField, title: String) -> some View {
        Group {
            if model.draft[field]?.number != nil {
                LabeledContent(L10n.string(title)) {
                    TextField(L10n.string("unit.kilobytes_per_second"), text: Binding(
                        get: { inputs[field] ?? "" }, set: {
                            inputs[field] = $0
                            if let value = parse($0), field.accepts(.number(value)) { model.set(field, to: .number(value)) }
                        }))
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .frame(minWidth: 55, maxWidth: 140)
                        .accessibilityLabel(L10n.string(title))
                        .accessibilityIdentifier("downloads.settings." + field.rawValue)
                        .disabled(!model.canEdit)
                }
            } else { unavailable(title) }
        }
    }
    private func unavailable(_ title: String) -> some View {
        LabeledContent(L10n.string(title), value: L10n.string("download.settings.unavailable")).foregroundStyle(.secondary)
    }
    private func parse(_ value: String) -> Int? {
        let normalized = value.replacingOccurrences(of: L10n.locale.groupingSeparator ?? ",", with: "")
        guard !normalized.isEmpty, normalized.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(normalized)
    }
    private var invalidLimits: Bool {
        inputs.contains { field, text in parse(text).map { !field.accepts(.number($0)) } ?? true }
    }
    private func syncInputs() {
        inputs = model.draft.compactMapValues { $0.number.map { $0.formatted(.number.locale(L10n.locale)) } }
    }
    private func statusKey(_ step: MobileDownloadSettingsStore.Step) -> String {
        switch step.phase {
        case .planned: "download.settings.planned"
        case .submitted: model.isSaving ? "download.settings.saving" : "download.settings.pending-short"
        case .complete: "download.settings.saved"
        case .cancelled: "download.settings.cancelled"
        case .failed:
            step.failure == .changed ? "download.settings.changed" : step.failure == .denied ? "download.settings.permission" : "download.settings.failed"
        }
    }
}
