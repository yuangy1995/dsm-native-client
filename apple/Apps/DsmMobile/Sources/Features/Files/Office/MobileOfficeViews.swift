import DsmCore
import DsmLocalization
import SwiftUI
import UniformTypeIdentifiers

struct MobileOfficeSelection: Identifiable {
    let id = UUID()
    let item: FileItem
    let context: String
}

private struct MobileOfficeExport: Identifiable {
    let id = UUID()
    let url: URL
}

struct MobileOfficeEditor: View {
    @Bindable var model: MobileOfficeModel
    let selection: MobileOfficeSelection
    @State private var recordID: UUID?
    @State private var isImporting = false
    @State private var export: MobileOfficeExport?
    @State private var showsDiscard = false
    @Environment(\.dismiss) private var dismiss

    private var record: MobileOfficeRecord? { recordID.flatMap(model.record) }
    private var isCurrent: Bool { model.context == selection.context }
    private var visibleFailure: MobileOfficeFailure? {
        if model.recoveryFailed { return .recovery }
        if record?.phase == .conflict && model.failure == .changed { return nil }
        if record?.phase == .uncertain && model.failure == .interrupted { return nil }
        return model.failure
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(selection.item.name).font(.headline).textSelection(.enabled)
                    Text(selection.item.path).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let visibleFailure {
                    Section {
                        Text(visibleFailure.message)
                            .foregroundStyle(.secondary).accessibilityIdentifier("files.office.error")
                        if record == nil && !model.isBusy && !model.recoveryFailed {
                            Button(L10n.string("background-tasks.retry")) { Task { await prepare() } }
                        }
                    }
                }
                if let record {
                    Section {
                        Text(record.phase.title).accessibilityIdentifier("files.office.status")
                        if record.phase == .ready { Text(L10n.string("mobile.office.handoff")).foregroundStyle(.secondary) }
                        if record.phase == .conflict { Text(L10n.string("mobile.office.conflict")).foregroundStyle(.secondary) }
                        if record.phase == .changed { Text(L10n.string("mobile.office.save.notice")).foregroundStyle(.secondary) }
                        if record.phase == .uncertain { Text(L10n.string("mobile.office.interrupted")).foregroundStyle(.secondary) }
                        if model.isBusy {
                            ProgressView(value: model.progress).accessibilityLabel(L10n.string("mobile.office.working"))
                        }
                    }
                    Section {
                        Button(L10n.string("mobile.office.export"), systemImage: "square.and.arrow.up") {
                            if let url = model.copyURL(record.id) { export = .init(url: url) }
                        }.disabled(model.isBusy).accessibilityIdentifier("files.office.export")
                        if record.phase != .uncertain && record.phase != .saving {
                            Button(L10n.string("mobile.office.import"), systemImage: "doc.badge.arrow.up") { isImporting = true }
                                .disabled(model.isBusy).accessibilityIdentifier("files.office.import")
                        }
                        if record.phase == .changed {
                            Button(L10n.string("mobile.office.save"), systemImage: "square.and.arrow.up.fill") {
                                Task { await model.save(record.id) }
                            }.disabled(model.isBusy).accessibilityIdentifier("files.office.save")
                        }
                        if record.phase == .uncertain {
                            Button(L10n.string("background-tasks.refresh"), systemImage: "arrow.clockwise") {
                                Task { await model.refresh(record.id) }
                            }.disabled(model.isBusy).accessibilityIdentifier("files.office.refresh")
                        }
                    }
                    if record.phase != .uncertain && record.phase != .saving {
                        Section {
                            Button(L10n.string("mobile.office.discard"), role: .destructive) { showsDiscard = true }
                                .disabled(model.isBusy).accessibilityIdentifier("files.office.discard")
                        }
                    }
                } else if model.isBusy {
                    Section { ProgressView(L10n.string("mobile.office.working")) }
                }

            }
            .navigationTitle(L10n.string("mobile.office.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.files.share-link.action.done")) { dismiss() }
                }
            }
            .task { await prepare() }
            .onChange(of: model.context) { _, _ in if !isCurrent { export = nil; isImporting = false; dismiss() } }
            .fileImporter(isPresented: $isImporting,
                allowedContentTypes: [UTType(filenameExtension: selection.item.fileExtension ?? "") ?? .item],
                allowsMultipleSelection: false) { result in
                guard isCurrent, let id = recordID, case .success(let urls) = result, let url = urls.first else { return }
                Task { await model.importEdited(url, id: id, expectedContext: selection.context) }
            }
            .sheet(item: $export) { artifact in
                MobileShareSheet(url: artifact.url) { export = nil }
            }
            .confirmationDialog(L10n.string("mobile.office.discard.title"), isPresented: $showsDiscard,
                titleVisibility: .visible) {
                Button(L10n.string("mobile.office.discard"), role: .destructive) {
                    guard let id = recordID else { return }
                    model.discard(id)
                    if model.record(id) == nil { dismiss() }
                }
            } message: { Text(L10n.string("mobile.office.discard.message")) }
        }
    }

    private func prepare() async {
        guard isCurrent, recordID == nil else { return }
        // 上一份文档仍在处理时等待其结束，避免新页面停留在没有下一步操作的空表单。
        while model.isBusy {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard isCurrent else { return }
        }
        recordID = await model.prepare(selection.item)
    }
}

struct MobileOfficeSections: View {
    @Bindable var model: MobileOfficeModel
    let filter: MobileActivityFilter
    let onSelect: (MobileOfficeSelection) -> Void

    var body: some View {
        if model.recoveryFailed { Section { Text(MobileOfficeFailure.recovery.message) } }
        let records = model.records.filter { filter.includes(active: $0.phase.isActive) }
        if !records.isEmpty {
            Section(L10n.string("mobile.office.activity")) {
                ForEach(records) { record in
                    Button {
                        onSelect(.init(item: record.baseline, context: record.context))
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(record.baseline.name).foregroundStyle(.primary)
                            Text(record.phase.title).font(.subheadline).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, minHeight: MobileMetrics.minimumTouchTarget, alignment: .leading)
                    }.accessibilityIdentifier("files.office.activity.\(record.id.uuidString)")
                }
            }
        }
    }
}

extension MobileOfficePhase {
    var title: String {
        switch self {
        case .ready: L10n.string("mobile.office.ready")
        case .changed: L10n.string("mobile.office.changed")
        case .unchanged: L10n.string("mobile.office.unchanged")
        case .saving: L10n.string("mobile.office.saving")
        case .saved: L10n.string("mobile.office.saved")
        case .conflict: L10n.string("mobile.office.conflict.title")
        case .uncertain: L10n.string("mobile.office.interrupted.title")
        }
    }
}

extension MobileOfficeFailure {
    var message: String {
        switch self {
        case .connection: L10n.string("mobile.office.connection")
        case .permission: L10n.string("mobile.office.permission")
        case .changed: L10n.string("mobile.office.conflict")
        case .format: L10n.string("mobile.office.format")
        case .local: L10n.string("mobile.office.local")
        case .recovery: L10n.string("mobile.office.recovery")
        case .interrupted: L10n.string("mobile.office.interrupted")
        }
    }
}
