import AppKit
import DsmCore
import DsmNetwork
import Foundation
import Observation
import SwiftUI
import DsmLocalization

struct ToastMessage: Identifiable, Sendable {
    enum Style: Sendable {
        case success, error, info
    }
    let id = UUID()
    let text: String
    let icon: String
    let style: Style

    var iconColor: SwiftUI.Color {
        switch style {
        case .success: return .green
        case .error: return .red
        case .info: return .accentColor
        }
    }
}

enum PhotoWorkspacePage: String, CaseIterable, Hashable, Identifiable {
    case timeline
    case albums

    var id: Self { self }

    var browseMode: PhotoBrowseMode {
        switch self {
        case .timeline: .timeline
        case .albums: .albums
        }
    }

    init(_ browseMode: PhotoBrowseMode) {
        switch browseMode {
        case .timeline: self = .timeline
        case .albums: self = .albums
        }
    }
}

enum ContainerManagerPane: String, CaseIterable, Hashable, Identifiable {
    case overview
    case containers
    case images
    case networks
    case projects
    case events

    var id: Self { self }
}

enum VirtualMachineManagerPane: String, CaseIterable, Hashable, Identifiable {
    case machines
    case hosts
    case storages
    case networks
    case images
    case protection
    case events

    var id: Self { self }
}

enum WorkspaceSection: Hashable, Identifiable {
    case files(String)
    case recycle(String)
    case photos(PhotoWorkspacePage)
    case favorites
    case recent
    case remoteLocations
    case sharedLinks
    case transfers
    case chat
    case nasSettings
    case downloadStation
    case containerManager(ContainerManagerPane)
    case virtualMachineManager(VirtualMachineManagerPane)
    case settings

    var id: String {
        switch self {
        case .files(let path): "files:\(path)"
        case .recycle(let path): "recycle:\(path)"
        case .photos(let page): "photos:\(page.rawValue)"
        case .favorites: "favorites"
        case .recent: "recent"
        case .remoteLocations: "remote-locations"
        case .sharedLinks: "shared-links"
        case .transfers: "transfers"
        case .chat: "chat"
        case .nasSettings: "nas-settings"
        case .downloadStation: "download-station"
        case .containerManager(let pane): "container-manager:\(pane.rawValue)"
        case .virtualMachineManager(let pane): "virtual-machine-manager:\(pane.rawValue)"
        case .settings: "settings"
        }
    }

    var belongsToFileModule: Bool {
        switch self {
        case .files, .recycle, .favorites, .recent, .remoteLocations, .sharedLinks, .transfers:
            true
        case .photos, .chat, .nasSettings, .downloadStation, .containerManager,
             .virtualMachineManager, .settings:
            false
        }
    }

    var belongsToPhotosModule: Bool {
        if case .photos = self { return true }
        return false
    }

    var belongsToContainerManagerModule: Bool {
        if case .containerManager = self { return true }
        return false
    }

    var belongsToVirtualMachineManagerModule: Bool {
        if case .virtualMachineManager = self { return true }
        return false
    }
}

enum FilePreviewState {
    case empty
    case loading
    case image(Data)
    case text(String, truncated: Bool)
    case pdf(URL)
    case video(MediaStreamSource)
    case audio(MediaStreamSource)
    case unsupported(String)
    case failed(String)
}

enum TextDocumentFormatter {
    static func format(_ text: String, fileExtension: String) throws -> String {
        let formatted: String
        switch fileExtension.lowercased() {
        case "json", "geojson":
            let object = try JSONSerialization.jsonObject(
                with: Data(text.utf8),
                options: [.fragmentsAllowed]
            )
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
            )
            guard let decoded = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            formatted = decoded
        case "xml":
            let document = try XMLDocument(xmlString: text)
            guard let decoded = String(
                data: document.xmlData(options: [.nodePrettyPrint]),
                encoding: .utf8
            ) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            formatted = decoded
        case "js", "ts", "jsx", "tsx", "css", "scss":
            formatted = formatBraceBasedSource(text)
        default:
            return text
        }
        return formatted + (formatted.hasSuffix("\n") ? "" : "\n")
    }

    /// 只调整代码行首缩进和行尾空白，不改写标识符、字符串或语句，避免格式化造成代码语义变化。
    private static func formatBraceBasedSource(_ source: String) -> String {
        var indentation = 0
        var inBlockComment = false
        var multilineQuote: Character?
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n",
            omittingEmptySubsequences: false
        )

        return lines.map { substring in
            let original = String(substring)
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return "" }
            let startedInsideTemplate = multilineQuote == "`"
            let scan = scanBraces(
                in: trimmed,
                inBlockComment: &inBlockComment,
                multilineQuote: &multilineQuote
            )
            let displayIndent = max(0, indentation - (scan.startsWithClosingBrace ? 1 : 0))
            indentation = max(0, indentation + scan.openingBraces - scan.closingBraces)
            if startedInsideTemplate {
                return original
            }
            return String(repeating: "    ", count: displayIndent) + trimmed
        }.joined(separator: "\n")
    }

    private static func scanBraces(
        in line: String,
        inBlockComment: inout Bool,
        multilineQuote: inout Character?
    ) -> (openingBraces: Int, closingBraces: Int, startsWithClosingBrace: Bool) {
        let characters = Array(line)
        var openingBraces = 0
        var closingBraces = 0
        var startsWithClosingBrace = false
        var foundCode = false
        var quote = multilineQuote
        var escaped = false
        var index = 0

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if inBlockComment {
                if character == "*", next == "/" {
                    inBlockComment = false
                    index += 2
                    continue
                }
                index += 1
                continue
            }
            if let activeQuote = quote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == activeQuote {
                    quote = nil
                }
                index += 1
                continue
            }
            if character == "/", next == "/" { break }
            if character == "/", next == "*" {
                inBlockComment = true
                index += 2
                continue
            }
            if character == "\"" || character == "'" || character == "`" {
                quote = character
                foundCode = true
            } else if character == "{" {
                openingBraces += 1
                foundCode = true
            } else if character == "}" {
                if !foundCode { startsWithClosingBrace = true }
                closingBraces += 1
                foundCode = true
            } else if !character.isWhitespace {
                foundCode = true
            }
            index += 1
        }
        multilineQuote = quote == "`" ? quote : nil
        return (openingBraces, closingBraces, startsWithClosingBrace)
    }
}

struct FolderStatistics: Equatable {
    let sizeBytes: Int64
    let fileCount: Int
    let folderCount: Int
    let isComplete: Bool
}

private struct FolderManifestEntry {
    let item: FileItem
    let relativePath: String
}

private struct FolderManifest {
    let directories: [FolderManifestEntry]
    let files: [FolderManifestEntry]

    var statistics: FolderStatistics {
        FolderStatistics(
            sizeBytes: files.compactMap(\.item.sizeBytes).reduce(0, +),
            fileCount: files.count,
            folderCount: directories.count,
            isComplete: files.allSatisfy { $0.item.sizeBytes != nil }
        )
    }
}

struct TransferProgressEstimator {
    private(set) var lastCompleted: Int64?
    private(set) var lastDate: Date?
    private(set) var smoothedBytesPerSecond: Double?

    mutating func update(
        completed: Int64,
        total: Int64?,
        at date: Date = Date()
    ) -> (speed: Double?, remaining: TimeInterval?) {
        guard let previousCompleted = lastCompleted,
              let previousDate = lastDate else {
            lastCompleted = completed
            lastDate = date
            smoothedBytesPerSecond = nil
            return (nil, nil)
        }

        guard completed >= previousCompleted else {
            // 忽略多线程异步回调乱序引起的过期进度更新，保留并返回当前速度指标，防止速度和剩余时间被重置为 nil
            return metrics(completed: previousCompleted, total: total)
        }

        let elapsed = date.timeIntervalSince(previousDate)
        let delta = completed - previousCompleted
        guard elapsed >= 0.2, delta > 0 else {
            return metrics(completed: completed, total: total)
        }

        lastCompleted = completed
        lastDate = date

        let instantSpeed = Double(delta) / elapsed
        if let previousSpeed = smoothedBytesPerSecond {
            smoothedBytesPerSecond = previousSpeed * 0.7 + instantSpeed * 0.3
        } else {
            smoothedBytesPerSecond = instantSpeed
        }
        return metrics(completed: completed, total: total)
    }

    private func metrics(
        completed: Int64,
        total: Int64?
    ) -> (speed: Double?, remaining: TimeInterval?) {
        guard let speed = smoothedBytesPerSecond, speed > 0 else {
            return (nil, nil)
        }
        guard let total, total > completed else {
            return (speed, nil)
        }
        return (speed, Double(total - completed) / speed)
    }
}

@MainActor
@Observable
final class WorkspaceModel {
    struct ArchivePasswordRequest: Identifiable {
        let id = UUID()
        let item: FileItem
        let destinationFolder: String
        let createSubfolder: Bool
        let keepDirectoryStructure: Bool
        let overwrite: Bool
        var errorMessage: String?
    }

    private struct DragMoveUndo {
        let id: UUID
        let items: [FileItem]
        let sourceFolder: String
        let destinationFolder: String
        let expiresAt: Date
    }
    enum SearchScope: String, CaseIterable, Identifiable {
        case currentFolder
        case subfolders
        var id: Self { self }
        var title: String { self == .currentFolder ? L10n.string("ui.9112e7066855185e") : L10n.string("ui.74c32a0e473dba46") }
    }

    enum FolderDownloadMode {
        case archive
        case directory
    }

    private enum RestartableTransfer: Codable {
        case download(item: FileItem, localURL: URL)
        case downloadArchive(item: FileItem, localURL: URL)
        case downloadBatchArchive(items: [FileItem], localURL: URL)
        case upload(localURL: URL, folderPath: String, overwrite: Bool)
    }

    private(set) var profile: NasProfile
    let allowsVerifiedRestore: Bool
    let allowsRemoteMountManagement: Bool
    let photoLibrary: PhotoLibraryModel
    let chat: ChatWorkspaceModel
    let nasSettings: NasSettingsModel
    let serviceManagement: ServiceManagementModel
    let desktopDriveSessionBridge: DesktopDriveSessionBridge?

    var shares: [FileItem] = []
    var recycleRoots: [FileItem] = []
    var section: WorkspaceSection?
    var items: [FileItem] = []
    var currentPath = ""
    var selection: Set<FileItem.ID> = []
    var searchText = ""
    var searchScope: SearchScope = .currentFolder
    var recursiveSearchResults: [FileItem] = []
    var isSearching = false
    var favorites: [FavoriteLocation] = []
    var recentLocations: [FavoriteLocation] = []
    var remoteLocations: [FileVirtualFolder] = []
    var unavailableRemoteLocationProtocols: [FileVirtualProtocol] = []
    var remoteLocationsAreTruncated = false
    var remoteLocationsError: String?
    var isLoadingRemoteLocations = false
    var remoteLocationsHasLoaded = false
    var shareLinks: [FileShareLink] = []
    var isLoadingShareLinks = false
    var storageSpaceSummary: StorageSpaceSummary?
    var isLoadingStorageSpace = false
    var isManagingRemoteMount = false
    var isLoading = false
    var isRefreshing = false
    var isLoadingMore = false
    var hasMore = false
    var totalItemCount = 0
    var statusMessage: String?
    var statusIsError = false
    var requiresReauthentication = false
    var preview: FilePreviewState = .empty
    var resolvedPreviewKind: PreviewKind?
    var isPreviewPresented = false
    var previewLoadingSpeedBytesPerSecond: Double?
    var editableText = ""
    var originalEditableText = ""
    var isEditingText = false
    var isSavingText = false
    var textEditingMessage: String?
    var textEditingMessageIsError = false
    var transfers: [ActivityTask] = []
    var serverBackgroundTasks: [FileBackgroundTaskSummary] = []
    var serverBackgroundTaskTotal = 0
    var serverBackgroundTaskHasMore = false
    var serverBackgroundTaskHasLoaded = false
    var isLoadingServerBackgroundTasks = false
    var serverBackgroundTaskError: String?
    var folderStatisticsResults: [FileItem.ID: FolderStatistics] = [:]
    var calculatingFolderStatisticsIDs: Set<FileItem.ID> = []
    var cancellingFolderStatisticsIDs: Set<FileItem.ID> = []
    var folderStatisticsErrors: [FileItem.ID: String] = [:]
    var isMovingItemsByDrag = false
    var archivePasswordRequest: ArchivePasswordRequest?
    var isCheckingArchivePassword = false
    var activeToast: ToastMessage?

    // 按 NAS profile 保存的模块开关；切换其他 NAS 时各用各的值。
    var isFileModuleEnabled: Bool = true {
        didSet {
            Self.saveModuleEnabled(isFileModuleEnabled, for: profile.id, module: "FileStation")
            guard oldValue != isFileModuleEnabled else { return }
            if !isFileModuleEnabled {
                suspendFileModule()
                if section?.belongsToFileModule == true {
                    section = .settings
                }
            }
        }
    }
    var isPhotosModuleEnabled: Bool = true {
        didSet {
            Self.saveModuleEnabled(isPhotosModuleEnabled, for: profile.id, module: "Photos")
            guard oldValue != isPhotosModuleEnabled else { return }
            photoLibrary.setModuleEnabled(isPhotosModuleEnabled)
            if !isPhotosModuleEnabled, section?.belongsToPhotosModule == true {
                section = .settings
            }
        }
    }
    var isChatModuleEnabled: Bool = true {
        didSet {
            Self.saveModuleEnabled(isChatModuleEnabled, for: profile.id, module: "Chat")
            guard oldValue != isChatModuleEnabled else { return }
            chat.setModuleEnabled(isChatModuleEnabled)
            if !isChatModuleEnabled, section == .chat {
                section = .settings
            }
        }
    }
    var isNasSettingsModuleEnabled: Bool = false {
        didSet {
            Self.saveModuleEnabled(isNasSettingsModuleEnabled, for: profile.id, module: "NASSettings")
            guard oldValue != isNasSettingsModuleEnabled else { return }
            nasSettings.setModuleEnabled(isNasSettingsModuleEnabled)
            if !isNasSettingsModuleEnabled, section == .nasSettings {
                section = .settings
            }
        }
    }
    var isDownloadStationModuleEnabled: Bool = true {
        didSet {
            Self.saveModuleEnabled(
                isDownloadStationModuleEnabled,
                for: profile.id,
                module: "DownloadStation"
            )
            if !isDownloadStationModuleEnabled, section == .downloadStation {
                section = .settings
            }
        }
    }
    var isContainerManagerModuleEnabled: Bool = true {
        didSet {
            Self.saveModuleEnabled(
                isContainerManagerModuleEnabled,
                for: profile.id,
                module: "ContainerManager"
            )
            if !isContainerManagerModuleEnabled,
               section?.belongsToContainerManagerModule == true {
                section = .settings
            }
        }
    }
    var isVirtualMachineManagerModuleEnabled: Bool = true {
        didSet {
            Self.saveModuleEnabled(
                isVirtualMachineManagerModuleEnabled,
                for: profile.id,
                module: "VirtualMachineManager"
            )
            if !isVirtualMachineManagerModuleEnabled,
               section?.belongsToVirtualMachineManagerModule == true {
                section = .settings
            }
        }
    }
    private var dragMoveUndo: DragMoveUndo?
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?

    func showToast(_ text: String, icon: String = "checkmark.circle.fill", style: ToastMessage.Style = .success) {
        toastDismissTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            activeToast = ToastMessage(text: text, icon: icon, style: style)
        }
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    self.activeToast = nil
                }
            }
        }
    }

    @ObservationIgnored private let repository: any FileRepository
    @ObservationIgnored private let transferNotifier: any TransferNotifying
    @ObservationIgnored private var history: [String] = []
    @ObservationIgnored private var navigationGeneration = 0
    @ObservationIgnored private var backgroundTaskGeneration = 0
    @ObservationIgnored private var remoteLocationGeneration = 0
    @ObservationIgnored private var nextBackgroundTaskOffset = 0
    @ObservationIgnored private var nextOffset = 0
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewProgressEstimator = TransferProgressEstimator()
    @ObservationIgnored private var isChangingPreviewImage = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var previewFileURL: URL?
    @ObservationIgnored private var editingTextItemID: FileItem.ID?
    @ObservationIgnored private var thumbnailCache: [FileItem.ID: Data] = [:]
    @ObservationIgnored private var unavailableThumbnails: Set<FileItem.ID> = []
    @ObservationIgnored private var displayedItemOrder: [FileItem.ID] = []
    @ObservationIgnored private var runningTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var restartableTransfers: [UUID: RestartableTransfer] = [:]
    @ObservationIgnored private var progressEstimators: [UUID: TransferProgressEstimator] = [:]
    @ObservationIgnored private var dragMoveUndoExpirationTask: Task<Void, Never>?
    @ObservationIgnored private var previewContextItems: [FileItem]?
    @ObservationIgnored private var folderStatisticsTasks: [FileItem.ID: Task<Void, Never>] = [:]

    var fileRepository: any FileRepository {
        repository
    }

    // 读取按 NAS 保存的模块开关；不存在时回退到旧全局 key，保持老用户已有选择。
    private static func moduleEnabledKey(for profileID: UUID, module: String) -> String {
        "LanStash_Module_\(module)_\(profileID.uuidString)"
    }

    private static func loadModuleEnabled(
        for profileID: UUID,
        module: String,
        legacyKey: String,
        defaultValue: Bool = true
    ) -> Bool {
        let key = moduleEnabledKey(for: profileID, module: module)
        if UserDefaults.standard.object(forKey: key) != nil {
            return UserDefaults.standard.bool(forKey: key)
        }
        if UserDefaults.standard.object(forKey: legacyKey) != nil {
            return UserDefaults.standard.bool(forKey: legacyKey)
        }
        return defaultValue
    }

    private static func saveModuleEnabled(_ value: Bool, for profileID: UUID, module: String) {
        UserDefaults.standard.set(value, forKey: moduleEnabledKey(for: profileID, module: module))
    }

    init(
        profile: NasProfile,
        repository: any FileRepository,
        chatRepository: any ChatRepository = UnverifiedDsmChatRepository(),
        nasSettingsRepository: any NasSettingsRepository = UnavailableNasAdministrationRepository(),
        serviceManagementRepository: any ServiceManagementRepository =
            UnavailableServiceManagementRepository(),
        desktopDriveSessionBridge: DesktopDriveSessionBridge? = nil,
        transferNotifier: any TransferNotifying = TransferNotifierFactory.makeDefault()
    ) {
        self.profile = profile
        self.repository = repository
        self.transferNotifier = transferNotifier
        self.desktopDriveSessionBridge = desktopDriveSessionBridge
        self.allowsVerifiedRestore = repository.allowsVerifiedRestore
        self.allowsRemoteMountManagement = repository.allowsRemoteMountManagement
        self.photoLibrary = PhotoLibraryModel(
            repository: FileStationPhotoRepository(files: repository),
            profileID: profile.id,
            thumbnailFallback: LocalPhotoThumbnailFallback(files: repository)
        )
        self.chat = ChatWorkspaceModel(
            repository: chatRepository,
            currentAccountName: profile.usernameHint,
            profileID: profile.id
        )
        self.nasSettings = NasSettingsModel(
            repository: nasSettingsRepository,
            fileRepository: repository
        )
        self.serviceManagement = ServiceManagementModel(
            repository: serviceManagementRepository,
            fileRepository: repository
        )
        self.isFileModuleEnabled = Self.loadModuleEnabled(for: profile.id, module: "FileStation", legacyKey: "LanStash_Module_FileStation")
        self.isPhotosModuleEnabled = Self.loadModuleEnabled(for: profile.id, module: "Photos", legacyKey: "LanStash_Module_Photos")
        self.isChatModuleEnabled = Self.loadModuleEnabled(for: profile.id, module: "Chat", legacyKey: "LanStash_Module_Chat")
        self.isNasSettingsModuleEnabled = Self.loadModuleEnabled(
            for: profile.id,
            module: "NASSettings",
            legacyKey: "LanStash_Module_NASSettings",
            defaultValue: false
        ) || Self.loadModuleEnabled(
            for: profile.id,
            module: "ServicesMonitor",
            legacyKey: "LanStash_Module_ServicesMonitor",
            defaultValue: false
        )
        Self.saveModuleEnabled(
            self.isNasSettingsModuleEnabled,
            for: profile.id,
            module: "NASSettings"
        )
        self.isDownloadStationModuleEnabled = Self.loadModuleEnabled(
            for: profile.id,
            module: "DownloadStation",
            legacyKey: "LanStash_Module_DownloadStation"
        )
        self.isContainerManagerModuleEnabled = Self.loadModuleEnabled(
            for: profile.id,
            module: "ContainerManager",
            legacyKey: "LanStash_Module_ContainerManager"
        )
        self.isVirtualMachineManagerModuleEnabled = Self.loadModuleEnabled(
            for: profile.id,
            module: "VirtualMachineManager",
            legacyKey: "LanStash_Module_VirtualMachineManager"
        )
        if let data = UserDefaults.standard.data(forKey: "LanStash_RecentLocations_\(profile.id.uuidString)"),
           let saved = try? JSONDecoder().decode([FavoriteLocation].self, from: data) {
            recentLocations = saved
        }
        Self.purgeStalePreviewCache()
        
        // 加载已保存的任务列表
        if let data = UserDefaults.standard.data(forKey: "LanStash_Transfers_\(profile.id.uuidString)"),
           let savedTransfers = try? JSONDecoder().decode([ActivityTask].self, from: data) {
            self.transfers = savedTransfers.map { task in
                var updatedTask = task
                // 异常退出的 running/queued 任务自动变为暂停状态
                if updatedTask.state == .running || updatedTask.state == .queued {
                    updatedTask.state = .paused
                }
                updatedTask.bytesPerSecond = nil
                updatedTask.estimatedSecondsRemaining = nil
                return updatedTask
            }
        }
        
        // 加载已保存的可重启任务参数
        if let data = UserDefaults.standard.data(forKey: "LanStash_Restartable_\(profile.id.uuidString)"),
           let savedRestartable = try? JSONDecoder().decode([UUID: RestartableTransfer].self, from: data) {
            self.restartableTransfers = savedRestartable
        }
        photoLibrary.setModuleEnabled(isPhotosModuleEnabled)
        chat.setModuleEnabled(isChatModuleEnabled)
        nasSettings.setModuleEnabled(isNasSettingsModuleEnabled)
    }

    private func saveTransfers() {
        if let data = try? JSONEncoder().encode(transfers) {
            UserDefaults.standard.set(data, forKey: "LanStash_Transfers_\(profile.id.uuidString)")
        }
        if let data = try? JSONEncoder().encode(restartableTransfers) {
            UserDefaults.standard.set(data, forKey: "LanStash_Restartable_\(profile.id.uuidString)")
        }
    }

    func updateProfile(_ profile: NasProfile) {
        guard self.profile.id == profile.id else { return }
        self.profile = profile
    }

    var filteredItems: [FileItem] {
        let source = searchScope == .subfolders && !searchText.isEmpty ? recursiveSearchResults : items
        let visible = source.filter { item in
            Self.matchesSearch(item.name, query: searchText)
        }
        return visible.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    var searchErrorMessage: String? {
        guard Self.regularExpressionQuery(searchText) != nil else { return nil }
        do {
            _ = try Self.makeSearchRegularExpression(searchText)
            return nil
        } catch {
            return L10n.string("ui.1f7f656abf2ac8c3")
        }
    }

    private var defaultPreviewSourceItems: [FileItem] {
        if section?.belongsToPhotosModule == true {
            return photoLibrary.displayedItems.map(\.fileItem)
        }
        return filteredItems
    }

    var selectedItems: [FileItem] {
        let source = previewContextItems ?? defaultPreviewSourceItems
        return source.filter { selection.contains($0.id) }
    }

    var selectedItem: FileItem? {
        guard selection.count == 1, let id = selection.first else {
            return nil
        }
        let source = previewContextItems ?? defaultPreviewSourceItems
        return source.first { $0.id == id }
    }

    var canEditSelectedText: Bool {
        guard let item = selectedItem,
              !item.isDirectory,
              !item.isRecyclePath,
              (resolvedPreviewKind ?? PreviewKind.classify(item)) == .text else {
            return false
        }
        // 文件列表中的 write 标记不等同于“允许覆盖保存”，部分 DSM 版本还会缺失或误报该字段。
        // 保存前的官方权限检查和上传接口才是最终依据，不能在界面层提前隐藏编辑入口。
        return Self.editableTextExtensions.contains(item.fileExtension?.lowercased() ?? "")
    }

    var currentFileSection: WorkspaceSection {
        let path = currentPath.isEmpty ? "/" : currentPath
        return path.split(separator: "/").contains("#recycle") ? .recycle(path) : .files(path)
    }

    var canFormatSelectedText: Bool {
        guard canEditSelectedText, let ext = selectedItem?.fileExtension?.lowercased() else { return false }
        return ["json", "geojson", "xml", "js", "ts", "jsx", "tsx", "css", "scss"].contains(ext)
    }

    var hasUnsavedTextEdits: Bool {
        isEditingText && editableText != originalEditableText
    }

    var canGoBack: Bool {
        !history.isEmpty
    }

    var canGoUp: Bool {
        currentPath.split(separator: "/").count > 1
    }

    var activeTransferCount: Int {
        transfers.filter {
            $0.state == .queued || $0.state == .running || $0.state == .paused || $0.state == .cancelling
        }.count
    }

    /// 只启动已启用的首个模块；所有功能都关闭时停留在设置页。
    func startEnabledModules() async {
        if isFileModuleEnabled {
            await load()
            guard isFileModuleEnabled else { return }
            section = .files("/")
            await navigate(to: "/", recordingHistory: false)
            return
        }
        if isPhotosModuleEnabled {
            section = .photos(.timeline)
            await photoLibrary.loadIfNeeded()
            return
        }
        if isChatModuleEnabled {
            section = .chat
            await chat.loadIfNeeded()
            return
        }
        if isNasSettingsModuleEnabled {
            section = .nasSettings
            await nasSettings.activate()
            return
        }
        if isDownloadStationModuleEnabled {
            section = .downloadStation
            await serviceManagement.activate(.downloads)
            return
        }
        if isContainerManagerModuleEnabled {
            section = .containerManager(.overview)
            await serviceManagement.activate(.containers)
            return
        }
        if isVirtualMachineManagerModuleEnabled {
            section = .virtualMachineManager(.machines)
            await serviceManagement.activate(.virtualMachines)
            return
        }
        section = .settings
    }

    func load() async {
        guard isFileModuleEnabled, shares.isEmpty else {
            return
        }
        isLoading = true
        statusMessage = nil
        do {
            let page = try await repository.listShares(offset: 0, limit: 200)
            guard isFileModuleEnabled else { return }
            shares = page.items
            isLoading = false
            if let first = shares.first {
                section = .files(first.path)
                await navigate(to: first.path, recordingHistory: false)
            } else {
                items = []
                statusMessage = L10n.string("ui.54febf8015c8e233")
            }
            guard isFileModuleEnabled else { return }
            await loadRemoteLocations()
            guard isFileModuleEnabled else { return }
            await discoverRecycleRoots()
            guard isFileModuleEnabled else { return }
            await loadFavorites()
            guard isFileModuleEnabled else { return }
            await loadStorageSpace()
        } catch {
            isLoading = false
            show(error)
        }
    }

    func activate(_ newSection: WorkspaceSection?) async {
        guard let newSection else {
            return
        }
        switch newSection {
        case .files(let path), .recycle(let path):
            guard isFileModuleEnabled else { return }
            if shares.isEmpty {
                await load()
                guard isFileModuleEnabled else { return }
            }
            if path != currentPath {
                history.removeAll()
                await navigate(to: path, recordingHistory: false)
            }
        case .photos(let page):
            guard isPhotosModuleEnabled else { return }
            await photoLibrary.setBrowseMode(page.browseMode)
            await photoLibrary.loadIfNeeded()
        case .chat:
            guard isChatModuleEnabled else { return }
            await chat.loadIfNeeded()
        case .nasSettings:
            guard isNasSettingsModuleEnabled else { return }
            await nasSettings.activate()
        case .downloadStation:
            guard isDownloadStationModuleEnabled else { return }
            await serviceManagement.activate(.downloads)
        case .containerManager:
            guard isContainerManagerModuleEnabled else { return }
            await serviceManagement.activate(.containers)
        case .virtualMachineManager:
            guard isVirtualMachineManagerModuleEnabled else { return }
            await serviceManagement.activate(.virtualMachines)
        case .favorites, .recent, .sharedLinks:
            guard isFileModuleEnabled else { return }
        case .remoteLocations:
            guard isFileModuleEnabled else { return }
            if !remoteLocationsHasLoaded {
                await refreshRemoteLocations()
            }
        case .transfers:
            guard isFileModuleEnabled else { return }
            if !serverBackgroundTaskHasLoaded {
                await refreshServerBackgroundTasks()
            }
        case .settings:
            break
        }
    }

    func navigate(to path: String, recordingHistory: Bool = true) async {
        guard isFileModuleEnabled else { return }
        previewContextItems = nil
        let previousPath = currentPath
        navigationGeneration += 1
        let generation = navigationGeneration
        isLoading = items.isEmpty
        isRefreshing = !items.isEmpty
        statusMessage = nil

        if path == "/" {
            if recordingHistory, !previousPath.isEmpty, previousPath != path {
                history.append(previousPath)
            }
            currentPath = "/"
            section = .files("/")
            items = shares.map { share in
                FileItem(
                    profileID: profile.id,
                    name: share.name,
                    path: share.path,
                    kind: .directory
                )
            }
            hasMore = false
            totalItemCount = shares.count
            nextOffset = shares.count
            selection.removeAll()
            clearPreview()
            isLoading = false
            isRefreshing = false
            return
        }

        do {
            let page = try await repository.listFolder(path: path, offset: 0, limit: 500)
            guard isFileModuleEnabled, generation == navigationGeneration else {
                return
            }
            if recordingHistory, !previousPath.isEmpty, previousPath != path {
                history.append(previousPath)
            }
            currentPath = path
            section = currentFileSection
            rememberRecentLocation(path: path)
            items = page.items
            hasMore = page.hasMore
            totalItemCount = page.total
            nextOffset = page.offset + page.items.count
            selection.removeAll()
            clearPreview()
            isLoading = false
            isRefreshing = false
        } catch {
            guard generation == navigationGeneration else {
                return
            }
            isLoading = false
            isRefreshing = false
            show(error)
        }
    }

    func updateSearch() {
        searchTask?.cancel()
        recursiveSearchResults = []
        guard isFileModuleEnabled,
              searchScope == .subfolders,
              !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !currentPath.isEmpty else {
            isSearching = false
            return
        }
        let query = searchText
        let folder = currentPath
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let serverQuery = Self.regularExpressionQuery(query) == nil ? query : "*"
                recursiveSearchResults = try await repository.search(folderPath: folder, query: serverQuery)
                selection.removeAll()
            } catch is CancellationError {
                return
            } catch {
                show(error)
            }
        }
    }

    private func rememberRecentLocation(path: String) {
        guard path != "/", !path.isEmpty else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        recentLocations.removeAll { $0.path == path }
        recentLocations.insert(FavoriteLocation(name: name, path: path), at: 0)
        recentLocations = Array(recentLocations.prefix(12))
        if let data = try? JSONEncoder().encode(recentLocations) {
            UserDefaults.standard.set(data, forKey: "LanStash_RecentLocations_\(profile.id.uuidString)")
        }
    }

    func removeRecentLocation(_ location: FavoriteLocation) {
        recentLocations.removeAll { $0.path == location.path }
        persistRecentLocations()
    }

    func clearRecentLocations() {
        recentLocations.removeAll()
        UserDefaults.standard.removeObject(forKey: "LanStash_RecentLocations_\(profile.id.uuidString)")
    }

    func openRecentLocation(_ location: FavoriteLocation) async {
        do {
            _ = try await repository.listFolder(path: location.path, offset: 0, limit: 1)
            section = .files(location.path)
            await navigate(to: location.path, recordingHistory: false)
        } catch let error as AppError where error.category == .notFound {
            statusIsError = true
            statusMessage = L10n.string("ui.9fa4d319f1784294")
        } catch {
            show(error)
        }
    }

    private func persistRecentLocations() {
        if let data = try? JSONEncoder().encode(recentLocations) {
            UserDefaults.standard.set(data, forKey: "LanStash_RecentLocations_\(profile.id.uuidString)")
        }
    }

    func loadStorageSpace() async {
        guard isFileModuleEnabled, !isLoadingStorageSpace else { return }
        isLoadingStorageSpace = true
        defer { isLoadingStorageSpace = false }
        do {
            storageSpaceSummary = try await repository.storageSpaceSummary()
        } catch {
            // 容量信息是辅助内容，读取失败不应阻断文件浏览。
            storageSpaceSummary = nil
        }
    }

    func refreshRemoteLocations() async {
        guard isFileModuleEnabled else { return }
        remoteLocationGeneration += 1
        let generation = remoteLocationGeneration
        isLoadingRemoteLocations = true
        remoteLocationsError = nil
        unavailableRemoteLocationProtocols = []
        remoteLocationsAreTruncated = false
        defer {
            if generation == remoteLocationGeneration {
                isLoadingRemoteLocations = false
            }
        }
        do {
            let page = try await repository.listVirtualFolders(offset: 0, limit: 5_000)
            guard isFileModuleEnabled, generation == remoteLocationGeneration else { return }
            remoteLocations = page.folders
            unavailableRemoteLocationProtocols = page.unavailableProtocols
            remoteLocationsAreTruncated = page.isTruncated
            remoteLocationsHasLoaded = true
        } catch let error as AppError where error.category == .apiUnavailable || error.category == .versionUnsupported {
            // 旧版 DSM 缺少官方虚拟文件夹能力时，仅显示共享列表中能明确识别协议的条目。
            guard isFileModuleEnabled, generation == remoteLocationGeneration else { return }
            remoteLocations = shares.compactMap { item in
                guard let rawType = item.mountPointType?.lowercased(),
                      let protocolType = FileVirtualProtocol(rawValue: rawType) else {
                    return nil
                }
                return FileVirtualFolder(item: item, protocolType: protocolType)
            }
            unavailableRemoteLocationProtocols = []
            remoteLocationsAreTruncated = false
            remoteLocationsHasLoaded = true
        } catch {
            guard isFileModuleEnabled, generation == remoteLocationGeneration else { return }
            remoteLocationsError = Self.userMessage(for: error)
            remoteLocationsHasLoaded = true
        }
    }

    private func loadRemoteLocations() async {
        await refreshRemoteLocations()
    }

    func createRemoteMount(_ configuration: RemoteMountConfiguration) async -> Bool {
        guard isFileModuleEnabled, !isManagingRemoteMount else { return false }
        isManagingRemoteMount = true
        defer { isManagingRemoteMount = false }
        do {
            try await repository.createRemoteMount(configuration)
            try await reloadShares()
            statusIsError = false
            statusMessage = L10n.string("ui.14d477b19fa31764")
            return true
        } catch {
            show(error)
            return false
        }
    }

    func updateRemoteMount(
        _ item: FileItem,
        configuration: RemoteMountConfiguration
    ) async -> Bool {
        guard !isManagingRemoteMount else { return false }
        isManagingRemoteMount = true
        defer { isManagingRemoteMount = false }
        do {
            try await repository.updateRemoteMount(
                existingMountPoint: item.path,
                configuration: configuration
            )
            try await reloadShares()
            statusIsError = false
            statusMessage = L10n.string("ui.109f075ff40700df")
            return true
        } catch {
            show(error)
            return false
        }
    }

    func removeRemoteMount(_ item: FileItem) async -> Bool {
        guard !isManagingRemoteMount else { return false }
        isManagingRemoteMount = true
        defer { isManagingRemoteMount = false }
        do {
            try await repository.removeRemoteMount(mountPoint: item.path)
            try await reloadShares()
            statusIsError = false
            statusMessage = L10n.string("ui.0e675b381ad62cd9")
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func reloadShares() async throws {
        let page = try await repository.listShares(offset: 0, limit: 200)
        shares = page.items
        if currentPath == "/" {
            items = shares.map { share in
                FileItem(
                    profileID: profile.id,
                    name: share.name,
                    path: share.path,
                    kind: .directory,
                    sizeBytes: share.sizeBytes,
                    owner: share.owner,
                    group: share.group,
                    times: share.times,
                    permissions: share.permissions,
                    rawType: share.rawType,
                    mountPointType: share.mountPointType
                )
            }
            totalItemCount = items.count
            selection.removeAll()
        }
        await loadRemoteLocations()
        await loadStorageSpace()
    }

    func loadFavorites() async {
        guard isFileModuleEnabled else { return }
        do {
            favorites = try await repository.listFavorites()
        } catch {
            // 收藏夹为侧边栏辅助功能，后台读取失败时不污染主内容区错误状态
            favorites = []
        }
    }

    func toggleFavorite(_ item: FileItem) {
        toggleFavorite(path: item.path, name: item.name)
    }

    func toggleFavorite(path: String, name: String) {
        guard isFileModuleEnabled else { return }
        Task { [weak self] in
            guard let self, isFileModuleEnabled else { return }
            do {
                if favorites.contains(where: { $0.path == path }) {
                    try await repository.removeFavorite(path: path)
                    favorites.removeAll { $0.path == path }
                    statusMessage = L10n.string("ui.25400251730cea8a")
                    statusIsError = false
                } else {
                    let result = try await repository.addFavoriteResult(
                        path: path,
                        name: name
                    )
                    applyFavoriteAddResult(result, path: path, name: name)
                }
            } catch { show(error) }
        }
    }

    private func applyFavoriteAddResult(
        _ result: MutationResult,
        path: String,
        name: String
    ) {
        let feedback = Self.favoriteAddFeedback(for: result.status)
        if feedback.shouldApplyFavorite {
            favorites.removeAll { $0.path == path }
            favorites.append(FavoriteLocation(name: name, path: path))
        }
        statusMessage = L10n.string(feedback.resourceKey)
        statusIsError = feedback.isError
    }

    struct FavoriteAddFeedback: Equatable {
        let resourceKey: String
        let isError: Bool
        let shouldApplyFavorite: Bool
    }

    static func favoriteAddFeedback(
        for status: MutationResultStatus
    ) -> FavoriteAddFeedback {
        switch status {
        case .confirmedSuccess:
            FavoriteAddFeedback(
                resourceKey: "ui.f8f147eae9ef4058",
                isError: false,
                shouldApplyFavorite: true
            )
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            FavoriteAddFeedback(
                resourceKey: "ui.c6509276bfb40c3e",
                isError: true,
                shouldApplyFavorite: false
            )
        case .confirmedFailure, .partialSuccess:
            FavoriteAddFeedback(
                resourceKey: "ui.879eea91f0f03666",
                isError: true,
                shouldApplyFavorite: false
            )
        case .permissionDenied:
            FavoriteAddFeedback(
                resourceKey: "ui.8456cb379b109f1f",
                isError: true,
                shouldApplyFavorite: false
            )
        case .unsupported:
            FavoriteAddFeedback(
                resourceKey: "ui.1a328a0c6cdda7f4",
                isError: true,
                shouldApplyFavorite: false
            )
        case .cancelledBeforeSubmission:
            FavoriteAddFeedback(
                resourceKey: "ui.d5f06160eed23cb2",
                isError: false,
                shouldApplyFavorite: false
            )
        }
    }

    func loadShareLinks() async {
        guard isFileModuleEnabled else { return }
        isLoadingShareLinks = true
        defer { isLoadingShareLinks = false }
        do {
            shareLinks = try await repository.listShareLinks()
        } catch {
            // 分享链接列表为辅助功能，不污染主文件列表状态
            shareLinks = []
        }
    }

    func createShareLink(paths: [String], password: String?, expiresAt: String?) async -> FileShareLink? {
        guard isFileModuleEnabled, !paths.isEmpty else { return nil }
        do {
            let link = try await repository.createShareLink(paths: paths, password: password, expiresAt: expiresAt)
            shareLinks.removeAll { $0.id == link.id }
            shareLinks.insert(link, at: 0)
            statusIsError = false
            statusMessage = L10n.string("ui.5f35da72ac6771cb")
            return link
        } catch {
            show(error)
            return nil
        }
    }

    func deleteShareLinks(ids: [String]) async {
        guard isFileModuleEnabled else { return }
        do {
            try await repository.deleteShareLinks(ids: ids)
            let wanted = Set(ids)
            shareLinks.removeAll { wanted.contains($0.id) }
            statusIsError = false
            statusMessage = L10n.string("ui.e277407e7218c8fd")
        } catch { show(error) }
    }

    func loadMore() async {
        guard isFileModuleEnabled, hasMore, !isLoadingMore, !currentPath.isEmpty else {
            return
        }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await repository.listFolder(
                path: currentPath,
                offset: nextOffset,
                limit: 500
            )
            let existing = Set(items.map(\.path))
            items.append(contentsOf: page.items.filter { !existing.contains($0.path) })
            hasMore = page.hasMore
            totalItemCount = page.total
            nextOffset = page.offset + page.items.count
        } catch {
            show(error)
        }
    }

    func refresh() async {
        guard isFileModuleEnabled, !currentPath.isEmpty else {
            return
        }
        if currentPath == "/" {
            isRefreshing = true
            defer { isRefreshing = false }
            do {
                try await reloadShares()
            } catch {
                show(error)
            }
            return
        }
        await navigate(to: currentPath, recordingHistory: false)
    }

    func goBack() async {
        guard let previous = history.popLast() else {
            return
        }
        await navigate(to: previous, recordingHistory: false)
    }

    func goUp() async {
        guard canGoUp else {
            return
        }
        let parent = URL(fileURLWithPath: currentPath).deletingLastPathComponent().path
        await navigate(to: parent, recordingHistory: true)
    }

    func open(_ item: FileItem) async {
        guard isFileModuleEnabled else { return }
        if item.isDirectory {
            await navigate(to: item.path)
        } else {
            selection = [item.id]
            preparePreview()
        }
    }

    func dismissPreview() {
        clearPreview()
        previewContextItems = nil
    }

    func thumbnailData(for item: FileItem) async -> Data? {
        guard isFileModuleEnabled else { return nil }
        let kind = PreviewKind.classify(item)
        guard kind == .image || kind == .video else { return nil }
        if let cached = thumbnailCache[item.id] { return cached }
        guard !unavailableThumbnails.contains(item.id) else { return nil }

        do {
            let data = try await repository.getThumbnail(path: item.path, size: .small)
            guard !data.isEmpty else { throw CancellationError() }
            if thumbnailCache.count >= 200 {
                for key in thumbnailCache.keys.prefix(40) {
                    thumbnailCache[key] = nil
                }
            }
            thumbnailCache[item.id] = data
            return data
        } catch is CancellationError {
            return nil
        } catch {
            unavailableThumbnails.insert(item.id)
            return nil
        }
    }

    func metadata(for item: FileItem) async -> PhotoMetadata? {
        guard isFileModuleEnabled else { return nil }
        let kind = PreviewKind.classify(item)
        guard kind == .image || kind == .video else { return nil }
        let extractor = PhotoMetadataExtractor(files: repository)
        return await Task.detached(priority: .userInitiated) {
            await extractor.extract(for: item)
        }.value
    }

    private func localFolderStatistics(for item: FileItem) async throws -> FolderStatistics {
        guard item.isDirectory else {
            return FolderStatistics(
                sizeBytes: item.sizeBytes ?? 0,
                fileCount: 1,
                folderCount: 0,
                isComplete: item.sizeBytes != nil
            )
        }
        return try await folderManifest(for: item).statistics
    }

    func startFolderStatistics(for item: FileItem) {
        guard item.isDirectory,
              isFileModuleEnabled,
              folderStatisticsTasks[item.id] == nil else { return }
        folderStatisticsErrors[item.id] = nil
        calculatingFolderStatisticsIDs.insert(item.id)
        cancellingFolderStatisticsIDs.remove(item.id)

        folderStatisticsTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let statistics: FolderStatistics
                do {
                    let summary = try await repository.calculateDirectorySize(path: item.path)
                    statistics = FolderStatistics(
                        sizeBytes: summary.totalBytes,
                        fileCount: summary.fileCount,
                        folderCount: summary.directoryCount,
                        isComplete: true
                    )
                } catch let error as AppError where error.category == .apiUnavailable {
                    // 旧版 DSM 没有官方目录大小任务时，才降级为现有的客户端递归枚举。
                    statistics = try await localFolderStatistics(for: item)
                }
                try Task.checkCancellation()
                folderStatisticsResults[item.id] = statistics
                folderStatisticsErrors[item.id] = nil
            } catch {
                if !Self.isCancellation(error) {
                    folderStatisticsErrors[item.id] = Self.userMessage(for: error)
                }
            }
            calculatingFolderStatisticsIDs.remove(item.id)
            cancellingFolderStatisticsIDs.remove(item.id)
            folderStatisticsTasks[item.id] = nil
        }
    }

    func cancelFolderStatistics(for itemID: FileItem.ID) {
        guard let task = folderStatisticsTasks[itemID] else { return }
        cancellingFolderStatisticsIDs.insert(itemID)
        task.cancel()
    }

    /// 返回是否应关闭当前预览。图片预览内部切换时复用同一个窗口，避免窗口闪烁。
    func selectionChanged() -> Bool {
        if hasUnsavedTextEdits,
           let editingTextItemID,
           selection != [editingTextItemID] {
            selection = [editingTextItemID]
            textEditingMessageIsError = true
            textEditingMessage = L10n.string("ui.daa9fbd7d7a79786")
            return false
        }
        if isChangingPreviewImage {
            isChangingPreviewImage = false
            return false
        }
        clearPreview()
        return true
    }

    var canPreviewPreviousImage: Bool {
        adjacentPreviewImage(offset: -1) != nil
    }

    var canPreviewNextImage: Bool {
        adjacentPreviewImage(offset: 1) != nil
    }

    func previewPreviousImage() {
        previewAdjacentImage(offset: -1)
    }

    func previewNextImage() {
        previewAdjacentImage(offset: 1)
    }

    func updateDisplayedItemOrder(_ items: [FileItem]) {
        displayedItemOrder = items.map(\.id)
    }

    private var previewImages: [FileItem] {
        let baseItems = previewContextItems ?? filteredItems
        let itemsByID = Dictionary(uniqueKeysWithValues: baseItems.map { ($0.id, $0) })
        let orderedItems = displayedItemOrder.compactMap { itemsByID[$0] }
        let source = orderedItems.isEmpty ? baseItems : orderedItems
        return source.filter { PreviewKind.classify($0) == .image }
    }

    private func adjacentPreviewImage(offset: Int) -> FileItem? {
        guard let current = selectedItem,
              PreviewKind.classify(current) == .image,
              let index = previewImages.firstIndex(where: { $0.id == current.id }) else {
            return nil
        }
        let targetIndex = index + offset
        guard previewImages.indices.contains(targetIndex) else { return nil }
        return previewImages[targetIndex]
    }

    private func previewAdjacentImage(offset: Int) {
        guard let target = adjacentPreviewImage(offset: offset) else { return }
        isChangingPreviewImage = true
        selection = [target.id]
        preparePreview()
    }

    func preparePreview() {
        guard isFileModuleEnabled else { return }
        previewTask?.cancel()
        clearPreviewFile()
        guard let item = selectedItem else {
            preview = .empty
            return
        }
        guard !item.isDirectory else {
            preview = .empty
            return
        }

        isPreviewPresented = true
        preview = .loading
        previewLoadingSpeedBytesPerSecond = nil
        previewProgressEstimator = TransferProgressEstimator()
        previewTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // 先异步读取内存/磁盘缩略图缓存，快速显示已有缩略图
            if let photoItem = photoLibrary.displayedItems.first(where: { $0.id == item.id }),
               let cachedData = await photoLibrary.cachedThumbnailData(for: photoItem) {
                preview = .image(cachedData)
            }
            do {
                let kind = try await resolvedKindForPreview(item)
                try Task.checkCancellation()
                resolvedPreviewKind = kind
                switch kind {
                case .image:
                    do {
                        let data = try await repository.getThumbnail(path: item.path, size: .large)
                        try Task.checkCancellation()
                        previewLoadingSpeedBytesPerSecond = nil
                        preview = .image(data)
                    } catch {
                        // 若获取 NAS 大缩略图失败（例如 HEIC/HEIF 照片未预生成大图），自动回退到下载原图并由 macOS 系统原生解码展示
                        let url = temporaryPreviewURL(for: item)
                        let progress = previewProgressHandler()
                        try await repository.download(
                            remotePath: item.path,
                            to: url,
                            expectedSize: item.sizeBytes
                        ) { completed, total in
                            progress(completed, total)
                        }
                        try Task.checkCancellation()
                        let data = try Data(contentsOf: url)
                        previewFileURL = url
                        previewLoadingSpeedBytesPerSecond = nil
                        preview = .image(data)
                    }
                case .text:
                    let limit: Int64 = 5 * 1_024 * 1_024
                    // 文件可能刚在编辑器或其他客户端中被修改，列表里的大小会滞后。
                    // 文本预览前读取最新详情，不能仅凭旧的 0 字节记录判定为空文件。
                    let currentItem = try await repository.getInfo(paths: [item.path]).first ?? item
                    updateCachedItem(currentItem)
                    if let size = currentItem.sizeBytes, size > limit {
                        preview = .unsupported(L10n.string("ui.c1806a32254ff009"))
                        return
                    }
                    if currentItem.sizeBytes == 0 {
                        // 空白文件没有内容需要下载，直接进入文本预览，确保编辑入口立即可见。
                        editableText = ""
                        originalEditableText = ""
                        editingTextItemID = item.id
                        isEditingText = false
                        textEditingMessage = nil
                        previewLoadingSpeedBytesPerSecond = nil
                        preview = .text("", truncated: false)
                        return
                    }
                    let url = temporaryPreviewURL(for: item)
                    let progress = previewProgressHandler()
                    try await repository.download(
                        remotePath: item.path,
                        to: url,
                        expectedSize: currentItem.sizeBytes
                    ) { completed, total in
                        progress(completed, total)
                    }
                    try Task.checkCancellation()
                    let data = try Data(contentsOf: url)
                    let text = Self.decodeText(data) ?? L10n.string("ui.7323ca45199e5442")
                    previewFileURL = url
                    previewLoadingSpeedBytesPerSecond = nil
                    editableText = text
                    originalEditableText = text
                    editingTextItemID = item.id
                    isEditingText = false
                    textEditingMessage = nil
                    preview = .text(text, truncated: false)
                case .pdf:
                    let url = temporaryPreviewURL(for: item)
                    let progress = previewProgressHandler()
                    try await repository.download(
                        remotePath: item.path,
                        to: url,
                        expectedSize: item.sizeBytes
                    ) { completed, total in
                        progress(completed, total)
                    }
                    try Task.checkCancellation()
                    previewFileURL = url
                    previewLoadingSpeedBytesPerSecond = nil
                    preview = .pdf(url)
                case .video:
                    let source = try await repository.mediaStreamSource(
                        remotePath: item.path,
                        fileExtension: item.fileExtension,
                        expectedContentLength: item.sizeBytes
                    )
                    try Task.checkCancellation()
                    previewLoadingSpeedBytesPerSecond = nil
                    preview = .video(source)
                case .audio:
                    let source = try await repository.mediaStreamSource(
                        remotePath: item.path,
                        fileExtension: item.fileExtension,
                        expectedContentLength: item.sizeBytes
                    )
                    try Task.checkCancellation()
                    previewLoadingSpeedBytesPerSecond = nil
                    preview = .audio(source)
                case .unsupported:
                    preview = .unsupported(L10n.string("ui.2799b0f2c23a0591"))
                }
            } catch is CancellationError {
                return
            } catch {
                previewLoadingSpeedBytesPerSecond = nil
                if !Self.isCancellation(error) {
                    preview = .failed(Self.userMessage(for: error))
                }
            }
        }
    }

    func preparePhotoPreview(items: [FileItem], selected item: FileItem) {
        previewContextItems = items
        displayedItemOrder = items.map(\.id)
        selection = [item.id]
        preparePreview()
    }

    func enqueueDownload(
        _ item: FileItem,
        to localURL: URL,
        folderMode: FolderDownloadMode = .archive
    ) {
        guard isFileModuleEnabled else { return }
        let downloadsDirectoryAsArchive = item.isDirectory && folderMode == .archive
        let taskID = addTransfer(
            kind: .download,
            displayName: downloadsDirectoryAsArchive ? "\(item.name).zip" : item.name,
            remotePath: item.path,
            totalUnits: downloadsDirectoryAsArchive ? nil : item.sizeBytes
        )
        restartableTransfers[taskID] = downloadsDirectoryAsArchive
            ? .downloadArchive(item: item, localURL: localURL)
            : .download(item: item, localURL: localURL)
        saveTransfers()
        startDownload(
            taskID: taskID,
            item: item,
            localURL: localURL,
            downloadsDirectoryAsArchive: downloadsDirectoryAsArchive
        )
    }

    func enqueueBatchDownload(_ selectedItems: [FileItem], to localURL: URL) {
        guard isFileModuleEnabled, !selectedItems.isEmpty else { return }
        if selectedItems.count == 1, let item = selectedItems.first {
            enqueueDownload(item, to: localURL, folderMode: item.isDirectory ? .archive : .directory)
            return
        }
        let taskID = addTransfer(
            kind: .download,
            displayName: L10n.string("ui.f2a892abb28de531", String(describing: selectedItems.count)),
            remotePath: currentPath,
            totalUnits: nil
        )
        restartableTransfers[taskID] = .downloadBatchArchive(items: selectedItems, localURL: localURL)
        saveTransfers()
        startBatchDownload(taskID: taskID, items: selectedItems, localURL: localURL)
    }

    private func startBatchDownload(taskID: UUID, items: [FileItem], localURL: URL) {
        runningTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            let scoped = localURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { localURL.stopAccessingSecurityScopedResource() }
                runningTasks[taskID] = nil
            }
            do {
                setTransferState(taskID, .running)
                try await repository.downloadArchive(
                    remotePaths: items.map(\.path),
                    to: localURL,
                    progress: progressHandler(for: taskID)
                )
                finishTransfer(taskID)
                statusIsError = false
                statusMessage = L10n.string("ui.64b83128a3f0d23e", String(describing: items.count))
            } catch is CancellationError {
                finishCancellation(taskID)
            } catch {
                Self.isCancellation(error)
                    ? finishCancellation(taskID)
                    : failTransfer(taskID, error: error)
            }
        }
    }

    private func startDownload(
        taskID: UUID,
        item: FileItem,
        localURL: URL,
        downloadsDirectoryAsArchive: Bool = false
    ) {
        let operation = Task { [weak self] in
            guard let self else { return }
            let scoped = localURL.startAccessingSecurityScopedResource()
            defer {
                if scoped { localURL.stopAccessingSecurityScopedResource() }
                runningTasks[taskID] = nil
            }
            do {
                setTransferState(taskID, .running)
                if downloadsDirectoryAsArchive {
                    // File Station 会在 NAS 端动态生成 ZIP，客户端直接流式保存，避免深层目录产生大量请求。
                    try await repository.downloadArchive(
                        remotePaths: [item.path],
                        to: localURL,
                        progress: progressHandler(for: taskID)
                    )
                } else if item.isDirectory {
                    try await downloadFolder(
                        taskID: taskID,
                        item: item,
                        to: localURL
                    )
                } else {
                    try await repository.download(
                        remotePath: item.path,
                        to: localURL,
                        expectedSize: item.sizeBytes,
                        progress: progressHandler(for: taskID)
                    )
                }
                finishTransfer(taskID)
                statusIsError = false
                statusMessage = L10n.string("ui.bc79cf398fac8ad5", String(describing: item.name))
            } catch is CancellationError {
                finishCancellation(taskID)
            } catch {
                if Self.isCancellation(error) {
                    finishCancellation(taskID)
                } else {
                    failTransfer(taskID, error: error)
                }
            }
        }
        runningTasks[taskID] = operation
    }

    private func downloadFolder(
        taskID: UUID,
        item: FileItem,
        to localURL: URL
    ) async throws {
        let manifest = try await folderManifest(for: item)
        let statistics = manifest.statistics
        if let index = transfers.firstIndex(where: { $0.id == taskID }) {
            transfers[index].fileSizeBytes = statistics.isComplete ? statistics.sizeBytes : nil
            transfers[index].totalUnits = statistics.isComplete ? statistics.sizeBytes : nil
            saveTransfers()
        }

        try FileManager.default.createDirectory(
            at: localURL,
            withIntermediateDirectories: true
        )
        for entry in manifest.directories {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: try safeLocalURL(root: localURL, relativePath: entry.relativePath),
                withIntermediateDirectories: true
            )
        }

        let total = statistics.isComplete ? statistics.sizeBytes : nil
        var completedBeforeFile: Int64 = 0
        let reportProgress = progressHandler(for: taskID)
        for entry in manifest.files {
            try Task.checkCancellation()
            let destination = try safeLocalURL(root: localURL, relativePath: entry.relativePath)
            let base = completedBeforeFile
            try await repository.download(
                remotePath: entry.item.path,
                to: destination,
                expectedSize: entry.item.sizeBytes
            ) { completed, _ in
                reportProgress(base + completed, total)
            }
            completedBeforeFile += entry.item.sizeBytes ?? Self.localFileSize(at: destination)
            reportProgress(completedBeforeFile, total)
        }
    }

    private func folderManifest(for root: FileItem) async throws -> FolderManifest {
        var directories: [FolderManifestEntry] = []
        var files: [FolderManifestEntry] = []
        var pending = [root.path]
        var visited = Set<String>()

        while let folderPath = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(folderPath).inserted else { continue }
            var offset = 0
            repeat {
                let page = try await repository.listFolder(path: folderPath, offset: offset, limit: 500)
                for child in page.items {
                    let relativePath = try relativePath(of: child.path, under: root.path)
                    let entry = FolderManifestEntry(item: child, relativePath: relativePath)
                    if child.isDirectory {
                        directories.append(entry)
                        pending.append(child.path)
                    } else {
                        files.append(entry)
                    }
                }
                offset = page.offset + page.items.count
                if !page.hasMore { break }
            } while true
        }
        return FolderManifest(directories: directories, files: files)
    }

    private func relativePath(of path: String, under rootPath: String) throws -> String {
        let normalizedRoot = rootPath.hasSuffix("/") ? String(rootPath.dropLast()) : rootPath
        let prefix = normalizedRoot + "/"
        guard path.hasPrefix(prefix) else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("ui.73547f53fd96278c")
            )
        }
        return String(path.dropFirst(prefix.count))
    }

    private func safeLocalURL(root: URL, relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("ui.f1861e9edaae1967")
            )
        }
        return components.reduce(root) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    private static func localFileSize(at url: URL) -> Int64 {
        let value = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return Int64(value ?? 0)
    }

    func enqueueUploads(_ urls: [URL], overwrite: Bool = false) {
        guard isFileModuleEnabled else { return }
        enqueueUploads(urls, to: currentPath, overwrite: overwrite)
    }

    func enqueueUploads(_ urls: [URL], to folderPath: String, overwrite: Bool = false) {
        guard isFileModuleEnabled, !folderPath.isEmpty else {
            return
        }
        for url in urls {
            let taskID = addTransfer(
                kind: .upload,
                displayName: url.lastPathComponent,
                remotePath: folderPath
            )
            restartableTransfers[taskID] = .upload(
                localURL: url,
                folderPath: folderPath,
                overwrite: overwrite
            )
            saveTransfers()
            startUpload(
                taskID: taskID,
                localURL: url,
                folderPath: folderPath,
                overwrite: overwrite
            )
        }
    }

    func createFolder(named rawName: String) async {
        guard let name = validatedNewItemName(rawName) else { return }
        do {
            try await repository.createFolder(parentPath: currentPath, name: name)
            await refresh()
            statusIsError = false
            statusMessage = L10n.string("ui.5d7d392e452b94e6", String(describing: name))
        } catch {
            show(error)
        }
    }

    func createEmptyFile(named rawName: String) async {
        guard let name = validatedNewItemName(rawName) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanStashNewFile-\(UUID().uuidString)", isDirectory: true)
        let localURL = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: localURL.path, contents: Data()) else {
                throw AppError(
                    category: .localStorageFull,
                    isRetryable: false,
                    safeUserMessage: L10n.string("ui.7c9b8db9c8b82d39")
                )
            }
            try await repository.upload(
                localURL: localURL,
                to: currentPath,
                overwrite: false
            ) { _, _ in }
            await refresh()
            statusIsError = false
            statusMessage = L10n.string("ui.ca2cc77f49f1ee00", String(describing: name))
        } catch {
            show(error)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private func validatedNewItemName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            statusIsError = true
            statusMessage = L10n.string("ui.75d2c77c80b0ee49")
            return nil
        }
        return name
    }

    var recentDragMoveUndoMessage: String? {
        guard let undo = dragMoveUndo, undo.expiresAt > Date() else { return nil }
        return undo.items.count == 1
            ? L10n.string("ui.4e7678988daa231d", String(describing: undo.items[0].name))
            : L10n.string("ui.f7d9290863c0f6cb", String(describing: undo.items.count))
    }

    func rename(_ item: FileItem, to rawName: String) async {
        guard let newName = validatedNewItemName(rawName) else { return }
        guard newName != item.name else { return }
        let parentPath = (item.path as NSString).deletingLastPathComponent
        do {
            let existingNames = try await namesInFolder(parentPath)
            guard !existingNames.contains(newName) else {
                statusIsError = true
                statusMessage = L10n.string("ui.9c02b5dbfd8c986d", String(describing: newName))
                return
            }
            try await repository.rename(path: item.path, newName: newName)
            await refresh()
            if let renamed = items.first(where: { $0.name == newName }) {
                selection = [renamed.id]
            }
            statusIsError = false
            statusMessage = L10n.string("ui.8a7f123d3ec9d713", String(describing: newName))
        } catch {
            show(error)
        }
    }

    func moveByDragging(_ targets: [FileItem], to destination: FileItem) {
        guard destination.isDirectory, !targets.isEmpty, !isMovingItemsByDrag else { return }
        let sourceFolders = Set(targets.map { ($0.path as NSString).deletingLastPathComponent })
        guard sourceFolders.count == 1, let sourceFolder = sourceFolders.first else {
            statusIsError = true
            statusMessage = L10n.string("ui.3fd4192c291b19f7")
            return
        }
        guard destination.path != sourceFolder else { return }
        guard !targets.contains(where: {
            destination.path == $0.path || destination.path.hasPrefix($0.path + "/")
        }) else {
            statusIsError = true
            statusMessage = L10n.string("ui.08095a2928ae457a")
            return
        }

        isMovingItemsByDrag = true
        Task { [weak self] in
            guard let self else { return }
            defer { isMovingItemsByDrag = false }
            do {
                let existingNames = try await namesInFolder(destination.path)
                if let conflict = targets.first(where: { existingNames.contains($0.name) }) {
                    statusIsError = true
                    statusMessage = L10n.string("ui.05efe0c78cbc8a24", String(describing: conflict.name))
                    return
                }
                // 列表中的 write 标记在部分 DSM 版本中会缺失或误报。
                // 真正移动前逐项使用 File Station 官方权限检查，避免仅凭展示字段误判。
                for target in targets {
                    try await repository.checkWritePermission(
                        folderPath: destination.path,
                        filename: target.name,
                        createOnly: true
                    )
                }
                try await repository.move(
                    paths: targets.map(\.path),
                    to: destination.path,
                    overwrite: false,
                    progress: { _, _ in }
                )
                let destinationNames = try await namesInFolder(destination.path)
                guard targets.allSatisfy({ destinationNames.contains($0.name) }) else {
                    throw AppError(
                        category: .partialFailure,
                        isRetryable: true,
                        safeUserMessage: L10n.string("ui.00b073e405a9166c")
                    )
                }
                await refresh()
                beginDragMoveUndo(items: targets, sourceFolder: sourceFolder, destinationFolder: destination.path)
                statusIsError = false
                statusMessage = targets.count == 1 ? L10n.string("ui.83125ab4272866e1") : L10n.string("ui.9f59299bdfdf2f02", String(describing: targets.count))
            } catch {
                show(error)
            }
        }
    }

    func undoRecentDragMove() {
        guard let undo = dragMoveUndo, undo.expiresAt > Date(), !isMovingItemsByDrag else { return }
        dragMoveUndo = nil
        dragMoveUndoExpirationTask?.cancel()
        isMovingItemsByDrag = true
        Task { [weak self] in
            guard let self else { return }
            defer { isMovingItemsByDrag = false }
            do {
                let existingNames = try await namesInFolder(undo.sourceFolder)
                if let conflict = undo.items.first(where: { existingNames.contains($0.name) }) {
                    statusIsError = true
                    statusMessage = L10n.string("ui.5b797f56d4623f22", String(describing: conflict.name))
                    return
                }
                let movedPaths = undo.items.map {
                    (undo.destinationFolder as NSString).appendingPathComponent($0.name)
                }
                try await repository.move(
                    paths: movedPaths,
                    to: undo.sourceFolder,
                    overwrite: false,
                    progress: { _, _ in }
                )
                let restoredNames = try await namesInFolder(undo.sourceFolder)
                guard undo.items.allSatisfy({ restoredNames.contains($0.name) }) else {
                    throw AppError(
                        category: .partialFailure,
                        isRetryable: true,
                        safeUserMessage: L10n.string("ui.e305d0f16f31cac3")
                    )
                }
                await refresh()
                statusIsError = false
                statusMessage = L10n.string("ui.72bbeeaf2f7ee268")
            } catch {
                show(error)
            }
        }
    }

    private func beginDragMoveUndo(items: [FileItem], sourceFolder: String, destinationFolder: String) {
        let undo = DragMoveUndo(
            id: UUID(),
            items: items,
            sourceFolder: sourceFolder,
            destinationFolder: destinationFolder,
            expiresAt: Date().addingTimeInterval(10)
        )
        dragMoveUndo = undo
        dragMoveUndoExpirationTask?.cancel()
        dragMoveUndoExpirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.dragMoveUndo?.id == undo.id else { return }
            self?.dragMoveUndo = nil
            if self?.statusMessage?.contains(L10n.string("ui.f933e37804930440")) == true {
                self?.statusMessage = L10n.string("ui.b48f99e79e9f6623")
            }
        }
    }

    func enqueueFileOperation(
        _ targets: [FileItem],
        to destinationFolder: String,
        moveSource: Bool,
        overwrite: Bool = false
    ) {
        guard isFileModuleEnabled, !targets.isEmpty else { return }
        let taskID = addTransfer(
            kind: moveSource ? .move : .copy,
            displayName: targets.count == 1 ? targets[0].name : L10n.string("ui.05ec76407f6737d9", String(describing: targets.count)),
            remotePath: destinationFolder,
            totalUnits: Int64(targets.count)
        )
        runningTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { runningTasks[taskID] = nil }
            do {
                setTransferState(taskID, .running)
                var operationTargets = targets
                var skippedCount = 0
                if !overwrite {
                    let existingNames = try await namesInFolder(destinationFolder)
                    operationTargets = targets.filter { !existingNames.contains($0.name) }
                    skippedCount = targets.count - operationTargets.count
                }
                guard !operationTargets.isEmpty else {
                    finishTransfer(taskID)
                    statusIsError = false
                    statusMessage = L10n.string("ui.a7d7914278b1f450")
                    return
                }
                let operationPaths = operationTargets.map(\.path)
                if moveSource {
                    try await repository.move(
                        paths: operationPaths,
                        to: destinationFolder,
                        overwrite: overwrite,
                        progress: progressHandler(for: taskID)
                    )
                } else {
                    try await repository.copy(
                        paths: operationPaths,
                        to: destinationFolder,
                        overwrite: overwrite,
                        progress: progressHandler(for: taskID)
                    )
                }
                finishTransfer(taskID)
                await refresh()
                statusIsError = false
                let completion = moveSource ? L10n.string("ui.b48f99e79e9f6623") : L10n.string("ui.802278b710b019ef")
                statusMessage = skippedCount > 0
                    ? L10n.string("operation.skipped_duplicates", completion, String(skippedCount))
                    : completion
            } catch is CancellationError {
                setTransferState(taskID, .cancelled)
            } catch {
                Self.isCancellation(error)
                    ? setTransferState(taskID, .cancelled)
                    : failTransfer(taskID, error: error)
            }
        }
    }

    func enqueueCompression(
        _ targets: [FileItem],
        archiveName rawArchiveName: String,
        format: ArchiveFormat,
        level: ArchiveCompressionLevel,
        password: String?
    ) {
        guard isFileModuleEnabled,
              !targets.isEmpty,
              let archiveName = validatedNewItemName(rawArchiveName) else { return }
        let expectedExtension = format == .zip ? "zip" : "7z"
        let filename = (archiveName as NSString).pathExtension.lowercased() == expectedExtension
            ? archiveName
            : "\(archiveName).\(expectedExtension)"
        let destinationPath = (currentPath as NSString).appendingPathComponent(filename)
        let taskID = addTransfer(
            kind: .compress,
            displayName: filename,
            remotePath: destinationPath,
            totalUnits: Int64(targets.count)
        )
        runningTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { runningTasks[taskID] = nil }
            do {
                setTransferState(taskID, .running)
                let existingNames = try await namesInFolder(currentPath)
                guard !existingNames.contains(filename) else {
                    throw AppError(
                        category: .partialFailure,
                        isRetryable: false,
                        safeUserMessage: L10n.string("ui.375e35999ba848ba", String(describing: filename))
                    )
                }
                do {
                    try await repository.checkWritePermission(
                        folderPath: currentPath,
                        filename: filename,
                        createOnly: true
                    )
                } catch let error as AppError where error.category == .permissionDenied {
                    throw AppError(
                        category: .permissionDenied,
                        isRetryable: false,
                        safeUserMessage: L10n.string("ui.64b1351d57a2ea4f"),
                        dsmCode: error.dsmCode
                    )
                }
                do {
                    try await repository.compress(
                        paths: targets.map(\.path),
                        destinationFilePath: destinationPath,
                        format: format,
                        level: level,
                        password: password,
                        progress: progressHandler(for: taskID)
                    )
                } catch let error as AppError where error.category == .permissionDenied {
                    throw AppError(
                        category: .permissionDenied,
                        isRetryable: false,
                        safeUserMessage: L10n.string("ui.8ff5a50a46f95c24"),
                        dsmCode: error.dsmCode
                    )
                }
                let resultingNames = try await namesInFolder(currentPath)
                guard resultingNames.contains(filename) else {
                    throw AppError(
                        category: .partialFailure,
                        isRetryable: true,
                        safeUserMessage: L10n.string("ui.6cf7af39661f207b")
                    )
                }
                finishTransfer(taskID)
                await refresh()
                statusIsError = false
                statusMessage = L10n.string("ui.1b9b6cb0eec9c615", String(describing: filename))
            } catch is CancellationError {
                setTransferState(taskID, .cancelled)
            } catch {
                Self.isCancellation(error)
                    ? setTransferState(taskID, .cancelled)
                    : failTransfer(taskID, error: error)
            }
        }
    }

    func prepareExtraction(
        _ item: FileItem,
        createSubfolder: Bool,
        keepDirectoryStructure: Bool,
        overwrite: Bool
    ) async {
        let destinationFolder = currentPath
        isCheckingArchivePassword = true
        defer { isCheckingArchivePassword = false }
        do {
            let codepage = try await preferredArchiveCodepage(filePath: item.path, password: nil)
            enqueueExtraction(
                item,
                destinationFolder: destinationFolder,
                createSubfolder: createSubfolder,
                keepDirectoryStructure: keepDirectoryStructure,
                overwrite: overwrite,
                codepage: codepage,
                password: nil
            )
        } catch let error as AppError where error.dsmCode == 1403 {
            archivePasswordRequest = ArchivePasswordRequest(
                item: item,
                destinationFolder: destinationFolder,
                createSubfolder: createSubfolder,
                keepDirectoryStructure: keepDirectoryStructure,
                overwrite: overwrite
            )
        } catch {
            show(error)
        }
    }

    func submitArchivePassword(_ password: String) async {
        guard var request = archivePasswordRequest else { return }
        isCheckingArchivePassword = true
        request.errorMessage = nil
        archivePasswordRequest = request
        defer { isCheckingArchivePassword = false }
        do {
            let codepage = try await preferredArchiveCodepage(filePath: request.item.path, password: password)
            archivePasswordRequest = nil
            enqueueExtraction(
                request.item,
                destinationFolder: request.destinationFolder,
                createSubfolder: request.createSubfolder,
                keepDirectoryStructure: request.keepDirectoryStructure,
                overwrite: request.overwrite,
                codepage: codepage,
                password: password
            )
        } catch let error as AppError where error.dsmCode == 1403 {
            request.errorMessage = L10n.string("ui.cff0d6bd7c1d30b9")
            archivePasswordRequest = request
        } catch {
            archivePasswordRequest = nil
            show(error)
        }
    }

    func cancelArchivePasswordRequest() {
        archivePasswordRequest = nil
        isCheckingArchivePassword = false
        statusIsError = false
        statusMessage = L10n.string("ui.6fdd6030dd5a6f67")
    }

    private func preferredArchiveCodepage(filePath: String, password: String?) async throws -> String? {
        let original = try await repository.listArchiveItems(filePath: filePath, codepage: nil, password: password)
        let originalScore = Self.archiveNamePenalty(original.map(\.name))
        guard originalScore > 0 else { return nil }

        // 简体中文旧版压缩工具常不写 UTF-8 标记；让 NAS 用中文编码再次读取并比较可读性。
        if let chinese = try? await repository.listArchiveItems(filePath: filePath, codepage: "chs", password: password),
           Self.archiveNamePenalty(chinese.map(\.name)) < originalScore {
            return "chs"
        }
        return nil
    }

    static func archiveNamePenalty(_ names: [String]) -> Int {
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

    private func enqueueExtraction(
        _ item: FileItem,
        destinationFolder: String,
        createSubfolder: Bool,
        keepDirectoryStructure: Bool,
        overwrite: Bool,
        codepage: String?,
        password: String?
    ) {
        guard !item.isDirectory else { return }
        let taskID = addTransfer(
            kind: .extract,
            displayName: item.name,
            remotePath: destinationFolder,
            totalUnits: 100
        )
        runningTasks[taskID] = Task { [weak self] in
            guard let self else { return }
            defer { runningTasks[taskID] = nil }
            do {
                setTransferState(taskID, .running)
                let namesBefore = try await namesInFolder(destinationFolder)
                let permissionProbe = createSubfolder
                    ? (item.name as NSString).deletingPathExtension
                    : item.name
                try await repository.checkWritePermission(
                    folderPath: destinationFolder,
                    filename: permissionProbe,
                    createOnly: !overwrite
                )
                let updateProgress = progressHandler(for: taskID)
                try await repository.extract(
                    filePath: item.path,
                    destinationFolder: destinationFolder,
                    overwrite: overwrite,
                    keepDirectoryStructure: keepDirectoryStructure,
                    createSubfolder: createSubfolder,
                    codepage: codepage,
                    password: password,
                    progress: { completed, total in
                        let normalizedCompleted = total == nil && completed <= 1 ? completed * 100 : completed
                        let normalizedTotal = total ?? (completed <= 1 ? 100 : nil)
                        updateProgress(normalizedCompleted, normalizedTotal)
                    }
                )
                let namesAfter = try await namesInFolder(destinationFolder)
                guard overwrite || namesAfter != namesBefore else {
                    throw AppError(
                        category: .partialFailure,
                        isRetryable: true,
                        safeUserMessage: L10n.string("ui.5c351e141dbea40b")
                    )
                }
                finishTransfer(taskID)
                if currentPath == destinationFolder { await refresh() }
                statusIsError = false
                statusMessage = L10n.string("ui.47963deffe8a1291", String(describing: item.name))
            } catch is CancellationError {
                setTransferState(taskID, .cancelled)
            } catch {
                Self.isCancellation(error)
                    ? setTransferState(taskID, .cancelled)
                    : failTransfer(taskID, error: error)
            }
        }
    }

    private func namesInFolder(_ path: String) async throws -> Set<String> {
        var names = Set<String>()
        var offset = 0
        while true {
            let page = try await repository.listFolder(path: path, offset: offset, limit: 500)
            names.formUnion(page.items.map(\.name))
            guard page.hasMore, !page.items.isEmpty else { break }
            offset = page.offset + page.items.count
        }
        return names
    }

    func pasteConflictNames(for targets: [FileItem], in destinationFolder: String) async -> [String]? {
        do {
            let existingNames = try await namesInFolder(destinationFolder)
            return Array(Set(targets.lazy.map(\.name).filter(existingNames.contains)))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            show(error)
            return nil
        }
    }

    func enqueueCrossNASOperation(
        from source: WorkspaceModel,
        targets: [FileItem],
        to destinationFolder: String,
        moveSource: Bool,
        overwrite: Bool = false
    ) {
        guard !targets.isEmpty else { return }
        let total = targets.compactMap(\.sizeBytes).reduce(0, +)
        let knownTotal = targets.contains(where: \.isDirectory) ? nil : (total > 0 ? total * 2 : nil)
        let taskID = addTransfer(
            kind: moveSource ? .move : .copy,
            displayName: targets.count == 1 ? targets[0].name : L10n.string("ui.057c1760db06e516", String(describing: targets.count)),
            remotePath: "\(source.profile.displayName) → \(profile.displayName)\(destinationFolder)",
            fileSizeBytes: targets.contains(where: \.isDirectory) ? nil : total,
            totalUnits: knownTotal
        )
        runningTasks[taskID] = Task { [weak self, weak source] in
            guard let self, let source else { return }
            defer { runningTasks[taskID] = nil }
            do {
                setTransferState(taskID, .running)
                var operationTargets = targets
                var skippedCount = 0
                if !overwrite {
                    let existingNames = try await namesInFolder(destinationFolder)
                    operationTargets = targets.filter { !existingNames.contains($0.name) }
                    skippedCount = targets.count - operationTargets.count
                }
                guard !operationTargets.isEmpty else {
                    finishTransfer(taskID)
                    statusIsError = false
                    statusMessage = L10n.string("ui.a7d7914278b1f450")
                    return
                }
                var completedBeforeFile: Int64 = 0
                for item in operationTargets {
                    try Task.checkCancellation()
                    completedBeforeFile += try await transferCrossNASItem(
                        item,
                        from: source,
                        to: destinationFolder,
                        taskID: taskID,
                        completedBeforeItem: completedBeforeFile,
                        knownTotal: knownTotal,
                        overwrite: overwrite
                    )
                }
                if moveSource {
                    // 所有目标文件确认上传后才删除源文件，避免跨 NAS 移动造成数据丢失。
                    try await source.repository.delete(paths: operationTargets.map(\.path)) { _, _ in }
                    await source.refresh()
                }
                finishTransfer(taskID)
                await refresh()
                statusIsError = false
                let completion = moveSource ? L10n.string("ui.a380c90e47459d56") : L10n.string("ui.f4acd4a3b946157a")
                statusMessage = skippedCount > 0
                    ? L10n.string("operation.skipped_duplicates", completion, String(skippedCount))
                    : completion
            } catch is CancellationError {
                setTransferState(taskID, .cancelled)
            } catch {
                Self.isCancellation(error)
                    ? setTransferState(taskID, .cancelled)
                    : failTransfer(taskID, error: error)
            }
        }
    }

    private func transferCrossNASItem(
        _ item: FileItem,
        from source: WorkspaceModel,
        to destinationFolder: String,
        taskID: UUID,
        completedBeforeItem: Int64,
        knownTotal: Int64?,
        overwrite: Bool
    ) async throws -> Int64 {
        if !overwrite {
            let existingNames = try await namesInFolder(destinationFolder)
            if existingNames.contains(item.name) {
                return 0
            }
        }
        if item.isDirectory {
            do {
                try await repository.createFolder(parentPath: destinationFolder, name: item.name)
            } catch let error as AppError where overwrite && error.category == .conflict {
                // 用户选择替换同名项目时，已有文件夹继续合并其中内容。
            }
            let childDestination = "\(destinationFolder)/\(item.name)"
            var offset = 0
            var completedChildren: Int64 = 0
            while true {
                let page = try await source.repository.listFolder(
                    path: item.path,
                    offset: offset,
                    limit: 500
                )
                for child in page.items {
                    completedChildren += try await transferCrossNASItem(
                        child,
                        from: source,
                        to: childDestination,
                        taskID: taskID,
                        completedBeforeItem: completedBeforeItem + completedChildren,
                        knownTotal: knownTotal,
                        overwrite: overwrite
                    )
                }
                guard page.hasMore, !page.items.isEmpty else { break }
                offset = page.offset + page.items.count
            }
            return completedChildren
        }

        let progress = progressHandler(for: taskID)
        if let sourceRepository = source.repository as? DsmFileRepository,
           let destinationRepository = repository as? DsmFileRepository,
           let expectedSize = item.sizeBytes {
            let base = completedBeforeItem
            try await sourceRepository.streamFileToNAS(
                remotePath: item.path,
                filename: item.name,
                expectedSize: expectedSize,
                target: destinationRepository,
                destinationFolder: destinationFolder,
                overwrite: overwrite
            ) { completed, _ in
                progress(base + completed, knownTotal)
            }
            return expectedSize * 2
        }

        throw AppError(
            category: .invalidResponse,
            isRetryable: false,
            safeUserMessage: L10n.string("ui.545d92f64ef6cb67")
        )
    }

    private func startUpload(
        taskID: UUID,
        localURL url: URL,
        folderPath: String,
        overwrite: Bool
    ) {
        let operation = Task { [weak self] in
                guard let self else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer {
                    if scoped { url.stopAccessingSecurityScopedResource() }
                    runningTasks[taskID] = nil
                }
                do {
                    setTransferState(taskID, .running)
                    try await repository.upload(
                        localURL: url,
                        to: folderPath,
                        overwrite: overwrite,
                        progress: progressHandler(for: taskID)
                    )
                    finishTransfer(taskID)
                    if photoLibrary.currentPath == folderPath {
                        await photoLibrary.refreshAll()
                    } else {
                        await refresh()
                    }
                    statusIsError = false
                    statusMessage = L10n.string("ui.c2fc5b99b068fa2b", String(describing: url.lastPathComponent))
                } catch is CancellationError {
                    finishCancellation(taskID)
                } catch {
                    if Self.isCancellation(error) {
                        finishCancellation(taskID)
                    } else {
                        failTransfer(taskID, error: error)
                    }
                }
            }
            runningTasks[taskID] = operation
    }

    func deleteItems(_ targets: [FileItem]) {
        guard isFileModuleEnabled, !targets.isEmpty else {
            return
        }
        guard Self.canDeleteItems(targets) else {
            statusIsError = true
            statusMessage = L10n.string("ui.3f7c1a9e5b206d84")
            return
        }
        let displayName = targets.count == 1 ? targets[0].name : L10n.string("ui.05ec76407f6737d9", String(describing: targets.count))
        let taskID = addTransfer(
            kind: .delete,
            displayName: displayName,
            remotePath: currentPath,
            totalUnits: Int64(targets.count)
        )
        let paths = targets.map(\.path)
        let deletingFromPhotos = section?.belongsToPhotosModule == true
        let operation = Task { [weak self] in
            guard let self else { return }
            do {
                setTransferState(taskID, .running)
                let result = try await repository.deleteResult(
                    paths: paths,
                    progress: progressHandler(for: taskID)
                )
                if result.requiresRefresh
                    || result.status == .confirmedSuccess
                    || result.status == .partialSuccess {
                    if deletingFromPhotos {
                        if result.status == .confirmedSuccess {
                            photoLibrary.removeDeletedItems(at: paths)
                        }
                        await photoLibrary.refreshAll()
                    } else {
                        await refresh()
                    }
                }

                let feedback = Self.fileDeleteFeedback(for: result.status)
                if feedback.shouldFinish {
                    finishTransfer(taskID)
                    statusIsError = false
                    statusMessage = L10n.string(feedback.resourceKey)
                    showToast(targets.count == 1 ? L10n.string("ui.025cce8bdaa86831") : L10n.string("ui.89b32b0e4eb8d36d", String(describing: targets.count)), icon: "trash.fill")
                } else if feedback.shouldCancel {
                    setTransferState(taskID, .cancelled)
                    statusIsError = false
                    statusMessage = L10n.string(feedback.resourceKey)
                } else {
                    failTransfer(
                        taskID,
                        error: AppError(
                            category: Self.fileDeleteErrorCategory(for: result.status),
                            isRetryable: false,
                            safeUserMessage: L10n.string(feedback.resourceKey)
                        )
                    )
                }
            } catch is CancellationError {
                setTransferState(taskID, .cancelled)
            } catch {
                if Self.isCancellation(error) {
                    setTransferState(taskID, .cancelled)
                } else {
                    failTransfer(taskID, error: error)
                }
            }
            runningTasks[taskID] = nil
        }
        runningTasks[taskID] = operation
    }

    struct FileDeleteFeedback: Equatable {
        let resourceKey: String
        let shouldFinish: Bool
        let shouldCancel: Bool
    }

    static func canDeleteItems(_ items: [FileItem]) -> Bool {
        !items.isEmpty
            && items.allSatisfy { $0.permissions?.canDelete != false }
    }

    static func fileDeleteFeedback(
        for status: MutationResultStatus
    ) -> FileDeleteFeedback {
        switch status {
        case .confirmedSuccess:
            FileDeleteFeedback(
                resourceKey: "ui.fe83a7f35e45f85e",
                shouldFinish: true,
                shouldCancel: false
            )
        case .submittedButUnverified:
            FileDeleteFeedback(
                resourceKey: "ui.4d9a5f1438e2c7b1",
                shouldFinish: false,
                shouldCancel: false
            )
        case .partialSuccess:
            FileDeleteFeedback(
                resourceKey: "ui.6a2c0e8b7f314d95",
                shouldFinish: false,
                shouldCancel: false
            )
        case .confirmedFailure:
            FileDeleteFeedback(
                resourceKey: "ui.9b5e1c7a3d804f62",
                shouldFinish: false,
                shouldCancel: false
            )
        case .permissionDenied:
            FileDeleteFeedback(
                resourceKey: "ui.3f7c1a9e5b206d84",
                shouldFinish: false,
                shouldCancel: false
            )
        case .unsupported:
            FileDeleteFeedback(
                resourceKey: "ui.8c2e6b4a1d957f30",
                shouldFinish: false,
                shouldCancel: false
            )
        case .cancelledBeforeSubmission:
            FileDeleteFeedback(
                resourceKey: "ui.5e1a8d3c7b904f26",
                shouldFinish: false,
                shouldCancel: true
            )
        case .cancellationRequestedAfterSubmission:
            FileDeleteFeedback(
                resourceKey: "ui.7b3d9e1a5c806f42",
                shouldFinish: false,
                shouldCancel: false
            )
        }
    }

    private static func fileDeleteErrorCategory(
        for status: MutationResultStatus
    ) -> AppErrorCategory {
        switch status {
        case .permissionDenied:
            .permissionDenied
        case .unsupported:
            .apiUnavailable
        case .partialSuccess:
            .partialFailure
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            .unknown
        case .confirmedFailure:
            .conflict
        case .confirmedSuccess, .cancelledBeforeSubmission:
            .cancelled
        }
    }

    func restoreToOriginalLocation(_ item: FileItem) {
        guard isFileModuleEnabled else { return }
        guard allowsVerifiedRestore else {
            statusIsError = true
            statusMessage = L10n.string("ui.96ad6681c3a52e78")
            return
        }
        guard let location = RecycleLocation(recyclePath: item.path) else {
            statusIsError = true
            statusMessage = L10n.string("ui.2ba55f653c1d2342")
            return
        }

        let taskID = addTransfer(
            kind: .restore,
            displayName: item.name,
            remotePath: item.path,
            totalUnits: item.sizeBytes
        )
        let operation = Task { [weak self] in
            guard let self else { return }
            do {
                setTransferState(taskID, .running)
                let destination = try await repository.listFolder(
                    path: location.originalParentPath,
                    offset: 0,
                    limit: 500
                )
                guard !destination.items.contains(where: { $0.name == item.name }) else {
                    throw AppError(
                        category: .conflict,
                        isRetryable: false,
                        safeUserMessage: L10n.string("ui.7da31d7e49907f02")
                    )
                }
                try await repository.move(
                    paths: [item.path],
                    to: location.originalParentPath,
                    overwrite: false,
                    progress: progressHandler(for: taskID)
                )
                await refresh()
                guard !items.contains(where: { $0.path == item.path }) else {
                    throw AppError(
                        category: .partialFailure,
                        isRetryable: false,
                        safeUserMessage: L10n.string("ui.cffb0e4a08c8e3a9")
                    )
                }
                let verifiedDestination = try await repository.listFolder(
                    path: location.originalParentPath,
                    offset: 0,
                    limit: 500
                )
                guard verifiedDestination.items.contains(where: { $0.path == location.originalPath }) else {
                    throw AppError(
                        category: .partialFailure,
                        isRetryable: false,
                        safeUserMessage: L10n.string("ui.e4b6882838181446")
                    )
                }
                finishTransfer(taskID)
                statusIsError = false
                statusMessage = L10n.string("ui.55a7aa44050bf4fe", String(describing: item.name))
            } catch is CancellationError {
                setTransferState(taskID, .cancelled)
            } catch {
                if Self.isCancellation(error) {
                    setTransferState(taskID, .cancelled)
                } else {
                    failTransfer(taskID, error: error)
                }
            }
            runningTasks[taskID] = nil
        }
        runningTasks[taskID] = operation
    }

    func cancelTransfer(_ taskID: UUID) {
        setTransferState(taskID, .cancelling)
        runningTasks[taskID]?.cancel()
    }

    func pauseTransfer(_ taskID: UUID) {
        guard restartableTransfers[taskID] != nil,
              transfers.first(where: { $0.id == taskID })?.state == .running else {
            return
        }
        setTransferState(taskID, .paused)
        runningTasks[taskID]?.cancel()
    }

    func resumeTransfer(_ taskID: UUID) {
        guard isFileModuleEnabled,
              let transfer = restartableTransfers[taskID],
              transfers.first(where: { $0.id == taskID })?.state == .paused else {
            return
        }
        restart(taskID, transfer: transfer)
    }

    func retryTransfer(_ taskID: UUID) {
        guard isFileModuleEnabled,
              let transfer = restartableTransfers[taskID],
              let state = transfers.first(where: { $0.id == taskID })?.state,
              state == .failed || state == .cancelled else {
            return
        }
        restart(taskID, transfer: transfer)
    }

    func canRetryTransfer(_ taskID: UUID) -> Bool {
        restartableTransfers[taskID] != nil
    }

    private func restart(_ taskID: UUID, transfer: RestartableTransfer) {
        guard let index = transfers.firstIndex(where: { $0.id == taskID }) else {
            return
        }
        transfers[index].failureMessage = nil
        if case .upload = transfer {
            // 群晖公开上传接口不提供字节偏移续传，继续上传会从头重新发送。
            transfers[index].completedUnits = 0
        }
        setTransferState(taskID, .queued)
        switch transfer {
        case .download(let item, let localURL):
            startDownload(taskID: taskID, item: item, localURL: localURL)
        case .downloadArchive(let item, let localURL):
            startDownload(
                taskID: taskID,
                item: item,
                localURL: localURL,
                downloadsDirectoryAsArchive: true
            )
        case .downloadBatchArchive(let items, let localURL):
            startBatchDownload(taskID: taskID, items: items, localURL: localURL)
        case .upload(let localURL, let folderPath, let overwrite):
            startUpload(
                taskID: taskID,
                localURL: localURL,
                folderPath: folderPath,
                overwrite: overwrite
            )
        }
    }

    private func finishCancellation(_ taskID: UUID) {
        let state = transfers.first(where: { $0.id == taskID })?.state
        if state != .paused {
            setTransferState(taskID, .cancelled)
        }
    }

    func clearCompletedTransfers() {
        let taskIDs = transfers.compactMap { task in
            task.state == .succeeded || task.state == .cancelled ? task.id : nil
        }
        taskIDs.forEach(deleteTransfer)
    }

    func refreshServerBackgroundTasks() async {
        guard isFileModuleEnabled, !isLoadingServerBackgroundTasks else { return }
        backgroundTaskGeneration += 1
        let generation = backgroundTaskGeneration
        isLoadingServerBackgroundTasks = true
        serverBackgroundTaskError = nil
        do {
            let page = try await repository.listBackgroundTasks(offset: 0, limit: 100)
            guard generation == backgroundTaskGeneration, isFileModuleEnabled else { return }
            serverBackgroundTasks = page.tasks
            serverBackgroundTaskTotal = page.total
            serverBackgroundTaskHasMore = page.hasMore
            nextBackgroundTaskOffset = page.nextOffset
            serverBackgroundTaskHasLoaded = true
            isLoadingServerBackgroundTasks = false
        } catch {
            guard generation == backgroundTaskGeneration, isFileModuleEnabled else { return }
            // 刷新失败时保留上一次成功结果，仅展示可安全呈现的错误信息。
            serverBackgroundTaskError = Self.userMessage(for: error)
            serverBackgroundTaskHasLoaded = true
            isLoadingServerBackgroundTasks = false
        }
    }

    func loadMoreServerBackgroundTasks() async {
        guard isFileModuleEnabled,
              serverBackgroundTaskHasMore,
              !isLoadingServerBackgroundTasks else { return }
        let generation = backgroundTaskGeneration
        isLoadingServerBackgroundTasks = true
        serverBackgroundTaskError = nil
        do {
            let page = try await repository.listBackgroundTasks(
                offset: nextBackgroundTaskOffset,
                limit: 100
            )
            guard generation == backgroundTaskGeneration, isFileModuleEnabled else { return }
            var existingIDs = Set(serverBackgroundTasks.map(\.id))
            serverBackgroundTasks.append(contentsOf: page.tasks.filter {
                existingIDs.insert($0.id).inserted
            })
            serverBackgroundTaskTotal = page.total
            serverBackgroundTaskHasMore = page.hasMore
            nextBackgroundTaskOffset = page.nextOffset
            isLoadingServerBackgroundTasks = false
        } catch {
            guard generation == backgroundTaskGeneration, isFileModuleEnabled else { return }
            serverBackgroundTaskError = Self.userMessage(for: error)
            isLoadingServerBackgroundTasks = false
        }
    }

    func deleteTransfer(_ taskID: UUID) {
        let runningTask = runningTasks[taskID]
        let restartableTransfer = restartableTransfers[taskID]
        runningTask?.cancel()
        Task { [weak self] in
            await runningTask?.value
            guard let self else { return }
            if case .download(_, let localURL) = restartableTransfer {
                await repository.removePartialDownload(to: localURL)
            }
            runningTasks[taskID] = nil
            restartableTransfers[taskID] = nil
            progressEstimators[taskID] = nil
            transfers.removeAll { $0.id == taskID }
            saveTransfers()
        }
    }

    func cancelAllWork() {
        suspendFileModule()
        photoLibrary.cancelAllWork()
        chat.cancelAllWork()
    }

    private func suspendFileModule() {
        navigationGeneration += 1
        backgroundTaskGeneration += 1
        remoteLocationGeneration += 1
        previewTask?.cancel()
        previewTask = nil
        searchTask?.cancel()
        searchTask = nil
        dragMoveUndoExpirationTask?.cancel()
        dragMoveUndoExpirationTask = nil
        dragMoveUndo = nil
        toastDismissTask?.cancel()
        toastDismissTask = nil
        activeToast = nil
        runningTasks.values.forEach { $0.cancel() }
        for (itemID, task) in folderStatisticsTasks {
            cancellingFolderStatisticsIDs.insert(itemID)
            task.cancel()
        }

        for index in transfers.indices {
            switch transfers[index].state {
            case .queued, .running, .cancelling:
                transfers[index].state = restartableTransfers[transfers[index].id] == nil
                    ? .cancelled
                    : .paused
                transfers[index].bytesPerSecond = nil
                transfers[index].estimatedSecondsRemaining = nil
            case .paused, .succeeded, .failed, .cancelled:
                break
            }
        }
        progressEstimators.removeAll()
        isLoading = false
        isRefreshing = false
        isLoadingMore = false
        isLoadingServerBackgroundTasks = false
        isLoadingRemoteLocations = false
        remoteLocationsHasLoaded = false
        remoteLocationsError = nil
        unavailableRemoteLocationProtocols = []
        remoteLocationsAreTruncated = false
        isSearching = false
        isMovingItemsByDrag = false
        clearPreview()
        saveTransfers()
    }

    private func discoverRecycleRoots() async {
        var discovered: [FileItem] = []
        for share in shares {
            let path = "\(share.path)/#recycle"
            if (try? await repository.listFolder(path: path, offset: 0, limit: 1)) != nil {
                discovered.append(
                    FileItem(
                        profileID: profile.id,
                        name: share.name,
                        path: path,
                        kind: .directory,
                        isRecyclePath: true
                    )
                )
            }
        }
        recycleRoots = discovered
    }

    private func temporaryPreviewURL(for item: FileItem) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanStashPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = item.fileExtension.map { ".\($0)" } ?? ""
        return directory.appendingPathComponent("\(UUID().uuidString)\(ext)")
    }

    private func clearPreview() {
        previewTask?.cancel()
        clearPreviewFile()
        preview = .empty
        resolvedPreviewKind = nil
        previewLoadingSpeedBytesPerSecond = nil
        editableText = ""
        originalEditableText = ""
        isEditingText = false
        isSavingText = false
        textEditingMessage = nil
        editingTextItemID = nil
        isPreviewPresented = false
    }

    func beginTextEditing() {
        guard canEditSelectedText, !isSavingText else { return }
        isEditingText = true
        textEditingMessage = nil
    }

    func cancelTextEditing() {
        guard !isSavingText else { return }
        editableText = originalEditableText
        isEditingText = false
        textEditingMessage = nil
    }

    func formatEditableText() {
        guard canFormatSelectedText, let ext = selectedItem?.fileExtension?.lowercased() else { return }
        do {
            editableText = try TextDocumentFormatter.format(editableText, fileExtension: ext)
            textEditingMessageIsError = false
            textEditingMessage = L10n.string("ui.edcd411e400a21fa")
        } catch {
            textEditingMessageIsError = true
            textEditingMessage = ext == "xml"
                ? L10n.string("ui.fb87fc9885ea7997")
                : L10n.string("ui.e0f34707b69f67bd")
        }
    }

    func saveTextEdits() async {
        guard canEditSelectedText,
              let item = selectedItem,
              !isSavingText else { return }
        guard hasUnsavedTextEdits else {
            isEditingText = false
            return
        }
        let data = Data(editableText.utf8)
        guard data.count <= 5 * 1_024 * 1_024 else {
            textEditingMessageIsError = true
            textEditingMessage = L10n.string("ui.d7f02859f122de6c")
            return
        }

        isSavingText = true
        textEditingMessage = nil
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanStashTextEdit", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let localURL = directory.appendingPathComponent(item.name)
        defer {
            isSavingText = false
            try? FileManager.default.removeItem(at: directory)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: localURL, options: .atomic)
            let parent = (item.path as NSString).deletingLastPathComponent
            try await repository.upload(localURL: localURL, to: parent, overwrite: true) { _, _ in }
            // 覆盖成功后重新读取并比对内容，避免 NAS 只接收了部分数据时
            // 界面误报“保存成功”。编辑器限制为 5 MB，因此可以完整校验。
            var savedItem: FileItem?
            for attempt in 0..<3 {
                savedItem = try await repository.getInfo(paths: [item.path]).first
                if savedItem?.sizeBytes == Int64(data.count) { break }
                if attempt < 2 { try await Task.sleep(for: .milliseconds(150)) }
            }
            let isSaveVerified: Bool
            if data.isEmpty {
                isSaveVerified = savedItem?.sizeBytes == 0
            } else {
                let savedData = try await repository.readPrefix(
                    remotePath: item.path,
                    maximumLength: data.count + 1
                )
                isSaveVerified = savedItem?.sizeBytes == Int64(data.count) && savedData == data
            }
            guard isSaveVerified else {
                throw AppError(
                    category: .partialFailure,
                    isRetryable: true,
                    safeUserMessage: L10n.string("ui.65f08d0357210c91")
                )
            }
            if let savedItem {
                updateCachedItem(savedItem)
            }
            originalEditableText = editableText
            preview = .text(editableText, truncated: false)
            isEditingText = false
            textEditingMessageIsError = false
            textEditingMessage = L10n.string("ui.78488de343f1c541")
            statusIsError = false
            statusMessage = L10n.string("ui.23c8348cbf752612", String(describing: item.name))
        } catch {
            textEditingMessageIsError = true
            textEditingMessage = Self.userMessage(for: error)
        }
    }

    private func resolvedKindForPreview(_ item: FileItem) async throws -> PreviewKind {
        let declaredKind = PreviewKind.classify(item)
        guard item.fileExtension?.lowercased() == "ts",
              item.mimeType?.lowercased().hasPrefix("video/") != true else {
            return declaredKind
        }
        do {
            let prefix = try await repository.readPrefix(remotePath: item.path, maximumLength: 4_096)
            return FileContentSniffer.classifyTypeScriptOrTransportStream(prefix)
        } catch let error as AppError where error.category == .apiUnavailable {
            return declaredKind
        }
    }

    private func updateCachedItem(_ updatedItem: FileItem) {
        if let index = items.firstIndex(where: { $0.id == updatedItem.id }) {
            items[index] = updatedItem
        }
        if let index = recursiveSearchResults.firstIndex(where: { $0.id == updatedItem.id }) {
            recursiveSearchResults[index] = updatedItem
        }
    }

    private func previewProgressHandler() -> FileTransferProgress {
        { [weak self] completed, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let metrics = self.previewProgressEstimator.update(completed: completed, total: total)
                self.previewLoadingSpeedBytesPerSecond = metrics.speed
            }
        }
    }

    private func clearPreviewFile() {
        if let previewFileURL {
            try? FileManager.default.removeItem(at: previewFileURL)
        }
        previewFileURL = nil
    }

    private func addTransfer(
        kind: ActivityKind,
        displayName: String,
        remotePath: String,
        fileSizeBytes: Int64? = nil,
        totalUnits: Int64? = nil
    ) -> UUID {
        let task = ActivityTask(
            kind: kind,
            displayName: displayName,
            remotePath: remotePath,
            fileSizeBytes: fileSizeBytes,
            totalUnits: totalUnits
        )
        transfers.insert(task, at: 0)
        if isFileModuleEnabled {
            transferNotifier.prepareAuthorization()
        }
        saveTransfers()
        return task.id
    }

    private func progressHandler(for taskID: UUID) -> FileTransferProgress {
        { [weak self] completed, total in
            Task { @MainActor [weak self] in
                guard let self, let index = self.transfers.firstIndex(where: { $0.id == taskID }) else {
                    return
                }
                self.transfers[index].completedUnits = completed
                if let total {
                    self.transfers[index].totalUnits = total
                }
                var estimator = self.progressEstimators[taskID] ?? TransferProgressEstimator()
                let metrics = estimator.update(
                    completed: completed,
                    total: self.transfers[index].totalUnits
                )
                self.progressEstimators[taskID] = estimator
                self.transfers[index].bytesPerSecond = metrics.speed
                self.transfers[index].estimatedSecondsRemaining = metrics.remaining
            }
        }
    }

    private func setTransferState(_ taskID: UUID, _ state: ActivityState) {
        guard let index = transfers.firstIndex(where: { $0.id == taskID }) else {
            return
        }
        transfers[index].state = state
        if state == .running {
            progressEstimators[taskID] = TransferProgressEstimator()
        } else if state == .cancelled || state == .failed {
            progressEstimators[taskID] = nil
            transfers[index].bytesPerSecond = nil
            transfers[index].estimatedSecondsRemaining = nil
        }
        saveTransfers()
    }

    private func finishTransfer(_ taskID: UUID) {
        guard let index = transfers.firstIndex(where: { $0.id == taskID }) else {
            return
        }
        if let total = transfers[index].totalUnits {
            transfers[index].completedUnits = total
        }
        transfers[index].state = .succeeded
        transfers[index].bytesPerSecond = nil
        transfers[index].estimatedSecondsRemaining = nil
        progressEstimators[taskID] = nil
        saveTransfers()
        if isFileModuleEnabled {
            transferNotifier.notify(task: transfers[index], profileName: profile.displayName)
        }
    }

    private func failTransfer(_ taskID: UUID, error: Error) {
        guard let index = transfers.firstIndex(where: { $0.id == taskID }) else {
            return
        }
        transfers[index].state = .failed
        transfers[index].failureMessage = Self.userMessage(for: error)
        transfers[index].bytesPerSecond = nil
        transfers[index].estimatedSecondsRemaining = nil
        progressEstimators[taskID] = nil
        saveTransfers()
        if isFileModuleEnabled {
            transferNotifier.notify(task: transfers[index], profileName: profile.displayName)
        }
        show(error)
    }

    private func show(_ error: Error) {
        guard !Self.isCancellation(error) else { return }
        statusIsError = true
        statusMessage = Self.userMessage(for: error)
        if let error = error as? AppError {
            if error.category == .authenticationRequired {
                requiresReauthentication = true
            }
        } else if error is DsmCertificateTrustError {
            requiresReauthentication = true
        }
    }

    private static func userMessage(for error: Error) -> String {
        if let error = error as? AppError {
            return error.safeUserMessage
        }
        if let error = error as? DsmCertificateTrustError {
            return error.localizedDescription
        }
        return L10n.string("ui.ef299a77b5f7d942")
    }

    private static func decodeText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(data: data, encoding: .utf16LittleEndian)
            ?? String(data: data, encoding: .utf16BigEndian)
    }

    private static let editableTextExtensions: Set<String> = [
        "txt", "md", "markdown", "json", "geojson", "xml", "yaml", "yml", "log", "csv", "tsv",
        "swift", "kt", "kts", "java", "cs", "js", "ts", "tsx", "jsx", "html", "css",
        "py", "rb", "go", "rs", "sh", "zsh", "ini", "conf", "toml"
    ]

    private static func purgeStalePreviewCache() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanStashPreview", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let error = error as? AppError {
            return error.category == .cancelled
        }
        if let error = error as? URLError {
            return error.code == .cancelled
        }
        return false
    }

    private static func matchesSearch(_ name: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        guard regularExpressionQuery(query) != nil else {
            return name.localizedCaseInsensitiveContains(query)
        }
        guard let expression = try? makeSearchRegularExpression(query) else {
            return false
        }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        return expression.firstMatch(in: name, range: range) != nil
    }

    private static func regularExpressionQuery(_ query: String) -> (pattern: String, flags: String)? {
        guard query.first == "/", query.count >= 2 else { return nil }
        let characters = Array(query)
        for index in stride(from: characters.count - 1, through: 1, by: -1) {
            guard characters[index] == "/" else { continue }
            var precedingBackslashes = 0
            var cursor = index - 1
            while cursor >= 1, characters[cursor] == "\\" {
                precedingBackslashes += 1
                cursor -= 1
            }
            if precedingBackslashes.isMultiple(of: 2) {
                let pattern = String(characters[1..<index])
                let flags = String(characters[(index + 1)...])
                guard flags.allSatisfy({ $0 == "i" }) else { return nil }
                return (pattern, flags)
            }
        }
        return nil
    }

    private static func makeSearchRegularExpression(_ query: String) throws -> NSRegularExpression {
        guard let parsed = regularExpressionQuery(query) else {
            return try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: query))
        }
        let options: NSRegularExpression.Options = parsed.flags.contains("i")
            ? [.caseInsensitive]
            : []
        return try NSRegularExpression(pattern: parsed.pattern, options: options)
    }

    func mediaStreamSource(path: String, fileExtension: String?) async throws -> MediaStreamSource {
        try await repository.mediaStreamSource(
            remotePath: path,
            fileExtension: fileExtension,
            expectedContentLength: nil
        )
    }
}
