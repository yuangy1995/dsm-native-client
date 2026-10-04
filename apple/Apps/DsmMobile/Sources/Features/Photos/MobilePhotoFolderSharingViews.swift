import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI

struct MobilePhotoFolderSharingForm: View {
    @Bindable var sharing: MobilePhotoFolderSharingModel
    let draft: MobilePhotoFolderSharingModel.Draft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if sharing.isLoading { ProgressView(L10n.string("mobile.photos.sharing.loading")) }
                else if let error = sharing.error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { sharing.load() } }
                } else if let original = sharing.original {
                    Form {
                        Section { Text(draft.folder.name).font(.headline) }
                        Section {
                            Picker(L10n.string("photos.manage.linkAccess"), selection: $sharing.access) {
                                ForEach(SynologyPhotoFolderSharingState.Access.allCases, id: \.self) { Text(accessTitle($0)).tag($0) }
                            }.disabled(!sharing.editable).accessibilityIdentifier("mobile.photos.folderSharing.access")
                            if original.inheritsManagementOnly { Text(L10n.string("photos.folderSharing.parentRestricted")) }
                            MobilePhotoSharingLink(url: original.url)
                        }
                        Section {
                            LabeledContent(L10n.string("photos.sharing.password"), value: L10n.string(original.hasPassword == true ? "photos.folderSharing.protected" : original.hasPassword == false ? "photos.folderSharing.unprotected" : "photos.folderSharing.unknown"))
                            if sharing.supportsEditing {
                                Picker(L10n.string("photos.sharing.password"), selection: $sharing.password.choice) {
                                    Text(L10n.string("photos.sharing.passwordKeep")).tag(PhotoSharingPasswordDraft.Choice.unchanged)
                                    Text(L10n.string("photos.sharing.passwordSet")).tag(PhotoSharingPasswordDraft.Choice.newPassword)
                                    Text(L10n.string("photos.sharing.passwordRemove")).tag(PhotoSharingPasswordDraft.Choice.remove)
                                }.accessibilityIdentifier("mobile.photos.folderSharing.passwordChoice")
                                if sharing.password.choice == .newPassword {
                                    SecureField(L10n.string("photos.sharing.passwordPlaceholder"), text: $sharing.password.password)
                                        .textContentType(.newPassword).autocorrectionDisabled().textInputAutocapitalization(.never)
                                        .accessibilityIdentifier("mobile.photos.folderSharing.password")
                                }
                            }
                        }.disabled(!sharing.editable)
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
                                                ForEach(sharing.roles, id: \.self) { Text(roleTitle($0)).tag($0) }
                                            }
                                            Button(role: .destructive) { sharing.members.removeAll { $0.id == member.id } } label: { Image(systemName: "minus.circle") }
                                                .frame(minWidth: 44, minHeight: 44).buttonStyle(.borderless)
                                                .accessibilityLabel(L10n.string("photos.sharing.removeMember", member.recipient.name))
                                        }
                                    }
                                }
                                if sharing.supportsEditing {
                                    NavigationLink(L10n.string("photos.sharing.chooseMember")) { recipientPicker }
                                        .accessibilityIdentifier("mobile.photos.folderSharing.members")
                                }
                            }
                        }.disabled(!sharing.editable)
                        if original.depth == 1 {
                            Section {
                                Toggle(L10n.string("photos.folderSharing.apply"), isOn: $sharing.appliesToSubfolders)
                                    .accessibilityIdentifier("mobile.photos.folderSharing.apply")
                            }.disabled(!sharing.editable)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(L10n.string("photos.folderSharing.title")).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.string("photos.delete.cancel")) { sharing.cancel(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("mobile.photos.edit.save")) { if sharing.save() { dismiss() } }
                            .disabled(sharing.mutation == nil).accessibilityIdentifier("mobile.photos.folderSharing.save")
                    }
                }
                .alert(L10n.string("photos.folderSharing.confirmTitle"), isPresented: $sharing.showsConfirmation) {
                    Button(L10n.string("photos.delete.cancel"), role: .cancel) { sharing.cancelConfirmation() }
                    Button(L10n.string("photos.folderSharing.save")) { if sharing.confirmSave() { dismiss() } }
                        .accessibilityIdentifier("mobile.photos.folderSharing.confirm")
                } message: {
                    Text(L10n.string(sharing.appliesToSubfolders ? "photos.folderSharing.confirmChildren" : "photos.folderSharing.confirm", draft.folder.name))
                }
        }
    }

    private var recipientPicker: some View {
        List {
            if sharing.loadingRecipients { ProgressView(L10n.string("mobile.photos.sharing.loadingMembers")) }
            else if let error = sharing.recipientError {
                Text(error).foregroundStyle(.red)
                Button(L10n.string("photos.retry")) { sharing.loadRecipients() }
            } else {
                if sharing.availableRecipients.isEmpty { Text(L10n.string("photos.sharing.noAvailableMembers")) }
                ForEach(sharing.availableRecipients) { recipient in
                    Button { sharing.add(recipient) } label: {
                        Label(recipient.name, systemImage: recipient.id.type == "group" ? "person.2" : "person").frame(minHeight: 44)
                    }
                }
            }
        }.searchable(text: $sharing.search, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("photos.sharing.searchMembers"))
            .navigationTitle(L10n.string("photos.sharing.chooseMember"))
            .task { sharing.loadRecipients() }
    }
    private func accessTitle(_ access: SynologyPhotoFolderSharingState.Access) -> String {
        switch access {
        case .management: L10n.string("photos.folderSharing.management")
        case .invited: L10n.string("photos.sharing.invited")
        case .view: L10n.string("photos.manage.link.view")
        case .download: L10n.string("photos.manage.link.download")
        }
    }
    private func roleTitle(_ role: String) -> String {
        role == "manage" ? L10n.string("photos.folderSharing.role.manage") : MobilePhotoSharingForm.roleTitle(role)
    }
}
