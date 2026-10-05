import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDirectoryScreen: View {
    @Bindable var model: MobileDirectoryModel
    @State private var scope = NasAccount.Kind.user
    @State private var query = ""
    @State private var editor: MobileDirectoryEditorSource?

    var body: some View {
        List {
            Section {
                Picker(L10n.string("mobile.nas.directory.title"), selection: $scope) {
                    Text(L10n.string("mobile.nas.directory.users")).tag(NasAccount.Kind.user)
                    Text(L10n.string("mobile.nas.directory.groups")).tag(NasAccount.Kind.group)
                }.pickerStyle(.segmented).accessibilityIdentifier("mobile.nas.directory.scope")
                if model.directory.value != nil {
                    Button(L10n.string(scope == .user ? "mobile.nas.directory.addUser" : "mobile.nas.directory.addGroup"), systemImage: "plus") {
                        open(nil)
                    }
                    .disabled(!model.canEdit).accessibilityIdentifier("mobile.nas.directory.add")
                    TextField(L10n.string("mobile.nas.directory.search"), text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                        .accessibilityIdentifier("mobile.nas.directory.search")
                    if !model.isAdministrator { Text((model.permissionError ?? .denied).message).foregroundStyle(.secondary) }
                }
            }
            Section {
                MobileNasDetailsSectionContent(section: model.directory,
                    loading: L10n.string("mobile.nas.directory.loading"), emptyTitle: L10n.string("mobile.nas.directory.empty"),
                    emptyMessage: L10n.string("mobile.nas.directory.addHint"), retry: { Task { await model.refresh() } }) { value in
                    let values = scope == .user ? value.users : value.groups
                    let filtered = values.filter { MobileNasReadFormatting.matches(query, values: [$0.name, $0.description, $0.email].compactMap { $0 }) }
                    if filtered.isEmpty {
                        ContentUnavailableView(L10n.string(query.isEmpty ? "mobile.nas.directory.empty" : "mobile.nas.filter.empty"),
                            systemImage: query.isEmpty ? "person.2" : "magnifyingglass",
                            description: Text(L10n.string(query.isEmpty ? "mobile.nas.directory.addHint" : "mobile.nas.filter.retry")))
                            .accessibilityIdentifier("mobile.nas.directory.empty")
                    }
                    ForEach(filtered) { account in
                        Button { open(account) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(account.name).font(.headline).foregroundStyle(.primary)
                                if let description = account.description, !description.isEmpty { Text(description).foregroundStyle(.secondary) }
                                if let email = account.email, !email.isEmpty { Text(email).font(.caption).foregroundStyle(.secondary) }
                                if account.kind == .user && account.isExpired { Text(L10n.string("mobile.nas.directory.disabledStatus")).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(.rect)
                        }.buttonStyle(.plain).accessibilityIdentifier("mobile.nas.directory.row.\(account.name)")
                    }
                }
            }
            if let error = model.error { Section { Text(error.message).accessibilityIdentifier("mobile.nas.directory.error") } }
            if !model.entries.isEmpty {
                Section(L10n.string("mobile.nas.directory.activity")) {
                    ForEach(model.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.action.title).font(.headline)
                            Text(model.name(for: entry) ?? L10n.string("mobile.nas.directory.originalTarget"))
                            Text(model.recovery.isExecuting(entry.id) ? L10n.string("mobile.nas.directory.working") : entry.message)
                                .accessibilityIdentifier("mobile.nas.directory.activity.\(entry.phase.rawValue)")
                            Text(entry.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(L10n.locale)))
                                .font(.caption).foregroundStyle(.secondary)
                            if entry.isUnfinished {
                                Button(L10n.string("mobile.nas.directory.reload")) { Task { await model.refresh() } }
                                    .disabled(model.isOperating || model.directory.isRefreshing).accessibilityIdentifier("mobile.nas.directory.recover")
                            } else if !model.recovery.isExecuting(entry.id) {
                                Button(L10n.string("mobile.nas.directory.removeRecord")) { model.removeRecord(entry.id) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityIdentifier("mobile.nas.directory.list")
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L10n.string("mobile.nas.directory.title")).navigationBarTitleDisplayMode(.inline)
        .task(id: model.activation) { await model.loadIfNeeded() }.refreshable { await model.refresh() }
        .onDisappear { model.cancelRead() }
        .onChange(of: model.activation) { _, _ in editor = nil; query = "" }
        .sheet(item: $editor) { source in
            NavigationStack { MobileDirectoryEditor(model: model, source: source, onClose: { editor = nil }) }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
    private func open(_ original: NasAccount?) {
        editor = .init(original: original, kind: scope, groups: model.directory.value?.groups ?? [], activation: model.activation)
    }
}

private struct MobileDirectoryEditorSource: Identifiable {
    let id = UUID()
    let original: NasAccount?
    let kind: NasAccount.Kind
    let groups: [NasAccount]
    let activation: UUID
}

private struct MobileDirectoryEditor: View {
    @Bindable var model: MobileDirectoryModel
    let source: MobileDirectoryEditorSource
    let onClose: () -> Void
    @State private var draft: NasAccountDraft
    @State private var confirmation: NasDirectoryChange?
    @State private var confirmedChange: NasDirectoryChange?
    @State private var operationID: UUID?
    @FocusState private var focused: Field?
    private enum Field: Hashable { case name, description, email, password, confirmation }

    init(model: MobileDirectoryModel, source: MobileDirectoryEditorSource, onClose: @escaping () -> Void) {
        self.model = model; self.source = source; self.onClose = onClose
        _draft = State(initialValue: .init(originalName: source.original?.name, name: source.original?.name ?? "",
            description: source.original?.description ?? "", email: source.original?.email ?? "", isExpired: source.original?.isExpired ?? false))
    }
    @State private var choosingGroups = false

    private var isCurrent: Bool { source.original.map(model.isCurrent) ?? false }
    private var editable: Bool { model.canEdit && (source.original == nil || source.original?.canEdit == true) }
    private var change: NasDirectoryChange {
        if source.kind == .group {
            return .saveGroup(original: source.original, draft: .init(originalName: draft.originalName, name: draft.name, description: draft.description))
        }
        var value = draft
        if let groups = value.groups, groups.sorted() == source.original?.groups?.sorted() { value.groups = nil }
        return .saveUser(original: source.original, draft: value, groups: value.groups == nil ? nil : source.groups)
    }
    var body: some View {
        Form {
            Section {
                if let original = source.original {
                    LabeledContent(L10n.string("mobile.nas.directory.name"), value: original.name)
                    if let id = original.numericID { LabeledContent(L10n.string("mobile.nas.directory.number"), value: id.formatted(.number.grouping(.never).locale(L10n.locale))) }
                } else {
                    TextField(L10n.string("mobile.nas.directory.name"), text: $draft.name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .name).submitLabel(.done)
                        .accessibilityIdentifier("mobile.nas.directory.name")
                }
                if let original = source.original, !original.canEdit {
                    if let description = original.description { LabeledContent(L10n.string("mobile.nas.directory.description"), value: description) }
                    if let email = original.email { LabeledContent(L10n.string("mobile.nas.directory.email"), value: email) }
                } else {
                    LabeledContent(L10n.string("mobile.nas.directory.description")) {
                        TextField(L10n.string("mobile.nas.directory.description"), text: $draft.description, axis: .vertical)
                            .lineLimit(1...4).focused($focused, equals: .description).accessibilityIdentifier("mobile.nas.directory.description")
                    }
                    if source.kind == .user {
                        LabeledContent(L10n.string("mobile.nas.directory.email")) {
                            TextField(L10n.string("mobile.nas.directory.email"), text: $draft.email)
                                .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused, equals: .email).submitLabel(.done)
                                .accessibilityIdentifier("mobile.nas.directory.email")
                        }
                        Toggle(L10n.string("mobile.nas.directory.disabled"), isOn: $draft.isExpired)
                            .disabled(isCurrent).accessibilityIdentifier("mobile.nas.directory.disabled")
                    }
                }
            }.disabled(!editable)
            if source.original?.canEdit == false {
                Section { Text(L10n.string("mobile.nas.directory.readOnly")) }
            }
            if source.kind == .user {
                Section(L10n.string("mobile.nas.directory.groups")) {
                    if let groups = draft.groups ?? source.original?.groups {
                        if groups.isEmpty { Text(L10n.string("mobile.nas.directory.noGroups")) }
                        ForEach(groups.sorted(), id: \.self) { Text($0) }
                    } else {
                        Text(L10n.string(source.original == nil ? "mobile.nas.directory.defaultGroups" : "mobile.nas.directory.unknownGroups"))
                            .foregroundStyle(.secondary)
                    }
                    if !source.groups.isEmpty, source.original == nil || source.original?.groups != nil {
                        Button(L10n.string("mobile.nas.directory.chooseGroups")) { focused = nil; choosingGroups = true }
                            .disabled(!editable || isCurrent).accessibilityIdentifier("mobile.nas.directory.chooseGroups")
                    }
                }
                if source.original?.canEdit != false {
                    Section {
                    SecureField(L10n.string(source.original == nil ? "mobile.nas.directory.password" : "mobile.nas.directory.newPassword"), text: $draft.password)
                        .textContentType(.newPassword).focused($focused, equals: .password).submitLabel(.done).accessibilityIdentifier("mobile.nas.directory.password")
                    SecureField(L10n.string("mobile.nas.directory.confirmPassword"), text: $draft.passwordConfirmation)
                        .textContentType(.newPassword).focused($focused, equals: .confirmation).submitLabel(.done).accessibilityIdentifier("mobile.nas.directory.confirmPassword")
                    if !draft.passwordConfirmation.isEmpty && draft.password != draft.passwordConfirmation {
                        Text(L10n.string("mobile.nas.directory.passwordMismatch")).foregroundStyle(.red)
                    }
                } footer: { Text(L10n.string("mobile.nas.directory.passwordPrivacy")) }
                    .disabled(!editable)
                }
                if isCurrent { Section { Text(L10n.string("mobile.nas.directory.currentProtected")).foregroundStyle(.secondary) } }
            }
            if let original = source.original {
                Section {
                    Button(L10n.string(source.kind == .user ? "mobile.nas.directory.deleteUser" : "mobile.nas.directory.deleteGroup"), role: .destructive) {
                        focused = nil; confirmation = .delete(original)
                    }.disabled(!model.canPerform(.delete(original))).accessibilityIdentifier("mobile.nas.directory.delete")
                }
            }
            if let operationID, let entry = model.recovery.entry(operationID) {
                Section { Text(model.recovery.isExecuting(operationID) ? L10n.string("mobile.nas.directory.working") : entry.message)
                    .accessibilityIdentifier("mobile.nas.directory.saveResult") }
            }
            if let error = model.error { Section { Text(error.message) } }
            if !model.isAdministrator { Section { Text((model.permissionError ?? .denied).message) } }
        }
        .accessibilityIdentifier("mobile.nas.directory.editor")
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(L10n.string(source.original == nil
            ? (source.kind == .user ? "mobile.nas.directory.addUser" : "mobile.nas.directory.addGroup") : (source.kind == .user ? "mobile.nas.directory.details" : "mobile.nas.directory.groupDetails")))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.string("mobile.nas.directory.done")) { clearSecrets(); onClose() }.accessibilityIdentifier("mobile.nas.directory.done")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(L10n.string("mobile.nas.directory.save")) {
                    focused = nil
                    if change.requiresRiskConfirmation { confirmation = change }
                    else { operationID = model.perform(change, activation: source.activation); clearSecrets() }
                }
                    .disabled(!model.canPerform(change)).accessibilityIdentifier("mobile.nas.directory.save")
            }
        }
        .sheet(isPresented: $choosingGroups) {
            NavigationStack {
                List(source.groups) { group in
                    Toggle(group.name, isOn: Binding(get: {
                        (draft.groups ?? source.original?.groups ?? []).contains(group.name)
                    }, set: { selected in
                        var groups = draft.groups ?? source.original?.groups ?? []
                        groups.removeAll { $0 == group.name }; if selected { groups.append(group.name) }; draft.groups = groups
                    }))
                    .disabled(group.numericID == nil).accessibilityIdentifier("mobile.nas.directory.group.\(group.name)")
                }
                .accessibilityIdentifier("mobile.nas.directory.groupPicker")
                .navigationTitle(L10n.string("mobile.nas.directory.groups"))
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.nas.directory.done")) { choosingGroups = false }
                        .accessibilityIdentifier("mobile.nas.directory.groupsDone")
                } }
            }
        }
        .onSubmit { focused = nil }
        .onChange(of: model.activation) { _, _ in clearSecrets(); onClose() }
        .task(id: operationID) {
            guard let operationID else { return }
            await model.waitForOperation(operationID)
            guard !Task.isCancelled, model.activation == source.activation,
                  model.recovery.entry(operationID)?.phase == .succeeded else { return }
            onClose()
        }
        .onDisappear { clearSecrets() }
        .sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), onDismiss: {
            // 等风险说明真正关闭后再提交，避免快速回执与嵌套弹窗的关闭动画竞争。
            guard let change = confirmedChange else { return }
            confirmedChange = nil
            operationID = model.perform(change, activation: source.activation)
            clearSecrets()
        }) {
            if let confirmation {
                NavigationStack {
                    Form {
                        Section {
                            Text(L10n.string(confirmation.isDeletion
                                ? (source.kind == .user ? "mobile.nas.directory.deleteUserWarning" : "mobile.nas.directory.deleteGroupWarning")
                                : "mobile.nas.directory.saveWarning", confirmation.name))
                        }
                    }
                    .accessibilityIdentifier("mobile.nas.directory.confirmation")
                    .navigationTitle(confirmation.action.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.string("mobile.nas.directory.cancel"), role: .cancel) { self.confirmation = nil }
                                .accessibilityIdentifier("mobile.nas.directory.cancel")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(confirmation.action.title, role: confirmation.isDeletion ? .destructive : nil) {
                                guard confirmedChange == nil else { return }
                                confirmedChange = confirmation; self.confirmation = nil
                            }
                            .disabled(!model.canPerform(confirmation) || confirmedChange != nil)
                            .accessibilityIdentifier("mobile.nas.directory.confirm")
                        }
                    }
                    .fillsAvailableContentArea(alignment: .topLeading)
                }
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
    }
    private func clearSecrets() { draft.password = ""; draft.passwordConfirmation = ""; confirmation = nil; confirmedChange = nil }
}

private extension NasDirectoryChange {
    var requiresRiskConfirmation: Bool {
        switch self {
        case .delete: true
        case .saveGroup: false
        case .saveUser(let original, let draft, _):
            original == nil || !draft.password.isEmpty || original?.isExpired != draft.isExpired
                || draft.groups.map { $0.sorted() != original?.groups?.sorted() } == true
        }
    }
}

extension NasDirectoryAction {
    var title: String {
        let key = switch self {
        case .saveUser: "mobile.nas.directory.saveUser"
        case .saveGroup: "mobile.nas.directory.saveGroup"
        case .deleteUser: "mobile.nas.directory.deleteUser"
        case .deleteGroup: "mobile.nas.directory.deleteGroup"
        }
        return L10n.string(key)
    }
}
extension MobileDirectoryModel.Failure {
    var message: String {
        let key = switch self {
        case .read: "mobile.nas.directory.readFailed"
        case .denied: "mobile.nas.directory.denied"
        case .unavailable: "mobile.nas.directory.unavailable"
        case .changed: "mobile.nas.directory.changed"
        case .storage: "mobile.nas.directory.storageFailed"
        }
        return L10n.string(key)
    }
}
extension MobileDirectoryOperationStore.Entry {
    var message: String {
        switch phase {
        case .prepared: L10n.string("mobile.nas.directory.working")
        case .submitted: L10n.string(requiresAcknowledgement && !accepted ? "mobile.nas.directory.credentialUnknown" : "mobile.nas.directory.unknown")
        case .succeeded: L10n.string(isDeletion ? "mobile.nas.directory.deleted" : "mobile.nas.directory.saved")
        case .cancelled: L10n.string("mobile.nas.directory.cancelled")
        case .failed:
            switch failure {
            case .denied: MobileDirectoryModel.Failure.denied.message
            case .unavailable: MobileDirectoryModel.Failure.unavailable.message
            case .changed: MobileDirectoryModel.Failure.changed.message
            default: L10n.string("mobile.nas.directory.failed")
            }
        }
    }
}
