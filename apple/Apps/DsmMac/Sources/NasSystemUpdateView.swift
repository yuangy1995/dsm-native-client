import DsmCore
import DsmLocalization
import SwiftUI

struct NasSystemUpdateView: View {
    let model: NasSystemUpdateModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsInstallation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(L10n.string("system-update.title"), systemImage: "arrow.triangle.2.circlepath")
                    .font(.title2.bold())
                Spacer()
                Button(L10n.string("system-update.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let current = model.info?.currentVersion {
                LabeledContent(L10n.string("system-update.current-version"), value: current)
            }
            if let target = model.plan?.version ?? model.info?.latestVersion {
                LabeledContent(L10n.string("system-update.target-version"), value: target)
            }
            Divider()
            Label(title, systemImage: model.phase == .completed || model.phase == .current ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                .font(.headline).accessibilityIdentifier("system-update.phase")
            if model.shouldPoll || model.isBusy {
                if let percent = model.percent {
                    ProgressView(value: percent, total: 100) { Text(L10n.string("system-update.progress", Int(percent))) }
                } else { ProgressView().controlSize(.small) }
            }
            if model.phase == .reconnecting {
                Text(L10n.string("system-update.reconnecting-detail")).foregroundStyle(.secondary)
            } else if model.phase == .installing {
                Text(L10n.string("system-update.installing-detail")).foregroundStyle(.secondary)
            } else if model.phase == .ready && !model.canInstall {
                Text(L10n.string("system-update.use-dsm")).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let notes = model.info?.releaseNotes, !notes.isEmpty, !model.installationSubmitted {
                ScrollView { Text(notes).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 140)
            }
            HStack {
                Button(L10n.string("system-update.refresh")) { Task { await model.refresh() } }
                Spacer()
                if model.phase == .available {
                    Button(L10n.string("system-update.download")) { Task { await model.download() } }.buttonStyle(.borderedProminent)
                }
                if model.phase == .ready && model.canInstall && !model.installationSubmitted {
                    Button(L10n.string("system-update.install")) {
                        Task { confirmsInstallation = await model.prepareInstallation() }
                    }.buttonStyle(.borderedProminent)
                }
            }.disabled(model.isBusy)
        }
        .padding(24).frame(width: 520).fixedSize(horizontal: false, vertical: true)
        .task { await model.refresh() }
        .task(id: model.shouldPoll) { if model.shouldPoll { await model.monitor() } }
        .confirmationDialog(L10n.string("system-update.confirm-title"), isPresented: $confirmsInstallation, titleVisibility: .visible) {
            Button(L10n.string("system-update.install"), role: .destructive) { Task { await model.install() } }
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
        } message: { Text(L10n.string("system-update.confirm-detail", model.plan?.version ?? "")) }
    }

    private var title: String {
        switch model.phase {
        case .unchecked: L10n.string("system-update.phase.checking")
        case .current: L10n.string("system-update.phase.current")
        case .available: L10n.string("system-update.phase.available")
        case .downloading: L10n.string("system-update.phase.downloading")
        case .ready: L10n.string("system-update.phase.ready")
        case .installing: L10n.string("system-update.phase.installing")
        case .reconnecting: L10n.string("system-update.phase.reconnecting")
        case .completed: L10n.string("system-update.phase.completed")
        case .attention: L10n.string("system-update.phase.attention")
        }
    }
}
