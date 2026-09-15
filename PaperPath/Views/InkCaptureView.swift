import PDFKit
import PencilKit
import SwiftUI

private enum PencilShape: String, CaseIterable, Identifiable {
    case line
    case rectangle
    case ellipse
    case arrow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        }
    }

    var symbol: String {
        switch self {
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.right"
        }
    }
}

private enum PencilHardwareShortcut {
    case switchEraser
    case switchPrevious
    case showContextualPalette
}

struct InkCaptureView: View {
    enum Mode: Equatable {
        case drawing
        case signature

        var title: String {
            switch self {
            case .drawing: return "Draw on page"
            case .signature: return "Add signature"
            }
        }
    }

    private enum SignatureStage: Equatable {
        case capture
        case placement

        var title: String {
            switch self {
            case .capture: return "Draw"
            case .placement: return "Place"
            }
        }
    }

    private enum PencilPreset: String, CaseIterable, Identifiable {
        case pen
        case marker
        case pencil
        case eraser
        case lasso

        var id: String { rawValue }

        var title: String {
            switch self {
            case .pen: return "Pen"
            case .marker: return "Marker"
            case .pencil: return "Pencil"
            case .eraser: return "Eraser"
            case .lasso: return "Lasso"
            }
        }

        var symbol: String {
            switch self {
            case .pen: return "pencil.tip"
            case .marker: return "highlighter"
            case .pencil: return "pencil"
            case .eraser: return "eraser"
            case .lasso: return "lasso"
            }
        }

        func tool(
            color: UIColor,
            widthScale: Double
        ) -> PKTool {
            let scale = CGFloat(widthScale)
            switch self {
            case .pen:
                return PKInkingTool(
                    .pen,
                    color: color,
                    width: 3.2 * scale
                )
            case .marker:
                return PKInkingTool(
                    .marker,
                    color: color.withAlphaComponent(0.62),
                    width: 18 * scale
                )
            case .pencil:
                return PKInkingTool(
                    .pencil,
                    color: color,
                    width: 4.5 * scale
                )
            case .eraser:
                return PKEraserTool(.vector)
            case .lasso:
                return PKLassoTool()
            }
        }
    }

    private enum PencilColor: String, CaseIterable, Identifiable {
        case blue
        case black
        case red
        case yellow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .blue: return "Blue"
            case .black: return "Black"
            case .red: return "Red"
            case .yellow: return "Yellow"
            }
        }

        var value: UIColor {
            switch self {
            case .blue: return .systemBlue
            case .black: return .black
            case .red: return .systemRed
            case .yellow: return .systemYellow
            }
        }

        var displayColor: Color {
            Color(uiColor: value)
        }
    }

    private enum PencilInputMode: String, CaseIterable, Identifiable {
        case anyInput
        case pencilOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .anyInput: return "Touch & Pencil"
            case .pencilOnly: return "Pencil Only"
            }
        }

        var policy: PKCanvasViewDrawingPolicy {
            switch self {
            case .anyInput: return .anyInput
            case .pencilOnly: return .pencilOnly
            }
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let pageIndex: Int
    let mode: Mode
    let onPrepare: () -> Void
    @State private var drawing = PKDrawing()
    @State private var canvasSize: CGSize = .zero
    @State private var signaturePreview: UIImage?
    @State private var pagePreviewImage: UIImage?
    @State private var pagePreviewErrorMessage: String?
    @State private var isLoadingPagePreview = true
    @State private var isPagePreviewVerified = false
    @State private var previewContentRevisionID: UUID?
    @AppStorage("pencil.preset")
    private var savedPencilPreset = PencilPreset.pen.rawValue
    @AppStorage("pencil.color")
    private var savedPencilColor = PencilColor.blue.rawValue
    @AppStorage("pencil.width")
    private var pencilWidthScale = 1.0
    @AppStorage("pencil.input")
    private var savedPencilInputMode = ""
    @State private var pencilCommand: PencilCanvasCommand?
    @State private var pencilZoomCommand: PencilZoomCommand?
    @State private var previousPencilPreset = PencilPreset.pen.rawValue
    @State private var isPencilViewportMode = false
    @State private var canUndoDrawing = false
    @State private var canRedoDrawing = false
    @State private var isShowingPencilShortcutMenu = false
    @State private var rememberSignature = false
    @State private var signatureStage: SignatureStage = .capture
    @State private var signatureBounds: PDFNormalizedRect
    @State private var pageAspectRatio: CGFloat = 612 / 792
    @State private var snapsToMargins = true
    @State private var isConfirmingSavedSignatureRemoval = false
    @State private var isSaving = false
    @State private var operationTask: Task<Void, Never>?
    @State private var operationGeneration = UUID()
    @State private var saveStopRequested = false
    @State private var didCommitInk = false
    @State private var inkValidationMessage: String?
    @State private var signatureLibraryTask: Task<Void, Never>?
    @State private var signatureLibraryGeneration = UUID()
    @State private var busySignatureID: UUID?
    @State private var selectedSignatureID: UUID?
    @State private var didInitializeSignatureSelection = false
    @State private var previewGeneration = 0
    @State private var previewReloadToken = UUID()
    @State private var didLoadSavedSignature = false
    @GestureState private var placementTranslation = CGSize.zero
    @GestureState private var placementScale: CGFloat = 1

    private var pencilPreset: PencilPreset {
        PencilPreset(rawValue: savedPencilPreset) ?? .pen
    }

    private var pencilColor: PencilColor {
        PencilColor(rawValue: savedPencilColor) ?? .blue
    }

    private var pencilInputMode: PencilInputMode {
        if let savedMode = PencilInputMode(
            rawValue: savedPencilInputMode
        ) {
            return savedMode
        }
        return UIPencilInteraction.prefersPencilOnlyDrawing
            ? .pencilOnly
            : .anyInput
    }

    init(
        recordID: UUID,
        pageIndex: Int,
        mode: Mode,
        initialSignatureBounds: PDFNormalizedRect? = nil,
        onPrepare: @escaping () -> Void = {}
    ) {
        self.recordID = recordID
        self.pageIndex = pageIndex
        self.mode = mode
        self.onPrepare = onPrepare
        _signatureBounds = State(
            initialValue: Self.initialPlacement(
                from: initialSignatureBounds
            )
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if mode == .drawing {
                    pencilSurface(
                        availableSize: proxy.size
                    )
                } else if signatureStage == .capture {
                    signatureCapture(
                        maxWidth: min(proxy.size.width - 48, 620)
                    )
                } else {
                    signaturePlacementSurface(
                        availableSize: proxy.size
                    )
                }
            }
            .background(PPColor.canvas)
            .safeAreaInset(edge: .top, spacing: 0) {
                precisionContextBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if mode == .signature {
                    signatureControls
                } else {
                    pencilControls
                }
            }
            .navigationTitle(mode.title.localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            saveStopRequested
                                ? "Stopping"
                                : hasActiveInkTask
                                    ? "Stop"
                                    : didCommitInk
                                        ? "Done"
                                        : "Cancel"
                        ).localizedUI
                    ) {
                        if hasActiveInkTask {
                            stopActiveInkTask()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saveStopRequested)
                }
                if mode == .drawing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save()
                        }
                        .disabled(
                            drawing.strokes.isEmpty
                                || canvasSize.width <= 0
                                || !isPagePreviewVerified
                                || hasActiveInkTask
                                || didCommitInk
                        )
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .onAppear {
#if DEBUG
                // #region debug-point C:experience-presentations
                if let endpoint = ProcessInfo.processInfo.environment["DEBUG_SERVER_URL"], let url = URL(string: endpoint) { var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "experience-presentations", "runId": ProcessInfo.processInfo.environment["DEBUG_RUN_ID"] ?? "pre-fix", "hypothesisId": "C", "location": "InkCaptureView.appeared", "msg": "[DEBUG] Ink view appeared", "data": ["saving": isSaving]]); URLSession.shared.dataTask(with: request).resume() }
                // #endregion
#endif
                initializeSignatureSelectionIfNeeded()
            }
            .onChange(of: savedPencilPreset) { _, _ in
                announcePencilState(pencilPreset.title.localizedUI)
            }
            .onChange(of: savedPencilInputMode) { _, _ in
                announcePencilState(pencilInputMode.title.localizedUI)
            }
            .onChange(of: isPencilViewportMode) { _, enabled in
                announcePencilState(
                    (enabled ? "Move and zoom page" : pencilPreset.title).localizedUI
                )
            }
            .task(id: previewReloadToken) {
                previewGeneration += 1
                let generation = previewGeneration
                guard let requestedRevisionID =
                        model.record(id: recordID)?
                            .contentRevisionID
                else {
                    isLoadingPagePreview = false
                    pagePreviewErrorMessage =
                        "The private working copy could not be opened."
                            .localizedUI
                    return
                }
                isLoadingPagePreview = true
                isPagePreviewVerified = false
                previewContentRevisionID = requestedRevisionID
                pagePreviewErrorMessage = nil
                pagePreviewImage = nil
                if mode == .signature,
                   !didLoadSavedSignature,
                   let saved = selectedSavedSignatureDrawing() {
                    drawing = saved
                    didLoadSavedSignature = true
                }
                guard let url = model.url(for: recordID)
                else {
                    isLoadingPagePreview = false
                    pagePreviewErrorMessage =
                        "The private working copy could not be opened."
                            .localizedUI
                    return
                }
                let preview = await PDFEditorPreviewLoader.shared.preview(
                    url: url,
                    pageIndex: pageIndex,
                    revision: model.refreshToken(for: recordID),
                    longEdge: 1_800
                )
                guard !Task.isCancelled,
                      generation == previewGeneration,
                      model.record(id: recordID)?
                        .contentRevisionID == requestedRevisionID
                else { return }
                guard let preview else {
                    isLoadingPagePreview = false
                    pagePreviewErrorMessage =
                        "The page preview could not be loaded. Try again."
                            .localizedUI
                    return
                }
                pageAspectRatio = CGFloat(preview.aspectRatio)
                pagePreviewImage = preview.image
                previewContentRevisionID = requestedRevisionID
                isPagePreviewVerified = true
                isLoadingPagePreview = false
            }
            .onChange(
                of: model.record(id: recordID)?
                    .contentRevisionID
            ) { _, revisionID in
                guard !isSaving, !didCommitInk,
                      let previewContentRevisionID,
                      revisionID != previewContentRevisionID
                else { return }
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                interruptProtectedInkWork()
                dismiss()
            }
            .onChange(of: model.savedSignatures.map(\.id)) {
                _, signatureIDs in
                guard let selectedSignatureID,
                      !signatureIDs.contains(selectedSignatureID)
                else { return }
                self.selectedSignatureID = nil
                isConfirmingSavedSignatureRemoval = false
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    if mode == .signature,
                       signatureStage == .placement,
                       signaturePreview == nil {
                        signaturePreview = makeSignatureImage()
                    }
                    if !isPagePreviewVerified {
                        previewReloadToken = UUID()
                    }
                } else if phase == .background {
                    interruptProtectedInkWork()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptProtectedInkWork()
            }
            .confirmationDialog(
                "Remove selected signature?",
                isPresented: $isConfirmingSavedSignatureRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Selected Signature", role: .destructive) {
                    removeSelectedSavedSignature()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("PDFs already signed with it will not change.")
            }
            .alert(
                "Drawing Not Saved".localizedUI,
                isPresented: Binding(
                    get: { inkValidationMessage != nil },
                    set: { if !$0 { inkValidationMessage = nil } }
                )
            ) {
                Button("OK".localizedUI, role: .cancel) {}
            } message: {
                Text(inkValidationMessage?.localizedUI ?? "")
            }
            .confirmationDialog(
                "Pencil controls",
                isPresented: $isShowingPencilShortcutMenu,
                titleVisibility: .visible
            ) {
                Button("Pen") {
                    selectPencilPreset(.pen)
                }
                Button("Marker") {
                    selectPencilPreset(.marker)
                }
                Button("Pencil") {
                    selectPencilPreset(.pencil)
                }
                if canUndoDrawing {
                    Button("Undo Last Stroke") {
                        pencilCommand = PencilCanvasCommand(action: .undo)
                    }
                }
                if canRedoDrawing {
                    Button("Redo Stroke") {
                        pencilCommand = PencilCanvasCommand(action: .redo)
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .interactiveDismissDisabled(hasActiveInkTask)
            .accessibilityAction(.escape) {
                if hasActiveInkTask {
                    stopActiveInkTask()
                } else {
                    dismiss()
                }
            }
            .sensoryFeedback(
                .selection,
                trigger: signatureStage
            )
            .sensoryFeedback(
                .error,
                trigger: pagePreviewErrorMessage
            )
            .onDisappear {
                interruptProtectedInkWork()
            }
        }
    }

    private var precisionContextBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PPSpacing.medium) {
                Label(
                    "Page \(pageIndex + 1)",
                    systemImage: "doc.text"
                )
                Label(
                    pagePreviewStatusTitle,
                    systemImage: pagePreviewStatusSymbol
                )
                .foregroundStyle(pagePreviewStatusColor)
                Label(
                    (
                        mode == .signature
                            ? signatureStage.title
                            : (
                                isPencilViewportMode
                                    ? "Move & Zoom"
                                    : pencilPreset.title
                            )
                    ).localizedUI,
                    systemImage: mode == .signature
                        ? "signature"
                        : (
                            isPencilViewportMode
                                ? "hand.draw"
                                : pencilPreset.symbol
                        )
                )
                if mode == .drawing {
                    Label(
                        "\(drawing.strokes.count)",
                        systemImage: "scribble"
                    )
                    Label(
                        pencilInputMode.title.localizedUI,
                        systemImage: "pencil.and.scribble"
                    )
                } else {
                    Label(
                        model.savedSignatures.isEmpty
                            ? "Not saved".localizedUI
                            : AppLocalization.format(
                                "%lld saved",
                                model.savedSignatures.count
                            ),
                        systemImage: model.savedSignatures.isEmpty
                            ? "internaldrive"
                            : "checkmark.circle"
                    )
                }
                OnDeviceBadge(compact: true)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PPSpacing.regular)
        }
        .scrollIndicators(.hidden)
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        .lineLimit(1)
        .frame(minHeight: 44)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var pagePreviewStatusTitle: String {
        if isLoadingPagePreview {
            return "Loading preview".localizedUI
        }
        if pagePreviewErrorMessage != nil || !isPagePreviewVerified {
            return "Preview unavailable".localizedUI
        }
        return "Preview ready".localizedUI
    }

    private var pagePreviewStatusSymbol: String {
        if isLoadingPagePreview {
            return "hourglass"
        }
        if pagePreviewErrorMessage != nil || !isPagePreviewVerified {
            return "exclamationmark.triangle"
        }
        return "checkmark.circle"
    }

    private var pagePreviewStatusColor: Color {
        if pagePreviewErrorMessage != nil || !isPagePreviewVerified {
            return PPColor.amber
        }
        if isLoadingPagePreview {
            return PPColor.textSecondary
        }
        return PPColor.mint
    }

    private var pagePreviewLoadingState: some View {
        VStack(spacing: PPSpacing.small) {
            ProgressView()
            Text("Loading page preview".localizedUI)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func pagePreviewFailureState(
        _ message: String
    ) -> some View {
        VStack(spacing: PPSpacing.small) {
            Image(systemName: "doc.questionmark")
                .font(.title2)
                .foregroundStyle(PPColor.amber)
            Text("Preview unavailable".localizedUI)
                .font(.headline)
                .foregroundStyle(PPColor.textPrimary)
            Text(message)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                retryPagePreview()
            } label: {
                Label(
                    "Load Preview Again",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
            .accessibilityIdentifier("retryInkPagePreview")
        }
        .padding(PPSpacing.regular)
    }

    private func compactPagePreviewFailure(
        _ message: String
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PPSpacing.small) {
                Label(
                    message,
                    systemImage: "doc.questionmark"
                )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .lineLimit(2)
                Spacer(minLength: PPSpacing.small)
                retryPagePreviewButton
            }
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                Label(
                    message,
                    systemImage: "doc.questionmark"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.amber)
                .fixedSize(horizontal: false, vertical: true)
                retryPagePreviewButton
            }
        }
    }

    private var retryPagePreviewButton: some View {
        Button {
            retryPagePreview()
        } label: {
            Label(
                "Retry Preview",
                systemImage: "arrow.clockwise"
            )
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
        .accessibilityIdentifier("retrySignaturePagePreview")
    }

    private func retryPagePreview() {
        previewGeneration += 1
        pagePreviewImage = nil
        pagePreviewErrorMessage = nil
        isPagePreviewVerified = false
        isLoadingPagePreview = true
        previewReloadToken = UUID()
    }

    private func pencilSurface(
        availableSize: CGSize
    ) -> some View {
        let pageSize = fittedPageSize(in: availableSize)
        return ZStack {
            PPColor.canvas

            PencilCanvas(
                drawing: $drawing,
                canvasSize: $canvasSize,
                tool: pencilPreset.tool(
                    color: pencilColor.value,
                    widthScale: pencilWidthScale
                ),
                backgroundImage: pagePreviewImage,
                referenceSize: CGSize(width: 768, height: 768 / pageAspectRatio),
                drawingPolicy: pencilInputMode.policy,
                allowsViewportGestures: isPencilViewportMode,
                command: pencilCommand,
                zoomCommand: pencilZoomCommand,
                onHardwareShortcut: handlePencilShortcut,
                onHistoryChange: { canUndo, canRedo in
                    canUndoDrawing = canUndo
                    canRedoDrawing = canRedo
                }
            )
            .allowsHitTesting(isPagePreviewVerified)
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            .overlay {
                if isLoadingPagePreview {
                    pagePreviewLoadingState
                } else if let pagePreviewErrorMessage {
                    pagePreviewFailureState(pagePreviewErrorMessage)
                } else if !isPagePreviewVerified {
                    pagePreviewFailureState(
                        "The page preview stopped before it was ready. Try again."
                            .localizedUI
                    )
                }
            }
        }
    }

    private var pencilControls: some View {
        VStack(spacing: PPSpacing.small) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PPSpacing.small) {
                    Button {
                        withAnimation(
                            reduceMotion ? nil : .easeInOut(duration: 0.16)
                        ) {
                            isPencilViewportMode.toggle()
                        }
                    } label: {
                        Image(systemName: "hand.draw")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(
                                isPencilViewportMode
                                    ? Color.white
                                    : PPColor.textPrimary
                            )
                            .background(
                                isPencilViewportMode
                                    ? PPColor.cyan
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Move and zoom page")
                    .accessibilityHint(
                        "Use one finger to move the page and two fingers to zoom. Choose a drawing tool to continue marking."
                    )
                    .accessibilityAddTraits(
                        isPencilViewportMode ? .isSelected : []
                    )

                    ForEach(PencilPreset.allCases) { preset in
                        Button {
                            selectPencilPreset(preset)
                        } label: {
                            Image(systemName: preset.symbol)
                                .font(.body.weight(.semibold))
                                .frame(width: 44, height: 44)
                                .foregroundStyle(
                                    pencilPreset == preset
                                        ? Color.white
                                        : PPColor.textPrimary
                                )
                                .background(
                                    pencilPreset == preset
                                        ? PPColor.accent
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.title.localizedUI)
                        .accessibilityAddTraits(
                            pencilPreset == preset ? .isSelected : []
                        )
                    }

                    Menu {
                        ForEach(PencilShape.allCases) { shape in
                            Button {
                                insert(shape)
                            } label: {
                                Label(
                                    shape.title.localizedUI,
                                    systemImage: shape.symbol
                                )
                            }
                        }
                    } label: {
                        Image(systemName: "square.on.circle")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Insert shape")

                    Button {
                        pencilZoomCommand = PencilZoomCommand(action: .fit)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fit page")

                    Button {
                        pencilCommand = PencilCanvasCommand(action: .undo)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canUndoDrawing)
                    .accessibilityLabel("Undo stroke")
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Undo stroke".localizedUI)

                    Button {
                        pencilCommand = PencilCanvasCommand(action: .redo)
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRedoDrawing)
                    .accessibilityLabel("Redo stroke")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .help("Redo stroke".localizedUI)
                }
            }
            .scrollClipDisabled()
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.large) {
                    pencilColorAndWidth
                    pencilInputAndClear
                        .frame(maxWidth: 250)
                }
                VStack(spacing: PPSpacing.small) {
                    pencilColorAndWidth
                    pencilInputAndClear
                }
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.small)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .sensoryFeedback(.selection, trigger: pencilPreset)
        .sensoryFeedback(.selection, trigger: pencilColor)
    }

    private var pencilColorAndWidth: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    pencilColorButtons
                    pencilWidthSlider
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    pencilColorButtons
                    pencilWidthSlider
                }
            }
        }
    }

    private var pencilColorButtons: some View {
        HStack(spacing: PPSpacing.small) {
            ForEach(PencilColor.allCases) { color in
                Button {
                    savedPencilColor = color.rawValue
                } label: {
                    Circle()
                        .fill(color.displayColor)
                        .frame(width: 24, height: 24)
                        .overlay {
                            Circle()
                                .stroke(
                                    pencilColor == color
                                        ? PPColor.textPrimary
                                        : PPColor.border,
                                    lineWidth: pencilColor == color
                                        ? 2
                                        : 0.8
                                )
                                .padding(-4)
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    AppLocalization.format(
                        "%@ ink",
                        color.title.localizedUI
                    )
                )
                .accessibilityAddTraits(
                    pencilColor == color ? .isSelected : []
                )
            }
        }
    }

    private var pencilWidthSlider: some View {
        Slider(
            value: $pencilWidthScale,
            in: 0.65...1.8
        ) {
            Text("Stroke width")
        } minimumValueLabel: {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
        } maximumValueLabel: {
            Image(systemName: "circle.fill")
                .font(.system(size: 13))
        }
    }

    private var pencilInputAndClear: some View {
        HStack(spacing: PPSpacing.medium) {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                pencilInputPicker
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                pencilInputPicker
                    .pickerStyle(.segmented)
            }

            Button(role: .destructive) {
                pencilCommand = PencilCanvasCommand(action: .clear)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(drawing.strokes.isEmpty)
            .accessibilityLabel("Clear page drawing")
        }
    }

    private var pencilInputPicker: some View {
        Picker(
            "Input",
            selection: Binding(
                get: { pencilInputMode },
                set: { savedPencilInputMode = $0.rawValue }
            )
        ) {
            ForEach(PencilInputMode.allCases) { inputMode in
                Text(inputMode.title.localizedUI).tag(inputMode)
            }
        }
    }

    private func insert(_ shape: PencilShape) {
        isPencilViewportMode = false
        selectPencilPreset(.lasso)
        model[noticeFor: paperPathSceneID] = AppLocalization.format(
            "%@ inserted · Lasso selected",
            shape.title.localizedUI
        )
        pencilCommand = PencilCanvasCommand(
            action: .insertShape(
                shape,
                pdfInkColor(from: pencilColor.value),
                pencilWidthScale
            )
        )
    }

    private func selectPencilPreset(_ preset: PencilPreset) {
        isPencilViewportMode = false
        guard pencilPreset != preset else { return }
        previousPencilPreset = pencilPreset.rawValue
        savedPencilPreset = preset.rawValue
    }

    private func announcePencilState(_ message: String) {
        guard voiceOverEnabled, scenePhase == .active else { return }
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    private func handlePencilShortcut(
        _ shortcut: PencilHardwareShortcut
    ) {
        isPencilViewportMode = false
        switch shortcut {
        case .switchEraser:
            if pencilPreset == .eraser {
                let previous = PencilPreset(
                    rawValue: previousPencilPreset
                ) ?? .pen
                savedPencilPreset = previous == .eraser
                    ? PencilPreset.pen.rawValue
                    : previous.rawValue
            } else {
                previousPencilPreset = pencilPreset.rawValue
                savedPencilPreset = PencilPreset.eraser.rawValue
            }
        case .switchPrevious:
            let previous = PencilPreset(
                rawValue: previousPencilPreset
            ) ?? .pen
            previousPencilPreset = pencilPreset.rawValue
            savedPencilPreset = previous.rawValue
        case .showContextualPalette:
            isShowingPencilShortcutMenu = true
        }
    }

    private var signatureControls: some View {
        VStack(spacing: PPSpacing.small) {
            if signatureStage == .capture {
                captureControls
            } else {
                placementControls
            }
        }
        .padding(PPSpacing.regular)
        .background(.bar)
    }

    private var captureControls: some View {
        VStack(spacing: PPSpacing.small) {
            if let pagePreviewErrorMessage {
                compactPagePreviewFailure(pagePreviewErrorMessage)
            }

            if !model.savedSignatures.isEmpty {
                savedSignatureRail
            }

            Group {
                if dynamicTypeSize.ppPrefersExpandedLayout {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        capturePreferenceControls
                    }
                } else {
                    HStack {
                        capturePreferenceControls
                    }
                }
            }

            Button {
                signaturePreview = makeSignatureImage()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    resizeSignature(to: signatureBounds.width)
                    signatureStage = .placement
                }
            } label: {
                Label(
                    "Place on Page",
                    systemImage: "arrow.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(
                drawing.strokes.isEmpty
                    || !isPagePreviewVerified
                    || signatureLibraryTask != nil
            )
            .accessibilityHint(
                signatureAdvanceHint.localizedUI
            )

            if !model.savedSignatures.isEmpty {
                Button("Remove Selected Signature") {
                    isConfirmingSavedSignatureRemoval = true
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .disabled(
                    signatureLibraryTask != nil
                        || selectedSignatureID == nil
                )
            }
        }
    }

    private var capturePreferenceControls: some View {
        Group {
            Toggle(
                "Remember on this device",
                isOn: $rememberSignature
            )
            .font(.subheadline)

            if !drawing.strokes.isEmpty {
                Button {
                    drawing = PKDrawing()
                    signaturePreview = nil
                    selectedSignatureID = nil
                } label: {
                    Label("Clear", systemImage: "eraser")
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.textSecondary)
            }
        }
        .disabled(signatureLibraryTask != nil)
    }

    private var savedSignatureRail: some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            HStack(spacing: PPSpacing.small) {
                Label(
                    AppLocalization.format(
                        "Saved %lld/%lld",
                        model.savedSignatures.count,
                        SignatureStore.maximumSignatureCount
                    ),
                    systemImage: "signature"
                )
                Spacer(minLength: 0)
                if let selectedIndex = selectedSignatureIndex {
                    Text("#\(selectedIndex + 1)")
                        .monospacedDigit()
                }
                if signatureLibraryTask != nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(
                            "Updating saved signatures".localizedUI
                        )
                }
            }
            .font(.caption.smallCaps().weight(.semibold))
            .foregroundStyle(PPColor.textSecondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PPSpacing.small) {
                    ForEach(
                        Array(model.savedSignatures.enumerated()),
                        id: \.element.id
                    ) { index, entry in
                        savedSignatureButton(entry, index: index)
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    private var selectedSignatureIndex: Int? {
        guard let selectedID = selectedSignatureID else { return nil }
        return model.savedSignatures.firstIndex { $0.id == selectedID }
    }

    private func savedSignatureButton(
        _ entry: SavedSignature,
        index: Int
    ) -> some View {
        let isSelected = selectedSignatureID == entry.id
        return Button {
            useSavedSignature(entry)
        } label: {
            HStack(spacing: PPSpacing.small) {
                Text("\(index + 1)")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(
                        isSelected ? Color.white : PPColor.textSecondary
                    )
                    .frame(width: 18, height: 18)
                    .background(
                        isSelected
                            ? PPColor.accent
                            : PPColor.border.opacity(0.32),
                        in: Circle()
                    )

                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                    if let image = signatureThumbnail(from: entry.data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    } else {
                        Image(systemName: "signature")
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                    }
                }
                .frame(width: 58, height: 32)
            }
            .padding(.horizontal, PPSpacing.small)
            .padding(.vertical, PPSpacing.xSmall)
            .frame(minHeight: 44)
            .background(
                Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? PPColor.accent : PPColor.border,
                        lineWidth: isSelected ? 1.6 : 0.8
                    )
            }
            .overlay {
                if busySignatureID == entry.id {
                    ProgressView()
                        .controlSize(.small)
                        .padding(PPSpacing.xSmall)
                        .background(.regularMaterial, in: Circle())
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(signatureLibraryTask != nil || isSaving)
        .accessibilityLabel(
            AppLocalization.format(
                "Saved signature %lld",
                index + 1
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button(role: .destructive) {
                removeSavedSignature(entry)
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private var placementControls: some View {
        VStack(spacing: PPSpacing.small) {
            PrecisionPlacementRail(
                bounds: $signatureBounds,
                tint: PPColor.accent,
                title: "Signature"
            )
            Group {
                if dynamicTypeSize.ppPrefersExpandedLayout {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        placementAdjustmentControls
                    }
                } else {
                    HStack(spacing: PPSpacing.medium) {
                        placementAdjustmentControls
                    }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    placeOnlyButton
                    prepareButton
                }
                VStack(spacing: PPSpacing.small) {
                    prepareButton
                    placeOnlyButton
                }
            }
        }
    }

    @ViewBuilder
    private var placementAdjustmentControls: some View {
        Button {
            withAnimation(
                reduceMotion ? nil : .easeInOut(duration: 0.22)
            ) {
                signatureStage = .capture
            }
        } label: {
            Label("Edit", systemImage: "pencil")
        }
        .buttonStyle(.plain)

        Slider(
            value: Binding(
                get: { signatureBounds.width },
                set: { resizeSignature(to: $0) }
            ),
            in: 0.18...0.72
        ) {
            Text("Signature size")
        } minimumValueLabel: {
            Image(systemName: "signature")
                .font(.caption2)
        } maximumValueLabel: {
            Image(systemName: "signature")
                .font(.title3)
        }

        Toggle(isOn: $snapsToMargins) {
            Image(systemName: "dot.scope")
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .accessibilityLabel("Snap to page margins")
    }

    private var placeOnlyButton: some View {
        Button {
            save()
        } label: {
            Label("Place Only", systemImage: "signature")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPQuietButtonStyle())
        .disabled(
            drawing.strokes.isEmpty
                || canvasSize.width <= 0
                || !isPagePreviewVerified
                || hasActiveInkTask
        )
        .accessibilityHint(signaturePlacementSaveHint.localizedUI)
        .accessibilityIdentifier("placeSignatureOnly")
    }

    private var prepareButton: some View {
        Button {
            save(preparesDelivery: true)
        } label: {
            Label(
                "Place & Continue",
                systemImage: "checkmark.shield"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(
            drawing.strokes.isEmpty
                || canvasSize.width <= 0
                || !isPagePreviewVerified
                || hasActiveInkTask
        )
        .accessibilityHint(
            (
                signaturePlacementDisabledReason
                    ?? "Places the signature, then continues to the next required step"
            ).localizedUI
        )
        .accessibilityIdentifier("placeSignatureAndVerify")
    }

    private func signatureCapture(maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            Spacer()
            Text("Sign for page \(pageIndex + 1)")
                .font(.caption.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .accessibilityIdentifier("signaturePageContext")

            ZStack {
                RoundedRectangle(
                    cornerRadius: PPRadius.document,
                    style: .continuous
                )
                .fill(Color.white)

                PencilCanvas(
                    drawing: $drawing,
                    canvasSize: $canvasSize,
                    tool: PKInkingTool(
                        .pen,
                        color: .black,
                        width: 4
                    )
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: PPRadius.document,
                        style: .continuous
                    )
                )

                VStack {
                    Spacer()
                    Rectangle()
                        .fill(Color.black.opacity(0.18))
                        .frame(height: 1)
                        .padding(.horizontal, PPSpacing.xLarge)
                        .padding(.bottom, 44)
                }
                .allowsHitTesting(false)
            }
            .frame(maxWidth: maxWidth)
            .aspectRatio(2.4, contentMode: .fit)
            .shadow(color: .black.opacity(0.12), radius: 18, y: 8)

            Text("Draw once, then place it precisely on the PDF.")
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(PPSpacing.xLarge)
        .frame(maxWidth: .infinity)
    }

    private func signaturePlacementSurface(
        availableSize: CGSize
    ) -> some View {
        let pageSize = fittedPageSize(in: availableSize)
        return ZStack {
            PPColor.canvas

            ZStack {
                Color.white
                if let pagePreviewImage,
                   isPagePreviewVerified {
                    Image(uiImage: pagePreviewImage)
                        .resizable()
                        .scaledToFit()
                    signaturePlacementOverlay(pageSize: pageSize)
                } else if isLoadingPagePreview {
                    pagePreviewLoadingState
                } else if let pagePreviewErrorMessage {
                    pagePreviewFailureState(pagePreviewErrorMessage)
                } else {
                    pagePreviewFailureState(
                        "The page preview stopped before it was ready. Try again."
                            .localizedUI
                    )
                }
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            AppLocalization.format(
                "Signature placement on page %lld",
                pageIndex + 1
            )
        )
    }

    private func signaturePlacementOverlay(
        pageSize: CGSize
    ) -> some View {
        let rect = displayedSignatureRect(pageSize: pageSize)
        return ZStack(alignment: .bottomTrailing) {
            if let image = signaturePreview {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(5)
            }

            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(PPColor.accent)
                .padding(5)
                .background(.regularMaterial, in: Circle())
                .offset(x: 7, y: 7)
                .accessibilityHidden(true)
        }
        .frame(width: rect.width, height: rect.height)
        .background(Color.white.opacity(0.72))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .stroke(PPColor.accent, lineWidth: 1.5)
        }
        .position(x: rect.midX, y: rect.midY)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($placementTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    moveSignature(
                        by: value.translation,
                        pageSize: pageSize
                    )
                }
        )
        .simultaneousGesture(
            MagnificationGesture()
                .updating($placementScale) { value, state, _ in
                    state = value
                }
                .onEnded { value in
                    scaleSignature(by: value)
                }
        )
        .accessibilityLabel("Signature placement")
        .accessibilityHint(
            "Drag to move or pinch to resize within the page"
        )
        .accessibilityValue(
            AppLocalization.format(
                "%lld percent page width",
                Int(signatureBounds.width * 100)
            )
        )
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.04 : -0.04
            resizeSignature(to: signatureBounds.width + delta)
        }
        .accessibilityAction(
            named: Text("Move signature left")
        ) {
            nudgeSignature(x: -0.025, y: 0)
        }
        .accessibilityAction(
            named: Text("Move signature right")
        ) {
            nudgeSignature(x: 0.025, y: 0)
        }
        .accessibilityAction(
            named: Text("Move signature up")
        ) {
            nudgeSignature(x: 0, y: -0.025)
        }
        .accessibilityAction(
            named: Text("Move signature down")
        ) {
            nudgeSignature(x: 0, y: 0.025)
        }
    }

    private func selectedSavedSignatureDrawing() -> PKDrawing? {
        let selectedID = selectedSignatureID
            ?? model.selectedSignatureID
        guard let entry = model.savedSignatures.first(
            where: { $0.id == selectedID }
        ) ?? model.savedSignatures.first
        else { return nil }
        return try? PKDrawing(data: entry.data)
    }

    private func useSavedSignature(_ entry: SavedSignature) {
        guard let saved = try? PKDrawing(data: entry.data),
              !saved.strokes.isEmpty
        else { return }
        drawing = saved
        signaturePreview = makeSignatureImage(from: saved)
        rememberSignature = false
        selectedSignatureID = entry.id
        selectSavedSignature(entry.id)
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            resizeSignature(to: signatureBounds.width)
            signatureStage = .placement
        }
    }

    private func removeSavedSignature(_ entry: SavedSignature) {
        let wasActive = selectedSignatureID == entry.id
        let generation = beginSignatureLibraryOperation(
            signatureID: entry.id
        )
        signatureLibraryTask = Task { @MainActor in
            await model.withFeedbackTarget(paperPathSceneID) {
                await model.removeSavedSignature(entry.id)
            }
            guard !Task.isCancelled,
                  signatureLibraryGeneration == generation
            else { return }
            signatureLibraryTask = nil
            busySignatureID = nil
            guard !model.savedSignatures.contains(
                where: { $0.id == entry.id }
            ) else { return }
            if wasActive {
                selectedSignatureID = nil
                clearActiveSignatureAfterRemoval()
            }
        }
    }

    private func signatureThumbnail(from data: Data) -> UIImage? {
        guard let saved = try? PKDrawing(data: data) else { return nil }
        return makeSignatureImage(from: saved)
    }

    private func makeSignatureImage() -> UIImage? {
        makeSignatureImage(from: drawing)
    }

    private func makeSignatureImage(from source: PKDrawing) -> UIImage? {
        guard !source.strokes.isEmpty else { return nil }
        let bounds = source.bounds.insetBy(dx: -8, dy: -8)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return source.image(from: bounds, scale: 2)
    }

    private var signatureDrawingAspectRatio: CGFloat {
        let bounds = drawing.bounds
        guard bounds.width > 0, bounds.height > 0 else { return 2.8 }
        return min(max(bounds.width / bounds.height, 1.2), 6)
    }

    private func fittedPageSize(in availableSize: CGSize) -> CGSize {
        let maximum = CGSize(
            width: max(1, availableSize.width - 32),
            height: max(1, availableSize.height - 24)
        )
        guard maximum.width / maximum.height > pageAspectRatio else {
            return CGSize(
                width: maximum.width,
                height: maximum.width / pageAspectRatio
            )
        }
        return CGSize(
            width: maximum.height * pageAspectRatio,
            height: maximum.height
        )
    }

    private func displayedSignatureRect(pageSize: CGSize) -> CGRect {
        let scaledWidth = signatureBounds.width * placementScale
        let scaledHeight = signatureBounds.height * placementScale
        let centerX = signatureBounds.x + signatureBounds.width / 2
        let centerY = signatureBounds.y + signatureBounds.height / 2
        return CGRect(
            x: (
                centerX - scaledWidth / 2
                    + placementTranslation.width / pageSize.width
            ) * pageSize.width,
            y: (
                centerY - scaledHeight / 2
                    + placementTranslation.height / pageSize.height
            ) * pageSize.height,
            width: scaledWidth * pageSize.width,
            height: scaledHeight * pageSize.height
        )
    }

    private static func initialPlacement(
        from requested: PDFNormalizedRect?
    ) -> PDFNormalizedRect {
        guard let requested else {
            return PDFNormalizedRect(
                x: 0.57,
                y: 0.78,
                width: 0.36,
                height: 0.12
            )
        }
        let width = min(max(requested.width, 0.18), 0.72)
        let height = min(max(requested.height, 0.05), 0.28)
        let centerX = requested.x + requested.width / 2
        let centerY = requested.y + requested.height / 2
        return PDFNormalizedRect(
            x: min(max(centerX - width / 2, 0), 1 - width),
            y: min(max(centerY - height / 2, 0), 1 - height),
            width: width,
            height: height
        )
    }

    private func moveSignature(by translation: CGSize, pageSize: CGSize) {
        var x = signatureBounds.x + translation.width / pageSize.width
        var y = signatureBounds.y + translation.height / pageSize.height
        if snapsToMargins {
            x = snapped(
                x,
                candidates: [
                    0.035,
                    0.5 - signatureBounds.width / 2,
                    0.965 - signatureBounds.width
                ]
            )
            y = snapped(
                y,
                candidates: [
                    0.035,
                    0.5 - signatureBounds.height / 2,
                    0.965 - signatureBounds.height
                ]
            )
        }
        signatureBounds = PDFNormalizedRect(
            x: min(max(0, x), 1 - signatureBounds.width),
            y: min(max(0, y), 1 - signatureBounds.height),
            width: signatureBounds.width,
            height: signatureBounds.height
        )
    }

    private func nudgeSignature(x: Double, y: Double) {
        signatureBounds = PDFNormalizedRect(
            x: min(
                max(0, signatureBounds.x + x),
                1 - signatureBounds.width
            ),
            y: min(
                max(0, signatureBounds.y + y),
                1 - signatureBounds.height
            ),
            width: signatureBounds.width,
            height: signatureBounds.height
        )
    }

    private func scaleSignature(by scale: CGFloat) {
        resizeSignature(to: signatureBounds.width * scale)
    }

    private func resizeSignature(to width: Double) {
        let safeWidth = min(max(width, 0.18), 0.72)
        let calculatedHeight = safeWidth
            * pageAspectRatio
            / signatureDrawingAspectRatio
        let safeHeight = min(max(calculatedHeight, 0.05), 0.28)
        let centerX = signatureBounds.x + signatureBounds.width / 2
        let centerY = signatureBounds.y + signatureBounds.height / 2
        signatureBounds = PDFNormalizedRect(
            x: min(
                max(0, centerX - safeWidth / 2),
                1 - safeWidth
            ),
            y: min(
                max(0, centerY - safeHeight / 2),
                1 - safeHeight
            ),
            width: safeWidth,
            height: safeHeight
        )
    }

    private func snapped(
        _ value: Double,
        candidates: [Double]
    ) -> Double {
        candidates.first { abs($0 - value) <= 0.028 } ?? value
    }

    private func save(preparesDelivery: Bool = false) {
        guard !hasActiveInkTask, !didCommitInk else { return }
        guard let previewContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == previewContentRevisionID
        else {
            model[noticeFor: paperPathSceneID] =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            interruptProtectedInkWork()
            dismiss()
            return
        }
        guard isPagePreviewVerified,
              pagePreviewErrorMessage == nil,
              !isLoadingPagePreview,
              signatureLibraryTask == nil,
              !didCommitInk,
              canvasSize.width > 0,
              canvasSize.height > 0,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        let normalizationBounds: CGRect
        if mode == .signature {
            normalizationBounds = drawing.bounds.insetBy(dx: -8, dy: -8)
        } else {
            normalizationBounds = CGRect(origin: .zero, size: canvasSize)
        }
        guard normalizationBounds.width > 0,
              normalizationBounds.height > 0
        else { return }
        // Reject over-budget drawings before conversion; never save a prefix.
        guard !drawing.strokes.isEmpty else { return }
        guard drawing.strokes.count <= PDFInkPayload.maximumStrokeCount else {
            inkValidationMessage =
                "The drawing exceeds the safe stroke or point limit."
            return
        }
        var totalPointCount = 0
        for stroke in drawing.strokes {
            guard stroke.path.count >= 2 else {
                inkValidationMessage =
                    "A stroke cannot be exported completely. The PDF has not been changed."
                return
            }
            guard stroke.path.count <= PDFInkPayload.maximumPointsPerStroke,
                  stroke.path.count
                    <= PDFInkPayload.maximumTotalPointCount - totalPointCount
            else {
                inkValidationMessage =
                    "The drawing exceeds the safe stroke or point limit."
                return
            }
            totalPointCount += stroke.path.count
        }
        let strokes = drawing.strokes.map { stroke -> PDFInkStroke in
            let sampledPoints = Array(stroke.path)
            let points = sampledPoints.map { point in
                let location = point.location.applying(stroke.transform)
                return PDFInkPoint(
                    x: min(
                        max(
                            (
                                location.x
                                    - normalizationBounds.minX
                            ) / normalizationBounds.width,
                            0
                        ),
                        1
                    ),
                    y: min(
                        max(
                            (
                                location.y
                                    - normalizationBounds.minY
                            ) / normalizationBounds.height,
                            0
                        ),
                        1
                    )
                )
            }
            let transform = stroke.transform
            let widthScale = sqrt(abs(
                transform.a * transform.d - transform.b * transform.c
            ))
            let averageWidth = sampledPoints.reduce(0) {
                $0 + $1.size.width
            } / CGFloat(sampledPoints.count) * widthScale
            return PDFInkStroke(
                points: points,
                color: pdfInkColor(from: stroke.ink.color),
                normalizedLineWidth: min(
                    max(averageWidth / normalizationBounds.width, 0.0005),
                    0.08
                )
            )
        }
        guard !strokes.isEmpty else { return }

        let payload = PDFInkPayload(
            pageIndex: pageIndex,
            strokes: strokes,
            placement: mode == .signature ? .signature : .page,
            normalizedBounds: mode == .signature
                ? signatureBounds
                : nil
        )
        isSaving = true
        saveStopRequested = false
        didCommitInk = false
        let generation = UUID()
        operationGeneration = generation
        let savedSignatureData = mode == .signature && rememberSignature
            ? drawing.dataRepresentation()
            : nil
        operationTask = Task { @MainActor in
#if DEBUG
            // #region debug-point B:experience-presentations
            if let endpoint = ProcessInfo.processInfo.environment["DEBUG_SERVER_URL"], let url = URL(string: endpoint) { var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "experience-presentations", "runId": ProcessInfo.processInfo.environment["DEBUG_RUN_ID"] ?? "pre-fix", "hypothesisId": "B", "location": "InkCaptureView.save.begin", "msg": "[DEBUG] Ink save entered"]); URLSession.shared.dataTask(with: request).resume() }
            // #endregion
#endif
            let succeeded = await model.withFeedbackTarget(paperPathSceneID) {
                let saved = await model.addInk(
                    recordID: recordID,
                    payload: payload,
                    expectedContentRevisionID: previewContentRevisionID
                )
                if saved, let savedSignatureData, !Task.isCancelled {
                    await model.saveSignature(savedSignatureData)
                }
                return saved
            }
#if DEBUG
            // #region debug-point B:experience-presentations
            if let endpoint = ProcessInfo.processInfo.environment["DEBUG_SERVER_URL"], let url = URL(string: endpoint) { var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": "experience-presentations", "runId": ProcessInfo.processInfo.environment["DEBUG_RUN_ID"] ?? "pre-fix", "hypothesisId": "B", "location": "InkCaptureView.save.completed", "msg": "[DEBUG] Ink save returned", "data": ["success": succeeded, "current": operationGeneration == generation, "saving": isSaving, "cancelled": Task.isCancelled]]); URLSession.shared.dataTask(with: request).resume() }
            // #endregion
#endif
            guard operationGeneration == generation else { return }
            let wasStopped =
                saveStopRequested || Task.isCancelled
            didCommitInk = succeeded
            isSaving = false
            operationTask = nil
            saveStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    succeeded
                        ? "Ink update finished before stopping · changes kept"
                        : "Ink update stopped · working copy unchanged"
                ).localizedUI
                return
            }
            guard succeeded else { return }
            if preparesDelivery,
               model.record(id: recordID)?
                .taskCheckpoint?.stage == .verify {
                onPrepare()
            }
            dismiss()
        }
    }

    private func interruptProtectedInkWork() {
        stopSaving(invalidateResult: true)
        stopSignatureLibraryOperation()
        previewGeneration += 1
        pagePreviewImage = nil
        pagePreviewErrorMessage = nil
        isLoadingPagePreview = false
        isPagePreviewVerified = false
        previewContentRevisionID = nil
        signaturePreview = nil
    }

    private func stopSaving(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            operationGeneration = UUID()
            saveStopRequested = false
        } else {
            guard operationTask != nil,
                  !saveStopRequested
            else { return }
            saveStopRequested = true
        }
        operationTask?.cancel()
        if invalidateResult {
            operationTask = nil
            isSaving = false
        }
    }

    private var hasActiveInkTask: Bool {
        isSaving || signatureLibraryTask != nil
    }

    private var signatureAdvanceHint: String {
        if drawing.strokes.isEmpty {
            return "Draw or choose a signature first."
        }
        if isLoadingPagePreview {
            return "Wait for the page preview to finish loading."
        }
        if !isPagePreviewVerified {
            return "Retry the page preview before placing the signature."
        }
        if signatureLibraryTask != nil {
            return "Wait for the saved signature update to finish."
        }
        return "Shows the PDF so you can position and resize this signature"
    }

    private var signaturePlacementDisabledReason: String? {
        if didCommitInk {
            return "The ink update is already saved."
        }
        if drawing.strokes.isEmpty {
            return "Draw or choose a signature first."
        }
        if isLoadingPagePreview {
            return "Wait for the page preview to finish loading."
        }
        if !isPagePreviewVerified {
            return "Retry the page preview before placing the signature."
        }
        if signatureLibraryTask != nil {
            return "Wait for the saved signature update to finish."
        }
        if isSaving {
            return "Wait for the current operation to finish."
        }
        return nil
    }

    private var signaturePlacementSaveHint: String {
        signaturePlacementDisabledReason
            ?? "Places the signature on this working copy."
    }

    @discardableResult
    private func beginSignatureLibraryOperation(
        signatureID: UUID?
    ) -> UUID {
        signatureLibraryGeneration = UUID()
        signatureLibraryTask?.cancel()
        busySignatureID = signatureID
        return signatureLibraryGeneration
    }

    private func selectSavedSignature(_ id: UUID) {
        let generation = beginSignatureLibraryOperation(
            signatureID: id
        )
        signatureLibraryTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled,
                  signatureLibraryGeneration == generation
            else { return }
            await model.withFeedbackTarget(paperPathSceneID) {
                await model.selectSavedSignature(
                    id,
                    presentsFeedback: false
                )
            }
            guard !Task.isCancelled,
                  signatureLibraryGeneration == generation
            else { return }
            signatureLibraryTask = nil
            busySignatureID = nil
        }
    }

    private func removeSelectedSavedSignature() {
        guard let selectedID = selectedSignatureID,
              let entry = model.savedSignatures.first(
                where: { $0.id == selectedID }
              )
        else { return }
        removeSavedSignature(entry)
    }

    private func initializeSignatureSelectionIfNeeded() {
        guard mode == .signature,
              !didInitializeSignatureSelection
        else { return }
        didInitializeSignatureSelection = true
        let preferredID = model.selectedSignatureID
        selectedSignatureID = model.savedSignatures.contains {
            $0.id == preferredID
        } ? preferredID : model.savedSignatures.first?.id
    }

    private func clearActiveSignatureAfterRemoval() {
        drawing = PKDrawing()
        signaturePreview = nil
        if signatureStage == .placement {
            withAnimation(
                reduceMotion ? nil : .easeInOut(duration: 0.18)
            ) {
                signatureStage = .capture
            }
        }
    }

    private func stopSignatureLibraryOperation() {
        signatureLibraryGeneration = UUID()
        signatureLibraryTask?.cancel()
        signatureLibraryTask = nil
        busySignatureID = nil
    }

    private func stopActiveInkTask() {
        if isSaving {
            stopSaving()
        } else {
            stopSignatureLibraryOperation()
        }
    }

    private func pdfInkColor(from color: UIColor) -> PDFInkColor {
        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .light)
        )
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        if !resolved.getRed(
            &red,
            green: &green,
            blue: &blue,
            alpha: &alpha
        ) {
            var white: CGFloat = 0
            resolved.getWhite(&white, alpha: &alpha)
            red = white
            green = white
            blue = white
        }
        return PDFInkColor(
            red: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}

private struct PencilCanvasCommand: Equatable {
    enum Action: Equatable {
        case undo
        case redo
        case clear
        case insertShape(PencilShape, PDFInkColor, Double)
    }

    let id = UUID()
    let action: Action

    static func == (
        lhs: PencilCanvasCommand,
        rhs: PencilCanvasCommand
    ) -> Bool {
        lhs.id == rhs.id
    }
}

private struct PencilZoomCommand: Equatable {
    enum Action: Equatable {
        case fit
    }

    let id = UUID()
    let action: Action

    static func == (
        lhs: PencilZoomCommand,
        rhs: PencilZoomCommand
    ) -> Bool {
        lhs.id == rhs.id
    }
}

private final class PencilCanvasHostView: UIView {
    let canvas = PKCanvasView()
    var referenceSize: CGSize?
    var onLayout: ((PKCanvasView) -> Void)?
    private var initialSize: CGSize?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        addSubview(canvas)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if initialSize == nil {
            initialSize = bounds.size
        }
        let logicalSize = referenceSize ?? initialSize ?? bounds.size
        guard logicalSize.width > 0, logicalSize.height > 0 else { return }
        // Window resizing changes the viewport, never the saved stroke coordinates.
        let scale = min(bounds.width / logicalSize.width, bounds.height / logicalSize.height)
        canvas.bounds.size = logicalSize
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
        canvas.transform = CGAffineTransform(scaleX: scale, y: scale)
        onLayout?(canvas)
    }
}

private struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var canvasSize: CGSize
    let tool: PKTool
    var backgroundImage: UIImage?
    var referenceSize: CGSize?
    var drawingPolicy: PKCanvasViewDrawingPolicy = .anyInput
    var allowsViewportGestures = false
    var command: PencilCanvasCommand?
    var zoomCommand: PencilZoomCommand?
    var onHardwareShortcut: (PencilHardwareShortcut) -> Void = { _ in }
    var onHistoryChange: (Bool, Bool) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            drawing: $drawing,
            canvasSize: $canvasSize,
            onHardwareShortcut: onHardwareShortcut,
            onHistoryChange: onHistoryChange
        )
    }

    func makeUIView(context: Context) -> PencilCanvasHostView {
        let host = PencilCanvasHostView()
        host.referenceSize = referenceSize
        let canvas = host.canvas
        context.coordinator.canvas = canvas
        host.onLayout = { [weak coordinator = context.coordinator] canvas in
            coordinator?.layoutCanvas(canvas)
        }
        canvas.delegate = context.coordinator
        canvas.drawingPolicy = drawingPolicy
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.alwaysBounceVertical = false
        canvas.alwaysBounceHorizontal = false
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 5
        canvas.bouncesZoom = true
        canvas.showsVerticalScrollIndicator = true
        canvas.showsHorizontalScrollIndicator = true
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.isAccessibilityElement = true
        canvas.accessibilityLabel = "Drawing canvas".localizedUI
        canvas.accessibilityHint = canvasAccessibilityHint
        canvas.tool = tool
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .white
        imageView.isUserInteractionEnabled = false
        canvas.insertSubview(imageView, at: 0)
        context.coordinator.backgroundImageView = imageView
        let pencilInteraction: UIPencilInteraction
        if #available(iOS 17.5, *) {
            pencilInteraction = UIPencilInteraction(
                delegate: context.coordinator
            )
        } else {
            pencilInteraction = UIPencilInteraction()
            pencilInteraction.delegate = context.coordinator
        }
        canvas.addInteraction(pencilInteraction)
        context.coordinator.pencilInteraction = pencilInteraction
        return host
    }

    func updateUIView(_ host: PencilCanvasHostView, context: Context) {
        host.referenceSize = referenceSize
        host.setNeedsLayout()
        let canvas = host.canvas
        context.coordinator.onHistoryChange = onHistoryChange
        context.coordinator.onHardwareShortcut = onHardwareShortcut
        if canvas.drawing != drawing {
            canvas.drawing = drawing
        }
        canvas.tool = tool
        canvas.drawingPolicy = allowsViewportGestures
            ? .pencilOnly
            : drawingPolicy
        canvas.isScrollEnabled = allowsViewportGestures
        canvas.panGestureRecognizer.isEnabled = allowsViewportGestures
        canvas.pinchGestureRecognizer?.isEnabled = allowsViewportGestures
        canvas.drawingGestureRecognizer.isEnabled = !allowsViewportGestures
        canvas.accessibilityHint = canvasAccessibilityHint
        canvas.minimumZoomScale = 1
        canvas.maximumZoomScale = 5
        if canvas.zoomScale < canvas.minimumZoomScale {
            canvas.zoomScale = canvas.minimumZoomScale
        }
        let logicalContentSize = canvas.bounds.size
        if logicalContentSize.width > 0,
           logicalContentSize.height > 0,
           context.coordinator.logicalContentSize != logicalContentSize {
            context.coordinator.logicalContentSize = logicalContentSize
            canvas.contentSize = logicalContentSize
        }
        context.coordinator.backgroundImageView?.frame = CGRect(
            origin: .zero,
            size: context.coordinator.logicalContentSize == .zero
                ? canvas.bounds.size
                : context.coordinator.logicalContentSize
        )
        context.coordinator.backgroundImageView?.image = backgroundImage
        if let imageView = context.coordinator.backgroundImageView {
            canvas.sendSubviewToBack(imageView)
        }
        if let command,
           context.coordinator.commandID != command.id {
            context.coordinator.commandID = command.id
            switch command.action {
            case .undo:
                canvas.undoManager?.undo()
            case .redo:
                canvas.undoManager?.redo()
            case .clear:
                context.coordinator.replaceDrawing(
                    with: PKDrawing(),
                    in: canvas
                )
            case .insertShape(let shape, let color, let widthScale):
                context.coordinator.insert(
                    shape,
                    color: color,
                    widthScale: widthScale,
                    in: canvas
                )
            }
            context.coordinator.synchronize(from: canvas)
        }
        if let zoomCommand,
           context.coordinator.zoomCommandID != zoomCommand.id {
            context.coordinator.zoomCommandID = zoomCommand.id
            switch zoomCommand.action {
            case .fit:
                canvas.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled)
                canvas.setContentOffset(.zero, animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
        context.coordinator.scheduleStateReport(from: canvas)
    }

    private var canvasAccessibilityHint: String {
        if allowsViewportGestures {
            return "Use one finger to move the page and two fingers to zoom."
                .localizedUI
        }
        if drawingPolicy == .pencilOnly {
            return "Draw with Apple Pencil. Touch gestures do not create ink."
                .localizedUI
        }
        return "Draw with Apple Pencil or one finger".localizedUI
    }

    static func dismantleUIView(
        _ host: PencilCanvasHostView,
        coordinator: Coordinator
    ) {
        let canvas = host.canvas
        host.onLayout = nil
        coordinator.cancelPendingStateReport()
        canvas.delegate = nil
        canvas.accessibilityCustomActions = nil
        coordinator.canvas = nil
        if let pencilInteraction = coordinator.pencilInteraction {
            canvas.removeInteraction(pencilInteraction)
        }
        coordinator.pencilInteraction = nil
        coordinator.backgroundImageView?.removeFromSuperview()
        coordinator.backgroundImageView = nil
    }

    final class Coordinator:
        NSObject,
        PKCanvasViewDelegate,
        UIPencilInteractionDelegate {
        @Binding var drawing: PKDrawing
        @Binding var canvasSize: CGSize
        var commandID: UUID?
        var zoomCommandID: UUID?
        var logicalContentSize: CGSize = .zero
        weak var backgroundImageView: UIImageView?
        weak var canvas: PKCanvasView?
        var pencilInteraction: UIPencilInteraction?
        var onHardwareShortcut: (PencilHardwareShortcut) -> Void
        var onHistoryChange: (Bool, Bool) -> Void
        private var stateReportTask: Task<Void, Never>?

        init(
            drawing: Binding<PKDrawing>,
            canvasSize: Binding<CGSize>,
            onHardwareShortcut:
                @escaping (PencilHardwareShortcut) -> Void,
            onHistoryChange: @escaping (Bool, Bool) -> Void
        ) {
            _drawing = drawing
            _canvasSize = canvasSize
            self.onHardwareShortcut = onHardwareShortcut
            self.onHistoryChange = onHistoryChange
        }

        deinit {
            stateReportTask?.cancel()
        }

        func scheduleStateReport(from canvas: PKCanvasView) {
            stateReportTask?.cancel()
            stateReportTask = Task { @MainActor [weak self, weak canvas] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      let canvas
                else { return }
                stateReportTask = nil
                canvasSize = canvas.bounds.size
                reportHistory(from: canvas)
            }
        }

        func cancelPendingStateReport() {
            stateReportTask?.cancel()
            stateReportTask = nil
        }

        func layoutCanvas(_ canvas: PKCanvasView) {
            if logicalContentSize != canvas.bounds.size {
                logicalContentSize = canvas.bounds.size
                canvas.contentSize = logicalContentSize
                backgroundImageView?.frame = CGRect(origin: .zero, size: logicalContentSize)
            }
            scheduleStateReport(from: canvas)
        }

        @objc private func accessibilityUndo(_ action: UIAccessibilityCustomAction) -> Bool {
            guard let canvas, canvas.undoManager?.canUndo == true else { return false }
            canvas.undoManager?.undo()
            synchronize(from: canvas)
            return true
        }

        @objc private func accessibilityRedo(_ action: UIAccessibilityCustomAction) -> Bool {
            guard let canvas, canvas.undoManager?.canRedo == true else { return false }
            canvas.undoManager?.redo()
            synchronize(from: canvas)
            return true
        }

        @objc private func accessibilityFit(_ action: UIAccessibilityCustomAction) -> Bool {
            guard let canvas else { return false }
            canvas.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled)
            canvas.setContentOffset(.zero, animated: !UIAccessibility.isReduceMotionEnabled)
            return true
        }

        @objc private func accessibilityTools(_ action: UIAccessibilityCustomAction) -> Bool {
            onHardwareShortcut(.showContextualPalette)
            return true
        }

        func pencilInteractionDidTap(
            _ interaction: UIPencilInteraction
        ) {
            handlePreferredTapAction()
        }

        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveTap tap: UIPencilInteraction.Tap
        ) {
            handlePreferredTapAction()
        }

        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            guard squeeze.phase == .ended else { return }
            switch UIPencilInteraction.preferredSqueezeAction {
            case .switchEraser:
                onHardwareShortcut(.switchEraser)
            case .switchPrevious:
                onHardwareShortcut(.switchPrevious)
            case .ignore, .runSystemShortcut:
                break
            case .showColorPalette, .showInkAttributes,
                 .showContextualPalette:
                onHardwareShortcut(.showContextualPalette)
            @unknown default:
                onHardwareShortcut(.showContextualPalette)
            }
        }

        private func handlePreferredTapAction() {
            if #available(iOS 17.5, *) {
                switch UIPencilInteraction.preferredTapAction {
                case .switchEraser:
                    onHardwareShortcut(.switchEraser)
                case .switchPrevious:
                    onHardwareShortcut(.switchPrevious)
                case .showColorPalette, .showInkAttributes,
                     .showContextualPalette:
                    onHardwareShortcut(.showContextualPalette)
                case .ignore, .runSystemShortcut:
                    break
                @unknown default:
                    break
                }
            } else {
                switch UIPencilInteraction.preferredTapAction {
                case .switchEraser:
                    onHardwareShortcut(.switchEraser)
                case .switchPrevious:
                    onHardwareShortcut(.switchPrevious)
                case .showColorPalette, .showInkAttributes:
                    onHardwareShortcut(.showContextualPalette)
                case .ignore:
                    break
                default:
                    break
                }
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            synchronize(from: canvasView)
        }

        func synchronize(from canvasView: PKCanvasView) {
            drawing = canvasView.drawing
            canvasSize = canvasView.bounds.size
            reportHistory(from: canvasView)
        }

        func reportHistory(from canvasView: PKCanvasView) {
            canvasView.accessibilityValue = AppLocalization.format(
                "%lld strokes", canvasView.drawing.strokes.count
            )
            var actions: [UIAccessibilityCustomAction] = []
            if canvasView.undoManager?.canUndo == true {
                actions.append(UIAccessibilityCustomAction(
                    name: "Undo stroke".localizedUI, target: self,
                    selector: #selector(accessibilityUndo(_:))
                ))
            }
            if canvasView.undoManager?.canRedo == true {
                actions.append(UIAccessibilityCustomAction(
                    name: "Redo stroke".localizedUI, target: self,
                    selector: #selector(accessibilityRedo(_:))
                ))
            }
            actions.append(UIAccessibilityCustomAction(
                name: "Fit page".localizedUI, target: self,
                selector: #selector(accessibilityFit(_:))
            ))
            actions.append(UIAccessibilityCustomAction(
                name: "Pencil controls".localizedUI, target: self,
                selector: #selector(accessibilityTools(_:))
            ))
            canvasView.accessibilityCustomActions = actions
            onHistoryChange(
                canvasView.undoManager?.canUndo == true,
                canvasView.undoManager?.canRedo == true
            )
        }

        func insert(
            _ shape: PencilShape,
            color: PDFInkColor,
            widthScale: Double,
            in canvas: PKCanvasView
        ) {
            guard canvas.bounds.width > 0,
                  canvas.bounds.height > 0
            else { return }
            let strokeColor = UIColor(
                red: color.red,
                green: color.green,
                blue: color.blue,
                alpha: color.alpha
            )
            let lineWidth = CGFloat(3.2 * widthScale)
            let rect = canvas.bounds.insetBy(
                dx: canvas.bounds.width * 0.24,
                dy: canvas.bounds.height * 0.36
            )
            let paths = shapePaths(shape, in: rect)
            let ink = PKInk(.pen, color: strokeColor)
            let newStrokes = paths.compactMap {
                stroke(
                    points: $0,
                    ink: ink,
                    lineWidth: lineWidth
                )
            }
            guard !newStrokes.isEmpty else { return }
            replaceDrawing(
                with: PKDrawing(
                    strokes: canvas.drawing.strokes + newStrokes
                ),
                in: canvas
            )
        }

        func replaceDrawing(
            with replacement: PKDrawing,
            in canvas: PKCanvasView
        ) {
            let previous = canvas.drawing
            guard previous != replacement else { return }
            canvas.undoManager?.registerUndo(
                withTarget: self
            ) { [weak canvas] coordinator in
                guard let canvas else { return }
                coordinator.replaceDrawing(
                    with: previous,
                    in: canvas
                )
            }
            canvas.drawing = replacement
            synchronize(from: canvas)
        }

        private func shapePaths(
            _ shape: PencilShape,
            in rect: CGRect
        ) -> [[CGPoint]] {
            switch shape {
            case .line:
                return [[
                    CGPoint(x: rect.minX, y: rect.midY),
                    CGPoint(x: rect.maxX, y: rect.midY)
                ]]
            case .rectangle:
                let topLeft = CGPoint(x: rect.minX, y: rect.minY)
                let topRight = CGPoint(x: rect.maxX, y: rect.minY)
                let bottomRight = CGPoint(
                    x: rect.maxX,
                    y: rect.maxY
                )
                let bottomLeft = CGPoint(
                    x: rect.minX,
                    y: rect.maxY
                )
                return [
                    [topLeft, topRight],
                    [topRight, bottomRight],
                    [bottomRight, bottomLeft],
                    [bottomLeft, topLeft]
                ]
            case .ellipse:
                return [
                    (0...48).map { index in
                        let angle = CGFloat(index) / 48 * .pi * 2
                        return CGPoint(
                            x: rect.midX + cos(angle) * rect.width / 2,
                            y: rect.midY + sin(angle) * rect.height / 2
                        )
                    }
                ]
            case .arrow:
                let head = min(rect.width, rect.height) * 0.24
                return [
                    [
                        CGPoint(x: rect.minX, y: rect.midY),
                        CGPoint(x: rect.maxX, y: rect.midY)
                    ],
                    [
                        CGPoint(
                            x: rect.maxX - head,
                            y: rect.midY - head
                        ),
                        CGPoint(x: rect.maxX, y: rect.midY),
                        CGPoint(
                            x: rect.maxX - head,
                            y: rect.midY + head
                        )
                    ]
                ]
            }
        }

        private func stroke(
            points: [CGPoint],
            ink: PKInk,
            lineWidth: CGFloat
        ) -> PKStroke? {
            guard points.count > 1 else { return nil }
            let controlPoints = points.enumerated().map { index, point in
                PKStrokePoint(
                    location: point,
                    timeOffset: TimeInterval(index) * 0.01,
                    size: CGSize(width: lineWidth, height: lineWidth),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                )
            }
            return PKStroke(
                ink: ink,
                path: PKStrokePath(
                    controlPoints: controlPoints,
                    creationDate: Date()
                )
            )
        }
    }
}
