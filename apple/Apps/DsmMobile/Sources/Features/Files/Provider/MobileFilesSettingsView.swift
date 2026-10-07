import DsmCore
import DsmLocalization
import SwiftUI

struct MobileFilesSettingsView: View {
    @Bindable var app: MobileAppModel
    @State private var model: MobileFilesSettingsModel?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let model { MobileFilesLocationsList(model: model) }
            else if unavailable {
                ContentUnavailableView(L10n.string("mobile.files-location.title"), systemImage: "folder.badge.gearshape",
                    description: Text(L10n.string("mobile.extensions.unavailable")))
            } else { ProgressView() }
        }
        .navigationTitle(L10n.string("mobile.files-location.title"))
        .task {
            guard model == nil else { return }
            do {
                guard let access = app.extensionAccess else { throw MobileExtensionAccountError.unavailable }
                model = try .init(locations: .live(), accounts: access.accounts, currentProfile: { app.activeProfile })
            } catch { unavailable = true }
        }
    }
}

struct MobileFilesLocationsList: View {
    @Bindable var model: MobileFilesSettingsModel

    var body: some View {
        List {
            if model.loading && !model.hasLoaded { ProgressView(L10n.string("mobile.files-location.loading")) }
            if model.hasLoaded && model.rows.isEmpty {
                ContentUnavailableView(L10n.string("mobile.files-location.empty"), systemImage: "folder",
                    description: Text(L10n.string("mobile.files-location.empty-detail")))
            }
            ForEach(model.rows) { row in
                NavigationLink {
                    MobileFilesLocationDetail(model: model, location: row.location)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(row.location.profile.displayName)
                        Text(L10n.string(!row.registered ? "mobile.files-location.not-added" : !row.hasAccess ? "mobile.files-location.changed" : !row.systemEnabled ? "mobile.files-location.enable-in-files" : row.paused ? "mobile.files-location.paused" : "mobile.files-location.available"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }.accessibilityIdentifier("mobile.files-location.row")
            }
            if !model.rows.contains(where: { $0.registered && $0.hasAccess }) {
                Button(L10n.string("mobile.files-location.add")) { Task { await model.add() } }
                    .frame(minHeight: 44).disabled(model.busy || model.loading)
                    .accessibilityIdentifier("mobile.files-location.add")
            }
            if let error = model.error {
                Section { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("mobile.files-location.error") }
            }
        }
        .navigationTitle(L10n.string("mobile.files-location.title"))
        .accessibilityIdentifier("mobile.files-location.list")
        .task { await model.reload() }
        .refreshable { await model.reload() }
        .toolbar {
            Button { Task { await model.reload() } } label: {
                Label(L10n.string("mobile.files-location.refresh"), systemImage: "arrow.clockwise")
            }.disabled(model.busy || model.loading)
        }
        .alert(L10n.string("mobile.files-location.added"), isPresented: $model.addedLocation) {
            Button(L10n.string("mobile.share.close")) {}
        } message: { Text(L10n.string("mobile.files-location.added-detail")) }
    }
}

private struct MobileFilesLocationDetail: View {
    @Bindable var model: MobileFilesSettingsModel
    let location: MobileFilesLocation
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsEditing = false
    @State private var confirmsDeleting = false
    @State private var confirmsRemove = false
    @State private var retrying: DesktopDriveWritebackRecord?
    @State private var stopping: DesktopDriveWritebackRecord?
    @State private var exporting: Export?

    private struct Export: Identifiable {
        let id = UUID()
        let record: DesktopDriveWritebackRecord
        let url: URL
        let stopAfterExport: Bool
    }

    private var row: MobileFilesLocationState? { model.rows.first { $0.id == location.id } }

    var body: some View {
        Form {
            if let row {
                Section {
                    Toggle(L10n.string("mobile.files-location.pause"), isOn: Binding(get: { row.paused }, set: { value in
                        Task { await model.setPaused(value, location: location) }
                    })).disabled(!row.hasAccess && row.paused).accessibilityIdentifier("mobile.files-location.pause")
                    Toggle(L10n.string("mobile.files-location.editing"), isOn: Binding(get: { row.editing }, set: { value in
                        if value { confirmsEditing = true } else { Task { await model.setEditing(false, location: location) } }
                    })).disabled(!row.hasAccess).accessibilityIdentifier("mobile.files-location.editing")
                    Toggle(L10n.string("mobile.files-location.deleting"), isOn: Binding(get: { row.deleting }, set: { value in
                        if value { confirmsDeleting = true } else { Task { await model.setDeleting(false, location: location) } }
                    })).disabled(!row.editing || !row.hasAccess).accessibilityIdentifier("mobile.files-location.deleting")
                } footer: {
                    if !row.hasAccess { Text(L10n.string("mobile.files-location.changed-detail")) }
                    else if !row.systemEnabled { Text(L10n.string("mobile.files-location.enable-detail")) }
                    else if row.paused { Text(L10n.string("mobile.files-location.pause-detail")) }
                }
                Section(L10n.string("mobile.files-location.pending")) {
                    if row.records.isEmpty { Text(L10n.string("mobile.files-location.saved")).foregroundStyle(.secondary) }
                    ForEach(row.records) { record in recordView(record) }
                }
                Section {
                    Button(L10n.string("mobile.files-location.remove"), role: .destructive) { confirmsRemove = true }
                        .frame(minHeight: 44).accessibilityIdentifier("mobile.files-location.remove")
                }
            }
            if let error = model.error { Section { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("mobile.files-location.error") } }
        }
        .disabled(model.busy)
        .navigationTitle(location.profile.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.reload() }
        .toolbar {
            Button { Task { await model.reload() } } label: { Label(L10n.string("mobile.files-location.refresh"), systemImage: "arrow.clockwise") }
                .disabled(model.busy || model.loading)
        }
        .alert(L10n.string("mobile.files-location.editing"), isPresented: $confirmsEditing) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("mobile.files-location.editing")) { Task { await model.setEditing(true, location: location) } }
        } message: { Text(L10n.string("mobile.files-location.editing-detail")) }
        .alert(L10n.string("mobile.files-location.deleting"), isPresented: $confirmsDeleting) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("mobile.files-location.deleting"), role: .destructive) { Task { await model.setDeleting(true, location: location) } }
        } message: { Text(L10n.string("mobile.files-location.deleting-detail")) }
        .alert(L10n.string("mobile.files-location.remove"), isPresented: $confirmsRemove) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("mobile.files-location.remove"), role: .destructive) { Task {
                await model.remove(location)
                if model.rows.allSatisfy({ $0.id != location.id }) { dismiss() }
            } }
        } message: { Text(L10n.string("mobile.files-location.remove-detail")) }
        .alert(L10n.string("mobile.files-location.retry"), isPresented: Binding(get: { retrying != nil }, set: { if !$0 { retrying = nil } })) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { retrying = nil }
            Button(L10n.string("mobile.files-location.retry"), role: .destructive) {
                if let record = retrying { Task { await model.retry(record, location: location) } }
                retrying = nil
            }
        } message: { Text(L10n.string(retrying?.isDeletion == true ? "mobile.files-location.retry-delete" : "mobile.files-location.retry-save")) }
        .alert(L10n.string("mobile.files-location.stop"), isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { stopping = nil }
            Button(L10n.string("mobile.files-location.stop"), role: .destructive) {
                if let record = stopping {
                    if record.contentHash != nil { beginExport(record, stop: true) }
                    else { Task { await model.stop(record, location: location) } }
                }
                stopping = nil
            }
        } message: { Text(L10n.string("mobile.files-location.stop-detail")) }
        .sheet(item: $exporting) { export in
            exporter(export)
        }
    }

    private func recordView(_ record: DesktopDriveWritebackRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text((record.destinationPath as NSString).lastPathComponent).font(.headline)
            Text(L10n.string(record.phase == .conflict ? "mobile.files-location.conflict" : "mobile.files-location.waiting"))
                .foregroundStyle(.secondary)
            HStack {
                Button(L10n.string("mobile.files-location.retry")) { retrying = record }
                    .disabled(row?.hasAccess != true || row?.editing != true || (record.isDeletion && row?.deleting != true))
                Menu {
                    if record.contentHash != nil { Button(L10n.string("mobile.files-location.export")) { beginExport(record, stop: false) } }
                    Button(L10n.string("mobile.files-location.stop"), role: .destructive) { stopping = record }
                } label: { Label(L10n.string("mobile.files-location.more"), systemImage: "ellipsis") }
            }.buttonStyle(.bordered).frame(minHeight: 44)
        }.padding(.vertical, 5)
    }

    private func beginExport(_ record: DesktopDriveWritebackRecord, stop: Bool) {
        do { exporting = Export(record: record, url: try model.exportURL(record, location: location), stopAfterExport: stop) }
        catch { model.error = L10n.string("mobile.files-location.export-error") }
    }

    private func exporter(_ export: Export) -> MobileDocumentExporter {
        var view = MobileDocumentExporter(url: export.url) { exporting = nil }
        view.exported = { _ in
            if export.stopAfterExport { Task { await model.stop(export.record, location: location, exportedCopy: true) } }
        }
        return view
    }
}
