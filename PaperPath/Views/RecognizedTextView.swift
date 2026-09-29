import SwiftUI

private struct OCRCorrectionTarget: Identifiable {
    let pageIndex: Int
    let block: OCRTextBlock

    var id: UUID { block.id }
}

private struct OCRRestorationRequest: Hashable {
    let contentRevisionID: UUID?
    let requestToken: UUID
}

private struct OCRSearchRequest: Hashable {
    let query: String
    let generation: UUID
}

struct RecognizedTextView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let onCreated: (DocumentRoute) -> Void
    let onOpenPage: (Int) -> Void
    let onRecognizeAgain: () -> Void

    @StateObject private var recognizedTextCopy =
        SecurePasteboardCopyController()
    @State private var showsReviewOnly = false
    @State private var correctionTarget: OCRCorrectionTarget?
    @State private var creationTask: Task<Void, Never>?
    @State private var creationGeneration = UUID()
    @State private var creationStopRequested = false
    @State private var creationErrorMessage: String?
    @State private var creationErrorFeedback = 0
    @State private var copyErrorMessage: String?
    @State private var isRestoringText = true
    @State private var restorationErrorMessage: String?
    @State private var restorationRequestToken = UUID()
    @State private var allLinesPageIndices: Set<Int> = []
    @State private var reviewLineLimits: [Int: Int] = [:]
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @State private var searchGeneration = UUID()
    @State private var matchingPageIndices: Set<Int> = []
    @State private var displayedSearchRequest: OCRSearchRequest?

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                if let result = model.ocrResults[recordID] {
                    content(result)
                } else if isRestoringText {
                    PPEmptyState(
                        kind: .processing,
                        title: "Loading recognized text",
                        message: "Restoring the private on-device result."
                    )
                    .padding(PPSpacing.regular)
                } else if let restorationErrorMessage {
                    recognitionRestoreFailureState(
                        restorationErrorMessage
                    )
                    .padding(PPSpacing.regular)
                } else {
                    recognitionEmptyState(
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
                    Button(
                        (
                            creationTask == nil
                                ? "Close"
                                : creationStopRequested
                                    ? "Stopping"
                                    : "Stop"
                        ).localizedUI
                    ) {
                        if creationTask != nil {
                            interruptSearchableCopyCreation()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(creationStopRequested)
                }
                if let result = model.ocrResults[recordID],
                   hasReadableText(in: result) {
                    ToolbarItem(placement: .confirmationAction) {
                        Menu {
                            Button("Copy all recognized text".localizedUI, systemImage: "doc.on.doc") {
                                copyRecognizedPages(result.pages)
                            }
                            if showsReviewOnly || !searchRequest.query.isEmpty {
                                Button("Copy filtered pages".localizedUI, systemImage: "line.3.horizontal.decrease") {
                                    copyRecognizedPages(visibleRecognizedPages(result))
                                }
                                .disabled(
                                    displayedSearchRequest != searchRequest
                                        || !visibleRecognizedPages(result).contains { !$0.text.isEmpty }
                                )
                            }
                        } label: {
                            Image(
                                systemName: recognizedCopySymbol
                            )
                        }
                        .foregroundStyle(recognizedCopyTint)
                        .accessibilityLabel("Copy recognized text".localizedUI)
                        .accessibilityIdentifier("recognizedTextCopyMenu")
                    }
                }
                if model.ocrResults[recordID] != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isSearchPresented = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .keyboardShortcut("f", modifiers: .command)
                        .accessibilityLabel("Search recognized text".localizedUI)
                        .help("Search recognized text".localizedUI)
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button {
                            onRecognizeAgain()
                        } label: {
                            Label(
                                "Recognize Again",
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .disabled(creationTask != nil)
                    }
                }
            }
            .searchable(
                text: $searchText,
                isPresented: $isSearchPresented,
                prompt: Text("Search recognized text".localizedUI)
            )
        }
        .accessibilityAction(.escape) {
            if creationTask != nil {
                interruptSearchableCopyCreation()
            } else {
                dismiss()
            }
        }
        .interactiveDismissDisabled(creationTask != nil)
        .task(id: restorationRequest) {
            await restoreRecognizedText()
        }
        .task(id: searchRequest) {
            await searchRecognizedPages()
        }
        .onReceive(model.$ocrResults) { _ in
            searchGeneration = UUID()
        }
        .onChange(of: searchText) { _, value in
            if value.count > 256 { searchText = String(value.prefix(256)) }
        }
        .onChange(
            of: model.record(id: recordID)?.contentRevisionID
        ) { _, _ in
            correctionTarget = nil
            allLinesPageIndices.removeAll()
            reviewLineLimits.removeAll()
            searchGeneration = UUID()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                recognizedTextCopy.synchronizeOwnership()
                if model.ocrResults[recordID] == nil,
                   !isRestoringText {
                    restorationRequestToken = UUID()
                }
            } else if phase == .background {
                isSearchPresented = false
                searchText = ""
                matchingPageIndices.removeAll()
                searchGeneration = UUID()
                correctionTarget = nil
                resetRecognizedCopyState()
                interruptSearchableCopyCreation(invalidateResult: true)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIPasteboard.changedNotification
            )
        ) { _ in
            recognizedTextCopy.synchronizeOwnership()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            isSearchPresented = false
            searchText = ""
            matchingPageIndices.removeAll()
            searchGeneration = UUID()
            correctionTarget = nil
            resetRecognizedCopyState()
            interruptSearchableCopyCreation(invalidateResult: true)
        }
        .onDisappear {
            resetRecognizedCopyState()
            interruptSearchableCopyCreation(invalidateResult: true)
        }
        .onChange(
            of: model.ocrResults[recordID]?
                .pagesNeedingReview.count ?? 0
        ) { _, reviewCount in
            if reviewCount == 0 {
                showsReviewOnly = false
            }
        }
        .sensoryFeedback(
            .success,
            trigger: recognizedTextCopy.successFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: recognizedTextCopy.errorFeedback
        )
        .sensoryFeedback(
            .error,
            trigger: creationErrorFeedback
        )
        .sensoryFeedback(
            .selection,
            trigger: showsReviewOnly
        )
        .alert(
            "Couldn’t Copy Text",
            isPresented: Binding(
                get: { copyErrorMessage != nil },
                set: {
                    if !$0 {
                        copyErrorMessage = nil
                        if recognizedTextCopy.status == .failed {
                            recognizedTextCopy.reset()
                        }
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                copyErrorMessage = nil
                recognizedTextCopy.reset()
            }
        } message: {
            Text(copyErrorMessage?.localizedUI ?? "")
        }
        .sheet(item: $correctionTarget) { target in
            OCRTextCorrectionSheet(
                pageIndex: target.pageIndex,
                block: target.block
            ) { replacement in
                let saved = await model.withFeedbackTarget(paperPathSceneID) {
                    await model.correctRecognizedText(
                        recordID: recordID,
                        pageIndex: target.pageIndex,
                        blockID: target.block.id,
                        expectedBlock: target.block,
                        replacement: replacement
                    )
                }
                if saved {
                    resetRecognizedCopyState()
                }
                return saved
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var recognizedCopyStatusLabel: some View {
        switch recognizedTextCopy.status {
        case .idle:
            EmptyView()
        case .copied:
            Label(
                "Recognized text copied locally for five minutes"
                    .localizedUI,
                systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(PPColor.mint)
            .font(.caption.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        case .failed:
            Label(
                "Recognized text is too large to copy safely."
                    .localizedUI,
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(PPColor.amber)
            .font(.caption.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recognizedCopySymbol: String {
        switch recognizedTextCopy.status {
        case .idle:
            return "doc.on.doc"
        case .copied:
            return "checkmark"
        case .failed:
            return "arrow.clockwise"
        }
    }

    private var recognizedCopyTint: Color {
        switch recognizedTextCopy.status {
        case .idle:
            return PPColor.accent
        case .copied:
            return PPColor.mint
        case .failed:
            return PPColor.amber
        }
    }

    private func copyRecognizedText(_ text: String) {
        copyErrorMessage = nil
        guard recognizedTextCopy.copy(text) else {
            copyErrorMessage =
                "Recognized text is too large to copy safely."
                    .localizedUI
            return
        }
    }

    private func resetRecognizedCopyState() {
        recognizedTextCopy.reset()
        copyErrorMessage = nil
    }

    private func visibleRecognizedPages(_ result: OCRResult) -> [OCRPageResult] {
        let pages = showsReviewOnly ? result.pagesNeedingReview : result.pages
        return searchRequest.query.isEmpty
            ? pages
            : pages.filter { matchingPageIndices.contains($0.pageIndex) }
    }

    private func copyRecognizedPages(_ pages: [OCRPageResult]) {
        guard scenePhase == .active, UIApplication.shared.isProtectedDataAvailable else { return }
        var text = ""
        var bytes = 0
        for page in pages where !page.text.isEmpty {
            let heading = AppLocalization.format("Page %lld", page.pageIndex + 1) + "\n"
            bytes += heading.utf8.count + page.text.utf8.count + (text.isEmpty ? 0 : 2)
            guard bytes <= 8 * 1_024 * 1_024 else {
                copyRecognizedText("")
                return
            }
            if !text.isEmpty { text += "\n\n" }
            text += heading + page.text
        }
        copyRecognizedText(text)
    }

    private func content(_ result: OCRResult) -> some View {
        let reviewPages = result.pagesNeedingReview
        let visiblePages = visibleRecognizedPages(result)
        let copyablePageCount = visiblePages.filter { !$0.text.isEmpty }.count
        let containsReadableText = hasReadableText(in: result)
        let statusTitle = !containsReadableText
            ? "No readable text found"
            : reviewPages.isEmpty
            ? "Text is ready"
            : AppLocalization.format(
                "%lld page%@ need review",
                reviewPages.count,
                reviewPages.count == 1 ? "" : "s"
            )
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: PPSpacing.large) {
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    Text(model.record(id: recordID)?.displayName ?? "")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textSecondary)
                    Label(
                        statusTitle.localizedUI,
                        systemImage: !containsReadableText || !reviewPages.isEmpty
                            ? "exclamationmark.circle" : "checkmark.circle"
                    )
                    .font(PPType.display)
                    .foregroundStyle(!containsReadableText || !reviewPages.isEmpty ? PPColor.amber : PPColor.textPrimary)
                    Text(result.configuration.languageSummary)
                        .font(PPType.metadata)
                        .foregroundStyle(PPColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .ppCard()
                recognizedCopyStatusLabel
                if showsReviewOnly || !searchRequest.query.isEmpty {
                    VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
                        Button {
                            copyRecognizedPages(visiblePages)
                        } label: {
                            Label(
                                copyablePageCount == 1
                                    ? "Copy text from 1 page".localizedUI
                                    : AppLocalization.format(
                                        "Copy text from %lld pages",
                                        copyablePageCount
                                    ),
                                systemImage: "doc.on.doc"
                            )
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                        }
                        .disabled(
                            displayedSearchRequest != searchRequest
                                || !visiblePages.contains { !$0.text.isEmpty }
                        )
                        .accessibilityIdentifier("copyFilteredRecognizedPages")
                        Text("Copies full page text, including words outside the current matches.".localizedUI)
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if result.pages.contains(where: { !$0.blocks.isEmpty }) {
                    recognizedPagesFilter(
                        pageCount: result.pages.count,
                        reviewCount: reviewPages.count
                    )
                }

                if !containsReadableText {
                    recognitionEmptyState(
                        title: "No readable text found",
                        message: "Try a clearer scan with stronger contrast and less perspective."
                    )
                } else if !searchRequest.query.isEmpty,
                          displayedSearchRequest != searchRequest {
                    ProgressView("Searching recognized text".localizedUI)
                        .frame(minHeight: 44)
                } else if visiblePages.isEmpty {
                    ContentUnavailableView(
                        "No matching pages".localizedUI,
                        systemImage: "magnifyingglass"
                    )
                    Button("Clear filters".localizedUI) {
                        searchText = ""
                        showsReviewOnly = false
                    }
                } else {
                    ForEach(visiblePages) { page in
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

                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: PPSpacing.large) {
                                    recognizedPageActions(page)
                                }
                                VStack(alignment: .leading, spacing: PPSpacing.small) {
                                    recognizedPageActions(page)
                                }
                            }

                            if showsReviewOnly, !page.blocks.isEmpty {
                                DisclosureGroup {
                                    recognizedPageText(page)
                                        .padding(.vertical, PPSpacing.small)
                                } label: {
                                    Label(
                                        "Full page text".localizedUI,
                                        systemImage: "text.alignleft"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minHeight: 44)
                                }
                            } else {
                                recognizedPageText(page)
                            }

                            if !page.blocks.isEmpty {
                                let reviewsAllLines = allLinesPageIndices.contains(page.pageIndex)
                                let reviewBlocks = reviewsAllLines ? page.blocks : page.lowConfidenceBlocks
                                let visibleLimit = reviewLineLimits[page.pageIndex, default: 6]
                                VStack(alignment: .leading, spacing: 0) {
                                    let reviewLayout = dynamicTypeSize.ppPrefersExpandedLayout
                                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: PPSpacing.small))
                                        : AnyLayout(HStackLayout(spacing: PPSpacing.small))
                                    reviewLayout {
                                        Text(
                                            !reviewsAllLines && reviewBlocks.isEmpty
                                                ? "No uncertain lines".localizedUI
                                                : AppLocalization.format(
                                                    reviewsAllLines ? "%lld lines" : "Review %lld uncertain lines",
                                                    reviewBlocks.count
                                                )
                                        )
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(PPColor.textSecondary)
                                        if !dynamicTypeSize.ppPrefersExpandedLayout {
                                            Spacer()
                                        }
                                        Button {
                                            if reviewsAllLines {
                                                allLinesPageIndices.remove(page.pageIndex)
                                            } else {
                                                allLinesPageIndices.insert(page.pageIndex)
                                            }
                                            reviewLineLimits[page.pageIndex] = 32
                                        } label: {
                                            Label(
                                                (reviewsAllLines ? "Uncertain lines" : "Review all lines").localizedUI,
                                                systemImage: "text.badge.checkmark"
                                            )
                                            .font(.caption.weight(.semibold))
                                            .frame(minHeight: 44)
                                        }
                                        .disabled(creationTask != nil)
                                    }

                                    ForEach(
                                        Array(reviewBlocks.prefix(visibleLimit))
                                    ) { block in
                                        Button {
                                            correctionTarget =
                                                OCRCorrectionTarget(
                                                    pageIndex:
                                                        page.pageIndex,
                                                    block: block
                                                )
                                        } label: {
                                            uncertainBlockRow(block)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(creationTask != nil)
                                        .accessibilityElement(
                                            children: .ignore
                                        )
                                        .accessibilityLabel(block.text)
                                        .accessibilityValue(
                                            AppLocalization.format(
                                                "%lld%% confidence",
                                                Int(
                                                    block.confidence
                                                        * 100
                                                )
                                            )
                                        )
                                        .accessibilityHint(
                                            "Opens text correction"
                                                .localizedUI
                                        )
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

                                    let remaining = reviewBlocks.count - visibleLimit
                                    if remaining > 0 {
                                        Button {
                                            reviewLineLimits[page.pageIndex] = min(reviewBlocks.count, visibleLimit + 32)
                                        } label: {
                                            Label(
                                                AppLocalization.format("Show more lines (%lld remaining)", remaining),
                                                systemImage: "chevron.down"
                                            )
                                            .font(.caption.weight(.semibold))
                                            .frame(minHeight: 44)
                                        }
                                    }
                                }
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if result.pages.contains(where: { !$0.blocks.isEmpty }) {
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    if let creationErrorMessage {
                        Label(
                            creationErrorMessage,
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.rose)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(
                        "Adds searchable text to the whole PDF. The original stays unchanged."
                            .localizedUI
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    searchableCopyButton
                }
                .frame(maxWidth: 880)
                .padding(.horizontal, PPSpacing.regular)
                .padding(.vertical, PPSpacing.small)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }

    private func recognizedPageText(_ page: OCRPageResult) -> some View {
        Text(page.text.isEmpty ? "No readable text".localizedUI : page.text)
            .font(.body)
            .foregroundStyle(
                page.text.isEmpty ? PPColor.textSecondary : PPColor.textPrimary
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func recognizedPageActions(_ page: OCRPageResult) -> some View {
        Button {
            onOpenPage(page.pageIndex)
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
        .disabled(creationTask != nil)
        .accessibilityValue(AppLocalization.format("Page %lld", page.pageIndex + 1))
        Button {
            copyRecognizedText(page.text)
        } label: {
            Label("Copy page text".localizedUI, systemImage: "doc.on.doc")
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityValue(AppLocalization.format("Page %lld", page.pageIndex + 1))
    }

    private var searchRequest: OCRSearchRequest {
        OCRSearchRequest(
            query: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            generation: searchGeneration
        )
    }

    private func searchRecognizedPages() async {
        let request = searchRequest
        guard scenePhase == .active, UIApplication.shared.isProtectedDataAvailable else { return }
        guard !request.query.isEmpty else {
            matchingPageIndices.removeAll()
            displayedSearchRequest = request
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(160))
            let pages = model.ocrResults[recordID]?.pages ?? []
            let worker = Task.detached(priority: .userInitiated) {
                var matches: Set<Int> = []
                for page in pages {
                    try Task.checkCancellation()
                    if page.text.localizedStandardContains(request.query) {
                        matches.insert(page.pageIndex)
                    }
                }
                return matches
            }
            let matches = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, searchRequest == request,
                  scenePhase == .active, UIApplication.shared.isProtectedDataAvailable
            else { return }
            matchingPageIndices = matches
            displayedSearchRequest = request
        } catch {
            return
        }
    }

    private func recognitionEmptyState(
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: PPSpacing.medium) {
            PPEmptyState(
                kind: .search,
                title: title,
                message: message
            )
            Button {
                onRecognizeAgain()
            } label: {
                Label(
                    "Recognize Again",
                    systemImage: "arrow.clockwise"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .accessibilityIdentifier("recognizeAgainFromEmptyState")
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private func recognitionRestoreFailureState(
        _ message: String
    ) -> some View {
        VStack(spacing: PPSpacing.medium) {
            PPEmptyState(
                kind: .workspace,
                title: "Recognized text unavailable",
                message: message
            )
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    restoreRecognizedTextButton
                    recognizeAgainButton
                }
                VStack(spacing: PPSpacing.small) {
                    restoreRecognizedTextButton
                    recognizeAgainButton
                }
            }
        }
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
    }

    private var restoreRecognizedTextButton: some View {
        Button {
            restorationRequestToken = UUID()
        } label: {
            Label(
                "Load Text Again",
                systemImage: "arrow.clockwise"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPQuietButtonStyle(tint: PPColor.cyan))
        .disabled(isRestoringText)
        .accessibilityIdentifier("retryRecognizedTextRestore")
    }

    private var restorationRequest: OCRRestorationRequest {
        OCRRestorationRequest(
            contentRevisionID: model.record(id: recordID)?
                .contentRevisionID,
            requestToken: restorationRequestToken
        )
    }

    private var recognizeAgainButton: some View {
        Button {
            onRecognizeAgain()
        } label: {
            Label(
                "Recognize Again",
                systemImage: "text.viewfinder"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(isRestoringText || creationTask != nil)
    }

    private func restoreRecognizedText() async {
        let requestedRevisionID = model.record(id: recordID)?
            .contentRevisionID
        isRestoringText = true
        restorationErrorMessage = nil
        await model.ensureAnalysisLoaded(for: recordID)
        guard !Task.isCancelled,
              model.record(id: recordID)?.contentRevisionID
                == requestedRevisionID
        else { return }
        if model.ocrResults[recordID] == nil {
            restorationErrorMessage =
                "The saved on-device recognition result could not be restored."
                    .localizedUI
        }
        isRestoringText = false
    }

    @ViewBuilder
    private func uncertainBlockRow(
        _ block: OCRTextBlock
    ) -> some View {
        if dynamicTypeSize.ppPrefersExpandedLayout {
            VStack(alignment: .leading, spacing: 4) {
                uncertainBlockText(block)
                HStack(spacing: PPSpacing.small) {
                    confidenceLabel(block.confidence)
                    Image(systemName: "pencil")
                        .foregroundStyle(PPColor.accent)
                }
            }
            .frame(
                maxWidth: .infinity,
                minHeight: 44,
                alignment: .leading
            )
            .contentShape(Rectangle())
        } else {
            HStack(
                alignment: .firstTextBaseline,
                spacing: PPSpacing.small
            ) {
                uncertainBlockText(block)
                Spacer(minLength: 12)
                confidenceLabel(block.confidence)
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(PPColor.accent)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    private func uncertainBlockText(
        _ block: OCRTextBlock
    ) -> some View {
        Text(block.text)
            .lineLimit(
                dynamicTypeSize.ppPrefersExpandedLayout ? 4 : 2
            )
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(PPColor.textPrimary)
    }

    private func confidenceLabel(
        _ confidence: Double
    ) -> some View {
        Text("\(Int(confidence * 100))%")
            .font(.caption.monospacedDigit())
            .foregroundStyle(PPColor.amber)
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.82 { return PPColor.mint }
        if confidence >= 0.62 { return PPColor.amber }
        return PPColor.textSecondary
    }

    private func hasReadableText(in result: OCRResult) -> Bool {
        result.pages.contains {
            !$0.text.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        }
    }

    @ViewBuilder
    private func recognizedPagesFilter(
        pageCount: Int,
        reviewCount: Int
    ) -> some View {
        if reviewCount > 0 {
            let picker = Picker(
                "Recognized pages",
                selection: $showsReviewOnly
            ) {
                Text(
                    AppLocalization.format(
                        "All %lld",
                        pageCount
                    )
                )
                    .tag(false)
                Text(
                    AppLocalization.format(
                        "Review %lld",
                        reviewCount
                    )
                )
                    .tag(true)
            }
            if dynamicTypeSize.ppPrefersExpandedLayout {
                picker
                    .pickerStyle(.menu)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44,
                        alignment: .leading
                    )
                    .accessibilityLabel(
                        "Filter recognized pages".localizedUI
                    )
                    .accessibilityValue(
                        AppLocalization.format(
                            showsReviewOnly
                                ? "Review %lld"
                                : "All %lld",
                            showsReviewOnly
                                ? reviewCount
                                : pageCount
                        )
                    )
            } else {
                picker
                    .pickerStyle(.segmented)
                    .accessibilityLabel(
                        "Filter recognized pages".localizedUI
                    )
                    .accessibilityValue(
                        AppLocalization.format(
                            showsReviewOnly
                                ? "Review %lld"
                                : "All %lld",
                            showsReviewOnly
                                ? reviewCount
                                : pageCount
                        )
                    )
            }
        }
    }

    private var searchableCopyButton: some View {
        Button {
            createSearchableCopy()
        } label: {
            Group {
                if creationTask != nil {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        if let progress = model.progress(for: recordID) {
                            Text(
                                AppLocalization.format(
                                    "%lld%%",
                                    Int(
                                        progress.fractionCompleted
                                            * 100
                                    )
                                )
                            )
                            .monospacedDigit()
                        }
                    }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "Creating searchable copy".localizedUI
                        )
                        .accessibilityValue(
                            searchableCreationProgressValue
                        )
                } else {
                    Label(
                        "Create Searchable Copy",
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .lineLimit(2)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            model.isProcessing(recordID)
                || creationTask != nil
        )
        .accessibilityIdentifier("createSearchableCopyButton")
    }

    private var searchableCreationProgressValue: String {
        guard let progress = model.progress(for: recordID) else {
            return "In progress".localizedUI
        }
        return AppLocalization.format(
            "%lld%%",
            Int(progress.fractionCompleted * 100)
        )
    }

    private func createSearchableCopy() {
        guard creationTask == nil,
              let sourceContentRevisionID =
                model.record(id: recordID)?.contentRevisionID,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        creationErrorMessage = nil
        creationStopRequested = false
        let generation = UUID()
        creationGeneration = generation
        creationTask = Task { @MainActor in
            let created = await model.withFeedbackTarget(paperPathSceneID) {
                await model.createSearchableCopy(
                    recordID: recordID,
                    expectedContentRevisionID:
                        sourceContentRevisionID
                )
            }
            guard creationGeneration == generation else { return }
            let wasStopped =
                creationStopRequested || Task.isCancelled
            creationTask = nil
            creationStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    created == nil
                        ? "Copy creation stopped"
                        : "Copy finished before stopping · copy kept in Library"
                ).localizedUI
                return
            }
            guard let created else {
                creationErrorMessage =
                    "The searchable copy could not be created. Try again."
                        .localizedUI
                creationErrorFeedback += 1
                return
            }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func interruptSearchableCopyCreation(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            creationGeneration = UUID()
            creationStopRequested = false
        } else {
            guard creationTask != nil,
                  !creationStopRequested
            else { return }
            creationStopRequested = true
        }
        creationTask?.cancel()
        if invalidateResult {
            creationTask = nil
            creationErrorMessage = nil
        }
    }
}

private struct OCRTextCorrectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let pageIndex: Int
    let block: OCRTextBlock
    let onSave: (String) async -> Bool

    @State private var text: String
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?
    @State private var saveGeneration = UUID()
    @State private var saveStopRequested = false
    @State private var committedText: String
    @State private var saveErrorMessage: String?
    @State private var saveStatusMessage: String?
    @State private var saveErrorFeedback = 0
    @State private var isConfirmingDiscard = false
    @FocusState private var isTextFocused: Bool

    init(
        pageIndex: Int,
        block: OCRTextBlock,
        onSave: @escaping (String) async -> Bool
    ) {
        self.pageIndex = pageIndex
        self.block = block
        self.onSave = onSave
        _text = State(initialValue: block.text)
        _committedText = State(initialValue: block.text)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.sentences)
                        .disabled(isSaving)
                        .focused($isTextFocused)
                        .accessibilityLabel("Recognized line")
                    HStack {
                        if saveStopRequested {
                            Label(
                                "Finishing current file commit".localizedUI,
                                systemImage: "hourglass"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.textSecondary)
                            .accessibilityAddTraits(.updatesFrequently)
                        }
                        if let saveErrorMessage {
                            Label(
                                saveErrorMessage,
                                systemImage: "exclamationmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.rose)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                        }
                        if let saveStatusMessage {
                            Label(
                                saveStatusMessage,
                                systemImage: "checkmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.mint)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                        }
                        Spacer(minLength: PPSpacing.small)
                        PasteButton(
                            payloadType: String.self
                        ) { values in
                            guard let value = values.first else {
                                return
                            }
                            text = String(value.prefix(500))
                        }
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(isSaving)
                        .accessibilityLabel(
                            "Paste recognized text correction"
                        )
                    }
                } header: {
                    Text("Recognized line")
                } footer: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            AppLocalization.format(
                                "Page %lld · Vision confidence %lld%% · %lld/500",
                                pageIndex + 1,
                                Int(block.confidence * 100),
                                text.count
                            )
                        )
                        Text(
                            "The correction stays on this device."
                                .localizedUI
                        )
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Correct Recognition")
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
                        if saveTask != nil {
                            interruptCorrectionSave()
                        } else {
                            requestCorrectionDismissal()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saveStopRequested)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard scenePhase == .active,
                              UIApplication.shared
                                .isProtectedDataAvailable
                        else { return }
                        saveErrorMessage = nil
                        saveStatusMessage = nil
                        isSaving = true
                        saveStopRequested = false
                        let generation = UUID()
                        let value = correctionValue
                        saveGeneration = generation
                        saveTask = Task { @MainActor in
                            let saved = await onSave(value)
                            guard saveGeneration == generation else {
                                return
                            }
                            let wasStopped =
                                saveStopRequested || Task.isCancelled
                            isSaving = false
                            saveTask = nil
                            saveStopRequested = false
                            if wasStopped {
                                if saved {
                                    committedText = value
                                }
                                saveErrorMessage = nil
                                saveStatusMessage = (
                                    saved
                                        ? "Correction finished before stopping · changes kept"
                                        : "Correction save stopped"
                                ).localizedUI
                                return
                            }
                            if saved {
                                dismiss()
                            } else {
                                saveErrorMessage =
                                    "The correction could not be saved. Review the text and try again."
                                        .localizedUI
                                saveErrorFeedback += 1
                            }
                        }
                    }
                    .disabled(
                        isSaving
                            || correctionValue.isEmpty
                            || !hasCorrectionChanges
                    )
                    .keyboardShortcut(.defaultAction)
                }
            }
            .onChange(of: text) { _, value in
                if value.count > 500 {
                    text = String(value.prefix(500))
                }
                saveErrorMessage = nil
                if correctionValue != committedText {
                    saveStatusMessage = nil
                }
            }
            .task {
                await Task.yield()
                guard !Task.isCancelled else { return }
                isTextFocused = true
            }
            .confirmationDialog(
                "Discard correction?".localizedUI,
                isPresented: $isConfirmingDiscard,
                titleVisibility: .visible
            ) {
                Button(
                    "Discard Changes".localizedUI,
                    role: .destructive
                ) {
                    dismiss()
                }
                Button("Keep Editing".localizedUI, role: .cancel) {}
            } message: {
                Text(
                    "The recognized text correction has not been saved."
                        .localizedUI
                )
            }
            .interactiveDismissDisabled(
                isSaving || hasCorrectionChanges
            )
            .accessibilityAction(.escape) {
                if isSaving {
                    interruptCorrectionSave()
                } else {
                    requestCorrectionDismissal()
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                interruptProtectedCorrection()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptProtectedCorrection()
            }
            .onDisappear {
                interruptCorrectionSave(invalidateResult: true)
                text = ""
                saveErrorMessage = nil
                saveStatusMessage = nil
            }
            .sensoryFeedback(.error, trigger: saveErrorFeedback)
        }
    }

    private var correctionValue: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasCorrectionChanges: Bool {
        correctionValue
            != committedText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }

    private func requestCorrectionDismissal() {
        if hasCorrectionChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func interruptCorrectionSave(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            saveGeneration = UUID()
            saveStopRequested = false
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
        }
    }

    private func interruptProtectedCorrection() {
        interruptCorrectionSave(invalidateResult: true)
        text = ""
        dismiss()
    }
}

struct OCRConfigurationSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("privacy.hideLibraryPreviews") private var hideLibraryPreviews = false

    let recordID: UUID?
    let onStart: (OCRRecognitionConfiguration) -> Void

    @State private var mode: OCRLanguageMode
    @State private var selectedLanguages: Set<String>
    @State private var customWordsText: String
    @State private var recoverySummary: OCRRecoverySummary?
    @State private var recoveryError: String?
    @State private var isLoadingRecovery = true
    @State private var recoveryRequest = UUID()
    @State private var isConfirmingReplacement = false
    @State private var pendingConfiguration: OCRRecognitionConfiguration?
    @State private var showsCustomTerms: Bool

    init(
        recordID: UUID? = nil,
        initialConfiguration: OCRRecognitionConfiguration = .automatic,
        onStart: @escaping (OCRRecognitionConfiguration) -> Void
    ) {
        self.recordID = recordID
        self.onStart = onStart
        _mode = State(
            initialValue: initialConfiguration.languageMode
        )
        let supportedLanguages = Set(
            OCRRecognitionLanguage.allCases.map(\.rawValue)
        )
        _selectedLanguages = State(
            initialValue: Set(
                initialConfiguration.languageIdentifiers.filter(
                    supportedLanguages.contains
                )
            )
        )
        _customWordsText = State(
            initialValue:
                initialConfiguration.customWords
                    .joined(separator: "\n")
        )
        _showsCustomTerms = State(
            initialValue: !initialConfiguration.customWords.isEmpty
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
                        recognitionDocument

                        if isLoadingRecovery {
                            ProgressView("Checking saved recognition".localizedUI)
                                .font(.subheadline)
                        } else if let summary = currentRecoverySummary,
                                  summary.completedPageCount > 0 || summary.damagedPageCount > 0 {
                            recoveryDetails(summary)
                        }
                        if let recoveryError {
                            VStack(alignment: .leading, spacing: PPSpacing.small) {
                                Label(recoveryError, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(PPColor.amber)
                                Button("Retry".localizedUI) { recoveryRequest = UUID() }
                                    .buttonStyle(PPQuietButtonStyle())
                            }
                        }

                        let picker = Picker(
                            "Recognition language",
                            selection: $mode
                        ) {
                            ForEach(
                                OCRLanguageMode.allCases
                            ) { option in
                                Text(option.title.localizedUI)
                                    .tag(option)
                            }
                        }
                        if dynamicTypeSize.ppPrefersExpandedLayout {
                            picker
                                .pickerStyle(.menu)
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: 44,
                                    alignment: .leading
                                )
                                .accessibilityIdentifier(
                                    "ocrLanguageMode"
                                )
                        } else {
                            picker
                                .pickerStyle(.segmented)
                                .accessibilityIdentifier(
                                    "ocrLanguageMode"
                                )
                        }

                        if mode == .selected {
                            LazyVGrid(
                                columns: dynamicTypeSize.ppPrefersExpandedLayout
                                    ? [GridItem(.flexible())]
                                    : [
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
                                    .accessibilityHint(
                                        languageSelectionHint(language)
                                    )
                                    .accessibilityIdentifier(
                                        "ocrLanguage-\(language.rawValue)"
                                    )
                                }
                            }
                        }

                        DisclosureGroup(isExpanded: $showsCustomTerms) {
                        ViewThatFits(in: .horizontal) {
                            HStack(
                                alignment: .top,
                                spacing: PPSpacing.small
                            ) {
                                customWordsField
                                customWordsPasteButton
                            }
                            VStack(
                                alignment: .trailing,
                                spacing: PPSpacing.small
                            ) {
                                customWordsField
                                customWordsPasteButton
                            }
                        }

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
                        } label: {
                            HStack(spacing: PPSpacing.small) {
                                Label(
                                    "Custom Terms".localizedUI,
                                    systemImage: "text.badge.plus"
                                )
                                Spacer()
                                if !customWords.isEmpty {
                                    Text("\(customWords.count)")
                                        .monospacedDigit()
                                        .foregroundStyle(PPColor.textSecondary)
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("ocrCustomTerms")

                        if let configurationValidationMessage {
                            Label(
                                configurationValidationMessage,
                                systemImage: "exclamationmark.circle"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PPColor.rose)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                            .accessibilityIdentifier(
                                "ocrConfigurationValidation"
                            )
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 72)
                    .frame(maxWidth: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    if let summary = currentRecoverySummary,
                       summary.completedPageCount > 0,
                       summary.identity.configuration != currentConfiguration {
                        pendingConfiguration = currentConfiguration
                        isConfirmingReplacement = true
                    } else {
                        onStart(currentConfiguration)
                    }
                } label: {
                    Label(
                        (currentSavedPageCount > 0
                            ? "Resume Recognition"
                            : "Recognize on Device").localizedUI,
                        systemImage: currentSavedPageCount > 0
                            ? "arrow.clockwise"
                            : "text.viewfinder"
                    )
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(!canStart || isLoadingRecovery || recoveryError != nil
                    || scenePhase != .active)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(recognitionStartHint)
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
                        .keyboardShortcut(.cancelAction)
                }
            }
            .accessibilityAction(.escape) {
                dismiss()
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
        .confirmationDialog(
            "Replace saved recognition progress?",
            isPresented: $isConfirmingReplacement,
            titleVisibility: .visible
        ) {
            Button("Recognize with New Settings".localizedUI, role: .destructive) {
                guard scenePhase == .active,
                      let pendingConfiguration,
                      pendingConfiguration == currentConfiguration,
                      currentRecoverySummary != nil else { return }
                onStart(pendingConfiguration)
                self.pendingConfiguration = nil
            }
            Button("Cancel", role: .cancel) { pendingConfiguration = nil }
        } message: {
            Text("Saved page progress will be replaced. Existing PDFs and completed text results stay unchanged.")
        }
        .task(id: recoveryRequest) {
            let request = recoveryRequest
            recoverySummary = nil
            isLoadingRecovery = true
            recoveryError = nil
            defer {
                if recoveryRequest == request { isLoadingRecovery = false }
            }
            guard let recordID, scenePhase == .active else { return }
            do {
                let summary = try await model.ocrRecoverySummary(recordID: recordID)
                try Task.checkCancellation()
                guard scenePhase == .active, recoveryRequest == request else { return }
                recoverySummary = summary
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                recoveryError = "Saved recognition progress could not be read.".localizedUI
            }
        }
        .onChange(of: recordID.flatMap { model.record(id: $0)?.contentRevisionID }) { _, _ in
            clearRecoveryState()
            recoveryRequest = UUID()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                recoveryRequest = UUID()
            } else {
                clearRecoveryState()
                if phase == .background {
                    customWordsText = ""
                    dismiss()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataWillBecomeUnavailableNotification
        )) { _ in
            clearRecoveryState()
            customWordsText = ""
            dismiss()
        }
    }

    private var currentConfiguration: OCRRecognitionConfiguration {
        OCRRecognitionConfiguration(
            languageMode: mode,
            languageIdentifiers: mode == .selected ? selectedLanguages.sorted() : [],
            customWords: customWords
        )
    }

    @ViewBuilder
    private var recognitionDocument: some View {
        if let recordID, let record = model.record(id: recordID) {
            let layout = dynamicTypeSize.ppPrefersExpandedLayout
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: PPSpacing.small))
                : AnyLayout(HStackLayout(spacing: PPSpacing.medium))
            layout {
                if !hideLibraryPreviews, !record.profile.isLocked,
                   !dynamicTypeSize.ppPrefersExpandedLayout,
                   let url = model.url(for: recordID) {
                    PDFPageThumbnailView(
                        url: url, pageIndex: 0,
                        refreshToken: model.refreshToken(for: recordID), width: 48
                    )
                } else {
                    Image(systemName: hideLibraryPreviews ? "eye.slash" : "text.viewfinder")
                        .font(.title2)
                        .foregroundStyle(PPColor.mint)
                        .frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.displayName)
                        .font(.headline)
                        .foregroundStyle(PPColor.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(record.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var currentSavedPageCount: Int {
        guard let summary = currentRecoverySummary,
              summary.identity.configuration == currentConfiguration else { return 0 }
        return summary.completedPageCount
    }

    private var currentRecoverySummary: OCRRecoverySummary? {
        guard let summary = recoverySummary, let recordID,
              model.record(id: recordID)?.contentRevisionID == summary.identity.revisionID
        else { return nil }
        return summary
    }

    private func clearRecoveryState() {
        recoverySummary = nil
        pendingConfiguration = nil
        isConfirmingReplacement = false
        recoveryError = nil
    }

    private func recoveryDetails(_ summary: OCRRecoverySummary) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            Label(
                AppLocalization.format("%lld pages saved for recognition", summary.completedPageCount),
                systemImage: "arrow.clockwise.circle"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PPColor.mint)
            .accessibilityIdentifier("ocrSavedPageCount")
            if summary.damagedPageCount > 0 {
                Text(AppLocalization.format(
                    "%lld saved pages need recognition again", summary.damagedPageCount
                ))
                .font(.caption)
                .foregroundStyle(PPColor.amber)
            }
            if summary.identity.configuration != currentConfiguration {
                Text(summary.identity.configuration.languageSummary)
                    .font(.subheadline)
                    .foregroundStyle(PPColor.textSecondary)
                Text(AppLocalization.format(
                    "%lld saved custom terms", summary.identity.configuration.customWords.count
                ))
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                Button {
                    let saved = summary.identity.configuration
                    mode = saved.languageMode
                    selectedLanguages = Set(saved.languageIdentifiers)
                    customWordsText = saved.customWords.joined(separator: "\n")
                } label: {
                    Label("Use Saved Settings".localizedUI, systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.mint))
                .accessibilityIdentifier("restoreOCRSettings")
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

    private var customWordsField: some View {
        TextField(
            "Names or terms, one per line",
            text: $customWordsText,
            axis: .vertical
        )
        .lineLimit(3...7)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .accessibilityIdentifier("ocrCustomWords")
    }

    private var customWordsPasteButton: some View {
        PasteButton(payloadType: String.self) { values in
            guard let value = values.first else { return }
            let prefix = customWordsText.isEmpty ? "" : "\n"
            customWordsText = String(
                (customWordsText + prefix + value).prefix(3_200)
            )
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint(
            "Adds copied terms to the local vocabulary"
        )
    }

    private var customWordsAreValid: Bool {
        customWords.count <= 50
            && customWords.allSatisfy { $0.count <= 64 }
            && customWords.reduce(0) { $0 + $1.count } <= 2_048
    }

    private var configurationValidationMessage: String? {
        if mode == .selected, selectedLanguages.isEmpty {
            return "Choose at least one recognition language."
                .localizedUI
        }
        if customWords.count > 50 {
            return "Use up to 50 custom terms.".localizedUI
        }
        if customWords.contains(where: { $0.count > 64 }) {
            return "Each custom term can contain up to 64 characters."
                .localizedUI
        }
        if customWords.reduce(0, { $0 + $1.count }) > 2_048 {
            return "Custom terms can contain up to 2,048 characters in total."
                .localizedUI
        }
        return nil
    }

    private var recognitionStartHint: String {
        configurationValidationMessage
            ?? "Starts recognition locally on this device.".localizedUI
    }

    private func languageSelectionHint(
        _ language: OCRRecognitionLanguage
    ) -> String {
        if !selectedLanguages.contains(language.rawValue),
           selectedLanguages.count >= 4 {
            return "Remove a selected language before adding another."
                .localizedUI
        }
        return selectedLanguages.contains(language.rawValue)
            ? "Double tap to remove this language.".localizedUI
            : "Double tap to add this language.".localizedUI
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
