import Foundation
import UniformTypeIdentifiers

/// NSItemProvider 的临时 URL 只在回调期间有效，必须在返回回调前复制到自己的目录。
enum MobileShareIntake {
    static func supportedType(for provider: NSItemProvider) -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return UTType.fileURL.identifier }
        return provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier) else { return false }
            return !type.conforms(to: .url) && (type.conforms(to: .data) || type.conforms(to: .directory))
        }
    }

    @MainActor
    static func receive(_ providers: [NSItemProvider], directory: URL) async throws -> [URL] {
        guard !providers.isEmpty else { throw CocoaError(.fileReadUnsupportedScheme) }
        try MobileExtensionStorage.prepareDirectory(directory)
        var files: [URL] = []
        for (index, provider) in providers.enumerated() {
            try Task.checkCancellation()
            guard let type = supportedType(for: provider) else { throw CocoaError(.fileReadUnsupportedScheme) }
            let target = directory.appendingPathComponent(String(index), isDirectory: true)
            try MobileExtensionStorage.prepareDirectory(target)
            let suggestedName = provider.suggestedName
            let file: URL = try await withCheckedThrowingContinuation { continuation in
                let accept: @Sendable (URL?, Error?) -> Void = { url, error in
                    do {
                        if let error { throw error }
                        guard let url else { throw CocoaError(.fileReadUnknown) }
                        let result = try copyRepresentation(url, suggestedName: suggestedName, type: type, directory: target)
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
                if type == UTType.fileURL.identifier {
                    provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                        accept(item as? URL, error)
                    }
                } else { provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: accept) }
            }
            try Task.checkCancellation()
            files.append(file)
        }
        return files
    }

    static func copyRepresentation(_ source: URL, suggestedName: String?, type: String, directory: URL) throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        var coordinationError: NSError?
        var result: Result<URL, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { coordinated in
            result = Result { try copyCoordinatedRepresentation(coordinated, suggestedName: suggestedName, type: type, directory: directory) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private static func copyCoordinatedRepresentation(_ source: URL, suggestedName: String?, type: String, directory: URL) throws -> URL {
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
        guard source.isFileURL, values.isSymbolicLink != true,
              values.isRegularFile == true || values.isDirectory == true else { throw CocoaError(.fileReadUnsupportedScheme) }
        var name = suggestedName ?? source.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
        if values.isDirectory != true, URL(fileURLWithPath: name).pathExtension.isEmpty {
            let fileExtension = source.pathExtension.isEmpty ? UTType(type)?.preferredFilenameExtension : source.pathExtension
            if let fileExtension, !fileExtension.isEmpty { name += "." + fileExtension }
        }
        let destination = directory.appendingPathComponent(name, isDirectory: values.isDirectory == true)
        try FileManager.default.copyItem(at: source, to: destination)
        try protect(destination)
        if values.isDirectory == true {
            guard let enumerator = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
                throw CocoaError(.fileReadUnknown)
            }
            for case let child as URL in enumerator {
                if try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { enumerator.skipDescendants(); continue }
                try protect(child)
            }
        }
        return destination
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
