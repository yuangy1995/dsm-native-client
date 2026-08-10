import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation
import Observation
import SwiftUI

enum MobileDownloadBTSearchModuleMode: String, CaseIterable, Identifiable {
    case enabled
    case all
    case selected

    var id: String { rawValue }
}

@MainActor
@Observable
final class MobileDownloadBTSearchModel {
    var keyword = "" {
        didSet {
            if keyword != oldValue { invalidateSearchPresentation() }
        }
    }
    var titleFilter = "" {
        didSet {
            if titleFilter != oldValue { invalidateSearchPresentation() }
        }
    }
    var moduleMode: MobileDownloadBTSearchModuleMode = .enabled {
        didSet {
            if moduleMode != oldValue { invalidateSearchPresentation() }
        }
    }
    var selectedModuleIDs: Set<String> = [] {
        didSet {
            if selectedModuleIDs != oldValue { invalidateSearchPresentation() }
        }
    }
    var selectedCategoryID: String? {
        didSet {
            if selectedCategoryID != oldValue { invalidateSearchPresentation() }
        }
    }
    var sort: DownloadBTSearchSort = .seeds {
        didSet {
            if sort != oldValue { invalidateSearchPresentation() }
        }
    }
    var direction: DownloadBTSearchDirection = .descending {
        didSet {
            if direction != oldValue { invalidateSearchPresentation() }
        }
    }
    var catalog: DownloadBTSearchCatalog?
    var results: [DownloadBTSearchResult] = []
    var isLoadingCatalog = false
    var isSearching = false
    var hasSearched = false
    var errorMessage: String?

    @ObservationIgnored private var repository: DsmServiceManagementRepository?
    @ObservationIgnored private var repositoryID: ObjectIdentifier?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    var canSearch: Bool {
        guard !isLoadingCatalog,
              !isSearching,
              let catalog,
              Self.isValidSearchText(keyword, required: true),
              Self.isValidSearchText(titleFilter, required: false),
              selectedCategoryID == nil || catalog.categories.contains(where: {
                  $0.id == selectedCategoryID
              }) else {
            return false
        }
        let catalogModuleIDs = Set(catalog.modules.map(\.id))
        switch moduleMode {
        case .all:
            return !catalogModuleIDs.isEmpty
        case .enabled:
            return catalog.modules.contains(where: \.isEnabled)
        case .selected:
            return !selectedModuleIDs.isEmpty && selectedModuleIDs.isSubset(of: catalogModuleIDs)
        }
    }

    var hasInvalidKeyword: Bool {
        !keyword.isEmpty && !Self.isValidSearchText(keyword, required: true)
    }

    var hasInvalidTitleFilter: Bool {
        !Self.isValidSearchText(titleFilter, required: false)
    }

    func activate(repository: DsmServiceManagementRepository?) {
        let nextID = repository.map(ObjectIdentifier.init)
        guard nextID != repositoryID else { return }
        generation &+= 1
        task?.cancel()
        task = nil
        self.repository = repository
        repositoryID = nextID
        keyword = ""
        titleFilter = ""
        moduleMode = .enabled
        selectedCategoryID = nil
        sort = .seeds
        direction = .descending
        catalog = nil
        results = []
        hasSearched = false
        errorMessage = nil
        selectedModuleIDs.removeAll()
        guard repository != nil else {
            isLoadingCatalog = false
            isSearching = false
            return
        }
        loadCatalog()
    }

    func close() {
        generation &+= 1
        task?.cancel()
        task = nil
        repository = nil
        repositoryID = nil
        keyword = ""
        titleFilter = ""
        moduleMode = .enabled
        selectedModuleIDs.removeAll()
        selectedCategoryID = nil
        sort = .seeds
        direction = .descending
        catalog = nil
        results = []
        hasSearched = false
        errorMessage = nil
        isLoadingCatalog = false
        isSearching = false
    }

    func loadCatalog() {
        guard let repository else { return }
        generation &+= 1
        let currentGeneration = generation
        let currentRepositoryID = repositoryID
        task?.cancel()
        errorMessage = nil
        catalog = nil
        selectedModuleIDs.removeAll()
        selectedCategoryID = nil
        isLoadingCatalog = true
        isSearching = false
        task = Task { [weak self, repository] in
            do {
                let catalog = try await repository.loadDownloadBTSearchCatalog()
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self,
                          self.generation == currentGeneration,
                          self.repositoryID == currentRepositoryID else { return }
                    self.catalog = catalog
                    self.selectedModuleIDs = Set(catalog.modules.filter(\.isEnabled).map(\.id))
                    self.isLoadingCatalog = false
                    self.errorMessage = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self,
                          self.generation == currentGeneration else { return }
                    self.isLoadingCatalog = false
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.generation == currentGeneration,
                          self.repositoryID == currentRepositoryID else { return }
                    self.isLoadingCatalog = false
                    self.errorMessage = Self.safeMessage(
                        for: error,
                        fallbackKey: "mobile.downloads.bt-search.catalog.error"
                    )
                }
            }
        }
    }

    func search() {
        guard canSearch,
              let repository else { return }
        let request = DownloadBTSearchRequest(
            keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            moduleScope: moduleScope,
            categoryID: selectedCategoryID,
            sort: sort,
            direction: direction,
            titleFilter: titleFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        generation &+= 1
        let currentGeneration = generation
        let currentRepositoryID = repositoryID
        task?.cancel()
        isSearching = true
        hasSearched = true
        errorMessage = nil
        results = []
        task = Task { [weak self, repository, request] in
            do {
                let results = try await repository.searchDownloadBT(request)
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self,
                          self.generation == currentGeneration,
                          self.repositoryID == currentRepositoryID else { return }
                    self.results = results
                    self.isSearching = false
                    self.errorMessage = nil
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard let self,
                          self.generation == currentGeneration else { return }
                    self.isSearching = false
                }
            } catch {
                await MainActor.run {
                    guard let self,
                          self.generation == currentGeneration,
                          self.repositoryID == currentRepositoryID else { return }
                    self.isSearching = false
                    self.errorMessage = Self.safeMessage(
                        for: error,
                        fallbackKey: "mobile.downloads.bt-search.search.error"
                    )
                }
            }
        }
    }

    func setModule(_ id: String, isSelected: Bool) {
        if isSelected {
            selectedModuleIDs.insert(id)
        } else {
            selectedModuleIDs.remove(id)
        }
    }

    private func invalidateSearchPresentation() {
        guard hasSearched || isSearching || !results.isEmpty else { return }
        generation &+= 1
        task?.cancel()
        task = nil
        results = []
        hasSearched = false
        isSearching = false
        errorMessage = nil
    }

    private var moduleScope: DownloadBTSearchModuleScope {
        switch moduleMode {
        case .all:
            .all
        case .enabled:
            .enabled
        case .selected:
            .selected(Array(selectedModuleIDs).sorted())
        }
    }

    private static func isValidSearchText(_ value: String, required: Bool) -> Bool {
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            return false
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty {
            return !required
        }
        return normalized.count <= 200
    }

    private static func safeMessage(for error: Error, fallbackKey: String) -> String {
        (error as? AppError)?.safeUserMessage ?? L10n.string(fallbackKey)
    }
}

struct MobileDownloadBTSearchView: View {
    @Bindable var model: MobileAppModel
    @State private var searchModel = MobileDownloadBTSearchModel()
    @Environment(\.dismiss) private var dismiss

    private var searchRepository: DsmServiceManagementRepository? {
        model.canSearchDownloadBT ? model.serviceRepository : nil
    }

    private var searchRepositoryIdentity: ObjectIdentifier? {
        searchRepository.map(ObjectIdentifier.init)
    }

    var body: some View {
        NavigationStack {
            Form {
                if searchModel.isLoadingCatalog {
                    Section {
                        ProgressView(L10n.string("mobile.downloads.bt-search.catalog.loading"))
                            .accessibilityLabel(
                                L10n.string("mobile.downloads.bt-search.catalog.loading")
                            )
                    }
                }

                if let catalog = searchModel.catalog {
                    if catalog.modules.isEmpty {
                        emptyCatalogSection
                    } else {
                        searchSection
                            .disabled(searchModel.isSearching)
                        filterSection(catalog: catalog)
                            .disabled(searchModel.isSearching)
                    }
                }

                if let errorMessage = searchModel.errorMessage {
                    errorSection(errorMessage)
                }

                if searchModel.isSearching {
                    Section {
                        ProgressView(L10n.string("mobile.downloads.bt-search.searching"))
                            .accessibilityLabel(L10n.string("mobile.downloads.bt-search.searching"))
                    }
                }

                if !searchModel.results.isEmpty {
                    resultSection
                } else if searchModel.hasSearched && !searchModel.isSearching &&
                            searchModel.errorMessage == nil {
                    emptyResultsSection
                }
            }
            .navigationTitle(L10n.string("mobile.downloads.bt-search.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.downloads.bt-search.close")) {
                        searchModel.close()
                        dismiss()
                    }
                }
            }
        }
        .task(id: searchRepositoryIdentity) {
            searchModel.activate(repository: searchRepository)
        }
        .onDisappear {
            searchModel.close()
        }
    }

    private var searchSection: some View {
        Section {
            TextField(
                L10n.string("mobile.downloads.bt-search.keyword.placeholder"),
                text: $searchModel.keyword
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(L10n.string("mobile.downloads.bt-search.keyword.label"))
            if searchModel.hasInvalidKeyword {
                invalidInputMessage
            }

            Text(L10n.string("mobile.downloads.bt-search.title-filter.label"))
                .font(.subheadline.weight(.semibold))
            TextField(
                L10n.string("mobile.downloads.bt-search.title-filter.placeholder"),
                text: $searchModel.titleFilter
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel(L10n.string("mobile.downloads.bt-search.title-filter.label"))
            if searchModel.hasInvalidTitleFilter {
                invalidInputMessage
            }

            Button {
                searchModel.search()
            } label: {
                Label(
                    L10n.string("mobile.downloads.bt-search.search"),
                    systemImage: "magnifyingglass"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!searchModel.canSearch)
            .frame(minHeight: MobileMetrics.minimumTouchTarget)
            .accessibilityHint(L10n.string("mobile.downloads.bt-search.search.hint"))
        } header: {
            Text(L10n.string("mobile.downloads.bt-search.keyword.label"))
        } footer: {
            Text(L10n.string("mobile.downloads.bt-search.keyword.help"))
        }
    }

    private var invalidInputMessage: some View {
        Text(L10n.string("mobile.downloads.bt-search.input.invalid"))
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityLabel(L10n.string("mobile.downloads.bt-search.input.invalid"))
    }

    private func filterSection(catalog: DownloadBTSearchCatalog) -> some View {
        Section(L10n.string("mobile.downloads.bt-search.filters.title")) {
            Picker(
                L10n.string("mobile.downloads.bt-search.provider.label"),
                selection: $searchModel.moduleMode
            ) {
                Text(L10n.string("mobile.downloads.bt-search.provider.enabled"))
                    .tag(MobileDownloadBTSearchModuleMode.enabled)
                Text(L10n.string("mobile.downloads.bt-search.provider.all"))
                    .tag(MobileDownloadBTSearchModuleMode.all)
                Text(L10n.string("mobile.downloads.bt-search.provider.selected"))
                    .tag(MobileDownloadBTSearchModuleMode.selected)
            }

            if searchModel.moduleMode == .selected {
                ForEach(catalog.modules) { module in
                    Toggle(
                        module.title,
                        isOn: Binding(
                            get: { searchModel.selectedModuleIDs.contains(module.id) },
                            set: { value in
                                searchModel.setModule(module.id, isSelected: value)
                            }
                        )
                    )
                }
                if searchModel.selectedModuleIDs.isEmpty {
                    Text(L10n.string("mobile.downloads.bt-search.provider.empty-selection"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            L10n.string("mobile.downloads.bt-search.provider.empty-selection")
                        )
                }
            }

            Picker(
                L10n.string("mobile.downloads.bt-search.category.label"),
                selection: $searchModel.selectedCategoryID
            ) {
                Text(L10n.string("mobile.downloads.bt-search.category.all"))
                    .tag(String?.none)
                ForEach(catalog.categories.filter { $0.id != "_allcat_" }) { category in
                    Text(category.title).tag(Optional(category.id))
                }
            }

            Picker(
                L10n.string("mobile.downloads.bt-search.sort.label"),
                selection: Binding(
                    get: { searchModel.sort.rawValue },
                    set: { value in
                        searchModel.sort = Self.sort(from: value)
                    }
                )
            ) {
                ForEach(Self.sortOptions, id: \.value) { value, title in
                    Text(title).tag(value)
                }
            }

            Picker(
                L10n.string("mobile.downloads.bt-search.direction.label"),
                selection: Binding(
                    get: { searchModel.direction.rawValue },
                    set: { value in
                        searchModel.direction = Self.direction(from: value)
                    }
                )
            ) {
                Text(L10n.string("mobile.downloads.bt-search.direction.desc"))
                    .tag(DownloadBTSearchDirection.descending.rawValue)
                Text(L10n.string("mobile.downloads.bt-search.direction.asc"))
                    .tag(DownloadBTSearchDirection.ascending.rawValue)
            }
        }
    }

    private func errorSection(_ errorMessage: String) -> some View {
        Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            Button(L10n.string("mobile.downloads.bt-search.retry")) {
                if searchModel.catalog == nil {
                    searchModel.loadCatalog()
                } else {
                    searchModel.search()
                }
            }
            .frame(minHeight: MobileMetrics.minimumTouchTarget)
        }
    }

    private var emptyCatalogSection: some View {
        Section {
            Label(
                L10n.string("mobile.downloads.bt-search.catalog.empty.title"),
                systemImage: "tray"
            )
            .font(.headline)
            Text(L10n.string("mobile.downloads.bt-search.catalog.empty.message"))
                .foregroundStyle(.secondary)
            Button(L10n.string("mobile.downloads.bt-search.retry")) {
                searchModel.loadCatalog()
            }
            .frame(minHeight: MobileMetrics.minimumTouchTarget)
        }
        .accessibilityElement(children: .contain)
    }

    private var emptyResultsSection: some View {
        Section {
            Label(
                L10n.string("mobile.downloads.bt-search.empty.title"),
                systemImage: "magnifyingglass"
            )
            .font(.headline)
            Text(L10n.string("mobile.downloads.bt-search.empty.message"))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var resultSection: some View {
        Section(L10n.string("mobile.downloads.bt-search.results.title")) {
            ForEach(searchModel.results) { result in
                VStack(alignment: .leading, spacing: 8) {
                    Text(result.title)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 4) {
                        if let provider = result.provider, !provider.isEmpty {
                            LabeledContent(
                                L10n.string("mobile.downloads.bt-search.result.provider"),
                                value: provider
                            )
                        }
                        LabeledContent(
                            L10n.string("mobile.downloads.bt-search.result.size"),
                            value: formattedSize(result.sizeBytes)
                        )
                        LabeledContent(
                            L10n.string("mobile.downloads.bt-search.result.seeds"),
                            value: formattedCount(result.seeds)
                        )
                        LabeledContent(
                            L10n.string("mobile.downloads.bt-search.result.leeches"),
                            value: formattedCount(result.leeches)
                        )
                    }
                    .font(.subheadline)

                    Button {
                        model.createDownloadTask(uri: result.downloadURI)
                        dismiss()
                    } label: {
                        Label(
                            L10n.string("mobile.downloads.bt-search.result.create"),
                            systemImage: "plus.circle"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canCreateDownloadTask)
                    .frame(minHeight: MobileMetrics.minimumTouchTarget)
                    .accessibilityHint(
                        L10n.string("mobile.downloads.bt-search.result.create.hint")
                    )
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func formattedSize(_ sizeBytes: Int64?) -> String {
        guard let sizeBytes, sizeBytes >= 0 else {
            return L10n.string("mobile.downloads.bt-search.result.unknown")
        }
        return sizeBytes.formatted(.byteCount(style: .file).locale(L10n.locale))
    }

    private func formattedCount(_ count: Int?) -> String {
        guard let count else {
            return L10n.string("mobile.downloads.bt-search.result.unknown")
        }
        return count.formatted(.number.locale(L10n.locale))
    }

    private static var sortOptions: [(value: String, title: String)] {
        [
            (
                DownloadBTSearchSort.seeds.rawValue,
                L10n.string("mobile.downloads.bt-search.sort.seeds")
            ),
            (
                DownloadBTSearchSort.size.rawValue,
                L10n.string("mobile.downloads.bt-search.sort.size")
            ),
            (
                DownloadBTSearchSort.date.rawValue,
                L10n.string("mobile.downloads.bt-search.sort.date")
            ),
            (
                DownloadBTSearchSort.title.rawValue,
                L10n.string("mobile.downloads.bt-search.sort.title")
            ),
            (
                DownloadBTSearchSort.peers.rawValue,
                L10n.string("mobile.downloads.bt-search.sort.peers")
            ),
            (
                DownloadBTSearchSort.provider.rawValue,
                L10n.string("mobile.downloads.bt-search.sort.provider")
            ),
            (
                DownloadBTSearchSort.leeches.rawValue,
                L10n.string("mobile.downloads.bt-search.sort.leeches")
            )
        ]
    }

    private static func sort(from rawValue: String) -> DownloadBTSearchSort {
        DownloadBTSearchSort(rawValue: rawValue) ?? .seeds
    }

    private static func direction(from rawValue: String) -> DownloadBTSearchDirection {
        DownloadBTSearchDirection(rawValue: rawValue) ?? .descending
    }
}
