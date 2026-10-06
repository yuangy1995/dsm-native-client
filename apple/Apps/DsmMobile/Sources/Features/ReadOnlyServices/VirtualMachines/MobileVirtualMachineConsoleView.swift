import DsmCore
import DsmLocalization
import DsmVirtualMachineConsoleFeature
import SwiftUI

struct MobileVirtualMachineConsoleRequest: Identifiable {
    let id = UUID()
    let target: VirtualMachineControlState
    let activation: UUID
}

struct MobileVirtualMachineConsoleView: View {
    @Bindable var model: MobileVirtualMachineControlModel
    let request: MobileVirtualMachineConsoleRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var session: VirtualMachineConsoleSession?
    @State private var attempt = UUID()
    @State private var loading = true
    @State private var interrupted = false
    @State private var failure: MobileVirtualMachineControlModel.Failure?

    var body: some View {
        NavigationStack {
            Group {
                if let session {
                    VirtualMachineConsoleView(session: session).id(session.id)
                } else if loading {
                    ProgressView(L10n.string("virtual-machine.console.connecting"))
                        .accessibilityIdentifier("virtual-machine.console.preparing")
                } else {
                    ContentUnavailableView {
                        Label(L10n.string("mobile.virtual-machines.console.title"), systemImage: "display.trianglebadge.exclamationmark")
                    } description: {
                        Text(L10n.string(errorKey))
                    }
                    .accessibilityIdentifier("virtual-machine.console.preparation-error")
                }
            }
            .fillsAvailableContentArea()
            .navigationTitle(request.target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.virtual-machines.console.close")) { stop(); dismiss() }
                        .accessibilityIdentifier("virtual-machine.console.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.string("mobile.virtual-machines.console.reconnect")) {
                        stop(); interrupted = false; loading = true; failure = nil; attempt = UUID()
                    }
                    .disabled(loading || scenePhase != .active || request.activation != model.activation)
                    .accessibilityIdentifier("virtual-machine.console.reconnect")
                }
            }
        }
        .task(id: attempt) {
            do {
                let result = try await model.openConsole(request.target, activation: request.activation)
                guard !Task.isCancelled, !interrupted else { await result.transport.close(); return }
                session = result; loading = false
            } catch {
                guard !Task.isCancelled, !interrupted else { return }
                loading = false; failure = MobileVirtualMachineControlModel.failure(error)
            }
        }
        .onChange(of: model.activation) { _, _ in stop(); dismiss() }
        .onChange(of: model.consoleSession) { old, current in
            if old != nil && current == nil && session != nil { session = nil; loading = false; interrupted = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stop(); interrupted = true; loading = false }
        }
        .onDisappear { stop() }
    }

    private var errorKey: String {
        if interrupted { return "virtual-machine.console.disconnected" }
        return switch failure {
        case .denied: "mobile.virtual-machines.control.error.denied"
        case .trust: "mobile.virtual-machines.control.error.trust"
        case .changed: "mobile.virtual-machines.control.error.changed"
        case .unavailable: "mobile.virtual-machines.control.error.unavailable"
        default: "virtual-machine.console.failed"
        }
    }
    private func stop() { session = nil; model.closeConsole() }
}
