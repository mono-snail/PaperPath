import Combine
import UniformTypeIdentifiers
import UIKit

@MainActor
enum SecurePasteboard {
    struct OwnershipToken: Equatable, Sendable {
        fileprivate let changeCount: Int
    }

    private static let maximumTextBytes = 8 * 1_024 * 1_024
    private static var ownedChangeCount: Int?

    @discardableResult
    static func copy(_ value: String) -> Bool {
        copyWithOwnership(value) != nil
    }

    static func copyWithOwnership(
        _ value: String
    ) -> OwnershipToken? {
        guard !value.isEmpty,
              value.utf8.count <= maximumTextBytes
        else { return nil }
        let pasteboard = UIPasteboard.general
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: value]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(5 * 60)
            ]
        )
        ownedChangeCount = pasteboard.changeCount
        return OwnershipToken(changeCount: pasteboard.changeCount)
    }

    static func clearIfOwned() {
        let pasteboard = UIPasteboard.general
        guard let ownedChangeCount else { return }
        defer { self.ownedChangeCount = nil }
        guard pasteboard.changeCount == ownedChangeCount else { return }
        pasteboard.items = []
    }

    static var isOwnedContentCurrent: Bool {
        guard let ownedChangeCount else { return false }
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount == ownedChangeCount,
              pasteboard.hasStrings
        else {
            self.ownedChangeCount = nil
            return false
        }
        return true
    }

    static func isCurrent(_ token: OwnershipToken) -> Bool {
        guard ownedChangeCount == token.changeCount else {
            return false
        }
        let pasteboard = UIPasteboard.general
        guard pasteboard.changeCount == token.changeCount,
              pasteboard.hasStrings
        else {
            ownedChangeCount = nil
            return false
        }
        return true
    }
}

@MainActor
final class SecurePasteboardCopyController: ObservableObject {
    enum Status: Equatable {
        case idle
        case copied
        case failed
    }

    @Published private(set) var status = Status.idle
    @Published private(set) var successFeedback = 0
    @Published private(set) var errorFeedback = 0

    private var ownershipToken: SecurePasteboard.OwnershipToken?
    private var statusResetTask: Task<Void, Never>?

    @discardableResult
    func copy(_ value: String) -> Bool {
        statusResetTask?.cancel()
        statusResetTask = nil
        guard let token = SecurePasteboard.copyWithOwnership(value) else {
            ownershipToken = nil
            status = .failed
            errorFeedback += 1
            scheduleStatusReset(after: .seconds(5))
            return false
        }
        ownershipToken = token
        status = .copied
        successFeedback += 1
        scheduleStatusReset(after: .seconds(5 * 60))
        return true
    }

    func synchronizeOwnership() {
        guard status == .copied,
              let ownershipToken,
              !SecurePasteboard.isCurrent(ownershipToken)
        else { return }
        reset()
    }

    func reset() {
        statusResetTask?.cancel()
        statusResetTask = nil
        ownershipToken = nil
        status = .idle
    }

    private func scheduleStatusReset(
        after duration: Duration
    ) {
        statusResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.reset()
        }
    }
}
