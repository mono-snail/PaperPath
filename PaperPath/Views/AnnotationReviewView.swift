import SwiftUI

enum PDFAnnotationMarkdown {
    static func inline(
        _ value: String,
        limit: Int? = nil
    ) -> String {
        var sanitized = ""
        sanitized.reserveCapacity(
            min(value.utf8.count, max(0, limit ?? 1_024))
        )
        var lastWasWhitespace = false
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !lastWasWhitespace, !sanitized.isEmpty {
                    sanitized.append(" ")
                }
                lastWasWhitespace = true
                continue
            }
            guard !CharacterSet.controlCharacters.contains(scalar),
                  !isDirectionalOrInvisibleControl(scalar)
            else { continue }
            sanitized.unicodeScalars.append(scalar)
            lastWasWhitespace = false
        }
        let trimmed = sanitized.trimmingCharacters(in: .whitespaces)
        let bounded = limit.map {
            String(trimmed.prefix(max(0, $0)))
        } ?? trimmed
        var escaped = bounded.replacingOccurrences(
            of: "\\",
            with: "\\\\"
        )
        for marker in ["`", "*", "_", "{", "}", "[", "]", "<", ">", "#", "!", "|"] {
            escaped = escaped.replacingOccurrences(
                of: marker,
                with: "\\\(marker)"
            )
        }
        return escaped
    }

    private static func isDirectionalOrInvisibleControl(
        _ scalar: UnicodeScalar
    ) -> Bool {
        switch scalar.value {
        case 0x061C, 0x200B...0x200F, 0x202A...0x202E,
             0x2060...0x206F, 0xFEFF:
            return true
        default:
            return false
        }
    }
}

private enum AnnotationReviewFilter:
    String,
    CaseIterable,
    Identifiable,
    Sendable {
    case all
    case markup
    case notes
    case drawings
    case signatures
    case generated
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .markup: return "Markup"
        case .notes: return "Notes"
        case .drawings: return "Drawings"
        case .signatures: return "Signatures"
        case .generated: return "Generated"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .markup: return "highlighter"
        case .notes: return "note.text"
        case .drawings: return "pencil.tip"
        case .signatures: return "signature"
        case .generated: return "wand.and.stars"
        case .other: return "ellipsis.circle"
        }
    }
}

private struct AnnotationReviewProjection: Sendable {
    let displayedAnnotations: [PDFAnnotationSnapshot]
    let filterCounts: [AnnotationReviewFilter: Int]
    let pageCount: Int
    let editableCount: Int
    let readOnlyCount: Int
}

private enum AnnotationReviewProjector {
    static func project(
        _ source: [PDFAnnotationSnapshot],
        filter: AnnotationReviewFilter,
        query: String,
        includesCounts: Bool
    ) throws -> AnnotationReviewProjection {
        var counts: [AnnotationReviewFilter: Int] = [:]
        if includesCounts {
            counts.reserveCapacity(AnnotationReviewFilter.allCases.count)
        }
        var pageIndices: Set<Int> = []
        var editableCount = 0
        var readOnlyCount = 0
        var displayed: [PDFAnnotationSnapshot] = []
        displayed.reserveCapacity(source.count)
        let terms = DocumentSearchNormalization.terms(in: query)

        for (index, annotation) in source.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            if includesCounts {
                pageIndices.insert(annotation.pageIndex)
                if annotation.canEdit {
                    editableCount += 1
                } else if annotation.hasAppearanceStream {
                    readOnlyCount += 1
                }
                for candidate in AnnotationReviewFilter.allCases
                where matches(annotation, filter: candidate) {
                    counts[candidate, default: 0] += 1
                }
            }
            guard matches(annotation, filter: filter) else {
                continue
            }
            guard terms.isEmpty
                    || searchMatches(
                        annotation,
                        terms: terms
                    )
            else { continue }
            displayed.append(annotation)
        }

        return AnnotationReviewProjection(
            displayedAnnotations: displayed,
            filterCounts: counts,
            pageCount: pageIndices.count,
            editableCount: editableCount,
            readOnlyCount: readOnlyCount
        )
    }

    static func matches(
        _ annotation: PDFAnnotationSnapshot,
        filter: AnnotationReviewFilter
    ) -> Bool {
        let type = annotation.type.lowercased()
        let isSignature = type == "ink"
            && annotation.contents == "Signature"
        switch filter {
        case .all:
            return true
        case .markup:
            return [
                "highlight",
                "underline",
                "strikeout",
                "squiggly"
            ].contains(type)
        case .notes:
            return annotation.generatedKind == nil
                && ["text", "freetext", "caret"].contains(type)
        case .drawings:
            return !isSignature
                && ["ink", "polygon", "polyline"].contains(type)
        case .signatures:
            return isSignature
        case .generated:
            return annotation.generatedKind != nil
        case .other:
            return !matches(annotation, filter: .markup)
                && !matches(annotation, filter: .notes)
                && !matches(annotation, filter: .drawings)
                && !isSignature
                && annotation.generatedKind == nil
        }
    }

    static func searchMatches(
        _ annotation: PDFAnnotationSnapshot,
        terms: [String]
    ) -> Bool {
        let page = annotation.pageIndex + 1
        let searchable = [
            title(for: annotation).localizedUI,
            annotation.type,
            annotation.contents ?? "",
            "page \(page)",
            "p\(page)",
            "页 \(page)",
            "第 \(page) 页",
            String(page)
        ].joined(separator: " ")
        let normalized = DocumentSearchNormalization.text(searchable)
        return terms.allSatisfy(normalized.contains)
    }

    static func title(
        for annotation: PDFAnnotationSnapshot
    ) -> String {
        if let generatedKind = annotation.generatedKind {
            return generatedKind.title
        }
        if annotation.type.lowercased() == "ink",
           annotation.contents == "Signature" {
            return "Signature"
        }
        switch annotation.type.lowercased() {
        case "highlight": return "Highlight"
        case "underline": return "Underline"
        case "strikeout": return "Strikethrough"
        case "ink": return "Drawing"
        case "text": return "Note"
        case "freetext": return "Added Text"
        case "link": return "Web Link"
        case "stamp": return annotation.contents ?? "Stamp"
        case "squiggly": return "Squiggly Underline"
        case "caret": return "Insertion Mark"
        case "polygon": return "Polygon"
        case "polyline": return "Polyline"
        default: return annotation.type
        }
    }
}

private struct PDFReviewLoadRequest: Hashable {
    let recordID: UUID
    let contentRevisionID: UUID?
    let isAvailable: Bool
    let reload: Int
}

struct AnnotationReviewView: View {
    private enum PendingEditorAction {
        case reload
        case openPage(Int, contentRevisionID: UUID)
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let onSelectPage: (Int) -> Void
    @State private var annotations: [PDFAnnotationSnapshot] = []
    @State private var displayedAnnotations:
        [PDFAnnotationSnapshot] = []
    @State private var filterCounts:
        [AnnotationReviewFilter: Int] = [:]
    @State private var annotationPageCount = 0
    @State private var editableAnnotationCount = 0
    @State private var readOnlyAnnotationCount = 0
    @State private var isLoading = true
    @State private var loadErrorMessage: String?
    @State private var reloadRequest = 0
    @State private var protectedDataAvailable =
        UIApplication.shared.isProtectedDataAvailable
    @State private var editingAnnotation: PDFAnnotationSnapshot?
    @State private var editingContentRevisionID: UUID?
    @State private var pendingEditorAction: PendingEditorAction?
    @State private var filter = AnnotationReviewFilter.all
    @State private var searchText = ""
    @State private var isTruncated = false
    @State private var displayLimit = 10_000
    @State private var isSelecting = false
    @State private var selectedAnnotationIDs: Set<String> = []
    @State private var isConfirmingRemoval = false
    @State private var isRemoving = false
    @State private var removalStopRequested = false
    @State private var removalTask: Task<Void, Never>?
    @State private var removalGeneration = UUID()
    @State private var recoverableRemovalCount: Int?
    @State private var recoverableRemovalRevisionID: UUID?
    @State private var summaryURL: URL?
    @State private var isSharingSummary = false
    @State private var isPreparingSummary = false
    @State private var summaryTask: Task<Void, Never>?
    @State private var summaryGeneration = UUID()
    @State private var loadGeneration = UUID()
    @State private var loadedContentRevisionID: UUID?
    @State private var projectionGeneration = UUID()
    @State private var projectionTask: Task<Void, Never>?
    @State private var editorTransitionTask: Task<Void, Never>?
    @State private var editorTransitionGeneration = UUID()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    PPEmptyState(
                        kind: .processing,
                        title: "Reading annotations",
                        message: "PaperPath is checking marks on the private copy."
                    )
                    .padding(PPSpacing.regular)
                } else if let loadErrorMessage {
                    VStack(spacing: PPSpacing.medium) {
                        PPEmptyState(
                            kind: .tools,
                            title: "Couldn’t inspect annotations",
                            message: loadErrorMessage
                        )
                        Button {
                            reloadRequest &+= 1
                        } label: {
                            Label("Retry".localizedUI, systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(PPPrimaryButtonStyle())
                        .disabled(!canReadReview)
                        .accessibilityIdentifier("retryAnnotationInspection")
                    }
                    .padding(PPSpacing.regular)
                } else if annotations.isEmpty {
                    PPEmptyState(
                        kind: .tools,
                        title: "No annotations",
                        message: "Highlights, notes, drawings, stamps, signatures, and generated page marks will appear here."
                    )
                    .padding(PPSpacing.regular)
                } else {
                    VStack(spacing: 0) {
                        annotationOverview
                            .padding(.horizontal, PPSpacing.regular)
                            .padding(.top, PPSpacing.small)
                        if isTruncated {
                            inventoryLimitNotice
                                .padding(.horizontal, PPSpacing.regular)
                        }
                        annotationFilterRail

                        if displayedAnnotations.isEmpty {
                            VStack(spacing: PPSpacing.medium) {
                                PPEmptyState(
                                    kind: .tools,
                                    title: searchText.isEmpty
                                        ? AppLocalization.format(
                                            "No %@",
                                            filter.title.localizedUI
                                        )
                                        : "No matching annotations",
                                    message: searchText.isEmpty
                                        ? "Choose another annotation type."
                                        : "Try another word, type, or page number."
                                )
                                Button {
                                    resetAnnotationScope()
                                } label: {
                                    Label(
                                        "Show All Annotations",
                                        systemImage:
                                            "line.3.horizontal.decrease.circle"
                                    )
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(
                                    PPQuietButtonStyle(
                                        tint: PPColor.amber
                                    )
                                )
                                .accessibilityIdentifier(
                                    "annotationResetScope"
                                )
                            }
                            .frame(maxWidth: 520)
                            .padding(PPSpacing.regular)
                            .frame(maxHeight: .infinity)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(displayedAnnotations) { annotation in
                                        annotationRow(annotation)
                                    }
                                }
                                .frame(maxWidth: 880)
                                .padding(.horizontal, PPSpacing.regular)
                                .padding(.bottom, PPSpacing.large)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
            }
            .background(PPColor.canvas)
            .navigationTitle("Comments & Markup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSelecting {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            endSelection()
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(
                            selectionLimitReached
                                && !allDisplayedRemovableSelected
                                ? "Limit Reached"
                                : (
                                    allDisplayedRemovableSelected
                                        ? "Deselect Results"
                                        : "Select Results"
                                )
                        ) {
                            toggleDisplayedSelection()
                        }
                        .disabled(
                            displayedRemovableAnnotations.isEmpty
                                || (
                                    selectionLimitReached
                                        && !allDisplayedRemovableSelected
                                )
                                || projectionTask != nil
                                || isRemoving
                                || !hasCurrentInventory
                        )
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .destructive) {
                            isConfirmingRemoval = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(
                            selectedAnnotationIDs.isEmpty
                                || projectionTask != nil
                                || isRemoving
                                || !hasCurrentInventory
                        )
                        .accessibilityLabel(
                            "Remove selected annotations"
                        )
                    }
                } else {
                    if !annotations.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            annotationActionsMenu
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .disabled(
                                isRemoving || isPreparingSummary
                            )
                    }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(
                    displayMode: .always
                ),
                prompt: "Search annotations"
            )
            .onSubmit(of: .search) {
                dismissSearch()
                scheduleProjection(debounced: false)
            }
            .onChange(of: searchText) { _, value in
                let bounded = String(value.prefix(200))
                if value != bounded {
                    searchText = bounded
                    return
                }
                scheduleProjection(debounced: true)
            }
            .task(id: loadRequest) {
                guard canReadReview else { return }
                if loadedContentRevisionID != loadRequest.contentRevisionID {
                    endSelection()
                    stopSummaryPreparation()
                    if recoverableRemovalRevisionID != loadRequest.contentRevisionID {
                        recoverableRemovalCount = nil
                        recoverableRemovalRevisionID = nil
                    }
                }
                await load()
            }
            .sheet(
                item: $editingAnnotation,
                onDismiss: completeEditorAction
            ) { annotation in
                if let editingContentRevisionID {
                    AnnotationEditorSheet(
                        recordID: recordID,
                        contentRevisionID: editingContentRevisionID,
                        annotation: annotation,
                        onSaved: {
                            pendingEditorAction = .reload
                            editingAnnotation = nil
                        },
                        onOpenPage: {
                            pendingEditorAction = .openPage(
                                annotation.pageIndex,
                                contentRevisionID: editingContentRevisionID
                            )
                            editingAnnotation = nil
                        }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(
                isPresented: $isSharingSummary,
                onDismiss: cleanupSummary
            ) {
                if let summaryURL {
                    ShareSheet(items: [summaryURL])
                        .presentationDetents([.medium, .large])
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting
                    || isRemoving
                    || isPreparingSummary
                    || recoverableRemovalCount != nil {
                    reviewStatusBar
                }
            }
            .interactiveDismissDisabled(
                isRemoving || isPreparingSummary
            )
            .confirmationDialog(
                AppLocalization.format(
                    "Remove %lld annotations?",
                    selectedAnnotationIDs.count
                ),
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button(
                    AppLocalization.format(
                        "Remove %lld annotations",
                        selectedAnnotationIDs.count
                    ),
                    role: .destructive
                ) {
                    removeSelectedAnnotations()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Only the selected removable annotations change. One-step recovery will be available."
                )
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    interruptProtectedReviewWork()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                protectedDataAvailable = false
                interruptProtectedReviewWork()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.protectedDataDidBecomeAvailableNotification
                )
            ) { _ in
                protectedDataAvailable = true
            }
            .onDisappear {
                interruptProtectedReviewWork()
            }
            .accessibilityAction(.escape) {
                if isRemoving {
                    stopRemoval()
                } else if isPreparingSummary {
                    stopSummaryPreparation()
                } else if isSelecting {
                    endSelection()
                } else {
                    dismiss()
                }
            }
            .sensoryFeedback(.selection, trigger: filter)
        }
    }

    private var canReadReview: Bool {
        scenePhase == .active && protectedDataAvailable
            && UIApplication.shared.isProtectedDataAvailable
    }

    private var loadRequest: PDFReviewLoadRequest {
        PDFReviewLoadRequest(
            recordID: recordID,
            contentRevisionID: model.record(id: recordID)?.contentRevisionID,
            isAvailable: canReadReview,
            reload: reloadRequest
        )
    }

    private var hasCurrentInventory: Bool {
        canReadReview && !isLoading && loadErrorMessage == nil
            && loadedContentRevisionID != nil
            && loadedContentRevisionID == model.record(id: recordID)?.contentRevisionID
    }

    private func load() async {
        guard canReadReview, !Task.isCancelled else { return }
        let request = loadRequest
        projectionTask?.cancel()
        projectionTask = nil
        projectionGeneration = UUID()
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        loadErrorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        let inventory: PDFAnnotationInventory
        do {
            inventory = try await model.inspectAnnotationInventory(recordID: recordID)
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation, loadRequest == request,
                  canReadReview, !Task.isCancelled else { return }
            loadErrorMessage = "The annotation list could not be read. Try again."
            return
        }
        guard !Task.isCancelled,
              loadGeneration == generation,
              loadRequest == request, canReadReview
        else { return }
        let loadedAnnotations = inventory.annotations
        let selectedFilter = filter
        let query = searchText
        guard let projection = await makeProjection(
            from: loadedAnnotations,
            filter: selectedFilter,
            query: query,
            includesCounts: true
        ),
              !Task.isCancelled,
              loadGeneration == generation,
              loadRequest == request, canReadReview
        else { return }
        annotations = loadedAnnotations
        filterCounts = projection.filterCounts
        annotationPageCount = projection.pageCount
        editableAnnotationCount = projection.editableCount
        readOnlyAnnotationCount = projection.readOnlyCount
        displayedAnnotations = selectedFilter == filter && query == searchText
            ? projection.displayedAnnotations : []
        isTruncated = inventory.isTruncated
        displayLimit = inventory.displayLimit
        loadedContentRevisionID = request.contentRevisionID
        selectedAnnotationIDs.formIntersection(
            Set(annotations.map(\.id))
        )
        isLoading = false
        if selectedFilter != filter || query != searchText {
            scheduleProjection(debounced: false)
        }
    }

    private func completeEditorAction() {
        guard let pendingEditorAction else { return }
        self.pendingEditorAction = nil
        editorTransitionTask?.cancel()
        let generation = UUID()
        editorTransitionGeneration = generation
        editorTransitionTask = Task { @MainActor in
            defer {
                if editorTransitionGeneration == generation {
                    editorTransitionTask = nil
                }
            }
            await Task.yield()
            guard !Task.isCancelled,
                  editorTransitionGeneration == generation,
                  scenePhase == .active,
                  UIApplication.shared.isProtectedDataAvailable,
                  model.record(id: recordID) != nil
            else { return }
            switch pendingEditorAction {
            case .reload:
                await load()
            case .openPage(
                let pageIndex,
                let contentRevisionID
            ):
                guard model.record(id: recordID)?
                        .contentRevisionID == contentRevisionID
                else {
                    model[noticeFor: paperPathSceneID] =
                        "The PDF changed before this action started. Review the updated PDF."
                            .localizedUI
                    return
                }
                onSelectPage(pageIndex)
            }
        }
    }

    private var annotationOverview: some View {
        WorkflowCommandHeader(
            eyebrow: "DOCUMENT MARKUP",
            title: "Comments & markup",
            detail: "Review, edit, or remove marks in this PDF.",
            symbol: "text.bubble",
            tint: PPColor.amber,
            metrics: [
                WorkflowMetric(
                    value: isTruncated
                        ? "\(annotations.count)+"
                        : "\(annotations.count)",
                    label: "Marks",
                    symbol: "text.bubble",
                    tint: PPColor.amber
                ),
                WorkflowMetric(
                    value: "\(annotationPageCount)",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                )
            ]
        )
    }

    private var inventoryLimitNotice: some View {
        Label(
            AppLocalization.format(
                "Showing the first %lld annotations. Search and selection apply to this bounded list.",
                displayLimit
            ),
            systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(PPColor.amber)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, PPSpacing.small)
        .accessibilityIdentifier("annotationInventoryLimit")
    }

    private var annotationActionsMenu: some View {
        Menu {
            Button {
                isSelecting = true
                recoverableRemovalCount = nil
                recoverableRemovalRevisionID = nil
            } label: {
                Label(
                    "Select annotations",
                    systemImage: "checkmark.circle"
                )
            }
            .disabled(!annotations.contains(where: \.canRemove))
            Button {
                exportSummary(
                    annotations,
                    scope: "All annotations".localizedUI
                )
            } label: {
                Label(
                    "Export all annotations",
                    systemImage: "square.and.arrow.up"
                )
            }
            if hasScopedResults {
                Button {
                    exportSummary(
                        displayedAnnotations,
                        scope: "Current results".localizedUI
                    )
                } label: {
                    Label(
                        "Export current results",
                        systemImage: "line.3.horizontal.decrease"
                    )
                }
                .disabled(displayedAnnotations.isEmpty)
            }
        } label: {
            if isPreparingSummary {
                ProgressView()
            } else {
                Image(systemName: "ellipsis.circle")
            }
        }
        .disabled(
            isPreparingSummary || isRemoving || !hasCurrentInventory
                || projectionTask != nil
        )
        .accessibilityLabel("Annotation actions")
        .accessibilityIdentifier("annotationActions")
    }

    @ViewBuilder
    private var reviewStatusBar: some View {
        if isRemoving {
            operationStatusBar(
                title: removalStopRequested
                    ? "Finishing annotation update"
                    : "Removing annotations",
                actionTitle: removalStopRequested
                    ? "Stopping"
                    : "Stop",
                actionDisabled: removalStopRequested
            ) {
                stopRemoval()
            }
        } else if isPreparingSummary {
            operationStatusBar(
                title: "Preparing annotation summary",
                actionTitle: "Stop"
            ) {
                stopSummaryPreparation()
            }
        } else if let recoverableRemovalCount {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(PPColor.mint)
                Text(
                    AppLocalization.format(
                        "%lld annotations removed",
                        recoverableRemovalCount
                    )
                )
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                Spacer()
                Button("Undo") {
                    undoLastRemoval()
                }
                .buttonStyle(PPQuietButtonStyle())
                .disabled(!canReadReview || !model.canUndoPageChange(recordID: recordID))
            }
            .padding(.horizontal, PPSpacing.regular)
            .frame(minHeight: 52)
            .background(.bar)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.7))
                    .frame(height: 0.6)
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PPSpacing.small) {
                    selectionSummary
                    Spacer()
                    selectionRemoveButton
                }
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    selectionSummary
                    selectionRemoveButton
                }
            }
            .padding(.horizontal, PPSpacing.regular)
            .padding(.vertical, PPSpacing.small)
            .background(.bar)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PPColor.border.opacity(0.7))
                    .frame(height: 0.6)
            }
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                AppLocalization.format(
                    "%lld selected",
                    selectedAnnotationIDs.count
                )
            )
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
            Text(
                AppLocalization.format(
                    "%lld removable in current results · 2,000 maximum",
                    displayedRemovableAnnotations.count
                )
            )
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)
            .monospacedDigit()
        }
    }

    private var selectionRemoveButton: some View {
        Button(role: .destructive) {
            isConfirmingRemoval = true
        } label: {
            Label("Remove Selected", systemImage: "trash")
        }
        .buttonStyle(PPQuietButtonStyle())
        .disabled(
            selectedAnnotationIDs.isEmpty
                || projectionTask != nil
                || !hasCurrentInventory
        )
    }

    private func operationStatusBar(
        title: String,
        actionTitle: String,
        actionDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            ProgressView()
                .controlSize(.small)
            Text(title.localizedUI)
                .font(.caption.weight(.semibold))
            Spacer()
            Button(actionTitle.localizedUI, action: action)
                .font(.caption.weight(.semibold))
                .frame(minHeight: 44)
                .buttonStyle(.plain)
                .disabled(actionDisabled)
        }
        .padding(.horizontal, PPSpacing.regular)
        .frame(minHeight: 48)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func annotationRow(
        _ annotation: PDFAnnotationSnapshot
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Button {
                guard hasCurrentInventory else { return }
                if isSelecting {
                    toggleSelection(annotation)
                } else {
                    onSelectPage(annotation.pageIndex)
                }
            } label: {
                HStack(spacing: PPSpacing.small) {
                    if isSelecting {
                        Image(
                            systemName: selectionSymbol(
                                for: annotation
                            )
                        )
                        .font(.title3)
                        .foregroundStyle(
                            selectedAnnotationIDs
                                .contains(annotation.id)
                                ? PPColor.accent
                                : PPColor.textSecondary
                        )
                        .frame(width: 36, height: 36)
                    } else {
                        ToolSymbolPlate(
                            symbol: symbol(for: annotation),
                            tint: PPColor.amber,
                            size: 36
                        )
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: annotation).localizedUI)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(PPColor.textPrimary)
                        Text(
                            annotation.contents.flatMap {
                                $0.isEmpty ? nil : $0
                            } ?? AppLocalization.format(
                                "Page %lld",
                                annotation.pageIndex + 1
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(
                            dynamicTypeSize.ppPrefersExpandedLayout
                                ? 3
                                : 2
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Text("p\(annotation.pageIndex + 1)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(PPColor.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                isSelecting && !annotation.canRemove
            )
            .accessibilityValue(
                isSelecting
                    ? (
                        annotation.canRemove
                            ? (
                                selectedAnnotationIDs
                                    .contains(annotation.id)
                                    ? "Selected".localizedUI
                                    : "Not selected".localizedUI
                            )
                            : "Read only".localizedUI
                    )
                    : ""
            )

            if !isSelecting && annotation.canEdit {
                Button {
                    guard hasCurrentInventory else { return }
                    editingContentRevisionID = loadedContentRevisionID
                    editingAnnotation = annotation
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    AppLocalization.format(
                        "Edit %@",
                        title(for: annotation).localizedUI
                    )
                )
                .help("Edit Annotation".localizedUI)
                .hoverEffect(.highlight)
            } else if !isSelecting
                && annotation.hasAppearanceStream {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(width: 44, height: 44)
            }

            if !isSelecting && annotation.canRemove {
                Button(role: .destructive) {
                    removeAnnotations([annotation])
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("Remove annotation")
                .help("Remove annotation".localizedUI)
                .hoverEffect(.highlight)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
                .padding(.leading, 46)
        }
        .accessibilityElement(children: .contain)
        .disabled(!hasCurrentInventory || isRemoving || isPreparingSummary)
    }

    private var annotationFilterRail: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PPSpacing.small) {
                ForEach(visibleFilters) { candidate in
                    let count = annotationCount(candidate)
                    let isSelected = candidate == filter
                    Button {
                        filter = candidate
                        scheduleProjection(debounced: false)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: candidate.symbol)
                            Text(candidate.title.localizedUI)
                            Text("\(count)")
                                .monospacedDigit()
                                .foregroundStyle(
                                    isSelected
                                        ? Color.white.opacity(0.82)
                                        : PPColor.textSecondary
                                )
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            isSelected
                                ? Color.white
                                : PPColor.textPrimary
                        )
                        .padding(.horizontal, PPSpacing.medium)
                        .frame(minHeight: 44)
                        .background(
                            isSelected
                                ? PPColor.accent
                                : Color.clear
                        )
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: 7,
                                style: .continuous
                            )
                        )
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(
                                    isSelected
                                        ? PPColor.accent
                                        : PPColor.border.opacity(0.58)
                                )
                                .frame(height: isSelected ? 2 : 0.6)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(
                        isSelected ? "Selected" : ""
                    )
                }
            }
            .padding(.horizontal, PPSpacing.regular)
            .padding(.vertical, PPSpacing.small)
        }
        .scrollIndicators(.hidden)
        .background(PPColor.canvas)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.6))
                .frame(height: 0.6)
        }
        .accessibilityIdentifier("annotationFilters")
    }

    private var visibleFilters: [AnnotationReviewFilter] {
        AnnotationReviewFilter.allCases.filter {
            $0 == .all || annotationCount($0) > 0
        }
    }

    private var displayedRemovableAnnotations:
        [PDFAnnotationSnapshot] {
        displayedAnnotations.filter(\.canRemove)
    }

    private var selectedAnnotations: [PDFAnnotationSnapshot] {
        annotations.filter {
            selectedAnnotationIDs.contains($0.id)
        }
    }

    private var allDisplayedRemovableSelected: Bool {
        !displayedRemovableAnnotations.isEmpty
            && displayedRemovableAnnotations.allSatisfy {
                selectedAnnotationIDs.contains($0.id)
            }
    }

    private var selectionLimitReached: Bool {
        selectedAnnotationIDs.count >= 2_000
    }

    private var hasScopedResults: Bool {
        filter != .all
            || !searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
    }

    private func resetAnnotationScope() {
        searchText = ""
        filter = .all
        selectedAnnotationIDs.removeAll(keepingCapacity: false)
        dismissSearch()
        scheduleProjection(debounced: false)
    }

    private func annotationCount(
        _ candidate: AnnotationReviewFilter
    ) -> Int {
        filterCounts[candidate, default: 0]
    }

    private func makeProjection(
        from source: [PDFAnnotationSnapshot],
        filter: AnnotationReviewFilter,
        query: String,
        includesCounts: Bool
    ) async -> AnnotationReviewProjection? {
        let worker = Task.detached(priority: .userInitiated) {
            try AnnotationReviewProjector.project(
                source,
                filter: filter,
                query: query,
                includesCounts: includesCounts
            )
        }
        return try? await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func scheduleProjection(debounced: Bool) {
        projectionTask?.cancel()
        guard !isLoading, hasCurrentInventory else {
            projectionTask = nil
            return
        }
        let generation = UUID()
        projectionGeneration = generation
        let source = annotations
        let selectedFilter = filter
        let query = searchText
        let revisionID = loadedContentRevisionID
        projectionTask = Task { @MainActor in
            defer {
                if projectionGeneration == generation {
                    projectionTask = nil
                }
            }
            if debounced {
                do {
                    try await Task.sleep(for: .milliseconds(140))
                } catch {
                    return
                }
            }
            guard let projection = await makeProjection(
                from: source,
                filter: selectedFilter,
                query: query,
                includesCounts: false
            ),
                  !Task.isCancelled,
                  projectionGeneration == generation,
                  hasCurrentInventory,
                  revisionID == loadedContentRevisionID,
                  filter == selectedFilter,
                  searchText == query
            else { return }
            displayedAnnotations = projection.displayedAnnotations
            if isSelecting {
                selectedAnnotationIDs.formIntersection(
                    Set(
                        projection.displayedAnnotations
                            .filter(\.canRemove)
                            .map(\.id)
                    )
                )
            }
        }
    }

    private func selectionSymbol(
        for annotation: PDFAnnotationSnapshot
    ) -> String {
        guard annotation.canRemove else {
            return "lock.circle"
        }
        return selectedAnnotationIDs.contains(annotation.id)
            ? "checkmark.circle.fill"
            : "circle"
    }

    private func toggleSelection(
        _ annotation: PDFAnnotationSnapshot
    ) {
        guard annotation.canRemove else { return }
        if selectedAnnotationIDs.contains(annotation.id) {
            selectedAnnotationIDs.remove(annotation.id)
        } else if selectedAnnotationIDs.count < 2_000 {
            selectedAnnotationIDs.insert(annotation.id)
        }
    }

    private func toggleDisplayedSelection() {
        let visibleIDs = displayedRemovableAnnotations.map(\.id)
        guard !visibleIDs.isEmpty else { return }
        if visibleIDs.allSatisfy(
            selectedAnnotationIDs.contains
        ) {
            selectedAnnotationIDs.subtract(visibleIDs)
            return
        }
        let remainingCapacity = max(
            0,
            2_000 - selectedAnnotationIDs.count
        )
        selectedAnnotationIDs.formUnion(
            visibleIDs
                .filter {
                    !selectedAnnotationIDs.contains($0)
                }
                .prefix(remainingCapacity)
        )
    }

    private func endSelection() {
        selectedAnnotationIDs.removeAll()
        isSelecting = false
        isConfirmingRemoval = false
    }

    private func removeSelectedAnnotations() {
        guard projectionTask == nil else { return }
        let visibleIDs = Set(
            displayedRemovableAnnotations.map(\.id)
        )
        selectedAnnotationIDs.formIntersection(visibleIDs)
        removeAnnotations(
            Array(selectedAnnotations.prefix(2_000))
        )
    }

    private func removeAnnotations(
        _ snapshots: [PDFAnnotationSnapshot]
    ) {
        guard !snapshots.isEmpty, !isRemoving, hasCurrentInventory,
              let revisionID = loadedContentRevisionID else { return }
        recoverableRemovalCount = nil
        recoverableRemovalRevisionID = nil
        isRemoving = true
        removalStopRequested = false
        let generation = UUID()
        removalGeneration = generation
        removalTask = Task { @MainActor in
            defer {
                if removalGeneration == generation {
                    isRemoving = false
                    removalTask = nil
                }
            }
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.removeAnnotations(
                    recordID: recordID,
                    annotations: snapshots,
                    expectedContentRevisionID: revisionID
                )
            }
            guard removalGeneration == generation else { return }
            if succeeded,
               let recoveryRevision = model.pageRecoveryRevision(
                    recordID: recordID,
                    after: revisionID
               ) {
                recoverableRemovalRevisionID = recoveryRevision
                recoverableRemovalCount = snapshots.count
            }
            let wasStopped =
                removalStopRequested || Task.isCancelled
            removalStopRequested = false
            if wasStopped {
                if succeeded {
                    model[noticeFor: paperPathSceneID] =
                        "Annotation update finished before stopping · changes kept"
                            .localizedUI
                    Task { @MainActor in
                        await load()
                    }
                } else {
                    model[noticeFor: paperPathSceneID] =
                        "Annotation update stopped".localizedUI
                }
                return
            }
            guard succeeded else { return }
            await load()
            guard removalGeneration == generation else { return }
            if removalStopRequested || Task.isCancelled {
                removalStopRequested = false
                model[noticeFor: paperPathSceneID] =
                    "Annotation update finished before stopping · changes kept"
                        .localizedUI
                return
            }
            endSelection()
        }
    }

    private func undoLastRemoval() {
        guard !isRemoving, canReadReview,
              let recoveryRevision = recoverableRemovalRevisionID,
              model.record(id: recordID)?.contentRevisionID == recoveryRevision
        else {
            recoverableRemovalCount = nil
            recoverableRemovalRevisionID = nil
            return
        }
        isRemoving = true
        removalStopRequested = false
        let generation = UUID()
        removalGeneration = generation
        removalTask = Task { @MainActor in
            defer {
                if removalGeneration == generation {
                    isRemoving = false
                    removalTask = nil
                }
            }
            let succeeded = await model.undoLastPageChange(
                recordID: recordID,
                expectedContentRevisionID: recoveryRevision
            )
            guard removalGeneration == generation else { return }
            let wasStopped =
                removalStopRequested || Task.isCancelled
            removalStopRequested = false
            if wasStopped {
                if succeeded {
                    model[noticeFor: paperPathSceneID] =
                        "Annotation update finished before stopping · changes kept"
                            .localizedUI
                    Task { @MainActor in
                        await load()
                    }
                } else {
                    model[noticeFor: paperPathSceneID] =
                        "Annotation update stopped".localizedUI
                }
                return
            }
            guard succeeded else { return }
            await load()
            guard removalGeneration == generation else { return }
            if removalStopRequested || Task.isCancelled {
                removalStopRequested = false
                model[noticeFor: paperPathSceneID] =
                    "Annotation update finished before stopping · changes kept"
                        .localizedUI
                return
            }
            recoverableRemovalCount = nil
            recoverableRemovalRevisionID = nil
        }
    }

    private func exportSummary(
        _ snapshots: [PDFAnnotationSnapshot],
        scope: String
    ) {
        guard !snapshots.isEmpty, !isPreparingSummary, hasCurrentInventory,
              let revisionID = loadedContentRevisionID
        else { return }
        let documentName = model.record(id: recordID)?
            .displayName ?? "Document"
        let summaryTitle = "Annotation Summary".localizedUI
        let scopeLabel = "Scope".localizedUI
        let generatedLabel = "Generated".localizedUI
        let pageLabel = "Page".localizedUI
        let singularLabel = "annotation".localizedUI
        let pluralLabel = "annotations".localizedUI
        let noTextLabel = "No text content".localizedUI
        let readOnlyLabel = "read-only appearance".localizedUI
        let signatureTitle = "Signature".localizedUI
        let generatedTitles = Dictionary(
            uniqueKeysWithValues:
                PDFGeneratedAnnotationKind.allCases.map {
                    ($0, $0.title.localizedUI)
                }
        )
        let annotationTitles = [
            "highlight": "Highlight".localizedUI,
            "underline": "Underline".localizedUI,
            "strikeout": "Strikethrough".localizedUI,
            "ink": "Drawing".localizedUI,
            "text": "Note".localizedUI,
            "freetext": "Added Text".localizedUI,
            "link": "Web Link".localizedUI,
            "stamp": "Stamp".localizedUI,
            "squiggly": "Squiggly Underline".localizedUI,
            "caret": "Insertion Mark".localizedUI,
            "polygon": "Polygon".localizedUI,
            "polyline": "Polyline".localizedUI
        ]
        isPreparingSummary = true
        let generation = UUID()
        summaryGeneration = generation
        summaryTask = Task {
            var preparedURL: URL?
            defer {
                if summaryGeneration == generation {
                    isPreparingSummary = false
                    summaryTask = nil
                }
            }
            let worker = Task.detached(priority: .utility) {
                func annotationTitle(
                    _ annotation: PDFAnnotationSnapshot
                ) -> String {
                    if let generatedKind =
                        annotation.generatedKind {
                        return generatedTitles[generatedKind]
                            ?? generatedKind.title
                    }
                    if annotation.type.lowercased() == "ink",
                       annotation.contents == "Signature" {
                        return signatureTitle
                    }
                    if annotation.type.lowercased() == "stamp",
                       let contents = annotation.contents,
                       !contents.isEmpty {
                        return contents.localizedUI
                    }
                    return annotationTitles[
                        annotation.type.lowercased()
                    ] ?? annotation.type
                }

                let ordered = snapshots.sorted {
                    if $0.pageIndex != $1.pageIndex {
                        return $0.pageIndex < $1.pageIndex
                    }
                    return $0.annotationIndex
                        < $1.annotationIndex
                }
                var markdown = """
                # \(PDFAnnotationMarkdown.inline(documentName)) — \(summaryTitle)

                \(scopeLabel): \(PDFAnnotationMarkdown.inline(scope))
                \(generatedLabel) \(Date().formatted(date: .long, time: .shortened))

                \(ordered.count) \(ordered.count == 1 ? singularLabel : pluralLabel)

                """
                markdown.reserveCapacity(
                    min(
                        6_000_000,
                        512 + ordered.count * 180
                    )
                )
                var lastPage: Int?
                for annotation in ordered {
                    try Task.checkCancellation()
                    if lastPage != annotation.pageIndex {
                        if lastPage != nil {
                            markdown.append("\n")
                        }
                        markdown.append(
                            "## \(pageLabel) \(annotation.pageIndex + 1)\n"
                        )
                        lastPage = annotation.pageIndex
                    }
                    let rawContents = annotation.contents?
                        .replacingOccurrences(
                            of: "\n",
                            with: " "
                        )
                        .trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                    let boundedContents = rawContents.map {
                        String($0.prefix(500))
                            + ($0.count > 500 ? "…" : "")
                    }
                    let text = boundedContents.flatMap {
                        $0.isEmpty
                            ? nil
                            : PDFAnnotationMarkdown.inline($0)
                    } ?? noTextLabel
                    let state = annotation.hasAppearanceStream
                        && !annotation.canEdit
                        ? " · \(readOnlyLabel)"
                        : ""
                    markdown.append(
                        "- **\(PDFAnnotationMarkdown.inline(annotationTitle(annotation)))**\(state): \(text)\n"
                    )
                }

                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "PaperPath-Annotations-\(UUID().uuidString)",
                        isDirectory: true
                    )
                let url = directory.appendingPathComponent(
                    "annotations.md"
                )
                do {
                    try Task.checkCancellation()
                    try LocalFileSecurity.prepareProtectedDirectory(
                        at: directory
                    )
                    try markdown.write(
                        to: url,
                        atomically: true,
                        encoding: .utf8
                    )
                    try LocalFileSecurity.requireCompleteProtection(
                        to: url
                    )
                    LocalFileSecurity.excludeFromBackup(directory)
                    return url
                } catch {
                    PaperPathTemporaryArtifact.removeManagedItem(
                        containing: url,
                        allowedPrefixes: [
                            "PaperPath-Annotations-"
                        ]
                    )
                    throw error
                }
            }
            do {
                let url = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                preparedURL = url
                try Task.checkCancellation()
                guard summaryGeneration == generation,
                      canReadReview,
                      model.record(id: recordID)?.contentRevisionID == revisionID
                else {
                    PaperPathTemporaryArtifact.removeManagedItem(
                        containing: url,
                        allowedPrefixes: [
                            "PaperPath-Annotations-"
                        ]
                    )
                    preparedURL = nil
                    return
                }
                summaryURL = url
                preparedURL = nil
                isSharingSummary = true
            } catch is CancellationError {
                if let preparedURL {
                    PaperPathTemporaryArtifact.removeManagedItem(
                        containing: preparedURL,
                        allowedPrefixes: [
                            "PaperPath-Annotations-"
                        ]
                    )
                }
            } catch {
                if summaryGeneration == generation, !Task.isCancelled, canReadReview {
                    model.present(error, in: paperPathSceneID)
                }
            }
        }
    }

    private func cleanupSummary() {
        guard let summaryURL else { return }
        PaperPathTemporaryArtifact.removeManagedItem(
            containing: summaryURL,
            allowedPrefixes: ["PaperPath-Annotations-"]
        )
        self.summaryURL = nil
    }

    private func interruptProtectedReviewWork() {
        loadGeneration = UUID()
        projectionGeneration = UUID()
        stopRemoval(invalidateResult: true)
        stopSummaryPreparation()
        projectionTask?.cancel()
        projectionTask = nil
        editorTransitionGeneration = UUID()
        editorTransitionTask?.cancel()
        editorTransitionTask = nil
        annotations.removeAll(keepingCapacity: false)
        displayedAnnotations.removeAll(keepingCapacity: false)
        filterCounts.removeAll(keepingCapacity: false)
        annotationPageCount = 0
        editableAnnotationCount = 0
        readOnlyAnnotationCount = 0
        selectedAnnotationIDs.removeAll(keepingCapacity: false)
        editingAnnotation = nil
        editingContentRevisionID = nil
        pendingEditorAction = nil
        searchText = ""
        isSelecting = false
        isConfirmingRemoval = false
        loadedContentRevisionID = nil
        loadErrorMessage = nil
        isLoading = true
    }

    private func stopRemoval(
        invalidateResult: Bool = false
    ) {
        if invalidateResult {
            removalGeneration = UUID()
            removalStopRequested = false
        } else {
            guard removalTask != nil,
                  !removalStopRequested
            else { return }
            removalStopRequested = true
        }
        removalTask?.cancel()
        if invalidateResult {
            removalTask = nil
            isRemoving = false
        }
    }

    private func stopSummaryPreparation() {
        summaryGeneration = UUID()
        summaryTask?.cancel()
        summaryTask = nil
        isPreparingSummary = false
        isSharingSummary = false
        cleanupSummary()
    }

    private func title(for annotation: PDFAnnotationSnapshot) -> String {
        AnnotationReviewProjector.title(for: annotation)
    }

    private func symbol(for annotation: PDFAnnotationSnapshot) -> String {
        if let generatedKind = annotation.generatedKind {
            return generatedKind.symbol
        }
        if annotation.type.lowercased() == "ink",
           annotation.contents == "Signature" {
            return "signature"
        }
        switch annotation.type.lowercased() {
        case "highlight": return "highlighter"
        case "underline": return "underline"
        case "strikeout": return "strikethrough"
        case "ink": return "pencil.tip"
        case "text": return "note.text"
        case "freetext": return "textformat"
        case "link": return "link"
        case "stamp": return "seal"
        case "squiggly": return "scribble.variable"
        case "caret": return "chevron.up"
        case "polygon": return "triangle"
        case "polyline":
            return "point.topleft.down.to.point.bottomright.curvepath"
        default: return "text.bubble"
        }
    }
}

struct PDFAttachmentsView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let onSelectPage: (Int) -> Void

    @State private var attachments: [PDFEmbeddedAttachmentSnapshot] = []
    @State private var shareURLs: [URL] = []
    @State private var isLoading = true
    @State private var isPreparing = false
    @State private var isSharing = false
    @State private var activeAttachmentIDs: Set<String> = []
    @State private var exportTask: Task<Void, Never>?
    @State private var exportGeneration = UUID()
    @State private var loadGeneration = UUID()
    @State private var loadedContentRevisionID: UUID?
    @State private var loadErrorMessage: String?
    @State private var exportErrorMessage: String?
    @State private var retryAttachmentIDs: Set<String> = []
    @State private var reloadRequest = 0
    @State private var protectedDataAvailable =
        UIApplication.shared.isProtectedDataAvailable

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    PPEmptyState(
                        kind: .processing,
                        title: "Reading attachments",
                        message:
                            "PaperPath is checking embedded file streams locally."
                    )
                    .padding(PPSpacing.regular)
                } else if let loadErrorMessage {
                    VStack(spacing: PPSpacing.medium) {
                        PPEmptyState(
                            kind: .tools,
                            title: "Couldn’t inspect attachments",
                            message: loadErrorMessage
                        )
                        Button {
                            reloadRequest &+= 1
                        } label: {
                            Label("Retry".localizedUI, systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(PPPrimaryButtonStyle())
                        .disabled(!canReadAttachments)
                        .accessibilityIdentifier("retryAttachmentInspection")
                    }
                    .padding(PPSpacing.regular)
                } else if attachments.isEmpty {
                    PPEmptyState(
                        kind: .tools,
                        title: "No embedded files",
                        message:
                            "Page attachments and document-level files will appear here."
                    )
                    .padding(PPSpacing.regular)
                } else {
                    ScrollView {
                        LazyVStack(
                            alignment: .leading,
                            spacing: PPSpacing.medium
                        ) {
                            attachmentOverview
                            ForEach(attachments) { attachment in
                                attachmentRow(attachment)
                            }
                        }
                        .frame(maxWidth: 880)
                        .padding(PPSpacing.regular)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .background(PPColor.canvas)
            .navigationTitle("Attachments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (isPreparing ? "Stop" : "Done")
                            .localizedUI
                    ) {
                        if isPreparing {
                            stopAttachmentExport()
                        } else {
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                }
                if extractableCount > 1 {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            extract(
                                Set(
                                    attachments
                                        .filter(\.isExtractable)
                                        .map(\.id)
                                )
                            )
                        } label: {
                            Image(
                                systemName:
                                    "square.and.arrow.up.on.square"
                            )
                        }
                        .disabled(isPreparing || !hasCurrentAttachments)
                        .accessibilityLabel("Extract all attachments")
                    }
                }
            }
            .task(id: attachmentLoadRequest) {
                guard canReadAttachments else { return }
                if loadedContentRevisionID != attachmentLoadRequest.contentRevisionID {
                    stopAttachmentExport()
                    exportErrorMessage = nil
                    retryAttachmentIDs = []
                }
                await loadAttachments()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isPreparing {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Verifying embedded bytes")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        OnDeviceBadge(compact: true)
                    }
                    .padding(.horizontal, PPSpacing.regular)
                    .frame(minHeight: 44)
                    .background(.bar)
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(PPColor.border.opacity(0.62))
                            .frame(height: 0.6)
                    }
                } else if let exportErrorMessage {
                    VStack(alignment: .leading, spacing: PPSpacing.small) {
                        Label(
                            exportErrorMessage.localizedUI,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        Button {
                            extract(retryAttachmentIDs)
                        } label: {
                            Label("Retry".localizedUI, systemImage: "arrow.clockwise")
                                .frame(minHeight: 44)
                        }
                        .disabled(!hasCurrentAttachments || retryAttachmentIDs.isEmpty)
                    }
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                }
            }
            .interactiveDismissDisabled(isPreparing)
            .sheet(
                isPresented: $isSharing,
                onDismiss: discardExports
            ) {
                ShareSheet(items: shareURLs.map { $0 as Any })
                    .presentationDetents([.medium, .large])
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    interruptProtectedAttachmentWork()
                }
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                protectedDataAvailable = false
                interruptProtectedAttachmentWork()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataDidBecomeAvailableNotification
                )
            ) { _ in
                protectedDataAvailable = true
            }
            .onDisappear {
                interruptProtectedAttachmentWork()
            }
        }
    }

    private var attachmentOverview: some View {
        WorkflowCommandHeader(
            eyebrow: "ATTACHMENT WORKFLOW",
            title: "Embedded files",
            detail: "Verify embedded bytes before creating temporary extraction copies.",
            symbol: "paperclip",
            tint: PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(attachments.count)",
                    label: "Files",
                    symbol: "doc.badge.paperclip",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: "\(extractableCount)",
                    label: "Extractable",
                    symbol: "checkmark.shield",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "\(attachments.count - extractableCount)",
                    label: "Blocked",
                    symbol: "lock",
                    tint: attachments.count == extractableCount
                        ? PPColor.textSecondary
                        : PPColor.amber
                ),
                WorkflowMetric(
                    value: formattedAttachmentSize,
                    label: "Total",
                    symbol: "internaldrive",
                    tint: PPColor.accent
                )
            ]
        )
    }

    @ViewBuilder
    private func attachmentRow(
        _ attachment: PDFEmbeddedAttachmentSnapshot
    ) -> some View {
        Group {
            if dynamicTypeSize.ppPrefersExpandedLayout {
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    HStack(alignment: .top, spacing: PPSpacing.medium) {
                        attachmentSymbol(attachment)
                        attachmentDetails(attachment)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        attachmentExportButton(attachment)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: PPSpacing.medium) {
                    attachmentSymbol(attachment)
                    attachmentDetails(attachment)
                    attachmentExportButton(attachment)
                }
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.58))
                .frame(height: 0.6)
                .padding(.leading, 50)
        }
        .accessibilityElement(children: .contain)
    }

    private func attachmentSymbol(
        _ attachment: PDFEmbeddedAttachmentSnapshot
    ) -> some View {
        ToolSymbolPlate(
            symbol: attachment.isExtractable
                ? "doc.badge.paperclip"
                : "lock.doc",
            tint: attachment.isExtractable
                ? PPColor.cyan
                : PPColor.amber,
            size: 42
        )
    }

    private func attachmentDetails(
        _ attachment: PDFEmbeddedAttachmentSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(attachment.fileName)
                .font(.body.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    attachmentMetadata(attachment)
                }
                VStack(alignment: .leading, spacing: 2) {
                    attachmentMetadata(attachment)
                }
            }
            .font(.caption)
            .foregroundStyle(PPColor.textSecondary)

            if let description = attachment.description?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
               !description.isEmpty {
                Text(description.localizedUI)
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let limitation = attachment.limitation {
                Label(
                    limitation.localizedUI,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(PPColor.amber)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(
                    "SHA-256 \(String(attachment.checksum.prefix(12)))…"
                )
                .font(.caption2.monospaced())
                .foregroundStyle(PPColor.textSecondary)
            }

            if let pageIndex = attachment.pageIndex {
                Button {
                    openPage(pageIndex)
                } label: {
                    Label(
                        "Open page \(pageIndex + 1)",
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .disabled(isPreparing || !hasCurrentAttachments)
                .frame(minHeight: 44)
            } else {
                Text(attachment.origin.title.localizedUI)
                    .font(.caption2)
                    .foregroundStyle(PPColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func attachmentMetadata(
        _ attachment: PDFEmbeddedAttachmentSnapshot
    ) -> some View {
        Text(attachment.formattedSize)
        if let contentType = attachment.contentType,
           !contentType.isEmpty {
            Text("·")
            Text(contentType)
                .lineLimit(1)
        }
    }

    private func attachmentExportButton(
        _ attachment: PDFEmbeddedAttachmentSnapshot
    ) -> some View {
        Button {
            extract([attachment.id])
        } label: {
            Group {
                if activeAttachmentIDs.contains(attachment.id) {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.borderless)
        .disabled(isPreparing || !attachment.isExtractable || !hasCurrentAttachments)
        .help("Extract attachment".localizedUI)
        .hoverEffect(.highlight)
        .accessibilityLabel(
            AppLocalization.format(
                "Extract %@",
                attachment.fileName
            )
        )
    }

    private var extractableCount: Int {
        attachments.lazy.filter(\.isExtractable).count
    }

    private var formattedAttachmentSize: String {
        ByteCountFormatter.string(
            fromByteCount: totalAttachmentBytes,
            countStyle: .file
        )
    }

    private var totalAttachmentBytes: Int64 {
        attachments.reduce(Int64.zero) { total, attachment in
            let bytes = Int64(clamping: max(0, attachment.byteCount))
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? .max : sum
        }
    }

    private func loadAttachments() async {
        guard canReadAttachments, !Task.isCancelled else { return }
        let request = attachmentLoadRequest
        let generation = UUID()
        loadGeneration = generation
        isLoading = true
        loadErrorMessage = nil
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        let loaded: [PDFEmbeddedAttachmentSnapshot]
        do {
            loaded = try await model.inspectEmbeddedAttachments(recordID: recordID)
        } catch is CancellationError {
            return
        } catch {
            guard loadGeneration == generation, attachmentLoadRequest == request,
                  canReadAttachments, !Task.isCancelled else { return }
            loadErrorMessage = "The attachment list could not be read. Try again."
            return
        }
        guard !Task.isCancelled,
              loadGeneration == generation,
              attachmentLoadRequest == request, canReadAttachments
        else { return }
        attachments = loaded
        loadedContentRevisionID = request.contentRevisionID
        retryAttachmentIDs.formIntersection(Set(loaded.filter(\.isExtractable).map(\.id)))
    }

    private func extract(_ ids: Set<String>) {
        guard !ids.isEmpty, exportTask == nil, hasCurrentAttachments else { return }
        guard let loadedContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == loadedContentRevisionID
        else {
            model[noticeFor: paperPathSceneID] =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            Task { await loadAttachments() }
            return
        }
        let generation = UUID()
        exportGeneration = generation
        activeAttachmentIDs = ids
        retryAttachmentIDs = ids
        exportErrorMessage = nil
        isPreparing = true
        exportTask = Task { @MainActor in
            let urls = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.makeAttachmentExportCopies(
                    recordID: recordID,
                    attachmentIDs: ids,
                    expectedContentRevisionID:
                        loadedContentRevisionID,
                    presentsFeedback: false
                )
            }
            guard exportGeneration == generation else {
                await model.discardAttachmentExportCopies(at: urls)
                return
            }
            exportGeneration = UUID()
            isPreparing = false
            activeAttachmentIDs = []
            exportTask = nil
            guard !Task.isCancelled, canReadAttachments,
                  model.record(id: recordID)?.contentRevisionID == loadedContentRevisionID
            else {
                await model.discardAttachmentExportCopies(at: urls)
                return
            }
            guard !urls.isEmpty else {
                exportErrorMessage = "Attachment copies could not be prepared. Nothing was shared."
                return
            }
            retryAttachmentIDs = []
            shareURLs = urls
            isSharing = true
        }
    }

    private func openPage(_ pageIndex: Int) {
        guard hasCurrentAttachments, let loadedContentRevisionID,
              model.record(id: recordID)?.contentRevisionID
                == loadedContentRevisionID
        else {
            model[noticeFor: paperPathSceneID] =
                "The PDF changed before this action started. Review the updated PDF."
                    .localizedUI
            Task { await loadAttachments() }
            return
        }
        onSelectPage(pageIndex)
    }

    private func discardExports() {
        let urls = shareURLs
        shareURLs = []
        guard !urls.isEmpty else { return }
        Task {
            await model.discardAttachmentExportCopies(at: urls)
        }
    }

    private func interruptProtectedAttachmentWork() {
        loadGeneration = UUID()
        stopAttachmentExport()
        attachments = []
        loadedContentRevisionID = nil
        loadErrorMessage = nil
        exportErrorMessage = nil
        retryAttachmentIDs = []
        isLoading = true
    }

    private var canReadAttachments: Bool {
        scenePhase == .active && protectedDataAvailable
            && UIApplication.shared.isProtectedDataAvailable
    }

    private var hasCurrentAttachments: Bool {
        canReadAttachments && !isLoading && loadErrorMessage == nil
            && loadedContentRevisionID != nil
            && loadedContentRevisionID == model.record(id: recordID)?.contentRevisionID
    }

    private var attachmentLoadRequest: PDFReviewLoadRequest {
        PDFReviewLoadRequest(
            recordID: recordID,
            contentRevisionID: model.record(id: recordID)?.contentRevisionID,
            isAvailable: canReadAttachments,
            reload: reloadRequest
        )
    }

    private func stopAttachmentExport() {
        exportGeneration = UUID()
        exportTask?.cancel()
        exportTask = nil
        isPreparing = false
        isSharing = false
        activeAttachmentIDs = []
        discardExports()
    }
}

private struct AnnotationEditorSheet: View {
    private enum PendingExitAction {
        case dismiss
        case openPage
    }

    private struct ColorOption: Identifiable {
        let id: String
        let color: PDFInkColor

        var displayColor: Color {
            Color(
                red: color.red,
                green: color.green,
                blue: color.blue
            )
        }

        static let options = [
            ColorOption(
                id: "yellow",
                color: PDFInkColor(
                    red: 1,
                    green: 0.78,
                    blue: 0.08,
                    alpha: 1
                )
            ),
            ColorOption(
                id: "red",
                color: PDFInkColor(
                    red: 0.88,
                    green: 0.12,
                    blue: 0.16,
                    alpha: 1
                )
            ),
            ColorOption(
                id: "blue",
                color: PDFInkColor(
                    red: 0.04,
                    green: 0.36,
                    blue: 0.88,
                    alpha: 1
                )
            ),
            ColorOption(
                id: "green",
                color: PDFInkColor(
                    red: 0.08,
                    green: 0.58,
                    blue: 0.32,
                    alpha: 1
                )
            ),
            ColorOption(
                id: "black",
                color: PDFInkColor(
                    red: 0.08,
                    green: 0.08,
                    blue: 0.1,
                    alpha: 1
                )
            )
        ]
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.paperPathSceneID) private var paperPathSceneID

    let recordID: UUID
    let contentRevisionID: UUID
    let annotation: PDFAnnotationSnapshot
    let onSaved: () -> Void
    let onOpenPage: () -> Void

    @State private var contents: String
    @State private var selectedColor: PDFInkColor
    @State private var lineWidth: Double
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?
    @State private var saveGeneration = UUID()
    @State private var saveStopRequested = false
    @State private var saveErrorMessage: String?
    @State private var saveErrorFeedback = 0
    @State private var pendingExitAction: PendingExitAction?

    init(
        recordID: UUID,
        contentRevisionID: UUID,
        annotation: PDFAnnotationSnapshot,
        onSaved: @escaping () -> Void,
        onOpenPage: @escaping () -> Void
    ) {
        self.recordID = recordID
        self.contentRevisionID = contentRevisionID
        self.annotation = annotation
        self.onSaved = onSaved
        self.onOpenPage = onOpenPage
        _contents = State(initialValue: annotation.contents ?? "")
        _selectedColor = State(initialValue: annotation.color)
        _lineWidth = State(
            initialValue: annotation.lineWidth ?? 1
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
                            eyebrow: "ANNOTATION STYLE",
                            title: annotation.type,
                            detail: "Edit supported properties without flattening the annotation.",
                            symbol: "pencil.tip",
                            tint: Color(
                                red: selectedColor.red,
                                green: selectedColor.green,
                                blue: selectedColor.blue
                            ),
                            metrics: [
                                WorkflowMetric(
                                    value:
                                        "\(annotation.pageIndex + 1)",
                                    label: "Page",
                                    symbol: "doc.text",
                                    tint: PPColor.accent
                                ),
                                WorkflowMetric(
                                    value: annotation.canEditStyle
                                        ? "Editable"
                                        : "Read only",
                                    label: "Style",
                                    symbol: annotation.canEditStyle
                                        ? "paintpalette"
                                        : "lock",
                                    tint: annotation.canEditStyle
                                        ? PPColor.mint
                                        : PPColor.amber
                                ),
                                WorkflowMetric(
                                    value: supportsLineWidth
                                        ? lineWidth.formatted(
                                            .number.precision(
                                                .fractionLength(0...1)
                                            )
                                        ) + " pt"
                                        : "—",
                                    label: "Line",
                                    symbol: "scribble",
                                    tint: PPColor.cyan
                                )
                            ]
                        )

                        Button {
                            requestExit(.openPage)
                        } label: {
                            Label(
                                "Open on Page",
                                systemImage:
                                    "doc.text.magnifyingglass"
                            )
                        }
                        .disabled(isSaving || hasRevisionConflict)

                        if annotation.canEditContents {
                            WorkflowSectionHeader(
                                eyebrow: "CONTENT",
                                title: "Text or Note",
                                count: contents.count,
                                tint: contents.count > 2_000
                                    ? .red
                                    : PPColor.cyan
                            )
                            HStack(alignment: .bottom) {
                                TextField(
                                    "Optional annotation text",
                                    text: $contents,
                                    axis: .vertical
                                )
                                .lineLimit(2...6)
                                .onChange(of: contents) {
                                    _, value in
                                    if value.count > 2_000 {
                                        contents = String(
                                            value.prefix(2_000)
                                        )
                                    }
                                    saveErrorMessage = nil
                                }
                                .accessibilityIdentifier(
                                    "annotationComment"
                                )

                                PasteButton(
                                    payloadType: String.self
                                ) { values in
                                    guard let value = values.first
                                    else { return }
                                    contents = String(
                                        value.prefix(2_000)
                                    )
                                }
                                .labelStyle(.iconOnly)
                                .frame(minWidth: 44, minHeight: 44)
                                .disabled(isSaving)
                                .accessibilityLabel(
                                    "Paste annotation text"
                                        .localizedUI
                                )
                            }
                        }

                        if annotation.canEditStyle {
                            WorkflowSectionHeader(
                                eyebrow: "APPEARANCE",
                                title: "Color and line"
                            )
                            if dynamicTypeSize
                                .ppPrefersExpandedLayout {
                                VStack(
                                    alignment: .leading,
                                    spacing: PPSpacing.small
                                ) {
                                    annotationColorPalette
                                    annotationLineWidthControl
                                }
                            } else {
                                HStack(spacing: PPSpacing.small) {
                                    annotationColorPalette
                                    annotationLineWidthControl
                                }
                            }
                        }

                        if annotation.hasAppearanceStream
                            && !annotation.canEditStyle {
                            Label(
                                "The original appearance is preserved. Its visual style is read only.",
                                systemImage: "lock"
                            )
                            .font(.subheadline)
                            .foregroundStyle(PPColor.textSecondary)
                        }
                    }
                    .frame(maxWidth: 720)
                    .padding(PPSpacing.regular)
                    .padding(.bottom, 72)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                .disabled(isSaving)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: PPSpacing.xSmall) {
                    if hasRevisionConflict && !isSaving {
                        Label(
                            "The PDF changed in another view. Your draft has not been applied.".localizedUI,
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let saveErrorMessage {
                        Label(
                            saveErrorMessage,
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.rose)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        save()
                    } label: {
                        Label(
                            isSaving ? "Saving" : "Save Changes",
                            systemImage: isSaving
                                ? "hourglass"
                                : "checkmark"
                        )
                    }
                    .buttonStyle(PPPrimaryButtonStyle())
                    .disabled(
                        isSaving
                            || hasRevisionConflict
                            || contents.count > 2_000
                            || !hasChanges
                    )
                    .keyboardShortcut(.defaultAction)
                    .accessibilityHint(saveAccessibilityHint)
                    .accessibilityIdentifier("saveAnnotationEdit")
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
            .navigationTitle("Edit Annotation")
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
                            requestAnnotationSaveStop()
                        } else {
                            requestExit(.dismiss)
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saveStopRequested)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .confirmationDialog(
                "Discard changes?".localizedUI,
                isPresented: Binding(
                    get: { pendingExitAction != nil },
                    set: {
                        if !$0 {
                            pendingExitAction = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button(
                    "Discard Changes".localizedUI,
                    role: .destructive
                ) {
                    performPendingExit()
                }
                Button("Keep Editing".localizedUI, role: .cancel) {
                    pendingExitAction = nil
                }
            } message: {
                Text(
                    "Your annotation edits have not been saved."
                        .localizedUI
                )
            }
            .interactiveDismissDisabled(isSaving || hasChanges)
            .accessibilityAction(.escape) {
                if isSaving {
                    requestAnnotationSaveStop()
                } else {
                    requestExit(.dismiss)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                interruptProtectedAnnotationEditing()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication
                        .protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                interruptProtectedAnnotationEditing()
            }
            .onDisappear {
                invalidateAnnotationSave()
                contents = ""
                pendingExitAction = nil
                saveErrorMessage = nil
            }
            .sensoryFeedback(.error, trigger: saveErrorFeedback)
        }
    }

    private var supportsLineWidth: Bool {
        switch annotation.type.lowercased() {
        case "ink", "square", "circle", "line":
            return true
        default:
            return false
        }
    }

    private var annotationColorPalette: some View {
        HStack(spacing: PPSpacing.small) {
            ForEach(ColorOption.options) { option in
                Button {
                    selectedColor = option.color
                } label: {
                    Circle()
                        .fill(option.displayColor)
                        .frame(width: 30, height: 30)
                        .overlay {
                            if colorsMatch(
                                selectedColor,
                                option.color
                            ) {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(
                                        option.id == "yellow"
                                            ? Color.black
                                            : Color.white
                                    )
                            }
                        }
                        .overlay {
                            Circle()
                                .stroke(
                                    PPColor.border,
                                    lineWidth: 0.7
                                )
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    AppLocalization.format(
                        "%@ annotation color",
                        option.id.capitalized.localizedUI
                    )
                )
                .accessibilityAddTraits(
                    colorsMatch(selectedColor, option.color)
                        ? .isSelected
                        : []
                )
                .accessibilityIdentifier(
                    "annotationColor-\(option.id)"
                )
            }
        }
    }

    @ViewBuilder
    private var annotationLineWidthControl: some View {
        if supportsLineWidth {
            Slider(
                value: $lineWidth,
                in: 0.5...12,
                step: 0.5
            ) {
                Text("Line width")
            } minimumValueLabel: {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
            } maximumValueLabel: {
                Image(systemName: "circle.fill")
                    .font(.system(size: 13))
            }
            .frame(
                maxWidth: dynamicTypeSize.ppPrefersExpandedLayout
                    ? .infinity
                    : nil
            )
            .accessibilityIdentifier("annotationLineWidth")
        }
    }

    private var hasChanges: Bool {
        contents != (annotation.contents ?? "")
            || !colorsMatch(selectedColor, annotation.color)
            || (
                supportsLineWidth
                    && abs(
                        lineWidth - (annotation.lineWidth ?? 1)
                    ) > 0.01
            )
    }

    private var hasRevisionConflict: Bool {
        model.record(id: recordID)?.contentRevisionID != contentRevisionID
    }

    private var saveAccessibilityHint: String {
        if hasRevisionConflict {
            return "The PDF changed in another view. Your draft has not been applied.".localizedUI
        }
        if isSaving {
            return "Wait for the annotation to finish saving."
                .localizedUI
        }
        if !hasChanges {
            return "Change the annotation before saving."
                .localizedUI
        }
        return "Saves the annotation to the private working copy."
            .localizedUI
    }

    private func requestExit(_ action: PendingExitAction) {
        guard hasChanges else {
            performExit(action)
            return
        }
        pendingExitAction = action
    }

    private func performPendingExit() {
        guard let action = pendingExitAction else { return }
        pendingExitAction = nil
        performExit(action)
    }

    private func performExit(_ action: PendingExitAction) {
        switch action {
        case .dismiss:
            dismiss()
        case .openPage:
            onOpenPage()
        }
    }

    private func save() {
        guard !isSaving, !hasRevisionConflict, hasChanges,
              contents.count <= 2_000,
              scenePhase == .active,
              UIApplication.shared.isProtectedDataAvailable
        else { return }
        saveErrorMessage = nil
        isSaving = true
        saveStopRequested = false
        let generation = UUID()
        saveGeneration = generation
        saveTask = Task {
            let succeeded = await model.withFeedbackTarget(
                paperPathSceneID
            ) {
                await model.editAnnotation(
                    recordID: recordID,
                    payload: PDFAnnotationEditPayload(
                        pageIndex: annotation.pageIndex,
                        annotationIndex: annotation.annotationIndex,
                        expectedType: annotation.type,
                        expectedMutationIdentity:
                            annotation.mutationIdentity,
                        contents: contents,
                        color: selectedColor,
                        lineWidth: supportsLineWidth
                            ? lineWidth
                            : nil
                    ),
                    expectedContentRevisionID: contentRevisionID
                )
            }
            guard saveGeneration == generation else { return }
            let wasStopped =
                saveStopRequested || Task.isCancelled
            isSaving = false
            saveTask = nil
            saveStopRequested = false
            if wasStopped {
                if succeeded {
                    model[noticeFor: paperPathSceneID] =
                        "Annotation update finished before stopping · changes kept"
                            .localizedUI
                    onSaved()
                } else {
                    model[noticeFor: paperPathSceneID] =
                        "Annotation update stopped · working copy unchanged"
                            .localizedUI
                }
                return
            }
            if succeeded {
                onSaved()
            } else {
                saveErrorMessage =
                    "The annotation could not be saved. Try again."
                        .localizedUI
                saveErrorFeedback += 1
            }
        }
    }

    private func requestAnnotationSaveStop() {
        guard saveTask != nil,
              !saveStopRequested
        else { return }
        saveStopRequested = true
        saveTask?.cancel()
    }

    private func invalidateAnnotationSave() {
        saveGeneration = UUID()
        saveTask?.cancel()
        saveTask = nil
        isSaving = false
        saveStopRequested = false
    }

    private func interruptProtectedAnnotationEditing() {
        invalidateAnnotationSave()
        contents = ""
        dismiss()
    }

    private func colorsMatch(
        _ left: PDFInkColor,
        _ right: PDFInkColor
    ) -> Bool {
        let tolerance = 0.025
        return abs(left.red - right.red) <= tolerance
            && abs(left.green - right.green) <= tolerance
            && abs(left.blue - right.blue) <= tolerance
    }
}
