import DsmCore
import DsmLocalization
import Foundation
import SwiftUI

@MainActor
struct RemoteMountRecoveryView: View {
    @Bindable var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var password = ""
    @State private var confirmedOperation: RemoteMountOperation?
    @State private var abandoningOperation: RemoteMountOperation?
    @State private var actionTask: Task<Void, Never>?
    @State private var actionGeneration = UUID()
    private var selected: RemoteMountOperation? {
        model.remoteMountOperations.first { $0.id == selection } ?? model.remoteMountOperations.first
    }
    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("remote-mount.recovery.title")).font(.title2.bold())
            if model.isManagingRemoteMount { ProgressView().controlSize(.small) }
            if let operation = selected {
                Picker(L10n.string("remote-mount.recovery.selection"), selection: $selection) {
                    ForEach(model.remoteMountOperations) { item in Text(item.mountPoint).tag(Optional(item.id)) }
                }
                .disabled(model.isManagingRemoteMount)
                Text(L10n.string(WorkspaceModel.remoteMountStageResourceKey(operation.stage)))
                Text(L10n.string("remote-mount.recovery.session-limit")).font(.caption).foregroundStyle(.secondary)
                if let baseline = operation.baseline {
                    Text(L10n.string("remote-mount.previous.identity", baseline.mountPoint, baseline.source)).font(.callout)
                }
                if let setup = operation.setup {
                    Text(L10n.string("remote-mount.recovery.destination", setup.mountPoint, setup.server, setup.remotePath)).font(.callout)
                    if setup.protocolType == .smb {
                        Text(L10n.string("remote-mount.recovery.account",
                            setup.username.isEmpty ? L10n.string("remote-mount.recovery.unset") : setup.username,
                            setup.domain.isEmpty ? L10n.string("remote-mount.recovery.unset") : setup.domain)).font(.callout)
                    } else {
                        Text(L10n.string("remote-mount.recovery.nfs-options",
                            L10n.string(setup.nfsVersion == .v3 ? "remote-mount.nfs3" : "remote-mount.nfs4"),
                            L10n.string(setup.nfsTransport == .tcp ? "remote-mount.tcp" : "remote-mount.udp"))).font(.callout)
                    }
                }
                if operation.stage == .readyToConnect && operation.setup?.protocolType == .smb {
                    SecureField(L10n.string("ui.a621ab606db2a11f"), text: $password).disabled(model.isManagingRemoteMount)
                    Text(L10n.string("remote-mount.recovery.password")).font(.caption).foregroundStyle(.secondary)
                }
                if operation.stage.canContinue {
                    Toggle(L10n.string("remote-mount.confirm"), isOn: Binding(
                        get: { confirmedOperation == operation }, set: { confirmedOperation = $0 ? operation : nil }
                    )).disabled(model.isManagingRemoteMount)
                }
                HStack {
                    if operation.stage.requiresReview {
                        Button(L10n.string("remote-mount.recovery.check")) {
                            clearConfirmation()
                            perform { await model.reviewRemoteMountOperation(operation) }
                        }.disabled(model.isManagingRemoteMount)
                    }
                    if operation.stage.canContinue {
                        Button(L10n.string(operation.stage == .readyToConnect ? "remote-mount.recovery.connect" : "remote-mount.recovery.disconnect")) {
                            guard confirmedOperation == operation else { return }
                            let enteredPassword = password; clearConfirmation()
                            perform { await model.continueRemoteMountOperation(operation, password: enteredPassword, confirmed: true) }
                        }.disabled(model.isManagingRemoteMount || confirmedOperation != operation).buttonStyle(.borderedProminent)
                        Button(L10n.string("remote-mount.recovery.stop")) { abandoningOperation = operation }.disabled(model.isManagingRemoteMount)
                    }
                }
            } else {
                Text(L10n.string("remote-mount.recovery.empty"))
            }
            if let message = model.statusMessage, model.statusIsError || selected == nil {
                Text(message).font(.callout).foregroundStyle(model.statusIsError ? Color.red : Color.secondary)
            }
            HStack {
                Spacer()
                Button(L10n.string("remote-mount.recovery.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
          }.padding(24)
        }
        .frame(width: 560).frame(maxHeight: 600)
        .task {
            await model.refreshRemoteMountOperations()
            guard !Task.isCancelled else { return }
            selection = selected?.id
        }
        .onChange(of: selection) { _, _ in clearConfirmation() }
        .onChange(of: password) { _, _ in confirmedOperation = nil }
        .onChange(of: model.remoteMountOperations) { _, _ in clearConfirmation(); selection = selected?.id }
        .onDisappear { clearConfirmation(); actionGeneration = UUID(); actionTask?.cancel(); actionTask = nil }
        .alert(L10n.string("remote-mount.recovery.stop"), isPresented: Binding(
            get: { abandoningOperation != nil }, set: { if !$0 { abandoningOperation = nil } }
        )) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { abandoningOperation = nil }
            Button(L10n.string("remote-mount.recovery.stop"), role: .destructive) {
                guard let operation = abandoningOperation else { return }
                abandoningOperation = nil; clearConfirmation()
                perform { await model.abandonRemoteMountOperation(operation, confirmed: true) }
            }
        } message: { Text(L10n.string("remote-mount.recovery.stop-warning")) }
    }
    private func clearConfirmation() { password = ""; confirmedOperation = nil }
    private func perform(_ action: @escaping @MainActor () async -> Void) {
        guard actionTask == nil else { return }
        let generation = UUID(); actionGeneration = generation
        actionTask = Task {
            await action()
            if generation == actionGeneration { actionTask = nil }
        }
    }
}
