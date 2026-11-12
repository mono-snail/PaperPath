import SwiftUI

private enum DocumentToolPaletteView:
    String,
    CaseIterable,
    Identifiable {
    case suggested
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suggested: return "Suggested"
        case .all: return "All actions"
        }
    }
}

struct DocumentToolPalette: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @FocusState private var isToolSearchFocused: Bool
    @State private var selectionFeedback = 0
    @State private var searchErrorFeedback = 0
    @State private var showsUnavailableTools = false
    @State private var isCommittingSelection = false
    @AppStorage("document.favoriteTools")
    private var savedFavoriteTools = ""
    @AppStorage("document.toolPaletteView")
    private var savedPaletteView =
        DocumentToolPaletteView.suggested.rawValue

    let recordTitle: String
    let availableTools: Set<DocumentTool>
    let unavailableReasons: [DocumentTool: String]
    let recentTools: [DocumentTool]
    let contextualTools: [DocumentTool]
    let contextualReasons: [DocumentTool: String]
    let onSelect: (DocumentTool) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                VStack(spacing: 0) {
                    toolSearchInput
                        .padding(.horizontal, PPSpacing.regular)
                        .padding(.top, PPSpacing.small)

                    ScrollView {
                        VStack(
                            alignment: .leading,
                            spacing: PPSpacing.medium
                        ) {
                            if !hasSearchQuery {
                                paletteHero
                                paletteViewPicker
                            } else if !filteredTools.isEmpty {
                                toolSearchSummary
                            }

                            switch effectivePaletteView {
                            case .suggested:
                                if !favoriteTools.isEmpty {
                                    favoriteToolSection
                                }

                                if !recommendedMoves.isEmpty {
                                    recommendedMoveSection
                                }

                                if !quickTools.isEmpty {
                                    quickMoves
                                }

                                if recommendedMoves.isEmpty,
                                   quickTools.isEmpty,
                                   favoriteTools.isEmpty {
                                    noSuggestedToolsState
                                }
                            case .all:
                                if hasSearchQuery {
                                    if !availableSearchResults.isEmpty {
                                        toolGroupCard(
                                            title: "TOOL RESULTS",
                                            tools: availableSearchResults,
                                            tint: PPColor.cyan
                                        )
                                    }
                                } else {
                                    ForEach(
                                        DocumentToolGroup.allCases
                                    ) { group in
                                        let tools = tools(in: group)
                                        if !tools.isEmpty {
                                            toolGroupCard(
                                                title: group.title,
                                                tools: tools,
                                                tint: tint(for: group)
                                            )
                                        }
                                    }
                                }

                                if !unavailableTools.isEmpty {
                                    unavailableToolSection
                                }
                            }

                            if filteredTools.isEmpty {
                                emptyToolsState
                            }

                        }
                        .frame(
                            maxWidth: horizontalSizeClass == .regular
                                ? 980
                                : 680
                        )
                        .padding(PPSpacing.regular)
                        .frame(maxWidth: .infinity)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") {
                        guard !isCommittingSelection else { return }
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isCommittingSelection)
                }
            }
        }
        .onChange(of: searchText) { _, value in
            if value.count > 200 {
                searchText = String(value.prefix(200))
            }
            showsUnavailableTools = !value
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                .isEmpty
        }
        .interactiveDismissDisabled(isCommittingSelection)
        .accessibilityAction(.escape) {
            guard !isCommittingSelection else { return }
            dismiss()
        }
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .sensoryFeedback(.selection, trigger: savedPaletteView)
        .sensoryFeedback(.error, trigger: searchErrorFeedback)
    }

    private var toolSearchInput: some View {
        HStack(spacing: PPSpacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PPColor.textSecondary)
                .accessibilityHidden(true)

            TextField("Search tools", text: $searchText)
                .focused($isToolSearchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit {
                    activateTopSearchResult()
                }
                .accessibilityIdentifier("documentToolSearchField")

            if hasSearchQuery {
                Button {
                    clearToolSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.textSecondary)
                .accessibilityLabel("Clear tool search".localizedUI)
                .help("Clear tool search".localizedUI)
            }
        }
        .padding(.leading, PPSpacing.regular)
        .padding(.trailing, PPSpacing.xSmall)
        .frame(minHeight: 50)
        .background(
            RoundedRectangle(cornerRadius: PPRadius.control, style: .continuous)
                .fill(PPColor.surfaceMuted)
        )
        .overlay {
            RoundedRectangle(cornerRadius: PPRadius.control, style: .continuous)
                .stroke(isToolSearchFocused ? PPColor.accent : PPColor.border.opacity(0.45), lineWidth: 1)
        }
    }

    private var paletteView: DocumentToolPaletteView {
        DocumentToolPaletteView(rawValue: savedPaletteView)
            ?? .suggested
    }

    private var effectivePaletteView: DocumentToolPaletteView {
        searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? paletteView : .all
    }

    private var paletteViewPicker: some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                Menu {
                    ForEach(DocumentToolPaletteView.allCases) { view in
                        Button {
                            savedPaletteView = view.rawValue
                        } label: {
                            Label(
                                view.title.localizedUI,
                                systemImage: paletteView == view
                                    ? "checkmark"
                                    : paletteViewSymbol(view)
                            )
                        }
                        .accessibilityIdentifier(
                            "documentToolView-\(view.rawValue)"
                        )
                    }
                } label: {
                    HStack(spacing: PPSpacing.small) {
                        Label(
                            paletteView.title.localizedUI,
                            systemImage: paletteViewSymbol(paletteView)
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(PPColor.textSecondary)
                    }
                    .padding(.horizontal, PPSpacing.small)
                    .frame(minHeight: 48)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.64))
                            .frame(height: 0.6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tool view")
                .accessibilityValue(paletteView.title.localizedUI)
            } else {
                Picker(
                    "Tool view",
                    selection: $savedPaletteView
                ) {
                    ForEach(DocumentToolPaletteView.allCases) { view in
                        Text(view.title.localizedUI)
                            .tag(view.rawValue)
                            .accessibilityIdentifier(
                                "documentToolView-\(view.rawValue)"
                            )
                    }
                }
                .pickerStyle(.segmented)
                .tint(PPColor.accent)
            }
        }
        .accessibilityIdentifier("documentToolView")
    }

    private var recommendedMoveSection: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(text: "SUGGESTED ACTIONS")
            if let primary = recommendedMoves.first {
                recommendedMoveRow(primary, isPrimary: true)
            }
            LazyVGrid(
                columns: toolColumns,
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(Array(recommendedMoves.dropFirst())) { tool in
                    recommendedMoveRow(tool)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
                .padding(.leading, 52)
        }
        .accessibilityIdentifier("recommendedDocumentMoves")
    }

    private func recommendedMoveRow(
        _ tool: DocumentTool,
        isPrimary: Bool = false
    ) -> some View {
        Button {
            choose(tool)
        } label: {
            HStack(spacing: PPSpacing.small) {
                paletteSymbol(tool.symbol, tint: isPrimary ? PPColor.accent : tint(for: tool))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.catalogTitle.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout ? nil : 2
                        )
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(tint(for: tool))
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(
                minHeight:
                    dynamicTypeSize.ppPrefersExpandedLayout ? 68 : (isPrimary ? 56 : 48)
            )
            .padding(.vertical, dynamicTypeSize.ppPrefersExpandedLayout ? PPSpacing.small : 0)
            .background(isPrimary ? PPColor.accent.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: PPRadius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(PPPressButtonStyle())
        .disabled(isCommittingSelection)
        .hoverEffect(.highlight)
        .accessibilityHint(recommendedMoveDetail(tool).localizedUI)
        .accessibilityIdentifier("documentTool-\(tool.rawValue)")
        .contextMenu {
            Button {
                toggleFavorite(tool)
            } label: {
                Label("Add to favorites".localizedUI, systemImage: "star")
            }
        }
    }

    private var paletteHero: some View {
        HStack(alignment: .center, spacing: PPSpacing.small) {
            paletteSymbol("doc.text", tint: PPColor.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(recordTitle)
                    .font(PPType.display)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(
                        dynamicTypeSize.ppPrefersExpandedLayout ? nil : 2
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var quickMoves: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(
                text: "RECENT TOOLS"
            )
            LazyVGrid(columns: toolColumns, alignment: .leading, spacing: 0) {
                ForEach(quickTools) { tool in
                    toolRow(tool)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
                .padding(.leading, 52)
        }
    }

    private var toolSearchSummary: some View {
        searchSummaryIdentity
            .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PPSpacing.xSmall)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(toolSearchSummaryDetail)
        .accessibilityIdentifier("documentToolSearchSummary")
    }

    private var searchSummaryIdentity: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(toolSearchSummaryTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
            }
        } icon: {
            Image(
                systemName: availableSearchResults.isEmpty
                    ? "circle.slash"
                    : "checkmark.circle"
            )
            .foregroundStyle(
                availableSearchResults.isEmpty
                    ? PPColor.amber
                    : PPColor.mint
            )
        }
    }

    private func clearToolSearch() {
        searchText = ""
        showsUnavailableTools = false
        isToolSearchFocused = true
    }

    private var favoriteToolSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionEyebrow(text: "FAVORITE TOOLS")
                Spacer()
                Text("\(favoriteTools.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PPColor.amber)
            }
            .padding(.bottom, PPSpacing.small)

            LazyVGrid(
                columns: toolColumns,
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(favoriteTools) { tool in
                    toolRow(tool)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
        .accessibilityIdentifier("favoriteDocumentTools")
    }

    private func toolGroupCard(
        title: String,
        tools: [DocumentTool],
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioSectionRule(
                title: title,
                symbol: groupSymbol(title),
                count: tools.count,
                tint: tint
            )
            .padding(.horizontal, PPSpacing.regular)
            .padding(.top, PPSpacing.regular)
            .padding(.bottom, PPSpacing.small)

            LazyVGrid(
                columns: toolColumns,
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(tools) { tool in
                    toolRow(tool)
                }
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func toolRow(_ tool: DocumentTool) -> some View {
        let isAvailable = availableTools.contains(tool)
        let unavailableReason = isAvailable
            ? nil
            : (
                unavailableReasons[tool]
                    ?? "Not available for this PDF"
            )

        return HStack(spacing: 0) {
            Button {
                choose(tool)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tool.catalogTitle.localizedUI)
                            .font(PPType.document)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(
                                isAvailable
                                    ? PPColor.textPrimary
                                    : PPColor.textSecondary
                            )
                        if let unavailableReason {
                            Label(
                                unavailableReason.localizedUI,
                                systemImage: "info.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.amber)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } icon: {
                    paletteSymbol(tool.symbol, tint: isAvailable ? tint(for: tool) : PPColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, PPSpacing.small)
                .padding(.vertical, 5)
                .frame(minHeight: PPDeskLayout.touchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(PPPressButtonStyle())
            .disabled(!isAvailable || isCommittingSelection)
            .hoverEffect(.highlight)
            .accessibilityHint(
                unavailableReason?.localizedUI
                    ?? AppLocalization.format(
                        "Opens %@ tools",
                        tool.title.localizedUI
                    )
            )
            .accessibilityIdentifier("documentTool-\(tool.rawValue)")

            Button {
                toggleFavorite(tool)
            } label: {
                Image(
                    systemName: favoriteTools.contains(tool)
                        ? "star.fill"
                        : "star"
                )
                .foregroundStyle(
                    favoriteTools.contains(tool)
                        ? PPColor.amber
                        : PPColor.textSecondary
                )
                .font(.subheadline.weight(.medium))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(PPPressButtonStyle())
            .disabled(isCommittingSelection || (!isAvailable && !favoriteTools.contains(tool)))
            .hoverEffect(.highlight)
            .opacity(isAvailable || favoriteTools.contains(tool) ? 1 : 0.35)
            .accessibilityLabel(
                favoriteTools.contains(tool)
                    ? AppLocalization.format(
                        "Remove %@ from favorites",
                        tool.title.localizedUI
                    )
                    : AppLocalization.format(
                        "Add %@ to favorites",
                        tool.title.localizedUI
                    )
            )
            .accessibilityIdentifier("documentToolFavorite-\(tool.rawValue)")
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
                .padding(.leading, 52)
        }
    }

    private func paletteSymbol(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .regular))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
    }

    private var emptyToolsState: some View {
        HStack(spacing: PPSpacing.medium) {
            if !dynamicTypeSize.ppPrefersExpandedLayout {
                PPIllustration(kind: .search, width: 92)
                    .frame(width: 88, height: 72)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("No matching tools")
                    .font(.headline)
                    .foregroundStyle(PPColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PPSpacing.small)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("documentToolEmptyState")
    }

    private var emptyFavoritesState: some View {
        HStack(spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: "star",
                tint: PPColor.amber,
                size: 44
            )
            VStack(alignment: .leading, spacing: 3) {
                Text("No favorite tools")
                    .font(.headline)
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                Text("Star tools in All to keep them one tap away.")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
            Spacer(minLength: 0)
            Button("Browse All") {
                savedPaletteView = DocumentToolPaletteView.all.rawValue
            }
            .font(.caption.weight(.semibold))
            .frame(minHeight: 44)
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PPSpacing.medium)
        .accessibilityIdentifier("emptyFavoriteDocumentTools")
    }

    private var noSuggestedToolsState: some View {
        HStack(spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: "square.grid.2x2",
                tint: PPColor.cyan,
                size: 44
            )
            VStack(alignment: .leading, spacing: 3) {
                Text("No suggested actions".localizedUI)
                    .font(.headline)
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
            }
            Spacer(minLength: 0)
            Button {
                savedPaletteView =
                    DocumentToolPaletteView.all.rawValue
            } label: {
                Image(systemName: "arrow.right")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.cyan)
            .accessibilityLabel("Browse all actions".localizedUI)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PPSpacing.medium)
        .accessibilityIdentifier("emptySuggestedDocumentTools")
    }

    private var filteredTools: [DocumentTool] {
        guard hasSearchQuery else {
            return DocumentTool.allCases
        }
        return DocumentTool.allCases.compactMap { tool in
            tool.matchScore(searchText).map { (tool, $0) }
        }
        .sorted { lhs, rhs in
            if lhs.1 == rhs.1 {
                return lhs.0.title < rhs.0.title
            }
            return lhs.1 > rhs.1
        }
        .map(\.0)
    }

    private var hasSearchQuery: Bool {
        !searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private var availableSearchResults: [DocumentTool] {
        filteredTools.filter(availableTools.contains)
    }

    private var toolSearchSummaryTitle: String {
        let readyCount = availableSearchResults.count
        let unavailableCount = unavailableTools.count
        if readyCount > 0 {
            return AppLocalization.format(
                "%lld ready · %lld unavailable",
                readyCount,
                unavailableCount
            )
        }
        if unavailableCount > 0 {
            return "Matches unavailable for this PDF".localizedUI
        }
        return "No tool matches".localizedUI
    }

    private var toolSearchSummaryDetail: String {
        if !availableSearchResults.isEmpty {
            return "Press Return to open the first ready action."
                .localizedUI
        }
        if !unavailableTools.isEmpty {
            return "The matching actions are shown with the reason they cannot run here."
                .localizedUI
        }
        return "Try sign, redact, compress, export, or pages."
            .localizedUI
    }

    private var quickTools: [DocumentTool] {
        guard searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        else { return [] }
        var result: [DocumentTool] = []
        for tool in recentTools
        where availableTools.contains(tool)
            && !favoriteTools.contains(tool)
            && !recommendedMoves.contains(tool)
            && !result.contains(tool) {
            result.append(tool)
        }
        return Array(result.prefix(6))
    }

    private var favoriteTools: [DocumentTool] {
        var result: [DocumentTool] = []
        for value in savedFavoriteTools.split(separator: ",") {
            guard let tool = DocumentTool(rawValue: String(value)),
                  !result.contains(tool)
            else { continue }
            result.append(tool)
        }
        return result
    }

    private func tools(in group: DocumentToolGroup) -> [DocumentTool] {
        return filteredTools.filter {
            $0.group == group
                && availableTools.contains($0)
        }
    }

    private var recommendedMoves: [DocumentTool] {
        guard searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        else { return [] }
        var result: [DocumentTool] = []
        for tool in contextualTools + [
            .find,
            .organize,
            .export
        ] where availableTools.contains(tool)
            && !favoriteTools.contains(tool)
            && !result.contains(tool) {
            result.append(tool)
        }
        return Array(result.prefix(4))
    }

    private func recommendedMoveDetail(
        _ tool: DocumentTool
    ) -> String {
        if let reason = contextualReasons[tool],
           !reason.isEmpty {
            return reason
        }
        switch tool {
        case .find:
            return "Locate evidence before editing"
        case .recognize:
            return "Index scanned pages locally"
        case .fillForm:
            return "Finish fields before output"
        case .sign:
            return "Place saved or new signature"
        case .redact:
            return "Remove sensitive content"
        case .organize:
            return "Fix page order and crops"
        case .export:
            return "Create PDF, Office, text, or images"
        default:
            return tool.detail
        }
    }

    private var toolColumns: [GridItem] {
        let count = horizontalSizeClass == .regular
            && !dynamicTypeSize.ppPrefersExpandedLayout
            ? 2
            : 1
        return Array(
            repeating: GridItem(.flexible(), spacing: PPSpacing.medium),
            count: count
        )
    }

    private var unavailableTools: [DocumentTool] {
        filteredTools.filter { !availableTools.contains($0) }
    }

    private var unavailableToolSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasSearchQuery {
                unavailableSectionHeading
            } else {
                Button {
                    withAnimation(
                        reduceMotion ? nil : .snappy(duration: 0.2)
                    ) {
                        showsUnavailableTools.toggle()
                    }
                } label: {
                    unavailableSectionHeading
                }
                .buttonStyle(PPPressButtonStyle())
                .accessibilityValue((showsUnavailableTools ? "Expanded" : "Collapsed").localizedUI)
            }

            if showsUnavailableTools || hasSearchQuery {
                LazyVGrid(
                    columns: toolColumns,
                    alignment: .leading,
                    spacing: 0
                ) {
                    ForEach(unavailableTools) { tool in
                        toolRow(tool)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var unavailableSectionHeading: some View {
        HStack {
            Label("Unavailable for this PDF".localizedUI, systemImage: "circle.slash")
                .font(.caption.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PPSpacing.small)
            Text("\(unavailableTools.count)").monospacedDigit()
            if !hasSearchQuery {
                Image(systemName: showsUnavailableTools ? "chevron.up" : "chevron.down")
                    .accessibilityHidden(true)
            }
        }
        .font(.caption)
        .foregroundStyle(PPColor.textSecondary)
        .frame(minHeight: PPDeskLayout.touchTarget)
        .contentShape(Rectangle())
    }

    private func choose(_ tool: DocumentTool) {
        guard availableTools.contains(tool),
              !isCommittingSelection
        else { return }
        isCommittingSelection = true
        selectionFeedback += 1
        onSelect(tool)
    }

    private func activateTopSearchResult() {
        guard hasSearchQuery else { return }
        if let tool = availableSearchResults.first {
            choose(tool)
            return
        }
        showsUnavailableTools = !unavailableTools.isEmpty
        searchErrorFeedback &+= 1
        isToolSearchFocused = false
    }

    private func toggleFavorite(_ tool: DocumentTool) {
        var updated = favoriteTools
        if let index = updated.firstIndex(of: tool) {
            updated.remove(at: index)
        } else {
            updated.insert(tool, at: 0)
        }
        savedFavoriteTools = updated
            .map(\.rawValue)
            .joined(separator: ",")
        selectionFeedback += 1
    }

    private func tint(for tool: DocumentTool) -> Color {
        tint(for: tool.group)
    }

    private func tint(for group: DocumentToolGroup) -> Color {
        PPColor.accent
    }

    private func paletteViewSymbol(
        _ view: DocumentToolPaletteView
    ) -> String {
        switch view {
        case .suggested: return "sparkles"
        case .all: return "square.grid.2x2"
        }
    }

    private func groupSymbol(_ title: String) -> String {
        guard let group = DocumentToolGroup.allCases.first(
            where: { $0.title == title }
        ) else { return "square.grid.2x2" }
        switch group {
        case .understand: return "doc.text.magnifyingglass"
        case .markUp: return "pencil.and.outline"
        case .finish: return "checkmark.seal"
        case .pages: return "square.grid.2x2"
        case .export: return "square.and.arrow.up"
        }
    }
}
