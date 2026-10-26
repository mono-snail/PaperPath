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
    private static let maximumVerifiedOutputCount = 1_000_000
    private(set) static var didVerifyStoreKitEntitlement = false

    static var isUnlocked: Bool {
        UserDefaults.standard.bool(forKey: unlockedKey)
    }

    static var canCreateVerifiedOutput: Bool {
        didVerifyStoreKitEntitlement && isUnlocked
    }

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

    static func setUnlocked(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: unlockedKey)
        didVerifyStoreKitEntitlement = true
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

enum FullUnlockContext: Equatable {
    case settings
    case singleVerifiedOutput
    case batchVerifiedOutput

    var isBlockedAction: Bool {
        self != .settings
    }

    var title: String {
        switch self {
        case .settings:
            return "Own trusted delivery for life."
        case .singleVerifiedOutput:
            return "Continue verified delivery."
        case .batchVerifiedOutput:
            return "Unlock batch verified delivery."
        }
    }

    var detail: String {
        switch self {
        case .settings:
            return "First Verified Output is free. Unlock unlimited copies anytime."
        case .singleVerifiedOutput:
            return "Your free Verified Output has been used. One purchase unlocks unlimited verified copies."
        case .batchVerifiedOutput:
            return "Lifetime access includes batch Verified Output. Reading and editing stay available."
        }
    }
}

@MainActor
final class PurchaseController: ObservableObject {
    enum Operation: Equatable {
        case refreshing
        case preparing
        case purchasing
        case restoring
    }

    enum Status: Equatable {
        case idle
        case loading
        case purchasing
        case restoring
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
            case .restoring:
                return "Checking previous purchases"
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
    @Published private(set) var activeOperation: Operation?

    private var updatesTask: Task<Void, Never>?
    private var entitlementRefreshTask: Task<Bool, Never>?
    private var entitlementRefreshID: UUID?
    private var entitlementRefreshRevision: UInt64?
    private var entitlementRevision: UInt64 = 0

    init() {
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self,
                      case let .verified(transaction) = result,
                      transaction.productID == AppEntitlement.productID
                else { continue }
                await self.apply(transaction)
                await transaction.finish()
                if self.activeOperation == nil {
                    self.status = self.isUnlocked
                        ? .purchased
                        : .idle
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
        entitlementRefreshTask?.cancel()
    }

    var displayPrice: String {
        product?.displayPrice ?? ""
    }

    var isBusy: Bool {
        activeOperation != nil
    }

    var purchaseControlsDisabled: Bool {
        isBusy || status == .pending
    }

    func prepare() async {
        while activeOperation == .refreshing {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
        }
        guard begin(.preparing) else { return }
        defer { finishOperation() }
        let preservesPendingStatus = status == .pending
        status = .loading
        do {
            if product == nil {
                product = try await Product.products(
                    for: [AppEntitlement.productID]
                ).first
            }
            guard !Task.isCancelled else {
                restoreStableStatus(
                    preservingPending: preservesPendingStatus
                )
                return
            }
            guard await refreshEntitlement() else {
                restoreStableStatus(
                    preservingPending: preservesPendingStatus
                )
                return
            }
            if isUnlocked {
                status = .purchased
            } else {
                status = preservesPendingStatus
                    ? .pending
                    : product == nil ? .unavailable : .idle
            }
        } catch is CancellationError {
            restoreStableStatus(
                preservingPending: preservesPendingStatus
            )
        } catch {
            status = preservesPendingStatus
                ? .pending
                : .failed(
                    AppLocalization.userFacingErrorDescription(error)
                )
        }
    }

    func refreshForLaunch() async {
        let preservesPendingStatus = status == .pending
        let ownsOperation = begin(.refreshing)
        defer {
            if ownsOperation {
                finishOperation()
            }
        }
        guard await refreshEntitlement() else { return }
        if ownsOperation {
            restoreStableStatus(preservingPending: preservesPendingStatus)
        }
    }

    func purchase() async {
        guard begin(.purchasing) else { return }
        defer { finishOperation() }
        do {
            if product == nil {
                status = .loading
                product = try await Product.products(
                    for: [AppEntitlement.productID]
                ).first
                guard !Task.isCancelled else {
                    restoreStableStatus()
                    return
                }
            }
            guard let product else {
                status = .unavailable
                return
            }
            status = .purchasing
            switch try await product.purchase() {
            case let .success(result):
                guard case let .verified(transaction) = result,
                      transaction.productID == AppEntitlement.productID
                else {
                    status = .failed(
                        "The purchase could not be verified."
                    )
                    return
                }
                await apply(transaction)
                await transaction.finish()
                status = isUnlocked
                    ? .purchased
                    : .failed("The purchase is no longer active.")
            case .pending:
                status = .pending
            case .userCancelled:
                status = .cancelled
            @unknown default:
                status = .failed(
                    "The App Store returned an unknown result."
                )
            }
        } catch is CancellationError {
            restoreStableStatus()
        } catch {
            status = .failed(
                AppLocalization.userFacingErrorDescription(error)
            )
        }
    }

    func restore() async {
        guard begin(.restoring) else { return }
        defer { finishOperation() }
        status = .restoring
        do {
            try await AppStore.sync()
            guard await refreshEntitlement() else {
                restoreStableStatus()
                return
            }
            status = isUnlocked
                ? .purchased
                : .failed("No lifetime purchase was found.")
        } catch is CancellationError {
            restoreStableStatus()
        } catch {
            status = .failed(
                AppLocalization.userFacingErrorDescription(error)
            )
        }
    }

    func recheckPendingPurchase() async {
        guard status == .pending else {
            await prepare()
            return
        }
        guard begin(.refreshing) else { return }
        defer { finishOperation() }
        status = .loading
        guard await refreshEntitlement() else {
            restoreStableStatus(preservingPending: true)
            return
        }
        // Ask to Buy remains pending until StoreKit delivers a decision.
        // An empty entitlement snapshot is not a rejected transaction.
        status = isUnlocked ? .purchased : .pending
    }

    private func refreshEntitlement() async -> Bool {
        let refreshID: UUID
        let requestedRevision: UInt64
        let task: Task<Bool, Never>
        if let activeTask = entitlementRefreshTask,
           let activeID = entitlementRefreshID,
           let activeRevision = entitlementRefreshRevision {
            refreshID = activeID
            requestedRevision = activeRevision
            task = activeTask
        } else {
            refreshID = UUID()
            requestedRevision = entitlementRevision
            task = Task {
                var unlocked = false
                for await result in StoreKit.Transaction
                    .currentEntitlements {
                    guard case let .verified(transaction) = result,
                          transaction.productID
                            == AppEntitlement.productID,
                          transaction.revocationDate == nil
                    else { continue }
                    unlocked = true
                    break
                }
                return unlocked
            }
            entitlementRefreshID = refreshID
            entitlementRefreshRevision = requestedRevision
            entitlementRefreshTask = task
        }

        let unlocked = await task.value
        let callerWasCancelled = Task.isCancelled
        guard entitlementRefreshID == refreshID else {
            return !callerWasCancelled
        }
        entitlementRefreshID = nil
        entitlementRefreshRevision = nil
        entitlementRefreshTask = nil
        guard entitlementRevision == requestedRevision else {
            return !callerWasCancelled
        }
        // StoreKit's current entitlements are the authority after launch.
        // Keeping a stale local unlock here would ignore refunds or revocation.
        if isUnlocked != unlocked {
            isUnlocked = unlocked
        }
        AppEntitlement.setUnlocked(isUnlocked)
        return !callerWasCancelled
    }

    private func apply(
        _ transaction: StoreKit.Transaction
    ) async {
        guard transaction.productID == AppEntitlement.productID
        else { return }
        entitlementRevision &+= 1
        let unlocked = transaction.revocationDate == nil
        if isUnlocked != unlocked {
            isUnlocked = unlocked
        }
        AppEntitlement.setUnlocked(unlocked)
    }

    private func begin(_ operation: Operation) -> Bool {
        guard activeOperation == nil else { return false }
        activeOperation = operation
        return true
    }

    private func finishOperation() {
        activeOperation = nil
    }

    private func restoreStableStatus(
        preservingPending: Bool = false
    ) {
        status = isUnlocked
            ? .purchased
            : preservingPending ? .pending : .idle
    }
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
                ),
                "fullUnlock":
                    AppEntitlement.canCreateVerifiedOutput
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
