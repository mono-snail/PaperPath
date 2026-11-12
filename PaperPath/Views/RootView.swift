import Foundation
import LocalAuthentication
import StoreKit
import SwiftUI
import UIKit

private struct PaperPathSceneIDKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    var paperPathSceneID: UUID? {
        get { self[PaperPathSceneIDKey.self] }
        set { self[PaperPathSceneIDKey.self] = newValue }
    }
}

enum AppLockDelay: Int, CaseIterable, Identifiable {
    case immediately = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .immediately: return "Immediately"
        case .oneMinute: return "After 1 Minute"
        case .fiveMinutes: return "After 5 Minutes"
        case .fifteenMinutes: return "After 15 Minutes"
        }
    }
}

enum AppLockLifecyclePolicy {
    static func preservesAuthenticationTask(
        isAuthenticating: Bool
    ) -> Bool {
        isAuthenticating
    }

    static func shouldAttemptAutomaticUnlock(
        becameGloballyActive: Bool,
        isLocked: Bool,
        isAuthenticating: Bool
    ) -> Bool {
        becameGloballyActive && isLocked && !isAuthenticating
    }
}

@MainActor
final class AppLockController: ObservableObject {
    static let defaultsKey = "privacy.appLockEnabled"
    static let delayDefaultsKey = "privacy.appLockDelay"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isLocked: Bool
    @Published private(set) var delay: AppLockDelay
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isAvailable = false
    @Published private(set) var biometryType = LABiometryType.none
    @Published private(set) var errorMessage: String?
    @Published private(set) var lockGeneration = 0

    private let defaults: UserDefaults
    private let authenticationOverride:
        (@MainActor @Sendable (String) async -> Bool)?
    private let uptimeProvider: @Sendable () -> TimeInterval
    private var backgroundedAt: Date?
    private var backgroundedUptime: TimeInterval?
    private var authenticationContext: LAContext?
    private var authenticationGeneration = 0
    private var activeSceneIDs = Set<UUID>()

    var hasActiveScenes: Bool {
        !activeSceneIDs.isEmpty
    }

    init(
        defaults: UserDefaults = .standard,
        authenticationOverride:
            (@MainActor @Sendable (String) async -> Bool)? = nil,
        uptimeProvider: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.defaults = defaults
        self.authenticationOverride = authenticationOverride
        self.uptimeProvider = uptimeProvider
        let enabled = defaults.bool(
            forKey: Self.defaultsKey
        )
        delay = AppLockDelay(
            rawValue: defaults.integer(
                forKey: Self.delayDefaultsKey
            )
        ) ?? .immediately
        isEnabled = enabled
        isLocked = enabled
        refreshAvailability()
    }

    var methodTitle: String {
        switch biometryType {
        case .faceID: return "Face ID or device passcode"
        case .touchID: return "Touch ID or device passcode"
        case .opticID: return "Optic ID or device passcode"
        case .none: return "Device passcode"
        @unknown default: return "Device authentication"
        }
    }

    var symbol: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "lock.fill"
        @unknown default: return "lock.fill"
        }
    }

    @discardableResult
    func enable() async -> Bool {
        guard !isEnabled else { return true }
        refreshAvailability()
        let authenticated = await authenticate(
            reason: "Enable App Lock for your private PaperPath workspace."
        )
        guard authenticated else { return false }

        defaults.set(true, forKey: Self.defaultsKey)
        isEnabled = true
        isLocked = false
        errorMessage = nil
        return true
    }

    @discardableResult
    func disable() async -> Bool {
        guard isEnabled else { return true }
        let authenticated = await authenticate(
            reason: "Authenticate to disable App Lock."
        )
        guard authenticated else { return false }
        defaults.set(false, forKey: Self.defaultsKey)
        isEnabled = false
        isLocked = false
        backgroundedAt = nil
        backgroundedUptime = nil
        errorMessage = nil
        return true
    }

    func setDelay(_ delay: AppLockDelay) {
        defaults.set(delay.rawValue, forKey: Self.delayDefaultsKey)
        self.delay = delay
    }

    func didEnterBackground(at date: Date = Date()) {
        cancelAuthentication()
        guard isEnabled else { return }
        backgroundedAt = date
        backgroundedUptime = uptimeProvider()
        if delay == .immediately {
            lock()
        }
    }

    func didBecomeActive(at date: Date = Date()) {
        refreshAvailability()
        guard isEnabled else {
            backgroundedAt = nil
            backgroundedUptime = nil
            return
        }
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil
        let wallClockElapsed = max(
            0,
            date.timeIntervalSince(backgroundedAt)
        )
        let uptimeElapsed: TimeInterval
        let currentUptime = uptimeProvider()
        if let backgroundedUptime,
           currentUptime >= backgroundedUptime {
            uptimeElapsed = currentUptime - backgroundedUptime
        } else {
            uptimeElapsed = 0
        }
        self.backgroundedUptime = nil
        let elapsed = max(wallClockElapsed, uptimeElapsed)
        if elapsed >= TimeInterval(delay.rawValue) {
            lock()
        }
    }

    @discardableResult
    func sceneDidBecomeActive(
        _ sceneID: UUID,
        at date: Date = Date()
    ) -> Bool {
        let wasEmpty = activeSceneIDs.isEmpty
        activeSceneIDs.insert(sceneID)
        if wasEmpty {
            didBecomeActive(at: date)
        }
        return wasEmpty
    }

    @discardableResult
    func sceneDidEnterBackground(
        _ sceneID: UUID,
        at date: Date = Date()
    ) -> Bool {
        guard activeSceneIDs.remove(sceneID) != nil,
              activeSceneIDs.isEmpty
        else { return false }
        didEnterBackground(at: date)
        return true
    }

    @discardableResult
    func sceneDidDisconnect(
        _ sceneID: UUID,
        at date: Date = Date()
    ) -> Bool {
        sceneDidEnterBackground(sceneID, at: date)
    }

    private func lock() {
        guard isEnabled else { return }
        cancelAuthentication()
        guard !isLocked else { return }
        isLocked = true
        lockGeneration &+= 1
    }

    func lockNow() {
        SecurePasteboard.clearIfOwned()
        lock()
    }

    func protectedDataWillBecomeUnavailable() {
        cancelAuthentication()
        if isEnabled {
            lock()
        }
    }

    @discardableResult
    func unlock() async -> Bool {
        guard isEnabled else {
            isLocked = false
            return true
        }
        guard isLocked else { return true }
        let authenticated = await authenticate(
            reason: "Unlock your private PaperPath workspace."
        )
        if authenticated {
            isLocked = false
            errorMessage = nil
        }
        return authenticated
    }

    func clearError() {
        errorMessage = nil
    }

    func cancelPendingAuthentication() {
        guard isAuthenticating || authenticationContext != nil else {
            return
        }
        cancelAuthentication()
    }

    private func refreshAvailability() {
        if authenticationOverride != nil {
            isAvailable = true
            biometryType = .none
            return
        }
        let context = LAContext()
        var error: NSError?
        isAvailable = context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        )
        _ = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: nil
        )
        biometryType = context.biometryType
    }

    private func authenticate(reason: String) async -> Bool {
        guard !isAuthenticating else { return false }
        errorMessage = nil
        if let authenticationOverride {
            authenticationGeneration &+= 1
            let generation = authenticationGeneration
            isAuthenticating = true
            defer {
                if authenticationGeneration == generation {
                    isAuthenticating = false
                }
            }
            let authenticated = await authenticationOverride(reason)
            guard authenticationGeneration == generation,
                  !Task.isCancelled
            else { return false }
            return authenticated
        }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel".localizedUI

        var evaluationError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &evaluationError
        ) else {
            isAvailable = false
            errorMessage = evaluationError.map {
                AppLocalization.userFacingErrorDescription(
                    $0,
                    fallback:
                        "Device authentication is unavailable."
                )
            } ?? "Device authentication is unavailable.".localizedUI
            return false
        }
        isAvailable = true
        _ = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: nil
        )
        biometryType = context.biometryType

        authenticationGeneration &+= 1
        let generation = authenticationGeneration
        authenticationContext = context
        isAuthenticating = true
        defer {
            if authenticationGeneration == generation {
                authenticationContext = nil
                isAuthenticating = false
            }
        }
        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason.localizedUI
            )
            guard authenticationGeneration == generation,
                  !Task.isCancelled
            else { return false }
            return authenticated
        } catch let error as LAError {
            guard authenticationGeneration == generation else {
                return false
            }
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                errorMessage = nil
            default:
                errorMessage = AppLocalization
                    .userFacingErrorDescription(error)
            }
            return false
        } catch {
            guard authenticationGeneration == generation else {
                return false
            }
            errorMessage = AppLocalization
                .userFacingErrorDescription(error)
            return false
        }
    }

    private func cancelAuthentication() {
        authenticationGeneration &+= 1
        authenticationContext?.invalidate()
        authenticationContext = nil
        isAuthenticating = false
    }
}

private struct LibraryRestorableContext: Equatable {
    let searchScope: LibrarySearchScope
    let statusFilter: DocumentWorkflowStatus?
    let categoryFilter: DocumentCategory?
    let smartView: LibrarySmartView?
}

struct RootView: View {
    private let initialRecordID: UUID?

    @EnvironmentObject private var model: PaperPathModel
    @EnvironmentObject private var appLock: AppLockController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.requestReview) private var requestReview
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityVoiceOverEnabled)
    private var voiceOverEnabled
    @AppStorage(AppPreferences.onboardingCompletedKey)
    private var onboardingCompleted = false
    @AppStorage(AppPreferences.onboardingReplayRequestedKey)
    private var onboardingReplayRequested = false
    @SceneStorage("workspace.lastRecordID")
    private var lastWorkspaceRecordID = ""
    @SceneStorage("workspace.deskVisible")
    private var isDeskVisible = true
    @SceneStorage("workspace.resolvedInitialRecordID")
    private var savedInitialRecordID = ""
    @SceneStorage("workspace.comparisonPeerID")
    private var lastComparisonPeerID = ""
    @SceneStorage("workspace.splitVisibility")
    private var savedSplitVisibility = "all"
    @SceneStorage("workspace.readingRecordID")
    private var sceneReadingRecordID = ""
    @SceneStorage("workspace.readingRevisionID")
    private var sceneReadingRevisionID = ""
    @SceneStorage("workspace.readingPageIndex")
    private var sceneReadingPageIndex = -1
    @SceneStorage("library.searchScope")
    private var savedLibrarySearchScope =
        LibrarySearchScope.all.rawValue
    @SceneStorage("library.statusFilter")
    private var savedLibraryStatusFilter = ""
    @SceneStorage("library.categoryFilter")
    private var savedLibraryCategoryFilter = ""
    @SceneStorage("library.smartView")
    private var savedLibrarySmartView = ""

    @State private var path: [DocumentRoute] = []
    @State private var selectedWorkspaceRoute: DocumentRoute?
    @State private var comparisonSession: StudioComparisonSession?
    @State private var splitVisibility =
        NavigationSplitViewVisibility.all
    @State private var splitVisibilityBeforeInspector:
        NavigationSplitViewVisibility?
    @State private var didRestoreSplitVisibility = false
    @SceneStorage("workspace.inspectorPresented")
    private var isInspectorPresented = false
    @State private var noticeDismissTask: Task<Void, Never>?
    @State private var pendingExternalOpenTask: Task<Void, Never>?
    @State private var externalURLTasks:
        [UUID: Task<Void, Never>] = [:]
    @State private var ratingRequestTask: Task<Void, Never>?
    @State private var activeLifecycleTask: Task<Void, Never>?
    @State private var layoutTransitionTask: Task<Void, Never>?
    @State private var navigationTask: Task<Void, Never>?
    @State private var pendingFirstRunDocumentID: UUID?
    @State private var pendingFirstRunImport = false
    @State private var libraryImportRequestID: UUID?
    @State private var isFirstRunPresentationActive = false
    @State private var activeLifecycleGeneration = UUID()
    @State private var navigationGeneration = UUID()
    @State private var pendingExternalOpenGeneration = UUID()
    @State private var noticeDismissGeneration = UUID()
    @State private var ratingRequestGeneration = UUID()
    @State private var pendingGlobalActivation = false
    @State private var protectedDataAvailable =
        UIApplication.shared.isProtectedDataAvailable
    @State private var sceneID = UUID()
    @State private var librarySearchText = ""
    @State private var libraryAppliedSearchText = ""
    @State private var librarySearchHistory: [String] = []
    @State private var librarySearchScope = LibrarySearchScope.all
    @State private var libraryStatusFilter: DocumentWorkflowStatus?
    @State private var libraryCategoryFilter: DocumentCategory?
    @State private var librarySelectedTag: String?
    @State private var librarySelectedSmartView: LibrarySmartView?
    @State private var isSelectingLibraryDocuments = false
    @State private var selectedLibraryDocumentIDs: Set<UUID> = []
    @State private var didRestoreLibraryContext = false
    @State private var didResolveInitialRecordID = false
    @State private var isPDFDropTargeted = false

    init(initialRecordID: UUID? = nil) {
        self.initialRecordID = initialRecordID
    }

    private var navigationWithFeedback: some View {
        ZStack {
            if !appLock.isLocked {
                workspaceNavigation
                    .accessibilityHidden(
                        scenePhase != .active || !protectedDataAvailable
                    )
                    .allowsHitTesting(
                        scenePhase == .active && protectedDataAvailable
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.paperPathSceneID, sceneID)
        .id(appLock.lockGeneration)
        .privacySensitive()
        .dropDestination(for: URL.self) { urls, _ in
            handleDroppedPDFURLs(urls)
        } isTargeted: { isTargeted in
            isPDFDropTargeted =
                isTargeted && canAcceptDroppedPDFs
        }
        .onOpenURL { url in
            receiveExternalURL(url)
        }
        .overlay(alignment: .top) {
            if !appLock.isLocked && scenePhase == .active && protectedDataAvailable {
            VStack(spacing: PPSpacing.small) {
                if model.isExternalPDFImportActive {
                    ExternalImportBanner(
                        progress: model.externalImportProgress,
                        onStop: model.cancelExternalPDFImports
                    )
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
                    .accessibilitySortPriority(2)
                } else if model.externalImportRetryAvailable {
                    NoticeBanner(
                        message: model.externalImportDeferredCount > 0
                            ? AppLocalization.format(
                                "%lld PDFs waiting to import",
                                model.externalImportDeferredCount
                            )
                            : "Import paused",
                        detail: model.externalImportRetryMessage
                            ?? "Pending shared PDFs stay on this device.",
                        kind: .warning,
                        actionTitle: "Retry Import",
                        onAction: {
                            Task {
                                await model.withFeedbackTarget(sceneID) {
                                    await model.processPendingExternalPDFs()
                                }
                            }
                        },
                        onDismiss: model.dismissExternalImportRetry,
                        actionAccessibilityHint:
                            "Retries queued PDFs without duplicating completed imports.",
                        showsFullDetail: true
                    )
                    .accessibilityIdentifier("externalImportRetry")
                    .accessibilitySortPriority(2)
                }

                if pendingExternalOpenTask != nil {
                    ExternalImportHandoffBanner(
                        documentTitle: pendingExternalOpenTitle,
                        onStay: {
                            cancelPendingExternalOpen(
                                clearsPendingDocument: true,
                                showsNotice: true
                            )
                        }
                    )
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
                    .accessibilitySortPriority(3)
                }

                if let notice = sceneActionNotice {
                    NoticeBanner(
                        message: notice.message,
                        detail: notice.detail,
                        kind: notice.kind,
                        actionTitle: notice.action.title,
                        onAction: {
                            Task {
                                await model.performNoticeAction(
                                    notice,
                                    from: sceneID
                                )
                            }
                        },
                        onDismiss: {
                            model.dismissActionNotice(
                                id: notice.id,
                                from: sceneID
                            )
                        }
                    )
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
                    .accessibilitySortPriority(1)
                } else if let notice = sceneTransientNotice {
                    NoticeBanner(
                        message: notice.message,
                        detail: nil,
                        kind: .success,
                        actionTitle: nil,
                        onAction: nil
                    ) {
                        model.dismissTransientNotice(
                            id: notice.id,
                            from: sceneID
                        )
                    }
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
                }
            }
            .padding(.top, PPSpacing.small)
            .padding(.horizontal, PPSpacing.regular)
            .frame(maxWidth: .infinity)
            .zIndex(10)
            }
        }
        .overlay {
            if isPDFDropTargeted && canAcceptDroppedPDFs {
                PDFDropTargetOverlay()
                    .transition(.opacity)
                    .zIndex(90)
            }
            if scenePhase != .active || !protectedDataAvailable {
                PrivacyCover()
                    .zIndex(100)
            } else if appLock.isLocked {
                AppLockView()
                    .zIndex(110)
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88),
            value: sceneTransientNotice?.id
        )
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.42, dampingFraction: 0.88),
            value: sceneActionNotice?.id
        )
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.42, dampingFraction: 0.88),
            value: model.isExternalPDFImportActive
        )
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.42, dampingFraction: 0.88),
            value: pendingExternalOpenTask != nil
        )
        .onChange(of: sceneTransientNotice, initial: true) {
            _, newValue in
            guard let newValue,
                  sceneActionNotice == nil,
                  canPresentTransientFeedback
            else { return }
            if voiceOverEnabled {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: newValue.message.localizedUI
                )
            }
            scheduleMessageDismiss(newValue)
        }
        .onChange(of: sceneActionNotice, initial: true) {
            _, newValue in
            suspendNoticePresentation()
            if let newValue {
                guard canPresentTransientFeedback else { return }
                if voiceOverEnabled {
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: [
                            newValue.message.localizedUI,
                            newValue.detail?.localizedUI
                        ]
                        .compactMap { $0 }
                        .joined(separator: ". ")
                    )
                }
                scheduleActionNoticeDismiss(newValue)
            } else if sceneActionNotice == nil,
                      let notice = sceneTransientNotice,
                      canPresentTransientFeedback {
                if voiceOverEnabled {
                    UIAccessibility.post(
                        notification: .announcement,
                        argument: notice.message.localizedUI
                    )
                }
                scheduleMessageDismiss(notice)
            }
        }
        .onChange(of: voiceOverEnabled) { _, isEnabled in
            suspendNoticePresentation()
            guard !isEnabled,
                  canPresentTransientFeedback
            else { return }
            if let notice = sceneActionNotice {
                scheduleActionNoticeDismiss(notice)
            } else if let notice = sceneTransientNotice {
                scheduleMessageDismiss(notice)
            }
        }
    }

    private var navigationWithLifecycle: some View {
        navigationWithFeedback
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            layoutTransitionTask?.cancel()
            layoutTransitionTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled,
                      horizontalSizeClass == sizeClass
                else { return }
                if sizeClass == .regular {
                    if let route = path.last {
                        let settledRoute =
                            settledWorkspaceRoute(route)
                        isDeskVisible = false
                        selectedWorkspaceRoute = settledRoute
                        path.removeAll()
                        restoreComparisonSessionIfPossible(
                            baseRecordID: settledRoute.recordID
                        )
                    }
                    restoreWorkspaceSplitVisibilityIfNeeded()
                    if !model.isLoading {
                        restoreWorkspaceSelectionIfNeeded()
                    }
                } else if let route = selectedWorkspaceRoute {
                    path = isDeskVisible ? [] : [settledWorkspaceRoute(route)]
                    selectedWorkspaceRoute = nil
                }
                layoutTransitionTask = nil
            }
        }
        .onChange(of: splitVisibility) { _, visibility in
            persistWorkspaceSplitVisibility(visibility)
        }
        .onChange(of: path) { _, routes in
            guard horizontalSizeClass == .compact else { return }
            isDeskVisible = routes.isEmpty
        }
        .onChange(of: libraryRestorableContext) { _, context in
            persistLibraryContextIfNeeded(context)
        }
        .task {
            protectedDataAvailable =
                UIApplication.shared.isProtectedDataAvailable
            restoreLibraryContextIfNeeded()
            restoreWorkspaceSplitVisibilityIfNeeded()
            if scenePhase == .active,
               protectedDataAvailable {
                model.feedbackSceneDidBecomeActive(sceneID)
                let becameGloballyActive =
                    appLock.sceneDidBecomeActive(sceneID)
                if becameGloballyActive {
                    scheduleRatingRequestIfAppropriate()
                }
                scheduleActiveLifecycle(
                    becameGloballyActive: becameGloballyActive
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                protectedDataAvailable =
                    UIApplication.shared.isProtectedDataAvailable
                guard protectedDataAvailable else { return }
                model.feedbackSceneDidBecomeActive(sceneID)
                let becameGloballyActive =
                    appLock.sceneDidBecomeActive(sceneID)
                if becameGloballyActive {
                    scheduleRatingRequestIfAppropriate()
                }
                scheduleActiveLifecycle(
                    becameGloballyActive: becameGloballyActive
                )
                resumePendingRootNavigationIfPossible()
                resumeNoticePresentationIfNeeded()
            case .background:
                librarySearchHistory.removeAll(keepingCapacity: false)
                isPDFDropTargeted = false
                model.feedbackSceneDidResignActive(sceneID)
                suspendNoticePresentation()
                ratingRequestTask?.cancel()
                ratingRequestTask = nil
                cancelPendingExternalOpen()
                if appLock.sceneDidEnterBackground(sceneID) {
                    cancelActiveLifecycle()
                    SecurePasteboard.clearIfOwned()
                    model.releaseTransientResourcesForBackground()
                }
            case .inactive:
                isPDFDropTargeted = false
                model.feedbackSceneDidResignActive(sceneID)
                suspendNoticePresentation()
                suspendActiveLifecycle()
                model.checkpointTrustedTime()
            @unknown default:
                break
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            isPDFDropTargeted = false
            protectedDataAvailable = false
            librarySearchHistory.removeAll(keepingCapacity: false)
            model.feedbackSceneDidResignActive(sceneID)
            suspendNoticePresentation()
            suspendActiveLifecycle()
            cancelPendingExternalOpen()
            ratingRequestTask?.cancel()
            ratingRequestTask = nil
            SecurePasteboard.clearIfOwned()
            appLock.protectedDataWillBecomeUnavailable()
            model.releaseTransientResourcesForBackground()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataDidBecomeAvailableNotification
            )
        ) { _ in
            protectedDataAvailable = true
            guard scenePhase == .active else { return }
            model.feedbackSceneDidBecomeActive(sceneID)
            let becameGloballyActive =
                appLock.sceneDidBecomeActive(sceneID)
            if becameGloballyActive {
                scheduleRatingRequestIfAppropriate()
            } else {
                appLock.didBecomeActive()
            }
            resumePendingRootNavigationIfPossible()
            resumeNoticePresentationIfNeeded()
            scheduleActiveLifecycle(
                becameGloballyActive: becameGloballyActive,
                resumesInterruptedWork: true
            )
        }
        .onDisappear {
            isPDFDropTargeted = false
            layoutTransitionTask?.cancel()
            layoutTransitionTask = nil
            navigationGeneration = UUID()
            navigationTask?.cancel()
            navigationTask = nil
            for task in externalURLTasks.values {
                task.cancel()
            }
            externalURLTasks.removeAll(keepingCapacity: false)
            cancelPendingExternalOpen()
            pendingFirstRunDocumentID = nil
            suspendNoticePresentation()
            ratingRequestTask?.cancel()
            ratingRequestTask = nil
            model.feedbackSceneDidDisconnect(sceneID)
            model.releaseExternalDocumentTarget(for: sceneID)
            model.releaseActionNoticeTarget(for: sceneID)
            model.releaseTransientNoticeTarget(for: sceneID)
            model.releasePresentationErrorTarget(for: sceneID)
            if appLock.sceneDidDisconnect(sceneID) {
                cancelActiveLifecycle()
                model.releaseTransientResourcesForBackground()
            }
        }
        .onChange(
            of: model.externalDocumentHandoffs,
            initial: true
        ) { _, handoffs in
            guard !handoffs.entries.isEmpty else { return }
            resumePendingRootNavigationIfPossible()
        }
        .onChange(of: appLock.isLocked) { _, isLocked in
            if isLocked {
                isPDFDropTargeted = false
                suspendNoticePresentation()
                suspendActiveLifecycle()
                ratingRequestTask?.cancel()
                ratingRequestTask = nil
                return
            }
            guard scenePhase == .active,
                  protectedDataAvailable
            else { return }
            scheduleActiveLifecycle(
                becameGloballyActive: model.isLoading
            )
            scheduleRatingRequestIfAppropriate()
            resumePendingRootNavigationIfPossible()
            resumeNoticePresentationIfNeeded()
        }
    }

    var body: some View {
        navigationWithLifecycle
        .fullScreenCover(
            isPresented: firstRunPresentation,
            onDismiss: completeFirstRunPresentation
        ) {
            FirstRunExperienceView(
                hasExistingDocuments: !model.workingDocuments.isEmpty,
                onImport: {
                    pendingFirstRunImport = true
                    onboardingCompleted = true
                    onboardingReplayRequested = false
                }
            ) {
                let recordID = await model.withFeedbackTarget(sceneID) {
                    await model.createSampleWorkspace()
                }
                if let recordID {
                    pendingFirstRunDocumentID = recordID
                    onboardingCompleted = true
                    onboardingReplayRequested = false
                    return true
                }
                return false
            } onComplete: {
                onboardingCompleted = true
                onboardingReplayRequested = false
            }
            .onAppear {
                isFirstRunPresentationActive = true
            }
        }
        .onChange(of: model.isLoading, initial: true) {
            _, isLoading in
            guard !isLoading else { return }
            restoreWorkspaceSelectionIfNeeded()
            if !onboardingCompleted,
               !onboardingReplayRequested,
               !model.documents.isEmpty {
                onboardingCompleted = true
            }
        }
        .onChange(of: initialRecordID) { _, _ in
            didResolveInitialRecordID = false
            guard !model.isLoading else { return }
            restoreWorkspaceSelectionIfNeeded()
        }
        .onChange(of: model.documents.map(\.id)) { _, recordIDs in
            let validRecordIDs = Set(recordIDs)
            if let savedID = UUID(
                uuidString: lastWorkspaceRecordID
            ),
               !validRecordIDs.contains(savedID) {
                lastWorkspaceRecordID = ""
                lastComparisonPeerID = ""
            }
            if let savedPeerID = UUID(
                uuidString: lastComparisonPeerID
            ),
               !validRecordIDs.contains(savedPeerID) {
                lastComparisonPeerID = ""
            }
            if let readingRecordID = UUID(
                uuidString: sceneReadingRecordID
            ),
               !validRecordIDs.contains(readingRecordID) {
                clearSceneReadingPosition()
            }
            if let selectedWorkspaceRoute,
               !validRecordIDs.contains(
                   selectedWorkspaceRoute.recordID
               ) {
                self.selectedWorkspaceRoute = nil
            }
            if let pendingFirstRunDocumentID,
               !validRecordIDs.contains(pendingFirstRunDocumentID) {
                self.pendingFirstRunDocumentID = nil
            }
            if let pendingExternalDocumentID =
                model.pendingExternalDocumentID(for: sceneID),
               !validRecordIDs.contains(pendingExternalDocumentID) {
                cancelPendingExternalOpen(clearsPendingDocument: true)
            }
            path.removeAll {
                !validRecordIDs.contains($0.recordID)
            }
            if let comparisonSession,
               !validRecordIDs.contains(
                   comparisonSession.baseRecordID
               )
                || !validRecordIDs.contains(
                    comparisonSession.revisedRecordID
                ) {
                self.comparisonSession = nil
                lastComparisonPeerID = ""
            }
            if model.workingDocuments.isEmpty {
                isInspectorPresented = false
                splitVisibilityBeforeInspector = nil
                splitVisibility = .all
                savedSplitVisibility = "all"
            }
            restoreWorkspaceSelectionIfNeeded()
        }
        .onChange(
            of: model.verifiedOutputSuccessCount
        ) { _, _ in
            scheduleRatingRequestIfAppropriate()
        }
        .alert(
            "Couldn’t complete that",
            isPresented: Binding(
                get: {
                    model.presentationError(for: sceneID) != nil
                },
                set: {
                    if !$0 {
                        model.clearError(from: sceneID)
                    }
                }
            )
        ) {
            if model.presentationError(for: sceneID)?
                .offersSettings == true {
                Button("Open Settings") {
                    if let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) {
                        UIApplication.shared.open(url)
                    }
                    model.clearError(from: sceneID)
                }
            }
            Button(
                (
                    model.presentationError(for: sceneID)?
                        .offersSettings == true
                        ? "Not Now"
                        : "OK"
                ).localizedUI,
                role: .cancel
            ) {
                model.clearError(from: sceneID)
            }
        } message: {
            Text(
                (
                    model.presentationError(for: sceneID)?.message
                        ?? ""
                ).localizedUI
            )
        }
    }

    private var firstRunPresentation: Binding<Bool> {
        Binding(
            get: {
                guard (!isRunningAutomatedTests || onboardingReplayRequested),
                      !model.isLoading
                else { return false }
                return onboardingReplayRequested
                    || (!onboardingCompleted
                        && model.documents.isEmpty)
            },
            set: { isPresented in
                guard !isPresented else { return }
                onboardingCompleted = true
                onboardingReplayRequested = false
            }
        )
    }

    private func completeFirstRunPresentation() {
        isFirstRunPresentationActive = false
        resumePendingRootNavigationIfPossible()
    }

    private var pendingExternalOpenTitle: String? {
        guard let recordID = model.pendingExternalDocumentID(
            for: sceneID
        ) else {
            return nil
        }
        return model.record(id: recordID)?.displayName
    }

    private func resumePendingRootNavigationIfPossible() {
        guard scenePhase == .active,
              protectedDataAvailable,
              !appLock.isLocked,
              !firstRunPresentation.wrappedValue,
              !isFirstRunPresentationActive
        else { return }
        if pendingFirstRunImport {
            pendingFirstRunImport = false
            path.removeAll()
            selectedWorkspaceRoute = nil
            isDeskVisible = true
            isSelectingLibraryDocuments = false
            libraryImportRequestID = UUID()
            return
        }
        if let recordID = pendingFirstRunDocumentID {
            guard model.record(id: recordID) != nil else {
                pendingFirstRunDocumentID = nil
                return
            }
            pendingFirstRunDocumentID = nil
            open(DocumentRoute(recordID: recordID))
            return
        }
        guard let recordID = model.pendingExternalDocumentID(
                for: sceneID
              ),
              model.record(id: recordID) != nil
        else { return }
        let generation = UUID()
        pendingExternalOpenGeneration = generation
        pendingExternalOpenTask?.cancel()
        pendingExternalOpenTask = Task { @MainActor in
            defer {
                if pendingExternalOpenGeneration == generation {
                    pendingExternalOpenTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  pendingExternalOpenGeneration == generation,
                  scenePhase == .active,
                  protectedDataAvailable,
                  !appLock.isLocked,
                  !firstRunPresentation.wrappedValue,
                  !isFirstRunPresentationActive,
                  model.pendingExternalDocumentID(
                    for: sceneID
                  ) == recordID,
                  model.record(id: recordID) != nil
            else { return }
            open(DocumentRoute(recordID: recordID))
            model.clearPendingExternalDocument(recordID)
        }
    }

    private var isRunningAutomatedTests: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains {
            $0.hasPrefix("UITEST_")
        }
            || ProcessInfo.processInfo.environment[
                "XCTestConfigurationFilePath"
            ] != nil
#else
        false
#endif
    }

    private func open(
        _ route: DocumentRoute,
        preservingComparisonState: Bool = false
    ) {
        guard let record = model.record(id: route.recordID) else {
            return
        }
        let initialResolvedRoute = resolvedRoute(route, for: record)
        lastWorkspaceRecordID =
            initialResolvedRoute.recordID.uuidString
        if let pageIndex = initialResolvedRoute.pageIndex {
            persistSceneReadingPosition(
                recordID: initialResolvedRoute.recordID,
                pageIndex: pageIndex,
                contentRevisionID: record.contentRevisionID
            )
        }
        if !preservingComparisonState {
            comparisonSession = nil
            lastComparisonPeerID = ""
        }
        navigationGeneration = UUID()
        navigationTask?.cancel()
        navigationTask = nil
        if horizontalSizeClass == .regular {
            let wasShowingDesk = isDeskVisible
            isDeskVisible = false
            if selectedWorkspaceRoute == initialResolvedRoute {
                if !wasShowingDesk {
                    isInspectorPresented = true
                }
                return
            }
            selectedWorkspaceRoute = initialResolvedRoute
            return
        }

        guard path.last != initialResolvedRoute else { return }
        let generation = UUID()
        navigationGeneration = generation
        navigationTask = Task { @MainActor in
            defer {
                if navigationGeneration == generation {
                    navigationTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  navigationGeneration == generation,
                  let currentRecord =
                    model.record(id: initialResolvedRoute.recordID)
            else {
                return
            }
            let finalRoute = resolvedRoute(
                initialResolvedRoute,
                for: currentRecord
            )
            if horizontalSizeClass == .regular {
                isDeskVisible = false
                selectedWorkspaceRoute = finalRoute
                path.removeAll()
                if preservingComparisonState {
                    restoreComparisonSessionIfPossible(
                        baseRecordID: finalRoute.recordID
                    )
                }
                return
            }
            guard navigationGeneration == generation,
                  path.last != finalRoute
            else { return }
            isDeskVisible = false
            path.append(finalRoute)
        }
    }

    private func resolvedRoute(
        _ route: DocumentRoute,
        for record: DocumentRecord
    ) -> DocumentRoute {
        if let expectedRevisionID =
            route.expectedContentRevisionID,
           expectedRevisionID != record.contentRevisionID {
            model.presentNotice(
                "Continue point refreshed for the updated PDF"
                    .localizedUI,
                in: sceneID
            )
            if let checkpoint = record.taskCheckpoint,
               checkpoint.contentRevisionID
                == record.contentRevisionID {
                return DocumentRoute(
                    recordID: record.id,
                    pageIndex: checkpoint.pageIndex,
                    quickTask: checkpoint.stage.quickTask,
                    expectedContentRevisionID:
                        record.contentRevisionID,
                    invocationID: route.invocationID
                )
            }
            return DocumentRoute(
                recordID: record.id,
                pageIndex: record.lastPageIndex
            )
        }
        let resolvedPageIndex = route.pageIndex.map {
            min(max(0, $0), max(0, record.profile.pageCount - 1))
        }
        return DocumentRoute(
            recordID: route.recordID,
            pageIndex: resolvedPageIndex,
            quickTask: route.quickTask,
            expectedContentRevisionID:
                route.expectedContentRevisionID,
            invocationID: route.invocationID
        )
    }

    @ViewBuilder
    private var workspaceNavigation: some View {
        if horizontalSizeClass == .regular,
           isDeskVisible || selectedWorkspaceRoute == nil {
            NavigationStack {
                LibraryView(
                    requestedPDFImport: $libraryImportRequestID,
                    searchText: $librarySearchText,
                    appliedSearchText: $libraryAppliedSearchText,
                    searchHistory: $librarySearchHistory,
                    searchScope: $librarySearchScope,
                    statusFilter: $libraryStatusFilter,
                    categoryFilter: $libraryCategoryFilter,
                    selectedTag: $librarySelectedTag,
                    selectedSmartView: $librarySelectedSmartView,
                    isSelectingDocuments: $isSelectingLibraryDocuments,
                    selectedDocumentIDs: $selectedLibraryDocumentIDs
                ) { route in
                    open(route)
                }
            }
        } else if horizontalSizeClass == .regular {
            NavigationSplitView(
                columnVisibility: $splitVisibility
            ) {
                LibraryView(
                    requestedPDFImport: $libraryImportRequestID,
                    selectedRecordID:
                        selectedWorkspaceRoute?.recordID,
                    isWorkspaceSidebar:
                        selectedWorkspaceRoute != nil,
                    searchText: $librarySearchText,
                    appliedSearchText: $libraryAppliedSearchText,
                    searchHistory: $librarySearchHistory,
                    searchScope: $librarySearchScope,
                    statusFilter: $libraryStatusFilter,
                    categoryFilter: $libraryCategoryFilter,
                    selectedTag: $librarySelectedTag,
                    selectedSmartView: $librarySelectedSmartView,
                    isSelectingDocuments:
                        $isSelectingLibraryDocuments,
                    selectedDocumentIDs:
                        $selectedLibraryDocumentIDs
                ) { route in
                    open(route)
                }
                .navigationSplitViewColumnWidth(
                    min: dynamicTypeSize.ppPrefersExpandedLayout
                        ? 340
                        : 260,
                    ideal: dynamicTypeSize.ppPrefersExpandedLayout
                        ? 400
                        : 280,
                    max: dynamicTypeSize.ppPrefersExpandedLayout
                        ? 480
                        : 320
                )
            } detail: {
                if let route = selectedWorkspaceRoute,
                   model.record(id: route.recordID) != nil {
                    Group {
                        if let comparisonSession,
                           comparisonSession.baseRecordID
                            == route.recordID {
                            StudioComparisonWorkspace(
                                session: comparisonSession,
                                onSwap: swapComparisonDocuments,
                                onClose: closeComparison
                            )
                        } else {
                            DocumentWorkspaceView(
                                recordID: route.recordID,
                                initialPageIndex: route.pageIndex,
                                initialQuickTask: route.quickTask,
                                initialContentRevisionID:
                                    route.expectedContentRevisionID,
                                onReadingPositionChange: {
                                    pageIndex,
                                    contentRevisionID in
                                    persistSceneReadingPosition(
                                        recordID: route.recordID,
                                        pageIndex: pageIndex,
                                        contentRevisionID:
                                            contentRevisionID
                                    )
                                }
                            ) { createdRoute in
                                open(createdRoute)
                            }
                            .id(route)
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button {
                                returnToDesk()
                            } label: {
                                Label("Document Desk".localizedUI, systemImage: "square.grid.2x2")
                            }
                            .keyboardShortcut("h", modifiers: [.command, .shift])
                            .help("Document Desk".localizedUI)
                            .accessibilityIdentifier("returnToDocumentDesk")
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                isInspectorPresented.toggle()
                            } label: {
                                HStack(spacing: PPSpacing.xSmall) {
                                    Image(systemName: "sidebar.right")
                                    Text("Tools".localizedUI)
                                        .font(.subheadline.weight(.semibold))
                                }
                                .fixedSize(horizontal: true, vertical: false)
                            }
                            .keyboardShortcut(
                                "i",
                                modifiers: [.command, .option]
                            )
                            .accessibilityLabel(
                                (
                                    isInspectorPresented
                                        ? "Hide Inspector"
                                        : "Show Inspector"
                                ).localizedUI
                            )
                            .accessibilityValue(
                                (
                                    isInspectorPresented
                                        ? "Shown"
                                        : "Hidden"
                                ).localizedUI
                            )
                            .accessibilityHint(
                                (
                                    isInspectorPresented
                                        ? "Hides document evidence and restores the previous library layout."
                                        : "Shows document evidence beside the PDF and temporarily hides the library."
                                ).localizedUI
                            )
                            .accessibilityIdentifier(
                                "workspaceInspectorToggle"
                            )
                            .help(
                                (
                                    isInspectorPresented
                                        ? "Hide Inspector"
                                        : "Show Inspector"
                                ).localizedUI
                            )
                        }
                    }
                    .inspector(
                        isPresented: $isInspectorPresented
                    ) {
                        StudioDocumentInspector(
                            recordID: route.recordID
                        ) { nextRoute in
                            isInspectorPresented = false
                            open(nextRoute)
                        } onCompare: { revisedRecordID in
                            beginComparison(
                                baseRecordID: route.recordID,
                                revisedRecordID: revisedRecordID
                            )
                        }
                        .inspectorColumnWidth(
                            min: dynamicTypeSize.ppPrefersExpandedLayout
                                ? 300
                                : 260,
                            ideal: dynamicTypeSize.ppPrefersExpandedLayout
                                ? 360
                                : 300,
                            max: dynamicTypeSize.ppPrefersExpandedLayout
                                ? 420
                                : 360
                        )
                    }
                } else {
                    StudioWorkspacePlaceholder()
                }
            }
            .navigationSplitViewStyle(.balanced)
            .onChange(
                of: isInspectorPresented,
                initial: true
            ) { _, isPresented in
                synchronizeWorkspaceColumnsForInspector(
                    isPresented
                )
            }
        } else {
            NavigationStack(path: $path) {
                LibraryView(
                    requestedPDFImport: $libraryImportRequestID,
                    searchText: $librarySearchText,
                    appliedSearchText: $libraryAppliedSearchText,
                    searchHistory: $librarySearchHistory,
                    searchScope: $librarySearchScope,
                    statusFilter: $libraryStatusFilter,
                    categoryFilter: $libraryCategoryFilter,
                    selectedTag: $librarySelectedTag,
                    selectedSmartView: $librarySelectedSmartView,
                    isSelectingDocuments:
                        $isSelectingLibraryDocuments,
                    selectedDocumentIDs:
                        $selectedLibraryDocumentIDs
                ) { route in
                    open(route)
                }
                .navigationDestination(for: DocumentRoute.self) { route in
                    DocumentWorkspaceView(
                        recordID: route.recordID,
                        initialPageIndex: route.pageIndex,
                        initialQuickTask: route.quickTask,
                        initialContentRevisionID:
                            route.expectedContentRevisionID,
                        onReadingPositionChange: {
                            pageIndex,
                            contentRevisionID in
                            persistSceneReadingPosition(
                                recordID: route.recordID,
                                pageIndex: pageIndex,
                                contentRevisionID:
                                    contentRevisionID
                            )
                        }
                    ) { createdRoute in
                        open(createdRoute)
                    }
                }
            }
        }
    }

    private func returnToDesk() {
        navigationGeneration = UUID()
        navigationTask?.cancel()
        navigationTask = nil
        isInspectorPresented = false
        synchronizeWorkspaceColumnsForInspector(false)
        isSelectingLibraryDocuments = false
        selectedLibraryDocumentIDs = []
        isDeskVisible = true
    }

    private func synchronizeWorkspaceColumnsForInspector(
        _ isPresented: Bool
    ) {
        guard horizontalSizeClass == .regular else { return }
        restoreWorkspaceSplitVisibilityIfNeeded()
        if isPresented {
            guard splitVisibilityBeforeInspector == nil else {
                return
            }
            splitVisibilityBeforeInspector = splitVisibility
            splitVisibility = .detailOnly
        } else if let previousVisibility =
                    splitVisibilityBeforeInspector {
            splitVisibility = previousVisibility
            splitVisibilityBeforeInspector = nil
        }
    }

    private func restoreWorkspaceSelectionIfNeeded() {
        if !didResolveInitialRecordID {
            didResolveInitialRecordID = true
            if let initialRecordID,
               savedInitialRecordID != initialRecordID.uuidString,
               let record = model.record(id: initialRecordID) {
                savedInitialRecordID = initialRecordID.uuidString
                open(
                    DocumentRoute(
                        recordID: initialRecordID,
                        pageIndex:
                            restoredSceneReadingPageIndex(for: record)
                                ?? record.lastPageIndex,
                        expectedContentRevisionID:
                            record.contentRevisionID
                    )
                )
                return
            }
        }

        let isRegularWorkspace = horizontalSizeClass == .regular
        let canRestoreCompactPadWorkspace =
            UIDevice.current.userInterfaceIdiom == .pad
                && !isRegularWorkspace
                && path.isEmpty
                && !isDeskVisible
        guard (isRegularWorkspace && selectedWorkspaceRoute == nil)
                || canRestoreCompactPadWorkspace
        else { return }

        if let recordID = UUID(uuidString: lastWorkspaceRecordID),
           let record = model.record(id: recordID) {
            let route = DocumentRoute(
                recordID: recordID,
                pageIndex:
                    restoredSceneReadingPageIndex(for: record)
                        ?? record.lastPageIndex,
                expectedContentRevisionID:
                    record.contentRevisionID
            )
            if isRegularWorkspace {
                selectedWorkspaceRoute = route
                restoreComparisonSessionIfPossible(
                    baseRecordID: recordID
                )
            } else {
                open(
                    route,
                    preservingComparisonState: true
                )
            }
            return
        }

        guard isRegularWorkspace else { return }
        guard let record = preferredInitialWorkspaceRecord else {
            return
        }
        comparisonSession = nil
        lastComparisonPeerID = ""
        lastWorkspaceRecordID = record.id.uuidString
        selectedWorkspaceRoute = DocumentRoute(
            recordID: record.id,
            pageIndex:
                restoredSceneReadingPageIndex(for: record)
                    ?? record.lastPageIndex,
            expectedContentRevisionID:
                record.contentRevisionID
        )
    }

    private func settledWorkspaceRoute(
        _ route: DocumentRoute
    ) -> DocumentRoute {
        guard let record = model.record(id: route.recordID) else {
            return route
        }
        let pageIndex =
            restoredSceneReadingPageIndex(for: record)
                ?? route.pageIndex
                ?? record.lastPageIndex
        return DocumentRoute(
            recordID: record.id,
            pageIndex: min(
                max(0, pageIndex),
                max(0, record.profile.pageCount - 1)
            ),
            expectedContentRevisionID: record.contentRevisionID
        )
    }

    private func restoredSceneReadingPageIndex(
        for record: DocumentRecord
    ) -> Int? {
        guard sceneReadingRecordID == record.id.uuidString else {
            return nil
        }
        guard sceneReadingRevisionID
                == record.contentRevisionID.uuidString,
              sceneReadingPageIndex >= 0,
              record.profile.pageCount > 0
        else {
            clearSceneReadingPosition()
            return nil
        }
        return min(
            sceneReadingPageIndex,
            record.profile.pageCount - 1
        )
    }

    private func persistSceneReadingPosition(
        recordID: UUID,
        pageIndex: Int,
        contentRevisionID: UUID
    ) {
        guard lastWorkspaceRecordID == recordID.uuidString,
              let record = model.record(id: recordID),
              record.contentRevisionID == contentRevisionID,
              record.profile.pageCount > 0
        else { return }
        sceneReadingRecordID = recordID.uuidString
        sceneReadingRevisionID = contentRevisionID.uuidString
        sceneReadingPageIndex = min(
            max(0, pageIndex),
            record.profile.pageCount - 1
        )
    }

    private func clearSceneReadingPosition() {
        sceneReadingRecordID = ""
        sceneReadingRevisionID = ""
        sceneReadingPageIndex = -1
    }

    private func restoreLibraryContextIfNeeded() {
        guard !didRestoreLibraryContext else { return }
        didRestoreLibraryContext = true
        librarySearchScope =
            LibrarySearchScope(rawValue: savedLibrarySearchScope)
                ?? .all
        libraryStatusFilter = DocumentWorkflowStatus(
            rawValue: savedLibraryStatusFilter
        )
        libraryCategoryFilter = DocumentCategory(
            rawValue: savedLibraryCategoryFilter
        )
        librarySelectedSmartView = LibrarySmartView(
            rawValue: savedLibrarySmartView
        )
        if librarySelectedSmartView != nil {
            libraryStatusFilter = nil
            libraryCategoryFilter = nil
            savedLibraryStatusFilter = ""
            savedLibraryCategoryFilter = ""
        }
    }

    private var libraryRestorableContext:
        LibraryRestorableContext {
        LibraryRestorableContext(
            searchScope: librarySearchScope,
            statusFilter: libraryStatusFilter,
            categoryFilter: libraryCategoryFilter,
            smartView: librarySelectedSmartView
        )
    }

    private func persistLibraryContextIfNeeded(
        _ context: LibraryRestorableContext
    ) {
        guard didRestoreLibraryContext else { return }
        savedLibrarySearchScope = context.searchScope.rawValue
        savedLibraryStatusFilter =
            context.statusFilter?.rawValue ?? ""
        savedLibraryCategoryFilter =
            context.categoryFilter?.rawValue ?? ""
        savedLibrarySmartView = context.smartView?.rawValue ?? ""
    }

    private func restoreComparisonSessionIfPossible(
        baseRecordID: UUID
    ) {
        guard let base = model.record(id: baseRecordID),
              let revisedRecordID = UUID(
                uuidString: lastComparisonPeerID
              ),
              revisedRecordID != baseRecordID,
              let revised = model.record(id: revisedRecordID),
              !base.profile.isLocked,
              !revised.profile.isLocked
        else {
            comparisonSession = nil
            lastComparisonPeerID = ""
            return
        }
        comparisonSession = StudioComparisonSession(
            baseRecordID: baseRecordID,
            revisedRecordID: revisedRecordID
        )
    }

    private func restoreWorkspaceSplitVisibilityIfNeeded() {
        guard UIDevice.current.userInterfaceIdiom == .pad,
              horizontalSizeClass == .regular,
              !didRestoreSplitVisibility
        else { return }
        didRestoreSplitVisibility = true
        let restored: NavigationSplitViewVisibility =
            savedSplitVisibility == "detailOnly"
                ? .detailOnly
                : .all
        if isInspectorPresented {
            splitVisibilityBeforeInspector = restored
            splitVisibility = .detailOnly
        } else {
            splitVisibility = restored
        }
    }

    private func persistWorkspaceSplitVisibility(
        _ visibility: NavigationSplitViewVisibility
    ) {
        guard didRestoreSplitVisibility,
              horizontalSizeClass == .regular,
              !isInspectorPresented,
              splitVisibilityBeforeInspector == nil
        else { return }
        savedSplitVisibility = visibility == .detailOnly
            ? "detailOnly"
            : "all"
    }

    private var canAcceptDroppedPDFs: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && scenePhase == .active
            && protectedDataAvailable
            && !appLock.isLocked
            && !model.isLoading
            && !isFirstRunPresentationActive
    }

    private func handleDroppedPDFURLs(_ urls: [URL]) -> Bool {
        isPDFDropTargeted = false
        guard canAcceptDroppedPDFs,
              !urls.isEmpty,
              urls.allSatisfy({
                  $0.isFileURL
                      && $0.pathExtension.caseInsensitiveCompare("pdf")
                          == .orderedSame
              })
        else {
            if canAcceptDroppedPDFs, !urls.isEmpty {
                model.present(
                    ExternalPDFInboxError.invalidPDF,
                    in: sceneID
                )
            }
            return false
        }

        var seenPaths = Set<String>()
        let uniqueURLs = urls.filter {
            seenPaths.insert($0.standardizedFileURL.path).inserted
        }
        guard !uniqueURLs.isEmpty else { return false }
        let taskID = UUID()
        let targetSceneID = sceneID
        externalURLTasks[taskID] = Task { @MainActor in
            defer {
                externalURLTasks[taskID] = nil
            }
            guard !Task.isCancelled else { return }
            await model.receiveExternalURLs(
                uniqueURLs,
                targetSceneID: targetSceneID
            )
        }
        return true
    }

    private var preferredInitialWorkspaceRecord: DocumentRecord? {
        let startOfToday = Calendar.current.startOfDay(for: Date())
        return model.workingDocuments.max { lhs, rhs in
            let lhsPriority = initialWorkspacePriority(
                lhs,
                startOfToday: startOfToday
            )
            let rhsPriority = initialWorkspacePriority(
                rhs,
                startOfToday: startOfToday
            )
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            let lhsActivity =
                lhs.lastViewedAt ?? lhs.modifiedAt
            let rhsActivity =
                rhs.lastViewedAt ?? rhs.modifiedAt
            if lhsActivity != rhsActivity {
                return lhsActivity < rhsActivity
            }
            return lhs.id.uuidString > rhs.id.uuidString
        }
    }

    private func initialWorkspacePriority(
        _ record: DocumentRecord,
        startOfToday: Date
    ) -> Int {
        if record.deliveryReceipt != nil,
           !record.hasCurrentDeliveryReceipt {
            return 50
        }
        if record.profile.isLocked {
            return 45
        }
        if record.taskCheckpoint != nil {
            return 40
        }
        if let dueAt = record.dueAt {
            return dueAt < startOfToday ? 35 : 30
        }
        if model.taskPackageRecommendation(for: record).map({
            $0.task != .safeShare
        }) ?? false {
            return 25
        }
        if model.needsAttention(record) {
            return 20
        }
        if record.lastViewedAt != nil && record.lastPageIndex > 0 {
            return 15
        }
        return 10
    }

    private func beginComparison(
        baseRecordID: UUID,
        revisedRecordID: UUID
    ) {
        guard baseRecordID != revisedRecordID,
              model.record(id: baseRecordID) != nil,
              model.record(id: revisedRecordID) != nil
        else { return }
        lastComparisonPeerID = revisedRecordID.uuidString
        comparisonSession = StudioComparisonSession(
            baseRecordID: baseRecordID,
            revisedRecordID: revisedRecordID
        )
        isInspectorPresented = true
    }

    private func swapComparisonDocuments() {
        guard let comparisonSession else { return }
        let swapped = StudioComparisonSession(
            baseRecordID: comparisonSession.revisedRecordID,
            revisedRecordID: comparisonSession.baseRecordID
        )
        selectedWorkspaceRoute = DocumentRoute(
            recordID: swapped.baseRecordID,
            pageIndex: model.record(id: swapped.baseRecordID)?
                .lastPageIndex
        )
        lastWorkspaceRecordID = swapped.baseRecordID.uuidString
        lastComparisonPeerID = swapped.revisedRecordID.uuidString
        self.comparisonSession = swapped
    }

    private func closeComparison() {
        if let selectedWorkspaceRoute {
            self.selectedWorkspaceRoute =
                settledWorkspaceRoute(selectedWorkspaceRoute)
        }
        comparisonSession = nil
        lastComparisonPeerID = ""
    }

    private func receiveExternalURL(_ url: URL) {
        let taskID = UUID()
        let targetSceneID = sceneID
        externalURLTasks[taskID] = Task { @MainActor in
            defer {
                externalURLTasks[taskID] = nil
            }
            guard !Task.isCancelled else { return }
            await model.receiveExternalURL(
                url,
                targetSceneID: targetSceneID
            )
        }
    }

    private func scheduleActiveLifecycle(
        becameGloballyActive: Bool,
        resumesInterruptedWork: Bool = false
    ) {
        pendingGlobalActivation =
            pendingGlobalActivation || becameGloballyActive
        guard !AppLockLifecyclePolicy.preservesAuthenticationTask(
            isAuthenticating: appLock.isAuthenticating
        ) else { return }
        activeLifecycleTask?.cancel()
        let generation = UUID()
        activeLifecycleGeneration = generation
        activeLifecycleTask = Task { @MainActor in
            defer {
                if activeLifecycleGeneration == generation {
                    activeLifecycleTask = nil
                }
            }
            if AppLockLifecyclePolicy.shouldAttemptAutomaticUnlock(
                becameGloballyActive: becameGloballyActive,
                isLocked: appLock.isLocked,
                isAuthenticating: appLock.isAuthenticating
            ) {
                _ = await appLock.unlock()
            }
            guard !Task.isCancelled,
                  activeLifecycleGeneration == generation,
                  canRunActiveLifecycle
            else { return }
            if resumesInterruptedWork {
                await model.restoreCommittedImportsForForeground()
                guard !Task.isCancelled,
                      activeLifecycleGeneration == generation,
                      canRunActiveLifecycle
                else { return }
                await model.processPendingExternalPDFs()
                guard !Task.isCancelled,
                      activeLifecycleGeneration == generation,
                      canRunActiveLifecycle
                else { return }
                await model.restoreCommittedImportsForForeground()
                guard !Task.isCancelled,
                      activeLifecycleGeneration == generation,
                      canRunActiveLifecycle
                else { return }
                model.resumeDeferredBackgroundWork()
                resumePendingRootNavigationIfPossible()
            } else {
                resumePendingRootNavigationIfPossible()
            }
            guard pendingGlobalActivation else { return }
            await model.bootstrap()
            guard !Task.isCancelled,
                  activeLifecycleGeneration == generation,
                  canRunActiveLifecycle
            else { return }
            pendingGlobalActivation = false
#if DEBUG
            await runDeviceGoldenPathIfRequested()
#endif
        }
    }

    private var canRunActiveLifecycle: Bool {
        scenePhase == .active
            && protectedDataAvailable
            && !appLock.isLocked
            && appLock.hasActiveScenes
    }

    private func suspendActiveLifecycle() {
        pendingGlobalActivation =
            pendingGlobalActivation || model.isLoading
        guard !AppLockLifecyclePolicy.preservesAuthenticationTask(
            isAuthenticating: appLock.isAuthenticating
        ) else { return }
        activeLifecycleGeneration = UUID()
        activeLifecycleTask?.cancel()
        activeLifecycleTask = nil
    }

    private func cancelActiveLifecycle() {
        activeLifecycleGeneration = UUID()
        pendingGlobalActivation = false
        activeLifecycleTask?.cancel()
        activeLifecycleTask = nil
    }

    private func cancelPendingExternalOpen(
        clearsPendingDocument: Bool = false,
        showsNotice: Bool = false
    ) {
        pendingExternalOpenGeneration = UUID()
        pendingExternalOpenTask?.cancel()
        pendingExternalOpenTask = nil
        guard clearsPendingDocument,
              let recordID = model.pendingExternalDocumentID(
                for: sceneID
              )
        else { return }
        model.clearPendingExternalDocument(recordID)
        if showsNotice {
            model.presentNotice(
                "Private copy stayed in Library".localizedUI,
                in: sceneID
            )
        }
    }

#if DEBUG
    private func runDeviceGoldenPathIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("UITEST_POLISH_OCR") {
            guard !model.documents.contains(where: { $0.displayName == "Polish scan" }) else { return }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try LocalFileSecurity.prepareProtectedDirectory(at: directory)
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("Polish scan.pdf")
                let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                format.opaque = true
                let pages = [
                    "Delivery 4827\n\nReview the signed documents.\nKeep processing on this device.",
                    "Invoice 2048\n\nAmount due USD 1280.\nCheck the date before sharing."
                ]
                try UIGraphicsPDFRenderer(bounds: bounds).writePDF(to: url) { context in
                    for text in pages {
                        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { canvas in
                            UIColor.white.setFill()
                            canvas.fill(bounds)
                            (text as NSString).draw(
                                in: bounds.insetBy(dx: 48, dy: 64),
                                withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black]
                            )
                        }
                        context.beginPage()
                        image.draw(in: bounds)
                    }
                }
                _ = await model.importPDF(from: url)
            } catch {
                model.present(error, in: sceneID)
            }
            return
        }
        if arguments.contains("DEVICE_OFFICE_CORPUS"),
           let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
           ).first {
            await DeviceOfficeCorpusDiagnostics.run(
                root: documents.appendingPathComponent("OfficeCorpus")
            )
            return
        }
        if arguments.contains("DEBUG_OPEN_OFFICE_EXPORT"),
           let record = model.documents.first {
            open(
                DocumentRoute(
                    recordID: record.id,
                    quickTask: .exportText
                )
            )
            return
        }
        guard arguments.contains("DEVICE_GOLDEN_PATH"),
        let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first
        else { return }
        let reportURL = documents.appendingPathComponent(
            "PaperPath-device-golden-path.json"
        )
        await Task.detached(priority: .userInitiated) {
            await DeviceGoldenPathDiagnostics.run(
                reportURL: reportURL
            )
        }.value
    }
#endif

    private var sceneActionNotice: AppActionNotice? {
        model.actionNotice(for: sceneID)
    }

    private var sceneTransientNotice: AppTransientNotice? {
        model.transientNotice(for: sceneID)
    }

    private var canPresentTransientFeedback: Bool {
        scenePhase == .active
            && protectedDataAvailable
            && !appLock.isLocked
    }

    private func suspendNoticePresentation() {
        noticeDismissGeneration = UUID()
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
    }

    private func resumeNoticePresentationIfNeeded() {
        guard canPresentTransientFeedback else { return }
        if let notice = sceneActionNotice {
            if voiceOverEnabled {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: [
                        notice.message.localizedUI,
                        notice.detail?.localizedUI
                    ]
                    .compactMap { $0 }
                    .joined(separator: ". ")
                )
            }
            scheduleActionNoticeDismiss(notice)
        } else if sceneActionNotice == nil,
                  let notice = sceneTransientNotice {
            if voiceOverEnabled {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: notice.message.localizedUI
                )
            }
            scheduleMessageDismiss(notice)
        }
    }

    private func scheduleMessageDismiss(
        _ notice: AppTransientNotice
    ) {
        suspendNoticePresentation()
        guard !voiceOverEnabled,
              canPresentTransientFeedback
        else { return }
        let generation = UUID()
        noticeDismissGeneration = generation
        noticeDismissTask = Task { @MainActor in
            defer {
                if noticeDismissGeneration == generation {
                    noticeDismissTask = nil
                }
            }
            let visibleSeconds = min(
                6,
                max(2.8, Double(notice.message.count) * 0.055)
            )
            try? await Task.sleep(
                for: .seconds(visibleSeconds)
            )
            if !Task.isCancelled,
               noticeDismissGeneration == generation,
               canPresentTransientFeedback,
               sceneTransientNotice?.id == notice.id,
               sceneActionNotice == nil {
                model.dismissTransientNotice(
                    id: notice.id,
                    from: sceneID
                )
            }
        }
    }

    private func scheduleActionNoticeDismiss(
        _ notice: AppActionNotice
    ) {
        suspendNoticePresentation()
        guard !voiceOverEnabled,
              canPresentTransientFeedback,
              sceneActionNotice?.id == notice.id
        else { return }
        let generation = UUID()
        noticeDismissGeneration = generation
        noticeDismissTask = Task { @MainActor in
            defer {
                if noticeDismissGeneration == generation {
                    noticeDismissTask = nil
                }
            }
            let readingLength = notice.message.count
                + (notice.detail?.count ?? 0)
                + notice.action.title.count
            let visibleSeconds = min(
                15,
                max(9, Double(readingLength) * 0.06)
            )
            try? await Task.sleep(
                for: .seconds(visibleSeconds)
            )
            if !Task.isCancelled,
               noticeDismissGeneration == generation,
               canPresentTransientFeedback,
               sceneActionNotice?.id == notice.id {
                model.dismissActionNotice(
                    id: notice.id,
                    from: sceneID
                )
            }
        }
    }

    private func scheduleRatingRequestIfAppropriate() {
        ratingRequestTask?.cancel()
        ratingRequestTask = nil
        guard !isRunningAutomatedTests,
              AppUsageHistory.shouldRequestRating
        else { return }
        let generation = UUID()
        ratingRequestGeneration = generation
        ratingRequestTask = Task { @MainActor in
            defer {
                if ratingRequestGeneration == generation {
                    ratingRequestTask = nil
                }
            }
            try? await Task.sleep(for: .seconds(7))
            guard !Task.isCancelled,
                  ratingRequestGeneration == generation,
                  scenePhase == .active,
                  !appLock.isLocked,
                  !model.hasActiveLocalDataOperations,
                  sceneTransientNotice == nil,
                  sceneActionNotice == nil,
                  AppUsageHistory.shouldRequestRating
            else { return }
            requestReview()
            AppUsageHistory.markRatingRequested()
        }
    }
}

private struct StudioComparisonSession: Equatable {
    let baseRecordID: UUID
    let revisedRecordID: UUID
}

private enum StudioInspectorAction:
    String,
    CaseIterable,
    Identifiable {
    case continueReading
    case organize
    case compare
    case versions
    case verify
    case recognize
    case fillForms
    case sign
    case redact
    case compress
    case protect
    case exportOffice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .continueReading: return "Continue reading"
        case .organize: return "Organize pages"
        case .compare: return "Compare versions"
        case .versions: return "Version history"
        case .verify: return "Verify & Share"
        case .recognize: return "Recognize text"
        case .fillForms: return "Fill forms"
        case .sign: return "Sign PDF"
        case .redact: return "Redact content"
        case .compress: return "Compress copy"
        case .protect: return "Protect copy"
        case .exportOffice: return "Export Office"
        }
    }

    var detail: String {
        switch self {
        case .continueReading:
            return "Return to the last viewed page"
        case .organize:
            return "Reorder, replace, crop, or extract"
        case .compare:
            return "Open a persistent side-by-side proof"
        case .versions:
            return "Review protected revisions before restoring"
        case .verify:
            return "Reopen and check a final copy"
        case .recognize:
            return "Index scanned text on device"
        case .fillForms:
            return "Review incomplete interactive fields"
        case .sign:
            return "Place a saved or new signature"
        case .redact:
            return "Remove selected content permanently"
        case .compress:
            return "Create a smaller delivery copy"
        case .protect:
            return "Create a password-protected copy"
        case .exportOffice:
            return "Rebuild Word, Excel, or PowerPoint"
        }
    }

    var symbol: String {
        switch self {
        case .continueReading: return "book.pages"
        case .organize: return "square.grid.2x2"
        case .compare: return "rectangle.split.2x1"
        case .versions: return "clock.arrow.circlepath"
        case .verify: return "checkmark.shield"
        case .recognize: return "text.viewfinder"
        case .fillForms: return "pencil.and.list.clipboard"
        case .sign: return "signature"
        case .redact: return "eye.slash"
        case .compress:
            return "arrow.down.right.and.arrow.up.left"
        case .protect: return "lock.doc"
        case .exportOffice: return "doc.richtext"
        }
    }

    var quickTask: PDFQuickTask? {
        switch self {
        case .continueReading, .compare, .versions:
            return nil
        case .organize: return .organizePages
        case .verify: return .safeShare
        case .recognize: return .recognizeText
        case .fillForms: return .fillForms
        case .sign: return .signPDF
        case .redact: return .redactPDF
        case .compress: return .compressPDF
        case .protect: return .protectPDF
        case .exportOffice: return .exportText
        }
    }

    static func mapped(from tool: DocumentTool) -> Self? {
        switch tool {
        case .organize: return .organize
        case .compare: return .compare
        case .recognize: return .recognize
        case .fillForm: return .fillForms
        case .sign: return .sign
        case .redact: return .redact
        case .compress: return .compress
        case .protect: return .protect
        case .export: return .exportOffice
        default: return nil
        }
    }
}

private struct StudioWorkspacePlaceholder: View {
    var body: some View {
        ZStack {
            PPCanvas()
            VStack(spacing: PPSpacing.large) {
                PPIllustration(kind: .workspace, width: 220)
                    .overlay {
                        StudioStageMarks(
                            tint: PPColor.accent,
                            inset: 4,
                            arm: 12
                        )
                    }
                VStack(spacing: PPSpacing.small) {
                    Text("Select a working copy")
                        .font(.title2.bold())
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                    Text(
                        "The library stays open while the PDF and its evidence appear here."
                    )
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                }
            }
            .padding(PPSpacing.xLarge)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct StudioDocumentInspector: View {
    private struct VersionLoadRequest: Hashable {
        let recordID: UUID
        let contentRevisionID: UUID?
        let reloadRequest: Int
        let isActive: Bool
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @AppStorage("workspace.inspectorActions")
    private var savedInspectorActions = ""
    @AppStorage("document.favoriteTools")
    private var savedFavoriteTools = ""
    @State private var showsDocumentDetails = false
    @State private var recentVersions: [PDFVersionSnapshot] = []
    @State private var isPresentingVersionHistory = false
    @State private var initialVersionHistoryID: UUID?
    @State private var isLoadingVersions = false
    @State private var versionLoadGeneration = UUID()
    @State private var versionReloadRequest = 0
    @State private var pendingVersionRoute: DocumentRoute?
    @State private var versionNavigationTask: Task<Void, Never>?
    @State private var versionNavigationGeneration = UUID()
    @State private var versionSelectionFeedback = 0

    let recordID: UUID
    let onOpen: (DocumentRoute) -> Void
    let onCompare: (UUID) -> Void

    var body: some View {
        ZStack {
            PPCanvas()

            if let record = model.record(id: recordID) {
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.large
                    ) {
                        Text("Document tools".localizedUI)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                            Text(record.displayName).font(.subheadline.weight(.semibold))
                            Text(record.subtitle).font(.caption).foregroundStyle(PPColor.textSecondary)
                        }
                        documentTools(record)
                        DisclosureGroup("Document details".localizedUI, isExpanded: $showsDocumentDetails) {
                            VStack(alignment: .leading, spacing: PPSpacing.large) {
                                documentIdentity(record)
                                evidenceLedger(record)
                                revisionTimeline(record)
                                nextActions(record)
                            }
                            .padding(.top, PPSpacing.medium)
                        }
                        .font(.subheadline)
                        .accessibilityIdentifier("inspectorDocumentDetails")
                    }
                    .padding(PPSpacing.regular)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task(id: versionLoadRequest) {
            guard scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else { return }
            await loadRecentVersions()
        }
        .onChange(of: recordID) { _, _ in
            interruptInspectorWork(clearsVersions: true)
        }
        .sheet(
            isPresented: $isPresentingVersionHistory,
            onDismiss: completeVersionHistoryPresentation
        ) {
            PDFVersionHistoryView(
                recordID: recordID,
                initialVersionID: initialVersionHistoryID
            ) { targetRecordID, pageIndex in
                pendingVersionRoute = DocumentRoute(
                    recordID: targetRecordID,
                    pageIndex: pageIndex
                ).bindingExpectedRevision(
                    model.record(id: targetRecordID)?
                        .contentRevisionID
                )
                isPresentingVersionHistory = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptInspectorWork(clearsVersions: true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptInspectorWork(clearsVersions: true)
        }
        .onDisappear {
            interruptInspectorWork(clearsVersions: false)
        }
        .sensoryFeedback(
            .selection,
            trigger: versionSelectionFeedback
        )
    }

    private func documentTools(_ record: DocumentRecord) -> some View {
        VStack(spacing: 0) {
            ForEach([PDFQuickTask.fillForms, .signPDF, .organizePages, .compressPDF, .recognizeText, .safeShare], id: \.self) { task in
                let supported = task.supports(record) && !model.isProcessing(record.id)
                Button {
                    guard supported else { return }
                    onOpen(DocumentRoute(recordID: record.id, quickTask: task)
                        .bindingExpectedRevision(record.contentRevisionID))
                } label: {
                    HStack(spacing: PPSpacing.medium) {
                        Image(systemName: task.symbol).frame(width: 24)
                        Text(task.title.localizedUI).font(.subheadline.weight(.medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .foregroundStyle(task == .safeShare ? PPColor.accent : PPColor.textPrimary)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!supported)
                .opacity(supported ? 1 : 0.45)
                .accessibilityHint(task.compatibilityNote(for: record).localizedUI)
                .accessibilityIdentifier("inspectorTool-\(task.rawValue)")
                Divider()
            }
        }
    }

    private var versionLoadRequest: VersionLoadRequest {
        VersionLoadRequest(
            recordID: recordID,
            contentRevisionID: model.record(id: recordID)?
                .contentRevisionID,
            reloadRequest: versionReloadRequest,
            isActive: scenePhase == .active
        )
    }

    private func loadRecentVersions() async {
        let generation = UUID()
        versionLoadGeneration = generation
        isLoadingVersions = true
        let loaded = await model.versionHistory(recordID: recordID)
        guard !Task.isCancelled,
              versionLoadGeneration == generation,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        recentVersions = Array(loaded.prefix(3))
        isLoadingVersions = false
    }

    private func presentVersionHistory(
        initialVersionID: UUID?
    ) {
        initialVersionHistoryID = initialVersionID
        versionSelectionFeedback &+= 1
        isPresentingVersionHistory = true
    }

    private func completeVersionHistoryPresentation() {
        initialVersionHistoryID = nil
        versionReloadRequest &+= 1
        guard let route = pendingVersionRoute else { return }
        pendingVersionRoute = nil
        versionNavigationTask?.cancel()
        let generation = UUID()
        versionNavigationGeneration = generation
        versionNavigationTask = Task { @MainActor in
            defer {
                if versionNavigationGeneration == generation {
                    versionNavigationTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  versionNavigationGeneration == generation,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  model.record(id: route.recordID) != nil
            else { return }
            onOpen(route)
        }
    }

    private func cancelVersionNavigation() {
        versionNavigationGeneration = UUID()
        versionNavigationTask?.cancel()
        versionNavigationTask = nil
    }

    private func interruptInspectorWork(
        clearsVersions: Bool
    ) {
        versionLoadGeneration = UUID()
        isLoadingVersions = false
        cancelVersionNavigation()
        pendingVersionRoute = nil
        initialVersionHistoryID = nil
        isPresentingVersionHistory = false
        if clearsVersions {
            recentVersions.removeAll(keepingCapacity: false)
        }
    }

    private func documentIdentity(
        _ record: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            if let url = model.url(for: record.id) {
                PDFPageThumbnailView(
                    url: url,
                    pageIndex: record.lastPageIndex,
                    refreshToken: model.refreshToken(for: record.id),
                    width: 126
                )
                .frame(maxWidth: .infinity)
                .overlay {
                    StudioStageMarks(
                        tint: PPColor.accent,
                        inset: 2,
                        arm: 8
                    )
                }
            }

            Text(record.displayName)
                .font(.headline)
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(3)
            Text(record.subtitle)
                .font(.caption.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
        }
    }

    private func evidenceLedger(
        _ record: DocumentRecord
    ) -> some View {
        let profile = model.commandProfile(for: record)
        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "EVIDENCE",
                symbol: "checklist",
                count: profile.signals.count,
                tint: inspectorTint(profile.readiness)
            )

            StudioMetricCell(
                value: "\(profile.score)",
                label: "Readiness",
                symbol: profile.primarySymbol,
                tint: inspectorTint(profile.readiness),
                detail: profile.primaryTitle
            )

            ForEach(profile.signals) { signal in
                StudioMetricCell(
                    value: signal.value,
                    label: signal.title,
                    symbol: signal.symbol,
                    tint: inspectorTint(signal.readiness),
                    detail: signal.detail
                )
            }
        }
    }

    private func nextActions(
        _ record: DocumentRecord
    ) -> some View {
        let headerLayout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                )
            )
            : AnyLayout(HStackLayout(spacing: PPSpacing.small))

        return VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "NEXT",
                symbol: "arrow.right",
                tint: PPColor.mint
            )

            headerLayout {
                Text(
                    AppLocalization.format(
                        "%lld of 5 work positions",
                        configuredActions.count
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer(minLength: 0)
                }
                Menu {
                    ForEach(StudioInspectorAction.allCases) {
                        action in
                        Button {
                            toggleConfiguredAction(action)
                        } label: {
                            Label(
                                action.title.localizedUI,
                                systemImage:
                                    configuredActions.contains(action)
                                    ? "checkmark"
                                    : action.symbol
                            )
                        }
                    }
                    Divider()
                    Button {
                        resetConfiguredActions()
                    } label: {
                        Label(
                            "Reset from Favorites",
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                } label: {
                    Label(
                        "Customize",
                        systemImage: "slider.horizontal.3"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.mint)
                .hoverEffect(.highlight)
                .frame(
                    maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                        ? .infinity
                        : nil,
                    alignment: .leading
                )
            }

            ForEach(configuredActions) { action in
                configurableAction(
                    action,
                    record: record
                )
            }
        }
    }

    private func revisionTimeline(
        _ record: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioSectionRule(
                title: "REVISION LINE",
                detail: recentVersions.isEmpty
                    ? "Protected before the next edit"
                    : "Current plus protected history",
                symbol: "point.3.connected.trianglepath.dotted",
                count: recentVersions.count,
                tint: PPColor.amber
            )
            .padding(.bottom, PPSpacing.small)

            if isLoadingVersions {
                HStack(spacing: PPSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading protected versions".localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                    Spacer(minLength: 0)
                    OnDeviceBadge(compact: true)
                }
                .frame(minHeight: 44)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }

            Button {
                presentVersionHistory(initialVersionID: nil)
            } label: {
                revisionNode(
                    title: "Current working copy",
                    detail: record.modifiedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    ),
                    value: String(
                        record.contentRevisionID.uuidString.prefix(6)
                    ),
                    tint: PPColor.mint,
                    isLast: recentVersions.isEmpty
                )
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityHint(
                "Opens the complete protected version history."
                    .localizedUI
            )

            ForEach(
                Array(recentVersions.enumerated()),
                id: \.element.id
            ) { index, version in
                Button {
                    presentVersionHistory(
                        initialVersionID: version.id
                    )
                } label: {
                    revisionNode(
                        title: AppLocalization.format(
                            "Before %@",
                            version.label.localizedUI
                        ),
                        detail: version.createdAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        ),
                        value: "\(version.pageCount)p",
                        tint: PPColor.amber,
                        isLast: index == recentVersions.count - 1
                    )
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .accessibilityHint(
                    "Opens this saved version and compares it with the working copy."
                        .localizedUI
                )
            }
        }
    }

    private func revisionNode(
        title: String,
        detail: String,
        value: String,
        tint: Color,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: PPSpacing.small) {
            VStack(spacing: 0) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .padding(.top, 5)
                if !isLast {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.72))
                        .frame(width: 1, height: 34)
                }
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.localizedUI)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(2)
                Text(detail.localizedUI)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
            }
            Spacer(minLength: 0)
            Text(value)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(tint)
        }
        .contentShape(Rectangle())
    }

    private func configurableAction(
        _ action: StudioInspectorAction,
        record: DocumentRecord
    ) -> some View {
        HStack(spacing: 2) {
            if action == .compare {
                Menu {
                    ForEach(comparisonCandidates) { candidate in
                        Button {
                            onCompare(candidate.id)
                        } label: {
                            Label(
                                candidate.displayName,
                                systemImage: "doc.on.doc"
                            )
                        }
                    }
                } label: {
                    inspectorActionLabel(
                        action.title,
                        detail: comparisonCandidates.isEmpty
                            ? "Import another unlocked PDF"
                            : action.detail,
                        symbol: action.symbol,
                        tint: actionTint(action)
                    )
                }
                .buttonStyle(.plain)
                .hoverEffect(.highlight)
                .disabled(comparisonCandidates.isEmpty)
            } else {
                inspectorAction(
                    action.title,
                    detail: action.detail,
                    symbol: action.symbol,
                    tint: actionTint(action)
                ) {
                    perform(action, record: record)
                }
            }

            Menu {
                Button {
                    moveConfiguredAction(action, offset: -1)
                } label: {
                    Label(
                        "Move Earlier",
                        systemImage: "arrow.up"
                    )
                }
                .disabled(configuredActions.first == action)

                Button {
                    moveConfiguredAction(action, offset: 1)
                } label: {
                    Label(
                        "Move Later",
                        systemImage: "arrow.down"
                    )
                }
                .disabled(configuredActions.last == action)

                Divider()
                Button(role: .destructive) {
                    toggleConfiguredAction(action)
                } label: {
                    Label(
                        "Remove from Inspector",
                        systemImage: "minus.circle"
                    )
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel(
                AppLocalization.format(
                    "Arrange %@",
                    action.title.localizedUI
                )
            )
        }
    }

    private func perform(
        _ action: StudioInspectorAction,
        record: DocumentRecord
    ) {
        if action == .continueReading {
            onOpen(
                DocumentRoute(
                    recordID: record.id,
                    pageIndex: record.lastPageIndex
                )
            )
        } else if action == .versions {
            presentVersionHistory(initialVersionID: nil)
        } else if let quickTask = action.quickTask {
            onOpen(
                DocumentRoute(
                    recordID: record.id,
                    quickTask: quickTask
                )
            )
        }
    }

    private var configuredActions: [StudioInspectorAction] {
        let stored = decodedActions(savedInspectorActions)
        if !stored.isEmpty {
            return Array(stored.prefix(5))
        }
        return recommendedActions
    }

    private var recommendedActions: [StudioInspectorAction] {
        var result: [StudioInspectorAction] = []
        for value in savedFavoriteTools.split(separator: ",") {
            guard let tool = DocumentTool(rawValue: String(value)),
                  let action = StudioInspectorAction.mapped(from: tool),
                  !result.contains(action)
            else { continue }
            result.append(action)
        }
        for action in [
            StudioInspectorAction.continueReading,
            .organize,
            .compare,
            .versions,
            .verify
        ] where !result.contains(action) {
            result.append(action)
        }
        return Array(result.prefix(5))
    }

    private func decodedActions(
        _ encoded: String
    ) -> [StudioInspectorAction] {
        var result: [StudioInspectorAction] = []
        for value in encoded.split(separator: ",") {
            guard let action = StudioInspectorAction(
                rawValue: String(value)
            ),
                  !result.contains(action)
            else { continue }
            result.append(action)
        }
        return result
    }

    private func persistActions(
        _ actions: [StudioInspectorAction]
    ) {
        savedInspectorActions = actions
            .prefix(5)
            .map(\.rawValue)
            .joined(separator: ",")
    }

    private func toggleConfiguredAction(
        _ action: StudioInspectorAction
    ) {
        var actions = configuredActions
        if let index = actions.firstIndex(of: action) {
            guard actions.count > 1 else { return }
            actions.remove(at: index)
        } else {
            guard actions.count < 5 else {
                model.presentNotice(
                    "The Inspector holds up to five actions.",
                    in: paperPathSceneID
                )
                return
            }
            actions.append(action)
        }
        persistActions(actions)
    }

    private func moveConfiguredAction(
        _ action: StudioInspectorAction,
        offset: Int
    ) {
        var actions = configuredActions
        guard let index = actions.firstIndex(of: action) else {
            return
        }
        let destination = min(
            max(index + offset, 0),
            actions.count - 1
        )
        guard destination != index else { return }
        actions.swapAt(index, destination)
        persistActions(actions)
    }

    private func resetConfiguredActions() {
        persistActions(recommendedActions)
    }

    private func actionTint(
        _ action: StudioInspectorAction
    ) -> Color {
        switch action {
        case .continueReading, .exportOffice:
            return PPColor.accent
        case .organize, .recognize:
            return PPColor.cyan
        case .compare, .versions, .compress, .protect:
            return PPColor.amber
        case .verify, .fillForms, .sign:
            return PPColor.mint
        case .redact:
            return PPColor.rose
        }
    }

    private var comparisonCandidates: [DocumentRecord] {
        DocumentComparisonCandidates.ordered(
            from: model.documents,
            sourceID: recordID
        )
    }

    private func inspectorAction(
        _ title: String,
        detail: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            inspectorActionLabel(
                title,
                detail: detail,
                symbol: symbol,
                tint: tint
            )
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }

    private func inspectorActionLabel(
        _ title: String,
        detail: String,
        symbol: String,
        tint: Color
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title.localizedUI)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(detail.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? nil
                            : 2
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
        }
        .padding(.leading, PPSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 44)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(0.72))
                .frame(width: 2)
        }
        .contentShape(Rectangle())
    }

    private func inspectorTint(
        _ readiness: DocumentCommandReadiness
    ) -> Color {
        switch readiness {
        case .ready: return PPColor.mint
        case .review: return PPColor.amber
        case .blocked: return PPColor.rose
        }
    }
}

private struct StudioComparisonWorkspace: View {
    private struct ComparisonRevisionStamp: Equatable {
        let baseRecordID: UUID
        let revisedRecordID: UUID
        let baseRevisionID: UUID?
        let revisedRevisionID: UUID?
    }

    private struct ComparisonProofPayload: Identifiable {
        let baseRecordID: UUID
        let baseRevisionID: UUID
        let baseTitle: String
        let baseURL: URL
        let basePageCount: Int
        let baseRefreshToken: Int
        let revisedRecordID: UUID
        let revisedRevisionID: UUID
        let revisedTitle: String
        let revisedURL: URL
        let revisedPageCount: Int
        let revisedRefreshToken: Int
        let initialBasePage: Int
        let initialRevisedPage: Int
        let initialChangeIndex: Int?
        let review: PDFChangeReview

        var id: String {
            [
                baseRecordID.uuidString,
                baseRevisionID.uuidString,
                revisedRecordID.uuidString,
                revisedRevisionID.uuidString
            ].joined(separator: ":")
        }
    }

    private struct ComparisonMetrics {
        static let empty = ComparisonMetrics(
            allCount: 0,
            criticalCount: 0,
            insertedCount: 0,
            removedCount: 0,
            structureCount: 0,
            textCount: 0,
            vectorCount: 0
        )

        let allCount: Int
        let criticalCount: Int
        let insertedCount: Int
        let removedCount: Int
        let structureCount: Int
        let textCount: Int
        let vectorCount: Int

        static func build(
            for review: PDFChangeReview
        ) -> ComparisonMetrics {
            var criticalCount = 0
            var insertedCount = 0
            var removedCount = 0
            var structureCount = 0
            var textCount = 0
            var vectorCount = 0
            for change in review.changes {
                if change.severity == .critical {
                    criticalCount += 1
                }
                if change.textChanged
                    || change.hasLocatedTextDifferences {
                    textCount += 1
                }
                if change.hasLocatedVectorDifferences {
                    vectorCount += 1
                }
                switch change.resolvedMatchKind {
                case .inserted:
                    insertedCount += 1
                    structureCount += 1
                case .removed:
                    removedCount += 1
                    structureCount += 1
                default:
                    if change.geometryChanged {
                        structureCount += 1
                    }
                    break
                }
            }
            return ComparisonMetrics(
                allCount: review.changes.count,
                criticalCount: criticalCount,
                insertedCount: insertedCount,
                removedCount: removedCount,
                structureCount: structureCount,
                textCount: textCount,
                vectorCount: vectorCount
            )
        }
    }

    private enum ChangeFilter:
        String,
        CaseIterable,
        Identifiable {
        case all
        case critical
        case structure
        case text
        case vector

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .critical: return "Critical"
            case .structure: return "Structure"
            case .text: return "Text"
            case .vector: return "Vector"
            }
        }

        var symbol: String {
            switch self {
            case .all:
                return "line.3.horizontal.decrease.circle"
            case .critical:
                return "exclamationmark.octagon"
            case .structure:
                return "doc.badge.plus"
            case .text:
                return "textformat"
            case .vector:
                return "square.dashed"
            }
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("workspace.comparisonSyncPages")
    private var defaultSyncPages = true
    @SceneStorage("workspace.sceneComparisonSyncPages")
    private var savedSyncPages = ""
    @SceneStorage("workspace.comparisonBasePage")
    private var savedBasePage = 0
    @SceneStorage("workspace.comparisonRevisedPage")
    private var savedRevisedPage = 0
    @SceneStorage("workspace.comparisonBasePageRecordID")
    private var savedBasePageRecordID = ""
    @SceneStorage("workspace.comparisonRevisedPageRecordID")
    private var savedRevisedPageRecordID = ""
    @AppStorage("workspace.comparisonPageEvidence")
    private var defaultShowsPageEvidence = true
    @SceneStorage("workspace.sceneComparisonPageEvidence")
    private var savedShowsPageEvidence = ""
    @SceneStorage("workspace.comparisonChangeFilter")
    private var savedChangeFilter = ChangeFilter.all.rawValue

    let session: StudioComparisonSession
    let onSwap: () -> Void
    let onClose: () -> Void

    @State private var basePage = 0
    @State private var revisedPage = 0
    @State private var baseNavigationToken = 0
    @State private var revisedNavigationToken = 0
    @State private var review: PDFChangeReview?
    @State private var pageMatchLookup: PDFPageMatchLookup?
    @State private var comparisonTask: Task<Void, Never>?
    @State private var isComparing = false
    @State private var comparisonProgress =
        PDFComparisonProgress.starting
    @State private var errorMessage: String?
    @State private var selectedChangeIndex = 0
    @State private var comparisonGeneration = 0
    @State private var syncPages = true
    @State private var showsPageEvidence = true
    @State private var changeFilter = ChangeFilter.all
    @State private var compactProofSide = PDFChangePageSide.revised
    @State private var didRestoreComparisonPresentation = false
    @State private var filteredChanges: [PDFPageChange] = []
    @State private var comparisonMetrics = ComparisonMetrics.empty
    @State private var comparisonProof: ComparisonProofPayload?
    @State private var proofIndexTask: Task<Void, Never>?
    @State private var proofIndexGeneration = UUID()
    @State private var proofOpenFeedback = 0

    var body: some View {
        ZStack {
            PPCanvas()

            if let baseRecord,
               let revisedRecord,
               let baseURL,
               let revisedURL {
                VStack(spacing: 0) {
                    proofHeader(
                        baseRecord: baseRecord,
                        revisedRecord: revisedRecord
                    )
                    changeNavigator
                    if horizontalSizeClass == .compact {
                        compactProofWorkspace(
                            baseRecord: baseRecord,
                            revisedRecord: revisedRecord,
                            baseURL: baseURL,
                            revisedURL: revisedURL
                        )
                    } else {
                        regularProofWorkspace(
                            baseRecord: baseRecord,
                            revisedRecord: revisedRecord,
                            baseURL: baseURL,
                            revisedURL: revisedURL
                        )
                    }
                }
            } else {
                ContentUnavailableView(
                    "Comparison unavailable",
                    systemImage: "doc.on.doc",
                    description: Text(
                        "One of the private working copies is no longer available."
                    )
                )
            }
        }
        .navigationTitle("Comparison workspace")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session) {
            restoreComparisonPresentationIfNeeded()
            restorePages()
            startComparison()
        }
        .onDisappear {
            stopComparison()
            interruptProofIndexRebuild()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptProtectedComparison()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtectedComparison()
        }
        .onChange(of: basePage) { _, page in
            savedBasePageRecordID =
                session.baseRecordID.uuidString
            savedBasePage = page
        }
        .onChange(of: revisedPage) { _, page in
            savedRevisedPageRecordID =
                session.revisedRecordID.uuidString
            savedRevisedPage = page
        }
        .onChange(of: syncPages) { _, isEnabled in
            guard didRestoreComparisonPresentation else { return }
            savedSyncPages = isEnabled ? "true" : "false"
            defaultSyncPages = isEnabled
        }
        .onChange(of: showsPageEvidence) { _, isEnabled in
            guard didRestoreComparisonPresentation else { return }
            savedShowsPageEvidence = isEnabled ? "true" : "false"
            defaultShowsPageEvidence = isEnabled
        }
        .onChange(of: changeFilter) { _, _ in
            if didRestoreComparisonPresentation {
                savedChangeFilter = changeFilter.rawValue
            }
            selectedChangeIndex = 0
            rebuildFilteredChanges()
            if let first = filteredChanges.first {
                open(first)
            }
        }
        .onChange(of: comparisonRevisionStamp) {
            oldStamp,
            newStamp in
            guard oldStamp.baseRecordID == newStamp.baseRecordID,
                  oldStamp.revisedRecordID
                    == newStamp.revisedRecordID,
                  oldStamp.baseRevisionID != nil,
                  oldStamp.revisedRevisionID != nil,
                  oldStamp != newStamp
            else { return }
            invalidateComparisonEvidenceForRevisionChange()
        }
        .fullScreenCover(item: $comparisonProof) { payload in
            comparisonProofView(payload)
        }
        .sensoryFeedback(
            .selection,
            trigger: selectedChangeIndex
        )
        .sensoryFeedback(.selection, trigger: changeFilter)
        .sensoryFeedback(
            .impact(weight: .light),
            trigger: proofOpenFeedback
        )
    }

    private var baseRecord: DocumentRecord? {
        model.record(id: session.baseRecordID)
    }

    private var revisedRecord: DocumentRecord? {
        model.record(id: session.revisedRecordID)
    }

    private var baseURL: URL? {
        model.url(for: session.baseRecordID)
    }

    private var revisedURL: URL? {
        model.url(for: session.revisedRecordID)
    }

    private var comparisonRevisionStamp:
        ComparisonRevisionStamp {
        ComparisonRevisionStamp(
            baseRecordID: session.baseRecordID,
            revisedRecordID: session.revisedRecordID,
            baseRevisionID: baseRecord?.contentRevisionID,
            revisedRevisionID: revisedRecord?.contentRevisionID
        )
    }

    private func restoreComparisonPresentationIfNeeded() {
        guard !didRestoreComparisonPresentation else { return }
        syncPages = switch savedSyncPages {
        case "true": true
        case "false": false
        default: defaultSyncPages
        }
        showsPageEvidence = switch savedShowsPageEvidence {
        case "true": true
        case "false": false
        default: defaultShowsPageEvidence
        }
        changeFilter =
            ChangeFilter(rawValue: savedChangeFilter) ?? .all
        didRestoreComparisonPresentation = true
        savedSyncPages = syncPages ? "true" : "false"
        savedShowsPageEvidence =
            showsPageEvidence ? "true" : "false"
        savedChangeFilter = changeFilter.rawValue
    }

    private func regularProofWorkspace(
        baseRecord: DocumentRecord,
        revisedRecord: DocumentRecord,
        baseURL: URL,
        revisedURL: URL
    ) -> some View {
        HStack(spacing: 0) {
            if let review, !review.changes.isEmpty {
                changeRail(review)
                Rectangle()
                    .fill(PPColor.border.opacity(0.72))
                    .frame(width: 1)
            }

            proofPane(
                side: .source,
                record: baseRecord,
                url: baseURL,
                page: basePage,
                navigationToken: baseNavigationToken
            ) { page in
                basePageChanged(page)
            }

            Rectangle()
                .fill(PPColor.border.opacity(0.72))
                .frame(width: 1)
                .overlay {
                    Rectangle()
                        .fill(PPColor.amber.opacity(0.52))
                        .frame(width: 1, height: 72)
                }

            proofPane(
                side: .revised,
                record: revisedRecord,
                url: revisedURL,
                page: revisedPage,
                navigationToken: revisedNavigationToken
            ) { page in
                revisedPageChanged(page)
            }
        }
    }

    private func compactProofWorkspace(
        baseRecord: DocumentRecord,
        revisedRecord: DocumentRecord,
        baseURL: URL,
        revisedURL: URL
    ) -> some View {
        VStack(spacing: 0) {
            let picker = Picker(
                "Comparison side",
                selection: $compactProofSide
            ) {
                Text("Base".localizedUI)
                    .tag(PDFChangePageSide.source)
                Text("Revised".localizedUI)
                    .tag(PDFChangePageSide.revised)
            }
            if dynamicTypeSize.ppPrefersExpandedLayout {
                picker
                    .pickerStyle(.menu)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44,
                        alignment: .leading
                    )
                    .padding(.horizontal, PPSpacing.medium)
                    .padding(.vertical, PPSpacing.xSmall)
                    .background(PPColor.surface.opacity(0.94))
            } else {
                picker
                    .pickerStyle(.segmented)
                    .padding(.horizontal, PPSpacing.medium)
                    .padding(.vertical, PPSpacing.small)
                    .background(PPColor.surface.opacity(0.94))
            }

            switch compactProofSide {
            case .source:
                proofPane(
                    side: .source,
                    record: baseRecord,
                    url: baseURL,
                    page: basePage,
                    navigationToken: baseNavigationToken
                ) { page in
                    basePageChanged(page)
                }
            case .revised:
                proofPane(
                    side: .revised,
                    record: revisedRecord,
                    url: revisedURL,
                    page: revisedPage,
                    navigationToken: revisedNavigationToken
                ) { page in
                    revisedPageChanged(page)
                }
            }
        }
    }

    private func proofHeader(
        baseRecord: DocumentRecord,
        revisedRecord: DocumentRecord
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.medium) {
                proofIdentityPair(
                    baseRecord: baseRecord,
                    revisedRecord: revisedRecord
                )
                Spacer(minLength: PPSpacing.small)
                proofControls
            }

            VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                proofIdentityPair(
                    baseRecord: baseRecord,
                    revisedRecord: revisedRecord
                )
                HStack {
                    Spacer(minLength: 0)
                    proofControls
                }
            }
        }
        .font(.subheadline)
        .padding(.horizontal, PPSpacing.medium)
        .padding(.vertical, PPSpacing.xSmall)
        .frame(minHeight: 52)
        .background(PPColor.surface.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.6)
        }
    }

    private func proofIdentityPair(
        baseRecord: DocumentRecord,
        revisedRecord: DocumentRecord
    ) -> some View {
        HStack(spacing: PPSpacing.medium) {
            proofIdentity(
                "BASE",
                record: baseRecord,
                tint: PPColor.cyan
            )
            Image(systemName: "arrow.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .accessibilityHidden(true)
            proofIdentity(
                "REVISED",
                record: revisedRecord,
                tint: PPColor.amber
            )
        }
    }

    private var proofControls: some View {
        HStack(spacing: PPSpacing.xSmall) {
            Button {
                stopComparison()
                onSwap()
            } label: {
                Image(systemName: "arrow.triangle.swap")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Swap base and revised PDFs")
            .help("Swap base and revised PDFs")

            Toggle(isOn: $syncPages) {
                Image(
                    systemName: syncPages
                        ? "link"
                        : "link.badge.plus"
                )
                .frame(width: 44, height: 44)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .accessibilityLabel(
                syncPages
                    ? "Disable synchronized pages"
                    : "Synchronize pages"
            )
            .help(
                syncPages
                    ? "Pages move together"
                    : "Pages move independently"
            )

            Toggle(isOn: $showsPageEvidence) {
                Image(
                    systemName: showsPageEvidence
                        ? "viewfinder.circle.fill"
                        : "viewfinder.circle"
                )
                .frame(width: 44, height: 44)
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .accessibilityLabel(
                showsPageEvidence
                    ? "Hide page evidence"
                    : "Show page evidence"
            )
            .help(
                showsPageEvidence
                    ? "Hide page evidence"
                    : "Show page evidence"
            )

            Button {
                openFullComparisonProof()
            } label: {
                Image(systemName: "rectangle.split.2x1.fill")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .disabled(review == nil || isComparing)
            .accessibilityLabel("Open full comparison proof")
            .accessibilityHint(fullProofAccessibilityHint)
            .help("Open full comparison proof")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close comparison workspace")
            .help("Close comparison workspace")
        }
    }

    private func proofIdentity(
        _ label: String,
        record: DocumentRecord,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.localizedUI)
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(tint)
            Text(record.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
            Text(
                AppLocalization.format(
                    "%lld pages",
                    record.profile.pageCount
                )
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(PPColor.textSecondary)
        }
        .frame(maxWidth: 190, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var changeNavigator: some View {
        Group {
            if isComparing {
                HStack(spacing: PPSpacing.small) {
                    LocalComparisonProgressView(
                        progress: comparisonProgress,
                        tint: PPColor.amber,
                        compact: true
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        stopComparison()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.amber)
                    .accessibilityLabel("Stop comparison".localizedUI)
                    .accessibilityHint(
                        "Keeps the current page positions".localizedUI
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let errorMessage {
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(PPColor.rose)
                    Text(errorMessage.localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: PPSpacing.xSmall)
                    Button("Retry") {
                        startComparison()
                    }
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
                }
            } else if let review {
                comparisonReviewNavigator(review)
            }
        }
        .padding(.horizontal, PPSpacing.medium)
        .padding(.vertical, PPSpacing.xSmall)
        .frame(minHeight: 44)
        .background(PPColor.elevated.opacity(0.92))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.52))
                .frame(height: 0.6)
        }
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.2),
            value: isComparing
        )
    }

    private func comparisonReviewNavigator(
        _ review: PDFChangeReview
    ) -> some View {
        let changes = filteredChanges
        return Group {
            if usesCompactChangeNavigator {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        changeMetrics
                            .padding(.trailing, PPSpacing.small)
                    }
                    changeNavigationControls(
                        review,
                        changes: changes
                    )
                }
            } else {
                HStack(spacing: PPSpacing.medium) {
                    changeMetrics
                    Spacer(minLength: 0)
                    changeNavigationControls(
                        review,
                        changes: changes
                    )
                }
            }
        }
    }

    private var usesCompactChangeNavigator: Bool {
        horizontalSizeClass == .compact
            || dynamicTypeSize.ppPrefersExpandedLayout
    }

    private var changeMetrics: some View {
        HStack(spacing: PPSpacing.medium) {
            changeMetric(
                value: comparisonMetrics.criticalCount,
                label: "Critical",
                tint: PPColor.rose
            )
            changeMetric(
                value: comparisonMetrics.insertedCount,
                label: "Inserted",
                tint: PPColor.cyan
            )
            changeMetric(
                value: comparisonMetrics.removedCount,
                label: "Removed",
                tint: PPColor.amber
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func changeNavigationControls(
        _ review: PDFChangeReview,
        changes: [PDFPageChange]
    ) -> some View {
        HStack(spacing: PPSpacing.xSmall) {
            changeFilterControl
            Spacer(minLength: PPSpacing.xSmall)

            if !changes.isEmpty {
                Text(
                    "\(min(selectedChangeIndex + 1, changes.count)) / \(changes.count)"
                )
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .accessibilityLabel(
                    AppLocalization.format(
                        "Change %lld of %lld",
                        min(selectedChangeIndex + 1, changes.count),
                        changes.count
                    )
                )
                Button {
                    moveToChange(offset: -1)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Previous change")
                .help("Previous change")
                Button {
                    moveToChange(offset: 1)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Next change")
                .help("Next change")
            } else {
                Label(
                    (
                        review.changes.isEmpty
                            ? "No deterministic changes"
                            : "No changes in this filter"
                    ).localizedUI,
                    systemImage: "checkmark.seal.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.mint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filteredChanges(
        in review: PDFChangeReview
    ) -> [PDFPageChange] {
        switch changeFilter {
        case .all:
            return review.changes
        case .critical:
            return review.criticalChanges
        case .structure:
            return review.changes.filter {
                $0.resolvedMatchKind == .inserted
                    || $0.resolvedMatchKind == .removed
                    || $0.geometryChanged
            }
        case .text:
            return review.changes.filter {
                $0.textChanged || $0.hasLocatedTextDifferences
            }
        case .vector:
            return review.vectorChanges
        }
    }

    private func rebuildComparisonIndex(
        for review: PDFChangeReview
    ) {
        comparisonMetrics = ComparisonMetrics.build(for: review)
        filteredChanges = filteredChanges(in: review)
    }

    private func rebuildFilteredChanges() {
        guard let review else {
            filteredChanges = []
            return
        }
        filteredChanges = filteredChanges(in: review)
    }

    @ViewBuilder
    private var changeFilterControl: some View {
        Menu {
            ForEach(ChangeFilter.allCases) { filter in
                Button {
                    changeFilter = filter
                } label: {
                    Label(
                        AppLocalization.format(
                            "%@ (%lld)",
                            filter.title.localizedUI,
                            changeCount(for: filter)
                        ),
                        systemImage: filter.symbol
                    )
                }
                .disabled(
                    filter != .all
                        && changeCount(for: filter) == 0
                )
            }
        } label: {
            Label(
                changeFilter.title.localizedUI,
                systemImage: changeFilter.symbol
            )
            .lineLimit(1)
        }
        .frame(minHeight: 44)
        .accessibilityLabel("Change filter")
        .accessibilityValue(
            AppLocalization.format(
                "%@, %lld changes",
                changeFilter.title.localizedUI,
                changeCount(for: changeFilter)
            )
        )
    }

    private func changeCount(
        for filter: ChangeFilter
    ) -> Int {
        switch filter {
        case .all: return comparisonMetrics.allCount
        case .critical: return comparisonMetrics.criticalCount
        case .structure: return comparisonMetrics.structureCount
        case .text: return comparisonMetrics.textCount
        case .vector: return comparisonMetrics.vectorCount
        }
    }

    private func changeRail(
        _ review: PDFChangeReview
    ) -> some View {
        let changes = filteredChanges
        return VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("CHANGE TRACK")
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                Spacer(minLength: 0)
                Text("\(changes.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.rose)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(minHeight: 34)
            .background(PPColor.surface.opacity(0.9))

            if changes.isEmpty {
                VStack(spacing: PPSpacing.small) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(PPColor.mint)
                    Text("No matching changes".localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(PPSpacing.small)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(
                            changes.indices,
                            id: \.self
                        ) { index in
                            changeRailRow(
                                changes[index],
                                index: index
                            )
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(width: 176)
        .background(PPColor.elevated.opacity(0.72))
    }

    private func changeRailRow(
        _ change: PDFPageChange,
        index: Int
    ) -> some View {
        let selected = currentChange?.id == change.id
            && currentChange?.resolvedSourcePageIndex
                == change.resolvedSourcePageIndex
        let accessibilityDetail = [
            change.severity.title.localizedUI,
            change.textDifferencePreview,
            change.hasLocatedVectorDifferences
                ? change.localizedVectorEvidenceCountLabel
                : nil
        ].compactMap { $0 }.joined(separator: " · ")
        return Button {
            selectedChangeIndex = index
            open(change)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: changeSymbol(change))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(changeTint(change))
                    Text(change.resolvedMatchKind.title.localizedUI)
                        .font(.caption2.smallCaps().weight(.bold))
                        .foregroundStyle(changeTint(change))
                    Spacer(minLength: 0)
                    Text(change.severity.title.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                }
                Text(pagePairLabel(change))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                differenceMap(change)
                if let preview = change.textDifferencePreview {
                    Text(preview)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if change.hasLocatedVectorDifferences {
                    Text(change.localizedVectorEvidenceCountLabel)
                        .font(.caption2)
                        .foregroundStyle(PPColor.cyan)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, PPSpacing.small)
            .padding(.vertical, 7)
            .background(
                selected
                    ? changeTint(change).opacity(0.075)
                    : Color.clear
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(
                        selected
                            ? changeTint(change)
                            : PPColor.border.opacity(0.6)
                    )
                    .frame(width: selected ? 2 : 0.6)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.5))
                    .frame(height: 0.6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(
            AppLocalization.format(
                "%@, %@",
                change.resolvedMatchKind.title.localizedUI,
                pagePairLabel(change)
            )
        )
        .accessibilityValue(accessibilityDetail)
    }

    private func differenceMap(
        _ change: PDFPageChange
    ) -> some View {
        GeometryReader { proxy in
            let textEvidence = (
                change.sourceTextDifferences ?? []
            ) + (
                change.revisedTextDifferences ?? []
            )
            let vectorEvidence = (
                change.sourceVectorDifferences ?? []
            ) + (
                change.revisedVectorDifferences ?? []
            )
            ZStack {
                Rectangle()
                    .fill(PPColor.surfaceMuted)
                ForEach(
                    Array(
                        (change.differenceRegions ?? [])
                            .enumerated()
                    ),
                    id: \.offset
                ) { _, region in
                    Rectangle()
                        .fill(
                            changeTint(change)
                                .opacity(
                                    0.18
                                        + 0.62 * region.intensity
                                )
                        )
                        .frame(
                            width: proxy.size.width
                                * region.width,
                            height: proxy.size.height
                                * region.height
                        )
                        .position(
                            x: proxy.size.width
                                * (region.x + region.width / 2),
                            y: proxy.size.height
                                * (region.y + region.height / 2)
                        )
                }
                ForEach(
                    Array(textEvidence.prefix(12).enumerated()),
                    id: \.offset
                ) { _, evidence in
                    Rectangle()
                        .fill(
                            evidence.resolvedGranularity == .character
                                ? PPColor.rose.opacity(0.72)
                                : PPColor.cyan.opacity(0.5)
                        )
                        .frame(
                            width: max(
                                1.5,
                                proxy.size.width
                                    * evidence.region.width
                            ),
                            height: max(
                                1.5,
                                proxy.size.height
                                    * evidence.region.height
                            )
                        )
                        .position(
                            x: proxy.size.width
                                * (
                                    evidence.region.x
                                        + evidence.region.width / 2
                                ),
                            y: proxy.size.height
                                * (
                                    evidence.region.y
                                        + evidence.region.height / 2
                                )
                        )
                }
                ForEach(
                    Array(vectorEvidence.prefix(12).enumerated()),
                    id: \.offset
                ) { _, evidence in
                    Rectangle()
                        .stroke(
                            PPColor.cyan.opacity(0.86),
                            style: StrokeStyle(
                                lineWidth: 1,
                                dash: [2, 1]
                            )
                        )
                        .frame(
                            width: max(
                                2,
                                proxy.size.width
                                    * evidence.region.width
                            ),
                            height: max(
                                2,
                                proxy.size.height
                                    * evidence.region.height
                            )
                        )
                        .position(
                            x: proxy.size.width
                                * (
                                    evidence.region.x
                                        + evidence.region.width / 2
                                ),
                            y: proxy.size.height
                                * (
                                    evidence.region.y
                                        + evidence.region.height / 2
                                )
                        )
                }
                if change.differenceRegions?.isEmpty != false,
                   textEvidence.isEmpty,
                   vectorEvidence.isEmpty {
                    Image(systemName: changeSymbol(change))
                        .font(.caption2)
                        .foregroundStyle(changeTint(change))
                }
            }
        }
        .frame(height: 26)
        .overlay {
            Rectangle()
                .stroke(PPColor.border.opacity(0.62), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var currentChange: PDFPageChange? {
        guard filteredChanges.indices.contains(
            selectedChangeIndex
        ) else { return filteredChanges.first }
        return filteredChanges[selectedChangeIndex]
    }

    private func pagePairLabel(
        _ change: PDFPageChange
    ) -> String {
        let source = change.resolvedSourcePageIndex.map {
            "B\($0 + 1)"
        } ?? "B—"
        let revised = change.resolvedRevisedPageIndex.map {
            "R\($0 + 1)"
        } ?? "R—"
        return "\(source) → \(revised)"
    }

    private func changeSymbol(
        _ change: PDFPageChange
    ) -> String {
        switch change.resolvedMatchKind {
        case .inserted: return "plus"
        case .removed: return "minus"
        case .unchanged: return "checkmark"
        case .modified:
            return change.geometryChanged
                ? "aspectratio"
                : "pencil.line"
        }
    }

    private func changeTint(
        _ change: PDFPageChange
    ) -> Color {
        switch change.resolvedMatchKind {
        case .inserted: return PPColor.cyan
        case .removed: return PPColor.amber
        case .unchanged: return PPColor.mint
        case .modified:
            switch change.severity {
            case .critical: return PPColor.rose
            case .major: return PPColor.accent
            case .minor: return PPColor.textSecondary
            }
        }
    }

    private func changeMetric(
        value: Int,
        label: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(tint)
            Text(label.localizedUI)
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
        }
    }

    private func proofPane(
        side: PDFChangePageSide,
        record: DocumentRecord,
        url: URL,
        page: Int,
        navigationToken: Int,
        onPageChange: @escaping (Int) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: PPSpacing.small) {
                Text(side.title.localizedUI)
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(
                        side == .source
                            ? PPColor.cyan
                            : PPColor.amber
                    )
                Spacer(minLength: 0)
                Button {
                    stepPage(
                        side: side,
                        delta: -1,
                        pageCount: record.profile.pageCount
                    )
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(page <= 0)
                .accessibilityLabel(
                    side == .source
                        ? "Previous base page".localizedUI
                        : "Previous revised page".localizedUI
                )
                Text(
                    AppLocalization.format(
                        "%lld / %lld",
                        page + 1,
                        max(record.profile.pageCount, 1)
                    )
                )
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .frame(minWidth: 62)
                Button {
                    stepPage(
                        side: side,
                        delta: 1,
                        pageCount: record.profile.pageCount
                    )
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderless)
                .disabled(page >= record.profile.pageCount - 1)
                .accessibilityLabel(
                    side == .source
                        ? "Next base page".localizedUI
                        : "Next revised page".localizedUI
                )
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(minHeight: 44)
            .background(PPColor.surface.opacity(0.9))

            PDFDocumentView(
                url: url,
                refreshToken: model.refreshToken(for: record.id),
                targetPageIndex: page,
                navigationToken: navigationToken,
                readingPreferences: PDFReadingPreferences(
                    theme: .paper,
                    layout: .singlePage,
                    scrollsHorizontally: true
                ),
                evidenceOverlay: evidenceOverlay(
                    side: side,
                    page: page
                ),
                onPageChange: onPageChange
            )
            .background(PPColor.surfaceMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func evidenceOverlay(
        side: PDFChangePageSide,
        page: Int
    ) -> PDFEvidenceOverlay? {
        guard showsPageEvidence,
              let change = currentChange
        else { return nil }
        let expectedPage: Int?
        let textEvidence: [PDFTextDifferenceEvidence]
        let vectorEvidence: [PDFVectorDifferenceEvidence]
        switch side {
        case .source:
            expectedPage = change.resolvedSourcePageIndex
            textEvidence = change.sourceTextDifferences ?? []
            vectorEvidence = change.sourceVectorDifferences ?? []
        case .revised:
            expectedPage = change.resolvedRevisedPageIndex
            textEvidence = change.revisedTextDifferences ?? []
            vectorEvidence = change.revisedVectorDifferences ?? []
        }
        guard expectedPage == page,
              !(change.differenceRegions ?? []).isEmpty
                || !textEvidence.isEmpty
                || !vectorEvidence.isEmpty
        else { return nil }
        return PDFEvidenceOverlay(
            pageIndex: page,
            regions: change.differenceRegions ?? [],
            textRegions: textEvidence.filter {
                $0.resolvedGranularity == .word
            }.map(\.region),
            characterTextRegions: textEvidence.filter {
                $0.resolvedGranularity == .character
            }.map(\.region),
            vectorRegions: vectorEvidence.map(\.region),
            tone: side == .source ? .source : .revised,
            generation: comparisonGeneration
                &+ selectedChangeIndex
        )
    }

    private func restorePages() {
        guard let baseRecord, let revisedRecord else { return }
        let restoredBasePage =
            savedBasePageRecordID
                == session.baseRecordID.uuidString
            ? savedBasePage
            : baseRecord.lastPageIndex
        let restoredRevisedPage =
            savedRevisedPageRecordID
                == session.revisedRecordID.uuidString
            ? savedRevisedPage
            : revisedRecord.lastPageIndex
        basePage = min(
            max(restoredBasePage, 0),
            max(baseRecord.profile.pageCount - 1, 0)
        )
        revisedPage = min(
            max(restoredRevisedPage, 0),
            max(revisedRecord.profile.pageCount - 1, 0)
        )
        baseNavigationToken &+= 1
        revisedNavigationToken &+= 1
    }

    private func basePageChanged(_ page: Int) {
        guard page != basePage else { return }
        basePage = page
        guard syncPages,
              let revisedRecord
        else { return }
        let peerPage = pageMatchLookup?
            .revisedPage(matchingSourcePage: page)
            ?? min(
                page,
                max(revisedRecord.profile.pageCount - 1, 0)
            )
        guard revisedPage != peerPage else { return }
        revisedPage = peerPage
        revisedNavigationToken &+= 1
    }

    private func revisedPageChanged(_ page: Int) {
        guard page != revisedPage else { return }
        revisedPage = page
        guard syncPages,
              let baseRecord
        else { return }
        let peerPage = pageMatchLookup?
            .sourcePage(matchingRevisedPage: page)
            ?? min(
                page,
                max(baseRecord.profile.pageCount - 1, 0)
            )
        guard basePage != peerPage else { return }
        basePage = peerPage
        baseNavigationToken &+= 1
    }

    private func stepPage(
        side: PDFChangePageSide,
        delta: Int,
        pageCount: Int
    ) {
        switch side {
        case .source:
            let next = min(
                max(basePage + delta, 0),
                max(pageCount - 1, 0)
            )
            basePage = next
            baseNavigationToken &+= 1
            if syncPages, let revisedRecord {
                revisedPage = pageMatchLookup?
                    .revisedPage(matchingSourcePage: next)
                    ?? min(
                        next,
                        max(
                            revisedRecord.profile.pageCount - 1,
                            0
                        )
                    )
                revisedNavigationToken &+= 1
            }
        case .revised:
            let next = min(
                max(revisedPage + delta, 0),
                max(pageCount - 1, 0)
            )
            revisedPage = next
            revisedNavigationToken &+= 1
            if syncPages, let baseRecord {
                basePage = pageMatchLookup?
                    .sourcePage(matchingRevisedPage: next)
                    ?? min(
                        next,
                        max(baseRecord.profile.pageCount - 1, 0)
                    )
                baseNavigationToken &+= 1
            }
        }
    }

    private func moveToChange(offset: Int) {
        guard !filteredChanges.isEmpty else { return }
        selectedChangeIndex = (
            selectedChangeIndex + offset + filteredChanges.count
        ) % filteredChanges.count
        open(filteredChanges[selectedChangeIndex])
    }

    private func open(_ change: PDFPageChange) {
        if horizontalSizeClass == .compact {
            compactProofSide = change.preferredOpenSide
        }
        if let sourcePageIndex =
            change.resolvedSourcePageIndex {
            basePage = sourcePageIndex
            baseNavigationToken &+= 1
        }
        if let revisedPageIndex =
            change.resolvedRevisedPageIndex {
            revisedPage = revisedPageIndex
            revisedNavigationToken &+= 1
        }
    }

    private func startComparison() {
        guard scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else {
            errorMessage =
                "Comparison stopped. Start again when PaperPath is active."
            return
        }
        comparisonGeneration &+= 1
        let generation = comparisonGeneration
        comparisonTask?.cancel()
        interruptProofIndexRebuild()
        comparisonProof = nil
        review = nil
        pageMatchLookup = nil
        filteredChanges = []
        comparisonMetrics = .empty
        errorMessage = nil
        isComparing = true
        comparisonProgress = .starting
        comparisonTask = Task {
            do {
                let result = try await model.comparePDFs(
                    sourceRecordID: session.baseRecordID,
                    revisedRecordID: session.revisedRecordID
                ) { update in
                    guard comparisonGeneration == generation,
                          update.fractionCompleted
                            >= comparisonProgress.fractionCompleted
                    else { return }
                    comparisonProgress = update
                }
                let lookup = await Task.detached(
                    priority: .utility
                ) {
                    PDFPageMatchLookup(review: result)
                }.value
                try Task.checkCancellation()
                guard comparisonGeneration == generation else {
                    return
                }
                review = result
                pageMatchLookup = lookup
                rebuildComparisonIndex(for: result)
                selectedChangeIndex = 0
                if let first = filteredChanges.first {
                    open(first)
                }
            } catch is CancellationError {
                return
            } catch {
                guard comparisonGeneration == generation else {
                    return
                }
                errorMessage = AppLocalization
                    .userFacingErrorDescription(error)
            }
            guard comparisonGeneration == generation else { return }
            isComparing = false
            comparisonTask = nil
            comparisonProgress = .starting
        }
    }

    private func stopComparison() {
        comparisonGeneration &+= 1
        comparisonTask?.cancel()
        comparisonTask = nil
        isComparing = false
        comparisonProgress = .starting
    }

    private func interruptProtectedComparison() {
        guard isComparing else { return }
        stopComparison()
        errorMessage =
            "Comparison stopped. Start again when PaperPath is active."
    }

    private func invalidateComparisonEvidenceForRevisionChange() {
        let hadEvidence = review != nil
            || comparisonProof != nil
            || isComparing
        stopComparison()
        interruptProofIndexRebuild()
        comparisonProof = nil
        review = nil
        pageMatchLookup = nil
        filteredChanges = []
        comparisonMetrics = .empty
        guard hadEvidence else { return }
        errorMessage =
            "A PDF changed. Compare again before reviewing evidence."
    }

    private var fullProofAccessibilityHint: String {
        if isComparing {
            return "Wait for comparison evidence to finish.".localizedUI
        }
        if review == nil {
            return "Compare both PDFs before opening the full proof."
                .localizedUI
        }
        return "Opens text, character, vector, and page-match evidence."
            .localizedUI
    }

    private func comparisonProofView(
        _ payload: ComparisonProofPayload
    ) -> some View {
        PDFComparisonProofView(
            configuration: comparisonProofConfiguration(
                for: payload
            ),
            review: payload.review
        ) { updatedReview in
            acceptProofReview(
                updatedReview,
                payload: payload
            )
        }
    }

    private func comparisonProofConfiguration(
        for payload: ComparisonProofPayload
    ) -> PDFComparisonProofConfiguration {
        PDFComparisonProofConfiguration(
            id: "studio:\(payload.id)",
            navigationTitle: "Comparison proof",
            evidenceLabel: "COMPARISON EVIDENCE",
            sourceLabel: "BASE",
            sourceTitle: payload.baseTitle,
            sourceURL: payload.baseURL,
            sourcePageCount: payload.basePageCount,
            sourceRefreshToken: payload.baseRefreshToken,
            sourceSymbol: "doc",
            revisedLabel: "REVISED",
            revisedTitle: payload.revisedTitle,
            revisedURL: payload.revisedURL,
            revisedPageCount: payload.revisedPageCount,
            revisedRefreshToken: payload.revisedRefreshToken,
            revisedSymbol: "doc.fill",
            initialSourcePageIndex: payload.initialBasePage,
            initialRevisedPageIndex: payload.initialRevisedPage,
            initialChangeIndex: payload.initialChangeIndex,
            recompute: { manualMatches, progress in
                guard model.record(
                    id: payload.baseRecordID
                )?.contentRevisionID == payload.baseRevisionID,
                      model.record(
                        id: payload.revisedRecordID
                      )?.contentRevisionID
                        == payload.revisedRevisionID
                else {
                    throw PaperPathError.outputVerificationFailed(
                        "a compared PDF changed during page-pair review"
                    )
                }
                return try await model.comparePDFs(
                    sourceRecordID: payload.baseRecordID,
                    revisedRecordID: payload.revisedRecordID,
                    manualMatches: manualMatches,
                    progress: progress
                )
            }
        )
    }

    private func openFullComparisonProof() {
        guard !isComparing,
              let review,
              let baseRecord,
              let revisedRecord,
              let baseURL,
              let revisedURL
        else { return }
        let selectedReviewIndex = currentChange.flatMap {
            review.changes.firstIndex(of: $0)
        }
        comparisonProof = ComparisonProofPayload(
            baseRecordID: baseRecord.id,
            baseRevisionID: baseRecord.contentRevisionID,
            baseTitle: baseRecord.displayName,
            baseURL: baseURL,
            basePageCount: baseRecord.profile.pageCount,
            baseRefreshToken: model.refreshToken(
                for: baseRecord.id
            ),
            revisedRecordID: revisedRecord.id,
            revisedRevisionID: revisedRecord.contentRevisionID,
            revisedTitle: revisedRecord.displayName,
            revisedURL: revisedURL,
            revisedPageCount: revisedRecord.profile.pageCount,
            revisedRefreshToken: model.refreshToken(
                for: revisedRecord.id
            ),
            initialBasePage: basePage,
            initialRevisedPage: revisedPage,
            initialChangeIndex: selectedReviewIndex,
            review: review
        )
        proofOpenFeedback += 1
    }

    private func acceptProofReview(
        _ updatedReview: PDFChangeReview,
        payload: ComparisonProofPayload
    ) {
        guard model.record(id: payload.baseRecordID)?
            .contentRevisionID == payload.baseRevisionID,
              model.record(id: payload.revisedRecordID)?
                .contentRevisionID == payload.revisedRevisionID
        else {
            comparisonProof = nil
            invalidateComparisonEvidenceForRevisionChange()
            return
        }

        let selectedChange = currentChange
        review = updatedReview
        rebuildComparisonIndex(for: updatedReview)
        if let selectedChange,
           let updatedIndex = filteredChanges.firstIndex(
                where: { $0.id == selectedChange.id }
           ) {
            selectedChangeIndex = updatedIndex
        } else {
            selectedChangeIndex = 0
        }
        if let currentChange {
            open(currentChange)
        }

        comparisonGeneration &+= 1
        let generation = comparisonGeneration
        proofIndexGeneration = UUID()
        let indexGeneration = proofIndexGeneration
        proofIndexTask?.cancel()
        pageMatchLookup = nil
        proofIndexTask = Task { @MainActor in
            defer {
                if proofIndexGeneration == indexGeneration {
                    proofIndexTask = nil
                }
            }
            let lookup = await Task.detached(
                priority: .utility
            ) {
                PDFPageMatchLookup(review: updatedReview)
            }.value
            guard !Task.isCancelled,
                  comparisonGeneration == generation,
                  proofIndexGeneration == indexGeneration,
                  model.record(id: payload.baseRecordID)?
                    .contentRevisionID == payload.baseRevisionID,
                  model.record(id: payload.revisedRecordID)?
                    .contentRevisionID
                        == payload.revisedRevisionID
            else { return }
            pageMatchLookup = lookup
        }
    }

    private func interruptProofIndexRebuild() {
        proofIndexGeneration = UUID()
        proofIndexTask?.cancel()
        proofIndexTask = nil
    }
}

private struct AppLockView: View {
    @EnvironmentObject private var appLock: AppLockController
    @Environment(\.accessibilityVoiceOverEnabled)
    private var voiceOverEnabled
    @AccessibilityFocusState private var unlockButtonFocused: Bool
    @State private var errorFeedback = 0

    var body: some View {
        ZStack {
            PPCanvas()
                .ignoresSafeArea()

            ViewThatFits(in: .vertical) {
                lockContent
                    .padding(PPSpacing.xLarge)
                ScrollView {
                    lockContent
                        .padding(PPSpacing.xLarge)
                }
                .scrollIndicators(.hidden)
            }
        }
        .accessibilityElement(children: .contain)
        .onAppear {
            if voiceOverEnabled {
                unlockButtonFocused = true
            }
        }
        .onChange(of: appLock.errorMessage) { _, message in
            guard let message else { return }
            errorFeedback += 1
            if voiceOverEnabled {
                UIAccessibility.post(
                    notification: .announcement,
                    argument: message
                )
            }
        }
        .sensoryFeedback(.error, trigger: errorFeedback)
    }

    private var lockContent: some View {
        VStack(
            alignment: .leading,
            spacing: PPSpacing.large
        ) {
            StudioSectionRule(
                title: "PRIVATE WORKSPACE",
                detail: "Document previews remain covered",
                symbol: "lock.shield",
                tint: PPColor.mint
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.xLarge) {
                    lockIllustration
                    lockCopy
                }
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.medium
                ) {
                    lockIllustration
                    lockCopy
                }
            }

            Button {
                Task {
                    _ = await appLock.unlock()
                }
            } label: {
                HStack(spacing: PPSpacing.small) {
                    if appLock.isAuthenticating {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: appLock.symbol)
                    }
                    Text("Unlock")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(appLock.isAuthenticating)
            .accessibilityIdentifier("unlockPaperPath")
            .accessibilityFocused($unlockButtonFocused)

            if let errorMessage = appLock.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(PPColor.rose)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var lockIllustration: some View {
        PPIllustration(kind: .privacy, width: 148)
            .frame(width: 160, height: 126)
            .overlay {
                StudioStageMarks(
                    tint: PPColor.mint,
                    inset: 3,
                    arm: 10
                )
            }
    }

    private var lockCopy: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Text("PaperPath Locked")
                .font(.title2.bold())
                .fontDesign(.serif)
                .foregroundStyle(PPColor.textPrimary)
            Text(appLock.methodTitle.localizedUI)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)

            HStack(spacing: PPSpacing.large) {
                Label("Local", systemImage: "iphone")
                Label("Covered", systemImage: "eye.slash")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.mint)
        }
    }
}

private struct PDFDropTargetOverlay: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()

            VStack(spacing: PPSpacing.medium) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(PPColor.accent)
                    .frame(width: 76, height: 76)
                    .background(PPColor.accent.opacity(0.1))
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: PPRadius.control,
                            style: .continuous
                        )
                    )
                    .accessibilityHidden(true)

                Text("Drop PDFs to import".localizedUI)
                    .font(
                        dynamicTypeSize.ppPrefersExpandedLayout
                            ? .title2.bold()
                            : .title.bold()
                    )
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(
                    "Private copies will be created. Originals stay unchanged."
                        .localizedUI
                )
                .font(.subheadline)
                .foregroundStyle(PPColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(PPSpacing.xLarge)
            .frame(maxWidth: 520)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: PPRadius.document,
                style: .continuous
            )
            .strokeBorder(
                PPColor.accent,
                style: StrokeStyle(
                    lineWidth: 3,
                    dash: [12, 8]
                )
            )
            .padding(PPSpacing.medium)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drop PDFs to import".localizedUI)
        .accessibilityHint(
            "Private copies will be created. Originals stay unchanged."
                .localizedUI
        )
    }
}

private struct PrivacyCover: View {
    var body: some View {
        ZStack {
            PPCanvas()

            VStack(spacing: PPSpacing.medium) {
                PPIllustration(kind: .privacy, width: 170)
                    .overlay {
                        StudioStageMarks(
                            tint: PPColor.mint,
                            inset: 3,
                            arm: 10
                        )
                    }
                Text(AppBrand.title)
                    .font(.title2.bold())
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                Text(AppBrand.subtitle.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.accent)
                Text("Document previews are hidden")
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
            }
            .padding(PPSpacing.xLarge)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ExternalImportBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let progress: PDFOperationProgress?
    let onStop: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    HStack(spacing: PPSpacing.small) {
                        importSymbol
                        importTitle
                        Spacer(minLength: PPSpacing.small)
                        stopButton
                    }
                    progressDetails
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    importSymbol
                    VStack(alignment: .leading, spacing: 4) {
                        importTitle
                        progressDetails
                    }
                    Spacer(minLength: PPSpacing.small)
                    stopButton
                }
            }
        }
        .padding(.leading, PPSpacing.regular)
        .padding(.trailing, PPSpacing.small)
        .padding(.vertical, PPSpacing.small)
        .frame(maxWidth: 560, minHeight: 64)
        .background {
            RoundedRectangle(
                cornerRadius: PPRadius.control,
                style: .continuous
            )
            .fill(.ultraThinMaterial)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PPColor.cyan)
                .frame(width: 2)
                .padding(.vertical, 7)
        }
        .accessibilityElement(children: .contain)
    }

    private var importSymbol: some View {
        ToolSymbolPlate(
            symbol: "tray.and.arrow.down.fill",
            tint: PPColor.cyan,
            size: 30
        )
    }

    private var importTitle: some View {
        Text("Importing shared PDFs".localizedUI)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PPColor.textPrimary)
    }

    @ViewBuilder
    private var progressDetails: some View {
        if let progress {
            LocalOperationProgressView(progress: progress)
                .accessibilityIdentifier(
                    "externalPDFImportProgress"
                )
        } else {
            Text("Checking the local import queue".localizedUI)
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(2)
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(PPColor.amber)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop import".localizedUI)
        .accessibilityHint(
            "Keeps private copies that already finished"
        )
    }
}

private struct ExternalImportHandoffBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let documentTitle: String?
    let onStay: () -> Void

    var body: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    HStack(spacing: PPSpacing.small) {
                        handoffSymbol
                        handoffCopy
                        Spacer(minLength: PPSpacing.small)
                        stayButton
                    }
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    handoffSymbol
                    handoffCopy
                    Spacer(minLength: PPSpacing.small)
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    stayButton
                }
            }
        }
        .padding(.leading, PPSpacing.regular)
        .padding(.trailing, PPSpacing.small)
        .padding(.vertical, PPSpacing.small)
        .frame(maxWidth: 560, minHeight: 64)
        .background {
            RoundedRectangle(
                cornerRadius: PPRadius.control,
                style: .continuous
            )
            .fill(.ultraThinMaterial)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(PPColor.mint)
                .frame(width: 2)
                .padding(.vertical, 7)
        }
        .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
    }

    private var handoffSymbol: some View {
        ToolSymbolPlate(
            symbol: "doc.text.magnifyingglass",
            tint: PPColor.mint,
            size: 30
        )
    }

    private var handoffCopy: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Opening private copy".localizedUI)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(documentTitle ?? "Preparing workspace".localizedUI)
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout ? 3 : 1
                )
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stayButton: some View {
        Button(action: onStay) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(PPColor.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stay in Library".localizedUI)
        .accessibilityHint(
            "Keep the new private copy in Library and stop automatic opening."
                .localizedUI
        )
        .help("Stay in Library".localizedUI)
    }
}

private struct NoticeBanner: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    let message: String
    let detail: String?
    let kind: AppNoticeKind
    let actionTitle: String?
    let onAction: (() -> Void)?
    let onDismiss: () -> Void
    var actionAccessibilityHint =
        "Restores the state before this action"
    var showsFullDetail = false

    var body: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout || showsFullDetail {
                VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                    HStack(spacing: PPSpacing.small) {
                        noticeIcon
                        noticeCopy
                        Spacer(minLength: PPSpacing.small)
                        dismissButton
                    }
                    noticeAction
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    noticeIcon
                    noticeCopy
                    Spacer(minLength: PPSpacing.small)
                    noticeAction
                    dismissButton
                }
            }
        }
        .padding(.leading, PPSpacing.regular)
        .padding(.trailing, 6)
        .padding(.vertical, PPSpacing.xSmall)
        .frame(minHeight: detail == nil ? 46 : 54)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(
                cornerRadius: PPRadius.surface,
                style: .continuous
            )
            .fill(PPColor.elevated)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: PPRadius.surface,
                style: .continuous
            )
                .stroke(PPColor.border.opacity(0.6), lineWidth: 0.7)
        }
        .shadow(color: colorScheme == .light ? .black.opacity(0.1) : .clear, radius: 12, y: 6)
        .accessibilityElement(children: .contain)
    }

    private var noticeIcon: some View {
        ToolSymbolPlate(
            symbol: noticeSymbol,
            tint: noticeTint,
            size: 30
        )
    }

    private var noticeCopy: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(message.localizedUI)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(
                    showsFullDetail ? nil
                        : dynamicTypeSize.ppPrefersExpandedLayout ? 4 : 2
                )
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(
                        showsFullDetail ? nil
                            : dynamicTypeSize.ppPrefersExpandedLayout ? 4 : 2
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var noticeAction: some View {
        if let actionTitle,
           let onAction {
            Button(action: onAction) {
                Text(actionTitle.localizedUI)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(noticeTint)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, PPSpacing.small)
                    .frame(
                        maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                            ? .infinity
                            : nil,
                        minHeight: 44
                    )
                    .background(PPColor.surfaceMuted, in: RoundedRectangle(cornerRadius: PPRadius.control))
            }
            .buttonStyle(PPPressButtonStyle())
            .accessibilityHint(
                actionAccessibilityHint.localizedUI
            )
        }
    }

    private var dismissButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(PPColor.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss".localizedUI)
    }

    private var noticeTint: Color {
        switch kind {
        case .success: return PPColor.mint
        case .recovery: return PPColor.cyan
        case .warning: return PPColor.amber
        }
    }

    private var noticeSymbol: String {
        switch kind {
        case .success: return "checkmark"
        case .recovery: return "arrow.uturn.backward"
        case .warning: return "exclamationmark"
        }
    }
}
