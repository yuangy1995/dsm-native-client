import AppKit
import DsmCore
import DsmLocalization
import SwiftUI

struct FileVFSCloudConnectionView: View {
    let model: WorkspaceModel
    let protocolID: String
    let protocolName: String
    let existing: FileVFSProfile?
    var onSuccess: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var request: FileVFSCloudAuthorizationRequest?
    @State private var browserRequest: FileVFSCloudAuthorizationRequest?
    @State private var authorization: FileVFSCloudAuthorization?
    @State private var alias = ""
    @State private var loading = true
    @State private var busy = false
    @State private var error: String?
    @State private var submitted: FileVFSChange?
    @State private var result: MutationResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? L10n.string("files.vfs.authorizeCloud") : L10n.string("files.vfs.reauthorize")).font(.title2.bold())
            Text(protocolName).font(.headline)
            if loading { ProgressView().fillsAvailableContentArea() }
            else if let authorization {
                LabeledContent(L10n.string("files.vfs.account"), value: authorization.account)
                if let existing { LabeledContent(L10n.string("files.vfs.alias"), value: existing.alias) }
                else { TextField(L10n.string("files.vfs.alias"), text: $alias) }
            } else if result == nil {
                Text(L10n.string("files.vfs.cloudAuthorizationDetail")).fixedSize(horizontal: false, vertical: true)
                Button(L10n.string("files.vfs.authorizeCloud")) {
                    if let request { browserRequest = request }
                    else { Task { await prepare() } }
                }.disabled(busy)
            }
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let result { FileVFSResultView(result: result) }
            Spacer()
            HStack {
                Button(L10n.string("files.common.close")) { authorization = nil; dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel(L10n.string(result?.requiresRefresh == true ? "files.vfs.checkingConnection" : "files.vfs.savingConnect"))
                        .accessibilityIdentifier("files.vfs.saveProgress")
                    Text(L10n.string(result?.requiresRefresh == true ? "files.vfs.checkingConnection" : "files.vfs.savingConnect"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                if result?.requiresRefresh == true {
                    Button(L10n.string("files.permissions.review")) { Task { await save(review: true) } }.disabled(busy)
                } else if authorization != nil {
                    Button(L10n.string("files.vfs.saveConnect")) { Task { await save(review: false) } }
                        .buttonStyle(.borderedProminent).disabled(busy || submitted != nil || alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else if !loading && result == nil {
                    Button(L10n.string("files.sharing.refresh")) { Task { await prepare() } }.disabled(busy)
                }
            }
        }.padding(24).frame(width: 560, height: 390)
            .task { alias = existing?.alias ?? ""; await prepare() }
            .onDisappear { authorization = nil; request = nil; browserRequest = nil }
            .sheet(item: $browserRequest) { request in
                FileVFSCloudBrowserSheet(request: request) { value in
                    browserRequest = nil
                    guard value.profileID == request.profileID, value.protocolID == protocolID,
                          existing == nil || existing?.account == value.account else {
                        error = L10n.string("files.vfs.authorizationMismatch"); return
                    }
                    authorization = value; error = nil
                    if alias.isEmpty { alias = value.account }
                }
            }
    }

    private func prepare() async {
        guard !busy else { return }; loading = true; error = nil; defer { loading = false }
        do { request = try await model.prepareFileVFSCloudAuthorization(protocolID: protocolID) }
        catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.vfs.authorizationFailed") }
    }

    private func save(review: Bool) async {
        guard !busy else { return }; busy = true; error = nil; defer { busy = false; authorization = nil }
        do {
            if review, let submitted { result = try await model.changeFileVFS(submitted, review: true) }
            else if let authorization {
                let change = existing.map(FileVFSChange.reauthorize) ?? .createCloud(.init(protocolID: protocolID, alias: alias, account: authorization.account))
                submitted = change
                result = try await model.authorizeFileVFS(change, authorization: authorization)
            }
            if result?.status == .confirmedSuccess { onSuccess(); dismiss() }
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.vfs.connection-failed") }
    }
}

private struct FileVFSCloudBrowserSheet: View {
    let request: FileVFSCloudAuthorizationRequest
    let onAuthorization: (FileVFSCloudAuthorization) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var session: FileVFSCloudAuthorizationSession?
    @State private var error: String?
    var body: some View {
        VStack(spacing: 20) {
            Text(L10n.string("files.vfs.authorizeCloud")).font(.title2.bold())
            Image(systemName: "network").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(L10n.string("files.vfs.browserAuthorizationWaiting")).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L10n.string("files.common.close")) { session?.stop(); dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.string("files.vfs.openBrowser")) {
                    if let url = session?.loginURL { NSWorkspace.shared.open(url) }
                }.disabled(session?.loginURL == nil)
            }
        }.padding(24).frame(width: 520, height: 310)
            .task {
                let value = FileVFSCloudAuthorizationSession(request: request, onAuthorization: onAuthorization,
                    onFailure: { error = $0 })
                session = value
                do { try value.start { url in if !NSWorkspace.shared.open(url) { error = L10n.string("files.vfs.authorizationFailed") } } }
                catch { self.error = L10n.string("files.vfs.authorizationFailed") }
            }
            .onDisappear { session?.stop(); session = nil }
    }
}
