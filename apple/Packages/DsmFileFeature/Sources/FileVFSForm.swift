import DsmCore
import Foundation

/// 表单接受完整地址；提交给既有接口时仍使用独立的主机、端口和文件夹字段。
public enum FileVFSForm {
    public struct ValidationError: Error {
        public let resourceKey: String
    }

    public static func configuration(_ draft: FileVFSConfiguration, protocols: [FileVFSProtocol], editingProtocol: String? = nil) throws -> FileVFSConfiguration {
        let value = try resolveAddress(draft, protocols: protocols, editingProtocol: editingProtocol)
        guard !value.alias.isEmpty, value.alias.count <= 255 else { throw invalid("files.vfs.invalidAlias") }
        guard !value.codepage.isEmpty else { throw invalid("files.vfs.invalidEncoding") }
        return value
    }

    public static func resolveAddress(_ draft: FileVFSConfiguration, protocols: [FileVFSProtocol], editingProtocol: String? = nil) throws -> FileVFSConfiguration {
        var value = draft
        value.hostname = draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        value.alias = draft.alias.trimmingCharacters(in: .whitespacesAndNewlines)
        value.folder = draft.folder.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hostname.contains("://") {
            guard let url = URLComponents(string: value.hostname), let scheme = url.scheme?.lowercased(),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil else { throw invalid("files.vfs.invalidAddress") }
            let protocolID: String
            switch (draft.protocolID, scheme) {
            case ("dav", "http"), ("davs", "http"), ("dav", "dav"), ("davs", "dav"): protocolID = "dav"
            case ("dav", "https"), ("davs", "https"), ("dav", "davs"), ("davs", "davs"): protocolID = "davs"
            case ("ftp", "ftp"): protocolID = "ftp"
            case ("sftp", "sftp"): protocolID = "sftp"
            default: throw invalid("files.vfs.addressTypeMismatch")
            }
            if let editingProtocol, protocolID != editingProtocol { throw invalid("files.vfs.editAddressTypeMismatch") }
            guard let selected = protocols.first(where: { $0.id == protocolID && $0.supportsServerSetup }) else {
                throw invalid("files.vfs.addressTypeMismatch")
            }
            value.protocolID = protocolID
            value.hostname = host
            if let port = url.port { value.port = port }
            else if draft.port == 0 || draft.port == protocols.first(where: { $0.id == draft.protocolID })?.defaultPort {
                value.port = selected.defaultPort ?? (protocolID == "davs" ? 443 : protocolID == "dav" ? 80 : draft.port)
            }
            let folder = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !folder.isEmpty {
                guard protocolID == "dav" || protocolID == "davs" else { throw invalid("files.vfs.invalidAddress") }
                guard value.folder.isEmpty || value.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == folder else {
                    throw invalid("files.vfs.folderMismatch")
                }
                value.folder = folder
            }
        }
        guard protocols.contains(where: { $0.id == value.protocolID && $0.supportsServerSetup }) else { throw invalid("files.vfs.addressTypeMismatch") }
        guard !value.hostname.isEmpty, !value.hostname.contains(where: { $0.isWhitespace || "/@?#".contains($0) }) else {
            throw invalid("files.vfs.invalidAddress")
        }
        guard (1...65535).contains(value.port) else { throw invalid("files.vfs.invalidPort") }
        return value
    }

    public static func usesCleartext(_ draft: FileVFSConfiguration) -> Bool {
        if ["dav", "davs"].contains(draft.protocolID), let scheme = URLComponents(string: draft.hostname.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased() {
            if ["https", "davs"].contains(scheme) { return false }
            if ["http", "dav"].contains(scheme) { return true }
        }
        return draft.protocolID == "ftp" || draft.protocolID == "dav"
    }

    private static func invalid(_ key: String) -> ValidationError { .init(resourceKey: key) }
}
