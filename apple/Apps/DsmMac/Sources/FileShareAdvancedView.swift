import DsmCore
import DsmLocalization
import SwiftUI

struct FileShareAdvancedView: View {
    @Bindable var model: WorkspaceModel
    let link: FileShareLink
    let onClose: () -> Void
    @State private var audienceMode = 0
    @State private var principals = Set<FileStationPrincipal>()
    @State private var editsLimit = false
    @State private var limit = ""
    @State private var requestName = ""
    @State private var requestMessage = ""
    @State private var showsPrincipals = false
    @State private var confirmsChange = false
    @State private var submitted = false
    @State private var access: FileStationAdvancedAccess?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("files.sharing.accessSettings")).font(.title2.bold())
            Text(link.name).font(.headline)
            Text(link.path).foregroundStyle(.secondary).lineLimit(2)
            if let details = link.advanced {
                ScrollView {
                    Form {
                        LabeledContent(L10n.string("files.sharing.currentAudience"), value: audienceTitle(details.protection))
                        if !details.users.isEmpty { Text(details.users.joined(separator: ", ")) }
                        if !details.groups.isEmpty { Text(details.groups.joined(separator: ", ")) }
                        if !details.isFileRequest {
                            Picker(L10n.string("files.sharing.changeAudience"), selection: $audienceMode) {
                                Text(L10n.string("files.sharing.keep")).tag(0)
                                Text(L10n.string("files.sharing.namedAudience")).tag(1)
                                Text(L10n.string("files.sharing.anyoneAudience")).tag(2)
                            }
                            if audienceMode == 1 {
                                ForEach(principals.sorted { $0.id < $1.id }) { principal in
                                    HStack {
                                        Label(principal.name, systemImage: principal.kind == .user ? "person" : "person.2")
                                        Spacer()
                                        Button { principals.remove(principal) } label: {
                                            Label(L10n.string("files.principals.remove"), systemImage: "minus.circle")
                                        }.labelStyle(.iconOnly)
                                    }
                                }
                                Button(L10n.string("files.sharing.chooseAudience")) { showsPrincipals = true }
                            }
                            if audienceMode == 2 {
                                Text(L10n.string("files.sharing.audienceRisk")).foregroundStyle(.orange)
                            }
                        }
                        LabeledContent(L10n.string("files.sharing.currentAccessLimit"), value: details.maximumAccesses == 0
                            ? L10n.string("files.sharing.unlimitedAccess") : details.maximumAccesses.formatted(.number.locale(L10n.locale)))
                        Toggle(L10n.string("files.sharing.editAccessLimit"), isOn: $editsLimit)
                        if editsLimit {
                            TextField(L10n.string("files.sharing.accessLimit"), text: $limit)
                            Text(L10n.string("files.sharing.accessLimitHint")).font(.caption).foregroundStyle(.secondary)
                        }
                        if details.isFileRequest {
                            TextField(L10n.string("files.request.name"), text: $requestName)
                            TextField(L10n.string("files.request.message"), text: $requestMessage, axis: .vertical).lineLimit(3...5)
                        }
                        if audienceMode != 0 {
                            Toggle(L10n.string(audienceMode == 2 ? "files.sharing.confirmPublicAccess" : "files.sharing.confirmAccessChange"), isOn: $confirmsChange)
                        }
                    }.disabled(access?.writesEnabled != true || submitted)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            if submitted {
                ForEach(model.shareManagementResults) { item in Text(item.message) }
            }
            HStack {
                if model.isManagingShareLinks { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.string("files.common.close"), action: onClose).keyboardShortcut(.cancelAction).disabled(model.isManagingShareLinks)
                if !submitted {
                    Button(L10n.string("files.sharing.save")) {
                        guard let request else { return }
                        submitted = true
                        Task { await model.editShareLinks([request]) }
                    }.buttonStyle(.borderedProminent)
                        .disabled((audienceMode != 0 && !confirmsChange) || request == nil || access?.writesEnabled != true || model.isManagingShareLinks)
                }
            }
        }.padding(24).frame(width: 570, height: 580)
            .interactiveDismissDisabled(model.isManagingShareLinks)
            .task {
                if let details = link.advanced {
                    principals = Set(details.users.map { .init(name: $0, kind: .user) } + details.groups.map { .init(name: $0, kind: .group) })
                    limit = String(details.maximumAccesses); requestName = details.requestName; requestMessage = details.requestMessage
                }
                do { access = try await model.loadFileStationAdvancedAccess() }
                catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.advanced.readFailed") }
            }
            .onChange(of: audienceMode) { _, _ in confirmsChange = false }
            .onChange(of: principals) { _, _ in confirmsChange = false }
            .macSheet(isPresented: $showsPrincipals) {
                FileStationPrincipalPicker(model: model, selection: $principals) { showsPrincipals = false }
            }
    }

    private var hasChanges: Bool {
        audienceMode != 0 || editsLimit || (link.advanced?.isFileRequest == true &&
            (requestName != link.advanced?.requestName || requestMessage != link.advanced?.requestMessage))
    }
    private var request: FileShareLinkEditRequest? {
        guard hasChanges, let details = link.advanced,
              audienceMode != 1 || !principals.isEmpty else { return nil }
        let count = editsLimit ? Int(limit) : nil
        if editsLimit && (count == nil || !(0...9_999).contains(count!)) { return nil }
        let audience: FileShareAdvancedChange.Audience = audienceMode == 0 ? .keep
            : audienceMode == 1 ? .principals(principals.sorted { $0.id < $1.id }) : .anyone
        return try? .init(baseline: link, availableOn: nil, expiresOn: nil,
            advanced: .init(audience: audience, maximumAccesses: count,
                requestName: details.isFileRequest && requestName != details.requestName ? requestName : nil,
                requestMessage: details.isFileRequest && requestMessage != details.requestMessage ? requestMessage : nil),
            keepsAvailableDate: true, keepsExpirationDate: true)
    }
    private func audienceTitle(_ protection: FileShareAdvancedDetails.Protection) -> String {
        switch protection {
        case .none: L10n.string("files.sharing.anyoneAudience")
        case .password: L10n.string("ui.8aa0da83b66e54f0")
        case .users: L10n.string("files.sharing.namedAudience")
        }
    }
}
