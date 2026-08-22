import SwiftUI

enum PDFAnnotationMarkdown {
    static func inline(_ value: String) -> String {
        var escaped = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
        for marker in ["`", "*", "_", "{", "}", "[", "]", "<", ">", "#", "!", "|"] {
            escaped = escaped.replacingOccurrences(
                of: marker,
                with: "\\\(marker)"
            )
        }
        return escaped
    }
}

private enum AnnotationReviewFilter: String, CaseIterable, Identifiable {
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

struct AnnotationReviewView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let onSelectPage: (Int) -> Void
    @State private var annotations: [PDFAnnotationSnapshot] = []
    @State private var displayedAnnotations:
        [PDFAnnotationSnapshot] = []
    @State private var filterCounts:
        [AnnotationReviewFilter: Int] = [:]
    @State private var isLoading = true
    @State private var editingAnnotation: PDFAnnotationSnapshot?
    @State private var filter = AnnotationReviewFilter.all
    @State private var searchText = ""
    @State private var isTruncated = false
    @State private var displayLimit = 10_000
    @State private var isSelecting = false
    @State private var selectedAnnotationIDs: Set<String> = []
    @State private var isConfirmingRemoval = false
    @State private var isRemoving = false
    @State private var removalTask: Task<Void, Never>?
    @State private var recoverableRemovalCount: Int?
    @State private var summaryURL: URL?
    @State private var isSharingSummary = false
    @State private var isPreparingSummary = false
    @State private var summaryTask: Task<Void, Never>?

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
            .navigationTitle("Annotations")
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
                                || isRemoving
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
                                || isRemoving
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
            .onChange(of: searchText) { _, value in
                let bounded = String(value.prefix(200))
                if value != bounded {
                    searchText = bounded
                }
                displayedAnnotations = projectedAnnotations(
                    annotations,
                    filter: filter,
                    query: bounded
                )
            }
            .task {
                await load()
            }
            .sheet(item: $editingAnnotation) { annotation in
                AnnotationEditorSheet(
                    recordID: recordID,
                    annotation: annotation,
                    onSaved: {
                        editingAnnotation = nil
                        Task { await load() }
                    },
                    onOpenPage: {
                        editingAnnotation = nil
                        dismiss()
                        onSelectPage(annotation.pageIndex)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
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
            .onDisappear {
                removalTask?.cancel()
                summaryTask?.cancel()
                cleanupSummary()
            }
        }
    }

    private func load() async {
        let inventory = await model.annotationInventory(
            recordID: recordID
        )
        let loadedAnnotations = inventory.annotations
        annotations = loadedAnnotations
        filterCounts = Dictionary(
            uniqueKeysWithValues:
                AnnotationReviewFilter.allCases.map {
                    candidate in
                    (
                        candidate,
                        loadedAnnotations.lazy.filter {
                            matches($0, filter: candidate)
                        }.count
                    )
                }
        )
        displayedAnnotations = projectedAnnotations(
            loadedAnnotations,
            filter: filter,
            query: searchText
        )
        isTruncated = inventory.isTruncated
        displayLimit = inventory.displayLimit
        selectedAnnotationIDs.formIntersection(
            Set(annotations.map(\.id))
        )
        isLoading = false
    }

    private var annotationOverview: some View {
        WorkflowCommandHeader(
            eyebrow: "REVIEW WORKFLOW",
            title: "Annotations",
            detail: "Search marks, edit supported properties, or remove verified batches.",
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
                    value: "\(Set(annotations.map(\.pageIndex)).count)",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: "\(annotations.filter(\.canEdit).count)",
                    label: "Editable",
                    symbol: "pencil",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "\(annotations.filter { $0.hasAppearanceStream && !$0.canEdit }.count)",
                    label: "Read only",
                    symbol: "lock",
                    tint: PPColor.textSecondary
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
        .disabled(isPreparingSummary || isRemoving)
        .accessibilityLabel("Annotation actions")
        .accessibilityIdentifier("annotationActions")
    }

    @ViewBuilder
    private var reviewStatusBar: some View {
        if isRemoving {
            operationStatusBar(
                title: "Removing annotations",
                actionTitle: "Stop"
            ) {
                removalTask?.cancel()
            }
        } else if isPreparingSummary {
            operationStatusBar(
                title: "Preparing annotation summary",
                actionTitle: "Stop"
            ) {
                summaryTask?.cancel()
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
        .disabled(selectedAnnotationIDs.isEmpty)
    }

    private func operationStatusBar(
        title: String,
        actionTitle: String,
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
                .buttonStyle(.plain)
        }
        .padding(.horizontal, PPSpacing.regular)
        .frame(minHeight: 48)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.6)
        }
    }

    private func annotationRow(
        _ annotation: PDFAnnotationSnapshot
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Button {
                if isSelecting {
                    toggleSelection(annotation)
                } else {
                    dismiss()
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
                            annotation.contents?.isEmpty == false
                                ? annotation.contents!
                                : "Page \(annotation.pageIndex + 1)"
                        )
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
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
                                    ? "Selected"
                                    : "Not selected"
                            )
                            : "Read only"
                    )
                    : ""
            )

            if !isSelecting && annotation.canEdit {
                Button {
                    editingAnnotation = annotation
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    "Edit \(title(for: annotation))"
                )
            } else if !isSelecting
                && annotation.hasAppearanceStream {
                Image(systemName: "lock")
                    .font(.caption)
                    .foregroundStyle(PPColor.textSecondary)
                    .frame(width: 34, height: 34)
            }

            if !isSelecting && annotation.canRemove {
                Button(role: .destructive) {
                    removeAnnotations([annotation])
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .accessibilityLabel("Remove annotation")
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
    }

    private var annotationFilterRail: some View {
        ScrollView(.horizontal) {
            HStack(spacing: PPSpacing.small) {
                ForEach(visibleFilters) { candidate in
                    let count = annotationCount(candidate)
                    let isSelected = candidate == filter
                    Button {
                        filter = candidate
                        displayedAnnotations = projectedAnnotations(
                            annotations,
                            filter: candidate,
                            query: searchText
                        )
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
                        .frame(minHeight: 34)
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

    private func annotationCount(
        _ candidate: AnnotationReviewFilter
    ) -> Int {
        filterCounts[candidate, default: 0]
    }

    private func projectedAnnotations(
        _ source: [PDFAnnotationSnapshot],
        filter: AnnotationReviewFilter,
        query: String
    ) -> [PDFAnnotationSnapshot] {
        let filtered = source.filter {
            matches($0, filter: filter)
        }
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedQuery.isEmpty else { return filtered }
        return filtered.filter {
            searchMatches($0, query: normalizedQuery)
        }
    }

    private func matches(
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

    private func searchMatches(
        _ annotation: PDFAnnotationSnapshot,
        query: String
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
        return searchable.localizedCaseInsensitiveContains(query)
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
        removeAnnotations(
            Array(selectedAnnotations.prefix(2_000))
        )
    }

    private func removeAnnotations(
        _ snapshots: [PDFAnnotationSnapshot]
    ) {
        guard !snapshots.isEmpty, !isRemoving else { return }
        recoverableRemovalCount = nil
        isRemoving = true
        removalTask = Task {
            let succeeded = await model.removeAnnotations(
                recordID: recordID,
                annotations: snapshots
            )
            if Task.isCancelled {
                if succeeded {
                    dismiss()
                }
                isRemoving = false
                removalTask = nil
                return
            }
            if succeeded {
                await load()
                endSelection()
                recoverableRemovalCount = snapshots.count
            }
            isRemoving = false
            removalTask = nil
        }
    }

    private func undoLastRemoval() {
        guard !isRemoving else { return }
        isRemoving = true
        removalTask = Task {
            let succeeded = await model.undoLastPageChange(
                recordID: recordID
            )
            if Task.isCancelled {
                if succeeded {
                    dismiss()
                }
                isRemoving = false
                removalTask = nil
                return
            }
            if succeeded {
                await load()
                recoverableRemovalCount = nil
            }
            isRemoving = false
            removalTask = nil
        }
    }

    private func exportSummary(
        _ snapshots: [PDFAnnotationSnapshot],
        scope: String
    ) {
        guard !snapshots.isEmpty, !isPreparingSummary else { return }
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
        summaryTask = Task {
            var preparedURL: URL?
            defer {
                isPreparingSummary = false
                summaryTask = nil
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
                    let text = boundedContents?.isEmpty == false
                        ? PDFAnnotationMarkdown.inline(boundedContents!)
                        : noTextLabel
                    let state = annotation.hasAppearanceStream
                        && !annotation.canEdit
                        ? " · \(readOnlyLabel)"
                        : ""
                    markdown.append(
                        "- **\(PDFAnnotationMarkdown.inline(annotationTitle(annotation)))**\(state): \(text)\n"
                    )
                }

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "PaperPath-Annotations-\(UUID().uuidString).md"
                    )
                try Task.checkCancellation()
                try markdown.write(
                    to: url,
                    atomically: true,
                    encoding: .utf8
                )
                LocalFileSecurity.applyCompleteProtection(to: url)
                LocalFileSecurity.excludeFromBackup(url)
                return url
            }
            do {
                let url = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                preparedURL = url
                try Task.checkCancellation()
                summaryURL = url
                preparedURL = nil
                isSharingSummary = true
            } catch is CancellationError {
                if let preparedURL {
                    try? FileManager.default.removeItem(
                        at: preparedURL
                    )
                }
            } catch {
                model.present(error)
            }
        }
    }

    private func cleanupSummary() {
        guard let summaryURL else { return }
        try? FileManager.default.removeItem(at: summaryURL)
        self.summaryURL = nil
    }

    private func title(for annotation: PDFAnnotationSnapshot) -> String {
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

    let recordID: UUID
    let onSelectPage: (Int) -> Void

    @State private var attachments: [PDFEmbeddedAttachmentSnapshot] = []
    @State private var shareURLs: [URL] = []
    @State private var isLoading = true
    @State private var isPreparing = false
    @State private var isSharing = false

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
                        VStack(
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
                    Button("Done") { dismiss() }
                        .disabled(isPreparing)
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
                        .disabled(isPreparing)
                        .accessibilityLabel("Extract all attachments")
                    }
                }
            }
            .task {
                attachments = await model.embeddedAttachments(
                    recordID: recordID
                )
                isLoading = false
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
        HStack(alignment: .top, spacing: PPSpacing.medium) {
            ToolSymbolPlate(
                symbol: attachment.isExtractable
                    ? "doc.badge.paperclip"
                    : "lock.doc",
                tint: attachment.isExtractable
                    ? PPColor.cyan
                    : PPColor.amber,
                size: 42
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(attachment.fileName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    Text(attachment.formattedSize)
                    if let contentType = attachment.contentType,
                       !contentType.isEmpty {
                        Text("·")
                        Text(contentType)
                            .lineLimit(1)
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
                        .lineLimit(2)
                }

                if let limitation = attachment.limitation {
                    Label(
                        limitation.localizedUI,
                        systemImage: "exclamationmark.triangle"
                    )
                        .font(.caption)
                        .foregroundStyle(PPColor.amber)
                } else {
                    Text(
                        "SHA-256 \(String(attachment.checksum.prefix(12)))…"
                    )
                    .font(.caption2.monospaced())
                    .foregroundStyle(PPColor.textSecondary)
                }

                if let pageIndex = attachment.pageIndex {
                    Button {
                        dismiss()
                        onSelectPage(pageIndex)
                    } label: {
                        Label(
                            "Open page \(pageIndex + 1)",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.plain)
                } else {
                    Text(attachment.origin.title.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                extract([attachment.id])
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .disabled(isPreparing || !attachment.isExtractable)
            .accessibilityLabel(
                "Extract \(attachment.fileName)"
            )
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

    private var extractableCount: Int {
        attachments.lazy.filter(\.isExtractable).count
    }

    private var formattedAttachmentSize: String {
        ByteCountFormatter.string(
            fromByteCount: Int64(
                attachments.reduce(0) { $0 + $1.byteCount }
            ),
            countStyle: .file
        )
    }

    private func extract(_ ids: Set<String>) {
        guard !ids.isEmpty, !isPreparing else { return }
        isPreparing = true
        Task {
            let urls = await model.makeAttachmentExportCopies(
                recordID: recordID,
                attachmentIDs: ids
            )
            guard !Task.isCancelled else {
                await model.discardAttachmentExportCopies(at: urls)
                isPreparing = false
                return
            }
            isPreparing = false
            guard !urls.isEmpty else { return }
            shareURLs = urls
            isSharing = true
        }
    }

    private func discardExports() {
        let urls = shareURLs
        shareURLs = []
        guard !urls.isEmpty else { return }
        Task {
            await model.discardAttachmentExportCopies(at: urls)
        }
    }
}

private struct AnnotationEditorSheet: View {
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

    let recordID: UUID
    let annotation: PDFAnnotationSnapshot
    let onSaved: () -> Void
    let onOpenPage: () -> Void

    @State private var contents: String
    @State private var selectedColor: PDFInkColor
    @State private var lineWidth: Double
    @State private var isSaving = false
    @State private var saveTask: Task<Void, Never>?

    init(
        recordID: UUID,
        annotation: PDFAnnotationSnapshot,
        onSaved: @escaping () -> Void,
        onOpenPage: @escaping () -> Void
    ) {
        self.recordID = recordID
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
                        onOpenPage()
                    } label: {
                        Label(
                            "Open on Page",
                            systemImage: "doc.text.magnifyingglass"
                        )
                    }

                if annotation.canEditContents {
                            WorkflowSectionHeader(
                                eyebrow: "CONTENT",
                                title: "Text or Note",
                                count: contents.count,
                                tint: contents.count > 2_000
                                    ? .red
                                    : PPColor.cyan
                            )
                        TextField(
                            "Optional annotation text",
                            text: $contents,
                            axis: .vertical
                        )
                        .lineLimit(2...6)
                        .accessibilityIdentifier(
                            "annotationComment"
                        )
                }

                if annotation.canEditStyle {
                            WorkflowSectionHeader(
                                eyebrow: "APPEARANCE",
                                title: "Color and line"
                            )
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
                                                Image(
                                                    systemName: "checkmark"
                                                )
                                                .font(
                                                    .caption.weight(.bold)
                                                )
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
                                    "\(option.id.capitalized) annotation color"
                                )
                                .accessibilityIdentifier(
                                    "annotationColor-\(option.id)"
                                )
                            }

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
                                    .accessibilityIdentifier(
                                        "annotationLineWidth"
                                    )
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
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
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
                        || contents.count > 2_000
                        || !hasChanges
                )
                .accessibilityIdentifier("saveAnnotationEdit")
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
                    Button((isSaving ? "Stop" : "Cancel").localizedUI) {
                        if isSaving {
                            saveTask?.cancel()
                            saveTask = nil
                            isSaving = false
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onDisappear {
                saveTask?.cancel()
                saveTask = nil
            }
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

    private func save() {
        isSaving = true
        saveTask = Task {
            let succeeded = await model.editAnnotation(
                recordID: recordID,
                payload: PDFAnnotationEditPayload(
                    pageIndex: annotation.pageIndex,
                    annotationIndex: annotation.annotationIndex,
                    expectedType: annotation.type,
                    contents: contents,
                    color: selectedColor,
                    lineWidth: supportsLineWidth
                        ? lineWidth
                        : nil
                )
            )
            guard !Task.isCancelled else {
                isSaving = false
                saveTask = nil
                return
            }
            isSaving = false
            saveTask = nil
            if succeeded {
                dismiss()
                onSaved()
            }
        }
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
