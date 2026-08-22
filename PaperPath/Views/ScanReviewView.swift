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
        case .createPDF: return "Review captured pages"
        case .replacePage: return "Review replacement scan"
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
        case .createPDF: return "Save PDF"
        case .replacePage: return "Use Scanned Pages"
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

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let images: [UIImage]
    let purpose: ScanReviewPurpose
    let onSave: ([ScanPageImage]) -> Void

    @State private var workingImages: [UIImage]
    @State private var pageOptions: [ScanProcessingOptions]
    @State private var preview: UIImage?
    @State private var detectedDocument = false
    @State private var detectedCropQuad: ScanCropQuad?
    @State private var pageIndex = 0
    @State private var pageRevision = 0
    @State private var previewMode = PreviewMode.processed
    @State private var isPreparingPreview = false
    @State private var applyAllFeedback = 0
    @State private var toneResetFeedback = 0
    @State private var isSelectingPages = false
    @State private var selectedPageIndices: Set<Int> = []
    @State private var isConfirmingSelectedPageRemoval = false
    @State private var isEditingManualCrop = false
    @State private var manualCropDraft = ScanCropQuad.fullFrame
    @State private var cropPreviousPreviewMode = PreviewMode.processed
    @State private var cropAppliedFeedback = 0

    init(
        images: [UIImage],
        initialOptions: ScanProcessingOptions = .document,
        purpose: ScanReviewPurpose = .createPDF,
        onSave: @escaping ([ScanPageImage]) -> Void
    ) {
        self.images = images
        self.purpose = purpose
        self.onSave = onSave
        _workingImages = State(initialValue: images)
        _pageOptions = State(
            initialValue: Array(
                repeating: initialOptions,
                count: images.count
            )
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                scanHeader
                    .padding(.horizontal, PPSpacing.regular)
                    .padding(.top, PPSpacing.small)
                if workingImages.isEmpty {
                    emptyScanState
                } else {
                    previewStage
                    if isEditingManualCrop {
                        cropEditingBar
                    } else {
                        pageQueue
                        controls
                    }
                }
            }
            .background(PPColor.canvas)
            .navigationTitle(purpose.title.localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        isEditingManualCrop
                            ? "Cancel Crop"
                            : "Cancel"
                    ) {
                        if isEditingManualCrop {
                            cancelManualCrop()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(purpose.actionTitle.localizedUI) {
                        dismiss()
                        saveReviewedPages()
                    }
                    .disabled(
                        workingImages.isEmpty
                            || isEditingManualCrop
                    )
                }
            }
            .task(id: previewTaskID) {
                await updatePreview()
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
            .sensoryFeedback(.success, trigger: applyAllFeedback)
            .sensoryFeedback(.impact(weight: .light), trigger: toneResetFeedback)
            .sensoryFeedback(.success, trigger: cropAppliedFeedback)
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
            .interactiveDismissDisabled(isEditingManualCrop)
        }
    }

    private var scanHeader: some View {
        WorkflowCommandHeader(
            eyebrow: purpose.eyebrow,
            title: purpose.title,
            detail: purpose.detail,
            symbol: "viewfinder",
            tint: PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(workingImages.count)",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: isSelectingPages
                        ? "\(selectedPageIndices.count)"
                        : workingImages.isEmpty
                            ? "0"
                            : "\(pageIndex + 1)",
                    label: isSelectingPages ? "Selected" : "Current",
                    symbol: isSelectingPages
                        ? "checkmark.circle"
                        : "rectangle.on.rectangle",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value:
                        isEditingManualCrop
                            ? "Editing"
                            : currentOptions.manualCrop != nil
                            ? "Manual"
                            : detectedDocument
                                ? "Detected"
                                : "Full frame",
                    label: "Edges",
                    symbol:
                        isEditingManualCrop
                            || currentOptions.manualCrop != nil
                            ? "crop"
                            : "viewfinder",
                    tint:
                        isEditingManualCrop
                            || currentOptions.manualCrop != nil
                            || detectedDocument
                            ? PPColor.mint
                            : PPColor.amber
                ),
                WorkflowMetric(
                    value: currentOptions.enhancement.title,
                    label: "Mode",
                    symbol: currentOptions.enhancement.symbol,
                    tint: PPColor.mint
                )
            ]
        )
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

    private var previewTaskID: String {
        [
            currentOptions.enhancement.rawValue,
            currentOptions.autoCrop ? "crop" : "full",
            currentOptions.removeShadows ? "light" : "natural",
            currentOptions.cleanEdges ? "clean" : "edges",
            String(
                Int((currentOptions.brightness * 100).rounded())
            ),
            String(
                Int((currentOptions.contrast * 100).rounded())
            ),
            currentOptions.manualCrop?.cacheKey ?? "automatic",
            isEditingManualCrop ? "editing-crop" : "reviewing",
            previewMode.rawValue,
            String(pageIndex),
            String(pageRevision)
        ].joined(separator: "-")
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
                } else {
                    ProgressView()
                }

                if isEditingManualCrop,
                   workingImages.indices.contains(pageIndex) {
                    ScanManualCropOverlay(
                        quad: $manualCropDraft,
                        imageSize: workingImages[pageIndex].size,
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
            .overlay(alignment: .bottomTrailing) {
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
                }
            }
            .frame(
                minHeight: max(
                    210,
                    proxy.size.height
                )
            )
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
    }

    private var cropCancelButton: some View {
        Button {
            cancelManualCrop()
        } label: {
            Label("Cancel", systemImage: "xmark")
        }
        .buttonStyle(PPQuietButtonStyle())
    }

    private var cropApplyButton: some View {
        Button {
            applyManualCrop()
        } label: {
            Label("Apply Crop", systemImage: "checkmark")
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(!manualCropDraft.isValid)
    }

    private var pageQueue: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
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
            HStack(spacing: 6) {
                ForEach(
                    Array(workingImages.enumerated()),
                    id: \.offset
                ) { index, image in
                    Button {
                        handlePageTap(index)
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 42, height: 52)
                                .clipped()
                            Text("\(index + 1)")
                                .font(.caption2.weight(.bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .background(
                                    index == pageIndex
                                        ? PPColor.accent
                                        : Color.black.opacity(0.58)
                                )
                        }
                        .overlay(alignment: .topTrailing) {
                            if isSelectingPages {
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
                    .buttonStyle(.plain)
                    .accessibilityLabel("Scanned page \(index + 1)")
                    .accessibilityValue(
                        selectedPageIndices.contains(index)
                            ? "Selected"
                            : ""
                    )
                    .accessibilityHint(
                        isSelectingPages
                            ? "Toggles page selection"
                            : "Shows this scanned page"
                    )
                }
            }
        }
    }

    private var pageActionStrip: some View {
        HStack(spacing: 4) {
            if isSelectingPages {
                pageAction(
                    selectedPageIndices.count == workingImages.count
                        ? "Clear Selection"
                        : "Select All",
                    symbol: selectedPageIndices.count == workingImages.count
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
    }

    @ViewBuilder
    private var controls: some View {
        if dynamicTypeSize.isAccessibilitySize {
            ScrollView(.vertical, showsIndicators: false) {
                controlPanel
            }
            .frame(maxHeight: 300)
        } else {
            controlPanel
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 0) {
            previewModeControl

            Rectangle()
                .fill(PPColor.border.opacity(0.65))
                .frame(height: 0.6)

            pageAdjustmentScope

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: PPSpacing.small) {
                    ForEach(ScanEnhancement.allCases) { option in
                        enhancementButton(option)
                    }
                }
                .padding(.horizontal, PPSpacing.regular)
                .padding(.vertical, PPSpacing.small)
            }

            Rectangle()
                .fill(PPColor.border.opacity(0.65))
                .frame(height: 0.6)

            toneControls

            Rectangle()
                .fill(PPColor.border.opacity(0.65))
                .frame(height: 0.6)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.regular) {
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

                VStack(alignment: .leading, spacing: PPSpacing.small) {
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
            }
            .padding(.horizontal, PPSpacing.regular)
            .padding(.bottom, PPSpacing.small)
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
            if dynamicTypeSize.isAccessibilitySize {
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

    private var pageAdjustmentScope: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                ) {
                    pageAdjustmentIdentity
                    pageAdjustmentActions
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    pageAdjustmentIdentity
                    Spacer(minLength: PPSpacing.small)
                    pageAdjustmentActions
                }
            }
        }
        .padding(.horizontal, PPSpacing.regular)
    }

    private var pageAdjustmentIdentity: some View {
        Label(
            isSelectingPages
                ? AppLocalization.format(
                    "%lld pages selected",
                    selectedPageIndices.count
                )
                : AppLocalization.format(
                    "Page %lld adjustments",
                    pageIndex + 1
                ),
            systemImage: isSelectingPages
                ? "checkmark.circle"
                : "slider.horizontal.3"
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textPrimary)
    }

    private var pageAdjustmentActions: some View {
        HStack(spacing: PPSpacing.medium) {
            if workingImages.count > 1,
               !isSelectingPages || !selectedPageIndices.isEmpty {
                Button(
                    isSelectingPages
                        ? "Copy to Selected"
                        : "Apply to All"
                ) {
                    applyCurrentOptionsToScope()
                }
                .foregroundStyle(PPColor.cyan)
            }

            if workingImages.count > 1 {
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
            }
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.plain)
        .frame(minHeight: 44)
    }

    private func enhancementButton(
        _ option: ScanEnhancement
    ) -> some View {
        Button {
            updateCurrentOptions {
                $0.enhancement = option
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: option.symbol)
                    .font(.caption.weight(.semibold))
                Text(option.title.localizedUI)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(
                currentOptions.enhancement == option
                    ? Color.white
                    : PPColor.textPrimary
            )
            .padding(.horizontal, PPSpacing.small)
            .frame(minHeight: 36)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
            )
            .tint(PPColor.cyan)
            .accessibilityLabel(title.localizedUI)
            .accessibilityValue(displayValue)
        }
        .frame(minWidth: 120, maxWidth: .infinity)
    }

    private var resetToneButton: some View {
        Button {
            updateCurrentOptions {
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
        let requestID = previewTaskID
        guard workingImages.indices.contains(pageIndex) else {
            preview = nil
            detectedDocument = false
            detectedCropQuad = nil
            isPreparingPreview = false
            return
        }
        guard previewMode == .processed else {
            preview = nil
            detectedDocument = false
            isPreparingPreview = false
            return
        }
        isPreparingPreview = true
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled,
              requestID == previewTaskID
        else { return }
        preview = nil
        detectedDocument = false
        detectedCropQuad = nil
        let page = ScanPageImage(image: workingImages[pageIndex])
        let selectedOptions = currentOptions
        let selectedPage = pageIndex
        let selectedRevision = pageRevision
        let renderer = ScanPDFRenderer()
        let worker = Task.detached(priority: .userInitiated) {
            renderer.preview(
                image: page.image,
                options: selectedOptions
            )
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled,
              requestID == previewTaskID,
              selectedPage == pageIndex,
              selectedRevision == pageRevision,
              selectedOptions == currentOptions
        else {
            return
        }
        preview = result.image
        detectedDocument = result.detectedDocument
        detectedCropQuad = result.cropQuad
        isPreparingPreview = false
    }

    private func moveCurrentPage(by offset: Int) {
        let destination = pageIndex + offset
        guard workingImages.indices.contains(pageIndex),
              workingImages.indices.contains(destination)
        else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            workingImages.swapAt(pageIndex, destination)
            pageOptions.swapAt(pageIndex, destination)
            pageIndex = destination
            pageRevision += 1
            preview = nil
            detectedCropQuad = nil
        }
    }

    private func removeCurrentPage() {
        guard workingImages.count > 1,
              workingImages.indices.contains(pageIndex)
        else { return }
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            workingImages.remove(at: pageIndex)
            pageOptions.remove(at: pageIndex)
            pageIndex = min(
                pageIndex,
                workingImages.count - 1
            )
            pageRevision += 1
            preview = nil
            detectedCropQuad = nil
        }
    }

    private func rotateCurrentPage() {
        guard workingImages.indices.contains(pageIndex),
              let rotated = rotatedImage(
                workingImages[pageIndex]
              )
        else { return }
        workingImages[pageIndex] = rotated
        pageOptions[pageIndex].manualCrop =
            pageOptions[pageIndex].manualCrop?.rotatedClockwise
        pageRevision += 1
        preview = nil
        detectedCropQuad = nil
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
                updateCurrentOptions {
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
                updateCurrentOptions {
                    $0[keyPath: keyPath] = value
                }
            }
        )
    }

    private func updateCurrentOptions(
        _ update: (inout ScanProcessingOptions) -> Void
    ) {
        guard pageOptions.indices.contains(pageIndex) else { return }
        update(&pageOptions[pageIndex])
    }

    private func applyCurrentOptionsToScope() {
        guard !pageOptions.isEmpty else { return }
        let options = currentOptions
        if isSelectingPages {
            for index in selectedPageIndices
            where pageOptions.indices.contains(index) {
                pageOptions[index] = transferableOptions(
                    options,
                    to: index
                )
            }
        } else {
            for index in pageOptions.indices {
                pageOptions[index] = transferableOptions(
                    options,
                    to: index
                )
            }
        }
        applyAllFeedback += 1
    }

    private func handlePageTap(_ index: Int) {
        guard workingImages.indices.contains(index) else { return }
        if index != pageIndex {
            detectedCropQuad = nil
        }
        pageIndex = index
        preview = nil
        if isSelectingPages {
            if selectedPageIndices.contains(index) {
                selectedPageIndices.remove(index)
            } else {
                selectedPageIndices.insert(index)
            }
        }
    }

    private func togglePageSelectionMode() {
        if isSelectingPages {
            isSelectingPages = false
            selectedPageIndices.removeAll()
        } else {
            isSelectingPages = true
            selectedPageIndices = [pageIndex]
        }
    }

    private func toggleAllPages() {
        if selectedPageIndices.count == workingImages.count {
            selectedPageIndices.removeAll()
        } else {
            selectedPageIndices = Set(workingImages.indices)
        }
    }

    private func rotateSelectedPages() {
        guard !selectedPageIndices.isEmpty else { return }
        for index in selectedPageIndices.sorted()
        where workingImages.indices.contains(index) {
            if let rotated = rotatedImage(workingImages[index]) {
                workingImages[index] = rotated
                pageOptions[index].manualCrop =
                    pageOptions[index]
                        .manualCrop?
                        .rotatedClockwise
            }
        }
        pageRevision += 1
        preview = nil
        detectedCropQuad = nil
    }

    private func beginManualCrop() {
        guard workingImages.indices.contains(pageIndex) else { return }
        cropPreviousPreviewMode = previewMode
        manualCropDraft =
            currentOptions.manualCrop
                ?? detectedCropQuad
                ?? .fullFrame
        isSelectingPages = false
        selectedPageIndices.removeAll()
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
        guard manualCropDraft.isValid else { return }
        updateCurrentOptions {
            $0.manualCrop =
                manualCropDraft.isEffectivelyFullFrame
                    ? nil
                    : manualCropDraft
            $0.autoCrop = false
            if $0.manualCrop == nil {
                $0.cleanEdges = false
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
        to index: Int
    ) -> ScanProcessingOptions {
        guard pageOptions.indices.contains(index),
              source.manualCrop != nil,
              index != pageIndex
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
        let firstRemoved = selectedPageIndices.min() ?? pageIndex
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            for index in selectedPageIndices.sorted(by: >) {
                guard workingImages.indices.contains(index),
                      pageOptions.indices.contains(index)
                else { continue }
                workingImages.remove(at: index)
                pageOptions.remove(at: index)
            }
            pageIndex = min(
                firstRemoved,
                workingImages.count - 1
            )
            pageRevision += 1
            preview = nil
            selectedPageIndices.removeAll()
            isSelectingPages = false
        }
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

    private func signedPercent(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        if rounded > 0 {
            return "+\(rounded)%"
        }
        return "\(rounded)%"
    }

    private func saveReviewedPages() {
        guard workingImages.count == pageOptions.count else { return }
        onSave(
            zip(workingImages, pageOptions).map {
                ScanPageImage(
                    image: $0.0,
                    processingOptions: $0.1
                )
            }
        )
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
                named: Text("Move Left")
            ) {
                nudge(corner, dx: -0.02, dy: 0)
            }
            .accessibilityAction(
                named: Text("Move Right")
            ) {
                nudge(corner, dx: 0.02, dy: 0)
            }
            .accessibilityAction(
                named: Text("Move Up")
            ) {
                nudge(corner, dx: 0, dy: -0.02)
            }
            .accessibilityAction(
                named: Text("Move Down")
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
