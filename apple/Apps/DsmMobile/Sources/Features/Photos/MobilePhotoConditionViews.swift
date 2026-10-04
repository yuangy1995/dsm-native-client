import DsmCore
import DsmLocalization
import SwiftUI

struct MobilePhotoConditionForm: View {
    @Bindable var editor: MobilePhotoConditionModel
    let draft: MobilePhotoConditionModel.Draft
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRebuild = false
    @FocusState private var focused: Field?
    private enum Field: Hashable { case name, search }

    var body: some View {
        NavigationStack {
            Form {
                if editor.isLoading { ProgressView(L10n.string(draft.restoring ? "mobile.photos.frozen.loading" : "mobile.photos.condition.loading")) }
                else if let error = editor.error {
                    Text(error).foregroundStyle(.red)
                    Button(L10n.string("photos.retry")) { editor.load() }
                } else {
                    if draft.restoring { restoration }
                    if !draft.restoring || editor.rebuild { rules }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(L10n.string(draft.restoring ? "photos.frozen.restore" : "mobile.photos.condition.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.delete.cancel")) { editor.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saveTitle) {
                        focused = nil
                        if draft.restoring && editor.rebuild { confirmingRebuild = true }
                        else if editor.submit() { dismiss() }
                    }
                        .disabled(editor.mutation == nil).accessibilityIdentifier("mobile.photos.condition.save")
                }
            }
            .alert(L10n.string("mobile.photos.frozen.confirmTitle"), isPresented: $confirmingRebuild) {
                Button(L10n.string("mobile.photos.frozen.replace"), role: .destructive) {
                    if editor.submit(confirmedRebuild: true) { dismiss() }
                }
                Button(L10n.string("photos.delete.cancel"), role: .cancel) { }
            } message: { Text(L10n.string("mobile.photos.frozen.confirmMessage")) }
        }
    }
    private var saveTitle: String {
        if draft.restoring { return L10n.string(editor.rebuild ? "mobile.photos.frozen.rebuild" : "mobile.photos.frozen.restore") }
        return L10n.string(draft.editing ? "mobile.photos.album.save" : "mobile.photos.condition.create")
    }
    private var restoration: some View {
        Section {
            if let frozen = editor.frozen, !frozen.unsupportedConditions.isEmpty {
                LabeledContent(L10n.string("photos.frozen.unsupported")) {
                    Text(frozen.unsupportedConditions.keys.sorted().map(frozenTitle).joined(separator: L10n.string("photos.frozen.separator")))
                }
            }
            if editor.canRebuild {
                Picker(L10n.string("photos.frozen.action"), selection: $editor.rebuild) {
                    Text(L10n.string("mobile.photos.frozen.regular")).tag(false)
                    Text(L10n.string("mobile.photos.condition.title")).tag(true)
                }.accessibilityIdentifier("mobile.photos.frozen.action")
            }
            Text(L10n.string(editor.rebuild ? "mobile.photos.frozen.confirmMessage" : "photos.frozen.ordinaryHint"))
                .foregroundStyle(.secondary)
        }
    }
    private func frozenTitle(_ key: String) -> String {
        switch key {
        case "recently_add": L10n.string("photos.frozen.recentlyAdded")
        case "recently_comment": L10n.string("photos.frozen.recentlyCommented")
        case "update_time": L10n.string("photos.frozen.updated")
        case "people": L10n.string("photos.frozen.people")
        case "geocoding": L10n.string("photos.frozen.location")
        case "rating": L10n.string("photos.frozen.rating")
        case "camera": L10n.string("photos.frozen.camera")
        case "lens": L10n.string("photos.frozen.lens")
        case "flash": L10n.string("photos.frozen.flash")
        default: L10n.string("photos.frozen.other")
        }
    }
    @ViewBuilder private var rules: some View {
        Section {
            if !draft.editing {
                TextField(L10n.string("photos.manage.albumName"), text: $editor.name)
                    .focused($focused, equals: .name).accessibilityIdentifier("mobile.photos.condition.name")
            }
            if editor.model.conditionSourceSpaces.count > 1 {
                Picker(L10n.string("photos.condition.source"), selection: Binding(get: { editor.condition.sourceSpace }, set: { editor.switchSource($0) })) {
                    ForEach(editor.model.conditionSourceSpaces, id: \.self) { space in
                        Text(L10n.string(space == .personal ? "shared.51fcaa8035fc61e2" : "shared.17d2e16862f16829")).tag(space)
                    }
                }.accessibilityIdentifier("mobile.photos.condition.source")
            }
            Picker(L10n.string("photos.condition.media"), selection: Binding(get: {
                let values = editor.condition.values("item_type")
                return values.isEmpty ? 0 : values == [.integer(-1)] ? -1 : values == [.integer(-2)] ? -2 : -3
            }, set: { if $0 != -3 { editor.condition.setValues($0 == 0 ? [] : [.integer($0)], for: "item_type") } })) {
                Text(L10n.string("photos.condition.allMedia")).tag(0)
                Text(L10n.string("photos.condition.photos")).tag(-1)
                Text(L10n.string("photos.condition.videos")).tag(-2)
                if ![[], [.integer(-1)], [.integer(-2)]].contains(editor.condition.values("item_type")) {
                    Text(L10n.string("photos.condition.existingMedia")).tag(-3)
                }
            }.accessibilityIdentifier("mobile.photos.condition.media")
        }
        dates
        Section(L10n.string("photos.condition.folders")) {
            selectedValues("folder_filter")
            NavigationLink(L10n.string("mobile.photos.condition.chooseFolders")) { MobilePhotoConditionFolders(editor: editor) }
                .accessibilityIdentifier("mobile.photos.condition.folders")
        }
        Section {
            DisclosureGroup(L10n.string("photos.manage.rating")) {
                ForEach(0...5, id: \.self) { rating in
                    Toggle(rating == 0 ? L10n.string("photos.manage.unrated") : L10n.string("mobile.photos.condition.stars", rating), isOn: Binding(get: {
                        editor.condition.values("rating").contains(.integer(rating))
                    }, set: { selected in
                        var values = editor.condition.values("rating").filter { $0 != .integer(rating) }
                        if selected { values.append(.integer(rating)) }
                        editor.condition.setValues(values, for: "rating")
                    }))
                }
            }
        }
        ForEach(SynologyPhotoConditionField.allCases, id: \.self) { field in
            if !editor.condition.values(field.rawValue).isEmpty {
                Section(conditionTitle(field)) {
                    if field.supportsPolicy {
                        Picker(L10n.string("photos.condition.match"), selection: Binding(get: {
                            editor.condition.fields[field.rawValue + "_policy"]?.string ?? "or"
                        }, set: { editor.condition.fields[field.rawValue + "_policy"] = .string($0) })) {
                            Text(L10n.string("photos.condition.matchAll")).tag("and")
                            Text(L10n.string("photos.condition.matchAny")).tag("or")
                        }
                    }
                    selectedValues(field.rawValue)
                }
            }
        }
        addRule
        Section {
            Button(L10n.string("photos.condition.preview")) { focused = nil; editor.preview() }
                .disabled(editor.isCounting || !editor.datesValid).accessibilityIdentifier("mobile.photos.condition.preview")
            if editor.isCounting { ProgressView() }
            if let count = editor.count { Text(L10n.string("photos.condition.count", count)).accessibilityIdentifier("mobile.photos.condition.count") }
            if let error = editor.countError { Text(error).foregroundStyle(.red) }
        }
    }
    private var dates: some View {
        Section {
            ForEach(editor.condition.values("time").indices, id: \.self) { index in
                dateBoundary(index: index, key: "start_time", title: "photos.condition.start")
                dateBoundary(index: index, key: "end_time", title: "photos.condition.end")
                Button(L10n.string("photos.condition.remove"), role: .destructive) {
                    var values = editor.condition.values("time"); values.remove(at: index); editor.condition.setValues(values, for: "time")
                }
            }
            if editor.condition.values("time").isEmpty {
                Button(L10n.string("photos.condition.addDate")) {
                    editor.condition.setValues([.object(["start_time": .integer(Int(Date().timeIntervalSince1970))])], for: "time")
                }
            }
            if !editor.datesValid { Text(L10n.string("photos.condition.invalidDates")).foregroundStyle(.red) }
        }
    }
    @ViewBuilder private func dateBoundary(index: Int, key: String, title: String) -> some View {
        Toggle(L10n.string(title), isOn: Binding(get: { editor.dateObject(index)?[key] != nil }, set: {
            editor.updateDate(index, key: key, date: $0 ? Date() : nil)
        }))
        if let seconds = editor.dateObject(index)?[key]?.integer {
            DatePicker(L10n.string(title), selection: Binding(get: { Date(timeIntervalSince1970: Double(seconds)) }, set: {
                editor.updateDate(index, key: key, date: $0)
            })).environment(\.locale, L10n.locale)
        }
    }
    private var addRule: some View {
        Section {
            Picker(L10n.string("photos.condition.addRule"), selection: $editor.field) {
                ForEach(SynologyPhotoConditionField.allCases.filter { $0 != .flash }, id: \.self) { field in
                    Text(conditionTitle(field)).tag(field)
                }
            }.accessibilityIdentifier("mobile.photos.condition.field")
            TextField(L10n.string("photos.condition.search"), text: $editor.search)
                .focused($focused, equals: .search).accessibilityIdentifier("mobile.photos.condition.search")
                .onSubmit { focused = nil; if editor.field == .keyword { editor.addKeyword() } else { editor.findSuggestions() } }
            if editor.field == .keyword {
                Button(L10n.string("photos.condition.add")) { focused = nil; editor.addKeyword() }
                    .disabled(editor.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("mobile.photos.condition.add")
            } else {
                Button(L10n.string("photos.condition.find")) { focused = nil; editor.findSuggestions() }
                    .disabled(editor.isSearching).accessibilityIdentifier("mobile.photos.condition.find")
                if editor.isSearching { ProgressView() }
                else if let error = editor.suggestionError { Text(error).foregroundStyle(.red) }
                else if (editor.suggestions[editor.field.rawValue] ?? []).isEmpty {
                    Text(L10n.string("photos.condition.noSuggestions")).foregroundStyle(.secondary)
                }
                ForEach(editor.suggestions[editor.field.rawValue] ?? []) { choice in
                    Button { editor.add(choice, key: editor.field.rawValue) } label: {
                        Label(choice.name, systemImage: editor.condition.values(editor.field.rawValue).contains(choice.value) ? "checkmark.circle.fill" : "plus.circle")
                            .frame(minHeight: 44)
                    }
                }
            }
        }
    }
    private func selectedValues(_ key: String) -> some View {
        ForEach(Array(editor.condition.values(key).enumerated()), id: \.offset) { _, value in
            let title = editor.condition.names[key]?.first(where: { $0.value == value })?.name ?? valueTitle(value)
            HStack {
                Text(title)
                Spacer()
                Button { editor.remove(value, key: key) } label: { Image(systemName: "xmark.circle").frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(.borderless).accessibilityLabel(L10n.string("photos.condition.remove")).accessibilityValue(title)
            }
        }
    }
    private func conditionTitle(_ field: SynologyPhotoConditionField) -> String {
        switch field {
        case .keyword: L10n.string("photos.condition.field.keyword")
        case .person: L10n.string("photos.condition.field.person")
        case .concept: L10n.string("photos.condition.field.concept")
        case .general_tag: L10n.string("photos.condition.field.general_tag")
        case .camera: L10n.string("photos.condition.field.camera")
        case .lens: L10n.string("photos.condition.field.lens")
        case .aperture: L10n.string("photos.condition.field.aperture")
        case .iso: L10n.string("photos.condition.field.iso")
        case .geocoding: L10n.string("photos.condition.field.geocoding")
        case .focal_length_group: L10n.string("photos.condition.field.focal_length_group")
        case .exposure_time_group: L10n.string("photos.condition.field.exposure_time_group")
        case .flash: L10n.string("photos.condition.field.flash")
        }
    }
    private func valueTitle(_ value: SynologyPhotoConditionValue) -> String {
        if let text = value.string { return text }
        if let id = value.integer { return L10n.string("photos.condition.missingReference", id) }
        func number(_ value: SynologyPhotoConditionValue?) -> String {
            if let integer = value?.integer { return integer.formatted(.number.locale(L10n.locale)) }
            if case .decimal(let number) = value { return number.formatted(.number.locale(L10n.locale)) }
            if let fraction = value?.object, let num = fraction["num"]?.integer, let den = fraction["den"]?.integer {
                return "\(num.formatted(.number.locale(L10n.locale)))/\(den.formatted(.number.locale(L10n.locale)))"
            }
            return "—"
        }
        return L10n.string("photos.condition.range", number(value.object?["start"]), number(value.object?["end"]))
    }
}

private struct MobilePhotoConditionFolders: View {
    @Bindable var editor: MobilePhotoConditionModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if editor.loadingFolders { ProgressView(L10n.string("mobile.photos.request.loadingFolders")) }
            else if let error = editor.folderError {
                Text(error).foregroundStyle(.red)
                Button(L10n.string("photos.retry")) { editor.loadFolders(path: editor.folderPath) }
            } else {
                if editor.folders.isEmpty { Text(L10n.string("mobile.photos.request.noSubfolders")).foregroundStyle(.secondary) }
                ForEach(editor.folders) { folder in
                    Button { editor.loadFolders(path: editor.folderPath + [folder]) } label: {
                        Label(folder.name, systemImage: "folder").frame(minHeight: 44)
                    }
                }
            }
        }
        .navigationTitle(L10n.string("photos.condition.folders"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(editor.folderPath.enumerated()), id: \.element.id) { index, folder in
                            if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true) }
                            Button(folder.name) { editor.loadFolders(path: Array(editor.folderPath.prefix(index + 1))) }
                                .frame(minHeight: 44).disabled(editor.loadingFolders)
                        }
                    }
                }.scrollIndicators(.hidden)
                Button(L10n.string("photos.condition.addFolder")) { if editor.chooseFolder() { dismiss() } }
                    .frame(minHeight: 44).fixedSize(horizontal: false, vertical: true)
                    .disabled(editor.loadingFolders || editor.folderError != nil || editor.folderPath.isEmpty)
                    .accessibilityIdentifier("mobile.photos.condition.addFolder")
            }.buttonStyle(.bordered).padding(.horizontal).padding(.vertical, 8).background(.regularMaterial)
        }
        .task { editor.loadFolders() }
    }
}
