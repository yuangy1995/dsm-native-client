import Foundation

public struct FileISOMountConnection: Equatable, Identifiable, Sendable {
    public let profileID: UUID
    public let source: String
    public let mountPoint: String
    public let automaticMount: Bool?
    public var id: String { mountPoint }
    public init(profileID: UUID, source: String, mountPoint: String, automaticMount: Bool?) {
        self.profileID = profileID; self.source = source; self.mountPoint = mountPoint; self.automaticMount = automaticMount
    }
}

public struct FileISOMountRequest: Equatable, Sendable {
    public let source: FileItem
    public let destination: FileItem
    public let automaticMount: Bool
    public init(source: FileItem, destination: FileItem, automaticMount: Bool = false) {
        self.source = source; self.destination = destination; self.automaticMount = automaticMount
    }
}

public enum FileISOMountChange: Equatable, Sendable {
    case mount(FileISOMountRequest)
    case unmount(FileISOMountConnection)
    public var mountPoint: String {
        switch self { case .mount(let request): request.destination.path; case .unmount(let connection): connection.mountPoint }
    }
}
