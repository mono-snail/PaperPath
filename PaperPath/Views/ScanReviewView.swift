import SwiftUI

enum ScanReviewPurpose: Hashable, Sendable {
    case createPDF
    case replacePage

    var eyebrow: String {
        switch self {
        case .createPDF: return "SCAN WORKFLOW"
        case .replacePage: return "REPLACEMENT SOURCE"
        }
    }

    var title: String {
        switch self {
        case .createPDF: return "Review Scan"
        case .replacePage: return "Replacement Scan"
        }
    }

    var detail: String {
        switch self {
        case .createPDF:
            return "Correct quality and order before creating the private PDF."
        case .replacePage:
            return "Correct rotation, crop, and contrast before choosing the replacement page."
        }
    }

    var actionTitle: String {
        switch self {
        case .createPDF: return "Create PDF"
        case .replacePage: return "Choose Replacement Page"
        }
    }
}

struct ScanReviewView: View {
    private enum PreviewMode: String, CaseIterable, Identifiable {
        case processed
        case original

        var id: String { rawValue }

        var title: String {
            switch self {
            case .processed: return "Processed"
            case .original: return "Original"
            }
        }

        var symbol: String {
            switch self {
            case .processed: return "wand.and.stars"
            case .original: return "photo"
            }
        }
    }

    private struct EditSnapshot {
        let images: [UIImage]
        let options: [ScanProcessingOptions]
        let automaticCropResolutions: [ScanAutomaticCropResolution?]
        let pageIndex: Int
        let isSelectingPages: Bool
        let selectedPageIndices: Set<Int>
        let adjustmentSourcePageIndex: Int?
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let purpose: ScanReviewPurpose
    let onSuspend: (([ScanPageImage], Int) -> Void)?
    let onSave: ([ScanPageImage]) -> Void

    @State private var workingImages: [UIImage]
    @State private var pageOptions: [ScanProcessingOptions]
    @State private var automaticCropResolutions:
        [ScanAutomaticCropResolution?]
    @State private var preview: UIImage?
    @State private var detectedDocument = false
    @State private var detectedCropQuad: ScanCropQuad?
    @State private var pageIndex = 0
    @State private var pageScrollPosition: Int?
    @State private var pageRevision = 0
    @State private var previewMode = PreviewMode.processed
    @State private var isPreparingPreview = false
    @State private var previewFailed = false
    @State private var previewGeneration = UUID()
    @State private var validatedProcessedPreviewKey: String?
    @State private var previewErrorFeedback = 0
    @State private var applyAllFeedback = 0
    @State private var toneResetFeedback = 0
    @State private var editFeedback = 0
    @State private var selectionModeFeedback = 0
    @State private var isSelectingPages = false
    @State private var selectedPageIndices: Set<Int> = []
    @State private var adjustmentSourcePageIndex: Int?
    @State private var isConfirmingSelectedPageRemoval = false
    @State private var isConfirmingDiscard = false
    @State private var isEditingManualCrop = false
    @State private var manualCropDraft = ScanCropQuad.fullFrame
    @State private var cropPreviousPreviewMode = PreviewMode.processed
    @State private var cropAppliedFeedback = 0
    @State private var undoSnapshot: EditSnapshot?
    @State private var undoFeedback = 0
    @State private var completionFeedback = 0
    @State private var isCompletingReview = false
    @State private var didSuspendForProtection = false
    @State private var showsFineAdjustments = false

    init(
        images: [UIImage],
        initialOptions: ScanProcessingOptions = .document,
        purpose: ScanReviewPurpose = .createPDF,
        initialPageIndex: Int = 0,
        onSuspend: (([ScanPageImage], Int) -> Void)? = nil,
        onSave: @escaping ([ScanPageImage]) -> Void
    ) {
        self.init(
            pages: images.map {
                ScanPageImage(
                    image: $0,
                    processingOptions: initialOptions
                )
            },
            fallbackOptions: initialOptions,
            purpose: purpose,
            initialPageIndex: initialPageIndex,
            onSuspend: onSuspend,
            onSave: onSave
        )
    }

    init(
        pages: [ScanPageImage],
        fallbackOptions: ScanProcessingOptions = .document,
        purpose: ScanReviewPurpose = .createPDF,
        initialPageIndex: Int = 0,
        onSuspend: (([ScanPageImage], Int) -> Void)? = nil,
        onSave: @escaping ([ScanPageImage]) -> Void
    ) {
        self.purpose = purpose
        self.onSuspend = onSuspend
        self.onSave = onSave
        _workingImages = State(initialValue: pages.map(\.image))
        _pageOptions = State(
            initialValue: pages.map {
                $0.processingOptions ?? fallbackOptions
            }
        )
        _automaticCropResolutions = State(
            initialValue: pages.map(\.automaticCropResolution)
        )
        _pageIndex = State(
            initialValue: pages.isEmpty
                ? 0
                : min(max(0, initialPageIndex), pages.count - 1)
        )
    }

    var body: some View {
        if #available(iOS 18.0, *) {
            reviewNavigation
                .presentationSizing(.page)
        } else {
            reviewNavigation
        }
    }

    private var reviewNavigation: some View {
        NavigationStack {
            VStack(spacing: 0) {
                scanWorkspace
            }
            .allowsHitTesting(!isCompletingReview)
            .background(PPColor.canvas)
            .navigationTitle(purpose.title.localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            isEditingManualCrop
                                ? "Cancel Crop"
                                : "Cancel"
                        ).localizedUI
                    ) {
                        if isEditingManualCrop {
                            cancelManualCrop()
                        } else if workingImages.isEmpty {
                            dismiss()
                        } else {
                            isConfirmingDiscard = true
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCompletingReview)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        undoLastEdit()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(
                        undoSnapshot == nil
                            || isEditingManualCrop
                            || isCompletingReview
                    )
                    .keyboardShortcut("z", modifiers: .command)
                    .accessibilityLabel(
                        "Undo last scan edit".localizedUI
                    )
                    .help("Undo last scan edit".localizedUI)
                    .accessibilityIdentifier("scanUndo")
                }
                ToolbarItem(placement: .primaryAction) {
                    scanCommands
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !workingImages.isEmpty,
                   !isEditingManualCrop {
                    scanCompletionBar
                }
            }
            .task(id: previewTaskID) {
                await updatePreview()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    pageRevision &+= 1
                } else if phase == .background {
                    suspendReviewForBackground()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                suspendReviewForProtection()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.didReceiveMemoryWarningNotification
                )
            ) { _ in
                previewGeneration = UUID()
                validatedProcessedPreviewKey = nil
                isPreparingPreview = false
                preview = nil
                previewFailed = false
                detectedDocument = false
                detectedCropQuad = nil
                undoSnapshot = nil
                ScanPDFRenderer().releaseCachedResources()
                pageRevision &+= 1
            }
            .onDisappear {
                previewGeneration = UUID()
                validatedProcessedPreviewKey = nil
                isPreparingPreview = false
                preview = nil
                previewFailed = false
                detectedDocument = false
                detectedCropQuad = nil
            }
            .sensoryFeedback(
                .selection,
                trigger: processingSelectionFeedback
            )
            .sensoryFeedback(.selection, trigger: pageIndex)
            .sensoryFeedback(
                .selection,
                trigger: selectedPageIndices.count
            )
            .sensoryFeedback(
                .selection,
                trigger: selectionModeFeedback
            )
            .sensoryFeedback(.success, trigger: applyAllFeedback)
            .sensoryFeedback(.impact(weight: .light), trigger: toneResetFeedback)
            .sensoryFeedback(.impact(weight: .light), trigger: editFeedback)
            .sensoryFeedback(.success, trigger: cropAppliedFeedback)
            .sensoryFeedback(.success, trigger: undoFeedback)
            .sensoryFeedback(.success, trigger: completionFeedback)
            .sensoryFeedback(.error, trigger: previewErrorFeedback)
            .confirmationDialog(
                "Remove selected pages?",
                isPresented: $isConfirmingSelectedPageRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Selected Pages", role: .destructive) {
                    removeSelectedPages()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "The pages are removed only from this unsaved scan review."
                )
            }
            .confirmationDialog(
                "Discard reviewed pages?",
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard Pages", role: .destructive) {
                    dismiss()
                }
                Button("Keep Reviewing", role: .cancel) {}
            } message: {
                Text(
                    "Rotation, crop, contrast, and page-order changes have not been saved."
                )
            }
            .accessibilityAction(.escape) {
                guard !isCompletingReview else { return }
                if isEditingManualCrop {
                    cancelManualCrop()
                } else if workingImages.isEmpty {
                    dismiss()
                } else {
                    isConfirmingDiscard = true
                }
            }
            .interactiveDismissDisabled(
                !workingImages.isEmpty || isCompletingReview
            )
        }
    }

    @ViewBuilder
    private var scanWorkspace: some View {
        GeometryReader { geometry in
            if workingImages.isEmpty {
                emptyScanState
            } else if geometry.size.width >= 760,
                      geometry.size.height >= 350,
                      !dynamicTypeSize.ppPrefersExpandedLayout {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        previewStage
                            .frame(minHeight: 210)
                        if !isEditingManualCrop {
                            pageQueue
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    ScrollView {
                        if isEditingManualCrop {
                            cropEditingBar
                        } else {
                            controlPanel
                        }
                    }
                    .frame(width: 320)
                    .background(PPColor.surface)
                }
                .accessibilityIdentifier("scanParallelWorkspace")
            } else if dynamicTypeSize.ppPrefersExpandedLayout
                        || geometry.size.height < 500 {
                ScrollView {
                    VStack(spacing: 0) {
                        previewStage
                            .frame(height: 300)
                        if isEditingManualCrop {
                            cropEditingBar
                        } else {
                            pageQueue
                            controlPanel
                        }
                    }
                }
            } else {
                VStack(spacing: 0) {
                    previewStage
                        .frame(minHeight: 210)
                    if isEditingManualCrop {
                        cropEditingBar
                    } else {
                        pageQueue
                        controls
                    }
                }
            }
        }
    }

    private var scanCommands: some View {
        Menu {
            Button {
                focusPage(pageIndex - 1)
            } label: {
                Label("Previous scanned page".localizedUI, systemImage: "chevron.left")
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(pageIndex == 0 || isSelectingPages)
            Button {
                focusPage(pageIndex + 1)
            } label: {
                Label("Next scanned page".localizedUI, systemImage: "chevron.right")
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(pageIndex >= workingImages.count - 1 || isSelectingPages)
            Divider()
            Button {
                if isSelectingPages {
                    rotateSelectedPages()
                } else {
                    rotateCurrentPage()
                }
            } label: {
                Label(
                    (isSelectingPages ? "Rotate Selected" : "Rotate Clockwise").localizedUI,
                    systemImage: "rotate.right"
                )
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(isSelectingPages && selectedPageIndices.isEmpty)
            Button {
                beginManualCrop()
            } label: {
                Label("Adjust crop".localizedUI, systemImage: "crop")
            }
            .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button {
                previewMode = .original
            } label: {
                Label("Original".localizedUI, systemImage: "photo")
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(previewMode == .original)
            Button {
                previewMode = .processed
            } label: {
                Label("Processed".localizedUI, systemImage: "wand.and.stars")
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(previewMode == .processed)
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(
            workingImages.isEmpty
                || isCompletingReview
                || isEditingManualCrop
                || isConfirmingDiscard
                || isConfirmingSelectedPageRemoval
                || scenePhase != .active
        )
        .accessibilityLabel("Scan actions".localizedUI)
        .help("Scan actions".localizedUI)
        .accessibilityIdentifier("scanCommands")
    }

    private var emptyScanState: some View {
        PPEmptyState(
            kind: .workspace,
            title: "No pages to review",
            message: "Cancel and choose an image again."
        )
        .padding(PPSpacing.regular)
        .frame(maxHeight: .infinity)
    }

    private var scanCompletionBar: some View {
        VStack(spacing: PPSpacing.small) {
            if purpose == .createPDF {
                Label(
                    "Image-based PDF · recognize text after saving".localizedUI,
                    systemImage: "doc.viewfinder"
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            let statusLayout = dynamicTypeSize.ppPrefersExpandedLayout
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
                : AnyLayout(HStackLayout(spacing: PPSpacing.small))
            statusLayout {
                Label(
                    completionStatusTitle,
                    systemImage: completionStatusSymbol
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(completionStatusTint)
                .fixedSize(horizontal: false, vertical: true)
                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer(minLength: PPSpacing.small)
                }
                Text(
                    completionPageStatus
                )
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                finishReview()
            } label: {
                Label(
                    purpose.actionTitle.localizedUI,
                    systemImage: purpose == .createPDF
                        ? "doc.badge.plus"
                        : "arrow.right"
                )
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(!canFinishReview)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(completionAccessibilityHint)
            .accessibilityIdentifier("scanSave")
        }
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var canFinishReview: Bool {
        let baseReady = !isCompletingReview
            && !workingImages.isEmpty
            && workingImages.count == pageOptions.count
            && workingImages.count
                == automaticCropResolutions.count
            && !isEditingManualCrop
            && !isPreparingPreview
            && scenePhase == .active
            && UIApplication.shared.isProtectedDataAvailable
            && (
                previewMode != .processed
                    || preview != nil && !previewFailed
            )
        guard baseReady else { return false }
        guard purpose == .replacePage else { return true }
        return validatedProcessedPreviewKey
            == processedPreviewValidationKey
    }

    private var completionStatusTitle: String {
        if isCompletingReview {
            return "Handing off reviewed pages".localizedUI
        }
        if isPreparingPreview {
            return "Updating preview".localizedUI
        }
        if previewFailed {
            return "Preview unavailable".localizedUI
        }
        if previewMode == .original {
            return "Original preview shown".localizedUI
        }
        if purpose == .replacePage {
            return validatedProcessedPreviewKey
                == processedPreviewValidationKey
                ? "Replacement page ready".localizedUI
                : "Check processed preview".localizedUI
        }
        return AppLocalization.format(
            "%lld page%@ ready",
            workingImages.count,
            workingImages.count == 1 ? "" : "s"
        )
    }

    private var completionPageStatus: String {
        if purpose == .replacePage {
            return AppLocalization.format(
                "Page %lld of %lld selected",
                pageIndex + 1,
                workingImages.count
            )
        }
        return AppLocalization.format(
            "%lld page%@",
            workingImages.count,
            workingImages.count == 1 ? "" : "s"
        )
    }

    private var completionStatusSymbol: String {
        if isCompletingReview {
            return "arrow.right.circle"
        }
        if isPreparingPreview {
            return "arrow.triangle.2.circlepath"
        }
        if previewFailed {
            return "exclamationmark.triangle"
        }
        return canFinishReview
            ? "checkmark.circle.fill"
            : "eye"
    }

    private var completionStatusTint: Color {
        if isCompletingReview {
            return PPColor.cyan
        }
        if previewFailed {
            return PPColor.amber
        }
        return canFinishReview
            ? PPColor.mint
            : PPColor.cyan
    }

    private var completionAccessibilityHint: String {
        if isCompletingReview {
            return "Wait for the reviewed pages to finish handing off."
                .localizedUI
        }
        if workingImages.isEmpty {
            return "Keep at least one scanned page to continue."
                .localizedUI
        }
        if isEditingManualCrop {
            return "Apply or cancel the crop adjustment first."
                .localizedUI
        }
        if isPreparingPreview {
            return "Wait for the processed preview to finish."
                .localizedUI
        }
        if previewFailed {
            return "Retry the processed preview before continuing."
                .localizedUI
        }
        if previewMode == .original {
            return purpose == .replacePage
                ? "Switch to Processed and review the final replacement."
                    .localizedUI
                : "Processing settings still apply to the created PDF."
                    .localizedUI
        }
        if canFinishReview {
            return purpose == .replacePage
                ? "Uses this reviewed page as the replacement source."
                    .localizedUI
                : "Creates a private PDF from the reviewed pages."
                    .localizedUI
        }
        if purpose == .replacePage,
           validatedProcessedPreviewKey
            != processedPreviewValidationKey {
            return "Open the processed preview and wait for it to finish."
                .localizedUI
        }
        return "Wait for the preview to finish.".localizedUI
    }

    private var previewTaskID: String {
        [
            currentOptions.enhancement.rawValue,
            currentOptions.autoCrop ? "crop" : "full",
            currentOptions.removeShadows ? "light" : "natural",
            currentOptions.cleanEdges ? "clean" : "edges",
            String(currentOptions.brightness.bitPattern),
            String(currentOptions.contrast.bitPattern),
            currentOptions.manualCrop?.cacheKey ?? "automatic",
            isEditingManualCrop ? "editing-crop" : "reviewing",
            previewMode.rawValue,
            scenePhase == .active ? "active" : "paused",
            String(pageIndex),
            String(pageRevision)
        ].joined(separator: "-")
    }

    private var processedPreviewValidationKey: String {
        let automaticResolution =
            automaticCropResolutions.indices.contains(pageIndex)
                ? automaticCropResolutions[pageIndex]
                : nil
        return [
            String(pageIndex),
            String(pageRevision),
            String(currentOptions.hashValue),
            String(automaticResolution.hashValue)
        ].joined(separator: ":")
    }

    private var previewStage: some View {
        GeometryReader { proxy in
            ZStack {
                PPColor.surfaceMuted

                if let displayedPreview {
                    Image(uiImage: displayedPreview)
                        .resizable()
                        .scaledToFit()
                        .padding(PPSpacing.medium)
                        .shadow(
                            color: .black.opacity(0.12),
                            radius: 6,
                            y: 3
                        )
                        .opacity(isPreparingPreview ? 0.5 : 1)
                        .transition(.opacity)
                        .accessibilityLabel(
                            AppLocalization.format(
                                "%@ preview, page %lld of %lld",
                                previewMode.title.localizedUI,
                                pageIndex + 1,
                                workingImages.count
                            )
                        )
                } else if !isPreparingPreview {
                    VStack(spacing: PPSpacing.small) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(PPColor.amber)
                        Text("Preview unavailable".localizedUI)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Button("Retry Preview".localizedUI) {
                            previewFailed = false
                            pageRevision &+= 1
                        }
                        .buttonStyle(
                            PPQuietButtonStyle(tint: PPColor.cyan)
                        )
                    }
                    .accessibilityElement(children: .combine)
                }

                if isEditingManualCrop,
                   workingImages.indices.contains(pageIndex) {
                    ScanManualCropOverlay(
                        quad: $manualCropDraft,
                        imageSize: displayedImageSize(
                            workingImages[pageIndex]
                        ),
                        contentInset: PPSpacing.medium
                    )
                }

                if isPreparingPreview && !isEditingManualCrop {
                    VStack(spacing: 6) {
                        ProgressView()
                        Text("Updating preview".localizedUI)
                            .font(.caption.weight(.semibold))
                    }
                    .padding(PPSpacing.small)
                    .background(.regularMaterial)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: PPRadius.control,
                            style: .continuous
                        )
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .overlay(alignment: .topLeading) {
                if isEditingManualCrop {
                    Label(
                        "Adjust corners",
                        systemImage: "crop"
                    )
                    .font(.caption.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.cyan)
                    .padding(PPSpacing.regular)
                    .allowsHitTesting(false)
                } else if currentOptions.manualCrop != nil {
                    Label(
                        "Manual crop",
                        systemImage: "crop"
                    )
                    .font(.caption.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.mint)
                    .padding(PPSpacing.regular)
                    .allowsHitTesting(false)
                } else if previewMode == .original {
                    Label(
                        "Original capture",
                        systemImage: "photo"
                    )
                    .font(.caption.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                    .padding(PPSpacing.regular)
                    .allowsHitTesting(false)
                } else if currentOptions.autoCrop {
                    Label(
                        detectedDocument
                            ? "Edges detected"
                            : "Full frame",
                        systemImage: detectedDocument
                            ? "viewfinder"
                            : "rectangle.dashed"
                    )
                    .font(.caption.smallCaps().weight(.bold))
                    .foregroundStyle(
                        detectedDocument
                            ? PPColor.mint
                            : PPColor.textSecondary
                    )
                    .padding(PPSpacing.regular)
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topTrailing) {
                if !isEditingManualCrop {
                    Button {
                        beginManualCrop()
                    } label: {
                        Image(systemName: "crop")
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.regularMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        currentOptions.manualCrop != nil
                            ? PPColor.mint
                            : PPColor.cyan
                    )
                    .padding(PPSpacing.regular)
                    .accessibilityLabel("Adjust crop".localizedUI)
                    .help("Adjust crop".localizedUI)
                    .accessibilityIdentifier("scanAdjustCrop")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var cropEditingBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                cropResetButton
                Spacer(minLength: PPSpacing.small)
                cropCancelButton
                cropApplyButton
                    .frame(maxWidth: 190)
            }

            VStack(spacing: PPSpacing.small) {
                HStack(spacing: PPSpacing.small) {
                    cropResetButton
                    cropCancelButton
                }
                cropApplyButton
            }
        }
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var cropResetButton: some View {
        Button {
            manualCropDraft = .fullFrame
        } label: {
            Label(
                "Reset Corners",
                systemImage: "arrow.counterclockwise"
            )
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
        .accessibilityIdentifier("scanResetCrop")
    }

    private var cropCancelButton: some View {
        Button {
            cancelManualCrop()
        } label: {
            Label("Cancel", systemImage: "xmark")
        }
        .buttonStyle(PPQuietButtonStyle())
        .accessibilityIdentifier("scanCancelCrop")
    }

    private var cropApplyButton: some View {
        Button {
            applyManualCrop()
        } label: {
            Label("Apply Crop", systemImage: "checkmark")
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(!manualCropDraft.isValid)
        .keyboardShortcut(.defaultAction)
        .accessibilityHint(
            (
                manualCropDraft.isValid
                    ? "Applies these crop corners to the current page."
                    : "Move the crop corners until they form a valid page."
            ).localizedUI
        )
        .accessibilityIdentifier("scanApplyCrop")
    }

    private var pageQueue: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(spacing: 6) {
                    pageThumbnailStrip
                    pageActionStrip
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    pageThumbnailStrip
                    pageActionStrip
                }
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var pageThumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                ForEach(
                    Array(workingImages.enumerated()),
                    id: \.offset
                ) { index, image in
                    Button {
                        handlePageTap(index)
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            ScanReviewThumbnail(image: image)
                                .frame(width: 44, height: 54)
                            Text("\(index + 1)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(PPColor.onInk)
                                .padding(.horizontal, 4)
                                .background(PPColor.ink, in: RoundedRectangle(cornerRadius: 3))
                        }
                        .overlay(alignment: .topTrailing) {
                            if isSelectingPages,
                               adjustmentSourcePageIndex != index {
                                Image(
                                    systemName:
                                        selectedPageIndices.contains(index)
                                        ? "checkmark.circle.fill"
                                        : "circle"
                                )
                                .font(.caption.weight(.bold))
                                .foregroundStyle(
                                    selectedPageIndices.contains(index)
                                        ? PPColor.mint
                                        : Color.white
                                )
                                .padding(3)
                                .background(
                                    Color.black.opacity(0.42),
                                    in: Circle()
                                )
                            }
                        }
                        .overlay(alignment: .topLeading) {
                            if isSelectingPages,
                               adjustmentSourcePageIndex == index {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(PPColor.onAccent)
                                    .frame(width: 22, height: 22)
                                    .background(PPColor.cyan, in: Circle())
                                    .padding(3)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(
                                    selectedPageIndices.contains(index)
                                        ? PPColor.mint
                                        : index == pageIndex
                                            ? PPColor.accent
                                            : PPColor.border.opacity(0.56),
                                    lineWidth:
                                        selectedPageIndices.contains(index)
                                            || index == pageIndex
                                        ? 2
                                        : 0.6
                                )
                        }
                    }
                    .buttonStyle(PPPressButtonStyle())
                    .id(index)
                    .accessibilityAddTraits(
                        (isSelectingPages ? selectedPageIndices.contains(index) : index == pageIndex) ? .isSelected : []
                    )
                    .accessibilityLabel(
                        AppLocalization.format(
                            "Scanned page %lld",
                            index + 1
                        )
                    )
                    .accessibilityValue(
                        pageAccessibilityValue(for: index)
                    )
                    .accessibilityHint(
                        (
                            isSelectingPages
                                ? adjustmentSourcePageIndex == index
                                    ? "This page supplies the adjustments."
                                    : "Toggles this target page."
                                : "Shows this scanned page"
                        ).localizedUI
                    )
                    .accessibilityIdentifier(
                        "scanThumbnail-\(index)"
                    )
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $pageScrollPosition, anchor: .center)
        .onAppear {
            pageScrollPosition = pageIndex
        }
        .onChange(of: pageIndex) { _, newValue in
            pageScrollPosition = newValue
        }
        .onChange(of: pageScrollPosition) { _, newValue in
            guard let newValue,
                  newValue != pageIndex,
                  !isSelectingPages
            else { return }
            focusPage(newValue)
        }
        .frame(
            minWidth: min(
                CGFloat(workingImages.count) * 50,
                150
            ),
            maxWidth: .infinity,
            alignment: .leading
        )
        .frame(height: 54)
        .layoutPriority(1)
    }

    private func pageAccessibilityValue(
        for index: Int
    ) -> String {
        if isSelectingPages {
            if adjustmentSourcePageIndex == index {
                return "Adjustment source".localizedUI
            }
            return selectedPageIndices.contains(index)
                ? "Selected".localizedUI
                : "Not selected".localizedUI
        }
        return index == pageIndex
            ? "Current page".localizedUI
            : ""
    }

    private var pageActionStrip: some View {
        HStack(spacing: 4) {
            if purpose == .replacePage {
                pageAction(
                    "Previous Candidate",
                    symbol: "chevron.left",
                    disabled: pageIndex == 0
                ) {
                    focusPage(pageIndex - 1)
                }
                pageAction(
                    "Rotate Clockwise",
                    symbol: "rotate.right"
                ) {
                    rotateCurrentPage()
                }
                pageAction(
                    "Next Candidate",
                    symbol: "chevron.right",
                    disabled: pageIndex >= workingImages.count - 1
                ) {
                    focusPage(pageIndex + 1)
                }
                pageAction(
                    "Remove Candidate",
                    symbol: "trash",
                    tint: .red,
                    disabled: workingImages.count <= 1
                ) {
                    removeCurrentPage()
                }
            } else if isSelectingPages {
                pageAction(
                    selectedPageIndices == selectableTargetPageIndices
                        ? "Clear Selection"
                        : "Select All",
                    symbol: selectedPageIndices
                        == selectableTargetPageIndices
                        ? "circle"
                        : "checkmark.circle"
                ) {
                    toggleAllPages()
                }
                pageAction(
                    "Rotate Selected",
                    symbol: "rotate.right",
                    disabled: selectedPageIndices.isEmpty
                ) {
                    rotateSelectedPages()
                }
                pageAction(
                    "Remove Selected",
                    symbol: "trash",
                    tint: .red,
                    disabled: selectedPageIndices.isEmpty
                        || selectedPageIndices.count
                            >= workingImages.count
                ) {
                    isConfirmingSelectedPageRemoval = true
                }
            } else {
                pageAction(
                    "Move Earlier",
                    symbol: "arrow.left",
                    disabled: pageIndex == 0
                ) {
                    moveCurrentPage(by: -1)
                }
                pageAction(
                    "Rotate Clockwise",
                    symbol: "rotate.right"
                ) {
                    rotateCurrentPage()
                }
                pageAction(
                    "Move Later",
                    symbol: "arrow.right",
                    disabled: pageIndex >= workingImages.count - 1
                ) {
                    moveCurrentPage(by: 1)
                }
                pageAction(
                    "Remove Page",
                    symbol: "trash",
                    tint: .red,
                    disabled: workingImages.count <= 1
                ) {
                    removeCurrentPage()
                }
            }
        }
    }

    private func pageAction(
        _ label: String,
        symbol: String,
        tint: Color = PPColor.accent,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    disabled ? PPColor.textSecondary.opacity(0.4) : tint
                )
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label.localizedUI)
        .help(label.localizedUI)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("scanPageAction-\(label)")
    }

    private var controls: some View {
        ScrollView(.vertical) {
            controlPanel
        }
        .frame(maxHeight: 250)
    }

    private var controlPanel: some View {
        VStack(spacing: 0) {
            previewModeControl

            if purpose == .replacePage {
                Rectangle()
                    .fill(PPColor.border.opacity(0.65))
                    .frame(height: 0.6)

                replacementPreviewGate
            }

            Rectangle()
                .fill(PPColor.border.opacity(0.65))
                .frame(height: 0.6)

            pageAdjustmentScope

            LazyVGrid(
                columns: enhancementColumns,
                spacing: PPSpacing.small
            ) {
                ForEach(ScanEnhancement.allCases) { option in
                    enhancementButton(option)
                }
            }
            .padding(.horizontal, PPSpacing.regular)
            .padding(.vertical, PPSpacing.small)
            .accessibilityIdentifier("scanEnhancementPicker")

            Rectangle()
                .fill(PPColor.border.opacity(0.65))
                .frame(height: 0.6)

            DisclosureGroup(isExpanded: $showsFineAdjustments) {
                VStack(spacing: PPSpacing.small) {
                    toneControls
                        .padding(.horizontal, -PPSpacing.regular)
                    scanToggle(
                        "Auto crop",
                        symbol: "viewfinder",
                        isOn: optionBinding(\.autoCrop)
                    )
                    scanToggle(
                        "Reduce shadows",
                        symbol: "circle.lefthalf.striped.horizontal",
                        isOn: optionBinding(\.removeShadows)
                    )
                    scanToggle(
                        "Clean edges",
                        symbol: "crop",
                        isOn: optionBinding(\.cleanEdges),
                        disabled: !currentOptions.autoCrop
                            && currentOptions.manualCrop == nil
                    )
                }
                .padding(.bottom, PPSpacing.small)
            } label: {
                Label(
                    "Fine adjustments".localizedUI,
                    systemImage: "slider.horizontal.3"
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .frame(minHeight: 44)
            }
            .padding(.horizontal, PPSpacing.regular)
            .accessibilityIdentifier("scanFineAdjustments")

            if purpose == .createPDF {
                DisclosureGroup {
                    Text(
                        "Pages are fitted to standard Letter-sized sheets and may be downsampled. Run Recognize Text afterward to search or copy."
                            .localizedUI
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .padding(.bottom, PPSpacing.small)
                } label: {
                    Label(
                        "Image-based Letter pages".localizedUI,
                        systemImage: "doc.viewfinder"
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(minHeight: 44)
                }
                .padding(.horizontal, PPSpacing.regular)
                .accessibilityIdentifier("scanOutputBoundary")
            }
        }
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.65))
                .frame(height: 0.6)
        }
    }

    private var previewModeControl: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                Menu {
                    ForEach(PreviewMode.allCases) { mode in
                        Button {
                            previewMode = mode
                        } label: {
                            Label(
                                mode.title.localizedUI,
                                systemImage: previewMode == mode
                                    ? "checkmark"
                                    : mode.symbol
                            )
                        }
                    }
                } label: {
                    HStack {
                        Label(
                            previewMode.title.localizedUI,
                            systemImage: previewMode.symbol
                        )
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Picker("Preview", selection: $previewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Label(
                            mode.title.localizedUI,
                            systemImage: mode.symbol
                        )
                        .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .accessibilityIdentifier("scanPreviewMode")
    }

    private var replacementPreviewGate: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.medium) {
                replacementPreviewGateIdentity
                Spacer(minLength: PPSpacing.small)
                if previewMode != .processed {
                    reviewProcessedPreviewButton
                }
            }

            VStack(alignment: .leading, spacing: PPSpacing.small) {
                replacementPreviewGateIdentity
                if previewMode != .processed {
                    reviewProcessedPreviewButton
                }
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(
            replacementPreviewGateTint.opacity(
                isReplacementPreviewCurrent ? 0.08 : 0.05
            )
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(replacementPreviewGateTint.opacity(0.72))
                .frame(width: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scanReplacementPreviewGate")
    }

    private var replacementPreviewGateIdentity: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(replacementPreviewGateTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(replacementPreviewGateDetail)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: replacementPreviewGateSymbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(replacementPreviewGateTint)
        }
    }

    private var reviewProcessedPreviewButton: some View {
        Button {
            previewMode = .processed
        } label: {
            Label("Review Final", systemImage: "eye")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
        .accessibilityIdentifier("scanReviewProcessedPreview")
    }

    private var isReplacementPreviewCurrent: Bool {
        previewMode == .processed
            && !isPreparingPreview
            && !previewFailed
            && preview != nil
            && validatedProcessedPreviewKey
                == processedPreviewValidationKey
    }

    private var replacementPreviewGateTitle: String {
        if isReplacementPreviewCurrent {
            return "Final replacement checked".localizedUI
        }
        if isPreparingPreview {
            return "Preparing final replacement".localizedUI
        }
        if previewFailed {
            return "Final preview needs retry".localizedUI
        }
        if previewMode == .original {
            return "Review final replacement".localizedUI
        }
        return "Waiting for final preview".localizedUI
    }

    private var replacementPreviewGateDetail: String {
        if isReplacementPreviewCurrent {
            return "This processed page is the version that will be inserted."
                .localizedUI
        }
        if isPreparingPreview {
            return "Wait for crop, rotation, and contrast to finish applying."
                .localizedUI
        }
        if previewFailed {
            return "Retry the processed preview before choosing this page."
                .localizedUI
        }
        if previewMode == .original {
            return "Switch to Processed to verify the inserted page, not just the camera capture."
                .localizedUI
        }
        return "The replacement handoff unlocks after the processed preview is current."
            .localizedUI
    }

    private var replacementPreviewGateSymbol: String {
        if isReplacementPreviewCurrent {
            return "checkmark.circle.fill"
        }
        if isPreparingPreview {
            return "arrow.triangle.2.circlepath"
        }
        if previewFailed {
            return "exclamationmark.triangle.fill"
        }
        return "eye"
    }

    private var replacementPreviewGateTint: Color {
        if isReplacementPreviewCurrent {
            return PPColor.mint
        }
        if previewFailed {
            return PPColor.amber
        }
        return PPColor.cyan
    }

    private var pageAdjustmentScope: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                pageAdjustmentIdentity
                Spacer(minLength: PPSpacing.small)
                pageAdjustmentActions
            }

            VStack(
                alignment: .leading,
                spacing: PPSpacing.xSmall
            ) {
                pageAdjustmentIdentity
                pageAdjustmentActions
            }
        }
        .padding(.horizontal, PPSpacing.regular)
    }

    private var pageAdjustmentIdentity: some View {
        Label(
            adjustmentIdentityTitle,
            systemImage: isSelectingPages
                ? "checkmark.circle"
                : "slider.horizontal.3"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var adjustmentIdentityTitle: String {
        if isSelectingPages,
           let adjustmentSourcePageIndex {
            return AppLocalization.format(
                "Page %lld source · %lld selected",
                adjustmentSourcePageIndex + 1,
                selectedPageIndices.count
            )
        }
        return AppLocalization.format(
            "Page %lld adjustments",
            pageIndex + 1
        )
    }

    private var pageAdjustmentActions: some View {
        HStack(spacing: PPSpacing.medium) {
            if workingImages.count > 1 {
                Button(
                    isSelectingPages
                        ? "Copy to Selected"
                        : "Apply to All"
                ) {
                    applyCurrentOptionsToScope()
                }
                .foregroundStyle(PPColor.cyan)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .disabled(
                    isSelectingPages && selectedPageIndices.isEmpty
                )
                .accessibilityHint(
                    (
                        isSelectingPages
                            && selectedPageIndices.isEmpty
                            ? "Choose at least one target page."
                            : isSelectingPages
                            ? "Copies the fixed source page adjustments to the selected target pages."
                            : "Copies this page’s adjustments to every scanned page."
                    ).localizedUI
                )
                .accessibilityIdentifier("scanApplyToScope")
            }

            if purpose == .createPDF,
               workingImages.count > 1 {
                Button(
                    isSelectingPages
                        ? "Done"
                        : "Select Pages"
                ) {
                    togglePageSelectionMode()
                }
                .foregroundStyle(
                    isSelectingPages
                        ? PPColor.mint
                        : PPColor.accent
                )
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("scanSelectPages")
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.plain)
    }

    private func enhancementButton(
        _ option: ScanEnhancement
    ) -> some View {
        Button {
            guard currentOptions.enhancement != option else { return }
            captureUndoSnapshot()
            updateCurrentOptions(clearsUndo: false) {
                $0.enhancement = option
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: option.symbol)
                    .font(.caption.weight(.semibold))
                Text(option.title.localizedUI)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(
                currentOptions.enhancement == option
                    ? PPColor.onAccent
                    : PPColor.textPrimary
            )
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                currentOptions.enhancement == option
                    ? PPColor.accent
                    : Color.clear
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: PPRadius.control,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(
            currentOptions.enhancement == option
                ? .isSelected
                : []
        )
        .accessibilityIdentifier(
            "scanEnhancement-\(option.rawValue)"
        )
    }

    private var enhancementColumns: [GridItem] {
        Array(
            repeating: GridItem(
                .flexible(minimum: 0),
                spacing: PPSpacing.small
            ),
            count: dynamicTypeSize.ppPrefersExpandedLayout ? 1 : 3
        )
    }

    private func scanToggle(
        _ title: String,
        symbol: String,
        isOn: Binding<Bool>,
        disabled: Bool = false
    ) -> some View {
        Toggle(isOn: isOn) {
            Label(title.localizedUI, systemImage: symbol)
                .font(.subheadline)
        }
        .toggleStyle(.switch)
        .frame(
            maxWidth: .infinity,
            minHeight: 44,
            alignment: .leading
        )
        .contentShape(Rectangle())
        .disabled(disabled)
    }

    private var toneControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.medium) {
                toneSlider(
                    "Brightness",
                    symbol: "sun.max",
                    value: doubleOptionBinding(\.brightness),
                    range: -0.35...0.35,
                    displayValue: signedPercent(
                        currentOptions.brightness * 100
                    )
                )
                toneSlider(
                    "Contrast",
                    symbol: "circle.lefthalf.filled",
                    value: doubleOptionBinding(\.contrast),
                    range: 0.7...1.4,
                    displayValue: signedPercent(
                        (currentOptions.contrast - 1) * 100
                    )
                )
                resetToneButton
            }

            VStack(spacing: PPSpacing.small) {
                toneSlider(
                    "Brightness",
                    symbol: "sun.max",
                    value: doubleOptionBinding(\.brightness),
                    range: -0.35...0.35,
                    displayValue: signedPercent(
                        currentOptions.brightness * 100
                    )
                )
                toneSlider(
                    "Contrast",
                    symbol: "circle.lefthalf.filled",
                    value: doubleOptionBinding(\.contrast),
                    range: 0.7...1.4,
                    displayValue: signedPercent(
                        (currentOptions.contrast - 1) * 100
                    )
                )
                HStack {
                    Spacer()
                    resetToneButton
                }
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
    }

    private func toneSlider(
        _ title: String,
        symbol: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        displayValue: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(PPColor.cyan)
                Text(title.localizedUI)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Spacer(minLength: 4)
                Text(displayValue)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .contentTransition(.numericText())
            }
            Slider(
                value: value,
                in: range,
                step: 0.05
            ) { isEditing in
                if isEditing {
                    captureUndoSnapshot()
                }
            }
            .tint(PPColor.cyan)
            .accessibilityLabel(title.localizedUI)
            .accessibilityValue(displayValue)
        }
        .frame(minWidth: 150, maxWidth: .infinity)
    }

    private var resetToneButton: some View {
        Button {
            captureUndoSnapshot()
            updateCurrentOptions(clearsUndo: false) {
                $0.brightness = 0
                $0.contrast = 1
            }
            toneResetFeedback += 1
        } label: {
            Image(systemName: "arrow.counterclockwise")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            currentOptions.hasToneAdjustments
                ? PPColor.cyan
                : PPColor.textSecondary.opacity(0.4)
        )
        .disabled(!currentOptions.hasToneAdjustments)
        .accessibilityLabel("Reset tone adjustments".localizedUI)
        .help("Reset tone adjustments".localizedUI)
    }

    private func updatePreview() async {
        guard scenePhase == .active else { return }
        let generation = UUID()
        previewGeneration = generation
        let requestID = previewTaskID
        if validatedProcessedPreviewKey
            != processedPreviewValidationKey {
            validatedProcessedPreviewKey = nil
        }
        previewFailed = false
        defer {
            if previewGeneration == generation {
                isPreparingPreview = false
            }
        }
        guard workingImages.indices.contains(pageIndex) else {
            preview = nil
            validatedProcessedPreviewKey = nil
            detectedDocument = false
            detectedCropQuad = nil
            return
        }
        guard previewMode == .processed else {
            preview = nil
            detectedDocument = false
            return
        }
        isPreparingPreview = true
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled,
              requestID == previewTaskID
        else { return }
        detectedDocument = false
        detectedCropQuad = nil
        let selectedOptions = currentOptions
        let selectedPage = pageIndex
        let selectedRevision = pageRevision
        let resolvedAutomaticCrop =
            automaticCropResolutions.indices.contains(selectedPage)
                ? automaticCropResolutions[selectedPage]
                : nil
        var previewOptions = selectedOptions
        if previewOptions.autoCrop,
           previewOptions.manualCrop == nil,
           let resolvedAutomaticCrop {
            previewOptions.autoCrop = false
            previewOptions.manualCrop =
                resolvedAutomaticCrop.cropQuad
        }
        let page = ScanPageImage(image: workingImages[selectedPage])
        let renderer = ScanPDFRenderer()
        let worker = Task.detached(
            priority: .userInitiated
        ) { () -> ScanPreviewResult? in
            guard !Task.isCancelled else { return nil }
            let result = autoreleasepool {
                renderer.preview(
                    image: page.image,
                    options: previewOptions
                )
            }
            return Task.isCancelled ? nil : result
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled,
              scenePhase == .active,
              previewGeneration == generation,
              requestID == previewTaskID,
              selectedPage == pageIndex,
              selectedRevision == pageRevision,
              selectedOptions == currentOptions
        else {
            return
        }
        guard let result else {
            preview = nil
            validatedProcessedPreviewKey = nil
            previewFailed = true
            previewErrorFeedback &+= 1
            return
        }
        preview = result.image
        if selectedOptions.autoCrop,
           selectedOptions.manualCrop == nil,
           automaticCropResolutions.indices.contains(selectedPage) {
            let resolution: ScanAutomaticCropResolution =
                result.cropQuad.map(
                    ScanAutomaticCropResolution.crop
                ) ?? .fullFrame
            automaticCropResolutions[selectedPage] = resolution
            detectedDocument = resolution.cropQuad != nil
            detectedCropQuad = resolution.cropQuad
        } else {
            detectedDocument = result.detectedDocument
            detectedCropQuad = result.cropQuad
        }
        validatedProcessedPreviewKey =
            processedPreviewValidationKey
    }

    private func moveCurrentPage(by offset: Int) {
        let destination = pageIndex + offset
        guard workingImages.indices.contains(pageIndex),
              workingImages.indices.contains(destination),
              pageOptions.indices.contains(pageIndex),
              pageOptions.indices.contains(destination),
              automaticCropResolutions.indices.contains(pageIndex),
              automaticCropResolutions.indices.contains(destination)
        else { return }
        captureUndoSnapshot()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            workingImages.swapAt(pageIndex, destination)
            pageOptions.swapAt(pageIndex, destination)
            automaticCropResolutions.swapAt(pageIndex, destination)
            pageIndex = destination
            pageRevision += 1
            preview = nil
            detectedDocument = false
            detectedCropQuad = nil
        }
    }

    private func removeCurrentPage() {
        guard workingImages.count > 1,
              workingImages.indices.contains(pageIndex),
              pageOptions.indices.contains(pageIndex),
              automaticCropResolutions.indices.contains(pageIndex)
        else { return }
        captureUndoSnapshot()
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            workingImages.remove(at: pageIndex)
            pageOptions.remove(at: pageIndex)
            automaticCropResolutions.remove(at: pageIndex)
            pageIndex = min(
                pageIndex,
                workingImages.count - 1
            )
            pageRevision += 1
            preview = nil
            detectedDocument = false
            detectedCropQuad = nil
        }
        editFeedback &+= 1
    }

    private func rotateCurrentPage() {
        guard workingImages.indices.contains(pageIndex),
              pageOptions.indices.contains(pageIndex),
              automaticCropResolutions.indices.contains(pageIndex),
              let rotated = rotatedImage(
                workingImages[pageIndex]
              )
        else { return }
        captureUndoSnapshot()
        workingImages[pageIndex] = rotated
        pageOptions[pageIndex].manualCrop =
            pageOptions[pageIndex].manualCrop?.rotatedClockwise
        automaticCropResolutions[pageIndex] =
            automaticCropResolutions[pageIndex]?
                .rotatedClockwise
        pageRevision += 1
        preview = nil
        detectedDocument = false
        detectedCropQuad = nil
        editFeedback &+= 1
    }

    private var displayedPreview: UIImage? {
        if previewMode == .original,
           workingImages.indices.contains(pageIndex) {
            return workingImages[pageIndex]
        }
        return preview
    }

    private var currentOptions: ScanProcessingOptions {
        guard pageOptions.indices.contains(pageIndex) else {
            return .document
        }
        return pageOptions[pageIndex]
    }

    private var processingSelectionFeedback: String {
        [
            currentOptions.enhancement.rawValue,
            currentOptions.autoCrop ? "crop" : "full",
            currentOptions.removeShadows ? "light" : "natural",
            currentOptions.cleanEdges ? "clean" : "edges"
        ].joined(separator: "-")
    }

    private func optionBinding(
        _ keyPath: WritableKeyPath<ScanProcessingOptions, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: {
                currentOptions[keyPath: keyPath]
            },
            set: { value in
                guard currentOptions[keyPath: keyPath] != value else {
                    return
                }
                captureUndoSnapshot()
                updateCurrentOptions(clearsUndo: false) {
                    $0[keyPath: keyPath] = value
                    if keyPath == \.autoCrop {
                        if value {
                            $0.manualCrop = nil
                        } else if $0.manualCrop == nil {
                            $0.cleanEdges = false
                        }
                    }
                }
            }
        )
    }

    private func doubleOptionBinding(
        _ keyPath: WritableKeyPath<ScanProcessingOptions, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                currentOptions[keyPath: keyPath]
            },
            set: { value in
                updateCurrentOptions(clearsUndo: false) {
                    $0[keyPath: keyPath] = value
                }
            }
        )
    }

    private func updateCurrentOptions(
        clearsUndo: Bool = true,
        _ update: (inout ScanProcessingOptions) -> Void
    ) {
        guard pageOptions.indices.contains(pageIndex) else { return }
        var updatedOptions = pageOptions[pageIndex]
        update(&updatedOptions)
        guard updatedOptions != pageOptions[pageIndex] else { return }
        if clearsUndo {
            undoSnapshot = nil
        }
        pageOptions[pageIndex] = updatedOptions
        previewMode = .processed
        previewGeneration = UUID()
        validatedProcessedPreviewKey = nil
        previewFailed = false
        isPreparingPreview = previewMode == .processed
        detectedDocument = false
        detectedCropQuad = nil
    }

    private func applyCurrentOptionsToScope() {
        let sourceIndex = isSelectingPages
            ? adjustmentSourcePageIndex
            : pageIndex
        guard let sourceIndex,
              pageOptions.indices.contains(sourceIndex)
        else { return }
        let options = pageOptions[sourceIndex]
        var updatedOptions = pageOptions
        let targetIndices = isSelectingPages
            ? selectedPageIndices
            : Set(pageOptions.indices)
        for index in targetIndices
        where pageOptions.indices.contains(index) {
            updatedOptions[index] = transferableOptions(
                options,
                sourceIndex: sourceIndex,
                to: index
            )
        }
        let hasChanges = updatedOptions != pageOptions
        if hasChanges {
            captureUndoSnapshot()
            pageOptions = updatedOptions
        }
        if isSelectingPages {
            isSelectingPages = false
            selectedPageIndices.removeAll()
            adjustmentSourcePageIndex = nil
            focusPage(sourceIndex)
        }
        previewMode = .processed
        guard hasChanges else { return }
        pageRevision &+= 1
        previewGeneration = UUID()
        preview = nil
        previewFailed = false
        isPreparingPreview = true
        validatedProcessedPreviewKey = nil
        detectedDocument = false
        detectedCropQuad = nil
        applyAllFeedback += 1
    }

    private func handlePageTap(_ index: Int) {
        if isSelectingPages {
            guard adjustmentSourcePageIndex != index else { return }
            if selectedPageIndices.contains(index) {
                selectedPageIndices.remove(index)
            } else {
                selectedPageIndices.insert(index)
            }
        } else {
            focusPage(index)
        }
    }

    private func focusPage(_ index: Int) {
        guard workingImages.indices.contains(index),
              index != pageIndex
        else { return }
        detectedDocument = false
        detectedCropQuad = nil
        pageIndex = index
        preview = nil
    }

    private func togglePageSelectionMode() {
        if isSelectingPages {
            isSelectingPages = false
            selectedPageIndices.removeAll()
            adjustmentSourcePageIndex = nil
        } else {
            isSelectingPages = true
            selectedPageIndices.removeAll()
            adjustmentSourcePageIndex = pageIndex
        }
        selectionModeFeedback &+= 1
    }

    private func toggleAllPages() {
        if selectedPageIndices == selectableTargetPageIndices {
            selectedPageIndices.removeAll()
        } else {
            selectedPageIndices = selectableTargetPageIndices
        }
    }

    private var selectableTargetPageIndices: Set<Int> {
        Set(
            workingImages.indices.filter {
                $0 != adjustmentSourcePageIndex
            }
        )
    }

    private func rotateSelectedPages() {
        guard !selectedPageIndices.isEmpty else { return }
        let snapshot = EditSnapshot(
            images: workingImages,
            options: pageOptions,
            automaticCropResolutions: automaticCropResolutions,
            pageIndex: pageIndex,
            isSelectingPages: isSelectingPages,
            selectedPageIndices: selectedPageIndices,
            adjustmentSourcePageIndex: adjustmentSourcePageIndex
        )
        var changed = false
        for index in selectedPageIndices.sorted()
        where workingImages.indices.contains(index)
            && pageOptions.indices.contains(index)
            && automaticCropResolutions.indices.contains(index) {
            if let rotated = rotatedImage(workingImages[index]) {
                changed = true
                workingImages[index] = rotated
                pageOptions[index].manualCrop =
                    pageOptions[index]
                        .manualCrop?
                        .rotatedClockwise
                automaticCropResolutions[index] =
                    automaticCropResolutions[index]?
                        .rotatedClockwise
            }
        }
        guard changed else { return }
        undoSnapshot = snapshot
        pageRevision += 1
        preview = nil
        detectedDocument = false
        detectedCropQuad = nil
        editFeedback &+= 1
    }

    private func beginManualCrop() {
        guard workingImages.indices.contains(pageIndex) else { return }
        previewGeneration = UUID()
        cropPreviousPreviewMode = previewMode
        manualCropDraft =
            currentOptions.manualCrop
                ?? detectedCropQuad
                ?? .fullFrame
        isSelectingPages = false
        selectedPageIndices.removeAll()
        adjustmentSourcePageIndex = nil
        isPreparingPreview = false
        isEditingManualCrop = true
        previewMode = .original
    }

    private func cancelManualCrop() {
        isEditingManualCrop = false
        previewMode = cropPreviousPreviewMode
        manualCropDraft = .fullFrame
    }

    private func applyManualCrop() {
        guard manualCropDraft.isValid,
              pageOptions.indices.contains(pageIndex)
        else { return }
        var updatedOptions = currentOptions
        updatedOptions.manualCrop = manualCropDraft.isEffectivelyFullFrame
            ? nil
            : manualCropDraft
        updatedOptions.autoCrop = false
        if updatedOptions.manualCrop == nil {
            updatedOptions.cleanEdges = false
        }
        if updatedOptions != currentOptions {
            captureUndoSnapshot()
            updateCurrentOptions(clearsUndo: false) {
                $0 = updatedOptions
            }
        }
        isEditingManualCrop = false
        previewMode = .processed
        preview = nil
        detectedCropQuad = nil
        cropAppliedFeedback += 1
    }

    private func transferableOptions(
        _ source: ScanProcessingOptions,
        sourceIndex: Int,
        to index: Int
    ) -> ScanProcessingOptions {
        guard pageOptions.indices.contains(index),
              source.manualCrop != nil,
              index != sourceIndex
        else {
            return source
        }
        var result = source
        let target = pageOptions[index]
        result.manualCrop = target.manualCrop
        result.autoCrop = target.autoCrop
        result.cleanEdges = target.cleanEdges
        return result
    }

    private func removeSelectedPages() {
        guard !selectedPageIndices.isEmpty,
              selectedPageIndices.count < workingImages.count
        else { return }
        captureUndoSnapshot()
        let sourceIndex = adjustmentSourcePageIndex ?? pageIndex
        let removedBeforeSource = selectedPageIndices.reduce(0) {
            $0 + ($1 < sourceIndex ? 1 : 0)
        }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            for index in selectedPageIndices.sorted(by: >) {
                guard workingImages.indices.contains(index),
                      pageOptions.indices.contains(index),
                      automaticCropResolutions.indices.contains(index)
                else { continue }
                workingImages.remove(at: index)
                pageOptions.remove(at: index)
                automaticCropResolutions.remove(at: index)
            }
            pageIndex = min(
                max(0, sourceIndex - removedBeforeSource),
                workingImages.count - 1
            )
            pageRevision += 1
            preview = nil
            detectedDocument = false
            detectedCropQuad = nil
            selectedPageIndices.removeAll()
            isSelectingPages = false
            adjustmentSourcePageIndex = nil
        }
        editFeedback &+= 1
    }

    private func captureUndoSnapshot() {
        undoSnapshot = EditSnapshot(
            images: workingImages,
            options: pageOptions,
            automaticCropResolutions: automaticCropResolutions,
            pageIndex: pageIndex,
            isSelectingPages: isSelectingPages,
            selectedPageIndices: selectedPageIndices,
            adjustmentSourcePageIndex: adjustmentSourcePageIndex
        )
    }

    private func undoLastEdit() {
        guard let snapshot = undoSnapshot,
              snapshot.images.count == snapshot.options.count,
              snapshot.images.count
                == snapshot.automaticCropResolutions.count
        else { return }
        undoSnapshot = nil
        previewGeneration = UUID()
        workingImages = snapshot.images
        pageOptions = snapshot.options
        automaticCropResolutions =
            snapshot.automaticCropResolutions
        pageIndex = min(
            max(0, snapshot.pageIndex),
            max(0, snapshot.images.count - 1)
        )
        isSelectingPages = snapshot.isSelectingPages
        selectedPageIndices = snapshot.selectedPageIndices
            .filter(snapshot.images.indices.contains)
        adjustmentSourcePageIndex =
            snapshot.adjustmentSourcePageIndex.flatMap { index in
                snapshot.images.indices.contains(index)
                    ? index
                    : nil
            }
        isEditingManualCrop = false
        manualCropDraft = .fullFrame
        pageRevision &+= 1
        preview = nil
        previewFailed = false
        detectedDocument = false
        detectedCropQuad = nil
        undoFeedback &+= 1
    }

    private func rotatedImage(
        _ image: UIImage
    ) -> UIImage? {
        if let cgImage = image.cgImage {
            return UIImage(
                cgImage: cgImage,
                scale: image.scale,
                orientation: image.imageOrientation.rotatedClockwise
            )
        }
        if let ciImage = image.ciImage {
            return UIImage(
                ciImage: ciImage,
                scale: image.scale,
                orientation: image.imageOrientation.rotatedClockwise
            )
        }
        return nil
    }

    private func displayedImageSize(
        _ image: UIImage
    ) -> CGSize {
        switch image.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(
                width: image.size.height,
                height: image.size.width
            )
        case .up, .upMirrored, .down, .downMirrored:
            return image.size
        @unknown default:
            return image.size
        }
    }

    private func signedPercent(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        if rounded > 0 {
            return "+\(rounded)%"
        }
        return "\(rounded)%"
    }

    private func reviewedPages(
        at indices: [Int]
    ) -> [ScanPageImage]? {
        guard workingImages.count == pageOptions.count,
              workingImages.count == automaticCropResolutions.count,
              indices.allSatisfy(workingImages.indices.contains)
        else { return nil }
        return indices.map { index in
            ScanPageImage(
                image: workingImages[index],
                processingOptions: pageOptions[index],
                automaticCropResolution:
                    pageOptions[index].autoCrop
                        && pageOptions[index].manualCrop == nil
                    ? automaticCropResolutions[index]
                    : nil
            )
        }
    }

    private func finishReview() {
        guard canFinishReview else { return }
        let savedIndices: [Int]
        switch purpose {
        case .createPDF:
            savedIndices = Array(workingImages.indices)
        case .replacePage:
            savedIndices = [pageIndex]
        }
        guard let pages = reviewedPages(at: savedIndices) else {
            return
        }
        isCompletingReview = true
        previewGeneration = UUID()
        isPreparingPreview = false
        completionFeedback &+= 1
        onSave(pages)
    }

    private func suspendReviewForBackground() {
        guard !didSuspendForProtection else { return }
        didSuspendForProtection = true
        guard !isCompletingReview else {
            clearTransientPreviewState()
            dismiss()
            return
        }
        let pages = reviewedPages(
            at: Array(workingImages.indices)
        )
        clearTransientPreviewState()
        if let pages {
            onSuspend?(pages, pageIndex)
        }
        dismiss()
    }

    private func suspendReviewForProtection() {
        guard !didSuspendForProtection else { return }
        didSuspendForProtection = true
        guard !isCompletingReview else {
            clearTransientPreviewState()
            dismiss()
            return
        }
        let pages = reviewedPages(
            at: Array(workingImages.indices)
        )
        clearTransientPreviewState()
        if let pages {
            onSuspend?(pages, pageIndex)
        }
        dismiss()
    }

    private func clearTransientPreviewState() {
        previewGeneration = UUID()
        validatedProcessedPreviewKey = nil
        isPreparingPreview = false
        preview = nil
        previewFailed = false
        detectedDocument = false
        detectedCropQuad = nil
        isEditingManualCrop = false
        manualCropDraft = .fullFrame
    }
}

private struct ScanReviewThumbnailRequestID: Hashable {
    let imageIdentity: ObjectIdentifier
    let isSceneActive: Bool
}

private struct ScanReviewThumbnail: View {
    @Environment(\.scenePhase) private var scenePhase

    let image: UIImage

    @State private var thumbnail: UIImage?
    @State private var thumbnailFailed = false

    private var requestID: ScanReviewThumbnailRequestID {
        ScanReviewThumbnailRequestID(
            imageIdentity: ObjectIdentifier(image),
            isSceneActive: scenePhase == .active
        )
    }

    var body: some View {
        ZStack {
            PPColor.surfaceMuted
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else if thumbnailFailed {
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .clipped()
        .task(id: requestID) {
            thumbnail = nil
            thumbnailFailed = false
            guard scenePhase == .active else { return }
            let source = image
            let worker = Task.detached(
                priority: .utility
            ) { () -> UIImage? in
                guard !Task.isCancelled else { return nil }
                return autoreleasepool {
                    source.preparingThumbnail(
                        of: CGSize(width: 168, height: 208)
                    )
                }
            }
            let prepared = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled,
                  scenePhase == .active
            else { return }
            if let prepared {
                thumbnail = prepared
            } else {
                thumbnailFailed = true
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ScanManualCropOverlay: View {
    @Binding var quad: ScanCropQuad
    let imageSize: CGSize
    let contentInset: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let imageFrame = aspectFitFrame(
                imageSize: imageSize,
                containerSize: proxy.size
            )
            let points = points(in: imageFrame)

            ZStack {
                cropMask(
                    frame: imageFrame,
                    points: points
                )
                .fill(
                    Color.black.opacity(0.42),
                    style: FillStyle(eoFill: true)
                )
                .allowsHitTesting(false)

                cropPath(points)
                    .stroke(
                        PPColor.cyan,
                        style: StrokeStyle(
                            lineWidth: 2,
                            lineJoin: .round
                        )
                    )
                    .allowsHitTesting(false)

                ForEach(ScanCropCorner.allCases) { corner in
                    cropHandle(
                        corner,
                        frame: imageFrame
                    )
                }
            }
            .coordinateSpace(name: "scanCropOverlay")
        }
    }

    private func cropHandle(
        _ corner: ScanCropCorner,
        frame: CGRect
    ) -> some View {
        let position = viewPoint(
            quad.point(for: corner),
            in: frame
        )
        return Circle()
            .fill(Color.white)
            .overlay {
                Circle()
                    .stroke(PPColor.cyan, lineWidth: 3)
            }
            .frame(width: 20, height: 20)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .position(position)
            .gesture(
                DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named("scanCropOverlay")
                )
                    .onChanged { value in
                        move(
                            corner,
                            to: value.location,
                            in: frame
                        )
                    }
            )
            .accessibilityLabel(cornerTitle(corner).localizedUI)
            .accessibilityValue(cornerPosition(corner))
            .accessibilityAction(
                named: Text("Move Left".localizedUI)
            ) {
                nudge(corner, dx: -0.02, dy: 0)
            }
            .accessibilityAction(
                named: Text("Move Right".localizedUI)
            ) {
                nudge(corner, dx: 0.02, dy: 0)
            }
            .accessibilityAction(
                named: Text("Move Up".localizedUI)
            ) {
                nudge(corner, dx: 0, dy: -0.02)
            }
            .accessibilityAction(
                named: Text("Move Down".localizedUI)
            ) {
                nudge(corner, dx: 0, dy: 0.02)
            }
    }

    private func aspectFitFrame(
        imageSize: CGSize,
        containerSize: CGSize
    ) -> CGRect {
        let available = CGRect(
            x: contentInset,
            y: contentInset,
            width: max(1, containerSize.width - contentInset * 2),
            height: max(1, containerSize.height - contentInset * 2)
        )
        guard imageSize.width > 0, imageSize.height > 0 else {
            return available
        }
        let scale = min(
            available.width / imageSize.width,
            available.height / imageSize.height
        )
        let fitted = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )
        return CGRect(
            x: available.midX - fitted.width / 2,
            y: available.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func points(
        in frame: CGRect
    ) -> [CGPoint] {
        [
            quad.topLeft,
            quad.topRight,
            quad.bottomRight,
            quad.bottomLeft
        ].map {
            viewPoint($0, in: frame)
        }
    }

    private func viewPoint(
        _ point: ScanCropPoint,
        in frame: CGRect
    ) -> CGPoint {
        CGPoint(
            x: frame.minX + CGFloat(point.x) * frame.width,
            y: frame.minY + CGFloat(point.y) * frame.height
        )
    }

    private func cropPath(
        _ points: [CGPoint]
    ) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }

    private func cropMask(
        frame: CGRect,
        points: [CGPoint]
    ) -> Path {
        var path = Path()
        path.addRect(frame)
        path.addPath(cropPath(points))
        return path
    }

    private func move(
        _ corner: ScanCropCorner,
        to location: CGPoint,
        in frame: CGRect
    ) {
        guard frame.width > 0, frame.height > 0 else { return }
        let normalized = ScanCropPoint(
            x: Double(
                (location.x - frame.minX) / frame.width
            ),
            y: Double(
                (location.y - frame.minY) / frame.height
            )
        )
        quad = quad.moving(corner, to: normalized)
    }

    private func nudge(
        _ corner: ScanCropCorner,
        dx: Double,
        dy: Double
    ) {
        let current = quad.point(for: corner)
        quad = quad.moving(
            corner,
            to: ScanCropPoint(
                x: current.x + dx,
                y: current.y + dy
            )
        )
    }

    private func cornerTitle(
        _ corner: ScanCropCorner
    ) -> String {
        switch corner {
        case .topLeft: return "Top-left crop corner"
        case .topRight: return "Top-right crop corner"
        case .bottomRight: return "Bottom-right crop corner"
        case .bottomLeft: return "Bottom-left crop corner"
        }
    }

    private func cornerPosition(
        _ corner: ScanCropCorner
    ) -> String {
        let point = quad.point(for: corner)
        return "\(Int((point.x * 100).rounded()))%, \(Int((point.y * 100).rounded()))%"
    }
}

private extension UIImage.Orientation {
    var rotatedClockwise: UIImage.Orientation {
        switch self {
        case .up: return .right
        case .right: return .down
        case .down: return .left
        case .left: return .up
        case .upMirrored: return .rightMirrored
        case .rightMirrored: return .downMirrored
        case .downMirrored: return .leftMirrored
        case .leftMirrored: return .upMirrored
        @unknown default: return .right
        }
    }
}
