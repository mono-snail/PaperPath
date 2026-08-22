import SwiftUI

private struct OCRCorrectionTarget: Identifiable {
    let pageIndex: Int
    let block: OCRTextBlock

    var id: UUID { block.id }
}

struct RecognizedTextView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let onCreated: (DocumentRoute) -> Void
    let onOpenPage: (Int) -> Void
    let onRecognizeAgain: () -> Void

    @State private var copyCount = 0
    @State private var showsReviewOnly = false
    @State private var correctionTarget: OCRCorrectionTarget?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                if let result = model.ocrResults[recordID] {
                    content(result)
                } else {
                    PPEmptyState(
                        kind: .search,
                        title: "No recognized text",
                        message: "Run local recognition from the document workspace."
                    )
                    .padding(PPSpacing.regular)
                }
            }
            .navigationTitle("Recognized text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if let result = model.ocrResults[recordID], !result.text.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            SecurePasteboard.copy(result.text)
                            copyCount += 1
                            model.noticeMessage = "Recognized text copied"
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel("Copy all recognized text")
                    }
                }
                if model.ocrResults[recordID] != nil {
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            dismiss()
                            onRecognizeAgain()
                        } label: {
                            Label(
                                "Recognize Again",
                                systemImage: "arrow.clockwise"
                            )
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.success, trigger: copyCount)
        .sheet(item: $correctionTarget) { target in
            OCRTextCorrectionSheet(
                pageIndex: target.pageIndex,
                block: target.block
            ) { replacement in
                await model.correctRecognizedText(
                    recordID: recordID,
                    pageIndex: target.pageIndex,
                    blockID: target.block.id,
                    replacement: replacement
                )
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func content(_ result: OCRResult) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PPSpacing.large) {
                WorkflowCommandHeader(
                    eyebrow: "OCR RESULT",
                    title: "Recognized text",
                    detail: result.configuration.languageSummary,
                    symbol: "text.viewfinder",
                    tint: PPColor.mint,
                    metrics: [
                        WorkflowMetric(
                            value: "\(result.pages.count)",
                            label: "Pages",
                            symbol: "doc.on.doc",
                            tint: PPColor.accent
                        ),
                        WorkflowMetric(
                            value: "\(Int(result.meanConfidence * 100))%",
                            label: "Confidence",
                            symbol: "chart.bar.fill",
                            tint: confidenceColor(result.meanConfidence)
                        ),
                        WorkflowMetric(
                            value: "\(result.pagesNeedingReview.count)",
                            label: "Review",
                            symbol: "exclamationmark.magnifyingglass",
                            tint: result.pagesNeedingReview.isEmpty
                                ? PPColor.mint
                                : PPColor.amber
                        ),
                        WorkflowMetric(
                            value: "\(result.configuration.customWords.count)",
                            label: "Terms",
                            symbol: "text.badge.plus",
                            tint: PPColor.cyan
                        )
                    ]
                )

                if result.pages.contains(where: { !$0.blocks.isEmpty }) {
                    HStack(spacing: PPSpacing.small) {
                        if !result.pagesNeedingReview.isEmpty {
                            Picker(
                                "Recognized pages",
                                selection: $showsReviewOnly
                            ) {
                                Text("All \(result.pages.count)")
                                    .tag(false)
                                Text(
                                    "Review \(result.pagesNeedingReview.count)"
                                )
                                .tag(true)
                            }
                            .pickerStyle(.segmented)
                            .accessibilityLabel("Filter recognized pages")
                        }
                        Button {
                            Task {
                                if let created =
                                    await model.createSearchableCopy(
                                        recordID: recordID
                                    ) {
                                    dismiss()
                                    try? await Task.sleep(
                                        for: .milliseconds(220)
                                    )
                                    onCreated(
                                        DocumentRoute(
                                            recordID: created.id
                                        )
                                    )
                                }
                            }
                        } label: {
                            Label(
                                "Create Searchable Copy",
                                systemImage: "doc.text.magnifyingglass"
                            )
                            .lineLimit(1)
                        }
                        .buttonStyle(PPQuietButtonStyle(tint: PPColor.mint))
                        .disabled(model.isProcessing(recordID))
                        .accessibilityIdentifier(
                            "createSearchableCopyButton"
                        )
                    }
                }

                if result.text.isEmpty {
                    PPEmptyState(
                        kind: .search,
                        title: "No readable text found",
                        message: "Try a clearer scan with stronger contrast and less perspective."
                    )
                } else {
                    ForEach(visiblePages(in: result)) { page in
                        VStack(alignment: .leading, spacing: PPSpacing.medium) {
                            HStack {
                                SectionEyebrow(
                                    text: AppLocalization.format(
                                        "PAGE %lld",
                                        page.pageIndex + 1
                                    )
                                )
                                if page.recognitionPass == .enhanced {
                                    Label(
                                        "Enhanced",
                                        systemImage: "wand.and.rays"
                                    )
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(PPColor.cyan)
                                }
                                Spacer()
                                Text("\(Int(page.confidence * 100))%")
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(confidenceColor(page.confidence))
                            }

                            Text(page.text.isEmpty ? "No readable text" : page.text)
                                .font(.body)
                                .foregroundStyle(
                                    page.text.isEmpty
                                        ? PPColor.textSecondary
                                        : PPColor.textPrimary
                                )
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if !page.lowConfidenceBlocks.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    Label(
                                        "Review \(page.lowConfidenceBlocks.count) uncertain line\(page.lowConfidenceBlocks.count == 1 ? "" : "s")",
                                        systemImage: "text.badge.checkmark"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PPColor.amber)
                                    .padding(.bottom, 4)

                                    ForEach(
                                        page.lowConfidenceBlocks.prefix(6)
                                    ) { block in
                                        Button {
                                            correctionTarget =
                                                OCRCorrectionTarget(
                                                    pageIndex:
                                                        page.pageIndex,
                                                    block: block
                                                )
                                        } label: {
                                            HStack(
                                                alignment:
                                                    .firstTextBaseline,
                                                spacing: PPSpacing.small
                                            ) {
                                                Text(block.text)
                                                    .lineLimit(1)
                                                    .foregroundStyle(
                                                        PPColor.textPrimary
                                                    )
                                                Spacer(minLength: 12)
                                                Text(
                                                    "\(Int(block.confidence * 100))%"
                                                )
                                                .font(
                                                    .caption
                                                        .monospacedDigit()
                                                )
                                                .foregroundStyle(
                                                    PPColor.amber
                                                )
                                                Image(systemName: "pencil")
                                                    .font(.caption)
                                                    .foregroundStyle(
                                                        PPColor.accent
                                                    )
                                            }
                                            .frame(minHeight: 38)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .overlay(alignment: .bottom) {
                                            Rectangle()
                                                .fill(
                                                    PPColor.border.opacity(
                                                        0.54
                                                    )
                                                )
                                                .frame(height: 0.6)
                                        }
                                    }
                                }
                            }

                            if page.needsReview {
                                Button {
                                    dismiss()
                                    Task {
                                        try? await Task.sleep(
                                            for: .milliseconds(180)
                                        )
                                        onOpenPage(page.pageIndex)
                                    }
                                } label: {
                                    Label(
                                        "Review on page",
                                        systemImage: "doc.text.magnifyingglass"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(PPColor.cyan)
                                .frame(minHeight: 44)
                            }
                        }
                        .padding(.vertical, PPSpacing.small)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(PPColor.border.opacity(0.66))
                                .frame(height: 0.6)
                        }
                    }
                }
            }
            .frame(maxWidth: 880)
            .padding(PPSpacing.regular)
            .frame(maxWidth: .infinity)
        }
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.82 { return PPColor.mint }
        if confidence >= 0.62 { return PPColor.amber }
        return PPColor.textSecondary
    }

    private func visiblePages(
        in result: OCRResult
    ) -> [OCRPageResult] {
        showsReviewOnly ? result.pagesNeedingReview : result.pages
    }
}

private struct OCRTextCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let pageIndex: Int
    let block: OCRTextBlock
    let onSave: (String) async -> Bool

    @State private var text: String
    @State private var isSaving = false

    init(
        pageIndex: Int,
        block: OCRTextBlock,
        onSave: @escaping (String) async -> Bool
    ) {
        self.pageIndex = pageIndex
        self.block = block
        self.onSave = onSave
        _text = State(initialValue: block.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.sentences)
                } header: {
                    Text("Recognized line")
                } footer: {
                    Text(
                        "Page \(pageIndex + 1) · Vision confidence \(Int(block.confidence * 100))%. The correction stays on this device."
                    )
                }
            }
            .navigationTitle("Correct Recognition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        Task {
                            let saved = await onSave(text)
                            isSaving = false
                            if saved {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        isSaving
                            || text.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                            || text.count > 500
                    )
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }
}

struct OCRConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onStart: (OCRRecognitionConfiguration) -> Void

    @State private var mode: OCRLanguageMode
    @State private var selectedLanguages: Set<String>
    @State private var customWordsText: String

    init(
        initialConfiguration: OCRRecognitionConfiguration = .automatic,
        onStart: @escaping (OCRRecognitionConfiguration) -> Void
    ) {
        self.onStart = onStart
        _mode = State(
            initialValue: initialConfiguration.languageMode
        )
        _selectedLanguages = State(
            initialValue: Set(
                initialConfiguration.languageIdentifiers
            )
        )
        _customWordsText = State(
            initialValue:
                initialConfiguration.customWords
                    .joined(separator: "\n")
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.large
                    ) {
                        WorkflowCommandHeader(
                            eyebrow: "OCR WORKFLOW",
                            title: "Recognize text",
                            detail: "Choose language intent and local vocabulary before processing.",
                            symbol: "text.viewfinder",
                            tint: PPColor.mint,
                            metrics: [
                                WorkflowMetric(
                                    value: mode.title,
                                    label: "Mode",
                                    symbol: "character.book.closed",
                                    tint: PPColor.accent
                                ),
                                WorkflowMetric(
                                    value: mode == .automatic
                                        ? "Auto"
                                        : "\(selectedLanguages.count)",
                                    label: "Languages",
                                    symbol: "globe",
                                    tint: PPColor.cyan
                                ),
                                WorkflowMetric(
                                    value: "\(customWords.count)",
                                    label: "Terms",
                                    symbol: "text.badge.plus",
                                    tint: customWordsAreValid
                                        ? PPColor.mint
                                        : PPColor.amber
                                )
                            ]
                        )

                        WorkflowSectionHeader(
                            eyebrow: "LANGUAGE INTENT",
                            title: mode.title
                        )

                    Picker("Recognition language", selection: $mode) {
                        ForEach(OCRLanguageMode.allCases) { option in
                            Text(option.title.localizedUI)
                                .tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("ocrLanguageMode")

                    if mode == .selected {
                            LazyVGrid(
                                columns: [
                                    GridItem(
                                        .adaptive(
                                            minimum: 148,
                                            maximum: 260
                                        ),
                                        spacing: PPSpacing.small
                                    )
                                ],
                                spacing: PPSpacing.small
                            ) {
                                ForEach(
                                    OCRRecognitionLanguage.allCases
                                ) { language in
                                    Toggle(
                                        language.title,
                                        isOn: languageBinding(language)
                                    )
                                    .toggleStyle(.button)
                                    .buttonStyle(
                                        PPQuietButtonStyle(
                                            tint: selectedLanguages.contains(
                                                language.rawValue
                                            )
                                                ? PPColor.accent
                                                : PPColor.textSecondary
                                        )
                                    )
                                    .disabled(
                                        !selectedLanguages.contains(
                                            language.rawValue
                                        )
                                            && selectedLanguages.count >= 4
                                    )
                                    .accessibilityIdentifier(
                                        "ocrLanguage-\(language.rawValue)"
                                    )
                                }
                            }
                        }

                        WorkflowSectionHeader(
                            eyebrow: "LOCAL VOCABULARY",
                            title: "Custom Terms",
                            count: customWords.count,
                            tint: customWordsAreValid
                                ? PPColor.mint
                                : PPColor.amber
                        )

                    TextField(
                        "Names or terms, one per line",
                        text: $customWordsText,
                        axis: .vertical
                    )
                    .lineLimit(3...7)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("ocrCustomWords")

                        HStack {
                            Text(
                                "Terms are used only for this on-device recognition run."
                            )
                            Spacer()
                            Text("\(customWords.count) / 50")
                                .monospacedDigit()
                        }
                        .font(.caption)
                        .foregroundStyle(
                            customWordsAreValid
                                ? PPColor.textSecondary
                                : Color.red
                        )
                    }
                    .frame(maxWidth: 720)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 72)
                    .frame(maxWidth: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    let configuration = OCRRecognitionConfiguration(
                        languageMode: mode,
                        languageIdentifiers:
                            mode == .selected
                                ? selectedLanguages.sorted()
                                : [],
                        customWords: customWords
                    )
                    dismiss()
                    onStart(configuration)
                } label: {
                    Label(
                        "Recognize on Device",
                        systemImage: "text.viewfinder"
                    )
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(!canStart)
                .accessibilityIdentifier("startOCR")
                .padding(.horizontal, PPSpacing.regular)
                .padding(.vertical, PPSpacing.small)
                .background(.bar)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.62))
                        .frame(height: 0.6)
                }
            }
            .navigationTitle("Recognition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: mode) { _, newMode in
                if newMode == .selected,
                   selectedLanguages.isEmpty {
                    selectedLanguages.insert(
                        OCRRecognitionLanguage.english.rawValue
                    )
                }
            }
            .onChange(of: customWordsText) { _, value in
                if value.count > 3_200 {
                    customWordsText = String(value.prefix(3_200))
                }
            }
        }
    }

    private var customWords: [String] {
        customWordsText
            .components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, word in
                guard !result.contains(where: {
                    $0.caseInsensitiveCompare(word) == .orderedSame
                }) else { return }
                result.append(word)
            }
    }

    private var customWordsAreValid: Bool {
        customWords.count <= 50
            && customWords.allSatisfy { $0.count <= 64 }
            && customWords.reduce(0) { $0 + $1.count } <= 2_048
    }

    private var canStart: Bool {
        customWordsAreValid
            && (
                mode == .automatic
                    || (1...4).contains(selectedLanguages.count)
            )
    }

    private func languageBinding(
        _ language: OCRRecognitionLanguage
    ) -> Binding<Bool> {
        Binding {
            selectedLanguages.contains(language.rawValue)
        } set: { selected in
            if selected {
                selectedLanguages.insert(language.rawValue)
            } else {
                selectedLanguages.remove(language.rawValue)
            }
        }
    }
}
