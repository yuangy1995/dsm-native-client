import FileProvider
import Foundation
import DsmCore

/// 系统回调桥接共用运行时；各平台保留自己的扩展入口与依赖来源。
open class ProviderExtension: NSObject, @unchecked Sendable {
    private let configuredRuntime: Result<ProviderRuntime, Error>
    private var runtime: ProviderRuntime { get throws { try configuredRuntime.get() } }
    private let operations = ProviderOperationRegistry()

    public init(mappingIdentifier: String, dependencies: ProviderRuntimeDependencies) {
        configuredRuntime = .success(ProviderRuntime(mappingIdentifier: mappingIdentifier, dependencies: dependencies))
        super.init()
    }

    public init(mappingIdentifier: String, makeDependencies: () throws -> ProviderRuntimeDependencies) {
        configuredRuntime = Result { ProviderRuntime(mappingIdentifier: mappingIdentifier, dependencies: try makeDependencies()) }
        super.init()
    }

    @objc(invalidate)
    public func invalidate() {
        operations.cancelAll()
        Task {
            try? await runtime.invalidate()
        }
    }

    @objc(itemForIdentifier:request:completionHandler:)
    public func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completionBox = UncheckedSendableBox(completionHandler)
        let operationID = UUID()
        let operation = Task {
            defer { operations.remove(operationID) }
            do {
                completionBox.value(try await runtime.item(for: identifier), nil)
                progress.completedUnitCount = 1
            } catch {
                completionBox.value(
                    nil,
                    ProviderErrorMapper.map(error, itemIdentifier: identifier)
                )
            }
        }
        operations.insert(operation, id: operationID)
        progress.cancellationHandler = {
            operation.cancel()
        }
        return progress
    }

    @objc(fetchContentsForItemWithIdentifier:version:request:completionHandler:)
    public func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completionBox = UncheckedSendableBox(completionHandler)
        let sendableRequestedVersion = requestedVersion.map {
            ProviderRequestedVersion(
                content: $0.contentVersion,
                metadata: $0.metadataVersion
            )
        }
        let operationID = UUID()
        let operation = Task {
            defer { operations.remove(operationID) }
            do {
                let result = try await runtime.fetchContents(
                    for: itemIdentifier,
                    requestedVersion: sendableRequestedVersion
                ) { completedBytes, totalBytes in
                    if let totalBytes, totalBytes > 0 {
                        progress.totalUnitCount = totalBytes
                    }
                    progress.completedUnitCount = min(
                        max(completedBytes, 0),
                        progress.totalUnitCount
                    )
                }
                completionBox.value(result.0, result.1, nil)
                progress.completedUnitCount = progress.totalUnitCount
            } catch {
                completionBox.value(
                    nil,
                    nil,
                    ProviderErrorMapper.map(
                        error,
                        itemIdentifier: itemIdentifier
                    )
                )
            }
        }
        operations.insert(operation, id: operationID)
        progress.cancellationHandler = {
            operation.cancel()
        }
        return progress
    }

    @objc(createItemBasedOnTemplate:fields:contents:options:request:completionHandler:)
    public func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let template = ProviderImportedItemTemplate(item: itemTemplate)
        let completionBox = UncheckedSendableBox(completionHandler)
        let operationID = UUID()
        let operation = Task {
            defer { operations.remove(operationID) }
            do {
                if let item = try await runtime.itemForImportedSystemItem(
                    template
                ) {
                    completionBox.value(item, [], false, nil)
                } else {
                    let item = try await runtime.writeItem(template, baseVersion: nil, contents: url, creating: true) { completed, total in
                        if let total { progress.totalUnitCount = max(total, 1) }
                        progress.completedUnitCount = min(completed, max(progress.totalUnitCount - 1, 0))
                    }
                    completionBox.value(item, [], false, nil)
                }
                progress.completedUnitCount = progress.totalUnitCount
            } catch {
                completionBox.value(
                    nil,
                    [],
                    false,
                    ProviderErrorMapper.map(
                        error,
                        itemIdentifier: template.identifier
                    )
                )
            }
        }
        operations.insert(operation, id: operationID)
        progress.cancellationHandler = {
            operation.cancel()
        }
        return progress
    }

    @objc(modifyItem:baseVersion:changedFields:contents:options:request:completionHandler:)
    public func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (
            NSFileProviderItem?,
            NSFileProviderItemFields,
            Bool,
            Error?
        ) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completionBox = UncheckedSendableBox(completionHandler)
        let template = ProviderImportedItemTemplate(item: item)
        let base = ProviderRequestedVersion(content: version.contentVersion, metadata: version.metadataVersion)
        let operationID = UUID()
        let operation = Task {
            defer { operations.remove(operationID) }
            do {
                if changedFields.contains(.contents), newContents == nil, !template.isDirectory {
                    throw DesktopDriveWritebackError.invalidItem
                }
                let result = try await runtime.writeItem(template, baseVersion: base,
                    contents: changedFields.contains(.contents) ? newContents : nil, creating: false) { completed, total in
                        if let total { progress.totalUnitCount = max(total, 1) }
                        progress.completedUnitCount = min(completed, max(progress.totalUnitCount - 1, 0))
                    }
                let handled: NSFileProviderItemFields = [.contents, .filename, .parentItemIdentifier, .creationDate, .contentModificationDate]
                completionBox.value(result, changedFields.subtracting(handled), false, nil)
                progress.completedUnitCount = progress.totalUnitCount
            } catch {
                completionBox.value(nil, [], false, ProviderErrorMapper.map(error, itemIdentifier: template.identifier))
            }
        }
        operations.insert(operation, id: operationID)
        progress.cancellationHandler = { operation.cancel() }
        return progress
    }

    @objc(deleteItemWithIdentifier:baseVersion:options:request:completionHandler:)
    public func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completionBox = UncheckedSendableBox(completionHandler)
        let base = ProviderRequestedVersion(content: version.contentVersion, metadata: version.metadataVersion)
        let recursive = options.contains(.recursive)
        let operationID = UUID()
        let operation = Task {
            defer { operations.remove(operationID) }
            do {
                try await runtime.deleteItem(identifier: identifier, baseVersion: base, recursive: recursive) { completed, total in
                    if let total { progress.totalUnitCount = max(total, 1) }
                    progress.completedUnitCount = min(completed, max(progress.totalUnitCount - 1, 0))
                }
                completionBox.value(nil)
                progress.completedUnitCount = progress.totalUnitCount
            } catch {
                completionBox.value(ProviderErrorMapper.mapDeletion(error, itemIdentifier: identifier))
            }
        }
        operations.insert(operation, id: operationID)
        progress.cancellationHandler = {
            operation.cancel()
        }
        return progress
    }

    @objc(enumeratorForContainerItemIdentifier:request:error:)
    public func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer {
            return ProviderEmptyEnumerator()
        }
        return ProviderEnumerator(
            containerIdentifier: containerItemIdentifier,
            runtime: try runtime
        )
    }

    @objc(importDidFinishWithCompletionHandler:)
    public func importDidFinish(completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
