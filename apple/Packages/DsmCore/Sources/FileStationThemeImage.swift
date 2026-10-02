import Foundation

/// 分享页面的图片选择意图；不包含鉴权 URL，也不持久保存图片或路径。
public struct FileStationThemeImage: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Identifiable, Sendable {
        case logo, background
        public var id: String { rawValue }
    }
    public enum Source: String, Sendable { case nas = "fromDS", history, systemDefault = "default" }
    public let kind: Kind
    public let source: Source
    public let path: String
    public let name: String
    public let historyIndex: Int?
    public var id: String { kind.rawValue + ":" + source.rawValue + ":" + path }
    public init(kind: Kind, source: Source, path: String, name: String, historyIndex: Int? = nil) {
        self.kind = kind; self.source = source; self.path = path; self.name = name; self.historyIndex = historyIndex
    }
    public static func supportsFilename(_ name: String) -> Bool {
        ["jpg", "jpeg", "jpe", "gif", "bmp", "png"].contains((name as NSString).pathExtension.lowercased())
    }
}
