import SwiftUI
import UIKit

struct DocumentWorkspaceView: View {
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
        case reading
        case bookmarks
        case formReview
        case find
        case annotations
        case attachments
        case compare
        case deliveryReceipt
        case deliveryHistory
        case sourceLocation
        case technicalInspector
        case versionHistory
        case reader
        case privateNote

        var id: String { rawValue }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("reading.theme") private var savedReadingTheme = PDFReadingTheme.paper.rawValue
    @AppStorage("reading.layout") private var savedReadingLayout = PDFReadingLayout.continuous.rawValue
    @AppStorage("reading.horizontal") private var savedHorizontalNavigation = false
    @AppStorage("markup.highlightColor")
    private var savedHighlightColor = PDFMarkupColor.yellow.rawValue
    @AppStorage("markup.underlineColor")
    private var savedUnderlineColor = PDFMarkupColor.blue.rawValue
    @AppStorage("markup.strikeColor")
    private var savedStrikeColor = PDFMarkupColor.red.rawValue

    let recordID: UUID
    let initialPageIndex: Int?
    let initialQuickTask: PDFQuickTask?
    let onOpenDocument: (DocumentRoute) -> Void

    @State private var presentedSheet: Sheet?
    @State private var isRenaming = false
    @State private var proposedName = ""
    @State private var isJumpingToPage = false
    @State private var pageJumpInput = ""
    @State private var isConfirmingDelete = false
    @State private var requestedPageIndex: Int?
    @State private var pageNavigationToken = 0
    @State private var recognitionTask: Task<Void, Never>?
    @State private var readingPositionTask: Task<Void, Never>?
    @State private var readingPreferences = PDFReadingPreferences()
    @State private var pdfCommand: PDFViewCommand?
    @State private var currentPageIndex = 0
    @State private var pageScrubberValue = 0.0
    @State private var isScrubbingPage = false
    @State private var pageBackHistory: [Int] = []
    @State private var pageForwardHistory: [Int] = []
    @State private var isImmersiveReading = false
    @State private var redactionMarks: [PDFRedactionMark] = []
    @State private var isAddingNote = false
    @State private var isUnlocking = false
    @State private var unlockInput = ""
    @State private var sessionPassword: String?
    @State private var isSessionUnlocked = false
    @State private var didRestoreReadingPreferences = false
    @State private var didHandleInitialQuickTask = false
    @State private var pageOrganizerStartsSelecting = false
    @State private var exportFocus: PDFExportFocus?
    @State private var isRedactionMode = false
    @State private var recommendationTapCount = 0
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
    @State private var textSelectionForReplacement:
        PDFTextSelectionSnapshot?
    @AppStorage("document.recentTools") private var savedRecentTools = ""
    @AppStorage("document.favoriteTools")
    private var savedFavoriteTools = ""

    init(
        recordID: UUID,
        initialPageIndex: Int? = nil,
        initialQuickTask: PDFQuickTask? = nil,
        onOpenDocument: @escaping (DocumentRoute) -> Void = { _ in }
    ) {
        self.recordID = recordID
        self.initialPageIndex = initialPageIndex
        self.initialQuickTask = initialQuickTask
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
        .task(id: initialPageIndex) {
            guard let initialPageIndex else { return }
            await Task.yield()
            model.noticeMessage = "Opened at match · page \(initialPageIndex + 1)"
        }
        .task(id: initialQuickTask) {
            guard !didHandleInitialQuickTask,
                  let initialQuickTask
            else { return }
            didHandleInitialQuickTask = true
            await Task.yield()
            if let checkpoint = model.record(id: recordID)?
                .taskCheckpoint,
               checkpoint.stage.quickTask == initialQuickTask {
                resume(checkpoint)
            } else {
                open(initialQuickTask)
            }
        }
        .task(id: recordID) {
            await model.synchronizeCompletionState(recordID: recordID)
            guard initialPageIndex == nil,
                  let record = model.record(id: recordID)
            else { return }
            currentPageIndex = record.lastPageIndex
            pageScrubberValue = Double(record.lastPageIndex)
            if record.lastPageIndex > 0 {
                await Task.yield()
                showPage(
                    record.lastPageIndex,
                    message: "Resumed at page \(record.lastPageIndex + 1)",
                    recordsHistory: false
                )
            } else {
                await model.updateReadingPosition(
                    recordID: recordID,
                    pageIndex: 0
                )
            }
        }
        .onDisappear {
            recognitionTask?.cancel()
            recognitionTask = nil
            readingPositionTask?.cancel()
            readingPositionTask = nil
            let pageIndex = currentPageIndex
            Task {
                await model.updateReadingPosition(
                    recordID: recordID,
                    pageIndex: pageIndex
                )
            }
        }
    }

    private func workspace(record: DocumentRecord, url: URL) -> some View {
        ZStack {
            PPCanvas()

            VStack(spacing: 0) {
                if !isImmersiveReading,
                   horizontalSizeClass == .regular,
                   !model.recentDocuments(
                        excluding: record.id,
                        limit: 1
                   ).isEmpty {
                    recentDocumentTabs(current: record)
                }

                if !isImmersiveReading {
                    workspaceContextStrip(record)
                        .frame(
                            maxWidth: horizontalSizeClass == .regular
                                ? 1_080
                                : .infinity
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, PPSpacing.regular)
                        .padding(.top, PPSpacing.small)
                        .padding(.bottom, PPSpacing.small)
                }

                PDFDocumentView(
                    url: url,
                    refreshToken: model.refreshToken(for: recordID),
                    targetPageIndex: requestedPageIndex,
                    navigationToken: pageNavigationToken,
                    readingPreferences: readingPreferences,
                    command: pdfCommand,
                    onMutation: {
                        Task {
                            await model.refreshAfterAnnotation(
                                recordID: recordID
                            )
                        }
                    },
                    onRedactionMarks: { marks in
                        guard !marks.isEmpty else {
                            model.noticeMessage = "Select text before marking a redaction"
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
                        currentPageIndex = pageIndex
                        if !isScrubbingPage {
                            pageScrubberValue = Double(pageIndex)
                        }
                        scheduleReadingPositionSave(pageIndex)
                    },
                    onCommandMessage: { message in
                        model.noticeMessage = message
                    },
                    unlockPassword: sessionPassword,
                    onUnlock: { success in
                        isSessionUnlocked = success
                        if success {
                            unlockInput = ""
                            model.noticeMessage = "Protected PDF unlocked for this session"
                        } else {
                            sessionPassword = nil
                            model.noticeMessage = "The password didn’t match"
                        }
                    }
                )
                .background(PPColor.surfaceMuted)
                .overlay {
                    if !isImmersiveReading {
                        StudioStageMarks(
                            tint: record.profile.isLocked
                                ? PPColor.amber
                                : PPColor.accent,
                            inset: horizontalSizeClass == .regular
                                ? 14
                                : 8,
                            arm: horizontalSizeClass == .regular
                                ? 18
                                : 12
                        )
                    }
                }
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
                    if model.isProcessing(recordID) {
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
                    withAnimation(
                        reduceMotion
                            ? nil
                            : .snappy(duration: 0.24)
                    ) {
                        isImmersiveReading = false
                    }
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
                .padding(PPSpacing.regular)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .bottomTrailing
                )
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Exit immersive reading")
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
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(record.displayName)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                        .accessibilityIdentifier(
                            "workspaceDocumentTitle"
                        )
                    Text(record.subtitle)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textSecondary)
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
                        presentedSheet = .reading
                    } label: {
                        Label("Reading Settings", systemImage: "textformat.size")
                    }
                    Button {
                        withAnimation(
                            reduceMotion
                                ? nil
                                : .snappy(duration: 0.24)
                        ) {
                            isImmersiveReading = true
                        }
                    } label: {
                        Label(
                            "Immersive Reading",
                            systemImage:
                                "arrow.up.left.and.arrow.down.right"
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
                    Button {
                        presentedSheet = .bookmarks
                    } label: {
                        Label(
                            "Bookmarks & Outline",
                            systemImage: "bookmark"
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
                    let recent = model.recentDocuments(
                        excluding: recordID
                    )
                    if !recent.isEmpty {
                        Divider()
                        Menu("Recent Documents") {
                            ForEach(recent) { recentRecord in
                                Button {
                                    readingPositionTask?.cancel()
                                    onOpenDocument(
                                        DocumentRoute(
                                            recordID: recentRecord.id,
                                            pageIndex: recentRecord
                                                .lastPageIndex
                                        )
                                    )
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
                } label: {
                    Image(systemName: "book.pages")
                }
                .accessibilityLabel("Reading and navigation")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Menu("Move to") {
                        ForEach(DocumentWorkflowStatus.allCases) { status in
                            Button {
                                Task {
                                    await model.updateWorkflow(
                                        recordID: recordID,
                                        status: status
                                    )
                                }
                            } label: {
                                Label(
                                    status.title.localizedUI,
                                    systemImage: status.symbol
                                )
                            }
                        }
                    }

                    Button {
                        Task {
                            await model.togglePinned(recordID: recordID)
                        }
                    } label: {
                        Label(
                            record.isPinned ? "Unpin" : "Pin",
                            systemImage: record.isPinned ? "pin.slash" : "pin"
                        )
                    }

                    Button {
                        proposedName = record.displayName
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }

                    Button {
                        presentedSheet = record.brief == nil ? .insight : .brief
                    } label: {
                        Label(
                            "File & privacy details",
                            systemImage: "info.circle"
                        )
                    }

                    Button {
                        presentedSheet = .technicalInspector
                    } label: {
                        Label(
                            "Technical Inspector",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }

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
                            "Files & Source",
                            systemImage: "folder.badge.gearshape"
                        )
                    }

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

                    let verifiedOutputs = model.verifiedOutputs(
                        for: record.id
                    )
                    if !verifiedOutputs.isEmpty {
                        Button {
                            presentedSheet = .deliveryHistory
                        } label: {
                            Label(
                                "Verified outputs (\(verifiedOutputs.count))",
                                systemImage: "clock.badge.checkmark"
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
                .accessibilityLabel("Document menu")
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .brief:
                DocumentBriefView(recordID: recordID) { step, pageIndex in
                    handle(step, pageIndex: pageIndex)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .insight:
                DocumentInsightView(record: record)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .pages:
                PageOrganizerView(
                    recordID: recordID,
                    startInSelectionMode: pageOrganizerStartsSelecting,
                    onCreated: onOpenDocument
                )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .recognizedText:
                RecognizedTextView(
                    recordID: recordID,
                    onCreated: onOpenDocument,
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
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .share:
                ShareSheet(items: shareItems.isEmpty ? [url] : shareItems)
                    .presentationDetents([.medium, .large])
            case .tools:
                DocumentToolPalette(
                    recordTitle: record.displayName,
                    documentURL: url,
                    refreshToken: model.refreshToken(for: recordID),
                    availableTools: availableTools(for: record),
                    unavailableReasons: unavailableToolReasons(
                        for: record
                    ),
                    recentTools: recentTools,
                    contextualTools: contextualTools(for: record),
                    onSelect: handle
                )
                .presentationDetents([.medium, .large])
            case .stamp:
                StampPickerView(pageIndex: currentPageIndex) { kind in
                    Task {
                        await model.addStamp(
                            recordID: recordID,
                            pageIndex: currentPageIndex,
                            kind: kind
                        )
                    }
                }
                .presentationDetents([.medium, .large])
            case .watermark:
                WatermarkSheet(
                    pageCount: record.profile.pageCount,
                    onApply: { payload in
                        await model.applyWatermark(
                            recordID: recordID,
                            payload: payload
                        )
                    },
                    onRemoveAll: {
                        await model.removeGeneratedWatermarks(
                            recordID: recordID
                        )
                    }
                )
                .presentationDetents([.large])
            case .bates:
                BatesNumberingSheet(
                    pageCount: record.profile.pageCount,
                    onApply: { payload in
                        await model.applyBatesNumbers(
                            recordID: recordID,
                            payload: payload
                        )
                    },
                    onRemoveAll: {
                        await model.removeGeneratedBatesNumbers(
                            recordID: recordID
                        )
                    }
                )
                .presentationDetents([.large])
            case .compression:
                CompressionSheet(
                    recordID: recordID,
                    onCreated: onOpenDocument
                )
            case .protection:
                ProtectionSheet(
                    recordID: recordID,
                    onCreated: onOpenDocument
                )
            case .redaction:
                RedactionReviewSheet(
                    recordID: recordID,
                    marks: $redactionMarks
                ) { route in
                    redactionMarks = []
                    onOpenDocument(route)
                }
            case .export:
                DocumentExportSheet(
                    recordID: recordID,
                    focus: exportFocus,
                    onCreated: onOpenDocument,
                    onReviewPage: { pageIndex in
                        showPage(
                            pageIndex,
                            message: "Reviewing preflight issue"
                        )
                    }
                )
            case .reading:
                ReadingSettingsSheet(preferences: $readingPreferences)
                .presentationDetents([.medium])
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
                        presentedSheet = nil
                        onOpenDocument(route)
                    }
                )
            case .formReview:
                FormReviewView(
                    recordID: recordID,
                    initialPageIndex: currentPageIndex,
                    onSelectPage: { pageIndex in
                        showPage(pageIndex, message: "Opened form field")
                    },
                    onSignField: { field in
                        showPageThenSignature(
                            field.pageIndex,
                            initialBounds: field.normalizedBounds
                        )
                    },
                    onPrepare: {
                        openSafeShareAfterDismissal()
                    }
                )
            case .find:
                DocumentFindView(recordID: recordID) { pageIndex in
                    showPage(
                        pageIndex,
                        message: "Previewing search result",
                        dismissesPresentedSheet: false
                    )
                }
                .presentationDetents([.medium, .large])
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
                    onOpenPage: openChangedPage
                )
            case .deliveryReceipt:
                DeliveryReceiptView(
                    recordID: recordID,
                    onOpenPage: openChangedPage
                )
            case .deliveryHistory:
                DeliveryHistoryView(sourceRecordID: recordID) { route in
                    presentedSheet = nil
                    onOpenDocument(route)
                }
            case .sourceLocation:
                SourceLocationView(
                    recordID: recordID,
                    onOpenDocument: onOpenDocument
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
                    initialPageIndex: currentPageIndex
                ) { pageIndex in
                    showPage(pageIndex, message: "Opened from Focus Reader")
                }
            }
        }
        .sheet(isPresented: $isConfiguringRecognition) {
            OCRConfigurationSheet(
                initialConfiguration: recognitionConfiguration
            ) { configuration in
                startRecognition(configuration)
            }
            .id(recognitionConfiguration)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(
            isPresented: $isPresentingSignature,
            onDismiss: {
                signaturePageIndex = nil
                signatureInitialBounds = nil
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
        .fullScreenCover(isPresented: $isPresentingPencil) {
            InkCaptureView(
                recordID: recordID,
                pageIndex: currentPageIndex,
                mode: .drawing
            )
        }
        .fullScreenCover(isPresented: $isPresentingContentEditor) {
            PDFContentEditorView(
                recordID: recordID,
                pageIndex: currentPageIndex,
                onCreated: onOpenDocument
            )
        }
        .fullScreenCover(isPresented: $isPresentingLinkEditor) {
            PDFLinkEditorView(
                recordID: recordID,
                pageIndex: currentPageIndex,
                onCreated: onOpenDocument
            )
        }
        .fullScreenCover(isPresented: $isPresentingImageReplacement) {
            PDFImageReplacementView(
                recordID: recordID,
                pageIndex: currentPageIndex,
                onCreated: onOpenDocument
            )
        }
        .fullScreenCover(
            item: $textSelectionForReplacement
        ) { selection in
            PDFTextReplacementView(
                recordID: recordID,
                selection: selection,
                onCreated: onOpenDocument
            )
        }
        .alert("Rename working copy", isPresented: $isRenaming) {
            TextField("Document name", text: $proposedName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                Task {
                    await model.rename(recordID: recordID, to: proposedName)
                }
            }
            .disabled(
                proposedName
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
        } message: {
            Text("This changes only the name inside PaperPath.")
        }
        .alert("Go to page", isPresented: $isJumpingToPage) {
            TextField("Page number", text: $pageJumpInput)
                .keyboardType(.numberPad)
            Button("Cancel", role: .cancel) {
                pageJumpInput = ""
            }
            Button("Go") {
                jumpToEnteredPage()
            }
            .disabled(!pageJumpIsValid)
        } message: {
            Text(
                "Enter a page from 1 to \(model.record(id: recordID)?.profile.pageCount ?? 1)."
            )
        }
        .confirmationDialog(
            "Move this private copy to Trash?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                Task {
                    if await model.delete(recordID: recordID) {
                        dismiss()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The copy remains recoverable. The original imported file stays untouched."
            )
        }
        .sheet(isPresented: $isAddingNote) {
            NoteComposerSheet(pageIndex: currentPageIndex) { value in
                pdfCommand = PDFViewCommand(action: .addNote(value))
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Unlock protected PDF", isPresented: $isUnlocking) {
            SecureField("Password", text: $unlockInput)
                .textContentType(.password)
            Button("Cancel", role: .cancel) {
                unlockInput = ""
            }
            Button("Unlock") {
                sessionPassword = unlockInput
            }
            .disabled(unlockInput.isEmpty)
        } message: {
            Text("The password is kept only while this document is open.")
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
        }
        .sensoryFeedback(.success, trigger: model.refreshToken(for: recordID))
        .sensoryFeedback(.selection, trigger: recommendationTapCount)
    }

    private var lockedDocumentOverlay: some View {
        VStack(spacing: PPSpacing.medium) {
            PPIllustration(kind: .locked, width: 156)
            Text("Protected PDF")
                .font(.title3.bold())
                .fontDesign(.serif)
            Text("Enter the document password to read it in this session.")
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Unlock") {
                isUnlocking = true
            }
            .buttonStyle(.borderedProminent)
            Button("Share encrypted PDF") {
                share(recordID: recordID)
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PPColor.accent)
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

        return VStack(spacing: 5) {
            HStack {
                Label(
                    "\(percentage)% read",
                    systemImage: "book.pages"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .monospacedDigit()
                Spacer()
                Text(
                    minutes > 0
                        ? "~\(minutes) min left"
                        : "Final page"
                )
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
        .accessibilityLabel(
            "\(percentage) percent read. Approximately \(minutes) minutes remaining."
        )
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
            let remainingCharacters = index.pages
                .filter { $0.pageIndex > currentPageIndex }
                .reduce(0) { $0 + $1.text.count }
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

    private func recentDocumentTabs(
        current: DocumentRecord
    ) -> some View {
        let records = [current]
            + model.recentDocuments(
                excluding: current.id,
                limit: 3
            )

        return ScrollView(.horizontal) {
            HStack(spacing: PPSpacing.xSmall) {
                ForEach(records) { record in
                    let isCurrent = record.id == current.id
                    Button {
                        guard !isCurrent else { return }
                        readingPositionTask?.cancel()
                        onOpenDocument(
                            DocumentRoute(
                                recordID: record.id,
                                pageIndex: record.lastPageIndex
                            )
                        )
                    } label: {
                        HStack(spacing: PPSpacing.small) {
                            Image(
                                systemName: isCurrent
                                    ? "doc.fill"
                                    : "doc"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                isCurrent
                                    ? PPColor.accent
                                    : PPColor.textSecondary
                            )

                            VStack(
                                alignment: .leading,
                                spacing: 1
                            ) {
                                Text(record.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(
                                        PPColor.textPrimary
                                    )
                                    .lineLimit(1)
                                Text(
                                    "p\((isCurrent ? currentPageIndex : record.lastPageIndex) + 1)"
                                )
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(
                                        PPColor.textSecondary
                                    )
                            }
                        }
                        .padding(.horizontal, PPSpacing.small)
                        .frame(minWidth: 108, maxWidth: 168)
                        .frame(minHeight: 44)
                        .padding(.leading, 5)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(
                                    isCurrent
                                        ? PPColor.accent
                                        : PPColor.border.opacity(0.55)
                                )
                                .frame(width: isCurrent ? 2 : 0.6)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrent)
                    .accessibilityLabel(
                        isCurrent
                            ? "\(record.displayName), current document"
                            : "Open \(record.displayName) at page \(record.lastPageIndex + 1)"
                    )
                }
            }
            .padding(.horizontal, PPSpacing.regular)
            .padding(.top, PPSpacing.xSmall)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .background(PPColor.canvas)
        .accessibilityIdentifier("recentDocumentTabs")
    }

    private func workspaceContextStrip(
        _ record: DocumentRecord
    ) -> some View {
        let recommendation = model.recommendation(for: record)

        return Group {
            if horizontalSizeClass == .compact
                || dynamicTypeSize.isAccessibilitySize {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    HStack {
                        contextCategory(record)
                        Spacer()
                        contextStatus(record)
                    }
                    contextSummary(record)
                    if horizontalSizeClass != .compact {
                        HStack(spacing: PPSpacing.small) {
                            routeEvidencePill(record)
                            workspaceProgress(record)
                            Spacer()
                            if shouldShowWorkspaceNextAction(
                                record: record,
                                recommendation: recommendation
                            ) {
                                workspaceNextAction(
                                    record: record,
                                    recommendation: recommendation
                                )
                            }
                        }
                    } else if shouldShowWorkspaceNextAction(
                        record: record,
                        recommendation: recommendation
                    ) {
                        HStack(spacing: PPSpacing.small) {
                            Spacer()
                            workspaceNextAction(
                                record: record,
                                recommendation: recommendation
                            )
                        }
                    }
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    contextCategory(record)
                    contextSummary(record)
                    routeEvidencePill(record)
                    workspaceProgress(record)
                    contextStatus(record)
                    workspaceNextAction(
                        record: record,
                        recommendation: recommendation
                    )
                }
            }
        }
        .padding(.vertical, 4)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("documentContext")
    }

    private func routeEvidencePill(
        _ record: DocumentRecord
    ) -> some View {
        let profile = model.commandProfile(for: record)
        return Button {
            if record.profile.isLocked {
                presentedSheet = .technicalInspector
            } else {
                exportFocus = .text
                presentedSheet = .export
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: profile.readiness.symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(commandTint(profile.readiness))
                Text(profile.scoreLabel)
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(PPColor.textPrimary)
                Rectangle()
                    .fill(PPColor.border.opacity(0.62))
                    .frame(width: 0.6, height: 13)
                Text(profile.officeRoute.localizedUI)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PPColor.cyan)
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .frame(minHeight: 28)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(
                        commandTint(profile.readiness)
                            .opacity(0.58)
                    )
                    .frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Route intelligence \(profile.compactLine). \(profile.officeDetail)"
        )
        .accessibilityHint(
            record.profile.isLocked
                ? "Open technical inspector"
                : "Open Office export"
        )
        .accessibilityIdentifier("routeEvidencePill")
    }

    @ViewBuilder
    private func workspaceProgress(
        _ record: DocumentRecord
    ) -> some View {
        if record.profile.pageCount > 1 {
            Button {
                pageJumpInput = "\(currentPageIndex + 1)"
                isJumpingToPage = true
            } label: {
                Label(
                    "\(currentPageIndex + 1)/\(record.profile.pageCount)",
                    systemImage: "book.pages"
                )
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(minHeight: 28)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.72))
                        .frame(height: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Page \(currentPageIndex + 1) of \(record.profile.pageCount)"
            )
            .accessibilityHint("Jump to a page")
        }
    }

    @ViewBuilder
    private func workspaceNextAction(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) -> some View {
        let title = statusActionCompactTitle(
            record: record,
            recommendation: recommendation
        )
        let fullTitle = statusActionTitle(
            record: record,
            recommendation: recommendation
        )
        let deliveryTitle =
            model.verifiedShareTarget(for: recordID) == nil
                ? "Verify"
                : "Share"

        if title != deliveryTitle {
            Button {
                recommendationTapCount += 1
                performStatusAction(
                    record: record,
                    recommendation: recommendation
                )
            } label: {
                HStack(spacing: 6) {
                    Text("NEXT")
                        .font(.caption2.smallCaps().weight(.bold))
                        .fontDesign(.monospaced)
                        .foregroundStyle(PPColor.textSecondary)
                    Label(
                        title.localizedUI,
                        systemImage: statusActionSymbol(
                            record: record,
                            recommendation: recommendation
                        )
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.cyan)
                    .lineLimit(1)
                }
                .padding(.horizontal, PPSpacing.small)
                .frame(minHeight: 30)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(PPColor.cyan.opacity(0.72))
                        .frame(height: 1.5)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Next: \(fullTitle)")
            .accessibilityHint(
                statusActionReason(
                    record: record,
                    recommendation: recommendation
                )
            )
            .accessibilityIdentifier("workspaceNextAction")
        }
    }

    private func shouldShowWorkspaceNextAction(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) -> Bool {
        let title = statusActionCompactTitle(
            record: record,
            recommendation: recommendation
        )
        let deliveryTitle =
            model.verifiedShareTarget(for: recordID) == nil
                ? "Verify"
                : "Share"
        return title != deliveryTitle
    }

    private func statusActionTitle(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) -> String {
        if record.profile.isLocked {
            return isSessionUnlocked
                ? "Create editable copy"
                : "Unlock to continue"
        }
        return record.taskCheckpoint?.stage.title
            ?? recommendation.action.title
    }

    private func statusActionCompactTitle(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) -> String {
        if record.profile.isLocked {
            return isSessionUnlocked ? "Copy" : "Unlock"
        }
        if let checkpoint = record.taskCheckpoint {
            switch checkpoint.stage {
            case .fillForm: return "Fill"
            case .sign: return "Sign"
            case .verify: return "Verify"
            }
        }
        switch recommendation.action {
        case .brief: return "Brief"
        case .recognizeText: return "OCR"
        case .makeSearchable: return "Searchable"
        case .organizePages: return "Pages"
        case .reviewForm: return "Fill"
        case .sign: return "Sign"
        case .safeShare: return "Verify"
        case .inspect: return "Inspect"
        case .shareCopy: return "Share"
        }
    }

    private func statusActionReason(
        record: DocumentRecord,
        recommendation: DocumentActionPlanner.Recommendation
    ) -> String {
        if record.profile.isLocked {
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
            if isSessionUnlocked {
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
                initialBounds: checkpoint.normalizedBounds
            )
        case .verify:
            shareVerifiedOrCreate()
        }
    }

    private func createUnlockedPrivateCopy() {
        guard let password = sessionPassword,
              !password.isEmpty
        else {
            isSessionUnlocked = false
            isUnlocking = true
            return
        }
        Task {
            if let created = await model.createUnlockedCopy(
                recordID: recordID,
                password: password
            ) {
                onOpenDocument(DocumentRoute(recordID: created.id))
            }
        }
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
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the delivery verification details")
            .accessibilityIdentifier("deliveryReceiptBadge")
        } else if !model.verifiedOutputs(for: record.id).isEmpty {
            Button {
                presentedSheet = .deliveryHistory
            } label: {
                OutputHistoryBadge(
                    count: model.verifiedOutputs(for: record.id).count
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens verified output history")
        } else {
            OnDeviceBadge(compact: true)
        }
    }

    private func contextCategory(_ record: DocumentRecord) -> some View {
        Label(
            contextCategoryTitle(record).localizedUI,
            systemImage: contextCategorySymbol(record)
        )
        .font(.caption.smallCaps().weight(.semibold))
        .foregroundStyle(PPColor.cyan)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 6 : 3)
        .frame(minHeight: 28)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.cyan.opacity(0.5))
                .frame(height: 1)
        }
        .lineLimit(1)
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

    private func contextSummary(_ record: DocumentRecord) -> some View {
        let summary = verifiedOutcomeSummary(record)
                ?? record.brief?.summary
                ?? record.profile.summary
        return Text(summary.localizedUI)
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .lineLimit(
                dynamicTypeSize.isAccessibilitySize ? 3 : 1
            )
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func verifiedOutcomeSummary(
        _ record: DocumentRecord
    ) -> String? {
        guard let receipt = record.deliveryReceipt else { return nil }
        guard record.hasCurrentDeliveryReceipt else {
            return "This output changed after it was checked. Verify it again before sharing."
        }
        return receipt.outcomeDetail
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
        let layout = dynamicTypeSize.isAccessibilitySize
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
                        .lineLimit(1)

                        Text(
                            isCurrent
                                ? "\(receipt?.operation.title ?? "Output") receipt"
                                : "This PDF changed after its receipt was issued"
                        )
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
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
                .lineLimit(1)
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
        VStack(spacing: 0) {
            if shouldShowWorkspaceCommandRail(record) {
                workspaceCommandRail(record)

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

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    ScrollView(.horizontal) {
                        HStack(spacing: 0) {
                            actionBarCommands(record)
                        }
                        .frame(minWidth: 430)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    HStack(spacing: 0) {
                        actionBarCommands(record)
                    }
                }
            }
            .padding(.horizontal, PPSpacing.small)
            .padding(.top, 3)
            .padding(.bottom, 5)
        }
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.72))
                .frame(height: 0.7)
        }
    }

    @ViewBuilder
    private func actionBarCommands(
        _ record: DocumentRecord
    ) -> some View {
        if isRedactionMode {
            WorkspaceBarButton(
                title: "Redact",
                symbol: "eye.slash",
                tint: PPColor.amber,
                isProminent: true
            ) {
                runCommand(.markRedaction)
            }
            .accessibilityHint(
                "Marks the currently selected text for permanent redaction"
            )
        } else {
            WorkspaceBarButton(
                title: "Find",
                symbol: "text.magnifyingglass",
                tint: PPColor.cyan,
                isProminent: true
            ) {
                presentedSheet = .find
            }
            .keyboardShortcut("f", modifiers: .command)
            .accessibilityIdentifier(
                "workspaceFindAction"
            )
        }

        markUpMenu

        WorkspaceBarButton(
            title: "Pages",
            symbol: "square.grid.2x2"
        ) {
            pageOrganizerStartsSelecting = false
            presentedSheet = .pages
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])

        WorkspaceBarButton(
            title: model.verifiedShareTarget(for: recordID) == nil
                ? "Verify"
                : "Share",
            symbol: model.verifiedShareTarget(for: recordID) == nil
                ? "checkmark.shield"
                : "square.and.arrow.up",
            tint: PPColor.mint,
            isProminent: true
        ) {
            shareVerifiedOrCreate()
        }
        .accessibilityLabel(
            (
                model.verifiedShareTarget(for: recordID) == nil
                    ? "Create verified sharing copy"
                    : "Share verified copy"
            ).localizedUI
        )
        .accessibilityHint(
            "PaperPath shares a checked output instead of the working copy"
                .localizedUI
        )
        .accessibilityIdentifier("verifiedShareAction")

        recentToolButton(record: record)
    }

    private func workspaceCommandRail(
        _ record: DocumentRecord
    ) -> some View {
        let signals = workspaceCommandSignals(record)

        return ScrollView(.horizontal) {
            HStack(spacing: PPSpacing.small) {
                ForEach(signals) { signal in
                    workspaceSignalChip(signal, record: record)
                        .frame(minWidth: 112, maxWidth: 172)
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

    private func shouldShowWorkspaceCommandRail(
        _ record: DocumentRecord
    ) -> Bool {
        horizontalSizeClass == .regular
            && !workspaceCommandSignals(record).isEmpty
    }

    private func workspaceCommandSignals(
        _ record: DocumentRecord
    ) -> [DocumentCommandSignal] {
        model.commandProfile(for: record).signals.filter {
            $0.readiness != .ready
        }
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
                Text(signal.value.localizedUI)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Text(signal.title.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 34)
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
            exportFocus = .text
            presentedSheet = .export
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

        WorkspaceBarButton(
            title: "Tools",
            symbol: "slider.horizontal.3",
            tint: PPColor.cyan
        ) {
            presentedSheet = .tools
        }
        .keyboardShortcut("t", modifiers: .command)
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
                        message: "Previous page"
                    )
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 40, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(currentPageIndex <= 0)
                .keyboardShortcut("[", modifiers: .command)
                .accessibilityLabel("Previous page")

                VStack(spacing: pageCount > 5 ? 0 : 2) {
                    Button {
                        pageJumpInput = "\(displayedPage + 1)"
                        isJumpingToPage = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text")
                            Text(
                                "Page \(displayedPage + 1) of \(pageCount)"
                            )
                            .monospacedDigit()
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .frame(minHeight: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("j", modifiers: .command)
                    .accessibilityLabel(
                        "Page \(displayedPage + 1) of \(pageCount). Go to page"
                    )

                    if pageCount > 5 {
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
                                    message: "Page \(page + 1)"
                                )
                            }
                        }
                        .tint(PPColor.accent)
                        .frame(minWidth: 112)
                        .accessibilityLabel("Page position")
                        .accessibilityValue(
                            "\(displayedPage + 1) of \(pageCount)"
                        )
                        .sensoryFeedback(
                            .selection,
                            trigger: displayedPage
                        )
                    }
                }
                .frame(maxWidth: .infinity)

                Button {
                    showPage(
                        currentPageIndex + 1,
                        message: "Next page"
                    )
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 40, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(
                    currentPageIndex >= record.profile.pageCount - 1
                )
                .keyboardShortcut("]", modifiers: .command)
                .accessibilityLabel("Next page")

                Button {
                    Task {
                        await model.toggleBookmark(
                            recordID: recordID,
                            pageIndex: currentPageIndex
                        )
                    }
                } label: {
                    Image(
                        systemName: record.bookmarkedPages
                            .contains(currentPageIndex)
                            ? "bookmark.fill"
                            : "bookmark"
                    )
                    .frame(width: 40, height: 34)
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
                .keyboardShortcut("b", modifiers: .command)
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
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
            }
            .buttonStyle(.plain)
            .disabled(pageBackHistory.isEmpty)

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
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 30)
            }
            .buttonStyle(.plain)
            .disabled(pageForwardHistory.isEmpty)
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
            Divider()
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
            Divider()
            Button {
                isPresentingPencil = true
            } label: {
                Label("Draw on Page", systemImage: "pencil.tip.crop.circle")
            }
            Button {
                isAddingNote = true
            } label: {
                Label("Add Note", systemImage: "note.text.badge.plus")
            }
            Button {
                presentedSheet = .stamp
            } label: {
                Label("Add Stamp", systemImage: "seal")
            }
            Button {
                isPresentingContentEditor = true
            } label: {
                Label(
                    "Add Text, Photo, or Link",
                    systemImage: "text.badge.plus"
                )
            }
            Button {
                isPresentingLinkEditor = true
            } label: {
                Label(
                    "Edit Existing Links",
                    systemImage: "link"
                )
            }
            Button {
                isPresentingImageReplacement = true
            } label: {
                Label(
                    "Replace Existing Image",
                    systemImage: "photo.badge.arrow.down"
                )
            }
            Button {
                runCommand(.captureTextForEditing)
            } label: {
                Label(
                    "Edit Selected Text",
                    systemImage: "character.cursor.ibeam"
                )
            }
            Button {
                presentSignature()
            } label: {
                Label("Add Signature", systemImage: "signature")
            }
            Button {
                runCommand(.markRedaction)
            } label: {
                Label("Mark Redaction", systemImage: "eye.slash")
            }
            Button {
                presentedSheet = .annotations
            } label: {
                Label("Review Annotations", systemImage: "text.bubble")
            }
            Button {
                presentedSheet = .attachments
            } label: {
                Label("Embedded Files", systemImage: "paperclip")
            }
            Button {
                runCommand(.removeAnnotation)
            } label: {
                Label("Undo Last on Page", systemImage: "arrow.uturn.backward")
            }
        } label: {
            WorkspaceBarLabel(
                title: "Edit",
                symbol: "pencil.tip",
                tint: PPColor.amber
            )
        }
        .frame(maxWidth: .infinity)
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
        pageJumpInput = ""
        showPage(page - 1, message: "Jumped to page")
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
            let tool: DocumentTool?
            switch action {
            case .brief:
                tool = .brief
            case .recognizeText:
                tool = .recognize
            case .makeSearchable:
                tool = nil
            case .organizePages:
                tool = .organize
            case .reviewForm:
                tool = .fillForm
            case .sign:
                tool = .sign
            case .safeShare, .shareCopy:
                tool = .export
            case .inspect:
                tool = record.brief == nil ? .find : .brief
            }
            if let tool,
               !result.contains(tool) {
                result.append(tool)
            }
        }
        return Array(result.prefix(4))
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
            presentedSheet = .pages
        case .compress:
            presentedSheet = .compression
        case .protect:
            presentedSheet = .protection
        case .export:
            exportFocus = nil
            presentedSheet = .export
        }
    }

    private func runCommand(_ action: PDFViewCommand.Action) {
        presentedSheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            if let label = directMutationVersionLabel(for: action) {
                guard await model.createVersionSnapshot(
                    recordID: recordID,
                    label: label
                ) else { return }
            }
            pdfCommand = PDFViewCommand(action: action)
        }
    }

    private func runMarkup(_ kind: PDFMarkupKind) {
        presentedSheet = nil
        let color = markupColor(for: kind)
        Task {
            try? await Task.sleep(for: .milliseconds(220))
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
        case .markRedaction, .captureTextForEditing:
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
        model.noticeMessage = AppLocalization.format(
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
        _ pageIndex: Int
    ) {
        readingPositionTask?.cancel()
        readingPositionTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            await model.updateReadingPosition(
                recordID: recordID,
                pageIndex: pageIndex
            )
        }
    }

    private var processingPill: some View {
        let progress = model.progress(for: recordID)
        return HStack(spacing: PPSpacing.small) {
            ToolSymbolPlate(
                symbol: recognitionTask == nil ? "gearshape.2" : "text.viewfinder",
                tint: recognitionTask == nil ? PPColor.accent : PPColor.cyan,
                size: 30
            )
            if let progress {
                LocalOperationProgressView(progress: progress)
                    .frame(minWidth: 190, maxWidth: 280)
            } else {
                Text(
                    "Working on device".localizedUI
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(2)
            }
            if recognitionTask != nil {
                Button {
                    recognitionTask?.cancel()
                    recognitionTask = nil
                    model.noticeMessage = "Text recognition stopped"
                } label: {
                    Image(systemName: "stop.fill")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.amber)
                .accessibilityLabel("Stop text recognition")
            }
        }
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
    }

    private func handle(_ action: DocumentAction) {
        switch action {
        case .brief:
            presentedSheet = .brief
        case .recognizeText:
            if model.ocrResults[recordID] != nil {
                presentedSheet = .recognizedText
            } else {
                openRecognitionSettings()
            }
        case .makeSearchable:
            Task {
                if let created = await model.createSearchableCopy(
                    recordID: recordID
                ) {
                    onOpenDocument(DocumentRoute(recordID: created.id))
                }
            }
        case .organizePages:
            pageOrganizerStartsSelecting = false
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
        case .scanToPDF, .imagesToPDF, .mergePDFs:
            break
        case .splitPDF:
            pageOrganizerStartsSelecting = true
            presentedSheet = .pages
        case .organizePages:
            pageOrganizerStartsSelecting = false
            presentedSheet = .pages
        case .compressPDF:
            presentedSheet = .compression
        case .fillForms:
            presentedSheet = .formReview
        case .signPDF:
            presentSignature()
        case .redactPDF:
            isRedactionMode = true
            model.noticeMessage = "Select text, then tap Redact"
        case .protectPDF:
            presentedSheet = .protection
        case .safeShare:
            shareVerifiedOrCreate()
        case .recognizeText:
            handle(.recognizeText)
        case .exportText:
            exportFocus = .text
            presentedSheet = .export
        case .exportImages:
            exportFocus = .images
            presentedSheet = .export
        }
    }

    private func shareVerifiedOrCreate() {
        if let target = model.verifiedShareTarget(for: recordID) {
            share(recordID: target.id)
        } else {
            Task {
                await model.updateTaskCheckpoint(
                    recordID: recordID,
                    checkpoint: DocumentTaskCheckpoint(stage: .verify)
                )
            }
            exportFocus = .safeShare
            presentedSheet = .export
        }
    }

    private func openRecognitionSettings(
        afterDismissal: Bool = false
    ) {
        recognitionConfiguration =
            model.ocrResults[recordID]?.configuration
                ?? recognitionConfiguration
        if afterDismissal {
            Task {
                try? await Task.sleep(for: .milliseconds(240))
                isConfiguringRecognition = true
            }
        } else {
            isConfiguringRecognition = true
        }
    }

    private func startRecognition(
        _ configuration: OCRRecognitionConfiguration
    ) {
        guard recognitionTask == nil else { return }
        recognitionConfiguration = configuration
        recognitionTask = Task {
            let succeeded = await model.recognizeText(
                recordID: recordID,
                configuration: configuration
            )
            guard !Task.isCancelled else {
                recognitionTask = nil
                return
            }
            if succeeded {
                presentedSheet = .recognizedText
            }
            recognitionTask = nil
        }
    }

    private func openSafeShareAfterDismissal() {
        Task {
            await model.updateTaskCheckpoint(
                recordID: recordID,
                checkpoint: DocumentTaskCheckpoint(stage: .verify)
            )
            try? await Task.sleep(for: .milliseconds(260))
            exportFocus = .safeShare
            presentedSheet = .export
        }
    }

    private func share(recordID targetID: UUID) {
        guard let url = model.url(for: targetID) else {
            model.noticeMessage = "The PDF could not be found"
            return
        }
        shareItems = [url]
        presentedSheet = .share
        if targetID != recordID {
            model.noticeMessage = "Sharing the latest verified copy"
        }
    }

    private func printDocument(
        record: DocumentRecord,
        url: URL
    ) {
        guard UIPrintInteractionController.isPrintingAvailable,
              UIPrintInteractionController.canPrint(url)
        else {
            model.noticeMessage = "Printing is unavailable for this PDF"
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
                    model.present(error)
                } else if completed {
                    model.noticeMessage = "Print job handed to iOS"
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
            presentedSheet = nil
            openRecognitionSettings(afterDismissal: true)
        case .organize:
            presentedSheet = nil
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                presentedSheet = .pages
            }
        case .share:
            presentedSheet = nil
            Task {
                try? await Task.sleep(for: .milliseconds(220))
                exportFocus = .safeShare
                presentedSheet = .export
            }
        case .completeForm:
            presentedSheet = .formReview
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
        dismissesPresentedSheet: Bool = true
    ) {
        guard let pageIndex else {
            if let sheet {
                presentedSheet = sheet
                model.noticeMessage = "Evidence page unavailable · continuing"
            } else {
                model.noticeMessage = "The evidence page could not be located"
            }
            return
        }
        if recordsHistory,
           pageIndex != currentPageIndex {
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
        if !dismissesPresentedSheet {
            requestedPageIndex = pageIndex
            pageNavigationToken += 1
            model.noticeMessage = "\(message) · page \(pageIndex + 1)"
            return
        }
        presentedSheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            requestedPageIndex = pageIndex
            pageNavigationToken += 1
            model.noticeMessage = "\(message) · page \(pageIndex + 1)"
            if let sheet {
                try? await Task.sleep(for: .milliseconds(260))
                presentedSheet = sheet
            }
        }
    }

    private func navigateBack() {
        guard let page = pageBackHistory.popLast() else { return }
        if pageForwardHistory.last != currentPageIndex {
            pageForwardHistory.append(currentPageIndex)
        }
        showPage(
            page,
            message: "Back",
            recordsHistory: false
        )
    }

    private func navigateForward() {
        guard let page = pageForwardHistory.popLast() else { return }
        if pageBackHistory.last != currentPageIndex {
            pageBackHistory.append(currentPageIndex)
        }
        showPage(
            page,
            message: "Forward",
            recordsHistory: false
        )
    }

    private func openChangedPage(
        targetRecordID: UUID,
        pageIndex: Int
    ) {
        guard model.record(id: targetRecordID) != nil else {
            model.noticeMessage = "The changed page is no longer available"
            return
        }
        guard targetRecordID != recordID else {
            presentedSheet = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(180))
                showPage(
                    pageIndex,
                    message: "Opened changed page"
                )
            }
            return
        }
        let targetName = model.record(id: targetRecordID)?
            .displayName ?? "PDF"
        presentedSheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            model.noticeMessage = AppLocalization.format(
                "Opened change in %@ · page %lld",
                targetName,
                pageIndex + 1
            )
            onOpenDocument(
                DocumentRoute(
                    recordID: targetRecordID,
                    pageIndex: pageIndex
                )
            )
        }
    }

    private func showPageThenSignature(
        _ pageIndex: Int?,
        initialBounds: PDFNormalizedRect? = nil
    ) {
        guard let pageIndex else {
            presentSignature(initialBounds: initialBounds)
            model.noticeMessage = "Evidence page unavailable · continuing"
            return
        }
        presentedSheet = nil
        Task {
            try? await Task.sleep(for: .milliseconds(220))
            requestedPageIndex = pageIndex
            pageNavigationToken += 1
            model.noticeMessage = "Signature evidence · page \(pageIndex + 1)"
            try? await Task.sleep(for: .milliseconds(260))
            presentSignature(
                pageIndex: pageIndex,
                initialBounds: initialBounds
            )
        }
    }

    private func presentSignature(
        pageIndex: Int? = nil,
        initialBounds: PDFNormalizedRect? = nil
    ) {
        let targetPageIndex = pageIndex ?? currentPageIndex
        Task {
            await model.updateTaskCheckpoint(
                recordID: recordID,
                checkpoint: DocumentTaskCheckpoint(
                    stage: .sign,
                    pageIndex: targetPageIndex,
                    normalizedBounds: initialBounds
                )
            )
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
