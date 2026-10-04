import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI
import UIKit

struct MobilePhotoSharingForm: View {
    @Bindable var sharing: MobilePhotoSharingModel
    let draft: MobilePhotoSharingModel.Draft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(draft.album.name).font(.headline) }
                if sharing.isLoading { ProgressView(L10n.string("mobile.photos.sharing.loading")).accessibilityIdentifier("mobile.photos.sharing.loading") }
                else if let error = sharing.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if sharing.original?.isTemporary != true { Button(L10n.string("photos.retry")) { sharing.load() } }
                    }
                } else if let original = sharing.original {
                    Section {
                        Picker(L10n.string("photos.manage.linkAccess"), selection: $sharing.access) {
                            ForEach(SynologyPhotoLinkAccess.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                        }.accessibilityIdentifier("mobile.photos.sharing.access")
                        if sharing.access == .invited { Text(L10n.string("photos.sharing.invitedHint")).foregroundStyle(.secondary) }
                        if let url = original.url { MobilePhotoSharingLink(url: url) }
                    }
                    Section {
                        if original.hasPassword == true { Label(L10n.string("photos.sharing.passwordProtected"), systemImage: "lock.fill") }
                        Picker(L10n.string("photos.sharing.password"), selection: $sharing.password.choice) {
                            Text(L10n.string("photos.sharing.passwordKeep")).tag(PhotoSharingPasswordDraft.Choice.unchanged)
                            Text(L10n.string("photos.sharing.passwordSet")).tag(PhotoSharingPasswordDraft.Choice.newPassword)
                            Text(L10n.string("photos.sharing.passwordRemove")).tag(PhotoSharingPasswordDraft.Choice.remove)
                        }.accessibilityIdentifier("mobile.photos.sharing.passwordChoice")
                        if sharing.password.choice == .newPassword {
                            SecureField(L10n.string("photos.sharing.passwordPlaceholder"), text: $sharing.password.password)
                                .textContentType(.newPassword).autocorrectionDisabled().textInputAutocapitalization(.never)
                                .accessibilityIdentifier("mobile.photos.sharing.password")
                        }
                    }
                    Section {
                        Picker(L10n.string("photos.sharing.expiration"), selection: Binding(get: { sharing.expiration.choice }, set: {
                            sharing.expiration.choice = $0; sharing.expiration.edited = true
                        })) {
                            if original.expiration == nil { Text(L10n.string("photos.sharing.expirationKeep")).tag(PhotoSharingExpirationDraft.Choice.unchanged) }
                            Text(L10n.string("photos.sharing.expirationUnlimited")).tag(PhotoSharingExpirationDraft.Choice.unlimited)
                            Text(L10n.string("photos.sharing.expirationDate")).tag(PhotoSharingExpirationDraft.Choice.date)
                        }.accessibilityIdentifier("mobile.photos.sharing.expiration")
                        if sharing.expiration.choice == .date {
                            DatePicker(L10n.string("photos.sharing.expirationDate"), selection: Binding(get: { sharing.expiration.date }, set: {
                                sharing.expiration.date = $0; sharing.expiration.edited = true
                            }), displayedComponents: .date)
                            if !sharing.expiration.isValid { Text(L10n.string("photos.sharing.expirationPast")).foregroundStyle(.red) }
                        }
                    }
                    Section(L10n.string("photos.sharing.members")) {
                        if original.members == nil { Text(L10n.string("photos.sharing.membersUnreadable")) }
                        else {
                            if sharing.members.isEmpty { Text(L10n.string("photos.sharing.noMembers")).foregroundStyle(.secondary) }
                            ForEach($sharing.members) { $member in
                                VStack(alignment: .leading) {
                                    Label(member.recipient.name, systemImage: member.id.type == "group" ? "person.2" : "person")
                                    HStack {
                                        Picker(L10n.string("photos.sharing.role"), selection: $member.role) {
                                            if !sharing.roles.contains(member.role) { Text(member.role).tag(member.role) }
                                            ForEach(sharing.roles, id: \.self) { Text(Self.roleTitle($0)).tag($0) }
                                        }
                                        Button(role: .destructive) { sharing.members.removeAll { $0.id == member.id } } label: {
                                            Image(systemName: "minus.circle")
                                        }.frame(minWidth: 44, minHeight: 44).buttonStyle(.borderless)
                                            .accessibilityLabel(L10n.string("photos.sharing.removeMember", member.recipient.name))
                                    }
                                }
                            }
                            NavigationLink(L10n.string("photos.sharing.chooseMember")) { MobilePhotoShareRecipientPicker(sharing: sharing) }
                                .accessibilityIdentifier("mobile.photos.sharing.members")
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("photos.manage.sharing"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.delete.cancel")) { sharing.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.photos.album.save")) { if sharing.requestSave() { dismiss() } }
                        .disabled(sharing.mutation == nil).accessibilityIdentifier("mobile.photos.sharing.save")
                }
            }
            .alert(L10n.string("mobile.photos.sharing.confirm"), isPresented: $sharing.showsConfirmation) {
                Button(L10n.string("photos.delete.cancel"), role: .cancel) { sharing.cancelConfirmation() }
                Button(L10n.string("mobile.photos.album.save")) { if sharing.confirmSave() { dismiss() } }
                    .accessibilityIdentifier("mobile.photos.sharing.confirm")
            } message: {
                Text(sharing.confirmationRisks.map(\.message).joined(separator: "\n\n"))
            }
        }
    }

    static func title(_ access: SynologyPhotoLinkAccess) -> String {
        switch access {
        case .disabled: L10n.string("photos.manage.link.disabled")
        case .invited: L10n.string("photos.sharing.invited")
        case .view: L10n.string("photos.manage.link.view")
        case .download: L10n.string("photos.manage.link.download")
        }
    }
    static func roleTitle(_ role: String) -> String {
        switch role {
        case "view": L10n.string("photos.sharing.role.view")
        case "download": L10n.string("photos.sharing.role.download")
        case "upload": L10n.string("photos.sharing.role.upload")
        default: role
        }
    }
}

private struct MobilePhotoShareRecipientPicker: View {
    @Bindable var sharing: MobilePhotoSharingModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if sharing.loadingRecipients { ProgressView(L10n.string("mobile.photos.sharing.loadingMembers")) }
            else if let error = sharing.recipientError {
                Text(error).foregroundStyle(.red)
                Button(L10n.string("photos.retry")) { sharing.loadRecipients() }
            } else {
                if sharing.availableRecipients.isEmpty { Text(L10n.string("photos.sharing.noAvailableMembers")) }
                ForEach(sharing.availableRecipients) { recipient in
                    Button { sharing.add(recipient); dismiss() } label: {
                        Label(recipient.name, systemImage: recipient.id.type == "group" ? "person.2" : "person")
                            .frame(minHeight: 44)
                    }
                }
            }
        }.searchable(text: $sharing.search, prompt: L10n.string("photos.sharing.searchMembers"))
            .navigationTitle(L10n.string("photos.sharing.chooseMember"))
    }
}

struct MobilePhotoSharingLink: View {
    let url: URL
    var body: some View {
        HStack {
            ShareLink(item: url) { Label(L10n.string("mobile.photos.sharing.sendLink"), systemImage: "square.and.arrow.up") }
                .accessibilityIdentifier("mobile.photos.sharing.sendLink")
            Button { UIPasteboard.general.url = url } label: {
                Label(L10n.string("photos.sharing.copyLink"), systemImage: "link")
            }.accessibilityIdentifier("mobile.photos.sharing.copyLink")
        }.buttonStyle(.bordered).frame(minHeight: 44)
    }
}
