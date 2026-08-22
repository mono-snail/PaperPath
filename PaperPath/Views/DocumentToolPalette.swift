import SwiftUI

private enum DocumentToolPaletteView:
    String,
    CaseIterable,
    Identifiable {
    case suggested
    case favorites
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .suggested: return "Recommended"
        case .favorites: return "Favorites"
        case .all: return "All tools"
        }
    }
}

struct DocumentToolPalette: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var selectionFeedback = 0
    @State private var showsUnavailableTools = false
    @State private var isCommittingSelection = false
    @AppStorage("document.favoriteTools")
    private var savedFavoriteTools = ""
    @AppStorage("document.toolPaletteView")
    private var savedPaletteView =
        DocumentToolPaletteView.suggested.rawValue

    let recordTitle: String
    let documentURL: URL?
    let refreshToken: Int
    let availableTools: Set<DocumentTool>
    let unavailableReasons: [DocumentTool: String]
    let recentTools: [DocumentTool]
    let contextualTools: [DocumentTool]
    let onSelect: (DocumentTool) -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                ScrollView {
                    VStack(alignment: .leading, spacing: PPSpacing.medium) {
                        paletteHero

                        if searchText.isEmpty {
                            paletteViewPicker
                        }

                        switch effectivePaletteView {
                        case .suggested:
                            if !recommendedMoves.isEmpty {
                                recommendedMoveSection
                            }

                            if !quickTools.isEmpty {
                                quickMoves
                            }
                        case .favorites:
                            if favoriteTools.isEmpty {
                                emptyFavoritesState
                            } else {
                                favoriteToolSection
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
                                ForEach(DocumentToolGroup.allCases) { group in
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
            }
            .navigationTitle("Choose a result")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search by goal"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selectionFeedback)
        .sensoryFeedback(.selection, trigger: savedPaletteView)
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
            if dynamicTypeSize.isAccessibilitySize {
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
            SectionEyebrow(text: "BEST NEXT STEPS")
            LazyVGrid(
                columns: toolColumns,
                alignment: .leading,
                spacing: 0
            ) {
                ForEach(
                    Array(recommendedMoves.enumerated()),
                    id: \.element
                ) { index, tool in
                    recommendedMoveRow(tool, rank: index + 1)
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
        rank: Int
    ) -> some View {
        Button {
            choose(tool)
        } label: {
            HStack(spacing: PPSpacing.small) {
                Text(String(format: "%02d", rank))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(tint(for: tool))
                    .frame(width: 20)
                ToolSymbolPlate(
                    symbol: tool.symbol,
                    tint: tint(for: tool),
                    size: 36
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title.localizedUI)
                        .font(.subheadline.weight(.semibold))
                        .fontDesign(.serif)
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(
                            dynamicTypeSize.isAccessibilitySize ? 2 : 1
                        )
                    Text(recommendedMoveDetail(tool).localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.isAccessibilitySize ? 3 : 1
                        )
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
                    dynamicTypeSize.isAccessibilitySize ? 68 : 48
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(tint(for: tool).opacity(0.7))
                    .frame(width: 2)
                    .padding(.vertical, 7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(tool.detail.localizedUI)
        .accessibilityIdentifier("documentTool-\(tool.rawValue)")
    }

    private var paletteHero: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "THIS PDF",
                detail: searchText.isEmpty
                    ? "Choose what you want to accomplish"
                    : "Matching results",
                symbol: "slider.horizontal.3",
                tint: PPColor.rose
            )

            HStack(alignment: .center, spacing: PPSpacing.regular) {
                ZStack {
                    Rectangle()
                        .fill(PPColor.elevated)
                        .frame(width: 42, height: 54)
                        .rotationEffect(.degrees(-5))
                        .offset(x: -5, y: 2)
                    if let documentURL {
                        PDFPageThumbnailView(
                            url: documentURL,
                            pageIndex: 0,
                            refreshToken: refreshToken,
                            width: 43
                        )
                        .shadow(
                            color: .black.opacity(0.13),
                            radius: 5,
                            y: 3
                        )
                    } else {
                        Image(systemName: "doc.text")
                            .font(.title3)
                            .foregroundStyle(PPColor.cyan)
                            .frame(width: 43, height: 55)
                            .background(PPColor.surface)
                    }
                }
                .frame(width: 52, height: 58)
                .overlay {
                    StudioStageMarks(
                        tint: PPColor.cyan,
                        inset: 1,
                        arm: 6
                    )
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    SectionEyebrow(
                        text: searchText.isEmpty
                            ? "CURRENT PDF"
                            : "MATCHING TOOLS"
                    )
                    Text(
                        searchText.isEmpty
                            ? recordTitle
                            : AppLocalization.format(
                                "%lld result%@",
                                filteredTools.count,
                                filteredTools.count == 1 ? "" : "s"
                            )
                        )
                    .font(.headline)
                    .fontDesign(.serif)
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(2)
                    if searchText.isEmpty {
                        Text("PaperPath recommends the safest next steps")
                            .font(.caption2)
                            .foregroundStyle(PPColor.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, PPSpacing.xSmall)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var quickMoves: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            SectionEyebrow(
                text: favoriteTools.isEmpty
                    ? "RECENT TOOLS"
                    : "SAVED & RECENT"
            )
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 0) {
                    ForEach(quickTools) { tool in
                        toolRow(tool)
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: PPSpacing.large) {
                        ForEach(quickTools) { tool in
                            quickMoveButton(tool)
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
                .padding(.leading, 52)
        }
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

    private func quickMoveButton(
        _ tool: DocumentTool
    ) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                choose(tool)
            } label: {
                VStack(spacing: 7) {
                    ToolSymbolPlate(
                        symbol: tool.symbol,
                        tint: tint(for: tool),
                        size: 46
                    )
                    Text(tool.compactTitle.localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                        .lineLimit(1)
                }
                .frame(width: 76)
                .frame(minHeight: 76)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(tool.detail.localizedUI)
            .accessibilityIdentifier("documentTool-\(tool.rawValue)")

            Button {
                toggleFavorite(tool)
            } label: {
                Image(
                    systemName: favoriteTools.contains(tool)
                        ? "star.fill"
                        : "star"
                )
                .font(.caption2.weight(.bold))
                .foregroundStyle(
                    favoriteTools.contains(tool)
                        ? PPColor.amber
                        : PPColor.textSecondary
                )
                .frame(width: 30, height: 30)
                .background(.thinMaterial, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 9, y: -8)
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
        }
        .frame(width: 82, height: 82)
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
                        Text(tool.title.localizedUI)
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
                        } else {
                            Text(tool.detail.localizedUI)
                                .font(.caption)
                                .foregroundStyle(PPColor.textSecondary)
                        }
                    }
                } icon: {
                    ToolSymbolPlate(
                        symbol: tool.symbol,
                        tint: isAvailable
                            ? tint(for: tool)
                            : PPColor.textSecondary,
                        size: 38
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, PPSpacing.small)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
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
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .opacity(isAvailable ? 1 : 0.35)
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
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
                .padding(.leading, 52)
        }
    }

    private var emptyToolsState: some View {
        HStack(spacing: PPSpacing.medium) {
            PPIllustration(kind: .search, width: 92)
                .frame(width: 88, height: 72)
            VStack(alignment: .leading, spacing: 3) {
                Text("No matching tools")
                    .font(.headline)
                    .foregroundStyle(PPColor.textPrimary)
                Text("Try sign, redact, compress, or pages.")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PPSpacing.small)
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
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, PPSpacing.medium)
        .accessibilityIdentifier("emptyFavoriteDocumentTools")
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

    private var quickTools: [DocumentTool] {
        guard searchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        else { return [] }
        var result: [DocumentTool] = []
        for tool in favoriteTools + recentTools
        where availableTools.contains(tool) && !result.contains(tool) {
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
            && !result.contains(tool) {
            result.append(tool)
        }
        return Array(result.prefix(4))
    }

    private func recommendedMoveDetail(
        _ tool: DocumentTool
    ) -> String {
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
            && !dynamicTypeSize.isAccessibilitySize
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
            Button {
                withAnimation(
                    reduceMotion ? nil : .snappy(duration: 0.2)
                ) {
                    showsUnavailableTools.toggle()
                }
            } label: {
                HStack {
                    Label(
                        "Unavailable for this PDF",
                        systemImage: "circle.slash"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    Spacer()
                    Text("\(unavailableTools.count)")
                        .monospacedDigit()
                    Image(
                        systemName: showsUnavailableTools
                            ? "chevron.up"
                            : "chevron.down"
                    )
                }
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showsUnavailableTools {
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

    private func choose(_ tool: DocumentTool) {
        guard availableTools.contains(tool),
              !isCommittingSelection
        else { return }
        isCommittingSelection = true
        selectionFeedback += 1
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            onSelect(tool)
        }
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
        switch group {
        case .understand: return PPColor.cyan
        case .markUp: return PPColor.rose
        case .finish: return PPColor.mint
        case .pages: return PPColor.accent
        case .export: return PPColor.textSecondary
        }
    }

    private func paletteViewSymbol(
        _ view: DocumentToolPaletteView
    ) -> String {
        switch view {
        case .suggested: return "sparkles"
        case .favorites: return "star"
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
