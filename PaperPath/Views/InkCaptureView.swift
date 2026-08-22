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
        rawValue.capitalized
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

    private enum SignatureStage {
        case capture
        case placement

        var title: String {
            switch self {
            case .capture: return "Capture"
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
            rawValue.capitalized
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
            rawValue.capitalized
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let recordID: UUID
    let pageIndex: Int
    let mode: Mode
    let onPrepare: () -> Void
    @State private var drawing = PKDrawing()
    @State private var canvasSize: CGSize = .zero
    @State private var signaturePreview: UIImage?
    @State private var pencilPageImage: UIImage?
    @AppStorage("pencil.preset")
    private var savedPencilPreset = PencilPreset.pen.rawValue
    @AppStorage("pencil.color")
    private var savedPencilColor = PencilColor.blue.rawValue
    @AppStorage("pencil.width")
    private var pencilWidthScale = 1.0
    @AppStorage("pencil.input")
    private var savedPencilInputMode = PencilInputMode.anyInput.rawValue
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
    @GestureState private var placementTranslation = CGSize.zero
    @GestureState private var placementScale: CGFloat = 1

    private var pencilPreset: PencilPreset {
        PencilPreset(rawValue: savedPencilPreset) ?? .pen
    }

    private var pencilColor: PencilColor {
        PencilColor(rawValue: savedPencilColor) ?? .blue
    }

    private var pencilInputMode: PencilInputMode {
        PencilInputMode(rawValue: savedPencilInputMode) ?? .anyInput
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
                if mode == .drawing,
                   let url = model.url(for: recordID) {
                    pencilSurface(
                        url: url,
                        availableSize: proxy.size
                    )
                } else if signatureStage == .capture {
                    signatureCapture(
                        maxWidth: min(proxy.size.width - 48, 620)
                    )
                } else if let url = model.url(for: recordID) {
                    signaturePlacementSurface(
                        url: url,
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
                    Button((isSaving ? "Stop" : "Cancel").localizedUI) {
                        if isSaving {
                            operationTask?.cancel()
                            operationTask = nil
                            isSaving = false
                        } else {
                            dismiss()
                        }
                    }
                }
                if mode == .drawing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            save()
                        }
                        .disabled(
                            drawing.strokes.isEmpty
                                || canvasSize.width <= 0
                                || isSaving
                        )
                    }
                }
            }
            .task {
                guard let url = model.url(for: recordID)
                else { return }
                let preview = await PDFEditorPreviewLoader.shared.preview(
                    url: url,
                    pageIndex: pageIndex,
                    revision: model.refreshToken(for: recordID),
                    longEdge: 1_800
                )
                if mode == .signature,
                   let saved = selectedSavedSignatureDrawing() {
                    drawing = saved
                }
                if let preview, !Task.isCancelled {
                    pageAspectRatio = CGFloat(preview.aspectRatio)
                    if mode == .drawing {
                        pencilPageImage = preview.image
                    }
                }
            }
            .confirmationDialog(
                "Remove selected signature?",
                isPresented: $isConfirmingSavedSignatureRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove Selected Signature", role: .destructive) {
                    drawing = PKDrawing()
                    signaturePreview = nil
                    Task {
                        await model.saveSignature(nil)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("PDFs already signed with it will not change.")
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
            .interactiveDismissDisabled(isSaving)
            .onDisappear {
                operationTask?.cancel()
                operationTask = nil
            }
        }
    }

    private var precisionContextBar: some View {
        HStack(spacing: PPSpacing.medium) {
            Label(
                "Page \(pageIndex + 1)",
                systemImage: "doc.text"
            )
            Label(
                mode == .signature
                    ? signatureStage.title
                    : (
                        isPencilViewportMode
                            ? "Move & Zoom"
                            : pencilPreset.title
                    ),
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
                    pencilInputMode.title,
                    systemImage: "pencil.and.scribble"
                )
            } else {
                Label(
                    model.savedSignatures.isEmpty
                        ? "Not saved"
                        : "\(model.savedSignatures.count) saved",
                    systemImage: model.savedSignatures.isEmpty
                        ? "internaldrive"
                        : "checkmark.circle"
                )
            }
            Spacer(minLength: 0)
            OnDeviceBadge(compact: true)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        .lineLimit(1)
        .padding(.horizontal, PPSpacing.regular)
        .frame(minHeight: 38)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func pencilSurface(
        url: URL,
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
                backgroundImage: pencilPageImage,
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
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
            .overlay {
                if pencilPageImage == nil {
                    ProgressView()
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
                            .frame(width: 38, height: 38)
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
                                .frame(width: 38, height: 38)
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
                            .frame(width: 38, height: 38)
                    }
                    .accessibilityLabel("Insert shape")

                    Button {
                        pencilZoomCommand = PencilZoomCommand(action: .fit)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Fit page")

                    Button {
                        pencilCommand = PencilCanvasCommand(action: .undo)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 40, height: 38)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canUndoDrawing)
                    .accessibilityLabel("Undo stroke")

                    Button {
                        pencilCommand = PencilCanvasCommand(action: .redo)
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                            .frame(width: 40, height: 38)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canRedoDrawing)
                    .accessibilityLabel("Redo stroke")
                }
            }
            .scrollClipDisabled()

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
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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
                            .frame(width: 40, height: 38)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(color.title.localizedUI) ink"
                    )
                    .accessibilityAddTraits(
                        pencilColor == color ? .isSelected : []
                    )
                }

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
    }

    private var pencilInputAndClear: some View {
        HStack(spacing: PPSpacing.medium) {
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
            .pickerStyle(.segmented)

            Button(role: .destructive) {
                pencilCommand = PencilCanvasCommand(action: .clear)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 44, height: 38)
            }
            .buttonStyle(.plain)
            .disabled(drawing.strokes.isEmpty)
            .accessibilityLabel("Clear page drawing")
        }
    }

    private func insert(_ shape: PencilShape) {
        isPencilViewportMode = false
        selectPencilPreset(.lasso)
        model.noticeMessage = AppLocalization.format(
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
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(PPSpacing.regular)
        .background(.bar)
    }

    private var captureControls: some View {
        VStack(spacing: PPSpacing.small) {
            if !model.savedSignatures.isEmpty {
                savedSignatureRail
            }

            HStack {
                Toggle(
                    "Remember on this device",
                    isOn: $rememberSignature
                )
                .font(.subheadline)

                if !drawing.strokes.isEmpty {
                    Button {
                        drawing = PKDrawing()
                        signaturePreview = nil
                    } label: {
                        Label("Clear", systemImage: "eraser")
                    }
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(PPColor.textSecondary)
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
                    "Continue to Placement",
                    systemImage: "arrow.right"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(drawing.strokes.isEmpty)

            if !model.savedSignatures.isEmpty {
                Button("Remove Selected Signature") {
                    isConfirmingSavedSignatureRemoval = true
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
            }
        }
    }

    private var savedSignatureRail: some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            HStack(spacing: PPSpacing.small) {
                Label(
                    "Saved \(model.savedSignatures.count)/\(SignatureStore.maximumSignatureCount)",
                    systemImage: "signature"
                )
                Spacer(minLength: 0)
                if let selectedIndex = selectedSignatureIndex {
                    Text("#\(selectedIndex + 1)")
                        .monospacedDigit()
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
        guard let selectedID = model.selectedSignatureID else { return nil }
        return model.savedSignatures.firstIndex { $0.id == selectedID }
    }

    private func savedSignatureButton(
        _ entry: SavedSignature,
        index: Int
    ) -> some View {
        let isSelected = model.selectedSignatureID == entry.id
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Saved signature \(index + 1)")
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
            HStack(spacing: PPSpacing.medium) {
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

    private var placeOnlyButton: some View {
        Button {
            save()
        } label: {
            Label("Place Signature", systemImage: "signature")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPQuietButtonStyle())
        .disabled(
            drawing.strokes.isEmpty
                || canvasSize.width <= 0
                || isSaving
        )
        .accessibilityIdentifier("placeSignatureOnly")
    }

    private var prepareButton: some View {
        Button {
            save(preparesDelivery: true)
        } label: {
            Label(
                "Place & Verify",
                systemImage: "checkmark.shield"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            drawing.strokes.isEmpty
                || canvasSize.width <= 0
                || isSaving
        )
        .accessibilityHint(
            "Places the signature, then checks the final copy before sharing"
        )
        .accessibilityIdentifier("placeSignatureAndVerify")
    }

    private func signatureCapture(maxWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            Spacer()
            Text("Sign for page \(pageIndex + 1)")
                .font(.caption.smallCaps().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)

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
        url: URL,
        availableSize: CGSize
    ) -> some View {
        let pageSize = fittedPageSize(in: availableSize)
        return ZStack {
            PPColor.canvas

            ZStack {
                PDFPageThumbnailView(
                    url: url,
                    pageIndex: pageIndex,
                    refreshToken: model.refreshToken(for: recordID),
                    width: pageSize.width,
                    height: pageSize.height
                )

                signaturePlacementOverlay(pageSize: pageSize)
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Signature placement on page \(pageIndex + 1)"
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
            "\(Int(signatureBounds.width * 100)) percent page width"
        )
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.04 : -0.04
            resizeSignature(to: signatureBounds.width + delta)
        }
    }

    private func selectedSavedSignatureDrawing() -> PKDrawing? {
        guard let data = model.savedSignatureData else { return nil }
        return try? PKDrawing(data: data)
    }

    private func useSavedSignature(_ entry: SavedSignature) {
        guard let saved = try? PKDrawing(data: entry.data),
              !saved.strokes.isEmpty
        else { return }
        drawing = saved
        signaturePreview = makeSignatureImage(from: saved)
        rememberSignature = false
        Task {
            await model.selectSavedSignature(entry.id)
        }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            resizeSignature(to: signatureBounds.width)
            signatureStage = .placement
        }
    }

    private func removeSavedSignature(_ entry: SavedSignature) {
        let wasActive = model.selectedSignatureID == entry.id
        Task {
            await model.removeSavedSignature(entry.id)
        }
        guard wasActive else { return }
        drawing = PKDrawing()
        signaturePreview = nil
        if signatureStage == .placement {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                signatureStage = .capture
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
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let normalizationBounds: CGRect
        if mode == .signature {
            normalizationBounds = drawing.bounds.insetBy(dx: -8, dy: -8)
        } else {
            normalizationBounds = CGRect(origin: .zero, size: canvasSize)
        }
        guard normalizationBounds.width > 0,
              normalizationBounds.height > 0
        else { return }
        var remainingPointCount = 20_000
        let strokes = drawing.strokes.prefix(400).compactMap {
            stroke -> PDFInkStroke? in
            guard remainingPointCount > 1 else { return nil }
            let sampledPoints = Array(
                stroke.path.prefix(min(2_000, remainingPointCount))
            )
            let points = sampledPoints.map { point in
                PDFInkPoint(
                    x: min(
                        max(
                            (
                                point.location.x
                                    - normalizationBounds.minX
                            ) / normalizationBounds.width,
                            0
                        ),
                        1
                    ),
                    y: min(
                        max(
                            (
                                point.location.y
                                    - normalizationBounds.minY
                            ) / normalizationBounds.height,
                            0
                        ),
                        1
                    )
                )
            }
            remainingPointCount -= points.count
            guard points.count > 1 else { return nil }
            let averageWidth = sampledPoints.reduce(0) {
                $0 + $1.size.width
            } / CGFloat(sampledPoints.count)
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
        operationTask = Task {
            if mode == .signature, rememberSignature {
                await model.saveSignature(drawing.dataRepresentation())
            }
            let succeeded = await model.addInk(
                recordID: recordID,
                payload: payload
            )
            guard !Task.isCancelled else {
                isSaving = false
                operationTask = nil
                return
            }
            isSaving = false
            operationTask = nil
            guard succeeded else { return }
            dismiss()
            if succeeded,
               preparesDelivery,
               model.record(id: recordID)?
                .taskCheckpoint?.stage == .verify {
                onPrepare()
            }
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

private struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    @Binding var canvasSize: CGSize
    let tool: PKTool
    var backgroundImage: UIImage?
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

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
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
        canvas.accessibilityLabel = "Drawing canvas"
        canvas.accessibilityHint = "Draw with Apple Pencil or one finger"
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
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
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
                canvas.setZoomScale(1, animated: true)
                canvas.setContentOffset(.zero, animated: true)
            }
        }
        DispatchQueue.main.async {
            canvasSize = canvas.bounds.size
            context.coordinator.reportHistory(from: canvas)
        }
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
        var pencilInteraction: UIPencilInteraction?
        var onHardwareShortcut: (PencilHardwareShortcut) -> Void
        var onHistoryChange: (Bool, Bool) -> Void

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

        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveTap tap: UIPencilInteraction.Tap
        ) {
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
        }

        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            guard squeeze.phase == .began
                    || squeeze.phase == .ended
            else { return }
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

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            synchronize(from: canvasView)
        }

        func synchronize(from canvasView: PKCanvasView) {
            drawing = canvasView.drawing
            canvasSize = canvasView.bounds.size
            reportHistory(from: canvasView)
        }

        func reportHistory(from canvasView: PKCanvasView) {
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
