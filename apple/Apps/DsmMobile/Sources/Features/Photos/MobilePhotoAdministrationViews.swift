import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI

struct MobilePhotoAdministrationForm: View {
    @Bindable var administration: MobilePhotoAdministrationModel
    let draft: MobilePhotoAdministrationModel.Draft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if administration.isLoading {
                    ProgressView(L10n.string("mobile.photos.preferences.loading")).accessibilityIdentifier("mobile.photos.administration.loading")
                } else if let error = administration.error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { administration.load() } }
                } else if draft.page == .members {
                    MobilePhotoMembersContent(administration: administration)
                } else {
                    Form {
                        if draft.page == .shared { sharedFields }
                        else { globalFields }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(draft.page.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("photos.delete.cancel")) { administration.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("mobile.photos.edit.save")) { if administration.save() { dismiss() } }
                            .disabled(administration.mutation == nil).keyboardShortcut(.defaultAction).accessibilityIdentifier("mobile.photos.administration.save")
                    }
                }
                .alert(administration.confirmationTitle, isPresented: $administration.showsConfirmation) {
                    Button(L10n.string("photos.delete.cancel"), role: .cancel) { administration.cancelConfirmation() }
                    Button(administration.confirmationAction) { if administration.confirmSave() { dismiss() } }
                        .accessibilityIdentifier("mobile.photos.administration.confirm")
                } message: { Text(administration.confirmationMessage) }
                .navigationDestination(isPresented: Binding(get: { administration.folderTarget != nil }, set: { if !$0 { administration.cancelFolders() } })) {
                    MobilePhotoMemberFoldersForm(administration: administration)
                }
                .sheet(isPresented: $administration.showsCandidates) { MobilePhotoMemberCandidatesForm(administration: administration) }
        }
        .task(id: administration.cache?.isClearing) {
            while administration.cache?.isClearing == true, !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if !administration.showsConfirmation { administration.loadCache() }
            }
        }
    }

    @ViewBuilder private var sharedFields: some View {
        if let original = administration.originalShared {
            Section {
                LabeledContent(L10n.string("photos.sharedSettings.status"), value: L10n.string(original.isEnabled ? "photos.sharedSettings.on" : "photos.sharedSettings.off"))
                Button(L10n.string(original.isEnabled ? "photos.sharedSettings.disable" : "photos.sharedSettings.enable")) { administration.confirmSharedSwitch() }
                    .disabled(!administration.editable || !original.canSetEnabled(!original.isEnabled)).accessibilityIdentifier("mobile.photos.administration.sharedSwitch")
                if original.isEnabled && !original.personalSpaceEnabled { Text(L10n.string("photos.sharedSettings.lastSpace")).foregroundStyle(.secondary) }
                else if !original.isEnabled && original.disabledBySharedFolder == true { Text(L10n.string("photos.sharedSettings.folderDisabled")).foregroundStyle(.secondary) }
            }
            if original.isEnabled {
                Section(L10n.string("photos.sharedSettings.preferences")) {
                    ForEach(SynologyPhotoSharedSpaceSettings.Kind.allCases, id: \.self) { kind in
                        if original.values[kind] != nil {
                            Toggle(sharedTitle(kind), isOn: Binding(get: { administration.sharedEnabled.contains(kind) }, set: { value in
                                if value { administration.sharedEnabled.insert(kind) } else { administration.sharedEnabled.remove(kind) }
                            })).disabled(!administration.editable || !original.editable.contains(kind))
                                .accessibilityIdentifier("photos.sharedSettings.\(kind.rawValue)")
                        }
                    }
                    if original.values.isEmpty { Text(L10n.string("photos.sharedSettings.empty")).foregroundStyle(.secondary) }
                    else if !Set(original.values.keys).subtracting([.publicRoot]).isSubset(of: original.globallyEnabled) {
                        Text(L10n.string("photos.sharedSettings.globalRequired")).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    @ViewBuilder private var globalFields: some View {
        if let original = administration.originalGlobal {
            if !Set(original.values.keys).isDisjoint(with: [.person, .concept, .similar]) {
                Section(L10n.string("photos.global.recognition")) { globalToggles([.person, .concept, .similar], original: original) }
            }
            if !Set(original.values.keys).isDisjoint(with: [.userSharing, .guestInfo]) {
                Section(L10n.string("photos.global.sharing")) { globalToggles([.userSharing, .guestInfo], original: original) }
            }
            if original.values.isEmpty && original.excludedExtensions == nil { Text(L10n.string("photos.global.empty")).foregroundStyle(.secondary) }
            if administration.excluded != nil {
                Section {
                    NavigationLink(L10n.string("photos.global.excluded")) {
                        List {
                            ForEach(SynologyPhotoGlobalSettings.supportedExtensions.union(original.excludedExtensions ?? []).sorted(), id: \.self) { value in
                                Toggle(isOn: Binding(get: { administration.excluded?.contains(value) == true }, set: { checked in
                                    if checked { administration.excluded?.insert(value) } else { administration.excluded?.remove(value) }
                                })) { Text(verbatim: value) }.disabled(!administration.editable)
                            }
                        }.navigationTitle(L10n.string("photos.global.excluded")).navigationBarTitleDisplayMode(.inline)
                    }.accessibilityIdentifier("mobile.photos.administration.excluded")
                }
            }
        }
        if administration.originalGlobal?.values[.originalJPEG] != nil || administration.model.managementFeatures.contains(.conversionCache) {
            Section(L10n.string("photos.global.conversion")) {
                if let original = administration.originalGlobal {
                    globalToggles([.originalJPEG], original: original)
                    if original.values[.originalJPEG] != nil && original.hasHEVC != true { Text(L10n.string("photos.global.codecRequired")).foregroundStyle(.secondary) }
                }
                if administration.model.managementFeatures.contains(.conversionCache) {
                    HStack {
                        Text(L10n.string("photos.global.cache"))
                        Spacer()
                        if administration.cacheLoading { ProgressView() }
                        else if let cache = administration.cache { Text(cache.sizeBytes.formatted(.byteCount(style: .file).locale(L10n.locale))).foregroundStyle(.secondary) }
                        Button { administration.loadCache() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel(L10n.string("photos.library.refresh")).disabled(administration.cacheLoading)
                    }
                    if let error = administration.cacheError { Text(error).foregroundStyle(.secondary) }
                    else if administration.cache?.isClearing == true { Label(L10n.string("photos.global.clearing"), systemImage: "clock").foregroundStyle(.secondary) }
                    Button(L10n.string("photos.global.clearCache")) { administration.confirmClearCache() }
                        .disabled(!administration.editable || administration.cacheLoading || administration.cache?.canClear != true)
                        .accessibilityIdentifier("mobile.photos.administration.clearCache")
                }
            }
        }
    }
    private func globalToggles(_ kinds: [SynologyPhotoGlobalSettings.Kind], original: SynologyPhotoGlobalSettings) -> some View {
        ForEach(kinds, id: \.self) { kind in
            if original.values[kind] != nil {
                Toggle(globalTitle(kind), isOn: Binding(get: { administration.globalEnabled.contains(kind) }, set: { value in
                    if value { administration.globalEnabled.insert(kind) } else { administration.globalEnabled.remove(kind) }
                })).disabled(!administration.editable || !original.editable.contains(kind))
                    .accessibilityIdentifier("photos.global.\(kind.rawValue)")
            }
        }
    }
    private func sharedTitle(_ kind: SynologyPhotoSharedSpaceSettings.Kind) -> String {
        switch kind {
        case .person: L10n.string("photos.sharedSettings.person")
        case .concept: L10n.string("photos.sharedSettings.concept")
        case .similar: L10n.string("photos.sharedSettings.similar")
        case .publicRoot: L10n.string("photos.sharedSettings.publicRoot")
        }
    }
    private func globalTitle(_ kind: SynologyPhotoGlobalSettings.Kind) -> String {
        switch kind {
        case .person: L10n.string("photos.global.person")
        case .concept: L10n.string("photos.global.concept")
        case .similar: L10n.string("photos.global.similar")
        case .userSharing: L10n.string("photos.global.userSharing")
        case .guestInfo: L10n.string("photos.global.guestInfo")
        case .originalJPEG: L10n.string("photos.global.originalJPEG")
        }
    }
}

private struct MobilePhotoMembersContent: View {
    @Bindable var administration: MobilePhotoAdministrationModel
    var body: some View {
        Group {
            if administration.originalMembers?.isEnabled == false {
                ContentUnavailableView(L10n.string("photos.members.disabled"), systemImage: "person.2.slash", description: Text(L10n.string("photos.members.enableFirst")))
            } else {
                List {
                    Section {
                        Button { administration.showsCandidates = true } label: { Label(L10n.string("photos.members.add"), systemImage: "person.badge.plus") }
                            .disabled(!administration.editable).accessibilityIdentifier("photos.members.add")
                        Menu {
                            Button(L10n.string("photos.members.backupAll")) { administration.setAllBackup(true) }
                            Button(L10n.string("photos.members.backupNone")) { administration.setAllBackup(false) }
                        } label: { Label(L10n.string("photos.members.backup"), systemImage: "arrow.clockwise.icloud") }
                            .disabled(!administration.editable || !administration.members.contains { $0.canEdit && $0.role == "entry" })
                    }
                    if administration.filteredMembers.isEmpty {
                        ContentUnavailableView(L10n.string(administration.members.isEmpty ? "photos.members.empty" : "photos.members.noMatches"), systemImage: "person.2",
                            description: Text(L10n.string(administration.members.isEmpty ? "photos.members.emptyHint" : "photos.members.searchHint")))
                    }
                    ForEach(administration.filteredMembers) { member in
                        Section {
                            Label(member.recipient.name, systemImage: member.id.type == "group" ? "person.2" : "person")
                                .accessibilityValue(L10n.string(member.id.type == "group" ? "photos.members.group" : "photos.members.user"))
                            if member.isProtected { Text(L10n.string("photos.members.protected")).foregroundStyle(.secondary) }
                            if member.canEdit {
                                Picker(L10n.string("photos.members.role"), selection: Binding(get: { member.role }, set: { role in
                                    if let role = SynologyPhotoSharedMember.Role(rawValue: role) { administration.changeRole(member, to: role) }
                                })) {
                                    Text(L10n.string("photos.members.role.entry")).tag("entry")
                                    Text(L10n.string("photos.members.role.management")).tag("management")
                                }
                                Toggle(L10n.string("photos.members.backup"), isOn: Binding(get: { member.autoBackup }, set: { administration.setBackup(member, enabled: $0) }))
                                    .disabled(member.role == "management")
                                if member.role == "entry" {
                                    Button(L10n.string("photos.members.folders")) { administration.beginFolders(member) }
                                }
                                Button(L10n.string("photos.members.remove"), role: .destructive) { administration.remove(member) }
                            } else { Text(L10n.string(member.role == "management" ? "photos.members.role.management" : "photos.members.unknownRole")).foregroundStyle(.secondary) }
                        }.disabled(!administration.editable)
                    }
                }.searchable(text: $administration.search, prompt: L10n.string("photos.members.search"))
            }
        }
    }
}

private struct MobilePhotoMemberCandidatesForm: View {
    @Bindable var administration: MobilePhotoAdministrationModel
    var body: some View {
        NavigationStack {
            Group {
                if administration.candidatesLoading { ProgressView() }
                else if let error = administration.candidatesError {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { administration.loadCandidates() } }
                } else if administration.availableCandidates.isEmpty {
                    ContentUnavailableView(L10n.string("photos.members.noMatches"), systemImage: "person.crop.circle.badge.questionmark", description: Text(L10n.string("photos.members.candidateHint")))
                } else {
                    List(administration.availableCandidates) { candidate in
                        Menu {
                            Button(L10n.string("photos.members.role.entry")) { administration.add(candidate, role: .entry) }
                            Button(L10n.string("photos.members.role.management")) { administration.add(candidate, role: .management) }
                        } label: {
                            Label(candidate.name, systemImage: candidate.id.type == "group" ? "person.2" : "person")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                        }
                            .disabled(!administration.editable)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .searchable(text: $administration.candidateSearch, prompt: L10n.string("photos.members.search"))
                .navigationTitle(L10n.string("photos.members.add")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.string("photos.delete.cancel")) { administration.showsCandidates = false } } }
        }
    }
}

private struct MobilePhotoMemberFoldersForm: View {
    @Bindable var administration: MobilePhotoAdministrationModel
    @State private var expanded: Set<Int> = []
    var body: some View {
        Group {
            if administration.folderLoading { ProgressView(L10n.string("mobile.photos.preferences.loading")) }
            else if let error = administration.folderError {
                ContentUnavailableView {
                    Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { administration.loadFolders() } }
            } else if let edit = administration.folderDraft {
                folderList(edit)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(L10n.string("photos.members.folders")).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $administration.folderSearch, prompt: L10n.string("photos.members.folderSearch"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("photos.members.done")) { _ = administration.finishFolders() }
                        .disabled(!administration.editable || administration.folderLoading || administration.folderError != nil || administration.folderDraft == nil)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("mobile.photos.administration.folders.done")
                }
            }
    }
    private func folderList(_ edit: SynologyPhotoMemberFolderEdit) -> some View {
        let search = administration.folderSearch
        let roots = edit.original.filter { root in root.depth == 0 && (search.isEmpty || root.folder.name.localizedStandardContains(search) ||
            edit.original.contains { $0.folder.parentID == root.id && $0.folder.name.localizedStandardContains(search) }) }
        return List {
            Menu {
                ForEach(SynologyPhotoFolderMemberRole.allCases, id: \.self) { role in
                    Menu(folderRoleTitle(role)) {
                        Button(L10n.string("photos.members.grantAll")) { administration.applyFolderBatch(.init(action: .checkAll, role: role)) }
                        Button(L10n.string("photos.members.revokeAll")) { administration.applyFolderBatch(.init(action: .uncheckAll, role: role)) }
                    }
                }
            } label: { Label(L10n.string("photos.members.allFolders"), systemImage: "folder.badge.person.crop") }
                .disabled(!administration.editable || edit.original.isEmpty || !edit.original.allSatisfy(\.hasKnownPermissions))
            if roots.isEmpty {
                ContentUnavailableView(L10n.string(edit.original.isEmpty ? "photos.members.noFolders" : "photos.members.noMatches"), systemImage: "folder",
                    description: Text(L10n.string(edit.original.isEmpty ? "photos.members.noFoldersHint" : "photos.members.searchHint")))
            }
            ForEach(roots) { root in
                Section {
                    folderRow(root, edit: edit)
                    let children = edit.original.filter { $0.depth == 1 && $0.folder.parentID == root.id &&
                        (search.isEmpty || root.folder.name.localizedStandardContains(search) || $0.folder.name.localizedStandardContains(search)) }
                    if !children.isEmpty {
                        DisclosureGroup(isExpanded: Binding(get: { !search.isEmpty || expanded.contains(root.id) }, set: { value in
                            if value { expanded.insert(root.id) } else { expanded.remove(root.id) }
                        })) {
                            ForEach(children) { folder in folderRow(folder, edit: edit) }
                        } label: { Text(L10n.string(!search.isEmpty || expanded.contains(root.id) ? "photos.members.collapse" : "photos.members.expand")) }
                    }
                }
            }
        }
    }
    private func folderRow(_ folder: SynologyPhotoMemberFolder, edit: SynologyPhotoMemberFolderEdit) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(folder.folder.name, systemImage: "folder")
            if let role = folder.publicRole { Text(L10n.string("photos.members.publicMinimum", folderRoleTitle(role))).font(.caption).foregroundStyle(.secondary) }
            if folder.hasKnownPermissions {
                Picker(L10n.string("photos.members.folderRole"), selection: Binding(get: { edit.expectedRole(for: folder) ?? "" }, set: { role in
                    administration.setFolderRole(SynologyPhotoFolderMemberRole(rawValue: role), for: folder)
                })) {
                    Text(L10n.string("photos.members.noDirectGrant")).tag("")
                    ForEach(SynologyPhotoFolderMemberRole.allCases, id: \.self) { role in Text(folderRoleTitle(role)).tag(role.rawValue) }
                }.disabled(!administration.editable || !edit.canEditFolder(folder))
                    .accessibilityIdentifier("mobile.photos.administration.folder.\(folder.id)")
            } else { Text(L10n.string("photos.members.unknownRole")).foregroundStyle(.secondary) }
        }.padding(.vertical, 4)
    }
    private func folderRoleTitle(_ role: SynologyPhotoFolderMemberRole) -> String {
        switch role {
        case .view: L10n.string("photos.members.folderRole.view")
        case .download: L10n.string("photos.members.folderRole.download")
        case .upload: L10n.string("photos.members.folderRole.upload")
        case .manage: L10n.string("photos.members.folderRole.manage")
        }
    }
}

struct MobilePhotoAdministrationPresentation: ViewModifier {
    @Bindable var session: MobileSynologyPhotosSession
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { session.administration?.draft }, set: { if $0 == nil { session.administration?.cancel() } }), onDismiss: { session.administration?.cancel() }) { draft in
            if let administration = session.administration { MobilePhotoAdministrationForm(administration: administration, draft: draft) }
        }
    }
}
