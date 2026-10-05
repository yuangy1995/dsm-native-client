import DsmCore
import DsmLocalization
import SwiftUI

struct MobileDownloadRSSView: View {
    @Bindable var downloads: MobileDownloadsModel
    var fileRepository: (any MobileFileBrowsing)?
    @State private var search = ""
    @State private var activation: UUID
    @State private var createActivation: UUID
    @Environment(\.dismiss) private var dismiss
    private var model: MobileDownloadRSSModel { downloads.rss }
    private var filtered: [DownloadRSSSite] { (model.sites ?? []).filter { rssMatches($0.title, search) } }
    private var errorKey: String? { model.recovery.failed ? "download.rss.storage-error" : model.errorKey }
    private var missingEntries: [MobileDownloadRSSStore.Entry] {
        model.entries.filter { entry in entry.unfinished && model.sites?.contains(where: { $0.id == entry.siteID }) != true }
    }

    init(downloads: MobileDownloadsModel, fileRepository: (any MobileFileBrowsing)?) {
        self.downloads = downloads; self.fileRepository = fileRepository
        _activation = State(initialValue: downloads.rss.activation); _createActivation = State(initialValue: downloads.editActivation)
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty && missingEntries.isEmpty {
                    if let errorKey {
                        rssError(errorKey).padding().fillsAvailableContentArea()
                    } else if let sites = model.sites {
                        rssEmpty(sites.isEmpty ? "download.rss.empty" : "download.rss.filtered-empty",
                            sites.isEmpty ? "download.rss.empty-help" : "download.rss.filter-help")
                            .fillsAvailableContentArea()
                    } else {
                        ProgressView(L10n.string("download.rss.loading")).fillsAvailableContentArea()
                    }
                } else {
                    List {
                        if let errorKey { rssError(errorKey) }
                        ForEach(filtered) { site in
                            NavigationLink {
                                MobileDownloadRSSFeedsView(downloads: downloads, site: site, fileRepository: fileRepository,
                                    activation: activation, createActivation: createActivation)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(rssTitle(site.title)).font(.headline)
                                    rssSiteStatus(site)
                                }
                                .frame(minHeight: MobileMetrics.minimumTouchTarget, alignment: .leading)
                            }
                            .accessibilityIdentifier("downloads.rss.site.\(site.id)")
                        }
                        ForEach(missingEntries) { entry in
                            Section(L10n.string("download.rss.previous-update")) { rssReceipt(entry) }
                        }
                    }
                }
            }
            .accessibilityIdentifier("downloads.rss.sites")
            .fillsAvailableContentArea(alignment: .topLeading)
            .navigationTitle(L10n.string("download.rss.title"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                MobileDownloadRSSSearchField(text: $search, promptKey: "download.rss.search-sites")
            }
            .refreshable { await model.load() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.accessibilityIdentifier("downloads.rss.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.load() } } label: { Label(L10n.string("download.rss.reload"), systemImage: "arrow.clockwise") }
                        .disabled(model.isLoading || model.isUpdating).accessibilityIdentifier("downloads.rss.reload")
                }
            }
        }
        .task { await model.load() }
        .onChange(of: model.activation) { _, _ in dismiss() }
    }
}

private struct MobileDownloadRSSFeedsView: View {
    @Bindable var downloads: MobileDownloadsModel
    let site: DownloadRSSSite
    var fileRepository: (any MobileFileBrowsing)?
    let activation: UUID
    let createActivation: UUID
    @State private var search = ""
    @State private var createDraft: MobileDownloadCreateDraft?
    private var model: MobileDownloadRSSModel { downloads.rss }
    private var current: DownloadRSSSite { model.sites?.first { $0.id == site.id && $0.identityDigest == site.identityDigest } ?? site }
    private var filtered: [DownloadRSSFeed] { (model.feeds ?? []).filter { rssMatches($0.title, search) } }

    var body: some View {
        List {
            Section {
                rssSiteStatus(current)
                if let entry = model.entry(for: site) { rssReceipt(entry) }
                if model.isUpdating { ProgressView(L10n.string("download.rss.sending")) }
                Button(L10n.string("download.rss.update")) { model.update(current, activation: activation) }
                    .disabled(activation != model.activation || !model.canUpdate(current)).frame(minHeight: MobileMetrics.minimumTouchTarget)
                    .accessibilityIdentifier("downloads.rss.update")
            }
            if let key = model.recovery.failed ? "download.rss.storage-error" : model.feedErrorKey ?? model.errorKey { rssError(key) }
            if model.isLoadingFeeds && model.feeds == nil { ProgressView(L10n.string("download.rss.loading-feeds")) }
            else if let feeds = model.feeds {
                if feeds.isEmpty { rssEmpty("download.rss.empty-feeds", "download.rss.empty-feeds-help") }
                else if filtered.isEmpty { rssEmpty("download.rss.filtered-empty", "download.rss.filter-help") }
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, feed in
                    Section {
                        Text(rssTitle(feed.title)).font(.headline).fixedSize(horizontal: false, vertical: true)
                        LabeledContent(L10n.string("mobile.downloads.bt-search.result.size"), value: MobileDownloadPresentation.bytes(feed.sizeBytes))
                        LabeledContent(L10n.string("download.rss.published"), value: rssDate(feed.time))
                        Button {
                            downloads.dismissDownloadCreateFeedback()
                            createDraft = .init(activation: createActivation, source: .link(feed.downloadURI))
                        } label: { Label(L10n.string("mobile.downloads.bt-search.result.create"), systemImage: "plus.circle") }
                            .disabled(createActivation != downloads.editActivation || !downloads.canCreateDownloadTask || feed.downloadURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .frame(minHeight: MobileMetrics.minimumTouchTarget)
                            .accessibilityHint(L10n.string("mobile.downloads.bt-search.result.create.hint"))
                            .accessibilityIdentifier("downloads.rss.create.\(index)")
                    }
                }
            }
        }
        .accessibilityIdentifier("downloads.rss.feeds")
        .fillsAvailableContentArea(alignment: .topLeading)
        .navigationTitle(rssTitle(current.title))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top) {
            MobileDownloadRSSSearchField(text: $search, promptKey: "download.rss.search-feeds")
        }
        .refreshable { await model.loadFeeds(site) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.loadFeeds(site) } } label: { Label(L10n.string("download.rss.reload"), systemImage: "arrow.clockwise") }
                    .disabled(model.isLoadingFeeds || model.isUpdating).accessibilityIdentifier("downloads.rss.reload-feeds")
            }
        }
        .task(id: site.id) { await model.loadFeeds(site) }
        .sheet(item: $createDraft) { draft in MobileDownloadCreateTaskView(model: downloads, draft: draft, fileRepository: fileRepository) }
        .onChange(of: model.activation) { _, _ in createDraft = nil }
    }
}

private struct MobileDownloadRSSSearchField: View {
    @Binding var text: String
    let promptKey: String
    @FocusState private var isFocused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(L10n.string(promptKey), text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                .focused($isFocused).onSubmit { isFocused = false }
                .frame(minHeight: MobileMetrics.minimumTouchTarget)
                .accessibilityIdentifier(promptKey)
            if !text.isEmpty {
                Button { text = ""; isFocused = false } label: { Image(systemName: "xmark.circle.fill") }
                    .frame(minWidth: MobileMetrics.minimumTouchTarget, minHeight: MobileMetrics.minimumTouchTarget)
                    .accessibilityLabel(L10n.string("workspace.search.clear"))
                    .accessibilityIdentifier(promptKey + ".clear")
            }
        }.padding(.horizontal).padding(.vertical, 4).background(.bar)
    }
}

private func rssMatches(_ title: String, _ query: String) -> Bool {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: L10n.locale) != nil
}
private func rssTitle(_ title: String) -> String { title.isEmpty ? L10n.string("download.rss.untitled") : title }
private func rssDate(_ timestamp: Int64) -> String {
    guard timestamp > 0 else { return MobileDownloadPresentation.unknown }
    return Date(timeIntervalSince1970: Double(timestamp)).formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))
}
private func rssSiteStatus(_ site: DownloadRSSSite) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        if site.isUpdating { Label(L10n.string("download.rss.updating"), systemImage: "arrow.clockwise") }
        LabeledContent(L10n.string("download.rss.last-update"), value: rssDate(site.lastUpdate))
    }.font(.subheadline).foregroundStyle(.secondary)
}
private func rssReceipt(_ entry: MobileDownloadRSSStore.Entry) -> some View {
    let key: String
    switch entry.phase {
    case .submitted: key = "download.rss.unknown"
    case .accepted: key = "download.rss.accepted"
    case .updated: key = "download.rss.updated"
    case .denied: key = "download.rss.permission"
    case .rejected: key = "download.rss.rejected"
    case .cancelled: key = "download.rss.cancelled"
    }
    return Text(L10n.string(key)).font(.subheadline).accessibilityIdentifier("downloads.rss.receipt.\(entry.siteID)")
}
private func rssError(_ key: String) -> some View {
    Label(L10n.string(key), systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).accessibilityElement(children: .combine)
}
private func rssEmpty(_ title: String, _ help: String) -> some View {
    ContentUnavailableView { Label(L10n.string(title), systemImage: "dot.radiowaves.left.and.right") }
        description: { Text(L10n.string(help)) }
}
