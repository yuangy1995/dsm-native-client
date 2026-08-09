import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

enum MobilePhotosPickerFailure: Error, Equatable, Sendable {
    case itemUnavailable
}

final class MobilePhotosPickerArtifact: @unchecked Sendable {
    let url: URL

    private let ownedDirectory: URL?
    private let lock = NSLock()
    private var released = false

    init(url: URL, ownedDirectory: URL? = nil) {
        self.url = url
        self.ownedDirectory = ownedDirectory
    }

    func release() {
        lock.lock()
        guard !released else {
            lock.unlock()
            return
        }
        released = true
        let directory = ownedDirectory
        lock.unlock()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    deinit {
        release()
    }
}

protocol MobilePhotosPickerItemServing: Sendable {
    var selectionID: String { get }
    func loadArtifact() async throws -> MobilePhotosPickerArtifact
}

private final class MobilePhotosPickerFile: Transferable, @unchecked Sendable {
    let artifact: MobilePhotosPickerArtifact

    init(artifact: MobilePhotosPickerArtifact) {
        self.artifact = artifact
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try makeOwnedCopy(of: received.file)
        }
        FileRepresentation(importedContentType: .movie) { received in
            try makeOwnedCopy(of: received.file)
        }
    }

    private static func makeOwnedCopy(of source: URL) throws -> MobilePhotosPickerFile {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanStashPhotoImport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = source.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..",
                  !name.contains("\\"),
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw MobilePhotosPickerFailure.itemUnavailable
            }
            let destination = directory.appendingPathComponent(name, isDirectory: false)
            try FileManager.default.copyItem(at: source, to: destination)
            return Self(artifact: MobilePhotosPickerArtifact(
                url: destination,
                ownedDirectory: directory
            ))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}

struct MobileSystemPhotosPickerItem: MobilePhotosPickerItemServing {
    let selectionID: String
    private let item: PhotosPickerItem

    init(_ item: PhotosPickerItem) {
        self.item = item
        selectionID = item.itemIdentifier ?? UUID().uuidString
    }

    func loadArtifact() async throws -> MobilePhotosPickerArtifact {
        guard let file = try await item.loadTransferable(type: MobilePhotosPickerFile.self) else {
            throw MobilePhotosPickerFailure.itemUnavailable
        }
        return file.artifact
    }
}
