import Foundation

protocol MobileDocumentImportCopying: Sendable {
    func copySecurityScopedFile(
        from sourceURL: URL,
        to destinationURL: URL,
        in directoryURL: URL
    ) async throws
}

struct MobileSecurityScopedDocumentCopier: MobileDocumentImportCopying {
    func copySecurityScopedFile(
        from sourceURL: URL,
        to destinationURL: URL,
        in directoryURL: URL
    ) async throws {
        let hasScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            try MobileExtensionStorage.prepareDirectory(directoryURL)
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: (any Error)?
            coordinator.coordinate(
                readingItemAt: sourceURL,
                options: .withoutChanges,
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    let values = try coordinatedURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
                    try fileManager.copyItem(at: coordinatedURL, to: destinationURL)
                    try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destinationURL.path)
                } catch {
                    copyError = error
                }
            }
            if let copyError { throw copyError }
            if let coordinationError { throw coordinationError }
        }.value
    }
}
