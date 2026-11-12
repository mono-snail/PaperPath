import Foundation
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
    static var currentRelease: String {
        Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.1.0"
    }

    static var versionDescription: String {
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "4"
        return "\(currentRelease) (\(build))"
    }

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

@MainActor
enum AppUsageHistory {
    private static let verifiedOutputCountKey =
        "commerce.verifiedOutputCount"
    private static let lastVerifiedOutputAtKey =
        "commerce.lastVerifiedOutputAt"
    private static let lastVerifiedFailureAtKey =
        "commerce.lastVerifiedFailureAt"
    private static let ratingRequestedKey =
        "experience.ratingRequested"
    private static let maximumVerifiedOutputCount = 1_000_000
    static var verifiedOutputCount: Int {
        min(
            maximumVerifiedOutputCount,
            max(
                0,
                UserDefaults.standard.integer(
                    forKey: verifiedOutputCountKey
                )
            )
        )
    }


    @discardableResult
    static func recordVerifiedOutput() -> Int {
        let count = min(
            maximumVerifiedOutputCount,
            verifiedOutputCount + 1
        )
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
              ) as? Date,
              isPlausibleExperienceDate(successAt)
        else { return false }
        guard let failureAt = defaults.object(
            forKey: lastVerifiedFailureAtKey
        ) as? Date else {
            return true
        }
        return isPlausibleExperienceDate(failureAt)
            && failureAt < successAt
    }

    private static func isPlausibleExperienceDate(
        _ date: Date
    ) -> Bool {
        let timestamp = date.timeIntervalSince1970
        return timestamp.isFinite
            && timestamp >= 0
            && date <= Date().addingTimeInterval(5 * 60)
    }

    static func markRatingRequested() {
        UserDefaults.standard.set(
            true,
            forKey: ratingRequestedKey
        )
    }

#if DEBUG
    static func resetVerifiedOutputHistoryForUITesting() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: verifiedOutputCountKey)
        defaults.removeObject(forKey: lastVerifiedOutputAtKey)
        defaults.removeObject(forKey: lastVerifiedFailureAtKey)
        defaults.removeObject(forKey: ratingRequestedKey)
    }
#endif
}

enum LocalDueReminderScheduler {
    private static let identifierPrefix =
        "paperpath.due."
    // Keep headroom below the system-wide pending notification limit.
    private static let maximumPendingReminderCount = 60

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

    @discardableResult
    static func update(
        recordID: UUID,
        dueAt: Date?
    ) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let identifier = identifierPrefix + recordID.uuidString
        center.removePendingNotificationRequests(
            withIdentifiers: [identifier]
        )
        guard UserDefaults.standard.bool(
            forKey: AppPreferences.dueRemindersEnabledKey
        ),
        let dueAt
        else { return true }

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
        let pending = await center.pendingNotificationRequests()
        let otherPaperPathRequests = pending.filter {
            $0.identifier.hasPrefix(identifierPrefix)
                && $0.identifier != identifier
        }
        if otherPaperPathRequests.count
            >= maximumPendingReminderCount {
            let scheduledRequests = otherPaperPathRequests.map {
                request in
                (
                    request: request,
                    date: nextFireDate(for: request)
                )
            }
            let furthestFirst = scheduledRequests.sorted {
                lhs, rhs in
                lhs.date > rhs.date
            }
            guard let furthest = furthestFirst.first,
                  fireDate < furthest.date
            else {
                return false
            }
            let removalCount =
                otherPaperPathRequests.count
                    - maximumPendingReminderCount + 1
            center.removePendingNotificationRequests(
                withIdentifiers: furthestFirst
                    .prefix(removalCount)
                    .map { $0.request.identifier }
            )
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
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    static func disableAll() async {
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(
            withIdentifiers: identifiers
        )
    }

    private static func nextFireDate(
        for request: UNNotificationRequest
    ) -> Date {
        (request.trigger as? UNCalendarNotificationTrigger)?
            .nextTriggerDate() ?? .distantFuture
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
                )
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
        let url = directory.appendingPathComponent(
            "PaperPath-Diagnostics.json"
        )
        do {
            try LocalFileSecurity.prepareProtectedDirectory(
                at: directory
            )
            try data.write(to: url, options: .atomic)
            try LocalFileSecurity.requireCompleteProtection(to: url)
            return url
        } catch {
            PaperPathTemporaryArtifact.removeManagedItem(
                containing: directory,
                allowedPrefixes: ["PaperPath-Diagnostics-"]
            )
            throw error
        }
    }

    static func discard(_ url: URL?) {
        guard let url else { return }
        PaperPathTemporaryArtifact.removeManagedItem(
            containing: url,
            allowedPrefixes: ["PaperPath-Diagnostics-"]
        )
    }
}
