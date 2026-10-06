import DsmCore
import DsmLocalization
import SwiftUI

struct MobileContainerImagePullView: View {
    @Bindable var model: MobileContainerImagePullModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var query = ""
    @State private var showsDownloads = false
    @State private var sourceActivation: UUID?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker(L10n.string("container-image.pull.section"), selection: $showsDownloads) {
                    Text(L10n.string("container-image.pull.search")).tag(false)
                    Text(L10n.string("container-image.pull.tasks")).tag(true)
                }.pickerStyle(.segmented).padding().accessibilityIdentifier("image-pull.section")
                if showsDownloads { downloads }
                else { search }
            }
            .navigationTitle(L10n.string("mobile.containers.pull.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("container-image.pull.close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if showsDownloads {
                        Button(L10n.string("container-image.pull.review"), systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                            .disabled(model.isRefreshing || model.isOperating).accessibilityIdentifier("image-pull.refresh")
                    } else {
                        Button(L10n.string("ui.44ce7ae909bbb28b"), systemImage: "magnifyingglass") { Task { await model.search(query) } }
                            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSearching)
                            .accessibilityIdentifier("image-pull.search")
                    }
                }
            }
        }
        .task {
            sourceActivation = model.activation
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                if scenePhase == .active && showsDownloads && model.hasPollableTasks && !model.isRefreshing && !model.isOperating {
                    await model.refresh()
                }
            }
        }
        .onChange(of: model.activation) { _, value in if sourceActivation != value { dismiss() } }
        .onDisappear { model.cancelVisibleReads() }
    }
    private var search: some View {
        Group {
            if model.isSearching {
                ProgressView(L10n.string("mobile.containers.pull.searching")).accessibilityIdentifier("image-pull.loading")
            } else if let error = model.searchError {
                ContentUnavailableView {
                    Label(L10n.string("container-image.search.failed"), systemImage: "exclamationmark.triangle")
                } description: { Text(error.message) } actions: {
                    Button(L10n.string("container-image.search.retry")) { Task { await model.search(query) } }
                }.accessibilityIdentifier("image-pull.search-error")
            } else if model.results.isEmpty {
                ContentUnavailableView(model.hasSearched ? L10n.string("mobile.containers.pull.no-results") : L10n.string("container-image.pull.search"),
                    systemImage: "magnifyingglass", description: Text(L10n.string("mobile.containers.pull.search-help")))
                    .accessibilityIdentifier("image-pull.search-empty")
            } else {
                List {
                    ForEach(model.results) { image in
                        NavigationLink {
                            MobileContainerImageTagView(model: model, image: image) { showsDownloads = true }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(image.name, systemImage: image.isOfficial ? "checkmark.seal" : "shippingbox")
                                if let description = image.description { Text(description).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                            }.padding(.vertical, 4)
                        }.accessibilityIdentifier("image-pull.result.\(image.id)")
                    }
                    if model.results.count == 50 { Text(L10n.string("mobile.containers.pull.search-limit")).font(.footnote).foregroundStyle(.secondary) }
                }.listStyle(.insetGrouped).accessibilityIdentifier("image-pull.results")
            }
        }
        .fillsAvailableContentArea(alignment: model.results.isEmpty || model.isSearching || model.searchError != nil ? .center : .topLeading)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("mobile.containers.pull.query"))
        .onSubmit(of: .search) { Task { await model.search(query) } }
    }
    private var downloads: some View {
        List {
            if let error = model.error { Text(error.message).foregroundStyle(.secondary).accessibilityIdentifier("image-pull.error") }
            if model.isRefreshing { ProgressView().accessibilityLabel(L10n.string("container-image.pull.review")) }
            if model.entries.isEmpty {
                ContentUnavailableView(L10n.string("container-image.pull.empty"), systemImage: "arrow.down.circle",
                    description: Text(L10n.string("mobile.containers.pull.empty-help")))
            }
            ForEach(model.entries) { entry in
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.names[entry.id] ?? L10n.string("mobile.containers.pull.saved-download")).font(.headline)
                        Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute().locale(L10n.locale)).font(.caption).foregroundStyle(.secondary)
                        Text(entry.message).accessibilityIdentifier("image-pull.record.\(entry.phase.rawValue)")
                        if entry.phase == .downloading, let percentage = entry.percentage {
                            ProgressView(value: percentage, total: 100)
                            Text(L10n.string("container-image.pull.percent", percentage)).font(.caption)
                        }
                    }
                    if !entry.isProtected && !model.recovery.isExecuting(entry.id) {
                        Button(L10n.string("mobile.containers.control.record.remove")) { model.removeRecord(entry.id) }
                    }
                }
            }
        }.listStyle(.insetGrouped).accessibilityIdentifier("image-pull.downloads")
            .refreshable { await model.refresh() }
    }
}

private struct MobileContainerImageTagView: View {
    @Bindable var model: MobileContainerImagePullModel
    let image: ContainerRegistryImage
    let onStarted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tag = ""
    @State private var sourceActivation: UUID?
    var body: some View {
        Group {
            if model.isLoadingTags {
                ProgressView(L10n.string("mobile.containers.pull.loading-tags")).accessibilityIdentifier("image-pull.tags-loading")
            } else if let error = model.tagsError {
                ContentUnavailableView {
                    Label(L10n.string("mobile.containers.pull.tags-failed"), systemImage: "exclamationmark.triangle")
                } description: { Text(error.message) } actions: {
                    Button(L10n.string("container-image.tags.retry")) { Task { await load() } }
                }
            } else if model.tags.isEmpty {
                ContentUnavailableView(L10n.string("mobile.containers.pull.no-tags"), systemImage: "tag",
                    description: Text(L10n.string("mobile.containers.pull.tags-help")))
                    .accessibilityIdentifier("image-pull.tags-empty")
            } else {
                Form {
                    Section {
                        Text(image.name).font(.headline).textSelection(.enabled)
                        if let description = image.description { Text(description).foregroundStyle(.secondary) }
                        if model.tags.count == 1 {
                            LabeledContent(L10n.string("mobile.containers.pull.tag"), value: tag)
                        } else {
                            NavigationLink {
                                MobileContainerImageTagPicker(tags: model.tags, selection: $tag)
                            } label: { LabeledContent(L10n.string("mobile.containers.pull.tag"), value: tag) }
                                .accessibilityValue(tag)
                                .accessibilityIdentifier("image-pull.tag-picker")
                        }
                    }
                    Section {
                        Text(L10n.string("mobile.containers.pull.risk"))
                        if !model.available { Text(L10n.string("container-image.pull.unavailable")).foregroundStyle(.secondary) }
                        if let error = model.error { Text(error.message).foregroundStyle(.secondary) }
                        Button(L10n.string("mobile.containers.pull.download"), systemImage: "arrow.down.circle") {
                            guard sourceActivation == model.activation,
                                  let confirmation = model.confirmation(repository: image.name, tag: tag), model.perform(confirmation) != nil else { return }
                            dismiss(); onStarted()
                        }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44)
                        .disabled(sourceActivation != model.activation || !model.canDownload(repository: image.name, tag: tag))
                        .accessibilityIdentifier("image-pull.download")
                    }
                }.accessibilityIdentifier("image-pull.target")
            }
        }
        .navigationTitle(L10n.string("mobile.containers.pull.download"))
        .navigationBarTitleDisplayMode(.inline)
        .fillsAvailableContentArea(alignment: model.tags.isEmpty || model.isLoadingTags || model.tagsError != nil ? .center : .topLeading)
        .task {
            // 从标签选择返回时保留用户选择，不重新套用默认标签。
            guard sourceActivation == nil else { return }
            sourceActivation = model.activation; await load()
        }
    }
    private func load() async {
        await model.select(image)
        guard sourceActivation == model.activation else { return }
        if !model.tags.contains(tag) { tag = model.tags.contains("latest") ? "latest" : (model.tags.first ?? "") }
    }
}

private struct MobileContainerImageTagPicker: View {
    let tags: [String]
    @Binding var selection: String
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    var matches: [String] { query.isEmpty ? tags : tags.filter { $0.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        List(matches, id: \.self) { tag in
            Button { selection = tag; dismiss() } label: {
                HStack { Text(tag); Spacer(); if tag == selection { Image(systemName: "checkmark").accessibilityHidden(true) } }
            }.frame(minHeight: 44).accessibilityAddTraits(tag == selection ? .isSelected : [])
        }
        .overlay { if matches.isEmpty { ContentUnavailableView.search(text: query) } }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: L10n.string("mobile.containers.pull.tag"))
        .navigationTitle(L10n.string("mobile.containers.pull.tag"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension MobileContainerImagePullModel.Failure {
    var message: String {
        switch self {
        case .read: L10n.string("mobile.containers.pull.read-error")
        case .denied: L10n.string("container-image.pull.permission")
        case .unavailable: L10n.string("container-image.pull.unavailable")
        case .changed: L10n.string("container-image.pull.conflict")
        case .storage: L10n.string("mobile.containers.control.error.storage")
        case .trust: L10n.string("mobile.containers.control.error.trust")
        }
    }
}

private extension MobileContainerImagePullStore.Entry {
    var message: String {
        if phase != .ready && phase != .skipped {
            if failure == .denied { return L10n.string("container-image.pull.permission") }
            if failure == .trust { return L10n.string("mobile.containers.control.error.trust") }
            if failure == .unavailable { return L10n.string("container-image.pull.unavailable") }
            if failure == .changed { return L10n.string("container-image.pull.conflict") }
        }
        switch phase {
        case .prepared: return L10n.string("mobile.containers.pull.preparing")
        case .awaitingReceipt: return L10n.string("container-image.pull.no-receipt")
        case .downloading: return L10n.string("container-image.pull.downloading")
        case .needsReview: return L10n.string("container-image.pull.read-failed")
        case .ready: return L10n.string("container-image.pull.ready")
        case .rejected: return L10n.string("container-image.pull.download-failed")
        case .skipped: return L10n.string("container-image.pull.not-sent")
        }
    }
}
