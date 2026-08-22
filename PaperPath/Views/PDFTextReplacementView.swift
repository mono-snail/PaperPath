import PDFKit
import SwiftUI

struct PDFTextReplacementView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let recordID: UUID
    let selection: PDFTextSelectionSnapshot
    let onCreated: (DocumentRoute) -> Void

    @State private var replacement = ""
    @State private var fontStyle: PDFTextReplacementFontStyle = .sans
    @State private var alignment: PDFTextReplacementAlignment = .left
    @State private var assessment: PDFTextReplacementAssessment?
    @State private var pagePreviews: [Int: UIImage] = [:]
    @State private var pagePointSizes: [Int: CGSize] = [:]
    @State private var activePageIndex = 0
    @State private var assessmentTask: Task<Void, Never>?
    @State private var saveTask: Task<Void, Never>?
    @State private var isSaving = false
    @State private var assessmentGeneration = 0
    @State private var previewGeneration = 0

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
                            isSaving
                                ? "Stop"
                                : "Cancel"
                        ).localizedUI
                    ) {
                        if isSaving {
                            saveTask?.cancel()
                            saveTask = nil
                            isSaving = false
                        } else {
                            dismiss()
                        }
                    }
                    .accessibilityHint(
                        isSaving
                            ? "Stops creation and discards the temporary copy"
                            : "Closes without creating a copy"
                    )
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create Copy") {
                        createCopy()
                    }
                    .disabled(
                        assessment?.isReady != true || isSaving
                    )
                }
            }
            .task {
                previewGeneration += 1
                let generation = previewGeneration
                guard let url = model.url(for: recordID) else { return }
                activePageIndex = pageIndices.first
                    ?? selection.pageIndex
                for pageIndex in pageIndices {
                    guard !Task.isCancelled,
                          generation == previewGeneration
                    else { return }
                    let preview = await PDFEditorPreviewLoader.shared.preview(
                        url: url,
                        pageIndex: pageIndex,
                        revision: model.refreshToken(for: recordID),
                        longEdge: 1_800
                    )
                    guard !Task.isCancelled,
                          generation == previewGeneration,
                          let preview
                    else { return }
                    pagePointSizes[pageIndex] = CGSize(
                        width: CGFloat(preview.pageWidth),
                        height: CGFloat(preview.pageHeight)
                    )
                    pagePreviews[pageIndex] = preview.image
                }
            }
            .onChange(of: replacement) { _, _ in
                scheduleAssessment()
            }
            .onChange(of: fontStyle) { _, _ in
                scheduleAssessment()
            }
            .onChange(of: alignment) { _, _ in
                scheduleAssessment()
            }
            .onDisappear {
                assessmentGeneration += 1
                previewGeneration += 1
                assessmentTask?.cancel()
                saveTask?.cancel()
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private var replacementContextBar: some View {
        HStack(spacing: PPSpacing.medium) {
            Label(
                "\(selection.originalText.count)",
                systemImage: "textformat"
            )
            Label(
                "\(selection.lineCount)",
                systemImage: "text.alignleft"
            )
            Label(
                "\(selection.flowRegions.count)",
                systemImage: "square.dashed"
            )
            Label(
                "\(pageIndices.count)",
                systemImage: "doc.on.doc"
            )
            Spacer(minLength: 0)
            Label(
                assessment?.isReady == true
                    ? "Fits"
                    : replacement.isEmpty
                        ? "Waiting"
                        : "Checking",
                systemImage: assessment?.isReady == true
                    ? "checkmark.circle"
                    : "text.magnifyingglass"
            )
            .foregroundStyle(
                assessment?.isReady == true
                    ? PPColor.mint
                    : PPColor.textSecondary
            )
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
            } else {
                ProgressView()
            }
            replacementOverlays(
                pageIndex: pageIndex,
                pageSize: pageSize
            )
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .clipped()
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
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
                                    pageSize: pageSize
                                ),
                                design: previewFontDesign
                            )
                        )
                        .lineSpacing(
                            previewLineSpacing(pageSize: pageSize)
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
                ? "Text box \(index + 1) of \(selection.flowRegions.count) on page \(region.pageIndex + 1)"
                : "Selected text on page \(selection.pageIndex + 1)"
        )
    }

    private var pagePositionControl: some View {
        HStack(spacing: PPSpacing.small) {
            Button {
                movePage(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(activePagePosition == 0)
            .accessibilityLabel("Previous selected page")

            Text(
                "PAGE \(activePagePosition + 1) OF \(pageIndices.count)"
            )
            .font(.caption2.smallCaps().weight(.bold))
            .monospacedDigit()
            .foregroundStyle(PPColor.textSecondary)
            .frame(minWidth: 92)

            Button {
                movePage(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 32, height: 32)
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
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            HStack(spacing: PPSpacing.small) {
                Text("ORIGINAL")
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(PPColor.textSecondary)
                Text(selection.originalText)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
            }

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

            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.medium) {
                    fontPicker
                    alignmentPicker
                }
                VStack(spacing: PPSpacing.small) {
                    fontPicker
                    alignmentPicker
                }
            }

            HStack(alignment: .top, spacing: PPSpacing.small) {
                if assessment == nil,
                   !replacement.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(
                        systemName: assessment?.isReady == true
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(
                        assessment?.isReady == true
                            ? PPColor.mint
                            : PPColor.amber
                    )
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
                    .lineLimit(3)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var fontPicker: some View {
        Picker("Font style", selection: $fontStyle) {
            ForEach(PDFTextReplacementFontStyle.allCases) { style in
                Text(style.title.localizedUI).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .disabled(isSaving)
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

    private func scheduleAssessment() {
        assessmentTask?.cancel()
        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessment = nil
        let value = replacement
        let requestedFontStyle = fontStyle
        let requestedAlignment = alignment
        guard !value.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else { return }
        assessmentTask = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let result = await model.assessTextReplacement(
                recordID: recordID,
                selection: selection,
                replacement: value,
                fontStyle: requestedFontStyle,
                alignment: requestedAlignment
            )
            guard !Task.isCancelled,
                  generation == assessmentGeneration,
                  replacement == value,
                  fontStyle == requestedFontStyle,
                  alignment == requestedAlignment
            else { return }
            assessment = result
        }
    }

    private func createCopy() {
        guard let assessment, assessment.isReady else { return }
        assessmentTask?.cancel()
        isSaving = true
        let value = replacement
        saveTask = Task {
            let created = await model.createTextReplacementCopy(
                recordID: recordID,
                selection: selection,
                replacement: value,
                assessment: assessment
            )
            guard !Task.isCancelled else {
                isSaving = false
                saveTask = nil
                return
            }
            isSaving = false
            saveTask = nil
            guard let created else { return }
            dismiss()
            onCreated(DocumentRoute(recordID: created.id))
        }
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

    private func previewFontSize(pageSize: CGSize) -> CGFloat {
        let pagePointSize = pagePointSizes[activePageIndex]
            ?? CGSize(width: 612, height: 792)
        let scale = pageSize.height
            / max(1, pagePointSize.height)
        return max(
            5,
            CGFloat(assessment?.resolvedFontSize ?? selection.fontSize)
                * scale
        )
    }

    private func previewLineSpacing(pageSize: CGSize) -> CGFloat {
        let pagePointSize = pagePointSizes[activePageIndex]
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
