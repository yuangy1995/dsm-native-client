import DsmCore
import DsmLocalization
import SwiftUI

/// 成员选择只展示接口实际返回的账号和群组；搜索和后续分页共用同一前缀快照。
struct MobileFileStationPrincipalPicker: View {
    @Binding var selection: Set<FileStationPrincipal>
    let load: @MainActor (String, Int) async throws -> FileStationPrincipalPage
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var prefix = ""
    @State private var items: [FileStationPrincipal] = []
    @State private var nextOffset = 0
    @State private var total = 0
    @State private var loading = false
    @State private var failed = false
    @State private var generation = UUID()

    var body: some View {
        NavigationStack {
            List {
                if loading && items.isEmpty { ProgressView().frame(maxWidth: .infinity) }
                else if failed {
                    Section {
                        Text(L10n.string("files.advanced.readFailed"))
                        Button(L10n.string("mobile.files.retry-load-more")) { Task { await fetch(reset: items.isEmpty) } }
                    }
                } else if items.isEmpty { Text(L10n.string("mobile.sharing.members-empty")) }
                ForEach(items) { principal in
                    Button {
                        if selection.contains(principal) { selection.remove(principal) } else { selection.insert(principal) }
                    } label: {
                        HStack {
                            Label(principal.name, systemImage: principal.kind == .user ? "person" : "person.2")
                            Spacer()
                            if selection.contains(principal) { Image(systemName: "checkmark") }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityAddTraits(selection.contains(principal) ? .isSelected : [])
                }
                if nextOffset < total {
                    Button(L10n.string("mobile.files.load-more")) { Task { await fetch(reset: false) } }.disabled(loading)
                }
            }.searchable(text: $query, prompt: L10n.string("files.sharing.chooseAudience"))
                .onSubmit(of: .search) { Task { await fetch(reset: true) } }
                .navigationTitle(L10n.string("files.sharing.chooseAudience"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("mobile.files.share-link.action.done")) { dismiss() } } }
                .task { await fetch(reset: true) }
                .onDisappear { generation = UUID() }
        }
    }
    private func fetch(reset: Bool) async {
        if reset { generation = UUID(); prefix = query; nextOffset = 0; total = 0; items = [] }
        else if loading { return }
        let request = generation, offset = nextOffset
        loading = true; failed = false
        defer { if request == generation { loading = false } }
        do {
            let page = try await load(prefix, offset)
            guard request == generation else { return }
            guard page.nextOffset == offset + page.items.count, page.nextOffset <= page.total,
                  offset == 0 || page.total == total,
                  !page.items.isEmpty || page.nextOffset == page.total,
                  Set(page.items.map(\.id)).count == page.items.count,
                  Set(items.map(\.id)).isDisjoint(with: page.items.map(\.id)) else { failed = true; return }
            items += page.items; nextOffset = page.nextOffset; total = page.total
        } catch { if request == generation { failed = true } }
    }
}
