import DsmCore
import DsmLocalization
import SwiftUI

struct FileAdvancedSearchView: View {
    @Bindable var model: WorkspaceModel
    @State private var request = FileSearchRequest(folders: [])
    @State private var minimumSize = ""
    @State private var maximumSize = ""
    @State private var sizeUnit: Int64 = 1_048_576
    @State private var showsFolderPicker = false
    @State private var showsDateConditions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.string("files.search.advanced")).font(.headline)
                Spacer()
                Button(L10n.string("files.search.reset")) {
                    request = FileSearchRequest(folders: [model.currentPath])
                    minimumSize = ""; maximumSize = ""
                    model.applyAdvancedSearch(nil)
                }
                Button(L10n.string("files.search.apply")) {
                    if let resolved { model.applyAdvancedSearch(resolved) }
                }.buttonStyle(.borderedProminent).disabled(resolved == nil)
            }
            HStack {
                TextField(L10n.string("files.search.extension"), text: $request.fileExtension)
                Picker(L10n.string("files.search.kind"), selection: $request.kind) {
                    Text(L10n.string("files.search.kind.all")).tag(FileSearchKind.all)
                    Text(L10n.string("files.search.kind.file")).tag(FileSearchKind.file)
                    Text(L10n.string("files.search.kind.directory")).tag(FileSearchKind.directory)
                }
                TextField(L10n.string("files.search.owner"), text: $request.owner)
                TextField(L10n.string("files.search.group"), text: $request.group)
            }
            Toggle(L10n.string("files.search.contents"), isOn: $request.searchesContents)
            HStack {
                TextField(L10n.string("files.search.minimumSize"), text: $minimumSize)
                TextField(L10n.string("files.search.maximumSize"), text: $maximumSize)
                Picker(L10n.string("files.search.sizeUnit"), selection: $sizeUnit) {
                    Text(L10n.string("files.search.bytes")).tag(Int64(1))
                    Text(L10n.string("files.search.mib")).tag(Int64(1_048_576))
                    Text(L10n.string("files.search.gib")).tag(Int64(1_073_741_824))
                }.frame(maxWidth: 160)
            }
            DisclosureGroup(L10n.string("files.search.dates"), isExpanded: $showsDateConditions) {
                VStack(alignment: .leading, spacing: 8) {
                    FileSearchDateRangeView(title: L10n.string("files.search.modified"), range: $request.modified)
                    FileSearchDateRangeView(title: L10n.string("files.search.created"), range: $request.created)
                    FileSearchDateRangeView(title: L10n.string("files.search.accessed"), range: $request.accessed)
                }.padding(.top, 8)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading) {
                    ForEach(request.folders, id: \.self) { folder in
                        HStack {
                            Text(folder).lineLimit(1).truncationMode(.middle)
                            Button { request.folders.removeAll { $0 == folder } } label: {
                                Label(L10n.string("files.search.removeLocation"), systemImage: "minus.circle")
                            }.labelStyle(.iconOnly)
                        }
                    }
                }
                Spacer()
                Button(L10n.string("files.search.addLocation")) { showsFolderPicker = true }
                Toggle(L10n.string("files.search.subfolders"), isOn: $request.recursive)
            }
            if resolved == nil { Text(L10n.string("files.search.invalidConditions")).font(.caption).foregroundStyle(.red) }
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 24).padding(.vertical, 12)
        .onAppear {
            request = model.advancedSearch ?? FileSearchRequest(folders: model.currentPath == "/" ? [] : [model.currentPath])
            if model.advancedSearch != nil {
                sizeUnit = 1
                minimumSize = request.minimumBytes.map(String.init) ?? ""
                maximumSize = request.maximumBytes.map(String.init) ?? ""
            }
        }
        .macSheet(isPresented: $showsFolderPicker) {
            FileLocationPicker(model: model) { path in
                if !request.folders.contains(path) { request.folders.append(path) }
            }
        }
    }

    private var resolved: FileSearchRequest? {
        var value = request
        value.name = model.searchText
        value.minimumBytes = nil; value.maximumBytes = nil
        if !minimumSize.isEmpty {
            guard let bytes = Self.bytes(minimumSize, unit: sizeUnit) else { return nil }
            value.minimumBytes = bytes
        }
        if !maximumSize.isEmpty {
            guard let bytes = Self.bytes(maximumSize, unit: sizeUnit) else { return nil }
            value.maximumBytes = bytes
        }
        return value.isValid ? value : nil
    }

    static func bytes(_ text: String, unit: Int64) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: trimmed, locale: L10n.locale), value >= 0 else { return nil }
        let bytes = value * Decimal(unit)
        guard bytes <= Decimal(Int64.max) else { return nil }
        return NSDecimalNumber(decimal: bytes).int64Value
    }
}

private struct FileSearchDateRangeView: View {
    let title: String
    @Binding var range: FileSearchTimeRange
    var body: some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Toggle(L10n.string("files.search.after"), isOn: enabled(\.from))
            if range.from != nil { DatePicker(title, selection: date(\.from), displayedComponents: [.date, .hourAndMinute]).labelsHidden() }
            Toggle(L10n.string("files.search.before"), isOn: enabled(\.to))
            if range.to != nil { DatePicker(title, selection: date(\.to), displayedComponents: [.date, .hourAndMinute]).labelsHidden() }
        }
    }
    private func enabled(_ keyPath: WritableKeyPath<FileSearchTimeRange, Date?>) -> Binding<Bool> {
        Binding(get: { range[keyPath: keyPath] != nil }, set: { range[keyPath: keyPath] = $0 ? Date() : nil })
    }
    private func date(_ keyPath: WritableKeyPath<FileSearchTimeRange, Date?>) -> Binding<Date> {
        Binding(get: { range[keyPath: keyPath] ?? Date() }, set: { range[keyPath: keyPath] = $0 })
    }
}
