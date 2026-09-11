import AppKit
import DsmCore
import DsmLocalization
import FileProvider
import SwiftUI

struct DesktopDriveWritebackSettingsSheet: View {
    let mapping: DesktopDriveMapping
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var enabled = false
    @State private var records: [DesktopDriveWritebackRecord] = []
    @State private var message: String?
    @State private var hasLoaded = false
    @State private var confirmingEnable = false
    @State private var retrying: DesktopDriveWritebackRecord?
    @State private var stopping: DesktopDriveWritebackRecord?
    private let store: DesktopDriveWritebackStore
    private let writebackAvailable: Bool

    init(mapping: DesktopDriveMapping, store: DesktopDriveWritebackStore = .init(),
         writebackAvailable: Bool = DesktopDriveWritebackAvailability.isEnabled) {
        self.mapping = mapping
        self.store = store
        self.writebackAvailable = writebackAvailable
    }

    private var canEnable: Bool {
        if case .folder = mapping.scope { return writebackAvailable }
        return false
    }

    private var palette: MacAppearancePalette {
        .init(scheme: colorScheme, increasedContrast: contrast == .increased)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(palette.separator)
            VStack(alignment: .leading, spacing: 16) {
                if canEnable {
                    HStack(spacing: 10) {
                        Image(systemName: "pencil.line").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(L10n.string("desktopDrive.writeback.allow")).fontWeight(.medium)
                        Spacer(minLength: 12)
                        Toggle(L10n.string("desktopDrive.writeback.allow"), isOn: Binding(
                            get: { enabled },
                            set: { if $0 { confirmingEnable = true } else { changeEnabled(false) } }
                        ))
                        .toggleStyle(.switch).labelsHidden()
                    }
                    .padding(12)
                    .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.separator, lineWidth: 0.5))
                } else if case .allShares = mapping.scope {
                    Label(L10n.string("desktopDrive.writeback.folderOnly"), systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 7) {
                    Text(L10n.string("desktopDrive.writeback.pendingTitle"))
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    if hasLoaded && !records.isEmpty {
                        Text(records.count.formatted(.number.locale(L10n.locale)))
                            .font(.caption.weight(.medium).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(palette.card, in: Capsule())
                    }
                    Spacer()
                    Button { reload() } label: {
                        Label(L10n.string("desktopDrive.writeback.refresh"), systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly).frame(width: 24, height: 22)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("desktopDrive.writeback.refresh"))
                }
                pendingContent
                if hasLoaded, let message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
            .fillsAvailableContentArea(alignment: .topLeading)
        }
        .font(.body)
        .controlSize(.small)
        .frame(width: 580, height: 400)
        .background(palette.content)
        .buttonStyle(.bordered)
        .alert(L10n.string("desktopDrive.writeback.confirmTitle"), isPresented: $confirmingEnable) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("desktopDrive.writeback.allow")) { changeEnabled(true) }
        } message: { Text(L10n.string("desktopDrive.writeback.confirmMessage")) }
        .alert(L10n.string("desktopDrive.writeback.retryTitle"), isPresented: Binding(
            get: { retrying != nil }, set: { if !$0 { retrying = nil } }
        )) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { retrying = nil }
            Button(L10n.string("desktopDrive.writeback.retryConfirm")) {
                if let record = retrying { retry(record) }
                retrying = nil
            }
        } message: { Text(L10n.string("desktopDrive.writeback.retryMessage")) }
        .alert(L10n.string("desktopDrive.writeback.stopTitle"), isPresented: Binding(
            get: { stopping != nil }, set: { if !$0 { stopping = nil } }
        )) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { stopping = nil }
            Button(L10n.string("desktopDrive.writeback.stop"), role: .destructive) {
                if let record = stopping { Task { await stop(record) } }
                stopping = nil
            }
        } message: { Text(L10n.string("desktopDrive.writeback.stopMessage")) }
        .task { reload() }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 19)).foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("desktopDrive.writeback.sheetTitle")).font(.title3.weight(.semibold))
                Text(mapping.displayName).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { dismiss() } label: {
                Label(L10n.string("ui.3fd47edce45b3603"), systemImage: "xmark")
                    .labelStyle(.iconOnly).font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .keyboardShortcut(.cancelAction).help(L10n.string("ui.3fd47edce45b3603"))
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    @ViewBuilder
    private var pendingContent: some View {
        if !hasLoaded {
            Group {
                if let message {
                    statusPlaceholder(symbol: "exclamationmark.circle", title: "desktopDrive.writeback.loadErrorTitle", detail: message)
                } else { ProgressView(L10n.string("desktopDrive.writeback.loading")) }
            }.fillsAvailableContentArea(alignment: .center)
        } else if records.isEmpty {
            statusPlaceholder(symbol: "checkmark.circle", title: "desktopDrive.writeback.emptyTitle",
                              detail: L10n.string("desktopDrive.writeback.empty"))
                .fillsAvailableContentArea(alignment: .center)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(records) { record in
                        recordCard(record)
                    }
                }
                .padding(1)
            }.fillsAvailableContentArea(alignment: .topLeading)
        }
    }

    private func statusPlaceholder(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(L10n.string(title)).font(.body.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
        }.padding(16)
    }

    private func recordCard(_ record: DesktopDriveWritebackRecord) -> some View {
        let isConflict = record.phase == .conflict
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.isDirectory ? "folder.fill" : "doc.text")
                .font(.system(size: 22, weight: .light)).foregroundStyle(palette.folderIcon)
                .frame(width: 32, height: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text((record.destinationPath as NSString).lastPathComponent)
                        .font(.body.weight(.semibold)).lineLimit(2).truncationMode(.middle)
                        .help((record.destinationPath as NSString).lastPathComponent)
                    Spacer(minLength: 4)
                    Label {
                        Text(L10n.string(isConflict ? "desktopDrive.writeback.statusChanged" : "desktopDrive.writeback.statusUnconfirmed"))
                    } icon: {
                        Image(systemName: isConflict ? "exclamationmark.triangle.fill" : "clock")
                            .foregroundStyle(isConflict ? Color.orange : Color.secondary)
                    }
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(isConflict ? Color.orange.opacity(0.10) : palette.card, in: Capsule())
                    .fixedSize()
                }
                Text(L10n.string(isConflict ? "desktopDrive.writeback.summaryConflict" : "desktopDrive.writeback.summaryUnknown"))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                HStack(spacing: 10) {
                    Spacer()
                    Button(L10n.string("desktopDrive.writeback.retry")) { retrying = record }
                        .buttonStyle(.borderedProminent)
                        .disabled(!enabled || !canEnable)
                    Menu {
                        if record.contentHash != nil {
                            Button(L10n.string("desktopDrive.writeback.export")) { export(record) }
                            Divider()
                        }
                        Button(L10n.string(record.contentHash == nil ? "desktopDrive.writeback.stop" : "desktopDrive.writeback.exportAndStop"), role: .destructive) {
                            stopping = record
                        }
                    } label: {
                        Label(L10n.string("desktopDrive.writeback.more"), systemImage: "ellipsis")
                            .labelStyle(.iconOnly).frame(width: 24, height: 22)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L10n.string("desktopDrive.writeback.more"))
                }.padding(.top, 2)
            }
        }
        .padding(14)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(palette.separator, lineWidth: 0.5))
    }

    private func reload() {
        do {
            enabled = try store.isEnabled(mappingID: mapping.id)
            records = try store.pendingRecords(mappingID: mapping.id)
            message = nil
            hasLoaded = true
        } catch { hasLoaded = false; message = L10n.string("desktopDrive.writeback.loadError") }
    }

    private func changeEnabled(_ value: Bool) {
        do {
            let lease = try store.lock(mappingID: mapping.id)
            defer { withExtendedLifetime(lease) {} }
            try store.setEnabled(value, mappingID: mapping.id)
            reload()
            signalChanges()
        } catch { message = L10n.string("desktopDrive.writeback.pending") }
    }

    private func retry(_ record: DesktopDriveWritebackRecord) {
        do {
            let lease = try store.lock(mappingID: mapping.id)
            defer { withExtendedLifetime(lease) {} }
            guard var current = try store.pendingRecords(mappingID: mapping.id).first(where: { $0.id == record.id }) else {
                reload(); return
            }
            current.allowOverwrite = true
            if current.phase == .conflict { current.phase = .prepared }
            // 已提交的记录仍需先回读；显式同意仅允许内容阶段在核对失败后重新保存。
            try store.save(current)
            signalChanges()
            reload()
        } catch { message = L10n.string("desktopDrive.writeback.pending") }
    }

    private func signalChanges() {
        guard let manager = NSFileProviderManager(for: DesktopDriveDomainController().domain(for: mapping)) else { return }
        manager.signalEnumerator(for: .rootContainer) { _ in }
        manager.signalEnumerator(for: .workingSet) { _ in }
        manager.signalErrorResolved(NSFileProviderError(.cannotSynchronize)) { error in
            if error != nil { Task { @MainActor in message = L10n.string("desktopDrive.writeback.loadError") } }
        }
    }

    private func export(_ record: DesktopDriveWritebackRecord) {
        Task { _ = await saveCopy(record) }
    }

    private func stop(_ record: DesktopDriveWritebackRecord) async {
        if record.contentHash != nil {
            guard await saveCopy(record) else { return }
        }
        do {
            let lease = try store.lock(mappingID: mapping.id)
            defer { withExtendedLifetime(lease) {} }
            if let current = try store.pendingRecords(mappingID: mapping.id).first(where: { $0.id == record.id }) {
                try store.keepLocally(current)
            }
            reload()
        } catch { message = L10n.string("desktopDrive.writeback.loadError") }
    }

    private func saveCopy(_ record: DesktopDriveWritebackRecord) async -> Bool {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (record.destinationPath as NSString).lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        do {
            let store = store
            try await Task.detached {
                let lease = try store.lock(mappingID: record.mappingID)
                defer { withExtendedLifetime(lease) {} }
                try FileManager.default.copyItem(at: store.contentURL(for: record), to: destination)
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }
                try handle.synchronize()
            }.value
            return true
        } catch { message = L10n.string("desktopDrive.writeback.exportError"); return false }
    }
}
