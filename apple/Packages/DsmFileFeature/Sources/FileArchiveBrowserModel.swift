import DsmCore
import DsmLocalization
import Foundation
import Observation

@MainActor @Observable
public final class FileArchiveBrowserModel {
    public let item: FileItem
    public var destination: String
    public var password = ""
    public var encoding = ""
    public var createSubfolder = true
    public var keepDirectories = true
    public var overwrite = false
    public var extractAll = true
    public private(set) var items: [ArchiveItem] = []
    public var selected: [Int: ArchiveItem] = [:]
    public private(set) var parents: [ArchiveItem] = []
    public private(set) var isLoading = false
    public private(set) var error: String?
    public private(set) var hasMore = false
    public private(set) var hasLoaded = false
    @ObservationIgnored private var resolvedEncoding: String?
    @ObservationIgnored private var offset = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let repository: any FileRepository
    public init(item: FileItem, destination: String, repository: any FileRepository) {
        self.item = item; self.destination = destination; self.repository = repository
    }
    public var currentFolder: String { parents.last?.path ?? item.name }
    public var canExtract: Bool { hasLoaded && !isLoading && error == nil && (extractAll || !selected.isEmpty) && destination != "/" && !destination.isEmpty }

    public func reload() async {
        parents = []; selected = [:]; hasLoaded = false
        resolvedEncoding = encoding.isEmpty ? nil : encoding
        await load(reset: true)
        let expectedGeneration = generation
        guard encoding.isEmpty, error == nil, Self.archiveNamePenalty(items.map(\.name)) > 0 else { return }
        if let page = try? await repository.listArchivePage(filePath: item.path, parentID: -1, offset: 0, limit: 200, codepage: "chs", password: password),
           expectedGeneration == generation, !Task.isCancelled,
           Self.archiveNamePenalty(page.items.map(\.name)) < Self.archiveNamePenalty(items.map(\.name)) {
            resolvedEncoding = "chs"; items = page.items; offset = items.count; hasMore = page.hasMore
        }
    }
    public func enter(_ folder: ArchiveItem) async { guard !isLoading else { return }; parents.append(folder); await load(reset: true) }
    public func back() async { guard !isLoading, !parents.isEmpty else { return }; parents.removeLast(); await load(reset: true) }
    public func more() async { guard !isLoading, hasMore else { return }; await load(reset: false) }
    public func invalidate() { generation += 1; isLoading = false; hasLoaded = false; selected = [:]; items = []; hasMore = false }

    private func load(reset: Bool) async {
        generation += 1; let generation = generation
        isLoading = true; error = nil
        if reset { offset = 0; items = [] }
        do {
            let page = try await repository.listArchivePage(filePath: item.path, parentID: parents.last?.id ?? -1,
                offset: offset, limit: 200, codepage: resolvedEncoding, password: password)
            guard generation == self.generation, !Task.isCancelled else { return }
            items.append(contentsOf: page.items); offset += page.items.count
            hasMore = page.hasMore; hasLoaded = true
        } catch {
            guard generation == self.generation, !Task.isCancelled else { return }
            self.error = (error as? AppError)?.dsmCode == 1403 ? L10n.string("ui.cff0d6bd7c1d30b9") : L10n.string("files.archive.loadFailed")
        }
        isLoading = false
    }

    /// 提交前重新读取所选目录，检查包内相对路径并保留输出核对清单。
    public func prepare() async throws -> (FileExtractionRequest, [ArchiveItem]) {
        guard canExtract else { throw invalidSelection() }
        let chosen = selected.values.sorted { $0.id < $1.id }
        let draft = FileExtractionRequest(filePath: item.path, destination: destination,
            selection: extractAll ? .all : .items(chosen), overwrite: overwrite,
            keepDirectories: keepDirectories, createSubfolder: createSubfolder,
            codepage: resolvedEncoding, password: password.isEmpty ? nil : password)
        isLoading = true
        defer { isLoading = false }
        guard let current = try await repository.getInfo(paths: [item.path]).first(where: { $0.path == item.path }),
              current.kind == item.kind, current.sizeBytes == item.sizeBytes, current.times?.modifiedAt == item.times?.modifiedAt else {
            throw AppError(category: .conflict, isRetryable: false, safeUserMessage: L10n.string("files.archive.changed"))
        }
        var inventory: [ArchiveItem] = []
        var visited = Set<Int>()
        func descend(_ parent: Int) async throws {
            guard visited.insert(parent).inserted else { throw invalidSelection() }
            var offset = 0
            while true {
                try Task.checkCancellation()
                let page = try await repository.listArchivePage(filePath: item.path, parentID: parent, offset: offset,
                    limit: 200, codepage: draft.codepage, password: draft.password)
                for entry in page.items {
                    guard FileArchiveSelection.safeRelativePath(entry.path) else { throw invalidSelection() }
                    inventory.append(entry)
                    if entry.isDirectory { try await descend(entry.id) }
                }
                guard page.hasMore else { break }
                guard !page.items.isEmpty else { throw invalidSelection() }
                offset += page.items.count
            }
        }
        // 完整遍历用于核对 ID 与路径，防止已选目录项改变或不安全的路径被遗漏。
        try await descend(-1)
        guard Set(inventory.map(\.id)).count == inventory.count else { throw invalidSelection() }
        if case .items = draft.selection {
            guard chosen.allSatisfy({ item in inventory.contains(item) }) else { throw invalidSelection() }
            inventory = inventory.filter { entry in chosen.contains { $0.id == entry.id || ($0.isDirectory && entry.path.hasPrefix($0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")) } }
        }
        guard !inventory.isEmpty else { throw invalidSelection() }
        if !draft.keepDirectories {
            let files = inventory.filter { !$0.isDirectory }
            guard Set(files.map(\.name)).count == files.count else { throw invalidSelection() }
        }
        return (draft, inventory)
    }

    public static func archiveNamePenalty(_ names: [String]) -> Int {
        names.reduce(into: 0) { score, name in
            for scalar in name.unicodeScalars {
                if scalar.value == 0xFFFD || (0x00C0...0x024F).contains(scalar.value) {
                    score += 3
                }
            }
            let suspicious = ["Ã", "Â", "Ð", "æ", "å", "ç", "ï¿½", "¤", "¦", "¨"]
            score += suspicious.reduce(0) { $0 + (name.contains($1) ? 5 : 0) }
        }
    }

    private func invalidSelection() -> AppError {
        AppError(category: .invalidResponse, isRetryable: false, safeUserMessage: L10n.string("files.archive.invalidSelection"))
    }
}
