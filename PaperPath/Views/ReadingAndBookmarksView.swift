import AVFoundation
import NaturalLanguage
import PDFKit
import SwiftUI

struct ReadingSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var preferences: PDFReadingPreferences

    var body: some View {
        NavigationStack {
            Form {
                Section("Reading background".localizedUI) {
                    ForEach(PDFReadingTheme.allCases) { theme in
                        Button {
                            preferences.theme = theme
                        } label: {
                            HStack(spacing: PPSpacing.medium) {
                                Circle()
                                    .fill(themeSwatch(theme))
                                    .frame(width: 24, height: 24)
                                    .overlay(Circle().stroke(PPColor.border, lineWidth: 0.6))
                                Text(theme.title.localizedUI)
                                    .foregroundStyle(PPColor.textPrimary)
                                Spacer(minLength: PPSpacing.small)
                                Image(systemName: "checkmark")
                                    .foregroundStyle(PPColor.accent)
                                    .opacity(preferences.theme == theme ? 1 : 0)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(preferences.theme == theme ? .isSelected : [])
                        .accessibilityIdentifier("readingTheme-\(theme.rawValue)")
                    }
                }
                Section("Page layout".localizedUI) {
                    pageLayoutPicker
                        .accessibilityIdentifier("readingLayout")
                    Toggle(
                        "Horizontal navigation",
                        isOn: $preferences.scrollsHorizontally
                    )
                    .disabled(preferences.layout == .continuous)
                    .onChange(of: preferences.layout) {
                        if preferences.layout == .continuous {
                            preferences.scrollsHorizontally = false
                        }
                    }
                }
                Section {
                    Button {
                        preferences = PDFReadingPreferences()
                    } label: {
                        Label(
                            "Reset reading settings".localizedUI,
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .disabled(preferences == PDFReadingPreferences())
                    .accessibilityIdentifier("resetReadingSettings")
                }
            }
            .scrollContentBackground(.hidden)
            .background(PPColor.canvas)
            .navigationTitle("Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .accessibilityAction(.escape) {
            dismiss()
        }
    }

    @ViewBuilder
    private var pageLayoutPicker: some View {
        let picker = Picker(
            "Page layout",
            selection: $preferences.layout
        ) {
            ForEach(PDFReadingLayout.allCases) { layout in
                Text(layout.title.localizedUI)
                    .tag(layout)
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
        } else {
            picker.pickerStyle(.segmented)
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
        var title: String {
            switch self {
            case .bookmarks: return "Bookmarks"
            case .outline: return "Outline"
            case .labels: return "Labels"
            }
        }
    }

    struct OutlineEntry: Identifiable, Sendable {
        let id = UUID()
        let title: String
        let pageIndex: Int
        let level: Int
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let currentPageIndex: Int
    let onSelect: (Int) -> Void
    let onCreated: (DocumentRoute) -> Void
    @State private var outline: [OutlineEntry] = []
    @State private var pageLabelCount = 0
    @State private var pageLabelByIndex: [Int: String] = [:]
    @State private var pageIndexByNormalizedLabel: [String: Int] = [:]
    @State private var searchText = ""
    @State private var pageInput = ""
    @State private var isEditingPageLabels = false
    @State private var pendingCreatedRoute: DocumentRoute?
    @State private var namingBookmarkPage: Int?
    @State private var bookmarkName = ""
    @State private var navigationMode = NavigationMode.bookmarks
    @State private var isLoadingNavigation = true
    @State private var navigationLoadErrorMessage: String?
    @State private var navigationReloadToken = UUID()
    @State private var loadGeneration = 0
    @State private var lifecycleGeneration = UUID()
    @State private var protectedDataAvailable =
        UIApplication.shared.isProtectedDataAvailable
    @State private var outlineCreationTask: Task<Void, Never>?
    @State private var outlineCreationGeneration = UUID()
    @State private var outlineCreationStopRequested = false
    @State private var bookmarkSaveTask: Task<Void, Never>?
    @State private var bookmarkSaveGeneration = UUID()
    @State private var bookmarkSaveStopRequested = false
    @State private var bookmarkSaveErrorMessage: String?
    @State private var pageLabelTransitionTask: Task<Void, Never>?
    @State private var pageLabelTransitionGeneration = UUID()
    @State private var outlineCreationErrorMessage: String?
    @State private var navigationErrorFeedback = 0
    @State private var navigationSuccessFeedback = 0
    @State private var pageInputErrorMessage: String?
    @State private var loadedContentRevisionID: UUID?
    @FocusState private var bookmarkNameFocused: Bool

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
                            navigationModePicker
                            if let navigationOperationStatus {
                                HStack(spacing: PPSpacing.small) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text(
                                        navigationOperationStatus
                                            .localizedUI
                                    )
                                    .font(
                                        .caption.weight(.semibold)
                                    )
                                    .foregroundStyle(
                                        PPColor.textPrimary
                                    )
                                    Spacer(minLength: 0)
                                    OnDeviceBadge(compact: true)
                                }
                                .frame(minHeight: 44)
                                .accessibilityElement(
                                    children: .combine
                                )
                                .accessibilityAddTraits(
                                    .updatesFrequently
                                )
                            }
                            if let bookmarkSaveErrorMessage {
                                Label(
                                    bookmarkSaveErrorMessage,
                                    systemImage:
                                        "exclamationmark.circle"
                                )
                                .font(.caption)
                                .foregroundStyle(PPColor.rose)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                            }

                            navigationContent(record)
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
                prompt: "Search bookmark, outline, or label"
            )
            .submitLabel(.search)
            .onSubmit(of: .search) {
                dismissSearch()
            }
            .onChange(of: searchText) { _, value in
                if value.count > 200 {
                    searchText = String(value.prefix(200))
                }
            }
            .onChange(of: pageInput) { _, value in
                if value.count > 128 {
                    pageInput = String(value.prefix(128))
                }
                pageInputErrorMessage = nil
            }
            .onChange(of: bookmarkName) { _, value in
                if value.count > 80 {
                    bookmarkName = String(value.prefix(80))
                }
                bookmarkSaveErrorMessage = nil
            }
            .onChange(of: namingBookmarkPage) { _, pageIndex in
                guard pageIndex != nil else {
                    bookmarkNameFocused = false
                    return
                }
                Task { @MainActor in
                    await Task.yield()
                    guard namingBookmarkPage != nil else { return }
                    bookmarkNameFocused = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(
                        (
                            outlineCreationStopRequested
                                || bookmarkSaveStopRequested
                                ? "Stopping"
                                : hasActiveNavigationTask
                                    ? "Stop"
                                    : "Done"
                        ).localizedUI
                    ) {
                        if hasActiveNavigationTask {
                            interruptActiveNavigationTask()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(
                        outlineCreationStopRequested
                            || bookmarkSaveStopRequested
                    )
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .task(id: navigationLoadRequestID) {
                loadGeneration += 1
                let generation = loadGeneration
                isLoadingNavigation = true
                navigationLoadErrorMessage = nil
                loadedContentRevisionID = nil
                guard !Task.isCancelled,
                      scenePhase == .active,
                      protectedDataAvailable,
                      UIApplication.shared.isProtectedDataAvailable
                else {
                    isLoadingNavigation = false
                    return
                }
                guard let requestedRevisionID =
                        model.record(id: recordID)?
                            .contentRevisionID,
                      let url = model.url(for: recordID)
                else {
                    isLoadingNavigation = false
                    navigationLoadErrorMessage =
                        "The private working copy could not be opened."
                            .localizedUI
                    return
                }
                async let loadedOutline = Self.loadOutline(from: url)
                async let loadedLabels = model.pageLabels(
                    recordID: recordID
                )
                let values = await (loadedOutline, loadedLabels)
                let labelIndexes = await Self.indexPageLabels(values.1)
                guard !Task.isCancelled,
                      generation == loadGeneration,
                      scenePhase == .active,
                      protectedDataAvailable,
                      UIApplication.shared.isProtectedDataAvailable,
                      model.record(id: recordID)?
                        .contentRevisionID == requestedRevisionID
                else { return }
                guard let loadedOutline = values.0 else {
                    isLoadingNavigation = false
                    navigationLoadErrorMessage =
                        "The private working copy could not be opened."
                            .localizedUI
                    return
                }
                outline = loadedOutline
                pageLabelCount = values.1.count
                pageLabelByIndex = labelIndexes.byPage
                pageIndexByNormalizedLabel = labelIndexes.byLabel
                loadedContentRevisionID = requestedRevisionID
                isLoadingNavigation = false
                if model.record(id: recordID)?
                    .bookmarkedPages.isEmpty == true,
                   !outline.isEmpty {
                    navigationMode = .outline
                }
            }
            .sheet(
                isPresented: $isEditingPageLabels,
                onDismiss: completePageLabelTransition
            ) {
                if let record = model.record(id: recordID),
                   let loadedContentRevisionID,
                   record.contentRevisionID
                    == loadedContentRevisionID {
                    PageLabelEditorSheet(
                        recordID: recordID,
                        pageCount: record.profile.pageCount,
                        expectedContentRevisionID:
                            loadedContentRevisionID
                    ) { route in
                        pendingCreatedRoute =
                            route.bindingExpectedRevision(
                                model.record(id: route.recordID)?
                                    .contentRevisionID
                            )
                        isEditingPageLabels = false
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
                            bookmarkSaveErrorMessage = nil
                        }
                    }
                )
            ) {
                TextField("Optional name", text: $bookmarkName)
                    .focused($bookmarkNameFocused)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    saveNamedBookmark()
                }
                .disabled(bookmarkSaveTask != nil)
            } message: {
                Text(
                    bookmarkSaveErrorMessage
                        ?? "The name stays in PaperPath metadata."
                )
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    protectedDataAvailable =
                        UIApplication.shared.isProtectedDataAvailable
                    lifecycleGeneration = UUID()
                } else if phase == .background {
                    interruptProtectedNavigationWork()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                protectedDataAvailable = false
                interruptProtectedNavigationWork()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataDidBecomeAvailableNotification
                )
            ) { _ in
                protectedDataAvailable = true
                guard scenePhase == .active else { return }
                lifecycleGeneration = UUID()
            }
            .onDisappear {
                interruptProtectedNavigationWork()
            }
            .sensoryFeedback(
                .error,
                trigger: navigationErrorFeedback
            )
            .sensoryFeedback(
                .success,
                trigger: navigationSuccessFeedback
            )
            .sensoryFeedback(
                .selection,
                trigger: navigationMode
            )
        }
        .interactiveDismissDisabled(hasActiveNavigationTask)
        .accessibilityAction(.escape) {
            if hasActiveNavigationTask {
                interruptActiveNavigationTask()
            } else {
                dismiss()
            }
        }
    }

    @ViewBuilder
    private func navigationContent(
        _ record: DocumentRecord
    ) -> some View {
        if isLoadingNavigation {
            PPEmptyState(
                kind: .processing,
                title: "Loading navigation",
                message: "Reading bookmarks, outlines, and page labels on this device."
            )
            .padding(.vertical, PPSpacing.large)
        } else if let navigationLoadErrorMessage {
            VStack(spacing: PPSpacing.medium) {
                PPEmptyState(
                    kind: .tools,
                    title: "Couldn’t load navigation",
                    message: navigationLoadErrorMessage
                )
                Button {
                    navigationReloadToken = UUID()
                } label: {
                    Label(
                        "Load Navigation Again",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(PPQuietButtonStyle(tint: PPColor.accent))
                .accessibilityIdentifier("retryNavigationLoad")
            }
            .padding(.vertical, PPSpacing.large)
        } else {
            switch navigationMode {
            case .bookmarks:
                bookmarksContent(record)
            case .outline:
                outlineContent
            case .labels:
                pageLabelsContent(record)
            }
        }
    }

    @ViewBuilder
    private var navigationModePicker: some View {
        let picker = Picker(
            "Navigation mode",
            selection: $navigationMode
        ) {
            ForEach(NavigationMode.allCases) { mode in
                Text(mode.title.localizedUI)
                    .tag(mode)
            }
        }
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                picker
                    .pickerStyle(.menu)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 44,
                        alignment: .leading
                    )
            } else {
                picker.pickerStyle(.segmented)
            }
        }
        .disabled(hasActiveNavigationTask)
    }

    private func navigationHeader(
        _ record: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            Text(record.displayName)
                .font(PPType.document)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            Text(AppLocalization.format(
                "Page %lld of %lld", currentPageIndex + 1, record.profile.pageCount
            ))
            .font(PPType.measure)
            .foregroundStyle(PPColor.textSecondary)
        }
        .accessibilityIdentifier("navigationDocumentContext")
    }

    private func pageJump(
        _ record: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            Group {
                if dynamicTypeSize.ppPrefersExpandedLayout {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.xSmall
                    ) {
                        pageJumpField(record)
                        Rectangle()
                            .fill(PPColor.border.opacity(0.58))
                            .frame(height: 0.6)
                        currentBookmarkButton(record)
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                    }
                } else {
                    HStack(spacing: PPSpacing.small) {
                        pageJumpField(record)
                        Rectangle()
                            .fill(PPColor.border.opacity(0.58))
                            .frame(width: 0.6, height: 28)
                        currentBookmarkButton(record)
                    }
                }
            }
            if let pageInputErrorMessage {
                Label(
                    pageInputErrorMessage,
                    systemImage: "exclamationmark.circle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.rose)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, PPSpacing.small)
        .frame(minHeight: 44)
        .background(PPColor.surface.opacity(0.72))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func pageJumpField(
        _ record: DocumentRecord
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            TextField(
                "Page number or label".localizedUI,
                text: $pageInput
            )
            .textFieldStyle(.plain)
            .submitLabel(.go)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit { openTypedPage(record) }
            .disabled(hasActiveNavigationTask)
            .accessibilityIdentifier("navigationPageInput")
            Button {
                openTypedPage(record)
            } label: {
                Label(
                    "Go".localizedUI,
                    systemImage: "arrow.right.circle.fill"
                )
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(
                hasActiveNavigationTask
                    || isLoadingNavigation
                    || pageInput.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            )
            .accessibilityLabel("Go to page".localizedUI)
            .accessibilityHint(pageJumpAccessibilityHint(record))
            .accessibilityIdentifier("navigationGoToPage")
        }
    }

    private func currentBookmarkButton(
        _ record: DocumentRecord
    ) -> some View {
        Button {
            bookmarkSaveErrorMessage = nil
            if record.bookmarkedPages.contains(currentPageIndex) {
                toggleBookmark(currentPageIndex)
            } else {
                bookmarkName = ""
                namingBookmarkPage = currentPageIndex
            }
        } label: {
            Label(
                (
                    record.bookmarkedPages.contains(currentPageIndex)
                        ? "Remove current bookmark"
                        : "Bookmark current page"
                ).localizedUI,
                systemImage:
                    record.bookmarkedPages.contains(currentPageIndex)
                    ? "bookmark.slash"
                    : "bookmark"
            )
            .font(.caption.weight(.semibold))
            .lineLimit(
                dynamicTypeSize.ppPrefersExpandedLayout ? 2 : 1
            )
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PPColor.accent)
        .disabled(hasActiveNavigationTask || isLoadingNavigation)
        .accessibilityIdentifier("navigationCurrentBookmark")
    }

    @ViewBuilder
    private func bookmarksContent(
        _ record: DocumentRecord
    ) -> some View {
        let bookmarks = filteredBookmarks(record)
        if bookmarks.isEmpty {
            navigationEmpty(
                title:
                    hasNavigationQuery
                        ? "No matching bookmarks"
                        : "No bookmarks",
                detail:
                    hasNavigationQuery
                        ? "Try a bookmark name or page number."
                        : "Bookmark the current page to return here quickly.",
                symbol: "bookmark"
            )
        } else {
            LazyVStack(spacing: 0) {
                if hasNavigationQuery {
                    navigationResultHeader(
                        count: bookmarks.count
                    )
                }
                ForEach(bookmarks, id: \.self) { page in
                    bookmarkRow(record, page: page)
                }

                Button {
                    createOutlineCopy()
                } label: {
                    Label(
                        outlineCreationTask == nil
                            ? "Create PDF Outline Copy"
                            : "Creating outline copy",
                        systemImage: outlineCreationTask == nil
                            ? "list.bullet.indent"
                            : "hourglass"
                    )
                    .font(.caption.weight(.semibold))
                    .frame(
                        maxWidth:
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? .infinity
                                : nil,
                        minHeight: 44,
                        alignment: .leading
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(PPColor.accent)
                .disabled(
                    model.isProcessing(recordID)
                        || hasActiveNavigationTask
                )
                .padding(.top, PPSpacing.small)
                if let outlineCreationErrorMessage {
                    Label(
                        outlineCreationErrorMessage,
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(PPColor.rose)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bookmarkRow(
        _ record: DocumentRecord,
        page: Int
    ) -> some View {
        let layout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                )
            )
            : AnyLayout(
                HStackLayout(spacing: PPSpacing.small)
            )
        let displayName =
            record.bookmarkNames[page]
                ?? AppLocalization.format(
                    "Page %lld",
                    page + 1
                )

        return layout {
            Button {
                choose(page)
            } label: {
                HStack(spacing: PPSpacing.small) {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(PPColor.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                            .lineLimit(
                                dynamicTypeSize.ppPrefersExpandedLayout
                                    ? 3
                                    : 1
                            )
                        Text(
                            AppLocalization.format(
                                "%@ · Page %lld",
                                pageLabel(for: page),
                                page + 1
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                    }
                    Spacer(minLength: PPSpacing.small)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: 44,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(hasActiveNavigationTask)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayName)
            .accessibilityValue(
                AppLocalization.format(
                    "Page %lld",
                    page + 1
                )
            )
            .accessibilityHint(
                "Opens this bookmark in the PDF.".localizedUI
            )

            HStack(spacing: 0) {
                Button {
                    bookmarkSaveErrorMessage = nil
                    bookmarkName =
                        record.bookmarkNames[page] ?? ""
                    namingBookmarkPage = page
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename bookmark".localizedUI)
                .accessibilityValue(displayName)
                .disabled(hasActiveNavigationTask)

                Button(role: .destructive) {
                    bookmarkSaveErrorMessage = nil
                    toggleBookmark(page)
                } label: {
                    Image(systemName: "bookmark.slash")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("Remove bookmark".localizedUI)
                .accessibilityValue(displayName)
                .disabled(hasActiveNavigationTask)
            }
            .frame(
                maxWidth:
                    dynamicTypeSize.ppPrefersExpandedLayout
                        ? .infinity
                        : nil,
                alignment: .trailing
            )
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
                .padding(.leading, 38)
        }
    }

    @ViewBuilder
    private var outlineContent: some View {
        if filteredOutline.isEmpty {
            navigationEmpty(
                title:
                    hasNavigationQuery
                        ? "No matching outline entries"
                        : "No document outline",
                detail:
                    hasNavigationQuery
                        ? "Try another heading or page number."
                        : "This PDF does not contain an outline.",
                symbol: "list.bullet.indent"
            )
        } else {
            LazyVStack(spacing: 0) {
                if hasNavigationQuery {
                    navigationResultHeader(
                        count: filteredOutline.count
                    )
                }
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
                                .lineLimit(
                                    dynamicTypeSize.ppPrefersExpandedLayout
                                        ? 3
                                        : 1
                                )
                            Spacer()
                            Text(pageLabel(for: entry.pageIndex))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(PPColor.textSecondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(PPColor.textSecondary)
                        }
                        .padding(.leading, min(CGFloat(entry.level), 4) * 10)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(hasActiveNavigationTask)
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

    @ViewBuilder
    private func pageLabelsContent(
        _ record: DocumentRecord
    ) -> some View {
        if hasNavigationQuery {
            if let pageIndex = matchingPageLabelIndex(record) {
                VStack(spacing: 0) {
                    navigationResultHeader(count: 1)
                    Button {
                        choose(pageIndex)
                    } label: {
                        HStack(spacing: PPSpacing.small) {
                            Image(systemName: "number.square.fill")
                                .foregroundStyle(PPColor.amber)
                                .frame(width: 28)
                            VStack(
                                alignment: .leading,
                                spacing: 2
                            ) {
                                Text(pageLabel(for: pageIndex))
                                    .font(
                                        .subheadline.monospaced()
                                            .weight(.semibold)
                                    )
                                    .foregroundStyle(
                                        PPColor.textPrimary
                                    )
                                Text(
                                    AppLocalization.format(
                                        "Page %lld",
                                        pageIndex + 1
                                    )
                                )
                                .font(.caption)
                                .foregroundStyle(
                                    PPColor.textSecondary
                                )
                            }
                            Spacer(minLength: PPSpacing.small)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(
                                    PPColor.textSecondary
                                )
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(hasActiveNavigationTask)
                    .accessibilityHint(
                        "Opens this page label in the PDF."
                            .localizedUI
                    )
                }
            } else {
                navigationEmpty(
                    title: "No matching page label",
                    detail:
                        "Enter an exact page label or page number.",
                    symbol: "number.square"
                )
            }
        } else {
            VStack(alignment: .leading, spacing: PPSpacing.medium) {
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(
                                minimum: 130,
                                maximum: 260
                            ),
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
                            for: max(
                                0,
                                record.profile.pageCount - 1
                            )
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
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.amber)
                )
                .disabled(hasActiveNavigationTask)
            }
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

    private func navigationEmpty(
        title: String,
        detail: String,
        symbol: String
    ) -> some View {
        VStack(spacing: PPSpacing.small) {
            compactNavigationEmpty(
                title: title,
                detail: detail,
                symbol: symbol
            )
            if !searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                Button {
                    clearNavigationSearch()
                } label: {
                    Label(
                        "Clear Search",
                        systemImage: "xmark.circle"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.accent)
                )
                .accessibilityIdentifier(
                    "navigationClearSearch"
                )
            }
        }
    }

    private func navigationResultHeader(
        count: Int
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Label(
                AppLocalization.format(
                    "Results: %lld",
                    count
                ),
                systemImage: "magnifyingglass"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(PPColor.textSecondary)
            .monospacedDigit()
            Spacer(minLength: 0)
            Button {
                clearNavigationSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(PPColor.textSecondary)
            .accessibilityLabel("Clear Search".localizedUI)
        }
        .frame(minHeight: 44)
    }

    private var hasNavigationQuery: Bool {
        !searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    }

    private func clearNavigationSearch() {
        searchText = ""
        dismissSearch()
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
        let pages = Array(
            Set(
                record.bookmarkedPages.filter {
                    $0 >= 0 && $0 < record.profile.pageCount
                }
            )
        ).sorted()
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

    private func matchingPageLabelIndex(
        _ record: DocumentRecord
    ) -> Int? {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return nil }
        if let page = Int(query),
           page >= 1,
           page <= record.profile.pageCount {
            return page - 1
        }
        return pageIndexByNormalizedLabel[
            Self.normalizedPageLabel(query)
        ]
    }

    private func pageLabel(for index: Int) -> String {
        pageLabelByIndex[index] ?? String(index + 1)
    }

    private func typedPageIndex(
        _ record: DocumentRecord
    ) -> Int? {
        let query = pageInput.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !query.isEmpty else { return nil }
        if let page = Int(query),
           page >= 1,
           page <= record.profile.pageCount {
            return page - 1
        }
        return pageIndexByNormalizedLabel[
            Self.normalizedPageLabel(query)
        ]
    }

    private func openTypedPage(_ record: DocumentRecord) {
        guard !hasActiveNavigationTask else { return }
        guard let index = typedPageIndex(record) else {
            pageInputErrorMessage = AppLocalization.format(
                "Enter a page from 1 to %lld or an existing page label.",
                record.profile.pageCount
            )
            navigationErrorFeedback += 1
            return
        }
        pageInputErrorMessage = nil
        choose(index)
    }

    private func pageJumpAccessibilityHint(
        _ record: DocumentRecord
    ) -> String {
        if typedPageIndex(record) != nil {
            return "Opens the entered page.".localizedUI
        }
        return AppLocalization.format(
            "Enter a page from 1 to %lld or an existing page label.",
            record.profile.pageCount
        )
    }

    private var navigationLoadRequestID: String {
        [
            model.record(id: recordID)?
                .contentRevisionID.uuidString ?? "missing",
            String(model.refreshToken(for: recordID)),
            lifecycleGeneration.uuidString,
            navigationReloadToken.uuidString
        ].joined(separator: "-")
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
        guard let loadedContentRevisionID,
              let record = model.record(id: recordID),
              pageIndex >= 0, pageIndex < record.profile.pageCount,
              model.record(id: recordID)?.contentRevisionID
                == loadedContentRevisionID
        else {
            navigationLoadErrorMessage =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            navigationErrorFeedback &+= 1
            navigationReloadToken = UUID()
            return
        }
        onSelect(pageIndex)
    }

    private func saveNamedBookmark() {
        guard let page = namingBookmarkPage,
              !hasActiveNavigationTask
        else { return }
        guard let loadedContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == loadedContentRevisionID
        else {
            bookmarkSaveErrorMessage =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            navigationErrorFeedback &+= 1
            navigationReloadToken = UUID()
            return
        }
        let name = bookmarkName
        bookmarkSaveErrorMessage = nil
        namingBookmarkPage = nil
        bookmarkName = ""
        let generation = UUID()
        bookmarkSaveGeneration = generation
        bookmarkSaveStopRequested = false
        bookmarkSaveTask = Task { @MainActor in
            let saved = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.saveBookmark(
                    recordID: recordID,
                    pageIndex: page,
                    name: name,
                    expectedContentRevisionID:
                        loadedContentRevisionID
                )
            }
            guard bookmarkSaveGeneration == generation else { return }
            let wasStopped =
                bookmarkSaveStopRequested || Task.isCancelled
            bookmarkSaveTask = nil
            bookmarkSaveStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    saved
                        ? "Bookmark update finished before stopping · changes kept"
                        : "Bookmark update stopped"
                ).localizedUI
                return
            }
            if saved {
                navigationSuccessFeedback += 1
                return
            }
            await Task.yield()
            guard bookmarkSaveGeneration == generation,
                  scenePhase == .active
            else { return }
            bookmarkName = name
            bookmarkSaveErrorMessage =
                "The bookmark could not be saved. Try again."
                    .localizedUI
            navigationErrorFeedback += 1
            namingBookmarkPage = page
        }
    }

    private func toggleBookmark(_ pageIndex: Int) {
        guard !hasActiveNavigationTask else { return }
        guard let loadedContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == loadedContentRevisionID
        else {
            bookmarkSaveErrorMessage =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            navigationErrorFeedback &+= 1
            navigationReloadToken = UUID()
            return
        }
        bookmarkSaveErrorMessage = nil
        let generation = UUID()
        bookmarkSaveGeneration = generation
        bookmarkSaveStopRequested = false
        bookmarkSaveTask = Task { @MainActor in
            let saved = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.toggleBookmark(
                    recordID: recordID,
                    pageIndex: pageIndex,
                    expectedContentRevisionID:
                        loadedContentRevisionID
                )
            }
            guard bookmarkSaveGeneration == generation else { return }
            let wasStopped =
                bookmarkSaveStopRequested || Task.isCancelled
            bookmarkSaveTask = nil
            bookmarkSaveStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    saved
                        ? "Bookmark update finished before stopping · changes kept"
                        : "Bookmark update stopped"
                ).localizedUI
                return
            }
            if saved {
                navigationSuccessFeedback &+= 1
            } else {
                bookmarkSaveErrorMessage =
                    "The bookmark could not be updated. Try again."
                        .localizedUI
                navigationErrorFeedback &+= 1
            }
        }
    }

    private func createOutlineCopy() {
        guard !hasActiveNavigationTask,
              !model.isProcessing(recordID),
              let loadedContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == loadedContentRevisionID,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        outlineCreationErrorMessage = nil
        outlineCreationStopRequested = false
        let generation = UUID()
        outlineCreationGeneration = generation
        outlineCreationTask = Task { @MainActor in
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createBookmarkOutlineCopy(
                    recordID: recordID,
                    expectedContentRevisionID:
                        loadedContentRevisionID
                )
            }
            guard outlineCreationGeneration == generation else { return }
            let wasStopped =
                outlineCreationStopRequested || Task.isCancelled
            outlineCreationTask = nil
            outlineCreationStopRequested = false
            if wasStopped {
                model[noticeFor: paperPathSceneID] = (
                    created == nil
                        ? "Copy creation stopped"
                        : "Copy finished before stopping · copy kept in Library"
                ).localizedUI
                return
            }
            guard let created else {
                outlineCreationErrorMessage =
                    "The outline copy could not be created. Try again."
                        .localizedUI
                navigationErrorFeedback += 1
                return
            }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func completePageLabelTransition() {
        guard let route = pendingCreatedRoute else { return }
        pendingCreatedRoute = nil
        pageLabelTransitionTask?.cancel()
        let generation = UUID()
        pageLabelTransitionGeneration = generation
        pageLabelTransitionTask = Task { @MainActor in
            defer {
                if pageLabelTransitionGeneration == generation {
                    pageLabelTransitionTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  pageLabelTransitionGeneration == generation,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  model.record(id: route.recordID) != nil
            else { return }
            onCreated(route)
        }
    }

    private func interruptOutlineCreation(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            outlineCreationGeneration = UUID()
            outlineCreationStopRequested = false
        } else {
            guard outlineCreationTask != nil,
                  !outlineCreationStopRequested
            else { return }
            outlineCreationStopRequested = true
        }
        outlineCreationTask?.cancel()
        if invalidateResult {
            outlineCreationTask = nil
        }
    }

    private var hasActiveNavigationTask: Bool {
        outlineCreationTask != nil
            || bookmarkSaveTask != nil
    }

    private var navigationOperationStatus: String? {
        if outlineCreationTask != nil {
            return outlineCreationStopRequested
                ? "Finishing current file commit"
                : "Creating outline copy"
        }
        if bookmarkSaveTask != nil {
            return bookmarkSaveStopRequested
                ? "Finishing bookmark update"
                : "Saving bookmark"
        }
        return nil
    }

    private func interruptActiveNavigationTask() {
        interruptOutlineCreation()
        interruptBookmarkSave()
    }

    private func interruptBookmarkSave(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            bookmarkSaveGeneration = UUID()
            bookmarkSaveStopRequested = false
        } else {
            guard bookmarkSaveTask != nil,
                  !bookmarkSaveStopRequested
            else { return }
            bookmarkSaveStopRequested = true
        }
        bookmarkSaveTask?.cancel()
        if invalidateResult {
            bookmarkSaveTask = nil
        }
    }

    private func interruptProtectedNavigationWork() {
        lifecycleGeneration = UUID()
        loadGeneration += 1
        outline.removeAll(keepingCapacity: false)
        pageLabelCount = 0
        pageLabelByIndex.removeAll(keepingCapacity: false)
        pageIndexByNormalizedLabel.removeAll(keepingCapacity: false)
        loadedContentRevisionID = nil
        searchText = ""
        pageInput = ""
        pageInputErrorMessage = nil
        bookmarkName = ""
        bookmarkSaveErrorMessage = nil
        namingBookmarkPage = nil
        isEditingPageLabels = false
        pendingCreatedRoute = nil
        pageLabelTransitionGeneration = UUID()
        pageLabelTransitionTask?.cancel()
        pageLabelTransitionTask = nil
        isLoadingNavigation = true
        navigationLoadErrorMessage = nil
        interruptBookmarkSave(invalidateResult: true)
        outlineCreationErrorMessage = nil
        interruptOutlineCreation(invalidateResult: true)
    }

    private nonisolated static func normalizedPageLabel(
        _ label: String
    ) -> String {
        label.folding(
            options: [
                .caseInsensitive,
                .diacriticInsensitive,
                .widthInsensitive
            ],
            locale: .current
        )
    }

    private static func indexPageLabels(
        _ labels: [PDFPageLabelSnapshot]
    ) async -> (
        byPage: [Int: String],
        byLabel: [String: Int]
    ) {
        let worker = Task.detached(
            priority: .utility
        ) { () -> ([Int: String], [String: Int]) in
            var byPage: [Int: String] = [:]
            var byLabel: [String: Int] = [:]
            byPage.reserveCapacity(labels.count)
            byLabel.reserveCapacity(labels.count)
            for (offset, snapshot) in labels.enumerated() {
                if offset.isMultiple(of: 256),
                   Task.isCancelled {
                    return ([:], [:])
                }
                byPage[snapshot.pageIndex] = snapshot.label
                let key = normalizedPageLabel(snapshot.label)
                if !key.isEmpty,
                   byLabel[key] == nil {
                    byLabel[key] = snapshot.pageIndex
                }
            }
            return (byPage, byLabel)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func loadOutline(
        from url: URL
    ) async -> [OutlineEntry]? {
        let worker = Task.detached(
            priority: .utility
        ) { () -> [OutlineEntry]? in
            guard !Task.isCancelled,
                  let document = PDFDocument(url: url) else {
                return nil
            }
            guard let root = document.outlineRoot else {
                return []
            }
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
                                        label.flatMap {
                                            $0.isEmpty ? nil : $0
                                        } ?? "Untitled".localizedUI
                                    )
                                    .prefix(160)
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
            return Task.isCancelled ? nil : result
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

private struct PageLabelEditorSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let pageCount: Int
    let expectedContentRevisionID: UUID
    let onCreated: (DocumentRoute) -> Void
    private let initialRules: [PDFPageLabelRule]

    @State private var rules: [PDFPageLabelRule]
    @State private var isCreating = false
    @State private var createTask: Task<Void, Never>?
    @State private var createGeneration = UUID()
    @State private var createStopRequested = false
    @State private var isConfirmingDiscard = false
    @State private var creationErrorMessage: String?
    @State private var creationErrorFeedback = 0

    init(
        recordID: UUID,
        pageCount: Int,
        expectedContentRevisionID: UUID,
        onCreated: @escaping (DocumentRoute) -> Void
    ) {
        self.recordID = recordID
        self.pageCount = pageCount
        self.expectedContentRevisionID =
            expectedContentRevisionID
        self.onCreated = onCreated
        let initialRules = [
            PDFPageLabelRule(
                startPageIndex: 0,
                style: .decimal
            )
        ]
        self.initialRules = initialRules
        _rules = State(initialValue: initialRules)
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
                                if dynamicTypeSize.ppPrefersExpandedLayout {
                                    VStack(
                                        alignment: .leading,
                                        spacing: PPSpacing.xSmall
                                    ) {
                                        SectionEyebrow(
                                            text: rule.startPageIndex == 0
                                                ? "FIRST RANGE"
                                                : "FROM PAGE \(rule.startPageIndex + 1)"
                                        )
                                        HStack(spacing: PPSpacing.small) {
                                            rulePreview(rule)
                                            Spacer(minLength: PPSpacing.small)
                                            if rules.count > 1 {
                                                removeRuleButton(rule.id)
                                            }
                                        }
                                    }
                                } else {
                                    HStack {
                                        SectionEyebrow(
                                            text: rule.startPageIndex == 0
                                                ? "FIRST RANGE"
                                                : "FROM PAGE \(rule.startPageIndex + 1)"
                                        )
                                        Spacer()
                                        rulePreview(rule)
                                        if rules.count > 1 {
                                            removeRuleButton(rule.id)
                                        }
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

                                let editorLayout =
                                    dynamicTypeSize.ppPrefersExpandedLayout
                                    ? AnyLayout(
                                        VStackLayout(
                                            alignment: .leading,
                                            spacing: PPSpacing.small
                                        )
                                    )
                                    : AnyLayout(
                                        HStackLayout(
                                            spacing: PPSpacing.medium
                                        )
                                    )
                                editorLayout {
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
                                        .fixedSize(
                                            horizontal:
                                                !dynamicTypeSize
                                                    .ppPrefersExpandedLayout,
                                            vertical: false
                                        )
                                        .frame(
                                            maxWidth:
                                                dynamicTypeSize
                                                    .ppPrefersExpandedLayout
                                                ? .infinity
                                                : nil,
                                            alignment: .leading
                                        )
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
                .scrollDismissesKeyboard(.interactively)
                .disabled(isCreating)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: PPSpacing.xSmall) {
                    if let creationErrorMessage {
                        Label(
                            creationErrorMessage,
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.rose)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        createCopy()
                    } label: {
                        Label(
                            createStopRequested
                                ? "Finishing current file commit"
                                : isCreating
                                    ? "Creating labeled copy"
                                    : "Create Labeled Copy",
                            systemImage: isCreating
                                ? "hourglass"
                                : "number.square"
                        )
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .disabled(!canCreate)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(createAccessibilityHint)
                }
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
                    Button(
                        (
                            createStopRequested
                                ? "Stopping"
                                : isCreating
                                    ? "Stop"
                                    : "Cancel"
                        ).localizedUI
                    ) {
                        if isCreating {
                            interruptPageLabelCreation()
                        } else {
                            requestPageLabelDismissal()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(createStopRequested)
                }
            }
            .confirmationDialog(
                "Discard page label draft?".localizedUI,
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
                    "The page label rules have not been applied."
                        .localizedUI
                )
            }
            .interactiveDismissDisabled(isCreating || hasDraftChanges)
            .accessibilityAction(.escape) {
                if isCreating {
                    interruptPageLabelCreation()
                } else {
                    requestPageLabelDismissal()
                }
            }
            .onChange(of: rules) {
                creationErrorMessage = nil
            }
            .onChange(
                of: model.record(id: recordID)?
                    .contentRevisionID
            ) { _, revisionID in
                guard revisionID
                        != expectedContentRevisionID
                else { return }
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                interruptPageLabelCreation(
                    invalidateResult: true
                )
                dismiss()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                interruptPageLabelCreation(invalidateResult: true)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptPageLabelCreation(invalidateResult: true)
            }
            .onDisappear {
                interruptPageLabelCreation(invalidateResult: true)
                creationErrorMessage = nil
            }
            .sensoryFeedback(
                .error,
                trigger: creationErrorFeedback
            )
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

    private var hasDraftChanges: Bool {
        rules != initialRules
    }

    private var createAccessibilityHint: String {
        if isCreating {
            return "Wait for the labeled copy to finish."
                .localizedUI
        }
        if !hasUniqueStarts {
            return "Give each range a different start page."
                .localizedUI
        }
        if !canCreate {
            return "Review the page label rules before creating the copy."
                .localizedUI
        }
        return "Creates a separate PDF with these page labels."
            .localizedUI
    }

    private func rulePreview(
        _ rule: PDFPageLabelRule
    ) -> some View {
        Text(rule.label(for: rule.startPageIndex))
            .font(.subheadline.monospaced().weight(.semibold))
            .foregroundStyle(PPColor.amber)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func removeRuleButton(
        _ ruleID: UUID
    ) -> some View {
        Button(role: .destructive) {
            rules.removeAll { $0.id == ruleID }
        } label: {
            Image(systemName: "trash")
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
        .accessibilityLabel("Remove numbering range")
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
        guard canCreate,
              model.record(id: recordID)?.contentRevisionID
                == expectedContentRevisionID,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        creationErrorMessage = nil
        isCreating = true
        createStopRequested = false
        let sorted = rules.sorted {
            $0.startPageIndex < $1.startPageIndex
        }
        let generation = UUID()
        createGeneration = generation
        createTask = Task {
            let created = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.createPageLabeledCopy(
                    recordID: recordID,
                    rules: sorted,
                    expectedContentRevisionID:
                        expectedContentRevisionID
                )
            }
            guard createGeneration == generation else { return }
            let wasStopped =
                createStopRequested || Task.isCancelled
            isCreating = false
            createTask = nil
            createStopRequested = false
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
                    "The labeled copy could not be created. Try again."
                        .localizedUI
                creationErrorFeedback += 1
                return
            }
            onCreated(DocumentRoute(recordID: created.id))
        }
    }

    private func requestPageLabelDismissal() {
        if hasDraftChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }

    private func interruptPageLabelCreation(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            createGeneration = UUID()
            createStopRequested = false
        } else {
            guard createTask != nil,
                  !createStopRequested
            else { return }
            createStopRequested = true
        }
        createTask?.cancel()
        if invalidateResult {
            createTask = nil
            isCreating = false
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
    private struct ReaderLoadRequest: Hashable {
        let contentRevisionID: UUID?
        let indexedAt: Date?
        let reloadToken: UUID
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID
    @ScaledMetric(relativeTo: .body)
    private var readerTypeScale: CGFloat = 1

    let recordID: UUID
    let initialPageIndex: Int
    let onOpenPage: (Int) -> Void
    let onRecognizeText: () -> Void

    @StateObject private var readAloud = PDFReadAloudController()
    @State private var selectedIndex = 0
    @State private var visiblePageID: Int?
    @State private var sleepRemainingSeconds = 0
    @State private var sleepTimerTask: Task<Void, Never>?
    @State private var readingPositionTask: Task<Void, Never>?
    @State private var readingPositionGeneration = UUID()
    @State private var cachedPages: [IndexedPageText] = []
    @State private var isPreparingPages = true
    @State private var readerLoadErrorMessage: String?
    @State private var pageLoadGeneration = UUID()
    @State private var readerReloadToken = UUID()
    @State private var sourceContentRevisionID: UUID?
    @State private var resumePageIndex: Int?
    @State private var resumeRevisionID: UUID?
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

    init(
        recordID: UUID,
        initialPageIndex: Int,
        onOpenPage: @escaping (Int) -> Void,
        onRecognizeText: @escaping () -> Void = {}
    ) {
        self.recordID = recordID
        self.initialPageIndex = initialPageIndex
        self.onOpenPage = onOpenPage
        self.onRecognizeText = onRecognizeText
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()

                if isPreparingPages {
                    PPEmptyState(
                        kind: .processing,
                        title: "Preparing reader",
                        message:
                            "PaperPath is arranging readable text on this device."
                    )
                } else if let readerLoadErrorMessage {
                    readerFailureState(readerLoadErrorMessage)
                } else if pages.isEmpty {
                    readerEmptyState
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
                    Button(
                        (
                            readAloud.isActive
                                || sleepRemainingSeconds > 0
                                ? "Stop"
                                : "Done"
                        ).localizedUI
                    ) {
                        closeOrStopReader()
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .task(id: readerLoadRequest) {
            normalizeReaderPreferences()
            guard scenePhase == .active, UIApplication.shared.isProtectedDataAvailable else { return }
            let request = readerLoadRequest
            guard let requestedRevisionID =
                request.contentRevisionID
            else { return }
            if sourceContentRevisionID == nil {
                sourceContentRevisionID = requestedRevisionID
                if resumeRevisionID != nil, resumeRevisionID != requestedRevisionID {
                    resumePageIndex = nil
                    resumeRevisionID = nil
                }
            }
            guard sourceContentRevisionID
                    == requestedRevisionID
            else {
                model[noticeFor: paperPathSceneID] =
                    "The PDF changed before this action started. Review the updated PDF."
                        .localizedUI
                interruptProtectedReading()
                dismiss()
                return
            }
            await model.ensureAnalysisLoaded(for: recordID)
            guard !Task.isCancelled,
                  scenePhase == .active, UIApplication.shared.isProtectedDataAvailable,
                  model.record(id: recordID)?.contentRevisionID
                    == requestedRevisionID
            else { return }
            await loadReaderPages(
                expectedContentRevisionID:
                    requestedRevisionID
            )
            guard !Task.isCancelled else { return }
            selectInitialPage()
        }
        .onChange(
            of: currentContentRevisionID
        ) { _, revisionID in
            guard let sourceContentRevisionID,
                  revisionID != sourceContentRevisionID
            else { return }
            model[noticeFor: paperPathSceneID] =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            interruptProtectedReading()
            dismiss()
        }
        .onChange(of: selectedIndex) {
            if readAloud.currentPageOffset != selectedIndex {
                readAloud.stop()
            }
            guard !pages.isEmpty else { return }
            let pageIndex = currentPage.pageIndex
            resumePageIndex = pageIndex
            resumeRevisionID = sourceContentRevisionID
            if readsContinuously,
               visiblePageID != pageIndex {
                visiblePageID = pageIndex
            }
            scheduleReadingPositionSave(pageIndex)
        }
        .onChange(of: visiblePageID) {
            guard readsContinuously,
                  let visiblePageID,
                  let index = pageOffset(for: visiblePageID),
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
        .onChange(of: speechRate) { _, _ in
            readAloud.updateRate(Float(boundedSpeechRate))
        }
        .onChange(of: readAloud.isActive) { _, isActive in
            if !isActive, sleepRemainingSeconds > 0 {
                cancelSleepTimer()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, cachedPages.isEmpty {
                readerReloadToken = UUID()
            } else if phase == .background {
                interruptProtectedReading()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication
                    .protectedDataWillBecomeUnavailableNotification
            )
        ) { _ in
            interruptProtectedReading()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.protectedDataDidBecomeAvailableNotification
        )) { _ in
            if scenePhase == .active { readerReloadToken = UUID() }
        }
        .onDisappear {
            interruptProtectedReading()
        }
        .interactiveDismissDisabled(
            readAloud.isActive || sleepRemainingSeconds > 0
        )
        .accessibilityAction(.escape) {
            closeOrStopReader()
        }
        .sensoryFeedback(
            .selection,
            trigger: selectedIndex
        ) { _, _ in
            !readAloud.isActive
        }
        .sensoryFeedback(
            .selection,
            trigger: readAloud.isSpeaking
        ) { _, _ in
            scenePhase == .active
        }
    }

    private var readerContextHeader: some View {
        VStack(alignment: .leading, spacing: PPSpacing.xSmall) {
            Text(model.record(id: recordID)?.displayName ?? "Reflowed text".localizedUI)
                .font(PPType.document)
                .lineLimit(2)
            if readAloud.isActive {
                Label(speechStateTitle, systemImage: readAloud.isSpeaking ? "speaker.wave.2" : "pause")
                    .font(PPType.metadata)
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PPSpacing.regular)
        .padding(.top, PPSpacing.small)
    }

    private var readerAppearanceRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PPSpacing.small) {
                Menu {
                    Picker(
                        "Typeface".localizedUI,
                        selection: $savedTypeface
                    ) {
                        ForEach(FocusReaderTypeface.allCases) {
                            Text($0.title.localizedUI)
                                .tag($0.rawValue)
                        }
                    }
                } label: {
                    Label(
                        typeface.title.localizedUI,
                        systemImage: "textformat"
                    )
                }

                Menu {
                    Picker(
                        "Text width".localizedUI,
                        selection: $savedMeasure
                    ) {
                        ForEach(FocusReaderMeasure.allCases) {
                            Text($0.title.localizedUI)
                                .tag($0.rawValue)
                        }
                    }
                } label: {
                    Label(
                        measure.title.localizedUI,
                        systemImage: "arrow.left.and.right"
                    )
                }

                Toggle(isOn: $readsContinuously) {
                    Label(
                        (
                            readsContinuously
                                ? "Continuous"
                                : "One page"
                        ).localizedUI,
                        systemImage: readsContinuously
                            ? "rectangle.stack"
                            : "doc"
                    )
                }
                .toggleStyle(.button)

                Button {
                    fontSize = max(15, boundedFontSize - 1)
                } label: {
                    Image(systemName: "textformat.size.smaller")
                        .frame(width: 44, height: 44)
                }
                .disabled(boundedFontSize <= 15)
                .accessibilityLabel("Smaller text".localizedUI)

                Text("\(Int(boundedFontSize))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(minWidth: 26)

                Button {
                    fontSize = min(30, boundedFontSize + 1)
                } label: {
                    Image(systemName: "textformat.size.larger")
                        .frame(width: 44, height: 44)
                }
                .disabled(boundedFontSize >= 30)
                .accessibilityLabel("Larger text".localizedUI)
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
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private var readerContent: some View {
        Group {
            if readsContinuously {
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: PPSpacing.xLarge
                    ) {
                        ForEach(pages.indices, id: \.self) { index in
                            let page = pages[index]
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
        let renderedFontSize =
            CGFloat(boundedFontSize) * readerTypeScale
        let headerLayout = dynamicTypeSize.ppPrefersExpandedLayout
            ? AnyLayout(
                VStackLayout(
                    alignment: .leading,
                    spacing: PPSpacing.xSmall
                )
            )
            : AnyLayout(HStackLayout())

        return VStack(alignment: .leading, spacing: PPSpacing.large) {
            if showsDivider {
                Divider()
                    .padding(.bottom, PPSpacing.small)
            }

            headerLayout {
                Button {
                    selectedIndex = index
                } label: {
                    SectionEyebrow(
                        text: AppLocalization.format(
                            "PAGE %lld OF %lld",
                            page.pageIndex + 1,
                            pageCount
                        )
                    )
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    AppLocalization.format(
                        "Page %lld anchor",
                        page.pageIndex + 1
                    )
                )
                if !dynamicTypeSize.ppPrefersExpandedLayout {
                    Spacer()
                }
                Label(
                    sourceTitle,
                    systemImage: "iphone"
                )
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Text(page.text)
                .font(
                    .system(
                        size: renderedFontSize,
                        design: typeface.design
                    )
                )
                .lineSpacing(
                    max(4 * readerTypeScale, renderedFontSize * 0.34)
                )
                .foregroundStyle(PPColor.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if readsContinuously {
                Button {
                    openPageInPDF(page.pageIndex)
                } label: {
                    Label(
                        AppLocalization.format(
                            "Open page %lld in PDF",
                            page.pageIndex + 1
                        ),
                        systemImage: "doc.text.magnifyingglass"
                    )
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
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
                fontSize = max(15, boundedFontSize - 1)
            } label: {
                Label("Smaller text", systemImage: "textformat.size.smaller")
            }
            .disabled(boundedFontSize <= 15)

            Button {
                fontSize = min(30, boundedFontSize + 1)
            } label: {
                Label("Larger text", systemImage: "textformat.size.larger")
            }
            .disabled(boundedFontSize >= 30)

            Button {
                speechRate = max(0.38, boundedSpeechRate - 0.04)
            } label: {
                Label("Slower speech", systemImage: "tortoise")
            }
            .disabled(boundedSpeechRate <= 0.38)

            Button {
                speechRate = min(0.62, boundedSpeechRate + 0.04)
            } label: {
                Label("Faster speech", systemImage: "hare")
            }
            .disabled(boundedSpeechRate >= 0.62)

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
                    .disabled(!readAloud.isActive)
                }
                if !readAloud.isActive {
                    Label(
                        "Start reading to use the timer",
                        systemImage: "info.circle"
                    )
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
        .accessibilityLabel("Reader settings".localizedUI)
        .help("Reader settings".localizedUI)
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
                        "Sleep timer".localizedUI,
                        systemImage: "moon.zzz.fill"
                    )
                    Spacer()
                    Text(formattedSleepTime)
                        .monospacedDigit()
                    Button {
                        cancelSleepTimer()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "Cancel sleep timer".localizedUI
                    )
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textSecondary)
                .padding(.horizontal, PPSpacing.regular)
                .frame(minHeight: 44)
                .background(PPColor.accent.opacity(0.06))
            }

            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(spacing: PPSpacing.xSmall) {
                    HStack(spacing: PPSpacing.small) {
                        previousPageButton
                        Spacer(minLength: PPSpacing.xSmall)
                        pagePositionLabel
                        Spacer(minLength: PPSpacing.xSmall)
                        nextPageButton
                    }
                    HStack(spacing: PPSpacing.large) {
                        Spacer(minLength: 0)
                        openInPDFButton
                        readAloudButton
                        stopReadingButton
                        Spacer(minLength: 0)
                    }
                }
            } else {
                HStack(spacing: PPSpacing.small) {
                    previousPageButton
                    pagePositionLabel
                    openInPDFButton
                    readAloudButton
                    stopReadingButton
                    nextPageButton
                }
            }
        }
        .frame(maxWidth: 560)
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

    private var previousPageButton: some View {
        readerButton(
            "Previous page",
            symbol: "chevron.left",
            disabled: selectedIndex == 0
        ) {
            selectedIndex -= 1
        }
        .accessibilityIdentifier("focusReaderPrevious")
    }

    private var nextPageButton: some View {
        readerButton(
            "Next page",
            symbol: "chevron.right",
            disabled: selectedIndex == pages.count - 1
        ) {
            selectedIndex += 1
        }
        .accessibilityIdentifier("focusReaderNext")
    }

    private var pagePositionLabel: some View {
        Text("\(selectedIndex + 1) / \(pages.count)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(PPColor.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(
                minWidth: 46,
                idealWidth: 64,
                maxWidth: .infinity
            )
            .accessibilityLabel("Reader page position".localizedUI)
            .accessibilityValue(
                AppLocalization.format(
                    "Page %lld of %lld",
                    selectedIndex + 1,
                    pages.count
                )
            )
            .accessibilityIdentifier("focusReaderPosition")
    }

    private var openInPDFButton: some View {
        readerButton(
            "Open in PDF",
            symbol: "doc.text.magnifyingglass"
        ) {
            let pageIndex = currentPage.pageIndex
            openPageInPDF(pageIndex)
        }
    }

    private var readAloudButton: some View {
        Button {
            readAloud.toggle(
                pageCount: pages.count,
                startingAt: selectedIndex,
                rate: Float(boundedSpeechRate),
                textForPage: { index in
                    guard pages.indices.contains(index) else {
                        return nil
                    }
                    return pages[index].text
                }
            )
        } label: {
            Image(
                systemName: readAloud.isSpeaking
                    ? "pause.fill"
                    : "speaker.wave.2.fill"
            )
            .font(.body.weight(.semibold))
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .frame(width: 48, height: 48)
            .foregroundStyle(.white)
            .background(PPColor.accent, in: Circle())
            .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            readAloud.isSpeaking
                ? "Pause reading".localizedUI
                : "Read continuously".localizedUI
        )
        .accessibilityValue(speechStateTitle)
        .help(
            readAloud.isSpeaking
                ? "Pause reading".localizedUI
                : "Read continuously".localizedUI
        )
    }

    private var stopReadingButton: some View {
        readerButton(
            "Stop reading",
            symbol: "stop.fill",
            disabled: !readAloud.isActive
        ) {
            readAloud.stop()
        }
    }

    private var formattedSleepTime: String {
        let minutes = sleepRemainingSeconds / 60
        let seconds = sleepRemainingSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var speechStateTitle: String {
        if readAloud.isSpeaking { return "Speaking".localizedUI }
        if readAloud.isPaused { return "Paused".localizedUI }
        return "Stopped".localizedUI
    }

    private var boundedFontSize: Double {
        fontSize.isFinite ? min(max(fontSize, 15), 30) : 19
    }

    private var boundedSpeechRate: Double {
        speechRate.isFinite
            ? min(max(speechRate, 0.38), 0.62)
            : Double(AVSpeechUtteranceDefaultSpeechRate)
    }

    private func normalizeReaderPreferences() {
        if FocusReaderTypeface(rawValue: savedTypeface) == nil {
            savedTypeface = FocusReaderTypeface.serif.rawValue
        }
        if FocusReaderMeasure(rawValue: savedMeasure) == nil {
            savedMeasure = FocusReaderMeasure.comfortable.rawValue
        }
        let normalizedFontSize = boundedFontSize
        if fontSize != normalizedFontSize {
            fontSize = normalizedFontSize
        }
        let normalizedSpeechRate = boundedSpeechRate
        if speechRate != normalizedSpeechRate {
            speechRate = normalizedSpeechRate
        }
    }

    private var currentContentRevisionID: UUID? {
        model.record(id: recordID)?.contentRevisionID
    }

    private var readerLoadRequest: ReaderLoadRequest {
        ReaderLoadRequest(
            contentRevisionID: currentContentRevisionID,
            indexedAt: model.textIndices[recordID]?.indexedAt,
            reloadToken: readerReloadToken
        )
    }

    private func startSleepTimer(minutes: Int) {
        guard readAloud.isActive else { return }
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
            model[noticeFor: paperPathSceneID] = "Sleep timer ended".localizedUI
        }
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepRemainingSeconds = 0
    }

    private func openPageInPDF(_ pageIndex: Int) {
        guard let sourceContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == sourceContentRevisionID
        else {
            model[noticeFor: paperPathSceneID] =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            interruptProtectedReading()
            dismiss()
            return
        }
        onOpenPage(pageIndex)
    }

    private func closeOrStopReader() {
        if readAloud.isActive || sleepRemainingSeconds > 0 {
            readAloud.stop()
            cancelSleepTimer()
        } else {
            dismiss()
        }
    }

    private func interruptProtectedReading() {
        let expectedContentRevisionID = sourceContentRevisionID
        pageLoadGeneration = UUID()
        readingPositionGeneration = UUID()
        cancelSleepTimer()
        readingPositionTask?.cancel()
        readingPositionTask = nil
        if let expectedContentRevisionID,
           pages.indices.contains(selectedIndex) {
            let pageIndex = pages[selectedIndex].pageIndex
            resumePageIndex = pageIndex
            resumeRevisionID = expectedContentRevisionID
        }
        readAloud.stop()
        cachedPages.removeAll(keepingCapacity: false)
        sourceContentRevisionID = nil
        readerLoadErrorMessage = nil
        isPreparingPages = false
    }

    private func scheduleReadingPositionSave(_ pageIndex: Int) {
        readingPositionTask?.cancel()
        guard let expectedContentRevisionID =
            sourceContentRevisionID
        else { return }
        let generation = UUID()
        readingPositionGeneration = generation
        readingPositionTask = Task { @MainActor in
            defer {
                if readingPositionGeneration == generation {
                    readingPositionTask = nil
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  readingPositionGeneration == generation,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  sourceContentRevisionID
                    == expectedContentRevisionID,
                  model.record(id: recordID)?.contentRevisionID
                    == expectedContentRevisionID
            else { return }
            await model.updateReadingPosition(
                recordID: recordID,
                pageIndex: pageIndex,
                expectedContentRevisionID:
                    expectedContentRevisionID
            )
        }
    }

    private func loadReaderPages(
        expectedContentRevisionID: UUID
    ) async {
        let generation = UUID()
        pageLoadGeneration = generation
        isPreparingPages = true
        readerLoadErrorMessage = nil
        cachedPages.removeAll(keepingCapacity: false)
        let source = model.textIndices[recordID]?.pages ?? []
        let worker = Task.detached(priority: .utility) {
            var prepared: [IndexedPageText] = []
            prepared.reserveCapacity(source.count)
            for (offset, page) in source.enumerated() {
                if offset.isMultiple(of: 8) {
                    try Task.checkCancellation()
                }
                let text = Self.reflowedText(page.text)
                guard !text.isEmpty else { continue }
                prepared.append(
                    IndexedPageText(
                        pageIndex: page.pageIndex,
                        text: text
                    )
                )
            }
            return prepared
        }
        let prepared: [IndexedPageText]
        do {
            prepared = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        } catch is CancellationError {
            return
        } catch {
            guard pageLoadGeneration == generation else { return }
            isPreparingPages = false
            readerLoadErrorMessage =
                "Reader text couldn’t be prepared."
            return
        }
        guard !Task.isCancelled,
              pageLoadGeneration == generation,
              model.record(id: recordID)?.contentRevisionID
                == expectedContentRevisionID
        else { return }
        cachedPages = prepared
        isPreparingPages = false
    }

    private func retryReaderLoad() {
        readerLoadErrorMessage = nil
        isPreparingPages = true
        readerReloadToken = UUID()
    }

    private func readerFailureState(
        _ message: String
    ) -> some View {
        VStack(spacing: PPSpacing.medium) {
            PPEmptyState(
                kind: .tools,
                title: "Couldn’t prepare reader",
                message: message
            )
            Button {
                retryReaderLoad()
            } label: {
                Label(
                    "Prepare Again",
                    systemImage: "arrow.clockwise"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            Button {
                openPageInPDF(initialPageIndex)
            } label: {
                Label(
                    "Open in PDF",
                    systemImage: "doc.text.magnifyingglass"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPQuietButtonStyle())
        }
        .frame(maxWidth: 480)
        .padding(PPSpacing.regular)
    }

    private var readerEmptyState: some View {
        VStack(spacing: PPSpacing.medium) {
            PPEmptyState(
                kind: .tools,
                title: "No readable text",
                message:
                    "Run local recognition if this PDF contains scanned pages."
            )
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
            Button {
                openPageInPDF(initialPageIndex)
            } label: {
                Label(
                    "Open in PDF",
                    systemImage: "doc.text.magnifyingglass"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPQuietButtonStyle())
        }
        .frame(maxWidth: 480)
        .padding(PPSpacing.regular)
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
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
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
        case .vision: return "LOCAL OCR".localizedUI
        case .searchableCopy: return "TEXT LAYER".localizedUI
        case .native, nil: return "PDF TEXT".localizedUI
        }
    }

    private nonisolated static func reflowedText(
        _ value: String
    ) -> String {
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
        selectedIndex = pageOffset(
            atOrAfter: resumePageIndex ?? initialPageIndex
        ) ?? pages.count - 1
        visiblePageID = currentPage.pageIndex
    }

    private func pageOffset(for pageIndex: Int) -> Int? {
        guard let offset = pageOffset(atOrAfter: pageIndex),
              pages[offset].pageIndex == pageIndex
        else { return nil }
        return offset
    }

    private func pageOffset(atOrAfter pageIndex: Int) -> Int? {
        var lower = pages.startIndex
        var upper = pages.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if pages[middle].pageIndex < pageIndex {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return pages.indices.contains(lower) ? lower : nil
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
    private var activeUtteranceID: ObjectIdentifier?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isActive: Bool {
        isSpeaking || isPaused
    }

    func updateRate(_ rate: Float) {
        speechRate = min(max(rate, 0.38), 0.62)
    }

    func toggle(
        pageCount: Int,
        startingAt index: Int,
        rate: Float,
        textForPage: @escaping (Int) -> String?
    ) {
        updateRate(rate)
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
        speakNextPage()
    }

    private func speakNextPage() {
        while nextPageOffset >= 0,
              nextPageOffset < queuedPageCount {
            let offset = nextPageOffset
            nextPageOffset += 1
            let value = String(
                (textForPage?(offset) ?? "")
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .prefix(24_000)
            )
            guard !value.isEmpty else { continue }

            let utterance = AVSpeechUtterance(string: value)
            if let language = NLLanguageRecognizer.dominantLanguage(
                for: String(value.prefix(1_000))
            )?.rawValue {
                utterance.voice = AVSpeechSynthesisVoice(
                    language: language
                )
            }
            utterance.rate = speechRate
            activeUtteranceID = ObjectIdentifier(utterance)
            currentPageOffset = offset
            synthesizer.speak(utterance)
            isSpeaking = true
            isPaused = false
            return
        }
        finishQueue()
    }

    func stop() {
        activeUtteranceID = nil
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
        isPaused = false
        queuedPageCount = 0
        textForPage = nil
        nextPageOffset = 0
        currentPageOffset = nil
    }

    private func finishQueue() {
        activeUtteranceID = nil
        isSpeaking = false
        isPaused = false
        queuedPageCount = 0
        textForPage = nil
        nextPageOffset = 0
        currentPageOffset = nil
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self,
                  self.activeUtteranceID == utteranceID
            else { return }
            self.activeUtteranceID = nil
            self.speakNextPage()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self,
                  self.activeUtteranceID == utteranceID
            else { return }
            self.finishQueue()
        }
    }
}
