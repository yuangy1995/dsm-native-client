import DsmCore
import DsmLocalization
import DsmNetwork
import SwiftUI

struct MobileCrossNASSelection: Identifiable {
    let id = UUID()
    let sourceContext: String
    let items: [FileItem]
}

struct MobileCrossNASSelectionView: View {
    @Bindable var model: MobileAppModel
    let selection: MobileCrossNASSelection
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: UUID?
    @State private var target: MobileCrossNASEndpoint?
    @State private var destination = ""
    @State private var moveSource = false
    @State private var loading = false
    @State private var failure: MobileCrossNASFailure?
    @State private var showsFolderPicker = false
    @State private var isSubmitting = false
    private var profiles: [NasProfile] { model.profiles.filter { $0.id != model.activeProfile?.id } }

    var body: some View {
        NavigationStack {
            Form {
                if profiles.isEmpty {
                    ContentUnavailableView(L10n.string("mobile.cross.empty.title"), systemImage: "externaldrive.badge.plus",
                        description: Text(L10n.string("mobile.cross.empty.message")))
                } else {
                    Section {
                        if profiles.count == 1, let profile = profiles.first {
                            LabeledContent(L10n.string("mobile.cross.target"), value: profile.displayName)
                        } else {
                            Picker(L10n.string("mobile.cross.target"), selection: $selectedID) {
                                Text(L10n.string("mobile.cross.choose-target")).tag(nil as UUID?)
                                ForEach(profiles) { profile in Text(profile.displayName).tag(Optional(profile.id)) }
                            }.accessibilityIdentifier("files.cross.target")
                        }
                        if loading { ProgressView(L10n.string("mobile.cross.connecting")) }
                        if target != nil {
                            Button { showsFolderPicker = true } label: {
                                LabeledContent(L10n.string("mobile.files.copy-move.destination.label"),
                                    value: destination.isEmpty ? L10n.string("mobile.files.choose-folder") : destination)
                                    .frame(minHeight: 44)
                            }.accessibilityIdentifier("files.cross.destination")
                        }
                        Picker(L10n.string("mobile.cross.action"), selection: $moveSource) {
                            Text(L10n.string("mobile.files.copy-move.copy.action")).tag(false)
                            Text(L10n.string("mobile.files.copy-move.move.action")).tag(true)
                        }.pickerStyle(.segmented).accessibilityIdentifier("files.cross.operation")
                        Text(L10n.string(moveSource ? "mobile.cross.move-notice" : "mobile.cross.copy-notice"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .disabled(model.crossNAS.isWorking)
                }
                if let message = failure ?? model.crossNAS.error {
                    Section { Text(message.message).foregroundStyle(.red).accessibilityIdentifier("files.cross.error") }
                }
                if model.crossNAS.isPreparing { Section { ProgressView(L10n.string("files.upload.preparing")) } }
                Section {
                    ForEach(selection.items) { item in Label(item.name, systemImage: item.isDirectory ? "folder" : "doc") }
                }
            }
            .navigationTitle(L10n.string("mobile.cross.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("ui.2cd0f3be8738a86c")) {
                        if isSubmitting { model.crossNAS.pause() }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.cross.start")) {
                        guard let target else { return }
                        isSubmitting = true
                        Task {
                            let id = await model.crossNAS.submit(items: selection.items, target: target,
                                destination: destination, moveSource: moveSource)
                            isSubmitting = false
                            if id != nil { dismiss() }
                        }
                    }
                    .disabled(target == nil || destination.isEmpty || loading || isSubmitting || model.crossNAS.isWorking)
                    .accessibilityIdentifier("files.cross.start")
                }
            }
            .sheet(isPresented: $showsFolderPicker) {
                if let repository = target?.repository as? DsmFileRepository {
                    MobileFileFolderPicker(repository: repository) { destination = $0 }
                }
            }
            .onAppear { if profiles.count == 1 { selectedID = profiles.first?.id } }
            .task(id: selectedID) {
                model.crossNAS.clearError(); failure = nil; destination = ""; target = nil
                guard let profile = profiles.first(where: { $0.id == selectedID }) else { loading = false; return }
                loading = true
                do {
                    let value = try await model.crossNASTarget(profile)
                    try Task.checkCancellation()
                    guard selectedID == profile.id else { return }
                    target = value; loading = false
                } catch {
                    guard !Task.isCancelled, selectedID == profile.id else { return }
                    failure = (error as? MobileCrossNASFailure) ?? .connection; loading = false
                }
            }
            .onChange(of: model.activeProfile.map { MobileWorkspaceIdentity($0).storageIdentifier }) { _, context in
                if context != selection.sourceContext { dismiss() }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }
}

struct MobileCrossNASSections: View {
    @Bindable var model: MobileAppModel
    let filter: MobileActivityFilter
    @State private var connectingID: UUID?
    @State private var confirmation: UUID?
    @State private var failure: MobileCrossNASFailure?

    var body: some View {
        if model.crossNAS.recoveryFailed {
            Section { Text(L10n.string("mobile.activity.recovery-error")) }
        }
        if let failure { Section { Text(failure.message).foregroundStyle(.red) } }
        ForEach(model.crossNAS.records.filter { filter.includes(active: $0.isRunning || $0.canContinue || $0.hasUnknown) }) { record in
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.string("mobile.cross.route", record.sourceName, record.targetName)).font(.headline)
                    Text(record.destination).font(.subheadline).foregroundStyle(.secondary)
                    Text(record.phase.title).accessibilityIdentifier("files.cross.status")
                    Text(L10n.string("mobile.cross.progress", Int64(record.completedCount), Int64(record.entries.count)))
                        .font(.caption).foregroundStyle(.secondary)
                    if record.isRunning {
                        if let total = model.crossNAS.totalBytes, total > 0 {
                            ProgressView(value: Double(model.crossNAS.completedBytes), total: Double(total))
                        } else { ProgressView() }
                    }
                    if let reason = record.failure { Text(reason.message).font(.callout).foregroundStyle(.secondary) }
                    DisclosureGroup(L10n.string("mobile.cross.items")) {
                        ForEach(record.entries) { entry in
                            VStack(alignment: .leading) {
                                Text(entry.source.path).lineLimit(2).truncationMode(.middle)
                                Text(entry.status.title).font(.caption).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                    }
                }
                if connectingID == record.id { ProgressView(L10n.string("mobile.cross.connecting")) }
                if record.isRunning {
                    Button(L10n.string("files.upload.pause")) { model.crossNAS.pause() }
                        .accessibilityIdentifier("files.cross.pause")
                } else {
                    if record.canContinue {
                        Button(L10n.string("files.upload.resume")) { perform(record, action: .resume) }
                            .accessibilityIdentifier("files.cross.resume")
                    }
                    if record.hasUnknown || record.failure != nil {
                        Button(L10n.string("ui.aee88743413144a2")) { perform(record, action: .refresh) }
                            .accessibilityIdentifier("files.cross.refresh")
                    }
                    if record.canRemoveSource {
                        Button(L10n.string("mobile.cross.remove-source"), role: .destructive) { confirmation = record.id }
                            .accessibilityIdentifier("files.cross.remove")
                    }
                }
            }
            .disabled(connectingID != nil || model.crossNAS.isPreparing || model.crossNAS.runningID != nil && model.crossNAS.runningID != record.id)
        }
        .confirmationDialog(L10n.string("mobile.cross.remove-source"),
            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
                Button(L10n.string("mobile.cross.remove-source"), role: .destructive) {
                    if let record = model.crossNAS.records.first(where: { $0.id == confirmation }) { perform(record, action: .remove) }
                    confirmation = nil
                }
            } message: {
                if let record = model.crossNAS.records.first(where: { $0.id == confirmation }) {
                    Text(L10n.string("mobile.cross.remove-notice", record.sourceName, record.targetName))
                }
            }
    }

    private enum Action { case resume, refresh, remove }
    private func perform(_ record: MobileCrossNASRecord, action: Action) {
        guard connectingID == nil, let profile = model.profiles.first(where: { $0.id == record.targetID }),
              MobileWorkspaceIdentity(profile).storageIdentifier == record.targetContext else { failure = .connection; return }
        connectingID = record.id; failure = nil
        Task {
            defer { connectingID = nil }
            do {
                let target = try await model.crossNASTarget(profile)
                switch action {
                case .resume: model.crossNAS.resume(record.id, target: target)
                case .refresh: await model.crossNAS.refresh(record.id, target: target)
                case .remove: model.crossNAS.removeSource(record.id, target: target)
                }
            } catch { failure = (error as? MobileCrossNASFailure) ?? .connection }
        }
    }
}

private extension MobileCrossNASPhase {
    var title: String {
        switch self {
        case .paused: L10n.string("mobile.cross.phase.paused")
        case .copying: L10n.string("mobile.cross.phase.copying")
        case .copied: L10n.string("mobile.cross.phase.copied")
        case .removing: L10n.string("mobile.cross.phase.removing")
        case .finished: L10n.string("mobile.cross.phase.finished")
        case .interrupted: L10n.string("mobile.cross.phase.interrupted")
        }
    }
}
private extension MobileCrossNASItemStatus {
    var title: String {
        switch self {
        case .pending: L10n.string("mobile.cross.item.pending")
        case .writing: L10n.string("mobile.cross.item.writing")
        case .copied: L10n.string("mobile.cross.item.copied")
        case .uncertain: L10n.string("mobile.cross.item.uncertain")
        case .deleting: L10n.string("mobile.cross.item.deleting")
        case .removed: L10n.string("mobile.cross.item.removed")
        case .deleteUncertain: L10n.string("mobile.cross.item.deleteUncertain")
        }
    }
}
extension MobileCrossNASFailure {
    var message: String {
        switch self {
        case .connection: L10n.string("mobile.cross.error.connection")
        case .permission: L10n.string("mobile.cross.error.permission")
        case .changed: L10n.string("mobile.cross.error.changed")
        case .conflict: L10n.string("mobile.cross.error.conflict")
        case .interrupted: L10n.string("mobile.cross.error.interrupted")
        case .recovery: L10n.string("mobile.cross.error.recovery")
        case .invalid: L10n.string("mobile.cross.error.invalid")
        case .unavailable: L10n.string("mobile.cross.error.unavailable")
        }
    }
}
