import UniformTypeIdentifiers
import UIKit

@MainActor
enum SecurePasteboard {
    static func copy(_ value: String) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(5 * 60)
            ]
        )
    }
}
