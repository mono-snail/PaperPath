import SwiftUI

struct DocumentFindView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("document.findHistory")
    private var savedFindHistory = "{}"

    let recordID: UUID
    let onSelectPage: (Int) -> Void
    @State private var query = ""
    @State private var results: [DocumentTextMatch] = []
    @State private var isSearching = false
    @State private var isResultLimited = false
    @State private var selectedResultIndex: Int?

    var body: some View {
        NavigationStack {
            Group {
                if query.isEmpty {
                    PPEmptyState(
                        kind: .search,
                        title: "Find in document",
                        message: "Search the private on-device text index."
                    )
                    .padding(PPSpacing.regular)
                } else if isSearching {
                    PPEmptyState(
                        kind: .processing,
                        title: "Searching on device",
                        message: "PaperPath is checking the local text index."
                    )
                    .padding(PPSpacing.regular)
                } else if results.isEmpty {
                    PPEmptyState(
                        kind: .search,
                        title: "No match found",
                        message: "Try a shorter phrase or search for a distinctive word in this PDF."
                    )
                    .padding(PPSpacing.regular)
                } else {
                    List {
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
                                        HStack {
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
                                            Spacer()
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
                                        .lineLimit(4)
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
                                .buttonStyle(.plain)
                                .accessibilityValue(
                                    selectedResultIndex == index
                                        ? "Previewing"
                                        : ""
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
                        }
                        Button(role: .destructive) {
                            clearFindHistory()
                        } label: {
                            Label(
                                "Clear This History",
                                systemImage: "trash"
                            )
                        }
                    }
                }
            }
            .onSubmit(of: .search) {
                recordSearch(query)
            }
            .onChange(of: query) { _, value in
                if value.count > 200 {
                    query = String(value.prefix(200))
                }
            }
            .task(id: query) {
                let searchQuery = query
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let terms = searchQuery
                    .split(whereSeparator: \.isWhitespace)
                    .map { String($0) }
                guard !terms.isEmpty,
                      let index = model.textIndices[recordID]
                else {
                    results = []
                    isSearching = false
                    isResultLimited = false
                    selectedResultIndex = nil
                    return
                }
                isSearching = true
                selectedResultIndex = nil
                try? await Task.sleep(for: .milliseconds(160))
                guard !Task.isCancelled else { return }
                let worker = Task.detached(
                    priority: .userInitiated
                ) { () throws -> ([DocumentTextMatch], Bool) in
                    let resultLimit = 200
                    try Task.checkCancellation()
                    let matches = index.matches(
                        for: searchQuery,
                        excerptLimit: 220,
                        limit: resultLimit + 1
                    )
                    try Task.checkCancellation()
                    return (
                        Array(matches.prefix(resultLimit)),
                        matches.count > resultLimit
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
                    guard query
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ) == searchQuery
                    else { return }
                    results = searchResult.0
                    isResultLimited = searchResult.1
                    isSearching = false
                } catch is CancellationError {
                    return
                } catch {
                    guard query
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ) == searchQuery
                    else { return }
                    results = []
                    isResultLimited = false
                    isSearching = false
                    selectedResultIndex = nil
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !results.isEmpty {
                    resultNavigator
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedResultIndex)
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
        HStack(spacing: PPSpacing.small) {
            Button {
                moveSelection(by: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .disabled(!canMoveSelection(by: -1))
            .accessibilityLabel("Previous result")

            Text(resultPositionTitle)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .frame(minWidth: 72)
                .contentTransition(.numericText())

            Button {
                moveSelection(by: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .disabled(!canMoveSelection(by: 1))
            .accessibilityLabel("Next result")

            Spacer(minLength: PPSpacing.small)

            Button {
                if selectedResultIndex == nil {
                    previewResult(at: 0)
                }
                dismiss()
            } label: {
                Label(
                    "View PDF",
                    systemImage: "doc.text.magnifyingglass"
                )
                .font(.caption.weight(.semibold))
                .frame(minHeight: 42)
            }
            .buttonStyle(.borderedProminent)
            .tint(PPColor.cyan)
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
        .accessibilityIdentifier("documentFindNavigator")
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

    private func canMoveSelection(by offset: Int) -> Bool {
        guard !results.isEmpty else { return false }
        guard let selectedResultIndex else {
            return offset > 0
        }
        return results.indices.contains(selectedResultIndex + offset)
    }

    private func moveSelection(by offset: Int) {
        let nextIndex: Int
        if let selectedResultIndex {
            nextIndex = selectedResultIndex + offset
        } else {
            nextIndex = offset > 0 ? 0 : results.count - 1
        }
        previewResult(at: nextIndex)
    }

    private func previewResult(at index: Int) {
        guard results.indices.contains(index) else { return }
        selectedResultIndex = index
        recordSearch(query)
        onSelectPage(results[index].pageIndex)
    }

    private func highlightedSnippet(
        from text: String
    ) -> AttributedString {
        var attributed = AttributedString(text)
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        for term in terms {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text.range(
                      of: term,
                      options: [
                          .caseInsensitive,
                          .diacriticInsensitive
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
                searchStart = range.upperBound
            }
        }
        return attributed
    }

    private var findHistory: [String] {
        searchHistoryMap[recordID.uuidString] ?? []
    }

    private var searchHistoryMap: [String: [String]] {
        guard let data = savedFindHistory.data(
            using: .utf8
        ) else {
            return [:]
        }
        return (try? JSONDecoder().decode(
            [String: [String]].self,
            from: data
        )) ?? [:]
    }

    private func recordSearch(_ value: String) {
        let normalized = String(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(100)
        )
        guard !normalized.isEmpty else { return }

        var map = searchHistoryMap
        var history = map[recordID.uuidString] ?? []
        history.removeAll {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }
        history.insert(normalized, at: 0)
        map[recordID.uuidString] = Array(history.prefix(5))
        persistSearchHistory(map)
    }

    private func clearFindHistory() {
        var map = searchHistoryMap
        map[recordID.uuidString] = nil
        persistSearchHistory(map)
    }

    private func persistSearchHistory(
        _ map: [String: [String]]
    ) {
        guard let data = try? JSONEncoder().encode(map),
              let encoded = String(data: data, encoding: .utf8)
        else { return }
        savedFindHistory = encoded
    }
}
