import PDFKit
import SwiftUI

struct PDFTextReplacementView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let selection: PDFTextSelectionSnapshot
    let onCreated: (DocumentRoute) -> Void

    @State private var replacement = ""
    @State private var fontStyle: PDFTextReplacementFontStyle = .sans
    @State private var alignment: PDFTextReplacementAlignment = .left
    @State private var assessment: PDFTextReplacementAssessment?
    @State private var pagePreviews: [Int: UIImage] = [:]
    @State private var pagePointSizes: [Int: CGSize] = [:]
    @State private var previewLoadingPageIndices: Set<Int> = []
    @State private var previewErrorMessages: [Int: String] = [:]
    @State private var validatedPreviewPageIndices: Set<Int> = []
    @State private var previewOrder: [Int] = []
    @State private var previewRevision = -1
    @State private var activePageIndex = 0
    @State private var assessmentTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var isAssessing = false
    @State private var isSaving = false
    @State private var saveStopRequested = false
    @State private var assessmentGeneration = 0
    @State private var previewGeneration = 0
    @State private var previewReloadToken = UUID()
    @State private var saveGeneration = UUID()
    @State private var isConfirmingDiscard = false
    @State private var sourceContentRevisionID: UUID?

    init(
        recordID: UUID,
        selection: PDFTextSelectionSnapshot,
        onCreated: @escaping (DocumentRoute) -> Void
    ) {
        self.recordID = recordID
        self.selection = selection
        self.onCreated = onCreated
        _replacement = State(
            initialValue: String(
                selection.originalText.prefix(16_000)
            )
        )
        _activePageIndex = State(
            initialValue: selection.pageIndices.first
                ?? selection.pageIndex
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                replacementSurface(availableSize: proxy.size)
            }
            .background(PPColor.canvas)
            .safeAreaInset(edge: .top, spacing: 0) {
                replacementContextBar
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                controls
            }
            .navigationTitle(
                (
                    selection.isCrossPage
                        ? "Reflow Across Pages"
                        : selection.flowRegions.count > 1
                        ? "Reflow Text Boxes"
                        : (
                            selection.lineCount > 4
                                ? "Reflow Paragraph"
                                : "Replace Text"
                        )
                ).localizedUI
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            saveStopRequested
                                ? "Stopping"
                                : isSaving
                                ? "Stop"
                                : "Cancel"
                        ).localizedUI
                    ) {
                        if isSaving {
                            stopSaving()
                        } else {
                            requestDismissal()
                        }
                    }
                    .disabled(saveStopRequested)
                    .accessibilityHint(
                        saveStopRequested
                            ? "Waiting for the current file commit to finish safely"
                            : isSaving
                            ? "Stops waiting; a copy already committed remains in the Library"
                            : "Closes without creating a copy"
                    )
                    .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Copy") {
                        createCopy()
                    }
                    .disabled(!canCreateCopy)
                    .accessibilityHint(createCopyHint.localizedUI)
                }
            }
            .task(id: previewRequestID) {
                await loadRequiredPagePreviews()
            }
            .task {
                sourceContentRevisionID =
                    model.record(id: recordID)?.contentRevisionID
                scheduleAssessment()
            }
            .onChange(of: replacement) { _, value in
                if value.count > 16_000 {
                    replacement = String(value.prefix(16_000))
                    return
                }
                scheduleAssessment()
            }
            .onChange(of: fontStyle) { _, _ in
                scheduleAssessment()
            }
            .onChange(of: alignment) { _, _ in
                scheduleAssessment()
            }
            .onChange(
                of: model.record(id: recordID)?
                    .contentRevisionID
            ) { _, revisionID in
                guard let sourceContentRevisionID,
                      revisionID != sourceContentRevisionID
                else { return }
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                interruptProtectedReplacementEditing()
                dismiss()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    previewReloadToken = UUID()
                    scheduleAssessment()
                } else if phase == .background {
                    interruptProtectedReplacementEditing()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptProtectedReplacementEditing()
            }
            .onDisappear {
                interruptProtectedReplacementWork()
                replacement = ""
            }
            .confirmationDialog(
                "Discard replacement draft?".localizedUI,
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button(
                    "Discard Draft".localizedUI,
                    role: .destructive
                ) {
                    dismiss()
                }
                Button("Keep Editing".localizedUI, role: .cancel) {}
            } message: {
                Text(
                    "Your replacement text and layout choices have not been applied."
                        .localizedUI
                )
            }
            .interactiveDismissDisabled(isSaving || hasDraftChanges)
            .accessibilityAction(.escape) {
                if isSaving {
                    stopSaving()
                } else {
                    requestDismissal()
                }
            }
        }
    }

    private var replacementContextBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PPSpacing.medium) {
                Label(
                    replacementReadinessTitle,
                    systemImage: replacementReadinessSymbol
                )
                .foregroundStyle(replacementReadinessColor)
                Label(
                    "\(selection.originalText.count)",
                    systemImage: "textformat"
                )
                .accessibilityLabel(
                    AppLocalization.format(
                        "%lld characters",
                        selection.originalText.count
                    )
                )
                Label(
                    "\(selection.lineCount)",
                    systemImage: "text.alignleft"
                )
                .accessibilityLabel(
                    AppLocalization.format("%lld lines", selection.lineCount)
                )
                Label(
                    "\(selection.flowRegions.count)",
                    systemImage: "square.dashed"
                )
                .accessibilityLabel(
                    AppLocalization.format(
                        "%lld text boxes",
                        selection.flowRegions.count
                    )
                )
                Label(
                    "\(pageIndices.count)",
                    systemImage: "doc.on.doc"
                )
                .accessibilityLabel(
                    AppLocalization.format("%lld pages", pageIndices.count)
                )
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, PPSpacing.regular)
        }
        .scrollIndicators(.hidden)
        .font(.caption.weight(.semibold))
        .foregroundStyle(PPColor.textSecondary)
        .frame(minHeight: 44)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func replacementSurface(
        availableSize: CGSize
    ) -> some View {
        ZStack {
            PPColor.canvas

            TabView(selection: $activePageIndex) {
                ForEach(pageIndices, id: \.self) { pageIndex in
                    replacementPage(
                        pageIndex: pageIndex,
                        availableSize: availableSize
                    )
                    .tag(pageIndex)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            if pageIndices.count > 1 {
                pagePositionControl
                    .padding(.bottom, PPSpacing.small)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func replacementPage(
        pageIndex: Int,
        availableSize: CGSize
    ) -> some View {
        let pageSize = fittedPageSize(
            in: availableSize,
            pageIndex: pageIndex
        )
        return ZStack {
            Color.white
            if let preview = pagePreviews[pageIndex] {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                replacementOverlays(
                    pageIndex: pageIndex,
                    pageSize: pageSize
                )
            } else if let message = previewErrorMessages[pageIndex] {
                previewFailureState(
                    message: message,
                    pageIndex: pageIndex
                )
            } else if previewLoadingPageIndices.contains(pageIndex) {
                previewLoadingState(pageIndex: pageIndex)
            } else {
                previewFailureState(
                    message:
                        "The page preview could not be loaded. Try again."
                            .localizedUI,
                    pageIndex: pageIndex
                )
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .clipped()
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }

    private func previewLoadingState(
        pageIndex: Int
    ) -> some View {
        VStack(spacing: PPSpacing.small) {
            ProgressView()
            Text(
                AppLocalization.format(
                    "Loading page %lld preview",
                    pageIndex + 1
                )
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func previewFailureState(
        message: String,
        pageIndex: Int
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
                retryPreview(pageIndex)
            } label: {
                Label(
                    "Load Preview Again",
                    systemImage: "arrow.clockwise"
                )
            }
            .buttonStyle(
                PPQuietButtonStyle(tint: PPColor.cyan)
            )
            .disabled(isSaving)
            .accessibilityIdentifier(
                "retryTextReplacementPreview-\(pageIndex)"
            )
        }
        .padding(PPSpacing.medium)
    }

    private func replacementOverlays(
        pageIndex: Int,
        pageSize: CGSize
    ) -> some View {
        let entries = Array(selection.flowRegions.enumerated())
            .filter { $0.element.pageIndex == pageIndex }
        return ForEach(entries, id: \.offset) { index, region in
            replacementOverlay(
                region: region,
                index: index,
                pageSize: pageSize
            )
        }
    }

    private func replacementOverlay(
        region: PDFTextFlowRegion,
        index: Int,
        pageSize: CGSize
    ) -> some View {
        let rect = displayRect(region: region, pageSize: pageSize)
        let ready = assessment?.isReady == true
        let backgrounds = assessment?.regionBackgroundColors ?? []
        let regionTexts = assessment?.flowRegionTexts ?? []
        let background = backgrounds.indices.contains(index)
            ? backgrounds[index]
            : nil
        let text = regionTexts.indices.contains(index)
            ? regionTexts[index]
            : ""
        return ZStack(alignment: .topLeading) {
            if ready, let background {
                Color(
                    red: background.red,
                    green: background.green,
                    blue: background.blue
                )
                if !text.isEmpty {
                    Text(text)
                        .font(
                            .system(
                                size: previewFontSize(
                                    pageSize: pageSize,
                                    pageIndex: region.pageIndex
                                ),
                                design: previewFontDesign
                            )
                        )
                        .lineSpacing(
                            previewLineSpacing(
                                pageSize: pageSize,
                                pageIndex: region.pageIndex
                            )
                        )
                        .multilineTextAlignment(textAlignment)
                        .foregroundStyle(
                            Color(
                                red: selection.color.red,
                                green: selection.color.green,
                                blue: selection.color.blue
                            )
                        )
                        .padding(.horizontal, 1)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: frameAlignment
                        )
                }
            } else {
                Color.clear
            }
            if selection.flowRegions.count > 1 {
                Text("\(index + 1)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(PPColor.accent)
                    .clipShape(Circle())
                    .offset(x: -9, y: -9)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .overlay {
            Rectangle()
                .stroke(
                    ready ? PPColor.mint : PPColor.accent,
                    style: StrokeStyle(
                        lineWidth: 1.4,
                        dash: ready ? [] : [5, 3]
                    )
                )
        }
        .position(x: rect.midX, y: rect.midY)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            selection.flowRegions.count > 1
                ? AppLocalization.format(
                    "Text box %lld of %lld on page %lld",
                    index + 1,
                    selection.flowRegions.count,
                    region.pageIndex + 1
                )
                : AppLocalization.format(
                    "Selected text on page %lld",
                    selection.pageIndex + 1
                )
        )
    }

    private var pagePositionControl: some View {
        HStack(spacing: PPSpacing.small) {
            Button {
                movePage(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(activePagePosition == 0)
            .accessibilityLabel("Previous selected page")

            Text(
                AppLocalization.format(
                    "PAGE %lld OF %lld",
                    activePagePosition + 1,
                    pageIndices.count
                )
            )
            .font(.caption2.smallCaps().weight(.bold))
            .monospacedDigit()
            .foregroundStyle(PPColor.textSecondary)
            .frame(minWidth: 92)

            Button {
                movePage(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(activePagePosition >= pageIndices.count - 1)
            .accessibilityLabel("Next selected page")
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, 4)
        .background(.bar, in: Capsule())
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                if isSaving {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text(
                            (
                                saveStopRequested
                                    ? "Finishing current file commit"
                                    : "Creating private copy"
                            ).localizedUI
                        )
                        .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        OnDeviceBadge(compact: true)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                }

                OperationBoundaryNotice(
                    title: "Edited pages are rebuilt",
                    detail: "Embedded files, bookmarks, or custom page labels may be lost.",
                    identifier: "textReplacementStructureBoundary"
                )

                DisclosureGroup {
                    Text(selection.originalText)
                        .font(.body)
                        .foregroundStyle(PPColor.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, PPSpacing.small)
                } label: {
                    Label(
                        "Original selection".localizedUI,
                        systemImage: "text.quote"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(minHeight: 44)
                }

                VStack(alignment: .trailing, spacing: PPSpacing.xSmall) {
                    TextField(
                        selection.flowRegions.count > 1
                            ? "Replacement text flow"
                            : (
                                selection.lineCount > 4
                                    ? "Replacement paragraph"
                                    : "Replacement text"
                            ),
                        text: $replacement,
                        axis: .vertical
                    )
                    .lineLimit(1...8)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .disabled(isSaving)

                    HStack(spacing: PPSpacing.small) {
                        Text("\(replacement.count) / 16,000")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(PPColor.textSecondary)
                        Spacer(minLength: PPSpacing.small)
                        PasteButton(payloadType: String.self) { values in
                            pasteReplacement(values.first)
                        }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(isSaving)
                        .accessibilityLabel("Paste replacement text")
                    }
                }

                if dynamicTypeSize.ppPrefersExpandedLayout {
                    VStack(spacing: PPSpacing.small) {
                        fontPicker
                        alignmentPicker
                    }
                } else {
                    HStack(spacing: PPSpacing.medium) {
                        fontPicker
                        alignmentPicker
                    }
                }

                HStack(alignment: .top, spacing: PPSpacing.small) {
                    if isAssessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: assessmentStatusSymbol)
                            .foregroundStyle(assessmentStatusColor)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            (
                                assessment?.title
                                ?? (
                                    replacement.isEmpty
                                        ? "Enter replacement text"
                                        : "Checking layout"
                                )
                            ).localizedUI
                        )
                        .font(.subheadline.weight(.semibold))
                        Text(
                            (
                                assessment?.detail
                                    ?? "The source PDF stays unchanged."
                            ).localizedUI
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? 5
                                : 3
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)

                if assessment?.status == .unavailable {
                    Button {
                        scheduleAssessment(immediate: true)
                    } label: {
                        Label(
                            "Check Layout Again",
                            systemImage: "arrow.clockwise"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(
                        PPQuietButtonStyle(tint: PPColor.cyan)
                    )
                    .disabled(isAssessing || isSaving)
                    .accessibilityIdentifier(
                        "retryTextReplacementAssessment"
                    )
                }
            }
            .padding(PPSpacing.regular)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: controlsMaximumHeight)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    @ViewBuilder
    private var fontPicker: some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            Menu {
                ForEach(PDFTextReplacementFontStyle.allCases) { style in
                    Button {
                        fontStyle = style
                    } label: {
                        Label(
                            style.title.localizedUI,
                            systemImage: fontStyle == style
                                ? "checkmark"
                                : "textformat"
                        )
                    }
                }
            } label: {
                HStack {
                    Label("Font style", systemImage: "textformat")
                    Spacer(minLength: PPSpacing.small)
                    Text(fontStyle.title.localizedUI)
                        .foregroundStyle(PPColor.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PPColor.textSecondary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        } else {
            Picker("Font style", selection: $fontStyle) {
                ForEach(PDFTextReplacementFontStyle.allCases) { style in
                    Text(style.title.localizedUI).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isSaving)
        }
    }

    private var alignmentPicker: some View {
        Picker("Alignment", selection: $alignment) {
            ForEach(PDFTextReplacementAlignment.allCases) { option in
                Image(systemName: option.symbol)
                    .accessibilityLabel(option.title.localizedUI)
                    .tag(option)
            }
        }
        .pickerStyle(.segmented)
        .disabled(isSaving)
    }

    private var controlsMaximumHeight: CGFloat {
        if verticalSizeClass == .compact {
            return 220
        }
        return dynamicTypeSize.ppPrefersExpandedLayout ? 340 : 280
    }

    private var previewValidationComplete: Bool {
        let requiredPageIndices = Set(pageIndices)
        return !requiredPageIndices.isEmpty
            && requiredPageIndices.isSubset(
                of: validatedPreviewPageIndices
            )
    }

    private var canCreateCopy: Bool {
        assessment?.isReady == true
            && previewValidationComplete
            && !isAssessing
            && !isSaving
    }

    private var hasDraftChanges: Bool {
        replacement
            != String(selection.originalText.prefix(16_000))
            || fontStyle != .sans
            || alignment != .left
    }

    private func requestDismissal() {
        if hasDraftChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private var createCopyHint: String {
        if assessment?.isReady == true,
           !previewValidationComplete {
            return "Wait for every selected page preview to be verified"
        }
        if assessment?.isReady == true {
            return "Creates a separate edited PDF copy"
        }
        return assessment?.detail
            ?? "Wait for the local layout check"
    }

    private var replacementReadinessTitle: String {
        if !previewErrorMessages.isEmpty {
            return "Preview unavailable"
        }
        if assessment?.isReady == true {
            return previewValidationComplete
                ? "Ready"
                : "Checking previews"
        }
        if replacement.isEmpty {
            return "Waiting"
        }
        if isAssessing {
            return "Checking"
        }
        if assessment?.status == .unavailable {
            return "Check failed"
        }
        return "Needs review"
    }

    private var replacementReadinessSymbol: String {
        if !previewErrorMessages.isEmpty {
            return "doc.questionmark"
        }
        if assessment?.isReady == true,
           previewValidationComplete {
            return "checkmark.circle"
        }
        if assessment?.status == .unavailable {
            return "exclamationmark.arrow.triangle.2.circlepath"
        }
        return "text.magnifyingglass"
    }

    private var replacementReadinessColor: Color {
        if assessment?.isReady == true,
           previewValidationComplete {
            return PPColor.mint
        }
        if assessment?.status == .unavailable
            || !previewErrorMessages.isEmpty {
            return PPColor.amber
        }
        return PPColor.textSecondary
    }

    private var assessmentStatusSymbol: String {
        guard let assessment else {
            return replacement.isEmpty
                ? "text.cursor"
                : "text.magnifyingglass"
        }
        switch assessment.status {
        case .ready:
            return "checkmark.circle.fill"
        case .blocked:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    private var assessmentStatusColor: Color {
        switch assessment?.status {
        case .ready:
            return PPColor.mint
        case .blocked, .unavailable:
            return PPColor.amber
        case nil:
            return PPColor.textSecondary
        }
    }

    private func scheduleAssessment(immediate: Bool = false) {
        assessmentTask?.cancel()
        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessment = nil
        isAssessing = false
        let value = replacement
        let requestedFontStyle = fontStyle
        let requestedAlignment = alignment
        guard let sourceContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == sourceContentRevisionID
        else { return }
        guard !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else { return }
        isAssessing = true
        assessmentTask = Task { @MainActor in
            defer {
                if generation == assessmentGeneration {
                    isAssessing = false
                    assessmentTask = nil
                }
            }
            if !immediate {
                do {
                    try await Task.sleep(for: .milliseconds(220))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled else { return }
            let result = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.assessTextReplacement(
                    recordID: recordID,
                    selection: selection,
                    replacement: value,
                    fontStyle: requestedFontStyle,
                    alignment: requestedAlignment,
                    expectedContentRevisionID:
                        sourceContentRevisionID
                )
            }
            guard !Task.isCancelled,
                  generation == assessmentGeneration,
                  replacement == value,
                  fontStyle == requestedFontStyle,
                  alignment == requestedAlignment,
                  model.record(id: recordID)?.contentRevisionID
                    == sourceContentRevisionID
            else { return }
            assessment = result
        }
    }

    private func createCopy() {
        guard canCreateCopy,
              let assessment,
              let sourceContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == sourceContentRevisionID
        else { return }
        assessmentTask?.cancel()
        isSaving = true
        saveStopRequested = false
        let value = replacement
        let generation = UUID()
        saveGeneration = generation
        saveTask = Task { @MainActor in
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createTextReplacementCopy(
                    recordID: recordID,
                    selection: selection,
                    replacement: value,
                    assessment: assessment,
                    expectedContentRevisionID:
                        sourceContentRevisionID
                )
            }
            guard saveGeneration == generation else { return }
            let wasStopped = saveStopRequested || Task.isCancelled
            isSaving = false
            saveTask = nil
            saveStopRequested = false
            guard !wasStopped else {
                model[noticeFor: paperPathSceneID] = created == nil
                    ? "Copy creation stopped".localizedUI
                    : "Copy finished before stopping · copy kept in Library"
                        .localizedUI
                return
            }
            guard let created else { return }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func pasteReplacement(_ value: String?) {
        guard let value else { return }
        replacement = String(value.prefix(16_000))
    }

    private var pageIndices: [Int] {
        selection.pageIndices
    }

    private var activePagePosition: Int {
        pageIndices.firstIndex(of: activePageIndex) ?? 0
    }

    private func movePage(by offset: Int) {
        let position = min(
            max(activePagePosition + offset, 0),
            max(0, pageIndices.count - 1)
        )
        guard pageIndices.indices.contains(position) else { return }
        withAnimation(
            reduceMotion ? nil : .easeInOut(duration: 0.2)
        ) {
            activePageIndex = pageIndices[position]
        }
    }

    private func fittedPageSize(
        in availableSize: CGSize,
        pageIndex: Int
    ) -> CGSize {
        let pointSize = pagePointSizes[pageIndex]
            ?? CGSize(width: 612, height: 792)
        let pageAspectRatio = pointSize.width
            / max(1, pointSize.height)
        let maximum = CGSize(
            width: max(1, availableSize.width - 32),
            height: max(
                1,
                availableSize.height
                    - (pageIndices.count > 1 ? 64 : 24)
            )
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

    private func displayRect(
        region: PDFTextFlowRegion,
        pageSize: CGSize
    ) -> CGRect {
        CGRect(
            x: region.normalizedX * pageSize.width,
            y: region.normalizedY * pageSize.height,
            width: region.normalizedWidth * pageSize.width,
            height: region.normalizedHeight * pageSize.height
        )
    }

    private var previewRequestID: String {
        [
            String(activePageIndex),
            model.record(id: recordID)?
                .contentRevisionID.uuidString ?? "missing",
            String(model.refreshToken(for: recordID)),
            previewReloadToken.uuidString
        ].joined(separator: "-")
    }

    private func loadRequiredPagePreviews() async {
        guard let requestedRevisionID =
                model.record(id: recordID)?.contentRevisionID
        else { return }
        if sourceContentRevisionID == nil {
            sourceContentRevisionID = requestedRevisionID
        }
        guard sourceContentRevisionID == requestedRevisionID else {
            return
        }
        previewGeneration += 1
        let generation = previewGeneration
        previewLoadingPageIndices.removeAll(keepingCapacity: true)
        let revision = model.refreshToken(for: recordID)
        if previewRevision != revision {
            previewRevision = revision
            pagePreviews.removeAll(keepingCapacity: false)
            pagePointSizes.removeAll(keepingCapacity: false)
            previewErrorMessages.removeAll(keepingCapacity: false)
            validatedPreviewPageIndices.removeAll(keepingCapacity: false)
            previewOrder.removeAll(keepingCapacity: false)
        }
        guard let url = model.url(for: recordID) else {
            for pageIndex in pageIndices {
                previewErrorMessages[pageIndex] =
                    "The working copy is unavailable.".localizedUI
            }
            return
        }
        let requestedPageIndices = [activePageIndex]
            + pageIndices.filter { $0 != activePageIndex }
        for pageIndex in requestedPageIndices {
            guard !Task.isCancelled,
                  generation == previewGeneration,
                  model.refreshToken(for: recordID) == revision,
                  model.record(id: recordID)?.contentRevisionID
                    == requestedRevisionID
            else { return }
            if pagePreviews[pageIndex] != nil {
                validatedPreviewPageIndices.insert(pageIndex)
                touchPreview(pageIndex)
                continue
            }
            if pageIndex != activePageIndex,
               validatedPreviewPageIndices.contains(pageIndex) {
                continue
            }
            previewErrorMessages[pageIndex] = nil
            previewLoadingPageIndices.insert(pageIndex)
            let preview = await PDFEditorPreviewLoader.shared.preview(
                url: url,
                pageIndex: pageIndex,
                revision: revision,
                longEdge: 1_800
            )
            guard !Task.isCancelled,
                  generation == previewGeneration,
                  model.refreshToken(for: recordID) == revision,
                  model.record(id: recordID)?.contentRevisionID
                    == requestedRevisionID
            else { return }
            previewLoadingPageIndices.remove(pageIndex)
            guard let preview else {
                previewErrorMessages[pageIndex] =
                    "The page preview could not be loaded. Try again."
                        .localizedUI
                validatedPreviewPageIndices.remove(pageIndex)
                continue
            }
            pagePointSizes[pageIndex] = CGSize(
                width: CGFloat(preview.pageWidth),
                height: CGFloat(preview.pageHeight)
            )
            pagePreviews[pageIndex] = preview.image
            validatedPreviewPageIndices.insert(pageIndex)
            touchPreview(pageIndex)
        }
    }

    private func retryPreview(_ pageIndex: Int) {
        previewGeneration += 1
        pagePreviews[pageIndex] = nil
        previewErrorMessages[pageIndex] = nil
        validatedPreviewPageIndices.remove(pageIndex)
        previewLoadingPageIndices.insert(pageIndex)
        activePageIndex = pageIndex
        previewReloadToken = UUID()
    }

    private func touchPreview(_ pageIndex: Int) {
        previewOrder.removeAll { $0 == pageIndex }
        previewOrder.append(pageIndex)
        while previewOrder.count > 3 {
            guard let evictionIndex = previewOrder.firstIndex(
                where: { $0 != activePageIndex }
            ) else { break }
            let evicted = previewOrder.remove(at: evictionIndex)
            pagePreviews[evicted] = nil
        }
    }

    private func interruptProtectedReplacementWork() {
        assessmentGeneration += 1
        previewGeneration += 1
        assessmentTask?.cancel()
        assessmentTask = nil
        stopSaving(invalidateResult: true)
        assessment = nil
        isAssessing = false
        pagePreviews.removeAll(keepingCapacity: false)
        pagePointSizes.removeAll(keepingCapacity: false)
        previewLoadingPageIndices.removeAll(keepingCapacity: false)
        previewErrorMessages.removeAll(keepingCapacity: false)
        validatedPreviewPageIndices.removeAll(keepingCapacity: false)
        previewOrder.removeAll(keepingCapacity: false)
    }

    private func interruptProtectedReplacementEditing() {
        interruptProtectedReplacementWork()
        replacement = ""
        dismiss()
    }

    private func stopSaving(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            saveGeneration = UUID()
        } else {
            guard saveTask != nil,
                  !saveStopRequested
            else { return }
            saveStopRequested = true
        }
        saveTask?.cancel()
        if invalidateResult {
            saveTask = nil
            isSaving = false
            saveStopRequested = false
        }
    }

    private func previewFontSize(
        pageSize: CGSize,
        pageIndex: Int
    ) -> CGFloat {
        let pagePointSize = pagePointSizes[pageIndex]
            ?? CGSize(width: 612, height: 792)
        let scale = pageSize.height
            / max(1, pagePointSize.height)
        return max(
            5,
            CGFloat(assessment?.resolvedFontSize ?? selection.fontSize)
                * scale
        )
    }

    private func previewLineSpacing(
        pageSize: CGSize,
        pageIndex: Int
    ) -> CGFloat {
        let pagePointSize = pagePointSizes[pageIndex]
            ?? CGSize(width: 612, height: 792)
        let scale = pageSize.height
            / max(1, pagePointSize.height)
        return CGFloat(assessment?.resolvedLineSpacing ?? 0) * scale
    }

    private var previewFontDesign: Font.Design {
        switch fontStyle {
        case .sans: return .default
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }

    private var textAlignment: TextAlignment {
        switch alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        }
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .left: return .topLeading
        case .center: return .top
        case .right: return .topTrailing
        }
    }

}
