import Foundation
import UIKit
import UniformTypeIdentifiers

@MainActor
protocol MobileClipboardWriting {
    func copySensitiveURL(_ url: URL)
}

@MainActor
struct MobileSystemClipboard: MobileClipboardWriting {
    private static let lifetime: TimeInterval = 10 * 60

    func copySensitiveURL(_ url: URL) {
        UIPasteboard.general.setItems(
            [[UTType.url.identifier: url]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(Self.lifetime),
            ]
        )
    }
}
