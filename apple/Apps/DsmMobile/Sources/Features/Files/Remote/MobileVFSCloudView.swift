import DsmCore
import DsmFileFeature
import DsmLocalization
import SafariServices
import SwiftUI

struct MobileVFSCloudView: View {
    @Bindable var model: MobileRemoteLocationsModel
    let protocolID: String
    let protocolName: String
    let existing: FileVFSProfile?
    var onSuccess: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var request: FileVFSCloudAuthorizationRequest?
    @State private var requestContext = ""
    @State private var session: FileVFSCloudAuthorizationSession?
    @State private var authorization: FileVFSCloudAuthorization?
    @State private var browserURL: URL?
    @State private var alias = ""
    @State private var loading = false
    @State private var attempt = UUID()
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                MobileRemoteFeedback(model: model)
                Section {
                    Text(protocolName).font(.headline)
                    if loading { ProgressView() }
                    else if let authorization {
                        LabeledContent(L10n.string("files.vfs.account"), value: authorization.account)
                        if let existing { LabeledContent(L10n.string("files.vfs.alias"), value: existing.alias) }
                        else { TextField(L10n.string("files.vfs.alias"), text: $alias) }
                    } else {
                        Text(L10n.string("files.vfs.cloudAuthorizationDetail")).foregroundStyle(.secondary)
                        Button(L10n.string("files.vfs.authorizeCloud")) { Task { await begin() } }
                            .disabled(!model.canManageVFS).accessibilityIdentifier("files.remote.cloud.start")
                    }
                }.disabled(model.busy)
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if authorization != nil {
                    Section {
                        Button(L10n.string("files.vfs.saveConnect")) { save() }
                            .disabled(!model.canManageVFS || alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("files.remote.cloud.save")
                    }
                }
            }.navigationTitle(L10n.string(existing == nil ? "files.vfs.authorizeCloud" : "files.vfs.reauthorize"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { stop(); dismiss() }.disabled(model.busy)
                } }
        }.interactiveDismissDisabled(model.busy)
            .background(MobileCloudBrowserPresenter(url: browserURL, onClose: {
                stop(); error = L10n.string("files.vfs.authorizationClosed")
            }, onRemove: { stop() }).frame(width: 0, height: 0))
            .task { if let existing, alias.isEmpty { alias = existing.alias } }
            .onChange(of: model.context) { _, _ in stop(); dismiss() }
    }
    private func begin() async {
        guard !loading, session == nil else { return }
        let token = UUID(); attempt = token
        loading = true; error = nil; authorization = nil
        defer { if token == attempt { loading = false } }
        do {
            let prepared = try await model.prepareCloud(protocolID)
            guard token == attempt, !Task.isCancelled else { return }
            request = prepared; requestContext = model.context
            let currentContext = requestContext
            let listener = FileVFSCloudAuthorizationSession(request: prepared, onAuthorization: { value in
                guard token == attempt else { return }
                session = nil; browserURL = nil
                guard currentContext == model.context, prepared.id == value.requestID,
                      prepared.profileID == value.profileID, protocolID == value.protocolID,
                      existing == nil || existing?.account == value.account else {
                    error = L10n.string("files.vfs.authorizationMismatch"); return
                }
                authorization = value
                if alias.isEmpty { alias = value.account }
            }, onFailure: { message in
                guard token == attempt else { return }
                session = nil; browserURL = nil; error = message
            })
            session = listener
            try listener.start { if token == attempt { browserURL = $0 } }
        } catch {
            guard token == attempt else { return }
            stop(); self.error = MobileRemoteLocationsModel.message(error)
        }
    }
    private func save() {
        guard let authorization, requestContext == model.context, request?.id == authorization.requestID else { return }
        let change = existing.map(FileVFSChange.reauthorize) ?? .createCloud(.init(protocolID: protocolID,
            alias: alias.trimmingCharacters(in: .whitespacesAndNewlines), account: authorization.account))
        self.authorization = nil
        Task {
            if await model.changeVFS(change, authorization: authorization) { onSuccess(); dismiss() }
        }
    }
    private func stop() {
        attempt = UUID(); loading = false
        session?.stop(); session = nil; browserURL = nil; authorization = nil; request = nil
    }
}

/// Safari 全屏会使原 SwiftUI 表单暂时消失；只在宿主被移除时结束授权，不能在 onDisappear 取消。
/// 仅宿主进入 SwiftUI 层级；Safari 使用系统模态呈现，不嵌为子控制器或读取页面内容。
private struct MobileCloudBrowserPresenter: UIViewControllerRepresentable {
    let url: URL?
    let onClose: () -> Void
    let onRemove: () -> Void
    func makeUIViewController(context: Context) -> Host { Host() }
    func updateUIViewController(_ controller: Host, context: Context) {
        controller.onClose = onClose; controller.onRemove = onRemove
        controller.requestedURL = url; controller.updatePresentation()
    }
    static func dismantleUIViewController(_ controller: Host, coordinator: ()) {
        let cleanup = controller.onRemove
        controller.onClose = nil; controller.onRemove = nil
        controller.requestedURL = nil; controller.updatePresentation()
        cleanup?()
    }
    final class Host: UIViewController, @preconcurrency SFSafariViewControllerDelegate {
        var requestedURL: URL?
        var onClose: (() -> Void)?
        var onRemove: (() -> Void)?
        private var safari: SFSafariViewController?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); updatePresentation() }
        func updatePresentation() {
            guard let url = requestedURL else {
                if let safari { safari.dismiss(animated: true); self.safari = nil }; return
            }
            guard viewIfLoaded?.window != nil, safari == nil, presentedViewController == nil else { return }
            let browser = SFSafariViewController(url: url)
            browser.delegate = self; safari = browser
            present(browser, animated: true)
        }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            guard controller === safari else { return }
            safari = nil; requestedURL = nil; onClose?()
        }
    }
}
