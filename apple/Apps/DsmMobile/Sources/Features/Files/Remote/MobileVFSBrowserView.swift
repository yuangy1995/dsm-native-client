import DsmCore
import DsmLocalization
import Foundation
import Observation
import SwiftUI

/// 连接提供的 URI 是独立命名空间，保留原值并交给共享 Repository 验证边界。
@MainActor @Observable
final class MobileVFSBrowserModel {
    struct Folder { let name: String; let path: String }
    let profile: FileVFSProfile
    private(set) var folders: [Folder] = []
    private(set) var items: [FileItem] = []
    private(set) var hasMore = false
    private(set) var loading = false
    private(set) var error: String?
    private var offset = 0
    private var generation: UInt64 = 0
    @ObservationIgnored private let repository: any MobileRemoteLocationServing
    var query = ""
    var path: String { folders.last?.path ?? profile.uri }
    var title: String { folders.last?.name ?? profile.alias }
    var filtered: [FileItem] { items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) } }
    init(repository: any MobileRemoteLocationServing, profile: FileVFSProfile) { self.repository = repository; self.profile = profile }
    func open(_ item: FileItem) async {
        guard item.isDirectory, item.profileID == profile.profileID, items.contains(item), !loading else { return }
        folders.append(.init(name: item.name, path: item.path)); query = ""; await load(reset: true)
    }
    func back() async { guard !folders.isEmpty else { return }; folders.removeLast(); query = ""; await load(reset: true) }
    func cancel() { generation &+= 1; loading = false }
    func load(reset: Bool) async {
        if reset { generation &+= 1; items = []; offset = 0; hasMore = false }
        else { guard !loading, hasMore else { return } }
        let token = generation; loading = true; error = nil
        defer { if token == generation { loading = false } }
        do {
            let page = try await repository.listFileVFSFolder(profile, path: path, offset: offset, limit: 200)
            guard token == generation, !Task.isCancelled else { return }
            guard page.folderPath == path, page.offset == offset, !page.hasMore || !page.items.isEmpty,
                  page.items.allSatisfy({ $0.profileID == profile.profileID }) else { throw URLError(.cannotParseResponse) }
            let old = Set(items.map(\.id)); items += page.items.filter { !old.contains($0.id) }
            offset = page.offset + page.items.count; hasMore = page.hasMore
        } catch {
            guard token == generation, !Task.isCancelled else { return }
            self.error = MobileRemoteLocationsModel.message(error)
        }
    }
}

struct MobileVFSBrowserView: View {
    @State private var browser: MobileVFSBrowserModel
    let download: (FileItem) -> Void
    init(repository: any MobileRemoteLocationServing, profile: FileVFSProfile, download: @escaping (FileItem) -> Void) {
        _browser = State(initialValue: .init(repository: repository, profile: profile)); self.download = download
    }
    var body: some View {
        List {
            if let error = browser.error { Text(error).foregroundStyle(.red) }
            if browser.loading && browser.items.isEmpty { ProgressView() }
            else if browser.error == nil && browser.filtered.isEmpty {
                ContentUnavailableView(L10n.string("files.vfs.folderEmpty"), systemImage: "folder",
                    description: Text(L10n.string(browser.query.isEmpty ? "files.vfs.folderEmptyDetail" : "files.vfs.filteredEmpty")))
            }
            ForEach(browser.filtered) { item in
                HStack {
                    if item.isDirectory {
                        Button { Task { await browser.open(item) } } label: {
                            Label(item.name, systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.disabled(browser.loading)
                    } else {
                        Label(item.name, systemImage: "doc").frame(maxWidth: .infinity, alignment: .leading)
                        Button(L10n.string("files.vfs.download")) { download(item) }
                    }
                }
            }
            if browser.hasMore {
                Button(L10n.string("mobile.files.load-more")) { Task { await browser.load(reset: false) } }.disabled(browser.loading)
            }
        }.navigationTitle(browser.title).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $browser.query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: L10n.string("files.vfs.fileFilter"))
            .refreshable { await browser.load(reset: true) }
            .toolbar {
                ToolbarItemGroup(placement: .confirmationAction) {
                    if !browser.folders.isEmpty {
                        Button { Task { await browser.back() } } label: { Image(systemName: "arrow.up").frame(width: 44, height: 44) }
                            .accessibilityLabel(L10n.string("ui.8e7847be62b68c2b"))
                    }
                    Button { Task { await browser.load(reset: true) } } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("ui.aee88743413144a2")).disabled(browser.loading)
                }
            }.task { await browser.load(reset: true) }.onDisappear { browser.cancel() }
    }
}
