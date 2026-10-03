import CoreImage.CIFilterBuiltins
import DsmCore
import DsmLocalization
import SwiftUI
import UIKit

struct MobileFileShareEditSelection: Identifiable {
    let id = UUID()
    let links: [FileShareLink]
    var advanced = false
}

struct MobileFileShareEditView: View {
    let links: [FileShareLink]
    let model: MobileFileShareLinkModel
    @Environment(\.dismiss) private var dismiss
    @State private var passwordMode = 0
    @State private var password = ""
    @State private var startMode = 0
    @State private var endMode = 0
    @State private var startDate = Date()
    @State private var endDate = Date()
    @State private var confirmsPasswordRemoval = false

    var body: some View {
        NavigationStack {
            Form {
                Section { ForEach(links) { Text($0.name) } }
                Section {
                    Picker(L10n.string("files.sharing.password"), selection: $passwordMode) {
                        Text(L10n.string("files.sharing.keep")).tag(0)
                        Text(L10n.string("files.sharing.setPassword")).tag(1)
                        Text(L10n.string("files.sharing.removePassword")).tag(2)
                    }.accessibilityIdentifier("sharing.edit.passwordMode")
                    if passwordMode == 1 {
                        SecureField(L10n.string("files.sharing.newPassword"), text: $password)
                            .textContentType(.newPassword).accessibilityIdentifier("sharing.edit.password")
                        if password.count > 16 { Text(L10n.string("files.sharing.passwordLength")).foregroundStyle(.red) }
                    }
                }
                Section {
                    dateMode("files.sharing.startDate", mode: $startMode, date: $startDate, clear: "files.sharing.immediate")
                    dateMode("files.sharing.endDate", mode: $endMode, date: $endDate, clear: "mobile.files.share-link.expiration.never")
                }
                if hasChanges && requests == nil { Text(L10n.string("files.sharing.checkChanges")).foregroundStyle(.red) }
            }
            .navigationTitle(L10n.string("files.sharing.edit"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.string("files.common.close")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.sharing.save")) {
                        if passwordMode == 2 { confirmsPasswordRemoval = true } else { save() }
                    }.disabled(requests == nil).accessibilityIdentifier("sharing.edit.save")
                }
            }
            .alert(L10n.string("files.sharing.removePassword"), isPresented: $confirmsPasswordRemoval) {
                Button(L10n.string("mobile.files.share-link.action.cancel"), role: .cancel) {}
                Button(L10n.string("files.sharing.save"), role: .destructive, action: save)
            } message: { Text(L10n.string("mobile.sharing.remove-password-risk")) }
        }.presentationDetents([.large])
    }

    private var hasChanges: Bool { passwordMode != 0 || startMode != 0 || endMode != 0 }
    private var requests: [FileShareLinkEditRequest]? {
        guard hasChanges else { return nil }
        return try? links.map { link in
            let start = try startMode == 2 ? model.calendarDate(startDate) : nil
            let end = try endMode == 2 ? model.calendarDate(endDate) : nil
            let originalStart = try link.availableAt.map { try FileShareLinkCalendarDate(iso8601: String($0.prefix(10))) }
            let originalEnd = try link.expiresAt.map { try FileShareLinkCalendarDate(iso8601: String($0.prefix(10))) }
            if let effectiveStart = startMode == 0 ? originalStart : start,
               let effectiveEnd = endMode == 0 ? originalEnd : end, effectiveStart > effectiveEnd {
                throw FileShareLinkContractError.invalidDateRange
            }
            return try FileShareLinkEditRequest(baseline: link,
                password: passwordMode == 0 ? .keep : passwordMode == 1 ? .set(password) : .remove,
                availableOn: start, expiresOn: end, keepsAvailableDate: startMode == 0, keepsExpirationDate: endMode == 0)
        }
    }
    private func dateMode(_ key: String, mode: Binding<Int>, date: Binding<Date>, clear: String) -> some View {
        VStack(alignment: .leading) {
            Picker(L10n.string(key), selection: mode) {
                Text(L10n.string("files.sharing.keep")).tag(0)
                Text(L10n.string(clear)).tag(1)
                Text(L10n.string("files.sharing.customDate")).tag(2)
            }
            if mode.wrappedValue == 2 { DatePicker(L10n.string(key), selection: date, displayedComponents: .date) }
        }
    }
    private func save() {
        guard let requests else { return }
        password = ""; model.editManagedLinks(requests); dismiss()
    }
}

struct MobileFileShareAdvancedView: View {
    let link: FileShareLink
    let model: MobileFileShareLinkModel
    @Environment(\.dismiss) private var dismiss
    @State private var audience = 0
    @State private var principals: Set<FileStationPrincipal> = []
    @State private var editsLimit = false
    @State private var limit = ""
    @State private var requestName = ""
    @State private var requestMessage = ""
    @State private var showsPrincipals = false
    @State private var confirmsAudience = false

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(link.name) }
                if let details = link.advanced {
                    Section {
                        LabeledContent(L10n.string("files.sharing.currentAudience"), value: audienceTitle(details.protection))
                        if !details.isFileRequest {
                            Picker(L10n.string("files.sharing.changeAudience"), selection: $audience) {
                                Text(L10n.string("files.sharing.keep")).tag(0)
                                Text(L10n.string("files.sharing.namedAudience")).tag(1)
                                Text(L10n.string("files.sharing.anyoneAudience")).tag(2)
                            }.accessibilityIdentifier("sharing.access.audience")
                            if audience == 1 {
                                ForEach(principals.sorted { $0.id < $1.id }) { principal in
                                    HStack {
                                        Label(principal.name, systemImage: principal.kind == .user ? "person" : "person.2")
                                        Spacer()
                                        Button { principals.remove(principal) } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44) }
                                            .accessibilityLabel(L10n.string("files.principals.remove"))
                                    }
                                }
                                Button(L10n.string("files.sharing.chooseAudience")) { showsPrincipals = true }
                            }
                        }
                    }
                    Section {
                        LabeledContent(L10n.string("files.sharing.currentAccessLimit"), value: details.maximumAccesses == 0
                            ? L10n.string("files.sharing.unlimitedAccess") : details.maximumAccesses.formatted(.number.locale(L10n.locale)))
                        Toggle(L10n.string("files.sharing.editAccessLimit"), isOn: $editsLimit)
                        if editsLimit {
                            TextField(L10n.string("files.sharing.accessLimit"), text: $limit).keyboardType(.numberPad)
                            Text(L10n.string("files.sharing.accessLimitHint")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if details.isFileRequest {
                        Section {
                            TextField(L10n.string("files.request.name"), text: $requestName)
                            TextField(L10n.string("files.request.message"), text: $requestMessage, axis: .vertical).lineLimit(3...6)
                        }
                    }
                }
                if model.advancedAccess?.writesEnabled != true {
                    Text(L10n.string("files.advanced.permissionUnavailable")).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(L10n.string("mobile.sharing.access-title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.string("files.common.close")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.sharing.save")) {
                        if audience != 0 { confirmsAudience = true } else { save() }
                    }.disabled(request == nil || model.advancedAccess?.writesEnabled != true).accessibilityIdentifier("sharing.access.save")
                }
            }
            .alert(L10n.string("files.sharing.accessSettings"), isPresented: $confirmsAudience) {
                Button(L10n.string("mobile.files.share-link.action.cancel"), role: .cancel) {}
                Button(L10n.string("files.sharing.save"), role: .destructive, action: save)
            } message: { Text(L10n.string(audience == 2 ? "mobile.sharing.public-risk" : "mobile.sharing.audience-risk")) }
            .sheet(isPresented: $showsPrincipals) {
                MobileFileStationPrincipalPicker(selection: $principals) { prefix, offset in
                    try await model.principals(prefix: prefix, offset: offset)
                }
            }
            .onAppear {
                guard let details = link.advanced else { return }
                principals = Set(details.users.map { .init(name: $0, kind: .user) } + details.groups.map { .init(name: $0, kind: .group) })
                limit = String(details.maximumAccesses); requestName = details.requestName; requestMessage = details.requestMessage
            }
        }.presentationDetents([.large])
    }

    private var request: FileShareLinkEditRequest? {
        guard let details = link.advanced, audience != 0 || editsLimit ||
            details.isFileRequest && (requestName != details.requestName || requestMessage != details.requestMessage),
              audience != 1 || !principals.isEmpty else { return nil }
        let count = editsLimit ? Int(limit) : nil
        if editsLimit && (count == nil || !(0...9_999).contains(count!)) { return nil }
        return try? .init(baseline: link, availableOn: nil, expiresOn: nil,
            advanced: .init(audience: audience == 0 ? .keep : audience == 2 ? .anyone : .principals(principals.sorted { $0.id < $1.id }),
                maximumAccesses: count,
                requestName: details.isFileRequest && requestName != details.requestName ? requestName : nil,
                requestMessage: details.isFileRequest && requestMessage != details.requestMessage ? requestMessage : nil),
            keepsAvailableDate: true, keepsExpirationDate: true)
    }
    private func save() { guard let request else { return }; model.editManagedLinks([request]); dismiss() }
    private func audienceTitle(_ value: FileShareAdvancedDetails.Protection) -> String {
        switch value {
        case .none: L10n.string("files.sharing.anyoneAudience")
        case .password: L10n.string("mobile.files.share-link.protected")
        case .users: L10n.string("files.sharing.namedAudience")
        }
    }
}

struct MobileFileShareQRCodeView: View {
    let link: FileShareLink
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(link.name).font(.headline)
                    if let image = Self.image(for: link.url) {
                        Image(uiImage: image).resizable().interpolation(.none).scaledToFit()
                            .frame(maxWidth: 300).padding(20).background(.white)
                            .accessibilityLabel(L10n.string("files.sharing.qr"))
                    } else { Text(L10n.string("files.sharing.qrFailed")) }
                    Text(link.url).textSelection(.enabled).font(.callout)
                }.padding().frame(maxWidth: .infinity)
            }.navigationTitle(L10n.string("files.sharing.qr"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("files.common.close")) { dismiss() } } }
        }
    }
    static func image(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(value.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
