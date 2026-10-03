import DsmCore
import DsmLocalization
import SwiftUI

struct MobileFileAdvancedSearchView: View {
    let repository: any MobileFileBrowsing
    let apply: (FileSearchRequest?) -> Void
    @State private var request: FileSearchRequest
    @State private var minimumSize: String
    @State private var maximumSize: String
    @State private var sizeUnit: Int64 = 1
    @State private var showsFolderPicker = false
    @Environment(\.dismiss) private var dismiss

    init(repository: any MobileFileBrowsing, request: FileSearchRequest, apply: @escaping (FileSearchRequest?) -> Void) {
        self.repository = repository; self.apply = apply
        _request = State(initialValue: request)
        _minimumSize = State(initialValue: request.minimumBytes.map(String.init) ?? "")
        _maximumSize = State(initialValue: request.maximumBytes.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(L10n.string("ui.9c8bd1565def7849"), text: $request.name)
                        .accessibilityIdentifier("files.search.name")
                    TextField(L10n.string("files.search.extension"), text: $request.fileExtension)
                        .accessibilityIdentifier("files.search.extension")
                    Picker(L10n.string("files.search.kind"), selection: $request.kind) {
                        Text(L10n.string("files.search.kind.all")).tag(FileSearchKind.all)
                        Text(L10n.string("files.search.kind.file")).tag(FileSearchKind.file)
                        Text(L10n.string("files.search.kind.directory")).tag(FileSearchKind.directory)
                    }
                    Toggle(L10n.string("files.search.contents"), isOn: $request.searchesContents)
                }
                Section(L10n.string("mobile.files.search.locations")) {
                    ForEach(request.folders, id: \.self) { folder in
                        HStack {
                            Text(folder).lineLimit(3).truncationMode(.middle)
                            Spacer()
                            Button {
                                request.folders.removeAll { $0 == folder }
                            } label: {
                                Image(systemName: "minus.circle").frame(width: 44, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.string("files.search.removeLocation"))
                            .accessibilityValue(folder)
                        }
                    }
                    Button(L10n.string("files.search.addLocation")) { showsFolderPicker = true }
                        .accessibilityIdentifier("files.search.addLocation")
                    Toggle(L10n.string("files.search.subfolders"), isOn: $request.recursive)
                }
                Section {
                    TextField(L10n.string("files.search.minimumSize"), text: $minimumSize).keyboardType(.decimalPad)
                    TextField(L10n.string("files.search.maximumSize"), text: $maximumSize).keyboardType(.decimalPad)
                    Picker(L10n.string("files.search.sizeUnit"), selection: $sizeUnit) {
                        Text(L10n.string("files.search.bytes")).tag(Int64(1))
                        Text(L10n.string("files.search.mib")).tag(Int64(1_048_576))
                        Text(L10n.string("files.search.gib")).tag(Int64(1_073_741_824))
                    }
                }
                Section(L10n.string("files.search.dates")) {
                    MobileFileSearchDateRange(title: L10n.string("files.search.modified"), range: $request.modified)
                    MobileFileSearchDateRange(title: L10n.string("files.search.created"), range: $request.created)
                    MobileFileSearchDateRange(title: L10n.string("files.search.accessed"), range: $request.accessed)
                }
                Section {
                    TextField(L10n.string("files.search.owner"), text: $request.owner)
                    TextField(L10n.string("files.search.group"), text: $request.group)
                }
                Section {
                    if resolved == nil {
                        Text(L10n.string(request.searchesContents && request.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "mobile.files.search.keyword-needed" : "files.search.invalidConditions")).foregroundStyle(.secondary)
                    }
                    Button(L10n.string("files.search.reset")) { apply(nil); dismiss() }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle(L10n.string("files.search.advanced"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("files.search.apply")) {
                        if let resolved { apply(resolved); dismiss() }
                    }.disabled(resolved == nil).accessibilityIdentifier("files.search.apply")
                }
            }
            .sheet(isPresented: $showsFolderPicker) {
                MobileFileFolderPicker(repository: repository) { path in
                    if !request.folders.contains(path) { request.folders.append(path) }
                }
            }
        }
    }

    private var resolved: FileSearchRequest? {
        Self.resolve(request, minimum: minimumSize, maximum: maximumSize, unit: sizeUnit)
    }

    static func resolve(_ request: FileSearchRequest, minimum: String, maximum: String, unit: Int64) -> FileSearchRequest? {
        var value = request
        value.minimumBytes = nil; value.maximumBytes = nil
        for (text, keyPath) in [(minimum, \FileSearchRequest.minimumBytes), (maximum, \FileSearchRequest.maximumBytes)] {
            let text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard text.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
                  let number = Decimal(string: text, locale: L10n.locale), number >= 0, unit > 0 else { return nil }
            let bytes = number * Decimal(unit)
            guard !bytes.isNaN, bytes <= Decimal(Int64.max) else { return nil }
            value[keyPath: keyPath] = NSDecimalNumber(decimal: bytes).int64Value
        }
        return value.isValid ? value : nil
    }
}

private struct MobileFileSearchDateRange: View {
    let title: String
    @Binding var range: FileSearchTimeRange
    var body: some View {
        DisclosureGroup(title) {
            Toggle(L10n.string("files.search.after"), isOn: enabled(\.from))
            if range.from != nil {
                DatePicker(L10n.string("files.search.after"), selection: date(\.from))
            }
            Toggle(L10n.string("files.search.before"), isOn: enabled(\.to))
            if range.to != nil {
                DatePicker(L10n.string("files.search.before"), selection: date(\.to))
            }
        }
    }
    private func enabled(_ path: WritableKeyPath<FileSearchTimeRange, Date?>) -> Binding<Bool> {
        Binding(get: { range[keyPath: path] != nil }, set: { range[keyPath: path] = $0 ? Date() : nil })
    }
    private func date(_ path: WritableKeyPath<FileSearchTimeRange, Date?>) -> Binding<Date> {
        Binding(get: { range[keyPath: path] ?? Date() }, set: { range[keyPath: path] = $0 })
    }
}
