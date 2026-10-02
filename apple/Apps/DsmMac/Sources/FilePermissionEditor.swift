import DsmCore
import DsmLocalization
import SwiftUI

struct FilePermissionEditor: View {
    let model: WorkspaceModel
    let item: FileItem
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: FilePermissionSnapshot?
    @State private var access: FileStationAdvancedAccess?
    @State private var rules: [FileACLRule] = []
    @State private var mode = "000"
    @State private var owner: FileStationPrincipal?
    @State private var group: FileStationPrincipal?
    @State private var recursive = false
    @State private var confirmed = false
    @State private var confirmedOwner = false
    @State private var confirmedRecursive = false
    @State private var confirmedRemoval = false
    @State private var busy = false
    @State private var loading = true
    @State private var error: String?
    @State private var result: MutationResult?
    @State private var submitted: FilePermissionChange?
    @State private var pickerRole: Int?
    @State private var picked: Set<FileStationPrincipal> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.string("files.permissions.title")).font(.title2.bold())
            Text(item.path).foregroundStyle(.secondary).textSelection(.enabled)
            if loading {
                ProgressView().fillsAvailableContentArea()
            } else if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if access?.writesEnabled != true {
                            Text(L10n.string("files.advanced.permissionUnavailable")).foregroundStyle(.secondary)
                        }
                        ownerFields(snapshot)
                        Divider()
                        if snapshot.isACL {
                            Text(L10n.string("files.permissions.explicit")).font(.headline)
                            if rules.isEmpty { Text(L10n.string("files.permissions.noExplicit")).foregroundStyle(.secondary) }
                            ForEach(rules.indices, id: \.self) { index in
                                ruleEditor(index).disabled(!editable || !snapshot.canChangePermissions)
                            }
                            Button(L10n.string("files.permissions.addAccount")) { picked = []; pickerRole = 0 }
                                .disabled(!editable || !snapshot.canChangePermissions)
                            ForEach(Array(removedRules.enumerated()), id: \.offset) { _, rule in
                                Label(L10n.string("files.permissions.removing", rule.ownerName), systemImage: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            Text(L10n.string("files.permissions.inherited")).font(.headline)
                            if snapshot.rules.allSatisfy({ $0.level == 0 }) {
                                Text(L10n.string("files.permissions.noInherited")).foregroundStyle(.secondary)
                            }
                            ForEach(Array(snapshot.rules.filter { $0.level > 0 }.enumerated()), id: \.offset) { _, rule in
                                DisclosureGroup(rule.ownerName.isEmpty ? L10n.string("files.permissions.unknownAccount") : rule.ownerName) {
                                    Text(effectTitle(rule.effect))
                                    ForEach(FileACLRight.allCases.filter { rule.rights.contains($0) }, id: \.self) { Text(rightTitle($0)) }
                                }
                            }
                        } else {
                            posixEditor.disabled(!editable || !snapshot.canChangePermissions)
                            if !snapshot.canChangePermissions { Text(L10n.string("files.advanced.adminRequired")).foregroundStyle(.secondary) }
                        }
                        Divider()
                        if item.isDirectory {
                            Toggle(L10n.string("files.permissions.recursive"), isOn: $recursive).disabled(!editable)
                            if recursive {
                                Toggle(L10n.string("files.permissions.confirmRecursive"), isOn: $confirmedRecursive)
                            }
                        }
                        if owner != nil || group != nil {
                            Toggle(L10n.string("files.permissions.confirmOwner"), isOn: $confirmedOwner)
                        }
                        if hasChanges {
                            Text(L10n.string("files.permissions.changeSummary")).font(.headline)
                            if !snapshot.isACL, mode != snapshot.posixMode {
                                Text(L10n.string("files.permissions.modeChange", snapshot.posixMode ?? "—", mode))
                            }
                            ForEach(Array(changedAccountNames.enumerated()), id: \.offset) { _, name in
                                Text(L10n.string("files.permissions.accountChange", name))
                            }
                            if mayRemoveAccess {
                                Toggle(L10n.string("files.permissions.confirmRemoval"), isOn: $confirmedRemoval).disabled(!editable)
                            }
                        }
                        Toggle(L10n.string("files.permissions.confirmChanges"), isOn: $confirmed)
                            .disabled(!editable || !hasChanges)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.fillsAvailableContentArea(alignment: .topLeading)
            } else {
                ContentUnavailableView(L10n.string("files.permissions.loadFailed"), systemImage: "lock.trianglebadge.exclamationmark",
                    description: Text(error ?? L10n.string("files.advanced.readFailed"))).fillsAvailableContentArea()
            }
            if snapshot != nil, let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if let result {
                Text(result.localizationKey.map { L10n.string($0) } ?? (result.status == .confirmedSuccess
                    ? L10n.string("files.permissions.saved") : result.requiresRefresh
                    ? L10n.string("files.permissions.pending") : L10n.string("files.permissions.failed")))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L10n.string("files.common.close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Spacer()
                if snapshot == nil && !loading {
                    Button(L10n.string("files.sharing.refresh")) { Task { await load() } }
                }
                if result?.requiresRefresh == true {
                    Button(L10n.string("files.permissions.review")) { Task { await save(review: true) } }.disabled(busy)
                } else {
                    Button(L10n.string("files.permissions.save")) { Task { await save(review: false) } }
                        .accessibilityIdentifier("filePermissions.save")
                        .buttonStyle(.borderedProminent)
                        .disabled(!editable || !hasChanges || !confirmed || (recursive && !confirmedRecursive)
                            || ((owner != nil || group != nil) && !confirmedOwner) || (mayRemoveAccess && !confirmedRemoval))
                }
            }
        }.padding(24).frame(width: 720, height: 680)
            .task { await load() }
            .sheet(isPresented: Binding(get: { pickerRole != nil }, set: { if !$0 { pickerRole = nil } })) {
                FileStationPrincipalPicker(model: model, selection: $picked) { applyPicked() }
            }
            .onChange(of: rules) { _, _ in resetConfirmation() }
            .onChange(of: mode) { _, _ in resetConfirmation() }
            .onChange(of: owner) { _, _ in resetConfirmation() }
            .onChange(of: group) { _, _ in resetConfirmation() }
            .onChange(of: recursive) { _, _ in resetConfirmation() }
    }

    private var editable: Bool { !busy && submitted == nil && access?.writesEnabled == true }
    private var hasChanges: Bool {
        guard let snapshot else { return false }
        return rules != snapshot.rules.filter { $0.level == 0 } || mode != (snapshot.posixMode ?? "000") || owner != nil || group != nil
    }
    private var removedRules: [FileACLRule] {
        snapshot?.rules.filter { old in old.level == 0 && !rules.contains { sameAccount($0, old) } } ?? []
    }
    private var changedAccountNames: [String] {
        guard let snapshot, snapshot.isACL else { return [] }
        let old = snapshot.rules.filter { $0.level == 0 }
        return Array(Set(old.filter { !rules.contains($0) }.map(\.ownerName)
            + rules.filter { !old.contains($0) }.map(\.ownerName))).sorted()
    }
    private var mayRemoveAccess: Bool {
        guard let snapshot else { return false }
        if let original = snapshot.posixMode, let old = Int(original, radix: 8), let new = Int(mode, radix: 8) { return old & ~new != 0 }
        let old = snapshot.rules.filter { $0.level == 0 }
        if !removedRules.isEmpty { return true }
        return rules.contains { rule in
            guard let previous = old.first(where: { sameAccount($0, rule) }) else { return rule.effect == .deny }
            return previous.effect != rule.effect || previous.inheritance != rule.inheritance
                || (rule.effect == .allow ? !previous.rights.isSubset(of: rule.rights) : !rule.rights.isSubset(of: previous.rights))
        }
    }
    private func sameAccount(_ lhs: FileACLRule, _ rhs: FileACLRule) -> Bool {
        lhs.ownerType == rhs.ownerType && lhs.ownerName == rhs.ownerName && lhs.ownerID == rhs.ownerID && lhs.effect == rhs.effect
    }

    private func ownerFields(_ snapshot: FilePermissionSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("files.permissions.owner", snapshot.owner?.name ?? snapshot.target.owner ?? "—"))
            if let owner { Text(L10n.string("files.permissions.newOwner", owner.name)).bold() }
            HStack {
                Button(L10n.string("files.permissions.chooseOwner")) { picked = []; pickerRole = 1 }
                if owner != nil { Button(L10n.string("files.permissions.keepOwner")) { owner = nil } }
            }.disabled(!editable || access?.isAdministrator != true || (snapshot.isACL && snapshot.owner?.canChange != true))
            if !snapshot.isACL {
                Text(L10n.string("files.permissions.group", snapshot.target.group ?? "—"))
                if let group { Text(L10n.string("files.permissions.newGroup", group.name)).bold() }
                HStack {
                    Button(L10n.string("files.permissions.chooseGroup")) { picked = []; pickerRole = 2 }
                    if group != nil { Button(L10n.string("files.permissions.keepGroup")) { group = nil } }
                }.disabled(!editable || access?.isAdministrator != true)
            }
        }
    }
    private func ruleEditor(_ index: Int) -> some View {
        DisclosureGroup {
            Picker(L10n.string("files.permissions.effect"), selection: $rules[index].effect) {
                ForEach(FileACLRule.Effect.allCases, id: \.self) { Text(effectTitle($0)).tag($0) }
            }
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], alignment: .leading) {
                ForEach(FileACLRight.allCases, id: \.self) { right in
                    Toggle(rightTitle(right), isOn: Binding(get: { rules[index].rights.contains(right) }, set: { enabled in
                        if enabled { rules[index].rights.insert(right) } else { rules[index].rights.remove(right) }
                    }))
                }
            }
            if item.isDirectory {
                ForEach(FileACLInheritance.allCases, id: \.self) { scope in
                    Toggle(inheritanceTitle(scope), isOn: Binding(get: { rules[index].inheritance.contains(scope) }, set: { enabled in
                        if enabled { rules[index].inheritance.insert(scope) } else { rules[index].inheritance.remove(scope) }
                    }))
                }
            }
            Button(L10n.string("files.permissions.removeRule"), role: .destructive) { rules.remove(at: index) }
        } label: {
            Text(rules[index].ownerName.isEmpty ? L10n.string("files.permissions.unknownAccount") : rules[index].ownerName)
            Text(effectTitle(rules[index].effect)).foregroundStyle(.secondary)
        }
    }
    private var posixEditor: some View {
        Grid(alignment: .leading) {
            ForEach(0..<3, id: \.self) { index in
                GridRow {
                    Text(index == 0 ? L10n.string("files.permissions.ownerRole") : index == 1
                        ? L10n.string("files.permissions.groupRole") : L10n.string("files.permissions.everyoneRole"))
                    ForEach([4, 2, 1], id: \.self) { bit in
                        Toggle(bit == 4 ? L10n.string("files.permissions.read") : bit == 2
                            ? L10n.string("files.permissions.write") : L10n.string("files.permissions.execute"), isOn: Binding(get: {
                                (Int(String(Array(mode)[index])) ?? 0) & bit != 0
                            }, set: { value in
                                var digits = Array(mode)
                                let old = Int(String(digits[index])) ?? 0
                                digits[index] = Character(String(value ? old | bit : old & ~bit)); mode = String(digits)
                            }))
                    }
                }
            }
        }
    }
    private func applyPicked() {
        defer { pickerRole = nil }
        if pickerRole == 0 {
            for principal in picked.sorted(by: { $0.id < $1.id }) where !rules.contains(where: { $0.ownerName == principal.name && $0.ownerType == principal.kind.rawValue }) {
                rules.append(.init(ownerType: principal.kind.rawValue, ownerName: principal.name, effect: .allow,
                    rights: [.readData, .readAttributes, .readExtendedAttributes, .readPermissions], inheritance: [.thisFolder]))
            }
        } else {
            guard picked.count == 1, let principal = picked.first,
                  pickerRole != 2 || principal.kind == .group,
                  snapshot?.isACL == true || pickerRole != 1 || principal.kind == .user else {
                error = L10n.string("files.permissions.chooseOne"); return
            }
            if pickerRole == 1 { owner = principal } else { group = principal }
        }
        error = nil
    }
    private func resetConfirmation() { confirmed = false; confirmedOwner = false; confirmedRecursive = false; confirmedRemoval = false }
    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            let loaded = try await model.loadFilePermissions(item)
            snapshot = loaded; rules = loaded.rules.filter { $0.level == 0 }; mode = loaded.posixMode ?? "000"
            access = try await model.loadFileStationAdvancedAccess()
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.permissions.loadFailed") }
    }
    private func save(review: Bool) async {
        guard let snapshot, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let change: FilePermissionChange
            if review, let submitted { change = submitted }
            else {
                change = .init(baseline: snapshot, explicitRules: snapshot.isACL && rules != snapshot.rules.filter { $0.level == 0 } ? rules : nil,
                    posixMode: !snapshot.isACL && mode != snapshot.posixMode ? mode : nil,
                    owner: owner, group: group, recursive: recursive,
                    confirmedScope: confirmedRecursive, confirmedOwner: confirmedOwner, confirmedAccessRemoval: !mayRemoveAccess || confirmedRemoval)
                submitted = change
            }
            result = try await model.changeFilePermissions(change, reviewOnly: review)
        } catch { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.permissions.failed") }
    }
    private func effectTitle(_ effect: FileACLRule.Effect) -> String {
        effect == .allow ? L10n.string("files.permissions.allow") : L10n.string("files.permissions.deny")
    }
    private func inheritanceTitle(_ scope: FileACLInheritance) -> String {
        switch scope {
        case .thisFolder: L10n.string("files.permissions.scope.current")
        case .childFiles: L10n.string("files.permissions.scope.files")
        case .childFolders: L10n.string("files.permissions.scope.folders")
        case .allDescendants: L10n.string("files.permissions.scope.descendants")
        }
    }
    private func rightTitle(_ right: FileACLRight) -> String {
        switch right {
        case .readData: L10n.string("files.permissions.right.read")
        case .writeData: L10n.string("files.permissions.right.write")
        case .execute: L10n.string("files.permissions.right.execute")
        case .append: L10n.string("files.permissions.right.append")
        case .delete: L10n.string("files.permissions.right.delete")
        case .deleteChildren: L10n.string("files.permissions.right.deleteChildren")
        case .readAttributes: L10n.string("files.permissions.right.readAttributes")
        case .writeAttributes: L10n.string("files.permissions.right.writeAttributes")
        case .readExtendedAttributes: L10n.string("files.permissions.right.readExtended")
        case .writeExtendedAttributes: L10n.string("files.permissions.right.writeExtended")
        case .readPermissions: L10n.string("files.permissions.right.readPermissions")
        case .changePermissions: L10n.string("files.permissions.right.changePermissions")
        case .takeOwnership: L10n.string("files.permissions.right.owner")
        }
    }
}
