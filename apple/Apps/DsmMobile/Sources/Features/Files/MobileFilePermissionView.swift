import DsmCore
import DsmLocalization
import SwiftUI

struct MobileFilePermissionView: View {
    @Bindable var model: MobileFilePermissionModel
    let item: FileItem
    @Environment(\.dismiss) private var dismiss
    @State private var showsPicker = false
    @State private var pickerRole = MobileFilePermissionModel.PickerRole.rule
    @State private var picked: Set<FileStationPrincipal> = []

    var body: some View {
        NavigationStack {
            Group {
                if model.loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let snapshot = model.snapshot {
                    permissionForm(snapshot)
                } else {
                    ContentUnavailableView {
                        Label(L10n.string("files.permissions.loadFailed"), systemImage: "lock.trianglebadge.exclamationmark")
                    } description: {
                        Text(model.error ?? L10n.string("mobile.permissions.load-error"))
                    } actions: {
                        Button(L10n.string("ui.aee88743413144a2")) { Task { await model.load(item) } }
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.permissions.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.disabled(model.busy)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    if model.busy { ProgressView() }
                    else {
                        Button { Task { await model.refresh(item) } } label: {
                            Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
                        }.disabled(model.loading)
                            .accessibilityLabel(L10n.string("ui.aee88743413144a2"))
                            .accessibilityIdentifier("files.permissions.refresh")
                        Button(L10n.string("mobile.sharing.save")) { model.requestConfirmation() }
                            .disabled(!model.canSave).accessibilityIdentifier("files.permissions.save")
                    }
                }
            }
        }
        .task { await model.load(item) }
        .interactiveDismissDisabled(model.busy)
        .presentationDetents([.large])
        .sheet(isPresented: $showsPicker, onDismiss: { model.apply(picked, role: pickerRole) }) {
            MobileFileStationPrincipalPicker(selection: $picked) { prefix, offset in
                try await model.principals(prefix: prefix, offset: offset)
            }
        }
        .sheet(isPresented: Binding(get: { model.pendingConfirmation != nil },
                                    set: { if !$0 { model.cancelConfirmation() } })) {
            confirmation
        }
    }

    private func permissionForm(_ snapshot: FilePermissionSnapshot) -> some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    Text(snapshot.target.name).font(.headline).id("permissions.heading")
                    if model.access?.writesEnabled != true || !model.permitsChanges {
                        Text(L10n.string(model.access?.writesEnabled == true
                            ? "files.permissions.readOnly" : "mobile.permissions.access-unavailable"))
                            .foregroundStyle(.secondary)
                    }
                }
                feedback
                ownership(snapshot)
                if snapshot.isACL { aclSections(snapshot) } else { posixSections }
                if snapshot.target.isDirectory {
                    Section {
                        Toggle(L10n.string("files.permissions.recursive"), isOn: $model.recursive).disabled(!model.canEdit)
                    }
                }
            }.onChange(of: model.result?.status) { _, value in
                if value != nil { proxy.scrollTo("permissions.heading", anchor: .top) }
            }
        }
    }

    private func ownership(_ snapshot: FilePermissionSnapshot) -> some View {
        Section {
            Text(L10n.string("files.permissions.owner", snapshot.owner?.name ?? snapshot.target.owner ?? "—"))
            if let owner = model.owner { Text(L10n.string("files.permissions.newOwner", owner.name)).bold() }
            Button(L10n.string("files.permissions.chooseOwner")) { choose(.owner) }.disabled(!model.canChangeOwner)
            if model.owner != nil {
                Button(L10n.string("files.permissions.keepOwner")) { model.owner = nil }.disabled(!model.canEdit)
            }
            if !snapshot.isACL {
                Text(L10n.string("files.permissions.group", snapshot.target.group ?? "—"))
                if let group = model.group { Text(L10n.string("files.permissions.newGroup", group.name)).bold() }
                Button(L10n.string("files.permissions.chooseGroup")) { choose(.group) }.disabled(!model.canChangeGroup)
                if model.group != nil {
                    Button(L10n.string("files.permissions.keepGroup")) { model.group = nil }.disabled(!model.canEdit)
                }
            }
        }
    }

    @ViewBuilder
    private func aclSections(_ snapshot: FilePermissionSnapshot) -> some View {
        Section(L10n.string("files.permissions.explicit")) {
            if model.rules.isEmpty { Text(L10n.string("files.permissions.noExplicit")).foregroundStyle(.secondary) }
            ForEach(model.rules.indices, id: \.self) { index in
                DisclosureGroup {
                    ruleEditor(index)
                } label: {
                    Text(model.rules[index].ownerName.isEmpty ? L10n.string("files.permissions.unknownAccount") : model.rules[index].ownerName)
                    Text(effectTitle(model.rules[index].effect)).foregroundStyle(.secondary)
                }
            }
            Button(L10n.string("files.permissions.addAccount")) { choose(.rule) }
                .disabled(!model.canEdit || !snapshot.canChangePermissions)
        }
        Section(L10n.string("files.permissions.inherited")) {
            if snapshot.rules.allSatisfy({ $0.level == 0 }) {
                Text(L10n.string("files.permissions.noInherited")).foregroundStyle(.secondary)
            }
            ForEach(Array(snapshot.rules.filter { $0.level > 0 }.enumerated()), id: \.offset) { index, rule in
                DisclosureGroup(rule.ownerName.isEmpty ? L10n.string("files.permissions.unknownAccount") : rule.ownerName) {
                    Text(effectTitle(rule.effect))
                    ForEach(FileACLRight.allCases.filter { rule.rights.contains($0) }, id: \.self) { Text(rightTitle($0)) }
                    ForEach(FileACLInheritance.allCases.filter { rule.inheritance.contains($0) }, id: \.self) { Text(scopeTitle($0)) }
                }
                .accessibilityIdentifier("files.permissions.inherited.\(index)")
            }
        }
    }

    private func ruleEditor(_ index: Int) -> some View {
        Group {
            Picker(L10n.string("files.permissions.effect"), selection: $model.rules[index].effect) {
                ForEach(FileACLRule.Effect.allCases, id: \.self) { Text(effectTitle($0)).tag($0) }
            }
            ForEach(FileACLRight.allCases, id: \.self) { right in
                Toggle(rightTitle(right), isOn: Binding(get: { model.rules[index].rights.contains(right) }, set: {
                    if $0 { model.rules[index].rights.insert(right) } else { model.rules[index].rights.remove(right) }
                })).accessibilityIdentifier("files.permissions.rule.\(index).\(right.rawValue)")
            }
            if item.isDirectory {
                ForEach(FileACLInheritance.allCases, id: \.self) { scope in
                    Toggle(scopeTitle(scope), isOn: Binding(get: { model.rules[index].inheritance.contains(scope) }, set: {
                        if $0 { model.rules[index].inheritance.insert(scope) } else { model.rules[index].inheritance.remove(scope) }
                    }))
                }
            }
            Button(L10n.string("files.permissions.removeRule"), role: .destructive) { model.rules.remove(at: index) }
        }.disabled(!model.canEdit || model.snapshot?.canChangePermissions != true)
    }

    private var posixSections: some View {
        ForEach(0..<3, id: \.self) { index in
            Section(L10n.string(index == 0 ? "files.permissions.ownerRole" : index == 1
                ? "files.permissions.groupRole" : "files.permissions.everyoneRole")) {
                ForEach([4, 2, 1], id: \.self) { bit in
                    Toggle(L10n.string(bit == 4 ? "files.permissions.read" : bit == 2
                        ? "files.permissions.write" : "files.permissions.execute"), isOn: Binding(get: {
                        let digits = Array(model.mode)
                        return digits.count == 3 && (Int(String(digits[index])) ?? 0) & bit != 0
                    }, set: { enabled in
                        var digits = Array(model.mode)
                        guard digits.count == 3 else { return }
                        let previous = Int(String(digits[index])) ?? 0
                        digits[index] = Character(String(enabled ? previous | bit : previous & ~bit))
                        model.mode = String(digits)
                    })).accessibilityIdentifier("files.permissions.posix.\(index).\(bit)")
                }
            }.disabled(!model.canEdit || model.snapshot?.canChangePermissions != true)
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
        if model.recoveryFailed {
            Section { Text(L10n.string("mobile.activity.recovery-error")).foregroundStyle(.red) }
        }
        if let result = model.result {
            Section {
                Text(L10n.string(result.status == .confirmedSuccess ? "files.permissions.saved"
                    : result.localizationKey == "files.permissions.partial-failure" ? "mobile.permissions.partial"
                    : result.requiresRefresh ? "mobile.permissions.pending" : "mobile.permissions.save-error"))
                    .accessibilityIdentifier("files.permissions.result")
            }
        } else if model.isBlocked { Section { Text(L10n.string("mobile.permissions.pending")) } }
    }

    private var confirmation: some View {
        NavigationStack {
            Form {
                Section { Text(item.name).font(.headline) }
                Section(L10n.string("files.permissions.changeSummary")) {
                    if let snapshot = model.snapshot, !snapshot.isACL, model.mode != snapshot.posixMode {
                        Text(L10n.string("files.permissions.modeChange", snapshot.posixMode ?? "—", model.mode))
                    }
                    ForEach(model.changedNames, id: \.self) { Text(L10n.string("files.permissions.accountChange", $0)) }
                    if let owner = model.owner { Text(L10n.string("files.permissions.newOwner", owner.name)) }
                    if let group = model.group { Text(L10n.string("files.permissions.newGroup", group.name)) }
                }
                Section {
                    Text(L10n.string(model.recursive ? "mobile.permissions.recursive-risk" : "mobile.permissions.current-risk"))
                    if model.owner != nil || model.group != nil { Text(L10n.string("mobile.permissions.owner-risk")) }
                    if model.removesAccess { Text(L10n.string("mobile.permissions.removal-risk")) }
                }
                Section {
                    Button(L10n.string("files.permissions.save"), role: .destructive) {
                        Task { await model.confirmChanges() }
                    }.accessibilityIdentifier("files.permissions.confirm")
                }
            }.navigationTitle(L10n.string("files.permissions.save"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.files.share-link.action.cancel")) { model.cancelConfirmation() }
                } }
        }
    }

    private func choose(_ role: MobileFilePermissionModel.PickerRole) { picked = []; pickerRole = role; showsPicker = true }
    private func effectTitle(_ effect: FileACLRule.Effect) -> String {
        L10n.string(effect == .allow ? "files.permissions.allow" : "files.permissions.deny")
    }
    private func scopeTitle(_ scope: FileACLInheritance) -> String {
        let key = switch scope {
        case .thisFolder: "files.permissions.scope.current"
        case .childFiles: "files.permissions.scope.files"
        case .childFolders: "files.permissions.scope.folders"
        case .allDescendants: "files.permissions.scope.descendants"
        }
        return L10n.string(key)
    }
    private func rightTitle(_ right: FileACLRight) -> String {
        let key = switch right {
        case .readData: "files.permissions.right.read"
        case .writeData: "files.permissions.right.write"
        case .execute: "files.permissions.right.execute"
        case .append: "files.permissions.right.append"
        case .delete: "files.permissions.right.delete"
        case .deleteChildren: "files.permissions.right.deleteChildren"
        case .readAttributes: "files.permissions.right.readAttributes"
        case .writeAttributes: "files.permissions.right.writeAttributes"
        case .readExtendedAttributes: "files.permissions.right.readExtended"
        case .writeExtendedAttributes: "files.permissions.right.writeExtended"
        case .readPermissions: "files.permissions.right.readPermissions"
        case .changePermissions: "files.permissions.right.changePermissions"
        case .takeOwnership: "files.permissions.right.owner"
        }
        return L10n.string(key)
    }
}
