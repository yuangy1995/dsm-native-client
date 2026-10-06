import DsmCore
import DsmLocalization
import SwiftUI

struct MobilePackageControlScreen: View {
    @Bindable var model: MobilePackageCenterModel
    let source: NasPackage
    @Environment(\.dismiss) private var dismiss
    @State private var prompt: MobilePackageControlPrompt?
    @State private var confirmed: MobilePackageControlPrompt?
    private var current: NasPackage? { model.installed.first { $0.id == source.id } }
    var body: some View {
        List {
            if model.section(.installed).phase != .empty { MobilePackageReadStatus(model: model, page: .installed) }
            if let package = current {
                Section {
                    LabeledContent(L10n.string("mobile.package.status"), value: package.mobilePackageStatus)
                        .accessibilityIdentifier("mobile.package.detail.status")
                    if let version = package.version { LabeledContent(L10n.string("package.center.installed-version"), value: version) }
                    if let date = package.installedAt {
                        LabeledContent(L10n.string("mobile.package.installedAt"), value: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
                    }
                    if let description = package.packageDescription, !description.isEmpty { Text(description) }
                }
                Section {
                    if package.canStart { actionButton(.start, package) }
                    if package.canStop { actionButton(.stop, package) }
                    if package.canUninstall { actionButton(.uninstall, package) }
                    if !model.supportedActions.contains(where: package.allowsControl) {
                        Text(L10n.string("mobile.package.controlUnavailable"))
                    }
                }
            } else if [.content, .empty].contains(model.section(.installed).phase) {
                Section { ContentUnavailableView(L10n.string("mobile.package.notInstalled"), systemImage: "shippingbox",
                    description: Text(L10n.string("mobile.package.returnToList"))).accessibilityIdentifier("mobile.package.detail.removed") }
            }
            MobilePackageActivitySection(model: model)
        }
        .listStyle(.insetGrouped).accessibilityIdentifier("mobile.package.detail")
        .navigationTitle(source.name).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { Task { await model.refresh(.installed) } } label: { Label(L10n.string("package.center.refresh"), systemImage: "arrow.clockwise") }
                .disabled(model.isOperating || model.isRefreshing).accessibilityIdentifier("mobile.package.detail.refresh")
        } }
        .refreshable { await model.refresh(.installed) }.task(id: model.activation) { await model.loadIfNeeded(.installed) }
        .onDisappear { model.cancelRead(.installed) }
        .onChange(of: model.activation) { _, _ in prompt = nil; confirmed = nil; dismiss() }
        .sheet(item: $prompt, onDismiss: {
            if let confirmed {
                model.performControl(confirmed.package, action: confirmed.action, activation: confirmed.activation)
                self.confirmed = nil
            }
        }) { value in
            MobilePackageControlConfirmation(model: model, source: value,
                cancel: { prompt = nil }, confirm: { confirmed = value; prompt = nil })
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
    private func actionButton(_ action: NasPackageAction, _ package: NasPackage) -> some View {
        Button(action.mobileControlTitle, role: action == .uninstall ? .destructive : nil) {
            prompt = .init(package: package, action: action, activation: model.activation)
        }.disabled(!model.canControl(package, action: action)).accessibilityIdentifier("mobile.package.action.\(action.rawValue)")
    }
}

private struct MobilePackageControlPrompt: Identifiable {
    let id = UUID()
    let package: NasPackage
    let action: NasPackageAction
    let activation: UUID
}

private struct MobilePackageControlConfirmation: View {
    @Bindable var model: MobilePackageCenterModel
    let source: MobilePackageControlPrompt
    let cancel: () -> Void
    let confirm: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(source.package.name).font(.headline)
                    if let version = source.package.version { LabeledContent(L10n.string("package.center.installed-version"), value: version) }
                    Text(source.action.mobileControlRisk)
                }
            }
            .accessibilityIdentifier("mobile.package.control.confirmation")
            .navigationTitle(source.action.mobileControlTitle).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.nas.service.cancel"), action: cancel).accessibilityIdentifier("mobile.package.control.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(source.action.mobileControlTitle, role: source.action == .uninstall ? .destructive : nil, action: confirm)
                        .disabled(source.activation != model.activation || !model.canControl(source.package, action: source.action))
                        .accessibilityIdentifier("mobile.package.control.confirm")
                }
            }
            .fillsAvailableContentArea(alignment: .topLeading)
        }
    }
}

extension NasPackageAction {
    var mobileControlTitle: String {
        let key = switch self { case .start: "mobile.package.action.start"; case .stop: "mobile.package.action.stop"; case .uninstall: "mobile.package.action.uninstall"; case .upgrade: "package.center.update" }
        return L10n.string(key)
    }
    var mobileControlRisk: String {
        let key = switch self { case .start: "mobile.package.risk.start"; case .stop: "mobile.package.risk.stop"; case .uninstall: "mobile.package.risk.uninstall"; case .upgrade: "package.center.automatic-warning" }
        return L10n.string(key)
    }
}
