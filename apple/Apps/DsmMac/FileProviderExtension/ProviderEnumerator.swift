import FileProvider
import Foundation

final class ProviderEnumerator: NSObject, NSFileProviderEnumerator, @unchecked Sendable {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let runtime: ProviderRuntime
    private let operations = ProviderOperationRegistry()
    private let pageSize = 500
    private let changePageSize = 200

    init(
        containerIdentifier: NSFileProviderItemIdentifier,
        runtime: ProviderRuntime
    ) {
        self.containerIdentifier = containerIdentifier
        self.runtime = runtime
        super.init()
    }

    func invalidate() {
        operations.cancelAll()
        Task {
            await runtime.invalidate()
        }
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let offset = Int(String(data: page.rawValue, encoding: .utf8) ?? "") ?? 0
        let observerBox = UncheckedSendableBox(observer)
        let operationID = UUID()
        let operation = Task {
            defer { operations.remove(operationID) }
            do {
                let result = try await runtime.enumerate(
                    containerIdentifier: containerIdentifier,
                    offset: offset,
                    limit: pageSize
                )
                observerBox.value.didEnumerate(result.items)
                let nextPage = result.nextOffset.map {
                    NSFileProviderPage(Data(String($0).utf8))
                }
                observerBox.value.finishEnumerating(upTo: nextPage)
            } catch {
                observerBox.value.finishEnumeratingWithError(error)
            }
        }
        operations.insert(operation, id: operationID)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        let observerBox = UncheckedSendableBox(observer)
        let operationID = UUID()
        let operation = Task {
            defer { operations.remove(operationID) }
            do {
                let result = try await runtime.enumerateChanges(
                    for: containerIdentifier,
                    from: anchor.rawValue,
                    limit: changePageSize
                )
                if !result.updatedItems.isEmpty {
                    observerBox.value.didUpdate(result.updatedItems)
                }
                if !result.deletedItemIdentifiers.isEmpty {
                    observerBox.value.didDeleteItems(
                        withIdentifiers: result.deletedItemIdentifiers
                    )
                }
                observerBox.value.finishEnumeratingChanges(
                    upTo: NSFileProviderSyncAnchor(result.nextAnchor),
                    moreComing: result.moreComing
                )
            } catch {
                observerBox.value.finishEnumeratingWithError(error)
            }
        }
        operations.insert(operation, id: operationID)
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        let completionBox = UncheckedSendableBox(completionHandler)
        let operationID = UUID()
        let operation = Task {
            defer { operations.remove(operationID) }
            do {
                let anchor = try await runtime.currentChangeAnchor(
                    for: containerIdentifier
                )
                completionBox.value(NSFileProviderSyncAnchor(anchor))
            } catch {
                completionBox.value(nil)
            }
        }
        operations.insert(operation, id: operationID)
    }
}

final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
