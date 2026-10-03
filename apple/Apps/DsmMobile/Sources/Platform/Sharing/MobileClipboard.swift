import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
protocol MobileClipboardWriting {
    func copySensitiveURL(_ url: URL)
    func copySensitiveURLs(_ urls: [URL])
}

@MainActor
struct MobileSystemClipboard: MobileClipboardWriting {
    private static let lifetime: TimeInterval = 10 * 60

    func copySensitiveURL(_ url: URL) { copySensitiveURLs([url]) }

    func copySensitiveURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        var item: [String: Any] = [UTType.utf8PlainText.identifier: urls.map(\.absoluteString).joined(separator: "\n")]
        if urls.count == 1 { item[UTType.url.identifier] = urls[0] }
        UIPasteboard.general.setItems(
            [item],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(Self.lifetime),
            ]
        )
    }
}
