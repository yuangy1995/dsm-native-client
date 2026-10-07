import DsmCore
import DsmFileFeature
import DsmLocalization
import DsmNetwork
import Foundation
import Observation

@MainActor @Observable
final class MobileShareComposerModel {
    enum Phase { case loading, ready, preparing, submitted, failed, closed }
    private let accountStore: MobileExtensionAccountStore
    private let transfers: MobileShareTransferStore
    private let loadInput: @MainActor () async throws -> [URL]
    private let cleanupInput: @MainActor () -> Void
    private let makeRepository: @Sendable (MobileExtensionAccount) async throws -> any FileRepository
    private var repository: (any FileRepository)?
    private var lease: MobileShareTransferLease?
    private var record: MobileShareTransfer?
    private var inputFiles: [URL] = []
    private var loadGeneration = UUID()
    private var nextOffset = 0
    private var didLoad = false
    private var isSubmitting = false
    private(set) var phase: Phase = .loading
    private(set) var accounts: [MobileExtensionAccount] = []
    private(set) var selectedAccount: MobileExtensionAccount?
    private(set) var folders: [FileItem] = []
    private(set) var path = ""
    private(set) var isLoadingFolders = false
    private(set) var hasMore = false
    private(set) var error: String?
    private(set) var folderError: String?
    private(set) var queue: MobileFileUploadQueue?

    init(accounts: MobileExtensionAccountStore, sessions: any SessionSecureStoring,
         transfers: MobileShareTransferStore, loadInput: @escaping @MainActor () async throws -> [URL],
         cleanupInput: @escaping @MainActor () -> Void,
         makeRepository: (@Sendable (MobileExtensionAccount) async throws -> any FileRepository)? = nil) {
        accountStore = accounts
        self.transfers = transfers
        self.loadInput = loadInput
        self.cleanupInput = cleanupInput
        self.makeRepository = makeRepository ?? { account in
            try await MobileExtensionTransport.repository(account: account, accounts: accounts, sessions: sessions)
        }
    }

    var fileNames: [String] { inputFiles.map(\.lastPathComponent) }
    var canUpload: Bool { phase == .ready && selectedAccount != nil && repository != nil && !inputFiles.isEmpty && !path.isEmpty && folderError == nil && !isLoadingFolders }
    var isRunning: Bool { queue?.batches.contains(where: \.isRunning) == true }
    var allSucceeded: Bool {
        guard let batches = queue?.batches, !batches.isEmpty else { return false }
        return batches.allSatisfy { !$0.isRunning && $0.entries.allSatisfy { [.succeeded, .skipped].contains($0.state) } }
    }

    func load() async {
        guard !didLoad else { return }
        didLoad = true
        do {
            accounts = try accountStore.accounts()
            guard !accounts.isEmpty else { phase = .failed; error = L10n.string("mobile.share.no-account"); return }
            inputFiles = try await loadInput()
            try Task.checkCancellation()
            guard phase != .closed else { cleanupInput(); return }
            guard !inputFiles.isEmpty else { throw CocoaError(.fileReadUnsupportedScheme) }
            phase = .ready
            if let first = accounts.first { await selectAccount(first.id) }
        } catch {
            guard phase != .closed else { cleanupInput(); return }
            phase = .failed
            self.error = L10n.string("mobile.share.receive-error")
        }
    }

    func selectAccount(_ id: UUID) async {
        guard phase == .ready, let account = accounts.first(where: { $0.id == id }) else { return }
        selectedAccount = account; repository = nil
        path = ""; folders = []; nextOffset = 0; hasMore = false; folderError = nil
        let generation = UUID(); loadGeneration = generation; isLoadingFolders = true
        do {
            try accountStore.requireCurrent(account)
            let repository = try await makeRepository(account)
            guard generation == loadGeneration, phase == .ready else { return }
            self.repository = repository
            await navigate(to: "")
        } catch {
            guard generation == loadGeneration, phase == .ready else { return }
            folderError = Self.message(error)
            isLoadingFolders = false
        }
    }

    func navigate(to path: String) async {
        guard phase == .ready, repository != nil else { return }
        loadGeneration = UUID()
        self.path = path; folders = []; nextOffset = 0; hasMore = false; folderError = nil
        await loadFolderPage()
    }

    func goUp() async {
        guard !path.isEmpty else { return }
        let components = path.split(separator: "/").dropLast()
        await navigate(to: components.isEmpty ? "" : "/" + components.joined(separator: "/"))
    }

    func loadMore() async {
        guard hasMore, !isLoadingFolders else { return }
        await loadFolderPage()
    }

    func retryFolder() async {
        if repository == nil, let selectedAccount { await selectAccount(selectedAccount.id) }
        else { await navigate(to: path) }
    }

    private func loadFolderPage() async {
        guard let repository, let account = selectedAccount else { return }
        let generation = loadGeneration, requestedPath = path, offset = nextOffset
        isLoadingFolders = true; folderError = nil
        do {
            try accountStore.requireCurrent(account)
            let page = try await requestedPath.isEmpty
                ? repository.listShares(offset: offset, limit: 200)
                : repository.listFolder(path: requestedPath, offset: offset, limit: 200)
            guard generation == loadGeneration, phase == .ready else { return }
            guard page.offset == offset, !page.hasMore || !page.items.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            var paths = Set(folders.map(\.path))
            folders += page.items.filter { $0.isDirectory && paths.insert($0.path).inserted }
            nextOffset = page.offset + page.items.count; hasMore = page.hasMore
        } catch {
            guard generation == loadGeneration, phase == .ready else { return }
            folderError = Self.message(error)
        }
        if generation == loadGeneration { isLoadingFolders = false }
    }

    func upload(overwrite: Bool) async {
        guard canUpload, let account = selectedAccount, let repository else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        phase = .preparing; error = nil
        do {
            try accountStore.requireCurrent(account)
            let (record, lease) = try transfers.create(profile: account.profile)
            self.record = record; self.lease = lease
            let queue = MobileFileUploadQueue(rootURL: transfers.queueURL(record.id), expectedContext: record.context)
            self.queue = queue
            queue.configure(profile: account.profile, repository: repository)
            while queue.isConfiguring { try await Task.sleep(for: .milliseconds(10)) }
            guard phase == .preparing else { return }
            await queue.prepare(inputFiles, destination: path)
            guard phase == .preparing else { return }
            try accountStore.requireCurrent(account)
            await queue.submit(overwrite: overwrite)
            guard phase == .preparing else { return }
            guard !queue.batches.isEmpty else { throw CocoaError(.fileWriteUnknown) }
            phase = .submitted
            cleanupInput()
        } catch {
            guard phase != .closed else { return }
            if let record, let lease, queue?.batches.isEmpty != false {
                try? transfers.remove(record, lease: lease)
                self.record = nil; self.lease = nil; queue = nil
            }
            phase = .ready
            self.error = Self.message(error)
        }
    }

    func pause() { for batch in queue?.batches ?? [] { batch.pause() } }
    func cancelUploads() { for batch in queue?.batches ?? [] { batch.cancel() } }

    /// 先让现有队列落盘并停止网络，再释放所有权。完成回调不得先于该步骤。
    func close() async {
        guard phase != .closed else { return }
        phase = .closed; loadGeneration = UUID()
        queue?.dismissSelection()
        pause()
        while isSubmitting || queue?.batches.contains(where: \.isRunning) == true {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if let record, let lease, queue?.batches.isEmpty != false {
            try? transfers.remove(record, lease: lease)
        }
        queue = nil; lease = nil
        cleanupInput()
    }

    private static func message(_ error: Error) -> String {
        if let appError = error as? AppError { return appError.safeUserMessage }
        if error is MobileExtensionAccountError { return L10n.string("mobile.extensions.sign-in-again") }
        return L10n.string("mobile.share.upload-error")
    }
}
