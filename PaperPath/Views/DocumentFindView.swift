import SwiftUI

private struct DocumentFindSearchRequest: Hashable {
    let query: String
    let contentRevisionID: UUID?
    let indexedAt: Date?
    let indexedPageCount: Int
    let lifecycleGeneration: UUID
    let reloadToken: UUID
}

struct DocumentFindView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    let recordID: UUID
    let onSelectResult: (DocumentTextMatch?, String) -> Void
    let onQueryChange: (String) -> Void
    let onHistoryChange: ([String]) -> Void
    let onRecognizeText: () -> Void
    @State private var query: String
    @State private var results: [DocumentTextMatch] = []
    @State private var findHistory: [String]
    @State private var preferredPageIndex: Int?
    @State private var isSearching = false
    @State private var isResultLimited = false
    @State private var isIndexTruncated = false
    @State private var needsSearchableText = false
    @State private var selectedResultIndex: Int?
    @State private var resultsContentRevisionID: UUID?
    @State private var resultsQuery = ""
    @State private var searchGeneration = UUID()
    @State private var searchLifecycleGeneration = UUID()
    @State private var searchReloadToken = UUID()
    @State private var isSearchLifecycleSuspended = false
    @State private var searchErrorMessage: String?
    @State private var searchErrorFeedback = 0
    @State private var preservesHighlightOnDismiss = false
    @AccessibilityFocusState private var focusedResultIndex: Int?

    init(
        recordID: UUID,
        initialQuery: String = "",
        initialHistory: [String] = [],
        initialSelectedPageIndex: Int? = nil,
        onQueryChange: @escaping (String) -> Void = { _ in },
        onHistoryChange: @escaping ([String]) -> Void = { _ in },
        onRecognizeText: @escaping () -> Void = {},
        onSelectResult: @escaping (
            DocumentTextMatch?,
            String
        ) -> Void
    ) {
        self.recordID = recordID
        self.onQueryChange = onQueryChange
        self.onHistoryChange = onHistoryChange
        self.onRecognizeText = onRecognizeText
        self.onSelectResult = onSelectResult
        _query = State(
            initialValue: String(initialQuery.prefix(200))
        )
        _findHistory = State(
            initialValue: Array(
                initialHistory
                    .map { String($0.prefix(100)) }
                    .filter { !$0.isEmpty }
                    .prefix(5)
            )
        )
        _preferredPageIndex = State(
            initialValue: initialSelectedPageIndex
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if normalizedQuery.isEmpty {
                    PPEmptyState(
                        kind: .search,
                        title: "Find in document",
                        message: "Search the private on-device text index."
                    )
                    .padding(PPSpacing.regular)
                } else if isSearching {
                    ProgressView("Searching on device".localizedUI)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(PPSpacing.regular)
                } else if let searchErrorMessage {
                    VStack(spacing: PPSpacing.medium) {
                        PPEmptyState(
                            kind: .tools,
                            title: "Search did not finish",
                            message: searchErrorMessage
                        )
                        Button {
                            self.searchErrorMessage = nil
                            searchReloadToken = UUID()
                        } label: {
                            Label(
                                "Search Again",
                                systemImage: "arrow.clockwise"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(
                            PPQuietButtonStyle(tint: PPColor.cyan)
                        )
                        .accessibilityIdentifier(
                            "documentFindRetrySearch"
                        )
                    }
                    .frame(maxWidth: 520)
                    .padding(PPSpacing.regular)
                } else if results.isEmpty {
                    VStack(spacing: PPSpacing.medium) {
                        PPEmptyState(
                            kind: .search,
                            title: needsSearchableText
                                ? "Search needs text"
                                : "No match found",
                            message: needsSearchableText
                                ? "Run local recognition to add a searchable text layer to this private copy."
                                : isIndexTruncated
                                    ? "No match was found in the indexed portion of this PDF."
                                    : "Try a shorter phrase or search for a distinctive word in this PDF."
                        )
                        if needsSearchableText {
                            Button {
                                onRecognizeText()
                            } label: {
                                Label(
                                    "Recognize Text",
                                    systemImage: "viewfinder"
                                )
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PPPrimaryButtonStyle())
                            .accessibilityIdentifier(
                                "documentFindRecognizeText"
                            )
                        }
                        Button {
                            query = ""
                            dismissSearch()
                        } label: {
                            Label(
                                "Clear Search",
                                systemImage: "xmark.circle"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(
                            PPQuietButtonStyle(tint: PPColor.cyan)
                        )
                        .accessibilityIdentifier(
                            "documentFindClearSearch"
                        )
                    }
                    .frame(maxWidth: 520)
                    .padding(PPSpacing.regular)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            if isIndexTruncated {
                                Section {
                                    Label(
                                        "This PDF reached the local text index limit",
                                        systemImage:
                                            "exclamationmark.triangle"
                                    )
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PPColor.amber)
                                    .accessibilityHint(
                                        "Search results may not cover the entire PDF."
                                            .localizedUI
                                    )
                                }
                            }
                            Section {
                                ForEach(
                                    Array(results.enumerated()),
                                    id: \.offset
                                ) { index, page in
                                    Button {
                                        previewResult(at: index)
                                    } label: {
                                        VStack(
                                            alignment: .leading,
                                            spacing: PPSpacing.small
                                        ) {
                                            let headerLayout =
                                                dynamicTypeSize
                                                    .ppPrefersExpandedLayout
                                                ? AnyLayout(
                                                    VStackLayout(
                                                        alignment: .leading,
                                                        spacing: 2
                                                    )
                                                )
                                                : AnyLayout(
                                                    HStackLayout(
                                                        spacing:
                                                            PPSpacing.small
                                                    )
                                                )
                                            headerLayout {
                                                Label(
                                                    "Page \(page.pageIndex + 1)",
                                                    systemImage:
                                                        "doc.text"
                                                )
                                                .font(
                                                    .caption
                                                        .smallCaps()
                                                        .weight(.semibold)
                                                )
                                                .foregroundStyle(
                                                    PPColor.cyan
                                                )
                                                if !dynamicTypeSize
                                                    .ppPrefersExpandedLayout {
                                                    Spacer()
                                                }
                                                Text(
                                                    "\(index + 1) of \(results.count)"
                                                )
                                                .font(
                                                    .caption2
                                                        .monospacedDigit()
                                                )
                                                .foregroundStyle(
                                                    PPColor.textSecondary
                                                )
                                            }
                                            Text(
                                                highlightedSnippet(
                                                    from: page.excerpt
                                                )
                                            )
                                            .font(.body)
                                            .foregroundStyle(
                                                PPColor.textPrimary
                                            )
                                            .lineLimit(
                                                dynamicTypeSize.isAccessibilitySize
                                                    ? nil : 4
                                            )
                                            .multilineTextAlignment(
                                                .leading
                                            )
                                        }
                                        .padding(.horizontal, PPSpacing.small)
                                        .padding(.vertical, PPSpacing.small)
                                        .background(
                                            selectedResultIndex == index
                                                ? PPColor.cyan.opacity(0.08)
                                                : Color.clear
                                        )
                                        .overlay(alignment: .leading) {
                                            if selectedResultIndex == index {
                                                Rectangle()
                                                    .fill(PPColor.cyan)
                                                    .frame(width: 2)
                                                    .padding(.vertical, 5)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .id(index)
                                    .buttonStyle(.plain)
                                    .disabled(!resultsTargetCurrentRevision)
                                    .accessibilityLabel(
                                        AppLocalization.format(
                                            "Page %lld, result %lld of %lld",
                                            page.pageIndex + 1,
                                            index + 1,
                                            results.count
                                        )
                                    )
                                    .accessibilityHint(page.excerpt)
                                    .accessibilityValue(
                                        selectedResultIndex == index
                                            ? "Previewing".localizedUI
                                            : ""
                                    )
                                    .accessibilityFocused(
                                        $focusedResultIndex,
                                        equals: index
                                    )
                                    .accessibilityIdentifier(
                                        "documentFindResult-\(index)"
                                    )
                                }
                            } header: {
                                Label(
                                    resultCountTitle,
                                    systemImage: "text.magnifyingglass"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PPColor.textSecondary)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .scrollDismissesKeyboard(.interactively)
                        .onAppear {
                            scrollToSelectedResult(
                                selectedResultIndex,
                                using: proxy
                            )
                        }
                        .onChange(of: selectedResultIndex) { _, index in
                            scrollToSelectedResult(
                                index,
                                using: proxy
                            )
                        }
                    }
                }
            }
            .background(PPColor.canvas)
            .navigationTitle("Find")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search this document"
            )
            .searchSuggestions {
                if query
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty,
                   !findHistory.isEmpty {
                    Section("Recent in This PDF") {
                        ForEach(findHistory, id: \.self) { value in
                            Button {
                                query = value
                                recordSearch(value)
                            } label: {
                                Label(
                                    value,
                                    systemImage:
                                        "clock.arrow.circlepath"
                                )
                            }
                            .accessibilityIdentifier(
                                "documentFindHistory-\(value)"
                            )
                        }
                        Button(role: .destructive) {
                            clearFindHistory()
                        } label: {
                            Label(
                                "Clear This History",
                                systemImage: "trash"
                            )
                        }
                        .accessibilityIdentifier(
                            "documentFindClearHistory"
                        )
                    }
                }
            }
            .onSubmit(of: .search) {
                recordSearch(query)
                dismissSearch()
            }
            .onChange(of: query) { _, value in
                let bounded = String(value.prefix(200))
                if value != bounded {
                    query = bounded
                    onQueryChange(bounded)
                    return
                }
                onQueryChange(value)
            }
            .task(id: searchRequest) {
                let request = searchRequest
                let generation = UUID()
                searchGeneration = generation
                let searchQuery = request.query
                let previouslySelectedPage =
                    selectedResultIndex.flatMap {
                        results.indices.contains($0)
                            ? results[$0].pageIndex
                            : nil
                    } ?? preferredPageIndex
                let terms = searchQuery
                    .split(whereSeparator: \.isWhitespace)
                guard !terms.isEmpty else {
                    results = []
                    resultsContentRevisionID = nil
                    isSearching = false
                    searchErrorMessage = nil
                    isResultLimited = false
                    isIndexTruncated = false
                    needsSearchableText = false
                    selectedResultIndex = nil
                    focusedResultIndex = nil
                    onSelectResult(nil, "")
                    return
                }
                guard !isSearchLifecycleSuspended,
                      scenePhase == .active,
                      UIApplication.shared.isProtectedDataAvailable,
                      request.contentRevisionID != nil
                else {
                    onSelectResult(nil, "")
                    clearSearchResults()
                    return
                }
                preservesHighlightOnDismiss = false
                onSelectResult(nil, searchQuery)
                isSearching = true
                searchErrorMessage = nil
                isResultLimited = false
                isIndexTruncated = false
                needsSearchableText = false
                results.removeAll(keepingCapacity: false)
                resultsContentRevisionID = nil
                selectedResultIndex = nil
                focusedResultIndex = nil
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                await model.ensureAnalysisLoaded(for: recordID)
                guard !Task.isCancelled else { return }
                guard let index = model.textIndices[recordID] else {
                    guard searchGeneration == generation,
                          searchRequest == request
                    else { return }
                    results = []
                    isSearching = false
                    searchErrorMessage = nil
                    isResultLimited = false
                    needsSearchableText = true
                    onSelectResult(nil, searchQuery)
                    return
                }
                let worker = Task.detached(
                    priority: .userInitiated
                ) { () throws -> (
                    matches: [DocumentTextMatch],
                    limited: Bool,
                    truncated: Bool,
                    hasText: Bool
                ) in
                    let resultLimit = 200
                    try Task.checkCancellation()
                    var hasText = false
                    for page in index.pages {
                        try Task.checkCancellation()
                        if page.text.contains(where: { !$0.isWhitespace }) {
                            hasText = true
                            break
                        }
                    }
                    let matches = try index.cancellableMatches(
                        for: searchQuery,
                        excerptLimit: 220,
                        limit: resultLimit + 1
                    )
                    try Task.checkCancellation()
                    return (
                        Array(matches.prefix(resultLimit)),
                        matches.count > resultLimit,
                        index.hasTruncatedContent,
                        hasText
                    )
                }
                do {
                    let searchResult =
                        try await withTaskCancellationHandler {
                            try await worker.value
                        } onCancel: {
                            worker.cancel()
                        }
                    try Task.checkCancellation()
                    guard searchGeneration == generation,
                          searchRequest == request
                    else { return }
                    results = searchResult.matches
                    resultsContentRevisionID =
                        request.contentRevisionID
                    resultsQuery = searchQuery
                    isResultLimited = searchResult.limited
                    isIndexTruncated = searchResult.truncated
                    needsSearchableText = !searchResult.hasText
                    searchErrorMessage = nil
                    isSearching = false
                    if let selection = previouslySelectedPage.flatMap({
                        pageIndex in
                        results.firstIndex {
                            $0.pageIndex == pageIndex
                        }
                    }) ?? results.indices.first {
                        previewResult(
                            at: selection,
                            recordsSearch: false
                        )
                    } else {
                        onSelectResult(nil, searchQuery)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard searchGeneration == generation,
                          searchRequest == request
                    else { return }
                    results = []
                    isResultLimited = false
                    isSearching = false
                    needsSearchableText = false
                    selectedResultIndex = nil
                    searchErrorMessage =
                        "The local text index could not be searched. Try again."
                            .localizedUI
                    searchErrorFeedback &+= 1
                    onSelectResult(nil, searchQuery)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    interruptSearch(clearsQuery: true)
                } else if phase == .active {
                    isSearchLifecycleSuspended = false
                    searchLifecycleGeneration = UUID()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptSearch(clearsQuery: true)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataDidBecomeAvailableNotification
                )
            ) { _ in
                guard scenePhase == .active else { return }
                isSearchLifecycleSuspended = false
                searchLifecycleGeneration = UUID()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        closeFind()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !results.isEmpty {
                    resultNavigator
                }
            }
        }
        .accessibilityAction(.escape) {
            closeFind()
        }
        .sensoryFeedback(.selection, trigger: selectedResultIndex)
        .sensoryFeedback(.error, trigger: searchErrorFeedback)
        .onDisappear {
            interruptSearch(
                clearsHighlight: !preservesHighlightOnDismiss,
                clearsQuery: false
            )
        }
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchRequest: DocumentFindSearchRequest {
        let index = model.textIndices[recordID]
        return DocumentFindSearchRequest(
            query: normalizedQuery,
            contentRevisionID: model.record(id: recordID)?
                .contentRevisionID,
            indexedAt: index?.indexedAt,
            indexedPageCount: index?.pages.count ?? 0,
            lifecycleGeneration: searchLifecycleGeneration,
            reloadToken: searchReloadToken
        )
    }

    private var resultCountTitle: String {
        if isResultLimited {
            return AppLocalization.format(
                "Showing first %lld matches",
                results.count
            )
        }
        return AppLocalization.format(
            "%lld matching pages",
            results.count
        )
    }

    private var resultNavigator: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(spacing: PPSpacing.xSmall) {
                    resultStepControls
                    viewPDFButton
                        .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    resultStepControls
                    Spacer(minLength: PPSpacing.small)
                    viewPDFButton
                }
            }
        }
        .padding(.horizontal, PPSpacing.regular)
        .padding(.vertical, PPSpacing.xSmall)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.68))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .contain)
        .disabled(!resultsTargetCurrentRevision)
        .accessibilityIdentifier("documentFindNavigator")
    }

    private var resultStepControls: some View {
        HStack(spacing: PPSpacing.small) {
            Button {
                moveSelection(by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(results.isEmpty)
            .keyboardShortcut(
                "g",
                modifiers: [.command, .shift]
            )
            .accessibilityLabel("Previous result")
            .help("Previous result".localizedUI)
            .accessibilityIdentifier("documentFindPrevious")

            Text(resultPositionTitle)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .frame(minWidth: 72)
                .contentTransition(.numericText())
                .accessibilityLabel("Result position".localizedUI)
                .accessibilityValue(resultPositionTitle)

            Button {
                moveSelection(by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(results.isEmpty)
            .keyboardShortcut("g", modifiers: .command)
            .accessibilityLabel("Next result")
            .help("Next result".localizedUI)
            .accessibilityIdentifier("documentFindNext")
        }
        .frame(maxWidth: .infinity)
    }

    private var viewPDFButton: some View {
        Button {
            guard resultsTargetCurrentRevision else {
                invalidateStaleResults()
                return
            }
            if selectedResultIndex == nil {
                previewResult(at: 0)
            }
            preservesHighlightOnDismiss = true
            dismiss()
        } label: {
            Label(
                "View PDF",
                systemImage: "doc.text.magnifyingglass"
            )
            .font(.caption.weight(.semibold))
            .frame(maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                ? .infinity
                : nil)
            .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(PPColor.cyan)
        .accessibilityHint(
            "Opens the selected match in the PDF."
                .localizedUI
        )
        .accessibilityIdentifier("documentFindViewPDF")
    }

    private var resultPositionTitle: String {
        guard let selectedResultIndex else {
            return AppLocalization.format(
                "%lld results",
                results.count
            )
        }
        return "\(selectedResultIndex + 1)/\(results.count)"
    }

    private func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        let nextIndex: Int
        if let selectedResultIndex {
            nextIndex = (
                selectedResultIndex + offset + results.count
            ) % results.count
        } else {
            nextIndex = offset > 0 ? 0 : results.count - 1
        }
        previewResult(at: nextIndex)
        focusedResultIndex = nextIndex
    }

    private func previewResult(
        at index: Int,
        recordsSearch: Bool = true
    ) {
        guard results.indices.contains(index),
              resultsTargetCurrentRevision
        else {
            invalidateStaleResults()
            return
        }
        if recordsSearch {
            dismissSearch()
        }
        selectedResultIndex = index
        preferredPageIndex = results[index].pageIndex
        if recordsSearch {
            recordSearch(query)
        }
        onSelectResult(results[index], normalizedQuery)
    }

    private var resultsTargetCurrentRevision: Bool {
        guard let resultsContentRevisionID,
              resultsQuery == normalizedQuery,
              !isSearchLifecycleSuspended,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return false }
        return model.record(id: recordID)?.contentRevisionID
            == resultsContentRevisionID
    }

    private func invalidateStaleResults() {
        onSelectResult(nil, normalizedQuery)
        clearSearchResults()
        searchErrorMessage =
            "The PDF changed before this action started. Review the updated PDF."
                .localizedUI
        searchErrorFeedback &+= 1
        searchReloadToken = UUID()
    }

    private func highlightedSnippet(
        from text: String
    ) -> AttributedString {
        var attributed = AttributedString(text)
        let terms = DocumentSearchNormalization.terms(
            in: normalizedQuery
        )
        var remainingHighlights = 32

        for term in terms {
            guard remainingHighlights > 0 else { break }
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  remainingHighlights > 0,
                  let range = text.range(
                      of: term,
                      options: [
                          .caseInsensitive,
                          .diacriticInsensitive,
                          .widthInsensitive
                      ],
                      range: searchStart..<text.endIndex
                  ) {
                if let lower = AttributedString.Index(
                    range.lowerBound,
                    within: attributed
                ),
                   let upper = AttributedString.Index(
                       range.upperBound,
                       within: attributed
                   ) {
                    attributed[lower..<upper].backgroundColor =
                        PPColor.amber.opacity(0.24)
                    attributed[lower..<upper].foregroundColor =
                        PPColor.textPrimary
                    attributed[lower..<upper].inlinePresentationIntent =
                        .stronglyEmphasized
                }
                remainingHighlights -= 1
                searchStart = range.upperBound
            }
        }
        return attributed
    }

    private func recordSearch(_ value: String) {
        let normalized = String(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(100)
        )
        guard !normalized.isEmpty else { return }

        findHistory.removeAll {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }
        findHistory.insert(normalized, at: 0)
        findHistory = Array(findHistory.prefix(5))
        onHistoryChange(findHistory)
    }

    private func clearFindHistory() {
        findHistory.removeAll(keepingCapacity: false)
        onHistoryChange([])
    }

    private func closeFind() {
        preservesHighlightOnDismiss = false
        onSelectResult(nil, "")
        dismiss()
    }

    private func scrollToSelectedResult(
        _ index: Int?,
        using proxy: ScrollViewProxy
    ) {
        guard let index, results.indices.contains(index) else {
            return
        }
        if reduceMotion {
            proxy.scrollTo(index, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func interruptSearch(
        clearsHighlight: Bool = true,
        clearsQuery: Bool = false
    ) {
        isSearchLifecycleSuspended = true
        searchLifecycleGeneration = UUID()
        searchGeneration = UUID()
        if clearsQuery {
            query = ""
            onQueryChange("")
            clearFindHistory()
            preferredPageIndex = nil
        }
        dismissSearch()
        if clearsHighlight {
            onSelectResult(nil, "")
        }
        clearSearchResults()
    }

    private func clearSearchResults() {
        results.removeAll(keepingCapacity: false)
        isSearching = false
        isResultLimited = false
        isIndexTruncated = false
        needsSearchableText = false
        searchErrorMessage = nil
        selectedResultIndex = nil
        resultsContentRevisionID = nil
        resultsQuery = ""
        focusedResultIndex = nil
    }
}
