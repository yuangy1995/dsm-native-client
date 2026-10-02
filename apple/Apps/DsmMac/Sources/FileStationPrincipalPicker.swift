import DsmCore
import DsmLocalization
import SwiftUI

struct FileStationPrincipalPicker: View {
    let model: WorkspaceModel
    @Binding var selection: Set<FileStationPrincipal>
    let onClose: () -> Void
    @State private var query = ""
    @State private var items: [FileStationPrincipal] = []
    @State private var nextOffset = 0
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("files.sharing.chooseAudience")).font(.title2.bold())
            TextField(L10n.string("files.principals.search"), text: $query).textFieldStyle(.roundedBorder)
            if loading && items.isEmpty {
                ProgressView().fillsAvailableContentArea()
            } else if let error {
                ContentUnavailableView {
                    Label(L10n.string("files.principals.loadFailed"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button(L10n.string("files.sharing.refresh")) { Task { await load(reset: true) } }
                }.fillsAvailableContentArea()
            } else if items.isEmpty {
                ContentUnavailableView(L10n.string("files.principals.empty"), systemImage: "person.crop.circle.badge.questionmark",
                    description: Text(L10n.string("files.principals.emptyDetail"))).fillsAvailableContentArea()
            } else {
                List(items) { item in
                    Toggle(isOn: Binding(get: { selection.contains(item) }, set: { selected in
                        if selected { selection.insert(item) } else { selection.remove(item) }
                    })) {
                        Label(item.name, systemImage: item.kind == .user ? "person" : "person.2")
                        Text(item.kind == .user ? L10n.string("files.principals.user") : L10n.string("files.principals.group"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.toggleStyle(.checkbox)
                }
                if nextOffset < total {
                    Button(L10n.string("files.principals.more")) { Task { await load(reset: false) } }.disabled(loading)
                }
            }
            HStack {
                Text(L10n.string("files.principals.selected", String(selection.count))).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("files.common.close"), action: onClose).keyboardShortcut(.cancelAction)
            }
        }.padding(24).frame(width: 480, height: 460)
            .task(id: query) { await load(reset: true) }
            .onDisappear { generation = UUID() }
    }

    private func load(reset: Bool) async {
        let token: UUID
        if reset {
            token = UUID(); generation = token; items = []; nextOffset = 0; total = 0
        } else {
            guard !loading else { return }
            token = generation
        }
        loading = true; error = nil
        do {
            let page = try await model.loadFileStationPrincipals(prefix: query, offset: nextOffset)
            guard token == generation, !Task.isCancelled else { return }
            let ids = Set(items.map(\.id))
            items += page.items.filter { !ids.contains($0.id) }
            nextOffset = page.nextOffset; total = page.total; loading = false
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            loading = false
            self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("files.principals.loadFailed")
        }
    }
}
