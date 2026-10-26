import PDFKit
import SwiftUI
import UIKit

private enum ProtectedPDFPasswordValidationResult: Sendable {
    case valid
    case invalid
    case unavailable
}

struct DocumentWorkspaceView: View {
    @State private var isPrivacyScanPresented = false
    @StateObject private var privacyScanReviewModel =
        PrivacyScanReviewModel()

    private enum ToolMode: String, CaseIterable, Identifiable {
        case read
        case annotate
        case pages
        case deliver

        var id: String { rawValue }

        var title: String {
            switch self {
            case .read: return "Read"
            case .annotate: return "Annotate"
            case .pages: return "Pages"
            case .deliver: return "Deliver"
            }
        }

        var tint: Color {
            switch self {
            case .read: return PPColor.accent
            case .annotate: return PPColor.cyan
            case .pages: return PPColor.textPrimary
            case .deliver: return PPColor.mint
            }
        }

        var symbol: String {
            switch self {
            case .read: return "book"
            case .annotate: return "pencil.tip"
            case .pages: return "square.grid.2x2"
            case .deliver: return "square.and.arrow.up"
            }
        }

        var shortcut: KeyEquivalent {
            switch self {
            case .read: return "1"
            case .annotate: return "2"
            case .pages: return "3"
            case .deliver: return "4"
            }
        }
    }

    enum Sheet: String, Identifiable {
        case brief
        case insight
        case pages
        case recognizedText
        case share
        case tools
        case stamp
        case watermark
        case bates
        case compression
        case protection
        case redaction
        case export
        case officeExport
        case imageExport
        case verifiedExport
        case reading
        case bookmarks
        case formReview
        case find
        case annotations
        case attachments
        case compare
        case deliveryReceipt
        case deliveryHistory
        case receivedPackage
        case sourceLocation
        case technicalInspector
        case versionHistory
        case reader
        case privateNote

        var id: String { rawValue }

        var exportFocus: PDFExportFocus? {
            switch self {
            case .officeExport: return .text
            case .imageExport: return .images
            case .verifiedExport: return .safeShare
            default: return nil
            }
        }
    }

    private enum PendingWorkspaceHandoff {
        case tool(DocumentTool)
        case action(DocumentAction)
        case stamp(
            PDFStampKind,
            pageIndex: Int,
            contentRevisionID: UUID
        )
        case openDocument(DocumentRoute)
        case safeShare
        case unlockForVerifiedOutput
        case recognitionSettings
        case presentSheet(Sheet)
        case navigate(
            pageIndex: Int,
            message: String,
            recordsHistory: Bool,
            thenPresent: Sheet?,
            showsNotice: Bool,
            contentRevisionID: UUID
        )
        case signature(
            pageIndex: Int,
            initialBounds: PDFNormalizedRect?,
            fieldName: String?,
            navigationMessage: String,
            updatesCheckpoint: Bool,
            contentRevisionID: UUID
        )
    }

    private enum WorkspaceMetadataOperation {
        case workflow
        case pin
        case rename
        case bookmark
        case trash

        var title: String {
            switch self {
            case .workflow:
                return "Updating workflow".localizedUI
            case .pin:
                return "Updating pin".localizedUI
            case .rename:
                return "Renaming working copy".localizedUI
            case .bookmark:
                return "Updating bookmark".localizedUI
            case .trash:
                return "Moving to Trash".localizedUI
            }
        }

        var symbol: String {
            switch self {
            case .workflow: return "folder"
            case .pin: return "pin"
            case .rename: return "pencil"
            case .bookmark: return "bookmark"
            case .trash: return "trash"
            }
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @AppStorage("reading.theme") private var savedReadingTheme = PDFReadingTheme.paper.rawValue
    @AppStorage("reading.layout") private var savedReadingLayout = PDFReadingLayout.continuous.rawValue
    @AppStorage("reading.horizontal") private var savedHorizontalNavigation = false
    @AppStorage("markup.highlightColor")
    private var savedHighlightColor = PDFMarkupColor.yellow.rawValue
    @AppStorage("markup.underlineColor")
    private var savedUnderlineColor = PDFMarkupColor.blue.rawValue
    @AppStorage("markup.strikeColor")
    private var savedStrikeColor = PDFMarkupColor.red.rawValue
    @SceneStorage("workspace.toolMode")
    private var savedToolMode = ToolMode.read.rawValue
    @AppStorage("workspace.showToolNames")
    private var showToolNames = true

    let recordID: UUID
    let initialPageIndex: Int?
    let initialQuickTask: PDFQuickTask?
    let initialContentRevisionID: UUID?
    let onReadingPositionChange: (Int, UUID) -> Void
    let onOpenDocument: (DocumentRoute) -> Void

    @State private var presentedSheet: Sheet?
    @State private var pendingWorkspaceHandoff:
        PendingWorkspaceHandoff?
    @State private var isRenaming = false
    @State private var proposedName = ""
    @State private var originalName = ""
    @State private var isSelectingToolMode = false
    @State private var isJumpingToPage = false
    @State private var pageJumpInput = ""
    @FocusState private var renameFieldFocused: Bool
    @FocusState private var pageJumpFieldFocused: Bool
    @State private var isConfirmingDelete = false
    @State private var requestedPageIndex: Int?
    @State private var pageNavigationToken = 0
    @State private var recognitionTask: Task<Void, Never>?
    @State private var recognitionGeneration = UUID()
    @State private var recognitionStopRequested = false
    @State private var searchableCopyTask: Task<Void, Never>?
    @State private var searchableCopyGeneration = UUID()
    @State private var searchableCopyStopRequested = false
    @State private var readingPositionTask: Task<Void, Never>?
    @State private var readingPositionGeneration = UUID()
    @State private var readingPositionOwnerID = UUID()
    @State private var workspaceTransitionTask: Task<Void, Never>?
    @State private var workspaceTransitionGeneration = UUID()
    @State private var activeWorkspaceHandoff:
        PendingWorkspaceHandoff?
    @State private var workspaceHandoffFeedback = 0
    @State private var shareTask: Task<Void, Never>?
    @State private var shareGeneration = UUID()
    @State private var temporaryShareURL: URL?
    @State private var shareProgress: PDFOperationProgress?
    @State private var shareRateWindow = ByteRateWindow()
    @State private var workspaceMetadataTask: Task<Void, Never>?
    @State private var workspaceMetadataGeneration = UUID()
    @State private var workspaceMetadataStopRequested = false
    @State private var activeMetadataOperation:
        WorkspaceMetadataOperation?
    @State private var metadataSuccessFeedback = 0
    @State private var metadataErrorFeedback = 0
    @State private var readingPreferences = PDFReadingPreferences()
    @State private var pdfCommand: PDFViewCommand?
    @State private var currentPageIndex = 0
    @State private var pageStateContentRevisionID: UUID?
    @State private var pageScrubberValue = 0.0
    @State private var isScrubbingPage = false
    @State private var pageBackHistory: [Int] = []
    @State private var pageForwardHistory: [Int] = []
    @State private var pdfSearchHighlight: PDFTextSearchHighlight?
    @State private var privacyEvidenceOverlay: PDFEvidenceOverlay?
    @State private var documentFindQuery = ""
    @State private var documentFindHistory: [String] = []
    @State private var isImmersiveReading = false
    @State private var redactionMarks: [PDFRedactionMark] = []
    @State private var isAddingNote = false
    @State private var pendingNote: String?
    @State private var isUnlocking = false
    @State private var unlockInput = ""
    @State private var unlockErrorMessage: String?
    @State private var unlockValidationTask: Task<Void, Never>?
    @State private var unlockValidationGeneration = UUID()
    @State private var unlockAttemptFeedback = 0
    @FocusState private var unlockFieldFocused: Bool
    @State private var sessionPassword: String?
    @State private var sessionUnlockGeneration = UUID()
    @State private var confirmedSessionUnlockGeneration: UUID?
    @State private var isSessionUnlocked = false
    @State private var isApplyingSessionUnlock = false
    @State private var unlockCopyTask: Task<Void, Never>?
    @State private var unlockCopyGeneration = UUID()
    @State private var unlockCopyIssue: PDFBatchDeliveryIssue?
    @State private var unlockCopyStopRequested = false
    @State private var unlockSuccessFeedback = 0
    @State private var unlockCopyErrorFeedback = 0
    @State private var continuesVerifiedOutputAfterUnlock = false
    @State private var didRestoreReadingPreferences = false
    @State private var didHandleInitialQuickTask = false
    @State private var pageOrganizerStartsSelecting = false
    @State private var pageOrganizerInitialSelection: Set<Int> = []
    @State private var isRedactionMode = false
    @State private var pageNavigationFeedback = 0
    @State private var shareItems: [Any] = []
    @State private var isPresentingPencil = false
    @State private var isPresentingSignature = false
    @State private var signaturePageIndex: Int?
    @State private var signatureInitialBounds: PDFNormalizedRect?
    @State private var isPresentingContentEditor = false
    @State private var isPresentingLinkEditor = false
    @State private var isPresentingImageReplacement = false
    @State private var isConfiguringRecognition = false
    @State private var recognitionConfiguration =
        OCRRecognitionConfiguration.automatic
    @State private var pendingRecognitionConfiguration:
        OCRRecognitionConfiguration?
    @State private var textSelectionForReplacement:
        PDFTextSelectionSnapshot?
    @AppStorage("document.recentTools") private var savedRecentTools = ""
    @AppStorage("document.favoriteTools")
    private var savedFavoriteTools = ""

    init(
        recordID: UUID,
        initialPageIndex: Int? = nil,
        initialQuickTask: PDFQuickTask? = nil,
        initialContentRevisionID: UUID? = nil,
        onReadingPositionChange: @escaping (Int, UUID) -> Void = {
            _,
            _ in
        },
        onOpenDocument: @escaping (DocumentRoute) -> Void = { _ in }
    ) {
        self.recordID = recordID
        self.initialPageIndex = initialPageIndex
        self.initialQuickTask = initialQuickTask
        self.initialContentRevisionID = initialContentRevisionID
        self.onReadingPositionChange = onReadingPositionChange
        self.onOpenDocument = onOpenDocument
        _requestedPageIndex = State(initialValue: initialPageIndex)
    }

    var body: some View {
        Group {
            if let record = model.record(id: recordID),
               let url = model.url(for: recordID) {
                workspace(record: record, url: url)
            } else {
                ContentUnavailableView(
                    "Document unavailable",
                    systemImage: "doc.questionmark",
                    description: Text("The private working copy may have been removed.")
                )
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: recordID) {
            await model.ensureAnalysisLoaded(for: recordID)
            guard !Task.isCancelled else { return }
            await model.synchronizeCompletionState(recordID: recordID)
            guard !Task.isCancelled,
                  let record = model.record(id: recordID)
            else { return }
            pageStateContentRevisionID = record.contentRevisionID
            if let initialContentRevisionID,
               initialContentRevisionID
                != record.contentRevisionID {
                didHandleInitialQuickTask = true
                model[noticeFor: paperPathSceneID] =
                    "Continue point refreshed for the updated PDF"
                        .localizedUI
                if let checkpoint = record.taskCheckpoint,
                   checkpoint.contentRevisionID
                    == record.contentRevisionID {
                    resume(checkpoint)
                    return
                }
                currentPageIndex = record.lastPageIndex
                pageScrubberValue = Double(record.lastPageIndex)
                onReadingPositionChange(
                    record.lastPageIndex,
                    record.contentRevisionID
                )
                if record.lastPageIndex > 0 {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    showPage(
                        record.lastPageIndex,
                        message: "Resumed updated PDF",
                        recordsHistory: false
                    )
                }
                return
            }
            if let initialPageIndex {
                await Task.yield()
                guard !Task.isCancelled else { return }
                _ = commitPageNavigation(
                    initialPageIndex,
                    message: "Opened at match",
                    recordsHistory: false,
                    showsNotice: false
                )
            }
            if !didHandleInitialQuickTask,
               let initialQuickTask {
                didHandleInitialQuickTask = true
                await Task.yield()
                guard !Task.isCancelled else { return }
                if let currentRecord = model.record(id: recordID),
                   let checkpoint = currentRecord.taskCheckpoint,
                   checkpoint.contentRevisionID
                    == currentRecord.contentRevisionID,
                   checkpoint.stage.quickTask == initialQuickTask {
                    resume(checkpoint)
                } else {
                    open(initialQuickTask)
                }
                return
            }
            guard initialPageIndex == nil else { return }
            currentPageIndex = record.lastPageIndex
            pageScrubberValue = Double(record.lastPageIndex)
            if record.lastPageIndex > 0 {
                await Task.yield()
                showPage(
                    record.lastPageIndex,
                    message: "Resumed reading",
                    recordsHistory: false
                )
            } else {
                onReadingPositionChange(
                    0,
                    record.contentRevisionID
                )
                guard scenePhase == .active,
                      UIApplication.shared.isProtectedDataAvailable
                else { return }
                await model.updateReadingPosition(
                    recordID: recordID,
                    pageIndex: 0,
                    expectedContentRevisionID:
                        record.contentRevisionID
                )
            }
        }
        .onDisappear {
            cancelWorkspaceTransition()
            pendingWorkspaceHandoff = nil
            pendingRecognitionConfiguration = nil
            clearProtectedDocumentSession()
            stopRecognition()
            stopSearchableCopyCreation()
            readingPositionGeneration = UUID()
            readingPositionTask?.cancel()
            readingPositionTask = nil
            model.cancelReadingPositionUpdate(
                ownerID: readingPositionOwnerID
            )
            stopSharePreparation()
            cleanupShareCopy()
            invalidateWorkspaceMetadataPresentation()
            let pageIndex = currentPageIndex
            let viewedAt = Date()
            let contentRevisionID = model.record(id: recordID)?
                .contentRevisionID
            let canPersistReadingPosition =
                scenePhase == .active
                && UIApplication.shared.isProtectedDataAvailable
            if canPersistReadingPosition,
               let contentRevisionID,
               pageStateContentRevisionID == contentRevisionID {
                onReadingPositionChange(
                    pageIndex,
                    contentRevisionID
                )
                model.enqueueReadingPositionUpdate(
                    ownerID: readingPositionOwnerID,
                    recordID: recordID,
                    pageIndex: pageIndex,
                    expectedContentRevisionID:
                        contentRevisionID,
                    viewedAt: viewedAt
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background else { return }
            interruptProtectedWorkspaceWork()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtectedWorkspaceWork()
        }
    }

    private func workspace(record: DocumentRecord, url: URL) -> some View {
        let recentDocuments = model.recentDocuments(
            excluding: record.id,
            limit: 5
        )
        let activeSessionPassword = sessionPassword
        let activeSessionGeneration = sessionUnlockGeneration
        let workspaceChrome = AnyView(
            ZStack {
                PPCanvas()

                VStack(spacing: 0) {
                if record.profile.isLocked,
                   isSessionUnlocked,
                   let unlockCopyIssue {
                    unlockCopyRecoveryStrip(unlockCopyIssue)
                        .frame(
                            maxWidth: horizontalSizeClass == .regular
                                ? 1_080
                                : .infinity
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, PPSpacing.regular)
                        .padding(.bottom, PPSpacing.small)
                }

                PDFDocumentView(
                    url: url,
                    refreshToken: model.refreshToken(for: recordID),
                    targetPageIndex: requestedPageIndex,
                    navigationToken: pageNavigationToken,
                    readingPreferences: readingPreferences,
                    command: pdfCommand,
                    evidenceOverlay: privacyEvidenceOverlay,
                    searchHighlight:
                        pdfSearchHighlight?.contentRevisionID
                            == record.contentRevisionID
                            ? pdfSearchHighlight
                            : nil,
                    allowsMutation:
                        !model.isProcessing(recordID)
                            && workspaceMetadataTask == nil,
                    onMutation: {
                        Task {
                            await model.refreshAfterAnnotation(
                                recordID: recordID
                            )
                        }
                    },
                    onRedactionMarks: { marks in
                        guard !marks.isEmpty else {
                            model[noticeFor: paperPathSceneID] = "Select text before marking a redaction"
                            return
                        }
                        redactionMarks = PDFRedactionMarkSanitizer.clean(
                            redactionMarks + marks
                        )
                        presentedSheet = .redaction
                    },
                    onTextSelection: { selection in
                        textSelectionForReplacement = selection
                    },
                    onPageChange: { pageIndex in
                        guard scenePhase == .active,
                              UIApplication.shared
                                .isProtectedDataAvailable,
                              model.record(id: recordID)?
                                .contentRevisionID
                                == record.contentRevisionID,
                              pageStateContentRevisionID
                                == record.contentRevisionID
                        else { return }
                        if pdfSearchHighlight?.pageIndex != pageIndex {
                            pdfSearchHighlight = nil
                        }
                        if privacyEvidenceOverlay?.pageIndex != pageIndex {
                            privacyEvidenceOverlay = nil
                        }
                        currentPageIndex = pageIndex
                        if !isScrubbingPage {
                            pageScrubberValue = Double(pageIndex)
                        }
                        onReadingPositionChange(
                            pageIndex,
                            record.contentRevisionID
                        )
                        scheduleReadingPositionSave(
                            pageIndex,
                            expectedContentRevisionID:
                                record.contentRevisionID
                        )
                    },
                    onCommandMessage: { message in
                        model[noticeFor: paperPathSceneID] = message
                    },
                    unlockPassword: activeSessionPassword,
                    onUnlock: { success in
                        handlePDFUnlockResult(
                            success,
                            expectedPassword:
                                activeSessionPassword,
                            generation:
                                activeSessionGeneration
                        )
                    }
                )
                .background(PPColor.documentStage)
                .padding(
                    .horizontal,
                    horizontalSizeClass == .regular
                        && !isImmersiveReading
                        ? PPSpacing.large
                        : 0
                )
                .padding(
                    .bottom,
                    isImmersiveReading ? 0 : PPSpacing.small
                )
                .accessibilityIdentifier("pdfWorkspace")
                .overlay(alignment: .topTrailing) {
                    if model.isProcessing(recordID)
                        || model.isAnalyzing(recordID)
                        || unlockCopyTask != nil
                        || workspaceMetadataTask != nil {
                        processingPill
                            .padding(PPSpacing.regular)
                    }
                }
                .overlay {
                    if record.profile.isLocked && !isSessionUnlocked {
                        lockedDocumentOverlay
                    }
                }
            }

                if isImmersiveReading {
                    Button {
                        setImmersiveReading(false)
                    } label: {
                        Image(
                            systemName:
                                "arrow.down.right.and.arrow.up.left"
                        )
                        .font(.body.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .stroke(
                                    PPColor.border.opacity(0.68),
                                    lineWidth: 0.7
                                )
                        }
                        .shadow(
                            color: .black.opacity(0.16),
                            radius: 10,
                            y: 4
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .padding(PPSpacing.regular)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomTrailing
                    )
                    .transition(.opacity)
                    .accessibilityLabel(
                        "Exit immersive reading".localizedUI
                    )
                    .accessibilityHint(
                        "Returns the document controls without changing your page."
                            .localizedUI
                    )
                    .accessibilityIdentifier("exitImmersiveReading")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isImmersiveReading {
                    actionBar(record: record)
                }
            }
            .toolbar(
                isImmersiveReading ? .hidden : .visible,
                for: .navigationBar
            )
            .statusBarHidden(isImmersiveReading)
            .sensoryFeedback(.selection, trigger: isImmersiveReading)
            .accessibilityAction(.escape) {
                handleWorkspaceEscape()
            }
            .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPrivacyScanPresented = true
                } label: {
                    Label(
                        "Privacy Scan".localizedUI,
                        systemImage: "checkmark.shield"
                    )
                }
                .help("Privacy Scan".localizedUI)
                .accessibilityLabel("Privacy Scan".localizedUI)
                .accessibilityHint(
                    privacyScanAvailabilityHint(for: record)
                )
                .accessibilityIdentifier("privacyScanButton")
                .sheet(
                    isPresented: $isPrivacyScanPresented,
                    onDismiss: handleWorkspacePresentationDismissal
                ) {
                    PrivacyScanWorkspaceSheet(
                        reviewModel: privacyScanReviewModel,
                        recordID: recordID,
                        contentRevisionID: record.contentRevisionID,
                        sourceURL: url,
                        estimatedPageCount: record.profile.pageCount,
                        documentName: record.displayName,
                        textIndex: model.textIndices[recordID],
                        onLocate: { finding in
                            locatePrivacyFinding(
                                finding,
                                contentRevisionID:
                                    record.contentRevisionID
                            )
                        },
                        onOpenDocument: { route in
                            queueWorkspaceHandoff(.openDocument(route))
                            isPrivacyScanPresented = false
                        }
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
                .disabled(
                    record.profile.isLocked
                        || model.isProcessing(recordID)
                )
            }
                ToolbarItem(placement: .principal) {
                    if hasDocumentRelationship(record) {
                        Menu {
                            Section(record.displayName) {
                                documentRelationshipMenuCommands(record)
                                Button {
                                    presentedSheet = .deliveryHistory
                                } label: {
                                    Label(
                                        "Delivery history",
                                        systemImage: "clock.badge.checkmark"
                                    )
                                }
                            }
                        } label: {
                            workspaceTitle(record, showsRelationship: true)
                        }
                        .accessibilityIdentifier("workspaceRelatedDocumentsMenu")
                        .disabled(hasBlockingWorkspaceControlTask)
                    } else {
                        workspaceTitle(record, showsRelationship: false)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            presentedSheet = .find
                        } label: {
                            Label(
                                "Find in Document",
                                systemImage: "text.magnifyingglass"
                            )
                        }
                        .keyboardShortcut("f", modifiers: .command)

                        Button {
                            presentedSheet = .tools
                        } label: {
                            Label("All tools", systemImage: "wrench.and.screwdriver")
                        }
                        .keyboardShortcut("t", modifiers: .command)

                        Menu("Workspace tools".localizedUI) {
                            ForEach(ToolMode.allCases) { mode in
                                Button {
                                    savedToolMode = mode.rawValue
                                } label: {
                                    Label(mode.title.localizedUI, systemImage: mode == toolMode ? "checkmark" : "circle")
                                }
                                .keyboardShortcut(mode.shortcut, modifiers: [.command, .control])
                            }
                        }
                        .disabled(isRedactionMode)

                        Menu {
                            Button {
                                presentedSheet = .reading
                            } label: {
                                Label(
                                    "Reading Settings",
                                    systemImage: "textformat.size"
                                )
                            }
                            Button {
                                toggleImmersiveReading()
                            } label: {
                                Label(
                                    isImmersiveReading
                                        ? "Exit immersive reading"
                                        : "Immersive Reading",
                                    systemImage:
                                        "arrow.up.left.and.arrow.down.right"
                                )
                            }
                            .keyboardShortcut(
                                "i",
                                modifiers: [.command, .shift]
                            )
                            Menu {
                                Button {
                                    runViewportCommand(.zoomIn)
                                } label: {
                                    Label(
                                        "Zoom In",
                                        systemImage: "plus.magnifyingglass"
                                    )
                                }
                                .keyboardShortcut(
                                    "+",
                                    modifiers: .command
                                )

                                Button {
                                    runViewportCommand(.zoomOut)
                                } label: {
                                    Label(
                                        "Zoom Out",
                                        systemImage: "minus.magnifyingglass"
                                    )
                                }
                                .keyboardShortcut(
                                    "-",
                                    modifiers: .command
                                )

                                Button {
                                    runViewportCommand(.fitToWindow)
                                } label: {
                                    Label(
                                        "Fit to Window",
                                        systemImage: "viewfinder"
                                    )
                                }
                                .keyboardShortcut(
                                    "0",
                                    modifiers: .command
                                )
                            } label: {
                                Label(
                                    "Zoom",
                                    systemImage: "plus.magnifyingglass"
                                )
                            }
                            Button {
                                presentedSheet = .reader
                            } label: {
                                Label(
                                    "Focus Reader",
                                    systemImage: "text.alignleft"
                                )
                            }
                        } label: {
                            Label("Reading", systemImage: "book")
                        }
                        Button {
                            presentedSheet = .bookmarks
                        } label: {
                            Label(
                                "Navigate",
                                systemImage: "bookmark"
                            )
                            .accessibilityIdentifier(
                                "workspaceNavigateAction"
                            )
                        }
                        Button {
                            presentedSheet = .privateNote
                        } label: {
                            Label(
                                record.privateNote == nil
                                    ? "Add Private Note"
                                    : "Edit Private Note",
                                systemImage: "note.text"
                            )
                        }
                        if let previousDocument =
                                recentDocuments.first {
                            Divider()

                            Button {
                                openRecentDocument(previousDocument)
                            } label: {
                                Label(
                                    "Previously Viewed Document",
                                    systemImage: "arrow.left.arrow.right"
                                )
                            }
                            .keyboardShortcut(
                                .tab,
                                modifiers: .control
                            )
                            .accessibilityHint(
                                AppLocalization.format(
                                    "Switches to %@",
                                    previousDocument.displayName
                                )
                            )

                            Menu("Recent Documents") {
                                ForEach(recentDocuments) { recentRecord in
                                    Button {
                                        openRecentDocument(recentRecord)
                                    } label: {
                                        Label(
                                            "\(recentRecord.displayName) · p\(recentRecord.lastPageIndex + 1)",
                                            systemImage: recentRecord.profile
                                                .kind.symbol
                                        )
                                    }
                                }
                            }
                        }

                        if UIDevice.current.userInterfaceIdiom == .pad {
                            Divider()

                            Button {
                                openCurrentDocumentInNewWindow(
                                    record.id
                                )
                            } label: {
                                Label(
                                    "Open in New Window",
                                    systemImage: "macwindow.badge.plus"
                                )
                            }
                            .accessibilityHint(
                                "Opens this PDF in a separate iPad window."
                                    .localizedUI
                            )
                            .keyboardShortcut(
                                "n",
                                modifiers: [.command, .shift]
                            )
                            .help("Open in New Window".localizedUI)
                        }
                    } label: {
                        Image(systemName: "book.pages")
                    }
                    .accessibilityLabel(
                        "Reading and navigation".localizedUI
                    )
                    .accessibilityIdentifier(
                        "workspaceNavigationMenu"
                    )
                    .disabled(hasBlockingWorkspaceControlTask)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Menu {
                            Menu("Move to") {
                                ForEach(DocumentWorkflowStatus.allCases) { status in
                                    Button {
                                        updateWorkflow(status)
                                    } label: {
                                        Label(
                                            status.title.localizedUI,
                                            systemImage: status.symbol
                                        )
                                    }
                                }
                            }

                            Button {
                                togglePinned(
                                    expectedIsPinned:
                                        record.isPinned
                                )
                            } label: {
                                Label(
                                    record.isPinned ? "Unpin" : "Pin",
                                    systemImage: record.isPinned
                                        ? "pin.slash"
                                        : "pin"
                                )
                            }

                            Button {
                                originalName = record.displayName
                                proposedName = record.displayName
                                isRenaming = true
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                        } label: {
                            Label("Organize", systemImage: "folder")
                        }

                        Button {
                            presentedSheet = record.brief == nil ? .insight : .brief
                        } label: {
                            Label(
                                "Document details",
                                systemImage: "info.circle"
                            )
                        }

                        Menu {
                            Button {
                                presentedSheet = .versionHistory
                            } label: {
                                Label(
                                    "Version History",
                                    systemImage: "clock.arrow.circlepath"
                                )
                            }

                            Button {
                                presentedSheet = .sourceLocation
                            } label: {
                                Label(
                                    "File location & source",
                                    systemImage: "folder.badge.gearshape"
                                )
                            }

                            Button {
                                presentedSheet = .technicalInspector
                            } label: {
                                Label(
                                    "Technical details",
                                    systemImage: "doc.text.magnifyingglass"
                                )
                            }
                        } label: {
                            Label(
                                "History & source",
                                systemImage: "clock.arrow.circlepath"
                            )
                        }

                        let historyOutputs = model.deliveryHistoryOutputs(
                            for: record.id
                        )
                        if record.deliveryReceipt != nil
                            || record.receivedPackageProvenance != nil
                            || !historyOutputs.isEmpty {
                            Menu {
                                if record.deliveryReceipt != nil {
                                    Button {
                                        presentedSheet = .deliveryReceipt
                                    } label: {
                                        Label(
                                            "Delivery receipt",
                                            systemImage: "checkmark.seal"
                                        )
                                    }
                                }

                                if record.receivedPackageProvenance != nil {
                                    Button {
                                        presentedSheet = .receivedPackage
                                    } label: {
                                        Label(
                                            "Received Package",
                                            systemImage: "shippingbox"
                                        )
                                    }
                                }

                                if !historyOutputs.isEmpty {
                                    Button {
                                        presentedSheet = .deliveryHistory
                                    } label: {
                                        Label(
                                            AppLocalization.format(
                                                "Delivery history (%lld)",
                                                historyOutputs.count
                                            ),
                                            systemImage: "clock.badge.checkmark"
                                        )
                                    }
                                }
                            } label: {
                                Label(
                                    "Results",
                                    systemImage: "checkmark.seal"
                                )
                            }
                        }

                        Button {
                            printDocument(record: record, url: url)
                        } label: {
                            Label(
                                "Print Working Copy",
                                systemImage: "printer"
                            )
                        }
                        .keyboardShortcut("p", modifiers: .command)

                        Button(role: .destructive) {
                            isConfirmingDelete = true
                        } label: {
                            Label("Move to Trash", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Document menu".localizedUI)
                    .disabled(hasBlockingWorkspaceControlTask)
                }
            }
        )
        .navigationTitle(record.displayName)

        let workspaceSheets = AnyView(
            workspaceChrome
                .sheet(
                    item: $presentedSheet,
                    onDismiss: handleWorkspacePresentationDismissal
                ) { sheet in
                    AnyView(
                        Group {
                            switch sheet {
                            case .brief:
                                DocumentBriefView(
                                    recordID: recordID,
                                    onOpenPage: { pageIndex in
                                        showPage(
                                            pageIndex,
                                            message: "Showing supporting evidence"
                                        )
                                    },
                                    onStep: { step, pageIndex in
                                        handle(step, pageIndex: pageIndex)
                                    }
                                )
                                .presentationDetents([.medium, .large])
                                .presentationDragIndicator(.visible)
                            case .insight:
                                DocumentInsightView(record: record) { action in
                                    queueWorkspaceHandoff(.action(action))
                                }
                                    .presentationDetents([.medium, .large])
                                    .presentationDragIndicator(.visible)
                            case .pages:
                                PageOrganizerView(
                                    recordID: recordID,
                                    startInSelectionMode: pageOrganizerStartsSelecting,
                                    initialSelectedPageIndices:
                                        pageOrganizerInitialSelection,
                                    onCreated: openCreatedDocument,
                                    onPrepare: {
                                        openSafeShareAfterDismissal()
                                        presentedSheet = nil
                                    }
                                )
                                    .presentationDetents([.large])
                                    .presentationDragIndicator(.visible)
                            case .recognizedText:
                                RecognizedTextView(
                                    recordID: recordID,
                                    onCreated: openCreatedDocument,
                                    onOpenPage: { pageIndex in
                                        showPage(
                                            pageIndex,
                                            message: "Reviewing recognized text"
                                        )
                                    },
                                    onRecognizeAgain: {
                                        openRecognitionSettings(
                                            afterDismissal: true
                                        )
                                    }
                                )
                                    .presentationDetents([.large])
                                    .presentationDragIndicator(.visible)
                            case .share:
                                ShareSheet(items: shareItems)
                                    .presentationDetents([.medium, .large])
                            case .tools:
                                DocumentToolPalette(
                                    recordTitle: record.displayName,
                                    availableTools: availableTools(for: record),
                                    unavailableReasons: unavailableToolReasons(
                                        for: record
                                    ),
                                    recentTools: recentTools,
                                    contextualTools: contextualTools(for: record),
                                    contextualReasons: contextualToolReasons(
                                        for: record
                                    ),
                                    onSelect: { tool in
                                        queueWorkspaceHandoff(.tool(tool))
                                    }
                                )
                                .presentationDetents([.large])
                            case .stamp:
                                StampPickerView(pageIndex: currentPageIndex) { kind in
                                    queueWorkspaceHandoff(
                                        .stamp(
                                            kind,
                                            pageIndex: currentPageIndex,
                                            contentRevisionID:
                                                record.contentRevisionID
                                        )
                                    )
                                }
                                .presentationDetents([.medium, .large])
                            case .watermark:
                                WatermarkSheet(
                                    pageCount: record.profile.pageCount,
                                    onApply: { payload in
                                        await model.withFeedbackTarget(
                                            paperPathSceneID
                                        ) {
                                            await model.applyWatermark(
                                                recordID: recordID,
                                                payload: payload
                                            )
                                        }
                                    },
                                    onRemoveAll: {
                                        await model.withFeedbackTarget(
                                            paperPathSceneID
                                        ) {
                                            await model
                                                .removeGeneratedWatermarks(
                                                    recordID: recordID
                                                )
                                        }
                                    }
                                )
                                .presentationDetents([.large])
                            case .bates:
                                BatesNumberingSheet(
                                    pageCount: record.profile.pageCount,
                                    onApply: { payload in
                                        await model.withFeedbackTarget(
                                            paperPathSceneID
                                        ) {
                                            await model.applyBatesNumbers(
                                                recordID: recordID,
                                                payload: payload
                                            )
                                        }
                                    },
                                    onRemoveAll: {
                                        await model.withFeedbackTarget(
                                            paperPathSceneID
                                        ) {
                                            await model
                                                .removeGeneratedBatesNumbers(
                                                    recordID: recordID
                                                )
                                        }
                                    }
                                )
                                .presentationDetents([.large])
                            case .compression:
                                CompressionSheet(
                                    recordID: recordID,
                                    onCreated: openCreatedDocument
                                )
                            case .protection:
                                ProtectionSheet(
                                    recordID: recordID,
                                    onCreated: openCreatedDocument
                                )
                            case .redaction:
                                RedactionReviewSheet(
                                    recordID: recordID,
                                    marks: $redactionMarks,
                                    onReviewPage: { pageIndex in
                                        showPage(
                                            pageIndex,
                                            message: "Reviewing redaction area"
                                        )
                                    },
                                    onCreated: { route in
                                        redactionMarks = []
                                        openCreatedDocument(route)
                                    }
                                )
                            case .export, .officeExport, .imageExport, .verifiedExport:
                                DocumentExportSheet(
                                    recordID: recordID,
                                    focus: sheet.exportFocus,
                                    onCreated: openCreatedDocument,
                                    onReviewPage: {
                                        pageIndex,
                                        checkpointSaved in
                                        showPage(
                                            pageIndex,
                                            message:
                                                checkpointSaved
                                                    ? "Reviewing preflight issue"
                                                    : "Reviewing preflight issue · resume point not saved"
                                        )
                                    },
                                    onRepairPreflightItem: {
                                        action,
                                        pageIndex,
                                        checkpointSaved in
                                        switch action {
                                        case .organizePages:
                                            guard let pageIndex else {
                                                model[noticeFor: paperPathSceneID] =
                                                    "The issue page could not be located"
                                                        .localizedUI
                                                return
                                            }
                                            pageOrganizerStartsSelecting = false
                                            pageOrganizerInitialSelection = [pageIndex]
                                            model[noticeFor: paperPathSceneID] =
                                                (
                                                    checkpointSaved
                                                        ? "Blank page selected for review"
                                                        : "Opening Pages · resume point not saved"
                                                ).localizedUI
                                            queueWorkspaceHandoff(
                                                .presentSheet(.pages)
                                            )
                                        case .createEditableCopy:
                                            queueWorkspaceHandoff(
                                                .unlockForVerifiedOutput
                                            )
                                        }
                                    }
                                )
                            case .reading:
                                ReadingSettingsSheet(preferences: $readingPreferences)
                                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                            case .privateNote:
                                DocumentPrivateNoteView(recordID: recordID)
                                    .presentationDetents([.medium, .large])
                            case .bookmarks:
                                BookmarksSheet(
                                    recordID: recordID,
                                    currentPageIndex: currentPageIndex,
                                    onSelect: { pageIndex in
                                        showPage(
                                            pageIndex,
                                            message: "Opened bookmark"
                                        )
                                    },
                                    onCreated: { route in
                                        openCreatedDocument(route)
                                    }
                                )
                            case .formReview:
                                FormReviewView(
                                    recordID: recordID,
                                    initialPageIndex: currentPageIndex,
                                    onSelectPage: {
                                        pageIndex,
                                        checkpointSaved in
                                        showPage(
                                            pageIndex,
                                            message:
                                                checkpointSaved
                                                    ? "Opened form field"
                                                    : "Opened form field · resume point not saved"
                                        )
                                    },
                                    onSignField: {
                                        field,
                                        checkpointSaved in
                                        showPageThenSignature(
                                            field.pageIndex,
                                            initialBounds: field.normalizedBounds,
                                            fieldName: field.name,
                                            navigationMessage:
                                                checkpointSaved
                                                    ? "Signature evidence"
                                                    : "Opening signature · resume point not saved",
                                            updatesCheckpoint: false
                                        )
                                    },
                                    onPrepare: {
                                        openSafeShareAfterDismissal()
                                        presentedSheet = nil
                                    }
                                )
                            case .find:
                                DocumentFindView(
                                    recordID: recordID,
                                    initialQuery: documentFindQuery,
                                    initialHistory: documentFindHistory,
                                    initialSelectedPageIndex:
                                        pdfSearchHighlight?.query
                                            == documentFindQuery
                                        ? pdfSearchHighlight?.pageIndex
                                        : nil,
                                    onQueryChange: { documentFindQuery = $0 },
                                    onHistoryChange: { documentFindHistory = $0 },
                                    onRecognizeText: {
                                        openRecognitionSettings(afterDismissal: true)
                                    }
                                ) {
                                    result,
                                    query in
                                    guard let result else {
                                        pdfSearchHighlight = nil
                                        return
                                    }
                                    pdfSearchHighlight = PDFTextSearchHighlight(
                                        query: query,
                                        pageIndex: result.pageIndex,
                                        contentRevisionID:
                                            record.contentRevisionID
                                    )
                                    showPage(
                                        result.pageIndex,
                                        message: "Previewing search result",
                                        dismissesPresentedSheet: false
                                    )
                                }
                                .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
                                .presentationDragIndicator(.visible)
                            case .annotations:
                                AnnotationReviewView(recordID: recordID) { pageIndex in
                                    showPage(pageIndex, message: "Opened annotation")
                                }
                            case .attachments:
                                PDFAttachmentsView(recordID: recordID) { pageIndex in
                                    showPage(pageIndex, message: "Opened page attachment")
                                }
                            case .compare:
                                CompareVersionsView(
                                    sourceRecordID: recordID,
                                    onOpenRoute: { route in
                                        queueWorkspaceHandoff(
                                            .openDocument(route)
                                        )
                                    }
                                )
                            case .deliveryReceipt:
                                DeliveryReceiptView(
                                    recordID: recordID,
                                    onOpenRoute: { route in
                                        queueWorkspaceHandoff(
                                            .openDocument(route)
                                        )
                                    }
                                )
                            case .deliveryHistory:
                                DeliveryHistoryView(
                                    sourceRecordID: recordID,
                                    onOpen: { route in
                                        queueWorkspaceHandoff(.openDocument(route))
                                    },
                                    onVerify: {
                                        queueWorkspaceHandoff(.safeShare)
                                    }
                                )
                            case .receivedPackage:
                                ReceivedPackageProvenanceView(
                                    recordID: recordID,
                                    onVerify: {
                                        queueWorkspaceHandoff(.safeShare)
                                    }
                                )
                                .presentationDetents([.medium, .large])
                                .presentationDragIndicator(.visible)
                            case .sourceLocation:
                                SourceLocationView(
                                    recordID: recordID,
                                    onOpenDocument: openCreatedDocument
                                )
                            case .technicalInspector:
                                PDFTechnicalInspectorView(
                                    recordID: recordID,
                                    unlockPassword: sessionPassword
                                )
                            case .versionHistory:
                                PDFVersionHistoryView(
                                    recordID: recordID,
                                    onOpenPage: openChangedPage
                                )
                            case .reader:
                                FocusReaderSheet(
                                    recordID: recordID,
                                    initialPageIndex: currentPageIndex,
                                    onOpenPage: { pageIndex in
                                        showPage(
                                            pageIndex,
                                            message: "Opened from Focus Reader"
                                        )
                                    },
                                    onRecognizeText: {
                                        openRecognitionSettings(afterDismissal: true)
                                    }
                                )
                            }
                        }
                    )
                }
                .sheet(
                    isPresented: $isConfiguringRecognition,
                    onDismiss: completeRecognitionConfigurationDismissal
                ) {
                    OCRConfigurationSheet(
                        recordID: recordID,
                        initialConfiguration: recognitionConfiguration
                    ) { configuration in
                        recognitionConfiguration = configuration
                        pendingRecognitionConfiguration = configuration
                        isConfiguringRecognition = false
                    }
                    .id(recognitionConfiguration)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
        )

        let workspaceEditors = AnyView(
            workspaceSheets
                .fullScreenCover(
                    isPresented: $isPresentingSignature,
                    onDismiss: {
                        signaturePageIndex = nil
                        signatureInitialBounds = nil
                        handleWorkspacePresentationDismissal()
                    }
                ) {
                    InkCaptureView(
                        recordID: recordID,
                        pageIndex: signaturePageIndex ?? currentPageIndex,
                        mode: .signature,
                        initialSignatureBounds: signatureInitialBounds
                    ) {
                        openSafeShareAfterDismissal()
                    }
                }
                .fullScreenCover(
                    isPresented: $isPresentingPencil,
                    onDismiss: handleWorkspacePresentationDismissal
                ) {
                    InkCaptureView(
                        recordID: recordID,
                        pageIndex: currentPageIndex,
                        mode: .drawing
                    )
                }
                .fullScreenCover(
                    isPresented: $isPresentingContentEditor,
                    onDismiss: handleWorkspacePresentationDismissal
                ) {
                    PDFContentEditorView(
                        recordID: recordID,
                        pageIndex: currentPageIndex,
                        onCreated: openCreatedDocument
                    )
                }
                .fullScreenCover(
                    isPresented: $isPresentingLinkEditor,
                    onDismiss: handleWorkspacePresentationDismissal
                ) {
                    PDFLinkEditorView(
                        recordID: recordID,
                        pageIndex: currentPageIndex,
                        onCreated: openCreatedDocument
                    )
                }
                .fullScreenCover(
                    isPresented: $isPresentingImageReplacement,
                    onDismiss: handleWorkspacePresentationDismissal
                ) {
                    PDFImageReplacementView(
                        recordID: recordID,
                        pageIndex: currentPageIndex,
                        onCreated: openCreatedDocument
                    )
                }
                .fullScreenCover(
                    item: $textSelectionForReplacement,
                    onDismiss: handleWorkspacePresentationDismissal
                ) { selection in
                    PDFTextReplacementView(
                        recordID: recordID,
                        selection: selection,
                        onCreated: openCreatedDocument
                    )
                }
        )

        return AnyView(
            workspaceEditors
                .alert("Rename working copy", isPresented: $isRenaming) {
                    TextField("Document name", text: $proposedName)
                        .focused($renameFieldFocused)
                        .submitLabel(.done)
                        .onSubmit {
                            renameWorkingCopy()
                        }
                    Button("Cancel", role: .cancel) {}
                    Button("Save") {
                        renameWorkingCopy()
                    }
                    .disabled(
                        workspaceMetadataTask != nil
                            || proposedName
                                .trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                                .isEmpty
                    )
                } message: {
                    Text("This changes only the name inside PaperPath.")
                }
                .alert("Go to page", isPresented: $isJumpingToPage) {
                    TextField("Page number", text: $pageJumpInput)
                        .keyboardType(.numberPad)
                        .focused($pageJumpFieldFocused)
                        .submitLabel(.go)
                        .onSubmit {
                            jumpToEnteredPage()
                        }
                    Button("Cancel", role: .cancel) {
                        pageJumpInput = ""
                    }
                    Button("Go") {
                        jumpToEnteredPage()
                    }
                    .disabled(!pageJumpIsValid)
                } message: {
                    Text(
                        AppLocalization.format(
                            "Enter a page from 1 to %lld.",
                            model.record(id: recordID)?.profile.pageCount ?? 1
                        )
                    )
                }
                .confirmationDialog(
                    "Move this private copy to Trash?",
                    isPresented: $isConfirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Move to Trash", role: .destructive) {
                        moveWorkingCopyToTrash()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "The copy remains recoverable. The original imported file stays untouched."
                    )
                }
                .sheet(
                    isPresented: $isAddingNote,
                    onDismiss: commitPendingNote
                ) {
                    NoteComposerSheet(pageIndex: currentPageIndex) { value in
                        pendingNote = value
                        isAddingNote = false
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
                .sheet(
                    isPresented: $isUnlocking,
                    onDismiss: {
                        cancelUnlockValidation()
                        unlockInput = ""
                        unlockErrorMessage = nil
                        if sessionPassword == nil {
                            continuesVerifiedOutputAfterUnlock = false
                        }
                    }
                ) {
                    NavigationStack {
                        Form {
                            Section {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: PPSpacing.small) {
                                        unlockPasswordField
                                        unlockPasswordPasteButton
                                    }
                                    VStack(
                                        alignment: .trailing,
                                        spacing: PPSpacing.small
                                    ) {
                                        unlockPasswordField
                                        unlockPasswordPasteButton
                                    }
                                }
                            } footer: {
                                VStack(
                                    alignment: .leading,
                                    spacing: PPSpacing.xSmall
                                ) {
                                    if let unlockErrorMessage {
                                        Label(
                                            unlockErrorMessage.localizedUI,
                                            systemImage:
                                                "exclamationmark.circle.fill"
                                        )
                                        .foregroundStyle(Color(uiColor: .systemRed))
                                        .accessibilityIdentifier(
                                            "protectedPDFUnlockError"
                                        )
                                    }
                                    Text(
                                        (
                                            continuesVerifiedOutputAfterUnlock
                                                ? "Unlocks into a separate copy. The encrypted original stays unchanged."
                                                : "The password is kept only while this PDF is open."
                                        ).localizedUI
                                    )
                                }
                            }
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .navigationTitle(
                            (
                                continuesVerifiedOutputAfterUnlock
                                    ? "Unlock for verified output"
                                    : "Unlock protected PDF"
                            ).localizedUI
                        )
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel", role: .cancel) {
                                    cancelUnlockValidation()
                                    continuesVerifiedOutputAfterUnlock = false
                                    isUnlocking = false
                                }
                                .keyboardShortcut(.cancelAction)
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button {
                                    submitProtectedDocumentPassword()
                                } label: {
                                    if unlockValidationTask != nil {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text("Unlock")
                                    }
                                }
                                .disabled(
                                    unlockInput.isEmpty
                                        || unlockValidationTask != nil
                                )
                                .accessibilityLabel(
                                    unlockValidationTask == nil
                                        ? "Unlock"
                                        : "Checking password"
                                )
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                    }
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                    .task {
                        await Task.yield()
                        unlockFieldFocused = true
                    }
                }
                .onAppear {
                    restoreReadingPreferences()
                }
                .onChange(of: readingPreferences) { _, preferences in
                    guard didRestoreReadingPreferences else { return }
                    savedReadingTheme = preferences.theme.rawValue
                    savedReadingLayout = preferences.layout.rawValue
                    savedHorizontalNavigation = preferences.scrollsHorizontally
                }
                .onChange(of: proposedName) { _, value in
                    if value.count > 80 {
                        proposedName = String(value.prefix(80))
                    }
                }
                .onChange(of: isRenaming) { _, isPresented in
                    guard isPresented else {
                        renameFieldFocused = false
                        return
                    }
                    Task { @MainActor in
                        await Task.yield()
                        guard isRenaming,
                              scenePhase == .active,
                              UIApplication.shared
                                .isProtectedDataAvailable
                        else { return }
                        renameFieldFocused = true
                    }
                }
                .onChange(of: isJumpingToPage) { _, isPresented in
                    guard isPresented else {
                        pageJumpFieldFocused = false
                        return
                    }
                    Task { @MainActor in
                        await Task.yield()
                        guard isJumpingToPage,
                              scenePhase == .active,
                              UIApplication.shared
                                .isProtectedDataAvailable
                        else { return }
                        pageJumpFieldFocused = true
                    }
                }
                .onChange(of: pageJumpInput) { _, value in
                    let digits = value.filter(\.isNumber)
                    if digits != value {
                        pageJumpInput = String(digits.prefix(6))
                    } else if value.count > 6 {
                        pageJumpInput = String(value.prefix(6))
                    }
                }
                .onChange(of: unlockInput) { _, value in
                    if value.count > 128 {
                        unlockInput = String(value.prefix(128))
                    }
                    unlockErrorMessage = nil
                }
                .onChange(
                    of: model.record(id: recordID)?.profile.pageCount
                ) { _, pageCount in
                    reconcilePageState(pageCount: pageCount)
                }
                .onChange(of: record.contentRevisionID) {
                    oldRevisionID,
                    newRevisionID in
                    privacyScanReviewModel.reset()
                    rebuildPageStateForUpdatedPDF(
                        from: oldRevisionID,
                        to: newRevisionID
                    )
                }
                .sensoryFeedback(
                    .success,
                    trigger: model.refreshToken(for: recordID)
                )
                .sensoryFeedback(.success, trigger: unlockSuccessFeedback)
                .sensoryFeedback(.selection, trigger: pageNavigationFeedback)
                .sensoryFeedback(.selection, trigger: workspaceHandoffFeedback)
                .sensoryFeedback(.error, trigger: unlockAttemptFeedback)
                .sensoryFeedback(.error, trigger: unlockCopyErrorFeedback)
                .sensoryFeedback(.success, trigger: metadataSuccessFeedback)
                .sensoryFeedback(.error, trigger: metadataErrorFeedback)
        )
    }

    private func locatePrivacyFinding(
        _ finding: PrivacyFinding,
        contentRevisionID: UUID
    ) {
        guard model.record(id: recordID)?.contentRevisionID
            == contentRevisionID
        else {
            model[noticeFor: paperPathSceneID] =
                "Document changed. Run the privacy scan again."
                    .localizedUI
            return
        }
        requestedPageIndex = finding.pageIndex
        pageNavigationToken += 1
        privacyEvidenceOverlay = PDFEvidenceOverlay(
            pageIndex: finding.pageIndex,
            regions: finding.normalizedBounds.map { bounds in
                PDFDifferenceRegion(
                    x: bounds.x,
                    y: 1 - bounds.y - bounds.height,
                    width: bounds.width,
                    height: bounds.height,
                    intensity: 1
                )
            },
            tone: .source,
            generation: pageNavigationToken
        )
        pdfSearchHighlight = PDFTextSearchHighlight(
            query: finding.rawValue,
            pageIndex: finding.pageIndex,
            contentRevisionID: contentRevisionID
        )
        model[noticeFor: paperPathSceneID] =
            AppLocalization.format(
                "Privacy candidate on page %lld · review preserved",
                finding.pageIndex + 1
            )
    }

    private func privacyScanAvailabilityHint(
        for record: DocumentRecord
    ) -> String {
        if record.profile.isLocked {
            return "Unlock this PDF before scanning for private information."
                .localizedUI
        }
        if model.isProcessing(recordID) {
            return "Wait for the current document operation to finish."
                .localizedUI
        }
        return "Scans this PDF on device before sharing.".localizedUI
    }

    private var lockedDocumentOverlay: some View {
        ViewThatFits(in: .vertical) {
            lockedDocumentCard
            ScrollView {
                lockedDocumentCard
                    .padding(.vertical, PPSpacing.small)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lockedDocumentCard: some View {
        VStack(spacing: PPSpacing.medium) {
            PPIllustration(kind: .locked, width: 156)
            Text("Protected PDF")
                .font(.title3.bold())
                .fontDesign(.serif)
            Text(
                (
                    isApplyingSessionUnlock
                        ? "Opening the protected PDF on this device."
                        : "Enter the document password to read it in this session."
                ).localizedUI
            )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .multilineTextAlignment(.center)
            if isApplyingSessionUnlock {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel(
                        "Opening protected PDF".localizedUI
                    )
                Button("Cancel", role: .cancel) {
                    clearProtectedDocumentSession()
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            } else {
                Button("Unlock") {
                    isUnlocking = true
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Share encrypted PDF") {
                share(recordID: recordID)
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PPColor.accent)
            .disabled(
                shareTask != nil
                    || isApplyingSessionUnlock
            )
            .accessibilityIdentifier("shareEncryptedPDF")
        }
        .padding(PPSpacing.xLarge)
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PPRadius.surface,
                style: .continuous
            )
        )
        .padding(PPSpacing.xLarge)
        .accessibilityElement(children: .contain)
    }

    private func unlockCopyRecoveryStrip(
        _ issue: PDFBatchDeliveryIssue
    ) -> some View {
        let layout = horizontalSizeClass == .compact
            || dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(
                HStackLayout(
                    alignment: .center,
                    spacing: PPSpacing.medium
                )
            )
        return layout {
            HStack(alignment: .top, spacing: PPSpacing.small) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PPColor.amber)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Editable copy not created")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    Text(issue.message.localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(issue.recovery.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)

            if !dynamicTypeSize.ppPrefersExpandedLayout {
                Spacer(minLength: 0)
            }

            HStack(spacing: PPSpacing.xSmall) {
                if issue.isRetryable {
                    Button {
                        retryUnlockedPrivateCopy()
                    } label: {
                        Label(
                            "Retry",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.amber)
                    )
                    .disabled(
                        unlockCopyTask != nil
                            || model.isProcessing(recordID)
                    )
                    .accessibilityHint(
                        "Retries with the password already verified for this session."
                            .localizedUI
                    )
                }
                Button {
                    dismissUnlockCopyIssue()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.textSecondary)
                .accessibilityLabel(
                    "Dismiss editable copy error".localizedUI
                )
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(PPColor.amber.opacity(0.08))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.amber.opacity(0.34))
                .frame(height: 0.7)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.amber.opacity(0.24))
                .frame(height: 0.7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("unlockCopyRecovery")
    }

    private var unlockPasswordField: some View {
        SecureField("Password", text: $unlockInput)
            .textContentType(.password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.go)
            .onSubmit {
                submitProtectedDocumentPassword()
            }
            .frame(minHeight: 44)
            .focused($unlockFieldFocused)
            .disabled(unlockValidationTask != nil)
    }

    private var unlockPasswordPasteButton: some View {
        PasteButton(payloadType: String.self) { values in
            guard let value = values.first else { return }
            unlockInput = String(value.prefix(128))
        }
        .frame(minWidth: 44, minHeight: 44)
        .disabled(unlockValidationTask != nil)
        .accessibilityHint(
            "Pastes the document password without storing it in PaperPath"
        )
    }

    private func submitProtectedDocumentPassword() {
        guard unlockValidationTask == nil,
              !unlockInput.isEmpty
        else { return }
        guard let url = model.url(for: recordID) else {
            unlockErrorMessage =
                "Working copy unavailable. Close and reopen the document."
            unlockAttemptFeedback += 1
            return
        }
        let password = unlockInput
        let generation = UUID()
        unlockValidationGeneration = generation
        unlockErrorMessage = nil
        unlockCopyIssue = nil
        unlockValidationTask = Task { @MainActor in
            defer {
                if unlockValidationGeneration == generation {
                    unlockValidationTask = nil
                }
            }
            let result = await Task.detached(
                priority: .userInitiated
            ) {
                autoreleasepool {
                    guard let document = PDFDocument(url: url) else {
                        return ProtectedPDFPasswordValidationResult
                            .unavailable
                    }
                    guard document.isLocked else {
                        return .valid
                    }
                    return document.unlock(withPassword: password)
                        ? .valid
                        : .invalid
                }
            }.value
            guard unlockValidationGeneration == generation,
                  !Task.isCancelled
            else { return }
            switch result {
            case .valid:
                sessionUnlockGeneration = UUID()
                sessionPassword = password
                isSessionUnlocked = false
                isApplyingSessionUnlock = true
                unlockInput = ""
                isUnlocking = false
            case .invalid:
                sessionUnlockGeneration = UUID()
                sessionPassword = nil
                isSessionUnlocked = false
                isApplyingSessionUnlock = false
                unlockErrorMessage =
                    "The password didn’t match. Check it and try again."
                unlockAttemptFeedback += 1
                unlockFieldFocused = true
            case .unavailable:
                isApplyingSessionUnlock = false
                unlockErrorMessage =
                    "Working copy unavailable. Close and reopen the document."
                unlockAttemptFeedback += 1
            }
        }
    }

    private func handlePDFUnlockResult(
        _ success: Bool,
        expectedPassword: String?,
        generation: UUID
    ) {
        guard generation == sessionUnlockGeneration,
              let expectedPassword,
              !expectedPassword.isEmpty,
              sessionPassword == expectedPassword
        else { return }

        if success {
            isSessionUnlocked = true
            isApplyingSessionUnlock = false
            unlockInput = ""
            unlockErrorMessage = nil
            unlockCopyIssue = nil
            if confirmedSessionUnlockGeneration != generation {
                confirmedSessionUnlockGeneration = generation
                unlockSuccessFeedback += 1
                model[noticeFor: paperPathSceneID] =
                    "Protected PDF unlocked for this session"
                        .localizedUI
            }
            if continuesVerifiedOutputAfterUnlock {
                createUnlockedPrivateCopy()
            }
            return
        }

        sessionUnlockGeneration = UUID()
        confirmedSessionUnlockGeneration = nil
        sessionPassword = nil
        isSessionUnlocked = false
        isApplyingSessionUnlock = false
        unlockInput = expectedPassword
        unlockCopyIssue = nil
        unlockErrorMessage =
            "The PDF could not be opened with that password. Check it and try again."
        unlockAttemptFeedback += 1
        Task { @MainActor in
            await Task.yield()
            guard sessionPassword == nil,
                  !isSessionUnlocked
            else { return }
            isUnlocking = true
            await Task.yield()
            unlockFieldFocused = true
        }
    }

    private func cancelUnlockValidation() {
        unlockValidationGeneration = UUID()
        unlockValidationTask?.cancel()
        unlockValidationTask = nil
    }

    private func readingProgressStrip(
        _ record: DocumentRecord
    ) -> some View {
        let progress = min(
            1,
            max(
                0,
                Double(currentPageIndex + 1)
                    / Double(max(record.profile.pageCount, 1))
            )
        )
        let percentage = Int((progress * 100).rounded())
        let minutes = estimatedMinutesRemaining(record)
        let readingLabel = AppLocalization.format(
            "%lld%% read",
            percentage
        )
        let remainingLabel = minutes > 0
            ? AppLocalization.format("~%lld min left", minutes)
            : "Final page".localizedUI
        let accessibilityLabel = minutes > 0
            ? AppLocalization.format(
                "%lld percent read. Approximately %lld minutes remaining.",
                percentage,
                minutes
            )
            : AppLocalization.format(
                "%lld percent read. Final page.",
                percentage
            )

        return VStack(spacing: 5) {
            HStack {
                Label(
                    readingLabel,
                    systemImage: "book.pages"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .monospacedDigit()
                Spacer()
                Text(remainingLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(PPColor.surfaceMuted)
                    Capsule()
                        .fill(PPColor.cyan)
                        .frame(
                            width: proxy.size.width * progress
                        )
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func estimatedMinutesRemaining(
        _ record: DocumentRecord
    ) -> Int {
        let remainingPages = max(
            0,
            record.profile.pageCount - currentPageIndex - 1
        )
        guard remainingPages > 0 else { return 0 }

        if let index = model.textIndices[recordID] {
            var remainingCharacters = 0
            for page in index.pages
            where page.pageIndex > currentPageIndex {
                remainingCharacters += page.text.count
            }
            if remainingCharacters > 0 {
                return max(
                    1,
                    Int(
                        ceil(
                            Double(remainingCharacters) / 1_050
                        )
                    )
                )
            }
        }
        return max(
            1,
            Int(ceil(Double(remainingPages) * 1.5))
        )
    }

    private func hasDocumentRelationship(
        _ record: DocumentRecord
    ) -> Bool {
        record.isDeliveryArtifact
            || !model.deliveryHistoryOutputs(for: record.id).isEmpty
    }

    private func documentRelationshipRoleTitle(
        _ record: DocumentRecord
    ) -> String {
        record.isDeliveryArtifact ? "Result copy" : "Working copy"
    }

    private func workspaceTitle(
        _ record: DocumentRecord,
        showsRelationship: Bool
    ) -> some View {
        VStack(spacing: 2) {
            Text(record.displayName)
                .font(PPType.document)
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
                .accessibilityIdentifier("workspaceDocumentTitle")
            if showsRelationship {
                HStack(spacing: 4) {
                    Text(documentRelationshipRoleTitle(record).localizedUI)
                        .accessibilityIdentifier("documentRelationshipRole")
                    Image(systemName: "chevron.down")
                        .accessibilityHidden(true)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(documentRelationshipTint(record))
                .lineLimit(1)
            } else if horizontalSizeClass == .regular {
                Text(record.subtitle)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(minHeight: PPDeskLayout.touchTarget)
    }

    private func documentRelationshipTint(
        _ record: DocumentRecord
    ) -> Color {
        record.isDeliveryArtifact ? PPColor.mint : PPColor.cyan
    }

    @ViewBuilder
    private func documentRelationshipMenuCommands(
        _ record: DocumentRecord
    ) -> some View {
        if record.isDeliveryArtifact {
            if let source = model.sourceRecord(for: record) {
                Button {
                    openRecentDocument(source)
                } label: {
                    Label(
                        AppLocalization.format(
                            "Open source: %@",
                            source.displayName
                        ),
                        systemImage: "arrow.left"
                    )
                }
                .accessibilityIdentifier(
                    "documentRelationshipOpenSource"
                )
            } else {
                Label(
                    "Source unavailable".localizedUI,
                    systemImage: "exclamationmark.triangle"
                )
            }
        } else if let latest = model.deliveryHistoryOutputs(
            for: record.id
        ).first {
            Button {
                openRecentDocument(latest)
            } label: {
                Label(
                    AppLocalization.format(
                        "Open latest result: %@",
                        latest.displayName
                    ),
                    systemImage: "arrow.right"
                )
            }
            .accessibilityIdentifier(
                "documentRelationshipOpenLatestResult"
            )
        }
    }

    private func workspaceContextStrip(
        _ record: DocumentRecord
    ) -> some View {
        let recommendation = model.recommendation(for: record)
        return HStack(alignment: .center, spacing: PPSpacing.medium) {
            VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: PPSpacing.small) {
                        contextCategory(record)
                        contextStatus(record)
                    }
                    VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                        contextCategory(record)
                        contextStatus(record)
                    }
                }
                Text(statusActionReason(record: record, recommendation: recommendation).localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(dynamicTypeSize.ppPrefersExpandedLayout ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            workspacePrimaryAction(record: record, recommendation: recommendation)
                .disabled(hasBlockingWorkspaceControlTask || isRedactionMode)
        }
        .padding(.horizontal, PPSpacing.medium)
        .padding(.vertical, PPSpacing.small)
        .background(PPColor.surface, in: RoundedRectangle(cornerRadius: PPRadius.control))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("documentContext")
    }

    private func workspacePrimaryAction(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) -> some View {
        let fullTitle = statusActionTitle(
            record: record,
            recommendation: recommendation
        )
        let isDeliveryAction = !workspacePrimaryContinuesTask(
            record: record,
            recommendation: recommendation
        )

        return DeskIconButton(
            title: fullTitle,
            symbol: statusActionSymbol(
                record: record,
                recommendation: recommendation
            ),
            tint: workspacePrimaryActionTint(
                record: record,
                isDeliveryAction: isDeliveryAction
            ),
            isProminent: true
        ) {
            if isDeliveryAction {
                shareVerifiedOrCreate()
            } else {
                performStatusAction(
                    record: record,
                    recommendation: recommendation
                )
            }
        }
        .accessibilityLabel(
            isDeliveryAction
                ? (
                    model.verifiedShareTarget(for: recordID) == nil
                        ? "Create verified sharing copy"
                        : "Share verified copy"
                ).localizedUI
                : AppLocalization.format(
                    "Next: %@",
                    fullTitle.localizedUI
                )
        )
        .accessibilityHint(
            isDeliveryAction
                ? "PaperPath shares a checked output instead of the working copy"
                    .localizedUI
                : (
                statusActionReason(
                    record: record,
                    recommendation: recommendation
                )
                )
        )
        .accessibilityIdentifier(
            isDeliveryAction
                ? "verifiedShareAction"
                : "workspaceNextAction"
        )
        .disabled(
            unlockCopyTask != nil
                || workspaceMetadataTask != nil
                || isWorkspaceHandoffActive
                || model.isProcessing(recordID)
                || (
                    record.profile.isLocked
                        && isApplyingSessionUnlock
                )
                || (
                    record.profile.isLocked
                        && isSessionUnlocked
                        && unlockCopyIssue?.isRetryable == false
                )
        )
    }

    private func workspacePrimaryContinuesTask(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) -> Bool {
        if record.profile.isLocked {
            return true
        }
        if let checkpoint = record.taskCheckpoint {
            switch checkpoint.stage {
            case .fillForm, .sign:
                return true
            case .verify:
                return false
            }
        }
        switch recommendation.action {
        case .safeShare, .shareCopy:
            return false
        default:
            return true
        }
    }

    private func workspacePrimaryActionTint(
        record: DocumentRecord,
        isDeliveryAction: Bool
    ) -> Color {
        if record.profile.isLocked {
            return PPColor.amber
        }
        return isDeliveryAction ? PPColor.mint : PPColor.cyan
    }

    private func statusActionTitle(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) -> String {
        if record.profile.isLocked {
            if isApplyingSessionUnlock {
                return "Opening protected PDF"
            }
            if isSessionUnlocked,
               unlockCopyIssue?.isRetryable == true {
                return "Retry editable copy"
            }
            return isSessionUnlocked
                ? "Create editable copy"
                : "Unlock to continue"
        }
        return record.taskCheckpoint?.stage.title
            ?? recommendation.action.title
    }

    private func statusActionReason(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) -> String {
        if record.profile.isLocked {
            if isApplyingSessionUnlock {
                return "Applying the password on this device."
            }
            if isSessionUnlocked,
               let unlockCopyIssue {
                return unlockCopyIssue.recovery
            }
            return isSessionUnlocked
                ? "Make a separate password-free private copy; the original stays encrypted."
                : "Enter the PDF password for this session only."
        }
        return record.taskCheckpoint?.resumeReason
            ?? recommendation.reason
    }

    private func statusActionSymbol(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) -> String {
        if record.profile.isLocked {
            if isApplyingSessionUnlock {
                return "hourglass"
            }
            if isSessionUnlocked,
               unlockCopyIssue?.isRetryable == true {
                return "arrow.clockwise"
            }
            return isSessionUnlocked ? "doc.badge.plus" : "lock.open"
        }
        return record.taskCheckpoint?.stage.symbol
            ?? recommendation.action.symbol
    }

    private func performStatusAction(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) {
        if record.profile.isLocked {
            if isApplyingSessionUnlock {
                return
            } else if isSessionUnlocked {
                createUnlockedPrivateCopy()
            } else {
                isUnlocking = true
            }
            return
        }
        if let checkpoint = record.taskCheckpoint {
            resume(checkpoint)
        } else {
            handle(recommendation.action)
        }
    }

    private func resume(_ checkpoint: DocumentTaskCheckpoint) {
        switch checkpoint.stage {
        case .fillForm:
            if let pageIndex = checkpoint.pageIndex {
                showPage(
                    pageIndex,
                    message: "Resuming form",
                    thenPresent: .formReview
                )
            } else {
                presentedSheet = .formReview
            }
        case .sign:
            showPageThenSignature(
                checkpoint.pageIndex,
                initialBounds: checkpoint.normalizedBounds,
                fieldName: checkpoint.fieldName
            )
        case .verify:
            shareVerifiedOrCreate()
        }
    }

    private func createUnlockedPrivateCopy() {
        guard unlockCopyTask == nil else { return }
        guard let password = sessionPassword,
              !password.isEmpty,
              let sourceContentRevisionID =
                model.record(id: recordID)?.contentRevisionID
        else {
            isSessionUnlocked = false
            isUnlocking = true
            return
        }
        unlockCopyIssue = nil
        unlockCopyStopRequested = false
        let generation = UUID()
        unlockCopyGeneration = generation
        unlockCopyTask = Task { @MainActor in
            defer {
                if unlockCopyGeneration == generation {
                    unlockCopyTask = nil
                    unlockCopyStopRequested = false
                }
            }
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createUnlockedCopy(
                    recordID: recordID,
                    password: password,
                    expectedContentRevisionID:
                        sourceContentRevisionID,
                    presentsFeedback: false
                ) { issue in
                    guard unlockCopyGeneration == generation,
                          issue.phase != .cancelled
                    else { return }
                    unlockCopyIssue = issue
                    unlockCopyErrorFeedback += 1
                }
            }
            guard unlockCopyGeneration == generation,
                  !Task.isCancelled,
                  let created
            else { return }
            unlockCopyIssue = nil
            let continuesToVerifiedOutput =
                continuesVerifiedOutputAfterUnlock
            if continuesToVerifiedOutput {
                _ = await model.updateTaskCheckpoint(
                    recordID: created.id,
                    checkpoint: DocumentTaskCheckpoint(
                        stage: .verify,
                        contentRevisionID: created.contentRevisionID
                    ),
                    presentsFeedback: false
                )
            }
            guard unlockCopyGeneration == generation,
                  !Task.isCancelled
            else { return }
            continuesVerifiedOutputAfterUnlock = false
            openCreatedDocument(
                DocumentRoute(
                    recordID: created.id,
                    quickTask:
                        continuesToVerifiedOutput
                            ? .safeShare
                            : nil
                )
            )
        }
    }

    private func stopUnlockCopyCreation() {
        guard unlockCopyTask != nil,
              !unlockCopyStopRequested
        else { return }
        unlockCopyStopRequested = true
        unlockCopyTask?.cancel()
        model[noticeFor: paperPathSceneID] =
            "Stopping editable copy creation".localizedUI
    }

    private func dismissUnlockCopyIssue() {
        unlockCopyIssue = nil
    }

    private func retryUnlockedPrivateCopy() {
        guard unlockCopyIssue?.isRetryable == true else {
            return
        }
        createUnlockedPrivateCopy()
    }

    private func resetUnlockCopyState() {
        unlockCopyGeneration = UUID()
        unlockCopyTask?.cancel()
        unlockCopyTask = nil
        unlockCopyIssue = nil
        unlockCopyStopRequested = false
        continuesVerifiedOutputAfterUnlock = false
    }

    private func clearProtectedDocumentSession() {
        cancelUnlockValidation()
        sessionUnlockGeneration = UUID()
        confirmedSessionUnlockGeneration = nil
        resetUnlockCopyState()
        unlockInput = ""
        sessionPassword = nil
        isSessionUnlocked = false
        isApplyingSessionUnlock = false
        isUnlocking = false
        redactionMarks = []
        textSelectionForReplacement = nil
    }

    private func setImmersiveReading(_ isEnabled: Bool) {
        guard isImmersiveReading != isEnabled else { return }
        withAnimation(
            reduceMotion ? nil : .snappy(duration: 0.24)
        ) {
            isImmersiveReading = isEnabled
        }
    }

    private func toggleImmersiveReading() {
        if isImmersiveReading {
            setImmersiveReading(false)
            return
        }
        guard !hasBlockingWorkspacePresentation,
              !hasBlockingWorkspaceControlTask
        else { return }
        setImmersiveReading(true)
    }

    private func openCurrentDocumentInNewWindow(
        _ currentRecordID: UUID
    ) {
        guard UIDevice.current.userInterfaceIdiom == .pad,
              !hasBlockingWorkspacePresentation,
              !hasBlockingWorkspaceControlTask
        else { return }
        openWindow(value: currentRecordID)
    }

    private func handleWorkspaceEscape() {
        if isWorkspaceHandoffActive {
            stopWorkspaceHandoff(showsNotice: true)
        } else if shareTask != nil || shareProgress != nil {
            stopSharePreparation(showsNotice: true)
        } else if isRedactionMode {
            cancelRedactionMode()
        } else if isImmersiveReading {
            setImmersiveReading(false)
        }
    }

    private func interruptProtectedWorkspaceWork() {
        cancelWorkspaceTransition()
        pendingWorkspaceHandoff = nil
        pendingRecognitionConfiguration = nil
        documentFindQuery = ""
        documentFindHistory.removeAll(keepingCapacity: false)
        isConfiguringRecognition = false
        stopRecognition()
        stopSearchableCopyCreation()
        readingPositionGeneration = UUID()
        readingPositionTask?.cancel()
        readingPositionTask = nil
        model.cancelReadingPositionUpdate(
            ownerID: readingPositionOwnerID
        )
        pdfSearchHighlight = nil
        privacyEvidenceOverlay = nil
        pdfCommand = nil
        originalName = ""
        proposedName = ""
        pageJumpInput = ""
        isRenaming = false
        isJumpingToPage = false
        isAddingNote = false
        pendingNote = nil
        isRedactionMode = false
        invalidateWorkspaceMetadataPresentation()
        clearProtectedDocumentSession()
        stopSharePreparation()
        if presentedSheet == .share {
            presentedSheet = nil
        }
        cleanupShareCopy()
    }

    @ViewBuilder
    private func contextStatus(_ record: DocumentRecord) -> some View {
        if let receipt = record.deliveryReceipt {
            Button {
                presentedSheet = .deliveryReceipt
            } label: {
                DeliveryReceiptBadge(
                    receipt: receipt,
                    isCurrent: record.hasCurrentDeliveryReceipt
                )
                .frame(
                    maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                        ? .infinity
                        : nil,
                    minHeight: 44,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                "Opens the delivery verification details".localizedUI
            )
            .accessibilityIdentifier("deliveryReceiptBadge")
        } else if !model.deliveryHistoryOutputs(for: record.id).isEmpty {
            Button {
                presentedSheet = .deliveryHistory
            } label: {
                OutputHistoryBadge(
                    count: model.deliveryHistoryOutputs(for: record.id).count
                )
                .frame(
                    maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                        ? .infinity
                        : nil,
                    minHeight: 44,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                "Opens verified output history".localizedUI
            )
        } else if let provenance =
                    record.receivedPackageProvenance {
            Button {
                presentedSheet = .receivedPackage
            } label: {
                ReceivedPackageBadge(
                    provenance: provenance,
                    isCurrent:
                        record.hasCurrentReceivedPackageProvenance
                )
                .frame(
                    maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                        ? .infinity
                        : nil,
                    minHeight: 44,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(
                "Opens the received package evidence"
            )
            .accessibilityIdentifier("receivedPackageBadge")
        }
    }

    private func contextCategory(_ record: DocumentRecord) -> some View {
        Label(
            contextCategoryTitle(record).localizedUI,
            systemImage: contextCategorySymbol(record)
        )
        .font(.caption.smallCaps().weight(.semibold))
        .foregroundStyle(PPColor.cyan)
        .padding(
            .vertical,
            dynamicTypeSize.ppPrefersExpandedLayout ? 6 : 3
        )
        .frame(minHeight: 28)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.cyan.opacity(0.5))
                .frame(height: 1)
        }
        .lineLimit(
            dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
        )
        .fixedSize(horizontal: false, vertical: true)
    }

    private func contextCategoryTitle(
        _ record: DocumentRecord
    ) -> String {
        guard let receipt = record.deliveryReceipt else {
            return record.brief?.category.title ?? record.profile.kind.title
        }
        return record.hasCurrentDeliveryReceipt
            ? receipt.outcomeTitle
            : "Output changed"
    }

    private func contextCategorySymbol(
        _ record: DocumentRecord
    ) -> String {
        guard let receipt = record.deliveryReceipt else {
            return record.brief?.category.symbol ?? record.profile.kind.symbol
        }
        if !record.hasCurrentDeliveryReceipt {
            return "arrow.triangle.2.circlepath"
        }
        return receipt.hasWarnings
            ? "exclamationmark.triangle"
            : "checkmark.seal"
    }

    private func commandTint(
        _ readiness: DocumentCommandReadiness
    ) -> Color {
        switch readiness {
        case .ready: return PPColor.mint
        case .review: return PPColor.amber
        case .blocked: return .red
        }
    }

    private func verifiedResultStrip(
        _ record: DocumentRecord
    ) -> some View {
        let receipt = record.deliveryReceipt
        let isCurrent = record.hasCurrentDeliveryReceipt
        let canShare = isCurrent
            && receipt?.isVerified == true
            && receipt?.isDeliveryOutput == true
        let tint = isCurrent ? PPColor.mint : PPColor.amber
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

        return layout {
            Button {
                presentedSheet = .deliveryReceipt
            } label: {
                HStack(spacing: PPSpacing.small) {
                    Image(
                        systemName: isCurrent
                            ? "checkmark.seal.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.body.weight(.semibold))
                    .foregroundStyle(tint)
                    .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            isCurrent
                                ? (
                                    receipt?.outcomeTitle
                                        ?? "Checked output"
                                )
                                : "Verification expired"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? nil
                                : 2
                        )

                        Text(
                            isCurrent
                                ? "\(receipt?.operation.title ?? "Output") receipt"
                                : "This PDF changed after its receipt was issued"
                        )
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? nil
                                : 2
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isCurrent
                    ? "Open current delivery receipt"
                    : "Open expired delivery receipt"
            )

            Button {
                if canShare {
                    share(recordID: recordID)
                } else {
                    shareVerifiedOrCreate()
                }
            } label: {
                Label(
                    canShare ? "Share" : "Verify",
                    systemImage: canShare
                        ? "square.and.arrow.up"
                        : "checkmark.shield"
                )
                .font(.caption.weight(.semibold))
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.bordered)
            .tint(tint)
            .accessibilityIdentifier("verifiedResultAction")
        }
        .padding(.horizontal, PPSpacing.medium)
        .padding(.vertical, PPSpacing.small)
        .background(tint.opacity(0.08))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .contain)
    }

    private func actionBar(record: DocumentRecord) -> some View {
        return VStack(spacing: 0) {
            if let shareProgress {
                HStack(spacing: PPSpacing.small) {
                    LocalOperationProgressView(
                        progress: shareProgress
                    )
                    .frame(maxWidth: .infinity)

                    Button {
                        stopSharePreparation(showsNotice: true)
                    } label: {
                        Image(systemName: "stop.fill")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.amber)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(
                        "Stop share preparation".localizedUI
                    )
                    .accessibilityHint(
                        "The working copy stays unchanged."
                            .localizedUI
                    )
                    .accessibilityIdentifier(
                        "stopWorkspaceSharePreparation"
                    )
                }
                .padding(.horizontal, PPSpacing.regular)
                .padding(.vertical, PPSpacing.small)

                Rectangle()
                    .fill(PPColor.border.opacity(0.5))
                    .frame(height: 0.6)
            } else if isWorkspaceHandoffActive {
                workspaceHandoffStatusBar(
                    activeWorkspaceHandoff ?? pendingWorkspaceHandoff
                )

                Rectangle()
                    .fill(PPColor.border.opacity(0.5))
                    .frame(height: 0.6)
            }

            if record.profile.pageCount > 1
                || !pageBackHistory.isEmpty
                || !pageForwardHistory.isEmpty {
                pageNavigator(record: record)

                Rectangle()
                    .fill(PPColor.border.opacity(0.56))
                    .frame(height: 0.6)
            }

            HStack(alignment: .top, spacing: PPSpacing.small) {
                if !isRedactionMode {
                    toolModeMenu
                        .fixedSize(
                            horizontal: true,
                            vertical: false
                        )
                }
                workspaceToolRow(record)
                    .layoutPriority(1)
            }
            .padding(.horizontal, PPSpacing.regular)
            .padding(.vertical, PPSpacing.small)
            .disabled(hasBlockingWorkspaceControlTask)
            .opacity(
                hasBlockingWorkspaceControlTask ? 0.46 : 1
            )
        }
        .background(PPColor.surface)
        .dynamicTypeSize(.xSmall ... .accessibility1)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.72))
                .frame(height: 0.7)
        }
    }

    private func workspaceToolRow(_ record: DocumentRecord) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: PPSpacing.small) {
                actionBarCommands(record)
            }
            .scrollTargetLayout()
        }
        // Each mode has a different leading action. Reusing the old horizontal
        // offset can leave Find or page tools clipped after closing All tools.
        .id(toolMode)
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("workspaceToolRow")
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.deskToolNamesVisible, showToolNames && verticalSizeClass != .compact)
        .environment(\.deskToolLabelWidth, horizontalSizeClass == .compact ? 64 : 88)
        .frame(minHeight: PPDeskLayout.touchTarget)
    }

    private func workspaceHandoffStatusBar(
        _ handoff: PendingWorkspaceHandoff?
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.medium) {
                workspaceHandoffIdentity(handoff)
                Spacer(minLength: PPSpacing.small)
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                workspaceHandoffStopButton
            }

            VStack(alignment: .leading, spacing: PPSpacing.small) {
                HStack(spacing: PPSpacing.small) {
                    workspaceHandoffIdentity(handoff)
                    Spacer(minLength: PPSpacing.small)
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                workspaceHandoffStopButton
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("workspaceHandoffStatus")
    }

    private func workspaceHandoffIdentity(
        _ handoff: PendingWorkspaceHandoff?
    ) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(workspaceHandoffTitle(handoff))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(workspaceHandoffDetail(handoff))
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: workspaceHandoffSymbol(handoff))
                .foregroundStyle(PPColor.mint)
                .symbolEffect(
                    .pulse,
                    value: reduceMotion ? 0 : workspaceHandoffFeedback
                )
        }
    }

    private var workspaceHandoffStopButton: some View {
        Button {
            stopWorkspaceHandoff(showsNotice: true)
        } label: {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(PPColor.textSecondary)
        .keyboardShortcut(.cancelAction)
        .accessibilityLabel("Stop opening next step".localizedUI)
        .accessibilityHint(
            "Keeps you in this workspace without changing the PDF."
                .localizedUI
        )
        .help("Stop opening next step".localizedUI)
        .accessibilityIdentifier("stopWorkspaceHandoff")
    }

    private func workspaceHandoffTitle(
        _ handoff: PendingWorkspaceHandoff?
    ) -> String {
        guard let handoff else {
            return "Opening next step".localizedUI
        }
        switch handoff {
        case .tool(let tool):
            return AppLocalization.format(
                "Opening %@",
                tool.title.localizedUI
            )
        case .action(let action):
            return AppLocalization.format(
                "Opening %@",
                action.title.localizedUI
            )
        case .stamp:
            return "Opening Stamp".localizedUI
        case .openDocument(let route):
            if let record = model.record(id: route.recordID) {
                return AppLocalization.format(
                    "Opening %@",
                    record.displayName
                )
            }
            return "Opening private copy".localizedUI
        case .safeShare:
            return "Opening trusted delivery".localizedUI
        case .unlockForVerifiedOutput:
            return "Opening secure unlock".localizedUI
        case .recognitionSettings:
            return "Opening OCR settings".localizedUI
        case .presentSheet(let sheet):
            return AppLocalization.format(
                "Opening %@",
                workspaceHandoffSheetTitle(sheet).localizedUI
            )
        case .navigate(let pageIndex, _, _, let sheet, _, _):
            if let sheet {
                return AppLocalization.format(
                    "Opening %@",
                    workspaceHandoffSheetTitle(sheet).localizedUI
                )
            }
            return AppLocalization.format(
                "Opening page %lld",
                pageIndex + 1
            )
        case .signature:
            return "Opening signature".localizedUI
        }
    }

    private func workspaceHandoffDetail(
        _ handoff: PendingWorkspaceHandoff?
    ) -> String {
        switch handoff {
        case .safeShare:
            return "PaperPath will verify a protected output before sharing."
                .localizedUI
        case .unlockForVerifiedOutput:
            return "The encrypted original stays unchanged."
                .localizedUI
        case .openDocument:
            return "The created copy stays in Library if you stop here."
                .localizedUI
        case .navigate:
            return "The evidence page opens before the next panel."
                .localizedUI
        default:
            return "Closing the current panel before the next step."
                .localizedUI
        }
    }

    private func workspaceHandoffSymbol(
        _ handoff: PendingWorkspaceHandoff?
    ) -> String {
        guard let handoff else { return "arrow.turn.down.right" }
        switch handoff {
        case .tool(let tool): return tool.symbol
        case .action(let action): return action.symbol
        case .stamp: return "seal"
        case .openDocument: return "doc.badge.arrow.up"
        case .safeShare: return "checkmark.shield"
        case .unlockForVerifiedOutput: return "lock.open"
        case .recognitionSettings: return "text.viewfinder"
        case .presentSheet(let sheet):
            return workspaceHandoffSheetSymbol(sheet)
        case .navigate(_, _, _, let sheet, _, _):
            return sheet.map(workspaceHandoffSheetSymbol)
                ?? "arrow.up.right.square"
        case .signature: return "signature"
        }
    }

    private func workspaceHandoffSheetTitle(_ sheet: Sheet) -> String {
        switch sheet {
        case .brief: return "Brief"
        case .insight: return "Insight"
        case .pages: return "Pages"
        case .recognizedText: return "Recognized Text"
        case .share: return "Share"
        case .tools: return "Tools"
        case .stamp: return "Stamp"
        case .watermark: return "Watermark"
        case .bates: return "Bates Numbering"
        case .compression: return "Compress"
        case .protection: return "Protect"
        case .redaction: return "Redaction"
        case .export: return "Export"
        case .officeExport: return "Convert PDF"
        case .imageExport: return "Save as Images"
        case .verifiedExport: return "Finish & Share"
        case .reading: return "Reading"
        case .bookmarks: return "Bookmarks"
        case .formReview: return "Forms"
        case .find: return "Find"
        case .annotations: return "Annotations"
        case .attachments: return "Attachments"
        case .compare: return "Compare"
        case .deliveryReceipt: return "Receipt"
        case .deliveryHistory: return "Delivery history"
        case .receivedPackage: return "Received Package"
        case .sourceLocation: return "Source"
        case .technicalInspector: return "Inspector"
        case .versionHistory: return "Version History"
        case .reader: return "Reader"
        case .privateNote: return "Private Note"
        }
    }

    private func workspaceHandoffSheetSymbol(_ sheet: Sheet) -> String {
        switch sheet {
        case .brief: return "list.bullet.rectangle.portrait"
        case .insight: return "sparkle.magnifyingglass"
        case .pages: return "square.grid.2x2"
        case .recognizedText: return "text.viewfinder"
        case .share: return "square.and.arrow.up"
        case .tools: return "wrench.and.screwdriver"
        case .stamp: return "seal"
        case .watermark: return "textformat.alt"
        case .bates: return "number.square.fill"
        case .compression:
            return "arrow.down.right.and.arrow.up.left"
        case .protection: return "lock.doc"
        case .redaction: return "eye.slash"
        case .export, .officeExport, .imageExport, .verifiedExport:
            return "doc.badge.arrow.up"
        case .reading: return "textformat.size"
        case .bookmarks: return "bookmark"
        case .formReview: return "pencil.and.list.clipboard"
        case .find: return "text.magnifyingglass"
        case .annotations: return "text.bubble"
        case .attachments: return "paperclip"
        case .compare: return "doc.on.doc"
        case .deliveryReceipt: return "checkmark.seal"
        case .deliveryHistory: return "clock.badge.checkmark"
        case .receivedPackage: return "shippingbox"
        case .sourceLocation: return "folder"
        case .technicalInspector: return "info.circle"
        case .versionHistory: return "clock.arrow.circlepath"
        case .reader: return "book"
        case .privateNote: return "note.text"
        }
    }

    private func actionBarCommands(
        _ record: DocumentRecord
    ) -> AnyView {
        if isRedactionMode {
            return AnyView(redactionActionBarCommands)
        }
        switch toolMode {
        case .read:
            return AnyView(readActionBarCommands(record))
        case .annotate:
            return AnyView(annotationActionBarCommands(record))
        case .pages:
            return AnyView(pageActionBarCommands(record))
        case .deliver:
            return AnyView(deliveryActionBarCommands(record))
        }
    }

    @ViewBuilder
    private var redactionActionBarCommands: some View {
        DeskIconButton(title: "Cancel redaction", symbol: "xmark", tint: PPColor.textSecondary) {
            cancelRedactionMode()
        }
        .keyboardShortcut(.cancelAction)
        .accessibilityIdentifier("cancelRedactionMode")
        DeskIconButton(
            title: "Redact", symbol: "eye.slash", tint: PPColor.amber,
            isProminent: true
        ) {
            runCommand(.markRedaction)
        }
        .accessibilityHint(
            "Marks the currently selected text for permanent redaction"
        )
        .accessibilityIdentifier("applyRedactionSelection")
    }

    @ViewBuilder
    private func readActionBarCommands(
        _ record: DocumentRecord
    ) -> some View {
        workspaceToolButton(.find, record: record)
            .accessibilityIdentifier("workspaceFindAction")
        workspaceToolButton(.bookmarks, record: record)
        DeskIconButton(title: "Reader", symbol: "book", tint: toolMode.tint) {
            presentedSheet = .reader
        }
        DeskIconButton(title: "Reading", symbol: "textformat.size", tint: toolMode.tint) {
            presentedSheet = .reading
        }
        DeskIconButton(title: "Focus reading", symbol: "arrow.up.left.and.arrow.down.right", tint: toolMode.tint) {
            toggleImmersiveReading()
        }
        .accessibilityIdentifier("enterFocusReading")
        recentToolButton(record: record)
    }

    @ViewBuilder
    private func annotationActionBarCommands(
        _ record: DocumentRecord
    ) -> some View {
        workspaceToolButton(.highlight, record: record)
        workspaceToolButton(.ink, record: record)
        workspaceToolButton(.note, record: record)
        workspaceToolButton(.sign, record: record)
        workspaceToolButton(.underline, record: record)
        markUpMenu
            .disabled(record.profile.isLocked)
    }

    @ViewBuilder
    private func pageActionBarCommands(
        _ record: DocumentRecord
    ) -> some View {
        workspaceToolButton(.organize, record: record)
            .keyboardShortcut("p", modifiers: [.command, .shift])
        workspaceToolButton(.compare, record: record)
        workspaceToolButton(.bates, record: record)
        workspaceToolButton(.watermark, record: record)
        DeskIconButton(title: "Version History", symbol: "clock.arrow.circlepath", tint: toolMode.tint) {
            presentedSheet = .versionHistory
        }
        recentToolButton(record: record)
    }

    @ViewBuilder
    private func deliveryActionBarCommands(
        _ record: DocumentRecord
    ) -> some View {
        DeskIconButton(
            title: record.profile.isLocked ? "Unlock to continue" : "Verify & Share",
            symbol: record.profile.isLocked ? "lock.open" : "checkmark.shield",
            tint: PPColor.mint, isProminent: true
        ) {
            if record.profile.isLocked {
                performStatusAction(record: record, recommendation: model.recommendation(for: record))
            } else {
                shareVerifiedOrCreate()
            }
        }
        .disabled(isApplyingSessionUnlock || unlockCopyIssue?.isRetryable == false)
        DeskIconButton(
            title: "Privacy Scan",
            symbol: "checkmark.shield",
            tint: PPColor.mint
        ) {
            isPrivacyScanPresented = true
        }
        .disabled(
            record.profile.isLocked
                || model.isProcessing(recordID)
        )
        .accessibilityHint(
            privacyScanAvailabilityHint(for: record)
        )
        .accessibilityIdentifier("privacyScanDeliveryAction")
        workspaceToolButton(.fillForm, record: record)
        workspaceToolButton(.compress, record: record)
        workspaceToolButton(.protect, record: record)
        workspaceToolButton(.export, record: record)
        DeskIconButton(title: "Delivery history", symbol: "clock.badge.checkmark", tint: PPColor.mint) {
            presentedSheet = .deliveryHistory
        }
    }

    private var toolMode: ToolMode {
        ToolMode(rawValue: savedToolMode) ?? .read
    }

    private var toolModeMenu: some View {
        Button {
            isSelectingToolMode = true
        } label: {
            VStack(spacing: PPSpacing.xSmall) {
                HStack(spacing: 3) {
                    Image(systemName: toolMode.symbol)
                        .font(.system(size: 18, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .frame(height: PPDeskLayout.touchTarget)
                if showToolNames && verticalSizeClass != .compact {
                    Text(toolMode.title.localizedUI)
                        .font(.caption2.weight(.semibold))
                        .lineLimit(2)
                        .frame(minHeight: 30, alignment: .top)
                }
            }
            .foregroundStyle(toolMode.tint)
            .frame(width: horizontalSizeClass == .compact ? 64 : 88)
            .background(PPColor.surfaceMuted, in: RoundedRectangle(cornerRadius: PPRadius.control))
        }
        .buttonStyle(PPPressButtonStyle())
        .tint(toolMode.tint)
        .accessibilityLabel("Workspace tools".localizedUI)
        .accessibilityValue(toolMode.title.localizedUI)
        .accessibilityIdentifier("workspaceModeMenu")
        .confirmationDialog(
            "Workspace tools".localizedUI,
            isPresented: $isSelectingToolMode,
            titleVisibility: .visible
        ) {
            ForEach(ToolMode.allCases) { mode in
                Button {
                    savedToolMode = mode.rawValue
                } label: {
                    Text(mode.title.localizedUI)
                }
                .accessibilityIdentifier(
                    "workspaceMode-\(mode.rawValue)"
                )
            }
            Button(
                (
                    showToolNames
                        ? "Hide tool names"
                        : "Show tool names"
                ).localizedUI
            ) {
                showToolNames.toggle()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func workspaceToolButton(_ tool: DocumentTool, record: DocumentRecord) -> some View {
        DeskIconButton(title: tool.title, symbol: tool.symbol, tint: toolMode.tint) {
            handle(tool)
        }
        .disabled(!isWorkspaceToolAvailable(tool, record: record))
        .accessibilityIdentifier("workspaceTool-\(tool.rawValue)")
    }

    private func isWorkspaceToolAvailable(_ tool: DocumentTool, record: DocumentRecord) -> Bool {
        if record.profile.isLocked, [.find, .bookmarks].contains(tool) {
            return isSessionUnlocked
        }
        return availableTools(for: record).contains(tool)
    }

    private func workspaceCommandRail(
        _ signals: [DocumentCommandSignal],
        record: DocumentRecord
    ) -> some View {
        return ScrollView(.horizontal) {
            HStack(spacing: PPSpacing.small) {
                ForEach(signals) { signal in
                    workspaceSignalChip(signal, record: record)
                        .frame(
                            minWidth:
                                dynamicTypeSize.ppPrefersExpandedLayout
                                    ? 200
                                    : 112,
                            maxWidth:
                                dynamicTypeSize.ppPrefersExpandedLayout
                                    ? 260
                                    : 172
                        )
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, PPSpacing.small)
        .padding(.top, 5)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workspaceCommandRail")
    }

    private func workspaceCommandSignals(
        _ record: DocumentRecord
    ) -> [DocumentCommandSignal] {
        let signals = model.commandProfile(for: record).signals
        let relevant = signals.filter {
            switch $0.id {
            case "privacy":
                return record.profile.isLocked
            case "delivery":
                return record.deliveryReceipt != nil && !record.hasCurrentDeliveryReceipt
            case "text":
                return !record.profile.isLocked
                    && ($0.readiness == .review || model.hasRecognizedText(recordID: record.id))
            default:
                return false
            }
        }
        return relevant.filter { $0.readiness == .blocked }
            + relevant.filter { $0.readiness != .blocked }
    }

    private func compactWorkspaceSignal(
        _ signal: DocumentCommandSignal,
        record: DocumentRecord
    ) -> some View {
        Button {
            openSignal(signal, record: record)
        } label: {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: signal.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(commandTint(signal.readiness))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(
                        AppLocalization.format(
                            "%@ · %@",
                            signal.title.localizedUI,
                            signal.value.localizedUI
                        )
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                    Text(signal.detail.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? 3
                                : 1
                        )
                }
                Spacer(minLength: PPSpacing.small)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(commandTint(signal.readiness))
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 48)
            .background(commandTint(signal.readiness).opacity(0.07))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(commandTint(signal.readiness))
                    .frame(width: 2)
                    .padding(.vertical, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            AppLocalization.format(
                "%@, %@. %@",
                signal.title.localizedUI,
                signal.value.localizedUI,
                signal.detail.localizedUI
            )
        )
        .accessibilityHint("Opens the relevant review step".localizedUI)
        .accessibilityIdentifier("workspacePrioritySignal")
    }

    private func workspaceSignalChip(
        _ signal: DocumentCommandSignal,
        record: DocumentRecord
    ) -> some View {
        Button {
            openSignal(signal, record: record)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: signal.symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(commandTint(signal.readiness))
                Text(
                    AppLocalization.format(
                        "%@ · %@",
                        signal.value.localizedUI,
                        signal.title.localizedUI
                    )
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? 2
                        : 1
                )
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(
                minHeight:
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? 56
                        : 44
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(commandTint(signal.readiness).opacity(0.38))
                    .frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            AppLocalization.format(
                "%@, %@. %@",
                signal.title.localizedUI,
                signal.value.localizedUI,
                signal.detail.localizedUI
            )
        )
    }

    private func openSignal(
        _ signal: DocumentCommandSignal,
        record: DocumentRecord
    ) {
        switch signal.id {
        case "delivery":
            if record.deliveryReceipt != nil {
                presentedSheet = .deliveryReceipt
            } else {
                shareVerifiedOrCreate()
            }
        case "office":
            presentedSheet = .officeExport
        case "text":
            handle(DocumentAction.recognizeText)
        case "structure":
            presentedSheet = record.brief == nil ? .insight : .brief
        case "privacy":
            presentedSheet = record.profile.isLocked
                ? .technicalInspector
                : .sourceLocation
        default:
            presentedSheet = .insight
        }
    }

    @ViewBuilder
    private func recentToolButton(
        record: DocumentRecord
    ) -> some View {
        let available = availableTools(for: record)
        let favorites = favoriteTools.filter(available.contains)
        let recents = recentTools.filter {
            available.contains($0) && !favorites.contains($0)
        }
        let hasShortcuts = !favorites.isEmpty || !recents.isEmpty

        DeskIconButton(
            title: "All tools",
            symbol: "ellipsis",
            tint: PPColor.textSecondary
        ) {
            presentedSheet = .tools
        }
        .accessibilityHint(
            (
                hasShortcuts
                    ? "Opens all document tools. Touch and hold for favorite and recent tools."
                    : "Opens all document tools."
            ).localizedUI
        )
        .accessibilityIdentifier("documentToolsAction")
        .contextMenu {
            if !favorites.isEmpty {
                Section("Favorites") {
                    ForEach(favorites) { tool in
                        Button {
                            handle(tool)
                        } label: {
                            Label(
                                tool.title.localizedUI,
                                systemImage: tool.symbol
                            )
                        }
                    }
                }
            }
            if !recents.isEmpty {
                Section("Recent Tools") {
                    ForEach(recents) { tool in
                        Button {
                            handle(tool)
                        } label: {
                            Label(
                                tool.title.localizedUI,
                                systemImage: tool.symbol
                            )
                        }
                    }
                }
            }
            Button {
                presentedSheet = .tools
            } label: {
                Label("All tools", systemImage: "square.grid.2x2")
            }
        }
    }

    private func pageNavigator(
        record: DocumentRecord
    ) -> some View {
        let pageCount = max(record.profile.pageCount, 1)
        let displayedPage = isScrubbingPage
            ? Int(pageScrubberValue.rounded())
            : currentPageIndex

        return VStack(spacing: 0) {
            HStack(spacing: PPSpacing.small) {
                Button {
                    showPage(
                        currentPageIndex - 1,
                        message: "Previous page",
                        showsNotice: false
                    )
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(currentPageIndex <= 0 ? PPColor.border : PPColor.accent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PPPressButtonStyle())
                .disabled(currentPageIndex <= 0)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Previous page".localizedUI)

                HStack(spacing: PPSpacing.small) {
                    Button {
                        pageJumpInput = "\(displayedPage + 1)"
                        isJumpingToPage = true
                    } label: {
                        ViewThatFits(in: .horizontal) {
                            Label(
                                AppLocalization.format(
                                    "Page %lld of %lld",
                                    displayedPage + 1,
                                    pageCount
                                ),
                                systemImage: "doc.text"
                            )
                            Text(
                                "\(displayedPage + 1) / \(pageCount)"
                            )
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .monospacedDigit()
                        .contentTransition(
                            reduceMotion
                                ? .identity
                                : .numericText()
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, PPSpacing.medium)
                        .frame(minHeight: 44)
                        .background(PPColor.surfaceMuted, in: Capsule())
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("j", modifiers: .command)
                    .accessibilityLabel(
                        AppLocalization.format(
                            "Page %lld of %lld. Go to page",
                            displayedPage + 1,
                            pageCount
                        )
                    )
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment:
                            showPage(
                                min(
                                    currentPageIndex + 1,
                                    pageCount - 1
                                ),
                                message: "Next page",
                                showsNotice: false
                            )
                        case .decrement:
                            showPage(
                                max(currentPageIndex - 1, 0),
                                message: "Previous page",
                                showsNotice: false
                            )
                        @unknown default:
                            break
                        }
                    }

                    if horizontalSizeClass == .regular,
                       pageCount > 5 {
                        Slider(
                            value: Binding(
                                get: {
                                    isScrubbingPage
                                        ? pageScrubberValue
                                        : Double(currentPageIndex)
                                },
                                set: {
                                    pageScrubberValue = $0
                                }
                            ),
                            in: 0...Double(pageCount - 1),
                            step: 1
                        ) { editing in
                            if editing {
                                pageScrubberValue = Double(
                                    currentPageIndex
                                )
                                isScrubbingPage = true
                            } else {
                                let page = Int(
                                    pageScrubberValue.rounded()
                                )
                                isScrubbingPage = false
                                showPage(
                                    page,
                                    message: "Jumped",
                                    showsNotice: false
                                )
                            }
                        }
                        .tint(PPColor.accent)
                        .frame(minWidth: 112)
                        .accessibilityLabel(
                            "Page position".localizedUI
                        )
                        .accessibilityValue(
                            AppLocalization.format(
                                "Page %lld of %lld",
                                displayedPage + 1,
                                pageCount
                            )
                        )
                    }
                }
                .frame(maxWidth: .infinity)

                Button {
                    showPage(
                        currentPageIndex + 1,
                        message: "Next page",
                        showsNotice: false
                    )
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(currentPageIndex >= pageCount - 1 ? PPColor.border : PPColor.accent)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(PPPressButtonStyle())
                .disabled(
                    currentPageIndex >= record.profile.pageCount - 1
                )
                .keyboardShortcut("]", modifiers: .command)
                .accessibilityLabel("Next page".localizedUI)

                Button {
                    toggleCurrentPageBookmark()
                } label: {
                    Image(
                        systemName: record.bookmarkedPages
                            .contains(currentPageIndex)
                            ? "bookmark.fill"
                            : "bookmark"
                    )
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    record.bookmarkedPages.contains(currentPageIndex)
                        ? PPColor.accent
                        : PPColor.textSecondary
                )
                .accessibilityLabel(
                    AppLocalization.format(
                        record.bookmarkedPages.contains(currentPageIndex)
                            ? "Remove bookmark from page %lld"
                            : "Bookmark page %lld",
                        currentPageIndex + 1
                    )
                )
                .accessibilityIdentifier("bookmarkCurrentPage")
                .accessibilityAddTraits(record.bookmarkedPages.contains(currentPageIndex) ? .isSelected : [])
                .keyboardShortcut("b", modifiers: .command)
                .disabled(workspaceMetadataTask != nil)
            }

            if !pageBackHistory.isEmpty
                || !pageForwardHistory.isEmpty {
                pageHistoryControls
            }
        }
        .foregroundStyle(PPColor.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
    }

    private var pageHistoryControls: some View {
        HStack(spacing: PPSpacing.small) {
            Button {
                navigateBack()
            } label: {
                Label(
                    pageBackHistory.last.map {
                        AppLocalization.format(
                            "Back · p%lld",
                            $0 + 1
                        )
                    } ?? "Back".localizedUI,
                    systemImage: "arrow.uturn.backward"
                )
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                )
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(pageBackHistory.isEmpty)
            .keyboardShortcut(
                .leftArrow,
                modifiers: [.command, .option]
            )
            .accessibilityHint(
                "Returns to the previous page jump.".localizedUI
            )
            .help("Back through page history".localizedUI)

            Rectangle()
                .fill(PPColor.border.opacity(0.6))
                .frame(width: 0.6, height: 18)

            Button {
                navigateForward()
            } label: {
                Label(
                    pageForwardHistory.last.map {
                        AppLocalization.format(
                            "Forward · p%lld",
                            $0 + 1
                        )
                    } ?? "Forward".localizedUI,
                    systemImage: "arrow.uturn.forward"
                )
                .lineLimit(
                    dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
                )
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .disabled(pageForwardHistory.isEmpty)
            .keyboardShortcut(
                .rightArrow,
                modifiers: [.command, .option]
            )
            .accessibilityHint(
                "Moves forward through page jump history.".localizedUI
            )
            .help("Forward through page history".localizedUI)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.5))
                .frame(height: 0.6)
        }
        .accessibilityIdentifier("pageNavigationHistory")
    }

    private var markUpMenu: some View {
        Menu {
            Section("Mark up") {
                Button {
                    runMarkup(.highlight)
                } label: {
                    Label(
                        AppLocalization.format(
                            "%@ · %@",
                            kindTitle(.highlight).localizedUI,
                            markupColor(for: .highlight).title.localizedUI
                        ),
                        systemImage: "highlighter"
                    )
                }
                Button {
                    runMarkup(.underline)
                } label: {
                    Label(
                        AppLocalization.format(
                            "%@ · %@",
                            kindTitle(.underline).localizedUI,
                            markupColor(for: .underline).title.localizedUI
                        ),
                        systemImage: "underline"
                    )
                }
                Button {
                    runMarkup(.strikeOut)
                } label: {
                    Label(
                        AppLocalization.format(
                            "%@ · %@",
                            kindTitle(.strikeOut).localizedUI,
                            markupColor(for: .strikeOut).title.localizedUI
                        ),
                        systemImage: "strikethrough"
                    )
                }
                Button {
                    isPresentingPencil = true
                } label: {
                    Label(
                        "Draw on Page",
                        systemImage: "pencil.tip.crop.circle"
                    )
                }
                Button {
                    isAddingNote = true
                } label: {
                    Label("Add Note", systemImage: "note.text.badge.plus")
                }
            }

            Menu {
                Button {
                    presentedSheet = .stamp
                } label: {
                    Label("Stamp", systemImage: "seal")
                }
                Button {
                    isPresentingContentEditor = true
                } label: {
                    Label(
                        "Text, Photo, or Link",
                        systemImage: "text.badge.plus"
                    )
                }
                Button {
                    presentSignature()
                } label: {
                    Label("Signature", systemImage: "signature")
                }
            } label: {
                Label("Add to Page", systemImage: "plus.circle")
            }

            Menu {
                Button {
                    runCommand(.captureTextForEditing)
                } label: {
                    Label(
                        "Selected Text",
                        systemImage: "character.cursor.ibeam"
                    )
                }
                Button {
                    isPresentingLinkEditor = true
                } label: {
                    Label("Existing Links", systemImage: "link")
                }
                Button {
                    isPresentingImageReplacement = true
                } label: {
                    Label(
                        "Existing Image",
                        systemImage: "photo.badge.arrow.down"
                    )
                }
            } label: {
                Label("Edit Page Content", systemImage: "doc.text")
            }

            Menu {
                markupColorMenu(
                    kind: .highlight,
                    title: "Highlight Color"
                )
                markupColorMenu(
                    kind: .underline,
                    title: "Underline Color"
                )
                markupColorMenu(
                    kind: .strikeOut,
                    title: "Strike Color"
                )
            } label: {
                Label("Markup Colors", systemImage: "paintpalette")
            }

            Button {
                presentedSheet = .annotations
            } label: {
                Label("Comments & Markup", systemImage: "text.bubble")
            }

            Button {
                runCommand(.removeAnnotation)
            } label: {
                Label("Undo Last on Page", systemImage: "arrow.uturn.backward")
            }
        } label: {
            DeskToolLabel(
                title: "More editing tools",
                symbol: "ellipsis",
                tint: PPColor.textSecondary
            )
        }
        .help("More editing tools".localizedUI)
        .accessibilityLabel("More editing tools".localizedUI)
        .hoverEffect(.highlight)
        .keyboardShortcut("a", modifiers: [.command, .shift])
    }

    private func markupColorMenu(
        kind: PDFMarkupKind,
        title: String
    ) -> some View {
        Menu {
            ForEach(PDFMarkupColor.allCases) { color in
                Button {
                    setMarkupColor(color, for: kind)
                } label: {
                    Label {
                        HStack {
                            Text(color.title.localizedUI)
                            if color == markupColor(for: kind) {
                                Image(systemName: "checkmark")
                            }
                        }
                    } icon: {
                        Circle()
                            .fill(markupSwiftUIColor(color))
                            .frame(width: 13, height: 13)
                    }
                }
            }
        } label: {
            Label {
                Text(title.localizedUI)
            } icon: {
                Circle()
                    .fill(markupSwiftUIColor(markupColor(for: kind)))
                    .frame(width: 13, height: 13)
                    .overlay {
                        Circle()
                            .stroke(
                                PPColor.border,
                                lineWidth: 0.5
                            )
                    }
                    .accessibilityHidden(true)
            }
        }
    }

    private var pageJumpIsValid: Bool {
        guard let page = Int(pageJumpInput),
              let pageCount = model.record(id: recordID)?.profile.pageCount,
              pageCount > 0
        else { return false }
        return (1...pageCount).contains(page)
    }

    private func jumpToEnteredPage() {
        guard pageJumpIsValid,
              let page = Int(pageJumpInput)
        else { return }
        isJumpingToPage = false
        pageJumpInput = ""
        showPage(
            page - 1,
            message: "Jumped",
            showsNotice: false
        )
    }

    private func availableTools(
        for record: DocumentRecord
    ) -> Set<DocumentTool> {
        var tools = Set(DocumentTool.allCases)
        if record.brief == nil {
            tools.remove(.brief)
        }
        if record.profile.kind != .scan && record.profile.kind != .mixed {
            tools.remove(.recognize)
        }
        if record.profile.kind != .form {
            tools.remove(.fillForm)
        }
        if model.documents.filter({ !$0.profile.isLocked }).count < 2 {
            tools.remove(.compare)
        }
        if record.profile.isLocked {
            tools = [.export]
        }
        return tools
    }

    private func unavailableToolReasons(
        for record: DocumentRecord
    ) -> [DocumentTool: String] {
        if record.profile.isLocked {
            return Dictionary(
                DocumentTool.allCases
                    .filter { $0 != .export }
                    .map {
                        (
                            $0,
                            "Create an unlocked private copy to use this tool."
                        )
                    },
                uniquingKeysWith: { current, _ in current }
            )
        }

        var reasons: [DocumentTool: String] = [:]
        if record.brief == nil {
            reasons[.brief] =
                "Available after PaperPath indexes readable text."
        }
        if record.profile.kind != .scan
            && record.profile.kind != .mixed {
            reasons[.recognize] =
                "This PDF already contains native searchable text."
        }
        if record.profile.kind != .form {
            reasons[.fillForm] =
                "No interactive form fields were detected."
        }
        if model.documents.filter({ !$0.profile.isLocked }).count < 2 {
            reasons[.compare] =
                "Import another unlocked PDF to compare versions."
        }
        return reasons
    }

    private func contextualTools(
        for record: DocumentRecord
    ) -> [DocumentTool] {
        var result: [DocumentTool] = []
        for action in model.actions(for: record) {
            let tool = contextualTool(for: action, record: record)
            if let tool,
               !result.contains(tool) {
                result.append(tool)
            }
        }
        return Array(result.prefix(4))
    }

    private func contextualToolReasons(
        for record: DocumentRecord
    ) -> [DocumentTool: String] {
        let recommendation = model.recommendation(for: record)
        guard let tool = contextualTool(
            for: recommendation.action,
            record: record
        ) else { return [:] }
        return [
            tool: statusActionReason(
                record: record,
                recommendation: recommendation
            )
        ]
    }

    private func contextualTool(
        for action: DocumentAction,
        record: DocumentRecord
    ) -> DocumentTool? {
        switch action {
        case .brief:
            return .brief
        case .recognizeText:
            return .recognize
        case .makeSearchable:
            return nil
        case .organizePages:
            return .organize
        case .reviewForm:
            return .fillForm
        case .sign:
            return .sign
        case .safeShare, .shareCopy:
            return .export
        case .inspect:
            return record.brief == nil ? .find : .brief
        }
    }

    private func handle(_ tool: DocumentTool) {
        var updated = recentTools.filter { $0 != tool }
        updated.insert(tool, at: 0)
        savedRecentTools = updated
            .prefix(4)
            .map(\.rawValue)
            .joined(separator: ",")

        switch tool {
        case .brief:
            presentedSheet = .brief
        case .find:
            presentedSheet = .find
        case .recognize:
            handle(.recognizeText)
        case .highlight:
            runMarkup(.highlight)
        case .underline:
            runMarkup(.underline)
        case .strikeOut:
            runMarkup(.strikeOut)
        case .ink:
            isPresentingPencil = true
        case .note:
            isAddingNote = true
        case .stamp:
            presentedSheet = .stamp
        case .watermark:
            presentedSheet = .watermark
        case .bates:
            presentedSheet = .bates
        case .content:
            isPresentingContentEditor = true
        case .links:
            isPresentingLinkEditor = true
        case .annotations:
            presentedSheet = .annotations
        case .attachments:
            presentedSheet = .attachments
        case .compare:
            presentedSheet = .compare
        case .sign:
            presentSignature()
        case .redact:
            isRedactionMode = true
            runCommand(.markRedaction)
        case .fillForm:
            presentedSheet = .formReview
        case .bookmarks:
            presentedSheet = .bookmarks
        case .organize:
            pageOrganizerStartsSelecting = false
            pageOrganizerInitialSelection = []
            presentedSheet = .pages
        case .compress:
            presentedSheet = .compression
        case .protect:
            presentedSheet = .protection
        case .export:
            presentedSheet = .export
        }
    }

    private func runCommand(_ action: PDFViewCommand.Action) {
        if directMutationVersionLabel(for: action) != nil,
           model.isProcessing(recordID) {
            model[noticeFor: paperPathSceneID] =
                "Wait for the current document task to finish"
            return
        }
        guard let contentRevisionID =
            model.record(id: recordID)?.contentRevisionID
        else { return }
        presentedSheet = nil
        scheduleWorkspaceTransition(
            expectedContentRevisionID: contentRevisionID
        ) {
            if let label = directMutationVersionLabel(for: action) {
                guard !model.isProcessing(recordID) else {
                    model[noticeFor: paperPathSceneID] =
                        "Wait for the current document task to finish"
                    return
                }
                guard await model.createVersionSnapshot(
                    recordID: recordID,
                    label: label
                ) else { return }
            }
            pdfCommand = PDFViewCommand(action: action)
        }
    }

    private func runViewportCommand(
        _ action: PDFViewCommand.Action
    ) {
        switch action {
        case .zoomIn, .zoomOut, .fitToWindow:
            break
        default:
            return
        }
        guard !hasBlockingWorkspacePresentation,
              !isWorkspaceHandoffActive,
              shareTask == nil,
              shareProgress == nil
        else { return }
        pdfCommand = PDFViewCommand(action: action)
    }

    private func commitPendingNote() {
        guard let pendingNote else { return }
        self.pendingNote = nil
        runCommand(.addNote(pendingNote))
    }

    private func cancelRedactionMode() {
        redactionMarks.removeAll(keepingCapacity: false)
        isRedactionMode = false
        model[noticeFor: paperPathSceneID] =
            "Redaction cancelled · PDF unchanged".localizedUI
    }

    private func runMarkup(_ kind: PDFMarkupKind) {
        guard !model.isProcessing(recordID) else {
            model[noticeFor: paperPathSceneID] =
                "Wait for the current document task to finish"
            return
        }
        presentedSheet = nil
        let color = markupColor(for: kind)
        guard let contentRevisionID =
            model.record(id: recordID)?.contentRevisionID
        else { return }
        scheduleWorkspaceTransition(
            expectedContentRevisionID: contentRevisionID
        ) {
            guard !model.isProcessing(recordID) else {
                model[noticeFor: paperPathSceneID] =
                    "Wait for the current document task to finish"
                return
            }
            guard await model.createVersionSnapshot(
                recordID: recordID,
                label: AppLocalization.format(
                    "Add %@ markup",
                    kindTitle(kind).localizedUI
                )
            ) else { return }
            pdfCommand = PDFViewCommand(
                action: .markup(kind),
                markupColor: color
            )
        }
    }

    private func openCreatedDocument(_ route: DocumentRoute) {
        queueWorkspaceHandoff(.openDocument(route))
        presentedSheet = nil
        isPresentingContentEditor = false
        isPresentingLinkEditor = false
        isPresentingImageReplacement = false
        textSelectionForReplacement = nil
    }

    private func scheduleWorkspaceTransition(
        handoff: PendingWorkspaceHandoff? = nil,
        expectedContentRevisionID: UUID? = nil,
        operation: @escaping @MainActor () async -> Void
    ) {
        workspaceTransitionTask?.cancel()
        let generation = UUID()
        workspaceTransitionGeneration = generation
        activeWorkspaceHandoff = handoff
        workspaceHandoffFeedback += 1
        workspaceTransitionTask = Task { @MainActor in
            defer {
                if workspaceTransitionGeneration == generation {
                    workspaceTransitionTask = nil
                    activeWorkspaceHandoff = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  workspaceTransitionGeneration == generation,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable
            else {
                return
            }
            if let expectedContentRevisionID,
               model.record(id: recordID)?.contentRevisionID
                    != expectedContentRevisionID {
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                return
            }
            await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await operation()
            }
        }
    }

    private func cancelWorkspaceTransition(
        showsNotice: Bool = false
    ) {
        workspaceTransitionGeneration = UUID()
        workspaceTransitionTask?.cancel()
        workspaceTransitionTask = nil
        activeWorkspaceHandoff = nil
        if showsNotice {
            model[noticeFor: paperPathSceneID] =
                "Opening next step stopped · PDF unchanged".localizedUI
        }
    }

    private func stopWorkspaceHandoff(
        showsNotice: Bool = false
    ) {
        pendingWorkspaceHandoff = nil
        cancelWorkspaceTransition(showsNotice: showsNotice)
    }

    private func directMutationVersionLabel(
        for action: PDFViewCommand.Action
    ) -> String? {
        switch action {
        case .markup(let kind):
            return AppLocalization.format(
                "Add %@ markup",
                kindTitle(kind).localizedUI
            )
        case .addNote:
            return "Add note".localizedUI
        case .removeAnnotation:
            return "Remove annotation".localizedUI
        case .markRedaction,
             .captureTextForEditing,
             .zoomIn,
             .zoomOut,
             .fitToWindow:
            return nil
        }
    }

    private func markupColor(
        for kind: PDFMarkupKind
    ) -> PDFMarkupColor {
        let rawValue: String
        let fallback: PDFMarkupColor
        switch kind {
        case .highlight:
            rawValue = savedHighlightColor
            fallback = .yellow
        case .underline:
            rawValue = savedUnderlineColor
            fallback = .blue
        case .strikeOut:
            rawValue = savedStrikeColor
            fallback = .red
        }
        return PDFMarkupColor(rawValue: rawValue) ?? fallback
    }

    private func setMarkupColor(
        _ color: PDFMarkupColor,
        for kind: PDFMarkupKind
    ) {
        switch kind {
        case .highlight:
            savedHighlightColor = color.rawValue
        case .underline:
            savedUnderlineColor = color.rawValue
        case .strikeOut:
            savedStrikeColor = color.rawValue
        }
        model[noticeFor: paperPathSceneID] = AppLocalization.format(
            "%@ · %@",
            kindTitle(kind).localizedUI,
            color.title.localizedUI
        )
    }

    private func kindTitle(_ kind: PDFMarkupKind) -> String {
        switch kind {
        case .highlight: return "Highlight"
        case .underline: return "Underline"
        case .strikeOut: return "Strike"
        }
    }

    private func markupSwiftUIColor(
        _ color: PDFMarkupColor
    ) -> Color {
        switch color {
        case .yellow: return .yellow
        case .mint: return .mint
        case .blue: return .blue
        case .pink: return .pink
        case .red: return .red
        }
    }

    private func scheduleReadingPositionSave(
        _ pageIndex: Int,
        expectedContentRevisionID: UUID? = nil
    ) {
        readingPositionTask?.cancel()
        let viewedAt = Date()
        guard let contentRevisionID =
            expectedContentRevisionID
                ?? model.record(id: recordID)?.contentRevisionID,
              pageStateContentRevisionID == contentRevisionID,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        let generation = UUID()
        readingPositionGeneration = generation
        readingPositionTask = Task { @MainActor in
            defer {
                if readingPositionGeneration == generation {
                    readingPositionTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  readingPositionGeneration == generation,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  model.record(id: recordID)?.contentRevisionID
                    == contentRevisionID,
                  pageStateContentRevisionID
                    == contentRevisionID
            else { return }
            await model.updateReadingPosition(
                recordID: recordID,
                pageIndex: pageIndex,
                expectedContentRevisionID:
                    contentRevisionID,
                viewedAt: viewedAt
            )
        }
    }

    private func performWorkspaceMetadataOperation(
        _ operation: WorkspaceMetadataOperation,
        action: @escaping @MainActor () async -> Bool,
        onSuccess: @escaping @MainActor () -> Void = {}
    ) {
        guard workspaceMetadataTask == nil,
              !model.isProcessing(recordID)
        else { return }
        let generation = UUID()
        workspaceMetadataGeneration = generation
        workspaceMetadataStopRequested = false
        activeMetadataOperation = operation
        workspaceMetadataTask = Task { @MainActor in
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await action()
            }
            guard workspaceMetadataGeneration == generation else {
                return
            }
            let wasStopped =
                workspaceMetadataStopRequested || Task.isCancelled
            workspaceMetadataTask = nil
            activeMetadataOperation = nil
            workspaceMetadataStopRequested = false
            if wasStopped {
                if succeeded {
                    metadataSuccessFeedback &+= 1
                    switch operation {
                    case .trash:
                        onSuccess()
                    default:
                        model[noticeFor: paperPathSceneID] =
                            "Metadata update finished before stopping · changes kept"
                                .localizedUI
                    }
                } else {
                    model[noticeFor: paperPathSceneID] =
                        "Metadata update stopped".localizedUI
                }
                return
            }
            if succeeded {
                metadataSuccessFeedback &+= 1
                onSuccess()
            } else {
                metadataErrorFeedback &+= 1
            }
        }
    }

    private func updateWorkflow(
        _ status: DocumentWorkflowStatus
    ) {
        performWorkspaceMetadataOperation(.workflow) {
            await model.updateWorkflow(
                recordID: recordID,
                status: status
            )
        }
    }

    private func togglePinned(
        expectedIsPinned: Bool
    ) {
        performWorkspaceMetadataOperation(.pin) {
            await model.togglePinned(
                recordID: recordID,
                expectedIsPinned: expectedIsPinned
            )
        }
    }

    private func renameWorkingCopy() {
        guard workspaceMetadataTask == nil,
              !model.isProcessing(recordID),
              !proposedName.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty
        else { return }
        let requestedName = proposedName
        let expectedName = originalName
        isRenaming = false
        performWorkspaceMetadataOperation(.rename) {
            await model.rename(
                recordID: recordID,
                to: requestedName,
                expectedName: expectedName
            )
        }
    }

    private func toggleCurrentPageBookmark() {
        let requestedPageIndex = currentPageIndex
        guard let contentRevisionID =
            model.record(id: recordID)?.contentRevisionID
        else { return }
        performWorkspaceMetadataOperation(.bookmark) {
            await model.toggleBookmark(
                recordID: recordID,
                pageIndex: requestedPageIndex,
                expectedContentRevisionID:
                    contentRevisionID
            )
        }
    }

    private func moveWorkingCopyToTrash() {
        performWorkspaceMetadataOperation(
            .trash,
            action: {
                await model.withFeedbackTarget(
                    paperPathSceneID
                ) {
                    await model.delete(recordID: recordID)
                }
            },
            onSuccess: {
                dismiss()
            }
        )
    }

    private func invalidateWorkspaceMetadataPresentation() {
        stopWorkspaceMetadataOperation(invalidateResult: true)
    }

    private func stopWorkspaceMetadataOperation(
        invalidateResult: Bool = false,
        showsNotice: Bool = false
    ) {
        if invalidateResult {
            workspaceMetadataGeneration = UUID()
            workspaceMetadataStopRequested = false
        } else {
            guard workspaceMetadataTask != nil,
                  !workspaceMetadataStopRequested
            else { return }
            workspaceMetadataStopRequested = true
        }
        workspaceMetadataTask?.cancel()
        if invalidateResult {
            workspaceMetadataTask = nil
            activeMetadataOperation = nil
        } else if showsNotice {
            model[noticeFor: paperPathSceneID] =
                "Finishing metadata update".localizedUI
        }
    }

    private var hasBlockingWorkspaceControlTask: Bool {
        shareTask != nil
            || workspaceMetadataTask != nil
            || isWorkspaceHandoffActive
            || model.isProcessing(recordID)
    }

    private var isWorkspaceHandoffActive: Bool {
        pendingWorkspaceHandoff != nil
            || activeWorkspaceHandoff != nil
            || workspaceTransitionTask != nil
    }

    private var processingPill: some View {
        let progress = model.progress(for: recordID)
        let isAnalyzing = model.isAnalyzing(recordID)
        let isComparing = model.isComparing(recordID)
        let metadataOperation = activeMetadataOperation
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.small
                )
            )
            : AnyLayout(HStackLayout(spacing: PPSpacing.small))
        return layout {
            ToolSymbolPlate(
                symbol:
                    metadataOperation?.symbol
                    ?? (
                    isAnalyzing && progress == nil
                    ? "text.magnifyingglass"
                    : isComparing
                        ? "rectangle.2.swap"
                        : recognitionTask == nil
                            ? "gearshape.2"
                            : "text.viewfinder"
                    ),
                tint:
                    metadataOperation != nil
                    ? PPColor.cyan
                    : isAnalyzing && progress == nil
                    ? PPColor.cyan
                    : isComparing
                        ? PPColor.amber
                        : recognitionTask == nil
                            ? PPColor.accent
                            : PPColor.cyan,
                size: 30
            )
            if recognitionStopRequested
                || searchableCopyStopRequested {
                Text(
                    (
                        searchableCopyStopRequested
                            ? "Stopping searchable copy"
                            : "Stopping text recognition"
                    ).localizedUI
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(2)
            } else if let progress {
                LocalOperationProgressView(progress: progress)
                    .frame(minWidth: 190, maxWidth: 280)
            } else {
                Text(
                    (
                        metadataOperation != nil
                            ? (
                                workspaceMetadataStopRequested
                                    ? "Finishing metadata update"
                                    : metadataOperation?.title
                                        ?? "Updating document metadata"
                            )
                            : (
                        isAnalyzing
                            ? "Indexing on device"
                            : isComparing
                                ? "Comparing on device"
                                : "Working on device"
                        )
                    ).localizedUI
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(2)
            }
            if workspaceMetadataTask != nil
                || recognitionTask != nil
                || searchableCopyTask != nil
                || unlockCopyTask != nil
                || isComparing {
                Button {
                    if workspaceMetadataTask != nil {
                        stopWorkspaceMetadataOperation(
                            showsNotice: true
                        )
                    } else if unlockCopyTask != nil {
                        stopUnlockCopyCreation()
                    } else if recognitionTask != nil {
                        stopRecognition(
                            showsNotice: true,
                            invalidateResult: false
                        )
                    } else if searchableCopyTask != nil {
                        stopSearchableCopyCreation(
                            showsNotice: true,
                            invalidateResult: false
                        )
                    } else {
                        model.stopComparisons(recordID: recordID)
                    }
                } label: {
                    if workspaceMetadataStopRequested
                        || unlockCopyStopRequested
                        || recognitionStopRequested
                        || searchableCopyStopRequested {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "stop.fill")
                            .frame(width: 44, height: 44)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.amber)
                .disabled(
                    workspaceMetadataStopRequested
                        || unlockCopyStopRequested
                        || recognitionStopRequested
                        || searchableCopyStopRequested
                )
                .accessibilityLabel(
                    (
                        workspaceMetadataTask != nil
                            ? (
                                workspaceMetadataStopRequested
                                    ? "Finishing metadata update"
                                    : "Stop updating document metadata"
                            )
                        : unlockCopyTask != nil
                            ? (
                                unlockCopyStopRequested
                                    ? "Stopping editable copy"
                                    : "Stop creating editable copy"
                            )
                        : isComparing
                            ? "Stop comparison"
                            : searchableCopyTask != nil
                                ? (
                                    searchableCopyStopRequested
                                        ? "Stopping searchable copy"
                                        : "Stop creating searchable copy"
                                )
                                : recognitionStopRequested
                                    ? "Stopping text recognition"
                                    : "Stop text recognition"
                    ).localizedUI
                )
                .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .frame(maxWidth: 380)
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(
                cornerRadius: PPRadius.control,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: PPRadius.control,
                style: .continuous
            )
                .stroke(PPColor.accent.opacity(0.22), lineWidth: 0.7)
        }
        .shadow(color: .black.opacity(0.14), radius: 10, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func handle(_ action: DocumentAction) {
        switch action {
        case .brief:
            presentedSheet = .brief
        case .recognizeText:
            if model.hasRecognizedText(recordID: recordID) {
                presentedSheet = .recognizedText
            } else {
                openRecognitionSettings()
            }
        case .makeSearchable:
            createSearchableCopy()
        case .organizePages:
            pageOrganizerStartsSelecting = false
            pageOrganizerInitialSelection = []
            presentedSheet = .pages
        case .reviewForm:
            presentedSheet = .formReview
        case .sign:
            presentSignature()
        case .safeShare:
            shareVerifiedOrCreate()
        case .inspect:
            presentedSheet = .insight
        case .shareCopy:
            if model.record(id: recordID)?.profile.isLocked == true {
                share(recordID: recordID)
            } else {
                shareVerifiedOrCreate()
            }
        }
    }

    private func open(_ task: PDFQuickTask) {
        switch task {
        case .signPDF:
            savedToolMode = ToolMode.annotate.rawValue
        case .organizePages, .splitPDF:
            savedToolMode = ToolMode.pages.rawValue
        case .fillForms, .safeShare, .compressPDF, .protectPDF, .exportText, .exportImages:
            savedToolMode = ToolMode.deliver.rawValue
        default:
            break
        }
        switch task {
        case .scanToPDF, .imagesToPDF, .mergePDFs:
            break
        case .splitPDF:
            pageOrganizerStartsSelecting = true
            pageOrganizerInitialSelection = []
            presentedSheet = .pages
        case .organizePages:
            pageOrganizerStartsSelecting = false
            pageOrganizerInitialSelection = []
            presentedSheet = .pages
        case .compressPDF:
            presentedSheet = .compression
        case .fillForms:
            presentedSheet = .formReview
        case .signPDF:
            presentSignature()
        case .redactPDF:
            isRedactionMode = true
            model[noticeFor: paperPathSceneID] = "Select text, then tap Redact"
        case .protectPDF:
            presentedSheet = .protection
        case .safeShare:
            shareVerifiedOrCreate()
        case .recognizeText:
            handle(.recognizeText)
        case .exportText:
            presentedSheet = .officeExport
        case .exportImages:
            presentedSheet = .imageExport
        }
    }

    private func shareVerifiedOrCreate() {
        if let target = model.verifiedShareTarget(for: recordID) {
            share(recordID: target.id)
        } else {
            queueWorkspaceHandoff(.safeShare)
        }
    }

    private func openRecognitionSettings(
        afterDismissal: Bool = false
    ) {
        recognitionConfiguration =
            model.ocrResults[recordID]?.configuration
                ?? recognitionConfiguration
        if afterDismissal {
            queueWorkspaceHandoff(.recognitionSettings)
        } else {
            cancelWorkspaceTransition()
            isConfiguringRecognition = true
        }
    }

    private func completeRecognitionConfigurationDismissal() {
        guard let configuration = pendingRecognitionConfiguration else {
            return
        }
        pendingRecognitionConfiguration = nil
        scheduleWorkspaceTransition {
            startRecognition(configuration)
        }
    }

    private func startRecognition(
        _ configuration: OCRRecognitionConfiguration
    ) {
        guard recognitionTask == nil else { return }
        guard !model.isProcessing(recordID) else {
            model[noticeFor: paperPathSceneID] =
                "Wait for the current document task to finish".localizedUI
            return
        }
        recognitionConfiguration = configuration
        recognitionStopRequested = false
        let generation = UUID()
        recognitionGeneration = generation
        recognitionTask = Task {
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.recognizeText(
                    recordID: recordID,
                    configuration: configuration
                )
            }
            let wasStopped =
                recognitionStopRequested || Task.isCancelled
            guard recognitionGeneration == generation else { return }
            recognitionTask = nil
            recognitionStopRequested = false
            guard !wasStopped else {
                model[noticeFor: paperPathSceneID] = succeeded
                    ? "Text recognition finished before stopping · results kept"
                        .localizedUI
                    : "Text recognition stopped".localizedUI
                return
            }
            if succeeded {
                presentedSheet = .recognizedText
            }
        }
    }

    private func stopRecognition(
        showsNotice: Bool = false,
        invalidateResult: Bool = true
    ) {
        guard recognitionTask != nil else { return }
        if invalidateResult {
            recognitionGeneration = UUID()
            recognitionStopRequested = false
        } else {
            recognitionStopRequested = true
        }
        recognitionTask?.cancel()
        if invalidateResult {
            recognitionTask = nil
        }
        if showsNotice {
            model[noticeFor: paperPathSceneID] =
                "Stopping text recognition".localizedUI
        }
    }

    private func createSearchableCopy() {
        guard searchableCopyTask == nil,
              !model.isProcessing(recordID),
              let sourceContentRevisionID =
                model.record(id: recordID)?.contentRevisionID
        else { return }
        searchableCopyStopRequested = false
        let generation = UUID()
        searchableCopyGeneration = generation
        searchableCopyTask = Task { @MainActor in
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createSearchableCopy(
                    recordID: recordID,
                    expectedContentRevisionID:
                        sourceContentRevisionID
                )
            }
            let wasStopped =
                searchableCopyStopRequested || Task.isCancelled
            guard searchableCopyGeneration == generation else { return }
            searchableCopyTask = nil
            searchableCopyStopRequested = false
            guard !wasStopped else {
                model[noticeFor: paperPathSceneID] = created == nil
                    ? "Searchable copy stopped".localizedUI
                    : "Searchable copy finished before stopping · copy kept in Library"
                        .localizedUI
                return
            }
            guard let created else { return }
            openCreatedDocument(
                DocumentRoute(recordID: created.id)
            )
        }
    }

    private func stopSearchableCopyCreation(
        showsNotice: Bool = false,
        invalidateResult: Bool = true
    ) {
        guard searchableCopyTask != nil else { return }
        if invalidateResult {
            searchableCopyGeneration = UUID()
            searchableCopyStopRequested = false
        } else {
            searchableCopyStopRequested = true
        }
        searchableCopyTask?.cancel()
        if invalidateResult {
            searchableCopyTask = nil
        }
        if showsNotice {
            model[noticeFor: paperPathSceneID] =
                "Stopping searchable copy".localizedUI
        }
    }

    private func openSafeShareAfterDismissal() {
        queueWorkspaceHandoff(.safeShare)
    }

    private func handleWorkspacePresentationDismissal() {
        cleanupShareCopy()
        guard !hasActiveWorkspacePresentation,
              let handoff = pendingWorkspaceHandoff
        else { return }
        pendingWorkspaceHandoff = nil
        scheduleWorkspaceTransition(handoff: handoff) {
            await performWorkspaceHandoff(handoff)
        }
    }

    private var hasActiveWorkspacePresentation: Bool {
        presentedSheet != nil
            || isPrivacyScanPresented
            || isPresentingSignature
            || isPresentingPencil
            || isPresentingContentEditor
            || isPresentingLinkEditor
            || isPresentingImageReplacement
            || textSelectionForReplacement != nil
    }

    private var hasBlockingWorkspacePresentation: Bool {
        hasActiveWorkspacePresentation
            || isAddingNote
            || isUnlocking
            || isConfiguringRecognition
            || isRenaming
            || isJumpingToPage
            || isConfirmingDelete
    }

    private func queueWorkspaceHandoff(
        _ handoff: PendingWorkspaceHandoff
    ) {
        cancelWorkspaceTransition()
        let revisionBoundHandoff: PendingWorkspaceHandoff
        switch handoff {
        case .openDocument(let route):
            revisionBoundHandoff = .openDocument(
                route.bindingExpectedRevision(
                    model.record(id: route.recordID)?
                        .contentRevisionID
                )
            )
        default:
            revisionBoundHandoff = handoff
        }
        pendingWorkspaceHandoff = revisionBoundHandoff
        workspaceHandoffFeedback += 1
        if presentedSheet != nil {
            presentedSheet = nil
            return
        }
        guard !hasActiveWorkspacePresentation else { return }
        handleWorkspacePresentationDismissal()
    }

    @MainActor
    private func performWorkspaceHandoff(
        _ handoff: PendingWorkspaceHandoff
    ) async {
        guard !Task.isCancelled else { return }
        switch handoff {
        case .tool(let tool):
            handle(tool)
        case .action(let action):
            handle(action)
        case .stamp(
            let kind,
            let pageIndex,
            let contentRevisionID
        ):
            guard model.record(id: recordID)?.contentRevisionID
                    == contentRevisionID
            else {
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                return
            }
            await model.addStamp(
                recordID: recordID,
                pageIndex: pageIndex,
                kind: kind
            )
        case .openDocument(let route):
            guard model.record(id: route.recordID) != nil else {
                model[noticeFor: paperPathSceneID] =
                    "The document is no longer available".localizedUI
                return
            }
            onOpenDocument(route)
        case .safeShare:
            guard let record = model.record(id: recordID) else {
                model[noticeFor: paperPathSceneID] =
                    "The document is no longer available".localizedUI
                return
            }
            let checkpointSaved: Bool
            if record.taskCheckpoint?.stage == .verify,
               record.taskCheckpoint?.contentRevisionID
                == record.contentRevisionID {
                checkpointSaved = true
            } else {
                checkpointSaved =
                    await model.updateTaskCheckpoint(
                        recordID: recordID,
                        checkpoint: DocumentTaskCheckpoint(
                            stage: .verify,
                            contentRevisionID:
                                record.contentRevisionID
                        ),
                        presentsFeedback: false
                    )
            }
            guard !Task.isCancelled else { return }
            guard model.record(id: recordID) != nil else {
                model[noticeFor: paperPathSceneID] =
                    "The document is no longer available".localizedUI
                return
            }
            if let target =
                model.verifiedShareTarget(for: recordID) {
                share(recordID: target.id)
                return
            }
            presentedSheet = .verifiedExport
            if !checkpointSaved {
                model[noticeFor: paperPathSceneID] =
                    "Opening verified output · resume point not saved"
                        .localizedUI
            }
        case .unlockForVerifiedOutput:
            guard let record = model.record(id: recordID) else {
                model[noticeFor: paperPathSceneID] =
                    "The document is no longer available".localizedUI
                return
            }
            guard record.profile.isLocked else {
                presentedSheet = .verifiedExport
                return
            }
            continuesVerifiedOutputAfterUnlock = true
            unlockCopyIssue = nil
            if isSessionUnlocked {
                createUnlockedPrivateCopy()
            } else {
                isUnlocking = true
            }
        case .recognitionSettings:
            guard recognitionTask == nil else { return }
            isConfiguringRecognition = true
        case .presentSheet(let sheet):
            presentedSheet = sheet
        case .navigate(
            let pageIndex,
            let message,
            let recordsHistory,
            let nextSheet,
            let showsNotice,
            let contentRevisionID
        ):
            guard model.record(id: recordID)?.contentRevisionID
                    == contentRevisionID
            else {
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                return
            }
            _ = commitPageNavigation(
                pageIndex,
                message: message,
                recordsHistory: recordsHistory,
                showsNotice: showsNotice
            )
            if let nextSheet {
                await Task.yield()
                guard !Task.isCancelled else { return }
                presentedSheet = nextSheet
            }
        case .signature(
            let pageIndex,
            let initialBounds,
            let fieldName,
            let navigationMessage,
            let updatesCheckpoint,
            let contentRevisionID
        ):
            guard model.record(id: recordID)?.contentRevisionID
                    == contentRevisionID
            else {
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this field opened. Review the updated form."
                        .localizedUI
                return
            }
            let resolvedPageIndex = commitPageNavigation(
                pageIndex,
                message: navigationMessage,
                recordsHistory: true
            ) ?? pageIndex
            await Task.yield()
            guard !Task.isCancelled,
                  model.record(id: recordID)?.contentRevisionID
                    == contentRevisionID
            else { return }
            presentSignature(
                pageIndex: resolvedPageIndex,
                initialBounds: initialBounds,
                fieldName: fieldName,
                updatesCheckpoint: updatesCheckpoint
            )
        }
    }

    private func share(recordID targetID: UUID) {
        guard shareTask == nil else { return }
        guard model.url(for: targetID) != nil else {
            model[noticeFor: paperPathSceneID] = "The PDF could not be found"
            return
        }
        cleanupShareCopy()
        let generation = UUID()
        shareGeneration = generation
        shareRateWindow.reset()
        shareProgress = PDFOperationProgress(
            label: "Verifying protected share copy",
            fractionCompleted: 0,
            byteStage: .checksumming
        )
        model[noticeFor: paperPathSceneID] = "Preparing protected share copy".localizedUI
        shareTask = Task { @MainActor in
            let url = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.makeFilesExportCopy(
                    recordID: targetID
                ) { update in
                    guard shareGeneration == generation else { return }
                    if let progress =
                        shareRateWindow.operationProgress(
                            label: "Verifying protected share copy",
                            update: update,
                            current: shareProgress
                        ) {
                        shareProgress = progress
                    }
                }
            }
            guard shareGeneration == generation else {
                if let url {
                    await model.discardFilesExportCopy(at: url)
                }
                return
            }
            shareTask = nil
            shareProgress = nil
            shareRateWindow.reset()
            guard !Task.isCancelled, let url else {
                if let url {
                    await model.discardFilesExportCopy(at: url)
                }
                return
            }
            temporaryShareURL = url
            shareItems = [url]
            presentedSheet = .share
            model[noticeFor: paperPathSceneID] = (
                targetID == recordID
                    ? "Protected share copy ready"
                    : "Sharing the latest verified copy"
            ).localizedUI
        }
    }

    private func stopSharePreparation(
        showsNotice: Bool = false
    ) {
        shareGeneration = UUID()
        shareTask?.cancel()
        shareTask = nil
        shareProgress = nil
        shareRateWindow.reset()
        if showsNotice {
            model[noticeFor: paperPathSceneID] =
                "Share preparation stopped".localizedUI
        }
    }

    private func cleanupShareCopy() {
        let url = temporaryShareURL
        temporaryShareURL = nil
        shareItems = []
        guard let url else { return }
        Task {
            await model.discardFilesExportCopy(at: url)
        }
    }

    private func printDocument(
        record: DocumentRecord,
        url: URL
    ) {
        guard UIPrintInteractionController.isPrintingAvailable,
              UIPrintInteractionController.canPrint(url)
        else {
            model[noticeFor: paperPathSceneID] = "Printing is unavailable for this PDF"
            return
        }

        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = record.displayName
        controller.printInfo = info
        controller.showsNumberOfCopies = true
        controller.printingItem = url

        let completion:
            UIPrintInteractionController.CompletionHandler = {
            _, completed, error in
            Task { @MainActor in
                if let error {
                    model.present(error, in: paperPathSceneID)
                } else if completed {
                    model[noticeFor: paperPathSceneID] = "Print job handed to iOS"
                }
            }
        }

        if UIDevice.current.userInterfaceIdiom == .pad,
           let view = activePresentationView() {
            let anchor = CGRect(
                x: view.bounds.midX,
                y: view.bounds.maxY - 8,
                width: 1,
                height: 1
            )
            controller.present(
                from: anchor,
                in: view,
                animated: true,
                completionHandler: completion
            )
        } else {
            controller.present(
                animated: true,
                completionHandler: completion
            )
        }
    }

    private func activePresentationView() -> UIView? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller?.view
    }

    private func handle(
        _ step: SuggestedStep,
        pageIndex: Int?
    ) {
        switch step.kind {
        case .recognize:
            openRecognitionSettings(afterDismissal: true)
        case .organize:
            pageOrganizerStartsSelecting = false
            pageOrganizerInitialSelection = []
            queueWorkspaceHandoff(.presentSheet(.pages))
        case .share:
            queueWorkspaceHandoff(.safeShare)
        case .completeForm:
            queueWorkspaceHandoff(.presentSheet(.formReview))
        case .reviewSignature:
            showPageThenSignature(pageIndex)
        case .reviewDate, .reviewAmount:
            showPage(pageIndex, message: "Showing supporting evidence")
        }
    }

    private func showPage(
        _ pageIndex: Int?,
        message: String,
        thenPresent sheet: Sheet? = nil,
        recordsHistory: Bool = true,
        dismissesPresentedSheet: Bool = true,
        showsNotice: Bool = true
    ) {
        guard let pageIndex else {
            cancelWorkspaceTransition()
            if let sheet {
                presentedSheet = sheet
                model[noticeFor: paperPathSceneID] = "Evidence page unavailable · continuing"
            } else {
                model[noticeFor: paperPathSceneID] = "The evidence page could not be located"
            }
            return
        }
        if !dismissesPresentedSheet {
            cancelWorkspaceTransition()
            _ = commitPageNavigation(
                pageIndex,
                message: message,
                recordsHistory: recordsHistory,
                showsNotice: showsNotice
            )
            return
        }
        guard let contentRevisionID =
            model.record(id: recordID)?.contentRevisionID
        else {
            model[noticeFor: paperPathSceneID] =
                "The document is no longer available".localizedUI
            return
        }
        queueWorkspaceHandoff(
            .navigate(
                pageIndex: pageIndex,
                message: message,
                recordsHistory: recordsHistory,
                thenPresent: sheet,
                showsNotice: showsNotice,
                contentRevisionID: contentRevisionID
            )
        )
    }

    @discardableResult
    private func commitPageNavigation(
        _ pageIndex: Int,
        message: String,
        recordsHistory: Bool,
        showsNotice: Bool = true
    ) -> Int? {
        guard let record = model.record(id: recordID),
              record.profile.pageCount > 0,
              pageStateContentRevisionID
                == record.contentRevisionID
        else { return nil }
        let resolvedPageIndex = min(
            max(0, pageIndex),
            record.profile.pageCount - 1
        )
        if pdfSearchHighlight?.pageIndex != resolvedPageIndex {
            pdfSearchHighlight = nil
        }
        if privacyEvidenceOverlay?.pageIndex != resolvedPageIndex {
            privacyEvidenceOverlay = nil
        }
        if recordsHistory,
           resolvedPageIndex != currentPageIndex {
            if pageBackHistory.last != currentPageIndex {
                pageBackHistory.append(currentPageIndex)
                if pageBackHistory.count > 32 {
                    pageBackHistory.removeFirst(
                        pageBackHistory.count - 32
                    )
                }
            }
            pageForwardHistory.removeAll()
        }
        if resolvedPageIndex != currentPageIndex {
            pageNavigationFeedback &+= 1
        }
        requestedPageIndex = resolvedPageIndex
        pageNavigationToken += 1
        currentPageIndex = resolvedPageIndex
        if !isScrubbingPage {
            pageScrubberValue = Double(resolvedPageIndex)
        }
        scheduleReadingPositionSave(
            resolvedPageIndex,
            expectedContentRevisionID:
                record.contentRevisionID
        )
        onReadingPositionChange(
            resolvedPageIndex,
            record.contentRevisionID
        )
        if showsNotice {
            model[noticeFor: paperPathSceneID] = AppLocalization.format(
                "%@ · page %lld",
                message.localizedUI,
                resolvedPageIndex + 1
            )
        }
        return resolvedPageIndex
    }

    private func reconcilePageState(pageCount: Int?) {
        guard let pageCount, pageCount > 0 else {
            pageBackHistory.removeAll(keepingCapacity: false)
            pageForwardHistory.removeAll(keepingCapacity: false)
            currentPageIndex = 0
            pageScrubberValue = 0
            requestedPageIndex = nil
            return
        }
        let maximumPageIndex = pageCount - 1
        pageBackHistory.removeAll {
            $0 < 0 || $0 > maximumPageIndex
        }
        pageForwardHistory.removeAll {
            $0 < 0 || $0 > maximumPageIndex
        }
        let resolvedCurrent = min(
            max(0, currentPageIndex),
            maximumPageIndex
        )
        let requestedWasOutOfRange = requestedPageIndex.map {
            $0 < 0 || $0 > maximumPageIndex
        } ?? false
        guard resolvedCurrent != currentPageIndex
                || requestedWasOutOfRange
        else {
            pageScrubberValue = min(
                max(0, pageScrubberValue),
                Double(maximumPageIndex)
            )
            return
        }
        currentPageIndex = resolvedCurrent
        pageScrubberValue = Double(resolvedCurrent)
        requestedPageIndex = resolvedCurrent
        pageNavigationToken += 1
        if let contentRevisionID = pageStateContentRevisionID {
            onReadingPositionChange(
                resolvedCurrent,
                contentRevisionID
            )
        }
        model[noticeFor: paperPathSceneID] = AppLocalization.format(
            "Moved to the last available page · page %lld",
            resolvedCurrent + 1
        )
    }

    private func rebuildPageStateForUpdatedPDF(
        from oldRevisionID: UUID,
        to newRevisionID: UUID
    ) {
        guard oldRevisionID != newRevisionID,
              let record = model.record(id: recordID),
              record.contentRevisionID == newRevisionID
        else { return }

        readingPositionTask?.cancel()
        readingPositionTask = nil
        cancelWorkspaceTransition()
        pendingWorkspaceHandoff = nil
        activeWorkspaceHandoff = nil
        pendingRecognitionConfiguration = nil
        pageOrganizerStartsSelecting = false
        pageOrganizerInitialSelection.removeAll(
            keepingCapacity: false
        )
        signaturePageIndex = nil
        signatureInitialBounds = nil
        pdfSearchHighlight = nil
        privacyEvidenceOverlay = nil
        pdfCommand = nil
        textSelectionForReplacement = nil
        redactionMarks.removeAll(keepingCapacity: false)
        isAddingNote = false
        pendingNote = nil
        pageBackHistory.removeAll(keepingCapacity: false)
        pageForwardHistory.removeAll(keepingCapacity: false)
        documentFindQuery = ""
        documentFindHistory.removeAll(keepingCapacity: false)
        pageJumpInput = ""
        isJumpingToPage = false
        isScrubbingPage = false
        pageStateContentRevisionID = newRevisionID

        let pageCount = record.profile.pageCount
        guard pageCount > 0 else {
            currentPageIndex = 0
            pageScrubberValue = 0
            requestedPageIndex = nil
            pageNavigationToken &+= 1
            return
        }
        let restoredPageIndex = min(
            max(0, currentPageIndex),
            pageCount - 1
        )
        let didMoveReadingPosition =
            restoredPageIndex != currentPageIndex
        currentPageIndex = restoredPageIndex
        pageScrubberValue = Double(restoredPageIndex)
        requestedPageIndex = restoredPageIndex
        pageNavigationToken &+= 1
        onReadingPositionChange(
            restoredPageIndex,
            newRevisionID
        )
        if didMoveReadingPosition,
           !hasActiveWorkspacePresentation {
            model[noticeFor: paperPathSceneID] =
                "PDF updated · reading position refreshed".localizedUI
        }
        Task {
            await model.ensureAnalysisLoaded(for: recordID)
        }
    }

    private func navigateBack() {
        cancelWorkspaceTransition()
        guard let page = pageBackHistory.popLast() else { return }
        if pageForwardHistory.last != currentPageIndex {
            pageForwardHistory.append(currentPageIndex)
        }
        commitPageNavigation(
            page,
            message: "Back",
            recordsHistory: false,
            showsNotice: false
        )
    }

    private func navigateForward() {
        cancelWorkspaceTransition()
        guard let page = pageForwardHistory.popLast() else { return }
        if pageBackHistory.last != currentPageIndex {
            pageBackHistory.append(currentPageIndex)
        }
        commitPageNavigation(
            page,
            message: "Forward",
            recordsHistory: false,
            showsNotice: false
        )
    }

    private func openChangedPage(
        targetRecordID: UUID,
        pageIndex: Int
    ) {
        guard model.record(id: targetRecordID) != nil else {
            model[noticeFor: paperPathSceneID] = "The changed page is no longer available"
            return
        }
        guard targetRecordID != recordID else {
            showPage(
                pageIndex,
                message: "Opened linked evidence"
            )
            return
        }
        queueWorkspaceHandoff(
            .openDocument(
                DocumentRoute(
                    recordID: targetRecordID,
                    pageIndex: pageIndex
                )
            )
        )
    }

    private func openRecentDocument(
        _ record: DocumentRecord
    ) {
        guard record.id != recordID,
              model.record(id: record.id) != nil
        else { return }
        readingPositionTask?.cancel()
        queueWorkspaceHandoff(
            .openDocument(
                DocumentRoute(
                    recordID: record.id,
                    pageIndex: record.lastPageIndex,
                    expectedContentRevisionID:
                        record.contentRevisionID
                )
            )
        )
    }

    private func showPageThenSignature(
        _ pageIndex: Int?,
        initialBounds: PDFNormalizedRect? = nil,
        fieldName: String? = nil,
        navigationMessage: String = "Signature evidence",
        updatesCheckpoint: Bool = true
    ) {
        guard let contentRevisionID =
            model.record(id: recordID)?.contentRevisionID
        else {
            model[noticeFor: paperPathSceneID] =
                "The document is no longer available".localizedUI
            return
        }
        guard let pageIndex else {
            queueWorkspaceHandoff(
                .signature(
                    pageIndex: currentPageIndex,
                    initialBounds: initialBounds,
                    fieldName: fieldName,
                    navigationMessage:
                        navigationMessage == "Signature evidence"
                            ? "Evidence page unavailable · continuing"
                            : navigationMessage,
                    updatesCheckpoint: updatesCheckpoint,
                    contentRevisionID: contentRevisionID
                )
            )
            return
        }
        queueWorkspaceHandoff(
            .signature(
                pageIndex: pageIndex,
                initialBounds: initialBounds,
                fieldName: fieldName,
                navigationMessage: navigationMessage,
                updatesCheckpoint: updatesCheckpoint,
                contentRevisionID: contentRevisionID
            )
        )
    }

    private func presentSignature(
        pageIndex: Int? = nil,
        initialBounds: PDFNormalizedRect? = nil,
        fieldName: String? = nil,
        updatesCheckpoint: Bool = true
    ) {
        let targetPageIndex = pageIndex ?? currentPageIndex
        if updatesCheckpoint,
           let contentRevisionID =
            model.record(id: recordID)?.contentRevisionID {
            Task {
                await model.updateTaskCheckpoint(
                    recordID: recordID,
                    checkpoint: DocumentTaskCheckpoint(
                        stage: .sign,
                        pageIndex: targetPageIndex,
                        fieldName: fieldName,
                        normalizedBounds: initialBounds,
                        contentRevisionID: contentRevisionID
                    )
                )
            }
        }
        signaturePageIndex = targetPageIndex
        signatureInitialBounds = initialBounds
        isPresentingSignature = true
    }

    private func restoreReadingPreferences() {
        guard !didRestoreReadingPreferences else { return }
        readingPreferences = PDFReadingPreferences(
            theme: PDFReadingTheme(rawValue: savedReadingTheme) ?? .paper,
            layout: PDFReadingLayout(rawValue: savedReadingLayout) ?? .continuous,
            scrollsHorizontally: savedHorizontalNavigation
        )
        didRestoreReadingPreferences = true
    }

    private var recentTools: [DocumentTool] {
        savedRecentTools
            .split(separator: ",")
            .compactMap { DocumentTool(rawValue: String($0)) }
    }

    private var favoriteTools: [DocumentTool] {
        var tools: [DocumentTool] = []
        for value in savedFavoriteTools.split(separator: ",") {
            guard let tool = DocumentTool(rawValue: String(value)),
                  !tools.contains(tool)
            else { continue }
            tools.append(tool)
        }
        return tools
    }
}
