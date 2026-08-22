import AVFoundation
import NaturalLanguage
import PDFKit
import SwiftUI

struct ReadingSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var preferences: PDFReadingPreferences

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
                            eyebrow: "READING WORKFLOW",
                            title: "Page reading",
                            detail: "Change the surround and navigation without altering document colors.",
                            symbol: "book.pages",
                            tint: PPColor.accent,
                            metrics: [
                                WorkflowMetric(
                                    value: preferences.theme.title,
                                    label: "Surround",
                                    symbol: preferences.theme.symbol,
                                    tint: PPColor.cyan
                                ),
                                WorkflowMetric(
                                    value: preferences.layout.title,
                                    label: "Layout",
                                    symbol: preferences.layout.symbol,
                                    tint: PPColor.accent
                                ),
                                WorkflowMetric(
                                    value: preferences.scrollsHorizontally
                                        ? "Horizontal"
                                        : "Vertical",
                                    label: "Direction",
                                    symbol: preferences.scrollsHorizontally
                                        ? "arrow.left.and.right"
                                        : "arrow.up.and.down",
                                    tint: PPColor.mint
                                )
                            ],
                            showsOnDevice: false
                        )

                        WorkflowSectionHeader(
                            eyebrow: "READING SURROUND",
                            title: preferences.theme.title
                        )
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(
                                        minimum: 112,
                                        maximum: 220
                                    ),
                                    spacing: PPSpacing.small
                                )
                            ],
                            spacing: PPSpacing.small
                        ) {
                            ForEach(PDFReadingTheme.allCases) { theme in
                                Button {
                                    preferences.theme = theme
                                } label: {
                                    HStack(spacing: PPSpacing.small) {
                                        Circle()
                                            .fill(themeSwatch(theme))
                                            .frame(width: 24, height: 24)
                                            .overlay {
                                                Circle()
                                                    .stroke(
                                                        PPColor.border,
                                                        lineWidth: 0.6
                                                    )
                                            }
                                        Text(theme.title.localizedUI)
                                            .font(
                                                .caption.weight(
                                                    .semibold
                                                )
                                            )
                                            .foregroundStyle(
                                                PPColor.textPrimary
                                            )
                                        Spacer(minLength: 0)
                                        if preferences.theme == theme {
                                            Image(
                                                systemName:
                                                    "checkmark.circle.fill"
                                            )
                                            .foregroundStyle(PPColor.accent)
                                        }
                                    }
                                    .padding(.horizontal, PPSpacing.small)
                                    .frame(minHeight: 42)
                                    .background(
                                        preferences.theme == theme
                                            ? PPColor.accent.opacity(0.08)
                                            : Color.clear
                                    )
                                    .overlay(alignment: .bottom) {
                                        Rectangle()
                                            .fill(
                                                preferences.theme == theme
                                                    ? PPColor.accent
                                                    : PPColor.border
                                                        .opacity(0.56)
                                            )
                                            .frame(
                                                height:
                                                    preferences.theme
                                                        == theme
                                                    ? 2
                                                    : 0.6
                                            )
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        WorkflowSectionHeader(
                            eyebrow: "PAGE FLOW",
                            title: preferences.layout.title
                        )
                        Picker(
                            "Page layout",
                            selection: $preferences.layout
                        ) {
                            ForEach(PDFReadingLayout.allCases) { layout in
                                Text(layout.title.localizedUI)
                                    .tag(layout)
                            }
                        }
                        .pickerStyle(.segmented)

                        Toggle(
                            "Horizontal navigation",
                            isOn: $preferences.scrollsHorizontally
                        )
                        .disabled(
                            preferences.layout == .continuous
                        )
                        .onChange(of: preferences.layout) {
                            if preferences.layout == .continuous {
                                preferences.scrollsHorizontally = false
                            }
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func themeSwatch(
        _ theme: PDFReadingTheme
    ) -> Color {
        switch theme {
        case .paper:
            return Color(
                light: UIColor.white,
                dark: UIColor(white: 0.9, alpha: 1)
            )
        case .sepia:
            return Color(
                light: UIColor(
                    red: 0.91,
                    green: 0.82,
                    blue: 0.64,
                    alpha: 1
                ),
                dark: UIColor(
                    red: 0.55,
                    green: 0.45,
                    blue: 0.31,
                    alpha: 1
                )
            )
        case .night:
            return Color(
                light: UIColor(
                    red: 0.13,
                    green: 0.15,
                    blue: 0.18,
                    alpha: 1
                ),
                dark: UIColor(
                    red: 0.04,
                    green: 0.05,
                    blue: 0.06,
                    alpha: 1
                )
            )
        }
    }
}

struct BookmarksSheet: View {
    private enum NavigationMode: String, CaseIterable, Identifiable {
        case bookmarks
        case outline
        case labels

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    struct OutlineEntry: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let pageIndex: Int
        let level: Int
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let currentPageIndex: Int
    let onSelect: (Int) -> Void
    let onCreated: (DocumentRoute) -> Void
    @State private var outline: [OutlineEntry] = []
    @State private var pageLabels: [PDFPageLabelSnapshot] = []
    @State private var searchText = ""
    @State private var pageInput = ""
    @State private var isEditingPageLabels = false
    @State private var namingBookmarkPage: Int?
    @State private var bookmarkName = ""
    @State private var navigationMode = NavigationMode.bookmarks
    @State private var loadGeneration = 0

    init(
        recordID: UUID,
        currentPageIndex: Int,
        onSelect: @escaping (Int) -> Void,
        onCreated: @escaping (DocumentRoute) -> Void = { _ in }
    ) {
        self.recordID = recordID
        self.currentPageIndex = currentPageIndex
        self.onSelect = onSelect
        self.onCreated = onCreated
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                if let record = model.record(id: recordID) {
                    ScrollView {
                        VStack(
                            alignment: .leading,
                            spacing: PPSpacing.medium
                        ) {
                            navigationHeader(record)
                            pageJump(record)
                            Picker(
                                "Navigation mode",
                                selection: $navigationMode
                            ) {
                                ForEach(NavigationMode.allCases) { mode in
                                    Text(mode.title.localizedUI)
                                        .tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)

                            switch navigationMode {
                            case .bookmarks:
                                bookmarksContent(record)
                            case .outline:
                                outlineContent
                            case .labels:
                                pageLabelsContent(record)
                            }
                        }
                        .frame(maxWidth: 960)
                        .padding(PPSpacing.regular)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView(
                        "Document unavailable",
                        systemImage: "doc.questionmark"
                    )
                }
            }
            .navigationTitle("Navigate")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                prompt: "Search outline or bookmark"
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: model.refreshToken(for: recordID)) {
                loadGeneration += 1
                let generation = loadGeneration
                guard let url = model.url(for: recordID) else {
                    return
                }
                async let loadedOutline = Self.loadOutline(from: url)
                async let loadedLabels = model.pageLabels(
                    recordID: recordID
                )
                let values = await (loadedOutline, loadedLabels)
                guard !Task.isCancelled,
                      generation == loadGeneration
                else { return }
                outline = values.0
                pageLabels = values.1
                if model.record(id: recordID)?
                    .bookmarkedPages.isEmpty == true,
                   !outline.isEmpty {
                    navigationMode = .outline
                }
            }
            .sheet(isPresented: $isEditingPageLabels) {
                if let record = model.record(id: recordID) {
                    PageLabelEditorSheet(
                        recordID: recordID,
                        pageCount: record.profile.pageCount
                    ) { route in
                        isEditingPageLabels = false
                        dismiss()
                        onCreated(route)
                    }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .alert(
                model.record(id: recordID)?
                    .bookmarkedPages.contains(
                        namingBookmarkPage ?? -1
                    ) == true
                    ? "Name Bookmark"
                    : "Add Bookmark",
                isPresented: Binding(
                    get: { namingBookmarkPage != nil },
                    set: {
                        if !$0 {
                            namingBookmarkPage = nil
                            bookmarkName = ""
                        }
                    }
                )
            ) {
                TextField("Optional name", text: $bookmarkName)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    saveNamedBookmark()
                }
            } message: {
                Text("The name stays in PaperPath metadata.")
            }
        }
    }

    private func navigationHeader(
        _ record: DocumentRecord
    ) -> some View {
        WorkflowCommandHeader(
            eyebrow: "READING POSITION",
            title: "Navigate document",
            detail: "Move by page, label, bookmark, or document outline.",
            symbol: "bookmark.square",
            tint: PPColor.accent,
            metrics: [
                WorkflowMetric(
                    value: pageLabel(for: currentPageIndex),
                    label: "Current",
                    symbol: "number.square",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: "\(record.bookmarkedPages.count)",
                    label: "Bookmarks",
                    symbol: "bookmark.fill",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: "\(outline.count)",
                    label: "Outline",
                    symbol: "list.bullet.indent",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "\(pageLabels.count)",
                    label: "Labels",
                    symbol: "number",
                    tint: PPColor.amber
                )
            ]
        )
    }

    private func pageJump(
        _ record: DocumentRecord
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            TextField(
                "Page number or label",
                text: $pageInput
            )
            .textFieldStyle(.plain)
            .submitLabel(.go)
            .onSubmit { openTypedPage(record) }
            Button {
                openTypedPage(record)
            } label: {
                Label("Go", systemImage: "arrow.right.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(typedPageIndex(record) == nil)
            .accessibilityLabel("Go to page")

            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(width: 0.6, height: 28)

            Button {
                if record.bookmarkedPages.contains(currentPageIndex) {
                    Task {
                        await model.toggleBookmark(
                            recordID: recordID,
                            pageIndex: currentPageIndex
                        )
                    }
                } else {
                    bookmarkName = ""
                    namingBookmarkPage = currentPageIndex
                }
            } label: {
                Label(
                    record.bookmarkedPages.contains(currentPageIndex)
                        ? "Remove current bookmark"
                        : "Bookmark current page",
                    systemImage:
                        record.bookmarkedPages.contains(currentPageIndex)
                        ? "bookmark.slash"
                        : "bookmark"
                )
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.accent)
        }
        .padding(.horizontal, PPSpacing.small)
        .frame(minHeight: 42)
        .background(PPColor.surface.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    @ViewBuilder
    private func bookmarksContent(
        _ record: DocumentRecord
    ) -> some View {
        let bookmarks = filteredBookmarks(record)
        if bookmarks.isEmpty {
            compactNavigationEmpty(
                title: "No bookmarks",
                detail: "Bookmark the current page to return here quickly.",
                symbol: "bookmark"
            )
        } else {
            VStack(spacing: 0) {
                ForEach(bookmarks, id: \.self) { page in
                    HStack(spacing: PPSpacing.small) {
                        Button {
                            choose(page)
                        } label: {
                            HStack(spacing: PPSpacing.small) {
                                Image(systemName: "bookmark.fill")
                                    .foregroundStyle(PPColor.accent)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        record.bookmarkNames[page]
                                            ?? "Page \(page + 1)"
                                    )
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(PPColor.textPrimary)
                                    Text(
                                        "\(pageLabel(for: page)) · Page \(page + 1)"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(PPColor.textSecondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            bookmarkName =
                                record.bookmarkNames[page] ?? ""
                            namingBookmarkPage = page
                        } label: {
                            Image(systemName: "pencil")
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename bookmark")
                        Button(role: .destructive) {
                            Task {
                                await model.toggleBookmark(
                                    recordID: recordID,
                                    pageIndex: page
                                )
                            }
                        } label: {
                            Image(systemName: "bookmark.slash")
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .accessibilityLabel("Remove bookmark")
                    }
                    .padding(.vertical, 6)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.58))
                            .frame(height: 0.6)
                            .padding(.leading, 38)
                    }
                }

                Button {
                    Task {
                        if let created =
                            await model.createBookmarkOutlineCopy(
                                recordID: recordID
                            ) {
                            dismiss()
                            onCreated(
                                DocumentRoute(recordID: created.id)
                            )
                        }
                    }
                } label: {
                    Label(
                        "Create PDF Outline Copy",
                        systemImage: "list.bullet.indent"
                    )
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.accent)
                .disabled(model.isProcessing(recordID))
                .padding(.top, PPSpacing.small)
            }
        }
    }

    @ViewBuilder
    private var outlineContent: some View {
        if filteredOutline.isEmpty {
            compactNavigationEmpty(
                title: "No document outline",
                detail: "This PDF has no matching outline entries.",
                symbol: "list.bullet.indent"
            )
        } else {
            LazyVStack(spacing: 0) {
                ForEach(filteredOutline) { entry in
                    Button {
                        choose(entry.pageIndex)
                    } label: {
                        HStack(spacing: PPSpacing.small) {
                            Image(
                                systemName: entry.level == 0
                                    ? "text.alignleft"
                                    : "arrow.turn.down.right"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                entry.level == 0
                                    ? PPColor.accent
                                    : PPColor.textSecondary
                            )
                            .frame(width: 24)
                            Text(entry.title)
                                .font(
                                    entry.level == 0
                                        ? .subheadline.weight(.semibold)
                                        : .subheadline
                                )
                                .foregroundStyle(PPColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            Text(pageLabel(for: entry.pageIndex))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(PPColor.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(PPColor.textSecondary)
                        }
                        .padding(.leading, min(CGFloat(entry.level), 4) * 10)
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.54))
                            .frame(height: 0.6)
                            .padding(.leading, 34)
                    }
                }
            }
        }
    }

    private func pageLabelsContent(
        _ record: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.medium) {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 130, maximum: 260),
                        spacing: PPSpacing.small
                    )
                ],
                spacing: PPSpacing.small
            ) {
                labelMetric(
                    "Current",
                    value: pageLabel(for: currentPageIndex)
                )
                labelMetric(
                    "First",
                    value: pageLabel(for: 0)
                )
                labelMetric(
                    "Last",
                    value: pageLabel(
                        for: max(0, record.profile.pageCount - 1)
                    )
                )
            }
            Button {
                isEditingPageLabels = true
            } label: {
                Label(
                    "Create Page Labels Copy",
                    systemImage: "number.square"
                )
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.amber))
        }
    }

    private func labelMetric(
        _ label: String,
        value: String
    ) -> some View {
        HStack {
            Text(label.localizedUI)
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PPColor.textPrimary)
        }
        .padding(.horizontal, PPSpacing.small)
        .frame(minHeight: 38)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
    }

    private func compactNavigationEmpty(
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        HStack(spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: symbol,
                tint: PPColor.textSecondary,
                size: 38
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(title.localizedUI)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(detail.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.vertical, PPSpacing.small)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
    }

    private var filteredOutline: [OutlineEntry] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return outline }
        return outline.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || String($0.pageIndex + 1) == query
        }
    }

    private func filteredBookmarks(
        _ record: DocumentRecord
    ) -> [Int] {
        let pages = record.bookmarkedPages.filter {
            $0 >= 0 && $0 < record.profile.pageCount
        }
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return pages }
        return pages.filter {
            String($0 + 1).contains(query)
                || record.bookmarkNames[$0]?
                    .localizedCaseInsensitiveContains(query) == true
        }
    }

    private func pageLabel(for index: Int) -> String {
        pageLabels.first(where: { $0.pageIndex == index })?
            .label ?? String(index + 1)
    }

    private func typedPageIndex(
        _ record: DocumentRecord
    ) -> Int? {
        let query = pageInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if let page = Int(query),
           page >= 1,
           page <= record.profile.pageCount {
            return page - 1
        }
        return pageLabels.first {
            $0.label.compare(
                query,
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive
                ]
            ) == .orderedSame
        }?.pageIndex
    }

    private func openTypedPage(_ record: DocumentRecord) {
        guard let index = typedPageIndex(record) else { return }
        choose(index)
    }

    private func pageButton(
        title: String,
        pageIndex: Int,
        symbol: String
    ) -> some View {
        Button {
            choose(pageIndex)
        } label: {
            Label(title.localizedUI, systemImage: symbol)
        }
    }

    private func choose(_ pageIndex: Int) {
        dismiss()
        onSelect(pageIndex)
    }

    private func saveNamedBookmark() {
        guard let page = namingBookmarkPage else { return }
        let alreadyBookmarked = model.record(id: recordID)?
            .bookmarkedPages.contains(page) == true
        let name = bookmarkName
        namingBookmarkPage = nil
        bookmarkName = ""
        Task {
            if !alreadyBookmarked {
                await model.toggleBookmark(
                    recordID: recordID,
                    pageIndex: page
                )
            }
            await model.updateBookmarkName(
                recordID: recordID,
                pageIndex: page,
                name: name
            )
        }
    }

    private static func loadOutline(from url: URL) async -> [OutlineEntry] {
        await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: url),
                  let root = document.outlineRoot
            else { return [] }
            var result: [OutlineEntry] = []

            func walk(_ item: PDFOutline, level: Int) {
                guard !Task.isCancelled else { return }
                guard level < 24, result.count < 2_000 else { return }
                for index in 0..<item.numberOfChildren {
                    guard !Task.isCancelled else { return }
                    guard result.count < 2_000 else { return }
                    guard let child = item.child(at: index) else { continue }
                    if let page = child.destination?.page {
                        let label = child.label?
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            )
                        result.append(
                            OutlineEntry(
                                title: String(
                                    (
                                        label?.isEmpty == false
                                            ? label!
                                            : "Untitled"
                                    ).prefix(160)
                                ),
                                pageIndex: document.index(for: page),
                                level: level
                            )
                        )
                    }
                    walk(child, level: level + 1)
                }
            }

            walk(root, level: 0)
            return result
        }.value
    }
}

private struct PageLabelEditorSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let pageCount: Int
    let onCreated: (DocumentRoute) -> Void

    @State private var rules: [PDFPageLabelRule]
    @State private var isCreating = false
    @State private var createTask: Task<Void, Never>?

    init(
        recordID: UUID,
        pageCount: Int,
        onCreated: @escaping (DocumentRoute) -> Void
    ) {
        self.recordID = recordID
        self.pageCount = pageCount
        self.onCreated = onCreated
        _rules = State(
            initialValue: [
                PDFPageLabelRule(
                    startPageIndex: 0,
                    style: .decimal
                )
            ]
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.medium
                    ) {
                        WorkflowCommandHeader(
                            eyebrow: "PAGE LABEL WORKFLOW",
                            title: "Number page ranges",
                            detail: "Create a separate PDF with explicit navigation labels.",
                            symbol: "number.square",
                            tint: PPColor.amber,
                            metrics: [
                                WorkflowMetric(
                                    value: "\(pageCount)",
                                    label: "Pages",
                                    symbol: "doc.on.doc",
                                    tint: PPColor.accent
                                ),
                                WorkflowMetric(
                                    value: "\(rules.count)",
                                    label: "Ranges",
                                    symbol: "list.number",
                                    tint: PPColor.cyan
                                ),
                                WorkflowMetric(
                                    value: hasUniqueStarts
                                        ? "Ready"
                                        : "Conflict",
                                    label: "Starts",
                                    symbol: hasUniqueStarts
                                        ? "checkmark.circle"
                                        : "exclamationmark.triangle",
                                    tint: hasUniqueStarts
                                        ? PPColor.mint
                                        : PPColor.amber
                                )
                            ]
                        )

                        ForEach($rules) { $rule in
                            VStack(
                                alignment: .leading,
                                spacing: PPSpacing.small
                            ) {
                                HStack {
                                    SectionEyebrow(
                                        text: rule.startPageIndex == 0
                                            ? "FIRST RANGE"
                                            : "FROM PAGE \(rule.startPageIndex + 1)"
                                    )
                                    Spacer()
                                    Text(
                                        rule.label(
                                            for: rule.startPageIndex
                                        )
                                    )
                                    .font(
                                        .subheadline.monospaced()
                                            .weight(.semibold)
                                    )
                                    .foregroundStyle(PPColor.amber)
                                    if rules.count > 1 {
                                        Button(role: .destructive) {
                                            rules.removeAll {
                                                $0.id == rule.id
                                            }
                                        } label: {
                                            Image(systemName: "trash")
                                                .frame(
                                                    width: 32,
                                                    height: 32
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.red)
                                        .accessibilityLabel(
                                            "Remove numbering range"
                                        )
                                    }
                                }

                                Stepper(
                                    value: $rule.startPageIndex,
                                    in: 0...max(0, pageCount - 1)
                                ) {
                                    LabeledContent(
                                        "Starts on",
                                        value:
                                            "Page \(rule.startPageIndex + 1)"
                                    )
                                }

                                Picker(
                                    "Numbering",
                                    selection: $rule.style
                                ) {
                                    ForEach(
                                        PDFPageLabelStyle.allCases
                                    ) { style in
                                        Text(style.title.localizedUI)
                                            .tag(style)
                                    }
                                }
                                .pickerStyle(.menu)

                                HStack(spacing: PPSpacing.medium) {
                                    TextField(
                                        "Optional prefix",
                                        text: $rule.prefix
                                    )
                                    .textInputAutocapitalization(.never)
                                    if rule.style != .prefixOnly {
                                        Stepper(
                                            value: $rule.startNumber,
                                            in: 1...maximumStartNumber(
                                                for: rule.style
                                            )
                                        ) {
                                            Text(
                                                rule.style
                                                    .formattedNumber(
                                                        rule.startNumber
                                                    )
                                            )
                                            .font(
                                                .caption.monospacedDigit()
                                            )
                                        }
                                        .fixedSize()
                                    }
                                }
                            }
                            .padding(.vertical, PPSpacing.small)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(PPColor.border.opacity(0.62))
                                    .frame(height: 0.6)
                            }
                        }

                        if rules.count < min(16, pageCount) {
                        Button {
                            addRule()
                        } label: {
                            Label(
                                "Add Numbering Range",
                                systemImage: "plus"
                            )
                        }
                        .buttonStyle(
                            PPQuietButtonStyle(tint: PPColor.accent)
                        )
                        }

                        if !hasUniqueStarts {
                        Label(
                            "Each range needs a different start page.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.subheadline)
                        .foregroundStyle(PPColor.amber)
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 72)
                    .frame(maxWidth: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Button {
                    createCopy()
                } label: {
                    Label(
                        isCreating
                            ? "Creating labeled copy"
                            : "Create Labeled Copy",
                        systemImage: isCreating
                            ? "hourglass"
                            : "number.square"
                    )
                }
                .buttonStyle(PPPrimaryButtonStyle())
                .disabled(!canCreate)
                .padding(.horizontal, PPSpacing.regular)
                .padding(.vertical, PPSpacing.small)
                .background(.bar)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(PPColor.border.opacity(0.62))
                        .frame(height: 0.6)
                }
            }
            .navigationTitle("Page Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button((isCreating ? "Stop" : "Cancel").localizedUI) {
                        if isCreating {
                            createTask?.cancel()
                            createTask = nil
                            isCreating = false
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(isCreating)
            .onDisappear {
                createTask?.cancel()
                createTask = nil
            }
        }
    }

    private var canCreate: Bool {
        !isCreating
            && hasUniqueStarts
            && rules.contains(where: { $0.startPageIndex == 0 })
            && rules.allSatisfy {
                $0.prefix.count <= 40
                    && (
                        $0.style != .prefixOnly
                            || !$0.prefix.isEmpty
                    )
            }
    }

    private var hasUniqueStarts: Bool {
        Set(rules.map(\.startPageIndex)).count == rules.count
    }

    private func maximumStartNumber(
        for style: PDFPageLabelStyle
    ) -> Int {
        switch style {
        case .uppercaseRoman, .lowercaseRoman:
            return 3_999
        default:
            return 999_999
        }
    }

    private func addRule() {
        let occupied = Set(rules.map(\.startPageIndex))
        let suggested = (0..<pageCount).first {
            !occupied.contains($0)
        }
        guard let suggested else { return }
        rules.append(
            PDFPageLabelRule(
                startPageIndex: suggested,
                style: .decimal
            )
        )
        rules.sort {
            $0.startPageIndex < $1.startPageIndex
        }
    }

    private func createCopy() {
        guard canCreate else { return }
        isCreating = true
        let sorted = rules.sorted {
            $0.startPageIndex < $1.startPageIndex
        }
        createTask = Task {
            let created = await model.createPageLabeledCopy(
                recordID: recordID,
                rules: sorted
            )
            guard !Task.isCancelled else {
                isCreating = false
                createTask = nil
                return
            }
            isCreating = false
            createTask = nil
            guard let created else { return }
            dismiss()
            onCreated(DocumentRoute(recordID: created.id))
        }
    }
}

private enum FocusReaderTypeface: String, CaseIterable, Identifiable {
    case serif
    case sans
    case rounded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .serif: return "Serif"
        case .sans: return "Sans"
        case .rounded: return "Rounded"
        }
    }

    var design: Font.Design {
        switch self {
        case .serif: return .serif
        case .sans: return .default
        case .rounded: return .rounded
        }
    }
}

private enum FocusReaderMeasure: String, CaseIterable, Identifiable {
    case narrow
    case comfortable
    case wide

    var id: String { rawValue }

    var title: String {
        switch self {
        case .narrow: return "Narrow"
        case .comfortable: return "Comfortable"
        case .wide: return "Wide"
        }
    }

    var maxWidth: CGFloat {
        switch self {
        case .narrow: return 560
        case .comfortable: return 720
        case .wide: return 900
        }
    }
}

private extension Character {
    var isCJK: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30ff,
                 0x3400...0x4dbf,
                 0x4e00...0x9fff,
                 0xac00...0xd7af,
                 0xf900...0xfaff:
                return true
            default:
                return false
            }
        }
    }
}

struct FocusReaderSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let initialPageIndex: Int
    let onOpenPage: (Int) -> Void

    @StateObject private var readAloud = PDFReadAloudController()
    @State private var selectedIndex = 0
    @State private var visiblePageID: Int?
    @State private var sleepRemainingSeconds = 0
    @State private var sleepTimerTask: Task<Void, Never>?
    @State private var cachedPages: [IndexedPageText] = []
    @AppStorage("focusReader.typeface")
    private var savedTypeface = FocusReaderTypeface.serif.rawValue
    @AppStorage("focusReader.measure")
    private var savedMeasure = FocusReaderMeasure.comfortable.rawValue
    @AppStorage("focusReader.fontSize")
    private var fontSize = 19.0
    @AppStorage("focusReader.continuous")
    private var readsContinuously = true
    @AppStorage("focusReader.speechRate")
    private var speechRate = Double(
        AVSpeechUtteranceDefaultSpeechRate
    )

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if pages.isEmpty {
                    ContentUnavailableView(
                        "No readable text",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text(
                            "Run local recognition first if this PDF contains scanned pages."
                        )
                    )
                } else {
                    VStack(spacing: 0) {
                        readerContextHeader
                        readerAppearanceRail
                        readerContent
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !pages.isEmpty {
                    readerControls
                }
            }
            .navigationTitle("Focus Reader")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    readerSettingsMenu
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: model.textIndices[recordID]?.indexedAt) {
            cachedPages = model.textIndices[recordID]?.pages.filter {
                !$0.text.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            } ?? []
            selectInitialPage()
        }
        .onChange(of: selectedIndex) {
            if readAloud.currentPageOffset != selectedIndex {
                readAloud.stop()
            }
            guard !pages.isEmpty else { return }
            let pageIndex = currentPage.pageIndex
            if readsContinuously,
               visiblePageID != pageIndex {
                visiblePageID = pageIndex
            }
            Task {
                await model.updateReadingPosition(
                    recordID: recordID,
                    pageIndex: pageIndex
                )
            }
        }
        .onChange(of: visiblePageID) {
            guard readsContinuously,
                  let visiblePageID,
                  let index = pages.firstIndex(where: {
                      $0.pageIndex == visiblePageID
                  }),
                  index != selectedIndex
            else { return }
            selectedIndex = index
        }
        .onChange(of: readAloud.currentPageOffset) {
            guard let offset = readAloud.currentPageOffset,
                  pages.indices.contains(offset),
                  offset != selectedIndex
            else { return }
            selectedIndex = offset
        }
        .onDisappear {
            sleepTimerTask?.cancel()
            sleepTimerTask = nil
            readAloud.stop()
        }
        .sensoryFeedback(.selection, trigger: selectedIndex)
    }

    private var readerContextHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "FOCUS READER",
            title: model.record(id: recordID)?.displayName
                ?? "Reflowed text",
            detail: "Readable text from the private working copy.",
            symbol: "text.book.closed",
            tint: PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(selectedIndex + 1)/\(pages.count)",
                    label: "Text pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: "\(Int(readingProgress * 100))%",
                    label: "Progress",
                    symbol: "chart.bar.fill",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: sourceTitle,
                    label: "Source",
                    symbol: "iphone",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: speechStateTitle,
                    label: "Read aloud",
                    symbol: readAloud.isSpeaking
                        ? "speaker.wave.2.fill"
                        : readAloud.isPaused
                            ? "pause.fill"
                            : "speaker.wave.2",
                    tint: readAloud.isActive
                        ? PPColor.amber
                        : PPColor.textSecondary
                )
            ]
        )
        .padding(.horizontal, PPSpacing.regular)
        .padding(.top, PPSpacing.small)
    }

    private var readerAppearanceRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PPSpacing.small) {
                Menu {
                    Picker("Typeface", selection: $savedTypeface) {
                        ForEach(FocusReaderTypeface.allCases) {
                            Text($0.title.localizedUI)
                                .tag($0.rawValue)
                        }
                    }
                } label: {
                    Label(typeface.title, systemImage: "textformat")
                }

                Menu {
                    Picker("Text width", selection: $savedMeasure) {
                        ForEach(FocusReaderMeasure.allCases) {
                            Text($0.title.localizedUI)
                                .tag($0.rawValue)
                        }
                    }
                } label: {
                    Label(measure.title, systemImage: "arrow.left.and.right")
                }

                Button {
                    readsContinuously.toggle()
                } label: {
                    Label(
                        readsContinuously ? "Continuous" : "One page",
                        systemImage: readsContinuously
                            ? "rectangle.stack"
                            : "doc"
                    )
                }

                Button {
                    fontSize = max(15, fontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 30, height: 30)
                }
                .disabled(fontSize <= 15)
                .accessibilityLabel("Smaller text")

                Text("\(Int(fontSize))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(minWidth: 26)

                Button {
                    fontSize = min(30, fontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 30, height: 30)
                }
                .disabled(fontSize >= 30)
                .accessibilityLabel("Larger text")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.textPrimary)
            .padding(.horizontal, PPSpacing.regular)
            .padding(.vertical, 6)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
        }
    }

    private var readerContent: some View {
        Group {
            if readsContinuously {
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: PPSpacing.xLarge
                    ) {
                        ForEach(
                            Array(pages.enumerated()),
                            id: \.element.pageIndex
                        ) { index, page in
                            readerPage(
                                page,
                                index: index,
                                showsDivider: index > 0
                            )
                            .id(page.pageIndex)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.bottom, 104)
                }
                .scrollPosition(id: $visiblePageID, anchor: .top)
                .scrollIndicators(.visible)
            } else {
                ScrollView {
                    readerPage(
                        currentPage,
                        index: selectedIndex,
                        showsDivider: false
                    )
                    .padding(.bottom, 104)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private func readerPage(
        _ page: IndexedPageText,
        index: Int,
        showsDivider: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.large) {
            if showsDivider {
                Divider()
                    .padding(.bottom, PPSpacing.small)
            }

            HStack {
                Button {
                    selectedIndex = index
                } label: {
                    SectionEyebrow(
                        text: "PAGE \(page.pageIndex + 1) OF \(pageCount)"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Page \(page.pageIndex + 1) anchor"
                )
                Spacer()
                Label(
                    sourceTitle,
                    systemImage: "iphone"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
            }
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)

            Text(reflowedText(page.text))
                .font(
                    .system(
                        size: min(max(fontSize, 15), 30),
                        design: typeface.design
                    )
                )
                .lineSpacing(max(4, fontSize * 0.34))
                .foregroundStyle(PPColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if readsContinuously {
                Button {
                    dismiss()
                    onOpenPage(page.pageIndex)
                } label: {
                    Label(
                        "Open page \(page.pageIndex + 1) in PDF",
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.accent)
            }
        }
        .frame(maxWidth: measure.maxWidth)
        .padding(.horizontal, PPSpacing.xLarge)
        .padding(.top, showsDivider ? 0 : PPSpacing.large)
        .overlay(alignment: .leading) {
            if index == selectedIndex {
                Rectangle()
                    .fill(
                        readAloud.currentPageOffset == index
                            ? PPColor.amber
                            : PPColor.cyan
                    )
                    .frame(width: 2)
                    .padding(.vertical, PPSpacing.small)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var readerSettingsMenu: some View {
        Menu {
            Picker("Typeface", selection: $savedTypeface) {
                ForEach(FocusReaderTypeface.allCases) {
                    Text($0.title.localizedUI).tag($0.rawValue)
                }
            }

            Picker("Text width", selection: $savedMeasure) {
                ForEach(FocusReaderMeasure.allCases) {
                    Text($0.title.localizedUI).tag($0.rawValue)
                }
            }

            Toggle(
                "Continuous pages",
                isOn: $readsContinuously
            )

            Divider()

            Button {
                fontSize = max(15, fontSize - 1)
            } label: {
                Label("Smaller text", systemImage: "textformat.size.smaller")
            }
            .disabled(fontSize <= 15)

            Button {
                fontSize = min(30, fontSize + 1)
            } label: {
                Label("Larger text", systemImage: "textformat.size.larger")
            }
            .disabled(fontSize >= 30)

            Button {
                speechRate = max(0.38, speechRate - 0.04)
            } label: {
                Label("Slower speech", systemImage: "tortoise")
            }
            .disabled(speechRate <= 0.38)

            Button {
                speechRate = min(0.62, speechRate + 0.04)
            } label: {
                Label("Faster speech", systemImage: "hare")
            }
            .disabled(speechRate >= 0.62)

            Divider()

            Menu {
                Button {
                    cancelSleepTimer()
                } label: {
                    Label(
                        "Off",
                        systemImage: sleepRemainingSeconds == 0
                            ? "checkmark"
                            : "timer"
                    )
                }
                ForEach([5, 10, 15, 30], id: \.self) { minutes in
                    Button {
                        startSleepTimer(minutes: minutes)
                    } label: {
                        Label(
                            "\(minutes) minutes",
                            systemImage: "timer"
                        )
                    }
                }
            } label: {
                Label(
                    sleepRemainingSeconds > 0
                        ? "Sleep · \(formattedSleepTime)"
                        : "Sleep Timer",
                    systemImage: "moon.zzz"
                )
            }
        } label: {
            Image(systemName: "textformat")
        }
        .accessibilityLabel("Reader appearance")
        .help("Reader appearance")
    }

    private var typeface: FocusReaderTypeface {
        FocusReaderTypeface(rawValue: savedTypeface) ?? .serif
    }

    private var measure: FocusReaderMeasure {
        FocusReaderMeasure(rawValue: savedMeasure) ?? .comfortable
    }

    private var readerControls: some View {
        VStack(spacing: 0) {
            if sleepRemainingSeconds > 0 {
                HStack {
                    Label(
                        "Sleep timer",
                        systemImage: "moon.zzz.fill"
                    )
                    Spacer()
                    Text(formattedSleepTime)
                        .monospacedDigit()
                    Button {
                        cancelSleepTimer()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Cancel sleep timer")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .padding(.horizontal, PPSpacing.regular)
                .frame(minHeight: 32)
                .background(PPColor.accent.opacity(0.06))
            }

            HStack(spacing: PPSpacing.small) {
            readerButton(
                "Previous page",
                symbol: "chevron.left",
                disabled: selectedIndex == 0
            ) {
                selectedIndex -= 1
            }

            Text("\(selectedIndex + 1) / \(pages.count)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .frame(minWidth: 46)

            readerButton(
                "Open in PDF",
                symbol: "doc.text.magnifyingglass"
            ) {
                let pageIndex = currentPage.pageIndex
                dismiss()
                onOpenPage(pageIndex)
            }

            Button {
                readAloud.toggle(
                    pageCount: pages.count,
                    startingAt: selectedIndex,
                    rate: Float(speechRate),
                    textForPage: { index in
                        guard pages.indices.contains(index) else {
                            return nil
                        }
                        return reflowedText(pages[index].text)
                    }
                )
            } label: {
                Image(
                    systemName: readAloud.isSpeaking
                        ? "pause.fill"
                        : "speaker.wave.2.fill"
                )
                .font(.body.weight(.semibold))
                .frame(width: 48, height: 48)
                .foregroundStyle(.white)
                .background(PPColor.accent, in: Circle())
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                readAloud.isSpeaking
                    ? "Pause reading"
                    : "Read continuously"
            )
            .help(
                readAloud.isSpeaking
                    ? "Pause reading"
                    : "Read continuously"
            )

            readerButton(
                "Stop reading",
                symbol: "stop.fill",
                disabled: !readAloud.isActive
            ) {
                readAloud.stop()
            }

            readerButton(
                "Next page",
                symbol: "chevron.right",
                disabled: selectedIndex == pages.count - 1
            ) {
                selectedIndex += 1
            }
            }
        }
        .frame(maxWidth: 560)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, PPSpacing.small)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.6))
                .frame(height: 0.6)
        }
    }

    private var formattedSleepTime: String {
        let minutes = sleepRemainingSeconds / 60
        let seconds = sleepRemainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var readingProgress: Double {
        guard !pages.isEmpty else { return 0 }
        return Double(selectedIndex + 1) / Double(pages.count)
    }

    private var speechStateTitle: String {
        if readAloud.isSpeaking { return "Speaking" }
        if readAloud.isPaused { return "Paused" }
        return "Stopped"
    }

    private func startSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        sleepRemainingSeconds = minutes * 60
        sleepTimerTask = Task { @MainActor in
            while !Task.isCancelled,
                  sleepRemainingSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                sleepRemainingSeconds -= 1
            }
            guard !Task.isCancelled else { return }
            readAloud.stop()
            sleepTimerTask = nil
            model.noticeMessage = "Sleep timer ended"
        }
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepRemainingSeconds = 0
    }

    private func readerButton(
        _ label: String,
        symbol: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            disabled ? PPColor.textSecondary.opacity(0.45) : PPColor.textPrimary
        )
        .disabled(disabled)
        .accessibilityLabel(label.localizedUI)
        .help(label)
    }

    private var pages: [IndexedPageText] {
        cachedPages
    }

    private var currentPage: IndexedPageText {
        pages[min(max(selectedIndex, 0), pages.count - 1)]
    }

    private var pageCount: Int {
        model.record(id: recordID)?.profile.pageCount ?? pages.count
    }

    private var sourceTitle: String {
        switch model.textIndices[recordID]?.source {
        case .vision: return "LOCAL OCR"
        case .searchableCopy: return "TEXT LAYER"
        case .native, nil: return "PDF TEXT"
        }
    }

    private func reflowedText(_ value: String) -> String {
        let rawLines = value.components(separatedBy: .newlines)
        var paragraphs: [String] = []
        var current = ""

        func flush() {
            let normalized = current.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !normalized.isEmpty {
                paragraphs.append(normalized)
            }
            current = ""
        }

        for rawLine in rawLines {
            let line = rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !line.isEmpty else {
                flush()
                continue
            }
            let isBullet = line.hasPrefix("•")
                || line.hasPrefix("- ")
                || line.hasPrefix("– ")
                || line.range(
                    of: #"^\d+[\.)]\s+"#,
                    options: .regularExpression
                ) != nil
            let letters = line.filter(\.isLetter)
            let isHeading = line.count <= 72
                && !letters.isEmpty
                && (
                    letters.allSatisfy(\.isUppercase)
                        || line.hasSuffix(":")
                )
            if isBullet || isHeading {
                flush()
                paragraphs.append(line)
                continue
            }
            guard !current.isEmpty else {
                current = line
                continue
            }
            if current.last == "-",
               line.first?.isLowercase == true {
                current.removeLast()
                current += line
            } else {
                let joinsWithoutSpace = current.last?.isCJK == true
                    && line.first?.isCJK == true
                current += joinsWithoutSpace ? line : " " + line
            }
        }
        flush()
        return paragraphs.joined(separator: "\n\n")
    }

    private func selectInitialPage() {
        guard !pages.isEmpty else { return }
        selectedIndex = pages.firstIndex {
            $0.pageIndex >= initialPageIndex
        } ?? pages.count - 1
        visiblePageID = currentPage.pageIndex
    }
}

@MainActor
private final class PDFReadAloudController:
    NSObject,
    ObservableObject,
    AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentPageOffset: Int?

    private let synthesizer = AVSpeechSynthesizer()
    private var queuedPageCount = 0
    private var textForPage: ((Int) -> String?)?
    private var nextPageOffset = 0
    private var speechRate = AVSpeechUtteranceDefaultSpeechRate

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isActive: Bool {
        isSpeaking || isPaused
    }

    func toggle(
        pageCount: Int,
        startingAt index: Int,
        rate: Float,
        textForPage: @escaping (Int) -> String?
    ) {
        if isSpeaking {
            if synthesizer.pauseSpeaking(at: .word) {
                isSpeaking = false
                isPaused = true
            }
            return
        }
        if isPaused {
            if synthesizer.continueSpeaking() {
                isSpeaking = true
                isPaused = false
            }
            return
        }
        queuedPageCount = pageCount
        self.textForPage = textForPage
        nextPageOffset = min(
            max(index, 0),
            max(0, pageCount - 1)
        )
        speechRate = min(max(rate, 0.38), 0.62)
        speakNextPage()
    }

    private func speakNextPage() {
        guard nextPageOffset >= 0,
              nextPageOffset < queuedPageCount
        else {
            finishQueue()
            return
        }
        let offset = nextPageOffset
        nextPageOffset += 1
        let value = String(
            (textForPage?(offset) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(24_000)
        )
        guard !value.isEmpty else {
            speakNextPage()
            return
        }
        let utterance = AVSpeechUtterance(string: value)
        if let language = NLLanguageRecognizer.dominantLanguage(
            for: String(value.prefix(1_000))
        )?.rawValue {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = speechRate
        currentPageOffset = offset
        synthesizer.speak(utterance)
        isSpeaking = true
        isPaused = false
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        queuedPageCount = 0
        textForPage = nil
        nextPageOffset = 0
        currentPageOffset = nil
    }

    private func finishQueue() {
        isSpeaking = false
        isPaused = false
        queuedPageCount = 0
        textForPage = nil
        nextPageOffset = 0
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.speakNextPage()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            self?.isSpeaking = false
            self?.isPaused = false
        }
    }
}
