import LocalAuthentication
import StoreKit
import SwiftUI
import UIKit

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
    private var backgroundedAt: Date?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

    func disable() {
        defaults.set(false, forKey: Self.defaultsKey)
        isEnabled = false
        isLocked = false
        backgroundedAt = nil
        errorMessage = nil
    }

    func setDelay(_ delay: AppLockDelay) {
        defaults.set(delay.rawValue, forKey: Self.delayDefaultsKey)
        self.delay = delay
    }

    func didEnterBackground(at date: Date = Date()) {
        guard isEnabled else { return }
        backgroundedAt = date
        if delay == .immediately {
            lock()
        }
    }

    func didBecomeActive(at date: Date = Date()) {
        guard isEnabled else {
            backgroundedAt = nil
            return
        }
        guard let backgroundedAt else { return }
        self.backgroundedAt = nil
        if date.timeIntervalSince(backgroundedAt)
            >= TimeInterval(delay.rawValue) {
            lock()
        }
    }

    private func lock() {
        guard isEnabled,
              !isAuthenticating,
              !isLocked
        else { return }
        isLocked = true
        lockGeneration &+= 1
    }

    func lockNow() {
        guard isEnabled, !isLocked else { return }
        isLocked = true
        lockGeneration &+= 1
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

    private func refreshAvailability() {
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
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var evaluationError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &evaluationError
        ) else {
            isAvailable = false
            errorMessage = evaluationError?.localizedDescription
                ?? "Device authentication is unavailable."
            return false
        }

        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                errorMessage = nil
            default:
                errorMessage = error.localizedDescription
            }
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: PaperPathModel
    @EnvironmentObject private var appLock: AppLockController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.requestReview) private var requestReview
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityVoiceOverEnabled)
    private var voiceOverEnabled
    @AppStorage(AppPreferences.onboardingCompletedKey)
    private var onboardingCompleted = false
    @AppStorage(AppPreferences.onboardingReplayRequestedKey)
    private var onboardingReplayRequested = false
    @AppStorage("workspace.lastRecordID")
    private var lastWorkspaceRecordID = ""
    @AppStorage("workspace.comparisonPeerID")
    private var lastComparisonPeerID = ""

    @State private var path: [DocumentRoute] = []
    @State private var selectedWorkspaceRoute: DocumentRoute?
    @State private var comparisonSession: StudioComparisonSession?
    @State private var splitVisibility =
        NavigationSplitViewVisibility.all
    @State private var isInspectorPresented = true
    @State private var noticeDismissTask: Task<Void, Never>?
    @State private var pendingExternalOpenTask: Task<Void, Never>?

    var body: some View {
        workspaceNavigation
        .id(appLock.lockGeneration)
        .privacySensitive()
        .overlay(alignment: .top) {
            if let notice = model.actionNotice {
                NoticeBanner(
                    message: notice.message,
                    detail: notice.detail,
                    kind: notice.kind,
                    actionTitle: notice.action.title,
                    onAction: {
                        Task {
                            await model.performNoticeAction(notice)
                        }
                    },
                    onDismiss: {
                        model.dismissActionNotice(id: notice.id)
                    }
                )
                    .padding(.top, PPSpacing.small)
                    .padding(.horizontal, PPSpacing.regular)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            } else if let message = model.noticeMessage {
                NoticeBanner(
                    message: message,
                    detail: nil,
                    kind: .success,
                    actionTitle: nil,
                    onAction: nil
                ) {
                    model.noticeMessage = nil
                }
                    .padding(.top, PPSpacing.small)
                    .padding(.horizontal, PPSpacing.regular)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(10)
            }
        }
        .overlay {
            if scenePhase != .active {
                PrivacyCover()
                    .zIndex(100)
            } else if appLock.isLocked {
                AppLockView()
                    .zIndex(110)
            }
        }
        .animation(
            reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.88),
            value: model.noticeMessage
        )
        .animation(
            reduceMotion
                ? nil
                : .spring(response: 0.42, dampingFraction: 0.88),
            value: model.actionNotice?.id
        )
        .onChange(of: model.noticeMessage) { _, newValue in
            guard let newValue else { return }
            scheduleMessageDismiss(newValue)
        }
        .onChange(of: model.actionNotice) { _, newValue in
            guard let newValue else { return }
            scheduleActionNoticeDismiss(newValue)
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            Task { @MainActor in
                await Task.yield()
                if sizeClass == .regular {
                    if let route = path.last {
                        selectedWorkspaceRoute = route
                        path.removeAll()
                    }
                } else if let route = selectedWorkspaceRoute {
                    path = [route]
                    selectedWorkspaceRoute = nil
                }
            }
        }
        .task {
            if scenePhase == .active,
               appLock.isLocked {
                _ = await appLock.unlock()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                appLock.didBecomeActive()
                Task {
                    if appLock.isLocked,
                       !appLock.isAuthenticating {
                        _ = await appLock.unlock()
                    }
                    await model.processPendingExternalPDFs()
                }
            case .background:
                appLock.didEnterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onChange(
            of: model.pendingExternalDocumentID,
            initial: true
        ) { _, recordID in
            guard let recordID,
                  model.record(id: recordID) != nil
            else { return }
            pendingExternalOpenTask?.cancel()
            pendingExternalOpenTask = Task { @MainActor in
                await Task.yield()
                guard !Task.isCancelled,
                      model.pendingExternalDocumentID == recordID,
                      model.record(id: recordID) != nil
                else { return }
                open(DocumentRoute(recordID: recordID))
                model.clearPendingExternalDocument(recordID)
            }
        }
        .fullScreenCover(
            isPresented: firstRunPresentation
        ) {
            FirstRunExperienceView {
                if let recordID = await model.createSampleWorkspace() {
                    onboardingCompleted = true
                    onboardingReplayRequested = false
                    open(DocumentRoute(recordID: recordID))
                }
            } onComplete: {
                onboardingCompleted = true
                onboardingReplayRequested = false
            }
        }
        .sheet(
            isPresented: $model.isPresentingFullUnlock
        ) {
            FullUnlockView()
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
        .onChange(of: model.documents.map(\.id)) { _, recordIDs in
            if let savedID = UUID(
                uuidString: lastWorkspaceRecordID
            ),
               !recordIDs.contains(savedID) {
                lastWorkspaceRecordID = ""
            }
            if let selectedWorkspaceRoute,
               !recordIDs.contains(selectedWorkspaceRoute.recordID) {
                self.selectedWorkspaceRoute = nil
            }
            if let comparisonSession,
               !recordIDs.contains(comparisonSession.baseRecordID)
                || !recordIDs.contains(
                    comparisonSession.revisedRecordID
                ) {
                self.comparisonSession = nil
                lastComparisonPeerID = ""
            }
        }
        .onChange(
            of: model.verifiedOutputSuccessCount
        ) { _, _ in
            guard !isRunningAutomatedTests,
                  AppEntitlement.shouldRequestRating
            else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard AppEntitlement.shouldRequestRating else {
                    return
                }
                requestReview()
                AppEntitlement.markRatingRequested()
            }
        }
        .alert(
            "Couldn’t complete that",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            if model.errorOffersSettings {
                Button("Open Settings") {
                    if let url = URL(
                        string: UIApplication.openSettingsURLString
                    ) {
                        UIApplication.shared.open(url)
                    }
                    model.clearError()
                }
            }
            Button(
                (
                    model.errorOffersSettings
                        ? "Not Now"
                        : "OK"
                ).localizedUI,
                role: .cancel
            ) {
                model.clearError()
            }
        } message: {
            Text((model.errorMessage ?? "").localizedUI)
        }
    }

    private var firstRunPresentation: Binding<Bool> {
        Binding(
            get: {
                guard !isRunningAutomatedTests,
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

    private func open(_ route: DocumentRoute) {
        lastWorkspaceRecordID = route.recordID.uuidString
        if horizontalSizeClass == .regular {
            comparisonSession = nil
            guard selectedWorkspaceRoute != route else { return }
            selectedWorkspaceRoute = route
            isInspectorPresented = true
            return
        }

        guard path.last != route else { return }
        Task { @MainActor in
            await Task.yield()
            guard path.last != route else { return }
            path.append(route)
        }
    }

    @ViewBuilder
    private var workspaceNavigation: some View {
        if horizontalSizeClass == .regular {
            NavigationSplitView(
                columnVisibility: $splitVisibility
            ) {
                LibraryView(
                    selectedRecordID:
                        selectedWorkspaceRoute?.recordID
                ) { route in
                    open(route)
                }
                .navigationSplitViewColumnWidth(
                    min: 320,
                    ideal: 410,
                    max: 520
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
                                initialQuickTask: route.quickTask
                            ) { createdRoute in
                                open(createdRoute)
                            }
                            .id(route)
                        }
                    }
                    .inspector(
                        isPresented: $isInspectorPresented
                    ) {
                        StudioDocumentInspector(
                            recordID: route.recordID
                        ) { nextRoute in
                            open(nextRoute)
                        } onCompare: { revisedRecordID in
                            beginComparison(
                                baseRecordID: route.recordID,
                                revisedRecordID: revisedRecordID
                            )
                        }
                        .inspectorColumnWidth(
                            min: 260,
                            ideal: 300,
                            max: 360
                        )
                    }
                } else {
                    StudioWorkspacePlaceholder()
                }
            }
            .navigationSplitViewStyle(.balanced)
        } else {
            NavigationStack(path: $path) {
                LibraryView { route in
                    open(route)
                }
                .navigationDestination(for: DocumentRoute.self) { route in
                    DocumentWorkspaceView(
                        recordID: route.recordID,
                        initialPageIndex: route.pageIndex,
                        initialQuickTask: route.quickTask
                    ) { createdRoute in
                        open(createdRoute)
                    }
                }
            }
        }
    }

    private func restoreWorkspaceSelectionIfNeeded() {
        guard horizontalSizeClass == .regular,
              selectedWorkspaceRoute == nil,
              let recordID = UUID(uuidString: lastWorkspaceRecordID),
              let record = model.record(id: recordID)
        else { return }
        selectedWorkspaceRoute = DocumentRoute(
            recordID: recordID,
            pageIndex: record.lastPageIndex
        )
        if let revisedRecordID = UUID(
            uuidString: lastComparisonPeerID
        ),
           revisedRecordID != recordID,
           let revised = model.record(id: revisedRecordID),
           !record.profile.isLocked,
           !revised.profile.isLocked {
            comparisonSession = StudioComparisonSession(
                baseRecordID: recordID,
                revisedRecordID: revisedRecordID
            )
        }
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
        comparisonSession = nil
        lastComparisonPeerID = ""
    }

    private func scheduleMessageDismiss(
        _ message: String
    ) {
        noticeDismissTask?.cancel()
        noticeDismissTask = Task {
            let visibleSeconds = min(
                6,
                max(2.8, Double(message.count) * 0.055)
            )
            try? await Task.sleep(
                for: .seconds(visibleSeconds)
            )
            if !Task.isCancelled,
               model.noticeMessage == message {
                model.noticeMessage = nil
            }
        }
    }

    private func scheduleActionNoticeDismiss(
        _ notice: AppActionNotice
    ) {
        noticeDismissTask?.cancel()
        guard !voiceOverEnabled else { return }
        noticeDismissTask = Task {
            try? await Task.sleep(for: .seconds(9))
            if !Task.isCancelled,
               model.actionNotice?.id == notice.id {
                model.dismissActionNotice(id: notice.id)
            }
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
    @EnvironmentObject private var model: PaperPathModel
    @AppStorage("workspace.inspectorActions")
    private var savedInspectorActions = ""
    @AppStorage("document.favoriteTools")
    private var savedFavoriteTools = ""
    @State private var recentVersions: [PDFVersionSnapshot] = []
    @State private var isPresentingVersionHistory = false

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
                        StudioSectionRule(
                            title: "LIVE INSPECTOR",
                            detail: "Current private copy",
                            symbol: "sidebar.right",
                            tint: PPColor.rose
                        )
                        documentIdentity(record)
                        evidenceLedger(record)
                        revisionTimeline(record)
                        nextActions(record)
                    }
                    .padding(PPSpacing.regular)
                }
                .scrollIndicators(.hidden)
            }
        }
        .task(id: recordID) {
            recentVersions = Array(
                await model.versionHistory(
                    recordID: recordID
                ).prefix(3)
            )
        }
        .sheet(isPresented: $isPresentingVersionHistory) {
            PDFVersionHistoryView(
                recordID: recordID
            ) { targetRecordID, pageIndex in
                isPresentingVersionHistory = false
                DispatchQueue.main.async {
                    onOpen(
                        DocumentRoute(
                            recordID: targetRecordID,
                            pageIndex: pageIndex
                        )
                    )
                }
            }
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
                detail: "Deterministic document state",
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
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "NEXT",
                detail: "Open directly in the current workspace",
                symbol: "arrow.right",
                tint: PPColor.mint
            )

            HStack(spacing: PPSpacing.small) {
                Text(
                    AppLocalization.format(
                        "%lld of 5 work positions",
                        configuredActions.count
                    )
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
                Spacer(minLength: 0)
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

            Button {
                isPresentingVersionHistory = true
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

            ForEach(
                Array(recentVersions.enumerated()),
                id: \.element.id
            ) { index, version in
                Button {
                    isPresentingVersionHistory = true
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
                    .frame(width: 24, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Arrange \(action.title)".localizedUI)
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
            isPresentingVersionHistory = true
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
                model.noticeMessage =
                    "The Inspector holds up to five actions."
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
                    .lineLimit(2)
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
    private enum ChangeFilter:
        String,
        CaseIterable,
        Identifiable {
        case all
        case critical
        case structure

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("workspace.comparisonSyncPages")
    private var syncPages = true
    @AppStorage("workspace.comparisonBasePage")
    private var savedBasePage = 0
    @AppStorage("workspace.comparisonRevisedPage")
    private var savedRevisedPage = 0
    @AppStorage("workspace.comparisonBasePageRecordID")
    private var savedBasePageRecordID = ""
    @AppStorage("workspace.comparisonRevisedPageRecordID")
    private var savedRevisedPageRecordID = ""
    @AppStorage("workspace.comparisonPageEvidence")
    private var showsPageEvidence = true

    let session: StudioComparisonSession
    let onSwap: () -> Void
    let onClose: () -> Void

    @State private var basePage = 0
    @State private var revisedPage = 0
    @State private var baseNavigationToken = 0
    @State private var revisedNavigationToken = 0
    @State private var review: PDFChangeReview?
    @State private var comparisonTask: Task<Void, Never>?
    @State private var isComparing = false
    @State private var errorMessage: String?
    @State private var selectedChangeIndex = 0
    @State private var comparisonGeneration = 0
    @State private var changeFilter = ChangeFilter.all

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
        .navigationTitle("Version proof")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session) {
            restorePages()
            startComparison()
        }
        .onDisappear {
            comparisonTask?.cancel()
            comparisonTask = nil
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
        .onChange(of: changeFilter) { _, _ in
            selectedChangeIndex = 0
            if let first = filteredChanges.first {
                open(first)
            }
        }
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

    private func proofHeader(
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
            Spacer(minLength: PPSpacing.small)

            Button(action: onSwap) {
                Image(systemName: "arrow.triangle.swap")
            }
            .buttonStyle(.borderless)
            .help("Swap base and revised PDFs")

            Toggle(isOn: $syncPages) {
                Image(
                    systemName: syncPages
                        ? "link"
                        : "link.badge.plus"
                )
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
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
            }
            .toggleStyle(.button)
            .buttonStyle(.borderless)
            .help(
                showsPageEvidence
                    ? "Hide page evidence"
                    : "Show page evidence"
            )

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close version proof")
        }
        .font(.subheadline)
        .padding(.horizontal, PPSpacing.medium)
        .frame(minHeight: 52)
        .background(PPColor.surface.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.6)
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
        HStack(spacing: PPSpacing.medium) {
            if isComparing {
                ProgressView()
                    .controlSize(.small)
                    .tint(PPColor.amber)
                Text("Comparing visible content, text, and page geometry")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            } else if let errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PPColor.rose)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Retry") {
                    startComparison()
                }
                .font(.caption.weight(.semibold))
            } else if let review {
                changeMetric(
                    value: review.criticalChanges.count,
                    label: "Critical",
                    tint: PPColor.rose
                )
                changeMetric(
                    value: review.insertedPages.count,
                    label: "Inserted",
                    tint: PPColor.cyan
                )
                changeMetric(
                    value: review.removedPages.count,
                    label: "Removed",
                    tint: PPColor.amber
                )
                Spacer(minLength: 0)
                Picker("Change filter", selection: $changeFilter) {
                    ForEach(ChangeFilter.allCases) { filter in
                        Text(filter.title.localizedUI).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 230)

                if !filteredChanges.isEmpty {
                    Text(
                        "\(min(selectedChangeIndex + 1, filteredChanges.count)) / \(filteredChanges.count)"
                    )
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    Button {
                        moveToChange(offset: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Previous change")
                    Button {
                        moveToChange(offset: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.borderless)
                    .help("Next change")
                } else {
                    Label(
                        review.changes.isEmpty
                            ? "No deterministic changes"
                            : "No changes in this filter",
                        systemImage: "checkmark.seal.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.mint)
                }
            }
        }
        .padding(.horizontal, PPSpacing.medium)
        .frame(minHeight: 40)
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

    private var filteredChanges: [PDFPageChange] {
        guard let review else { return [] }
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
        }
    }

    private func changeRail(
        _ review: PDFChangeReview
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("CHANGE TRACK")
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                Spacer(minLength: 0)
                Text("\(filteredChanges.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.rose)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(minHeight: 34)
            .background(PPColor.surface.opacity(0.9))

            if filteredChanges.isEmpty {
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
                            Array(filteredChanges.enumerated()),
                            id: \.element
                        ) { index, change in
                            changeRailRow(
                                change,
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
        .accessibilityLabel(
            "\(change.resolvedMatchKind.title), \(pagePairLabel(change))"
                .localizedUI
        )
    }

    private func differenceMap(
        _ change: PDFPageChange
    ) -> some View {
        GeometryReader { proxy in
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
                if change.differenceRegions?.isEmpty != false {
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
                }
                .buttonStyle(.borderless)
                .disabled(page <= 0)
                Text(
                    "\(page + 1) / \(max(record.profile.pageCount, 1))"
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
                }
                .buttonStyle(.borderless)
                .disabled(page >= record.profile.pageCount - 1)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(minHeight: 34)
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
              let change = currentChange,
              !(change.differenceRegions ?? []).isEmpty
        else { return nil }
        let expectedPage: Int?
        switch side {
        case .source:
            expectedPage = change.resolvedSourcePageIndex
        case .revised:
            expectedPage = change.resolvedRevisedPageIndex
        }
        guard expectedPage == page else { return nil }
        return PDFEvidenceOverlay(
            pageIndex: page,
            regions: change.differenceRegions ?? [],
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
        let peerPage = review?
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
        let peerPage = review?
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
                revisedPage = review?
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
                basePage = review?
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
        comparisonGeneration &+= 1
        let generation = comparisonGeneration
        comparisonTask?.cancel()
        review = nil
        errorMessage = nil
        isComparing = true
        comparisonTask = Task {
            do {
                let result = try await model.comparePDFs(
                    sourceRecordID: session.baseRecordID,
                    revisedRecordID: session.revisedRecordID
                )
                try Task.checkCancellation()
                guard comparisonGeneration == generation else {
                    return
                }
                review = result
                selectedChangeIndex = 0
                if let first = result.changes.first {
                    open(first)
                }
            } catch is CancellationError {
                return
            } catch {
                guard comparisonGeneration == generation else {
                    return
                }
                errorMessage = error.localizedDescription
            }
            guard comparisonGeneration == generation else { return }
            isComparing = false
            comparisonTask = nil
        }
    }
}

private struct AppLockView: View {
    @EnvironmentObject private var appLock: AppLockController

    var body: some View {
        ZStack {
            PPCanvas()
                .ignoresSafeArea()

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

                if let errorMessage = appLock.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 560)
            .padding(PPSpacing.xLarge)
        }
        .accessibilityElement(children: .contain)
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

private struct NoticeBanner: View {
    let message: String
    let detail: String?
    let kind: AppNoticeKind
    let actionTitle: String?
    let onAction: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: PPSpacing.small) {
            ToolSymbolPlate(
                symbol: noticeSymbol,
                tint: noticeTint,
                size: 30
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(message.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(2)
                if let detail {
                    Text(detail.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: PPSpacing.small)
            if let actionTitle,
               let onAction {
                Button(action: onAction) {
                    Text(actionTitle.localizedUI)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(noticeTint)
                        .padding(.horizontal, PPSpacing.small)
                        .frame(minHeight: 32)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(noticeTint.opacity(0.72))
                                .frame(height: 1.5)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    "Restores the state before this action"
                )
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss".localizedUI)
        }
        .padding(.leading, PPSpacing.regular)
        .padding(.trailing, 6)
        .frame(minHeight: detail == nil ? 46 : 54)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: 2,
                bottomLeadingRadius: 9,
                bottomTrailingRadius: 9,
                topTrailingRadius: 2,
                style: .continuous
            )
            .fill(.ultraThinMaterial)
        }
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: 2,
                bottomLeadingRadius: 9,
                bottomTrailingRadius: 9,
                topTrailingRadius: 2,
                style: .continuous
            )
                .stroke(PPColor.border.opacity(0.6), lineWidth: 0.7)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(noticeTint)
                .frame(width: 2)
                .padding(.vertical, 7)
        }
        .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
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
