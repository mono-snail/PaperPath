import Foundation
import StoreKit
import UIKit
import UserNotifications

enum AppPreferences {
    static let onboardingCompletedKey =
        "experience.onboardingCompleted.v4"
    static let onboardingReplayRequestedKey =
        "experience.onboardingReplayRequested"
    static let metadataSyncEnabledKey =
        "privacy.metadataSyncEnabled"
    static let dueRemindersEnabledKey =
        "reminders.dueDatesEnabled"
    static let previewQualityKey =
        "performance.previewQuality"
    static let latestReleaseSeenKey =
        "experience.latestReleaseSeen"
    static let currentRelease = "v4"

    static func registerDefaults(
        defaults: UserDefaults = .standard
    ) {
        defaults.register(defaults: [
            metadataSyncEnabledKey: false,
            dueRemindersEnabledKey: false,
            previewQualityKey: ThumbnailPreviewQuality.automatic.rawValue
        ])
    }
}

enum ThumbnailPreviewQuality:
    String,
    CaseIterable,
    Identifiable {
    case automatic
    case economy
    case detailed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .economy: return "Save Memory"
        case .detailed: return "Sharper Previews"
        }
    }

    var detail: String {
        switch self {
        case .automatic:
            return "Adapts preview work to this device"
        case .economy:
            return "Uses fewer cached thumbnails"
        case .detailed:
            return "Keeps more high-resolution previews"
        }
    }

    var renderScale: CGFloat {
        switch self {
        case .automatic:
            if Self.isAutomaticResourceConstrained {
                return 1
            }
            return ProcessInfo.processInfo.physicalMemory
                < 4 * 1_024 * 1_024 * 1_024 ? 1.25 : 1.65
        case .economy:
            return 1
        case .detailed:
            return 2
        }
    }

    var cacheEntryLimit: Int {
        switch self {
        case .automatic:
            return Self.isAutomaticResourceConstrained ? 24 : 48
        case .economy: return 24
        case .detailed: return 72
        }
    }

    var cacheByteLimit: Int {
        switch self {
        case .automatic:
            return Self.isAutomaticResourceConstrained
                ? 5 * 1_024 * 1_024
                : 10 * 1_024 * 1_024
        case .economy: return 5 * 1_024 * 1_024
        case .detailed: return 18 * 1_024 * 1_024
        }
    }

    var cacheDocumentLimit: Int {
        switch self {
        case .automatic:
            return Self.isAutomaticResourceConstrained ? 1 : 2
        case .economy:
            return 1
        case .detailed:
            return 3
        }
    }

    private static var isAutomaticResourceConstrained: Bool {
        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled {
            return true
        }
        switch processInfo.thermalState {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            return true
        }
    }

    static var selected: Self {
        let value = UserDefaults.standard.string(
            forKey: AppPreferences.previewQualityKey
        )
        return Self(rawValue: value ?? "") ?? .automatic
    }
}

enum AppEntitlement {
    static let productID =
        "com.monoware.paperpath.full-unlock"

    private static let unlockedKey =
        "commerce.fullUnlock.cached"
    private static let verifiedOutputCountKey =
        "commerce.verifiedOutputCount"
    private static let lastVerifiedOutputAtKey =
        "commerce.lastVerifiedOutputAt"
    private static let lastVerifiedFailureAtKey =
        "commerce.lastVerifiedFailureAt"
    private static let ratingRequestedKey =
        "experience.ratingRequested"

    static var isUnlocked: Bool {
        UserDefaults.standard.bool(forKey: unlockedKey)
    }

    static var verifiedOutputCount: Int {
        UserDefaults.standard.integer(
            forKey: verifiedOutputCountKey
        )
    }

    static var canCreateSingleVerifiedOutput: Bool {
        isUnlocked || verifiedOutputCount == 0
    }

    static func setUnlocked(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: unlockedKey)
    }

    @discardableResult
    static func recordVerifiedOutput() -> Int {
        let count = verifiedOutputCount + 1
        UserDefaults.standard.set(
            count,
            forKey: verifiedOutputCountKey
        )
        UserDefaults.standard.set(
            Date(),
            forKey: lastVerifiedOutputAtKey
        )
        return count
    }

    static func recordVerifiedFailure() {
        UserDefaults.standard.set(
            Date(),
            forKey: lastVerifiedFailureAtKey
        )
    }

    static var shouldRequestRating: Bool {
        let defaults = UserDefaults.standard
        guard verifiedOutputCount >= 2,
              !defaults.bool(forKey: ratingRequestedKey),
              let successAt = defaults.object(
                forKey: lastVerifiedOutputAtKey
              ) as? Date
        else { return false }
        let failureAt = defaults.object(
            forKey: lastVerifiedFailureAtKey
        ) as? Date
        return failureAt == nil || failureAt! < successAt
    }

    static func markRatingRequested() {
        UserDefaults.standard.set(
            true,
            forKey: ratingRequestedKey
        )
    }
}

@MainActor
final class PurchaseController: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case purchasing
        case pending
        case purchased
        case cancelled
        case unavailable
        case failed(String)

        var detail: String {
            switch self {
            case .idle:
                return "One-time purchase · no subscription"
            case .loading:
                return "Checking App Store"
            case .purchasing:
                return "Confirming purchase"
            case .pending:
                return "Purchase approval is pending"
            case .purchased:
                return "Lifetime Verified Output is active"
            case .cancelled:
                return "Purchase cancelled"
            case .unavailable:
                return "App Store product is unavailable"
            case let .failed(message):
                return message
            }
        }
    }

    @Published private(set) var product: Product?
    @Published private(set) var isUnlocked =
        AppEntitlement.isUnlocked
    @Published private(set) var status = Status.idle

    private var updatesTask: Task<Void, Never>?

    init() {
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self,
                      case let .verified(transaction) = result
                else { continue }
                await self.apply(transaction)
                await transaction.finish()
            }
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    var displayPrice: String {
        product?.displayPrice ?? ""
    }

    func prepare() async {
        status = .loading
        do {
            product = try await Product.products(
                for: [AppEntitlement.productID]
            ).first
            await refreshEntitlement()
            if isUnlocked {
                status = .purchased
            } else {
                status = product == nil ? .unavailable : .idle
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func refreshForLaunch() async {
        await refreshEntitlement()
        let refreshedStatus: Status =
            isUnlocked ? .purchased : .idle
        if status != refreshedStatus {
            status = refreshedStatus
        }
    }

    func purchase() async {
        guard let product else {
            status = .unavailable
            return
        }
        status = .purchasing
        do {
            switch try await product.purchase() {
            case let .success(result):
                guard case let .verified(transaction) = result else {
                    status = .failed(
                        "The purchase could not be verified."
                    )
                    return
                }
                await apply(transaction)
                await transaction.finish()
                status = .purchased
            case .pending:
                status = .pending
            case .userCancelled:
                status = .cancelled
            @unknown default:
                status = .failed(
                    "The App Store returned an unknown result."
                )
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func restore() async {
        status = .loading
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            status = isUnlocked
                ? .purchased
                : .failed("No lifetime purchase was found.")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func refreshEntitlement() async {
        var unlocked = false
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  transaction.productID == AppEntitlement.productID,
                  transaction.revocationDate == nil
            else { continue }
            unlocked = true
            break
        }
        // StoreKit's current entitlements are the authority after launch.
        // Keeping a stale local unlock here would ignore refunds or revocation.
        if isUnlocked != unlocked {
            isUnlocked = unlocked
        }
        AppEntitlement.setUnlocked(isUnlocked)
    }

    private func apply(
        _ transaction: StoreKit.Transaction
    ) async {
        guard transaction.productID == AppEntitlement.productID
        else { return }
        let unlocked = transaction.revocationDate == nil
        if isUnlocked != unlocked {
            isUnlocked = unlocked
        }
        AppEntitlement.setUnlocked(unlocked)
    }
}

enum LocalDueReminderScheduler {
    private static let identifierPrefix =
        "paperpath.due."

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func authorizationStatus()
        async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }

    static func update(
        recordID: UUID,
        dueAt: Date?
    ) async {
        let center = UNUserNotificationCenter.current()
        let identifier = identifierPrefix + recordID.uuidString
        center.removePendingNotificationRequests(
            withIdentifiers: [identifier]
        )
        guard UserDefaults.standard.bool(
            forKey: AppPreferences.dueRemindersEnabledKey
        ),
        let dueAt
        else { return }

        let content = UNMutableNotificationContent()
        content.title = AppBrand.name
        content.body = AppLocalization.string(
            "A private PDF is due for review."
        )
        content.sound = .default

        let calendar = Calendar.current
        var fireDate = calendar.date(
            bySettingHour: 9,
            minute: 0,
            second: 0,
            of: dueAt
        ) ?? dueAt
        if fireDate <= Date() {
            fireDate = Date().addingTimeInterval(60)
        }
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(
                dateMatching: components,
                repeats: false
            )
        )
        try? await center.add(request)
    }

    static func disableAll() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let identifiers = requests
                .map(\.identifier)
                .filter { $0.hasPrefix(identifierPrefix) }
            center.removePendingNotificationRequests(
                withIdentifiers: identifiers
            )
        }
    }
}

@MainActor
enum SupportBundleService {
    static func create(
        documentCount: Int,
        deletedCount: Int,
        pageCount: Int,
        localByteCount: Int64,
        indexedDocumentCount: Int,
        ocrDocumentCount: Int,
        receiptCount: Int,
        metadataSyncState: String
    ) throws -> URL {
        let bundle = Bundle.main
        let payload: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "app": [
                "version": bundle.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                "build": bundle.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "unknown"
            ],
            "device": [
                "model": UIDevice.current.model,
                "system": UIDevice.current.systemName,
                "systemVersion": UIDevice.current.systemVersion,
                "physicalMemory": ProcessInfo.processInfo.physicalMemory
            ],
            "library": [
                "documentCount": documentCount,
                "trashCount": deletedCount,
                "pageCount": pageCount,
                "allocatedPDFBytes": localByteCount,
                "indexedDocumentCount": indexedDocumentCount,
                "ocrDocumentCount": ocrDocumentCount,
                "receiptCount": receiptCount
            ],
            "settings": [
                "metadataSyncEnabled": UserDefaults.standard.bool(
                    forKey: AppPreferences.metadataSyncEnabledKey
                ),
                "metadataSyncState": metadataSyncState,
                "previewQuality": ThumbnailPreviewQuality.selected.rawValue,
                "appLockEnabled": UserDefaults.standard.bool(
                    forKey: AppLockController.defaultsKey
                ),
                "fullUnlock": AppEntitlement.isUnlocked
            ],
            "privacy": [
                "containsPDFBytes": false,
                "containsFileNames": false,
                "containsExtractedText": false,
                "containsPasswords": false,
                "containsSignatures": false
            ]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PaperPath-Diagnostics-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        LocalFileSecurity.applyCompleteProtection(to: directory)
        LocalFileSecurity.excludeFromBackup(directory)
        let url = directory.appendingPathComponent(
            "PaperPath-Diagnostics.json"
        )
        try data.write(to: url, options: .atomic)
        LocalFileSecurity.applyCompleteProtection(to: url)
        return url
    }

    static func discard(_ url: URL?) {
        guard let url else { return }
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent
            .hasPrefix("PaperPath-Diagnostics-")
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
