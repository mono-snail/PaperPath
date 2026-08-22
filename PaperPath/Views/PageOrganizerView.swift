import ImageIO
import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

struct PageOrganizerView: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let recordID: UUID
    let startInSelectionMode: Bool
    let onCreated: (DocumentRoute) -> Void

    @State private var pendingDeleteIndex: Int?
    @State private var selectedIndices: Set<Int> = []
    @State private var isSelecting: Bool
    @State private var isImportingPages = false
    @State private var isChoosingDestination = false
    @State private var isSelectingRange = false
    @State private var isConfirmingBulkDelete = false
    @State private var cropPageIndex: Int?
    @State private var replacementTargetIndex: Int?
    @State private var isPresentingRuleWorkbench = false
    @State private var isPresentingPageNumbers = false
    @State private var isPresentingWatermark = false
    @State private var isPresentingBatesNumbers = false
    @State private var isPreparingPages = false
    @State private var preparationInitialSelection: Set<Int> = []

    init(
        recordID: UUID,
        startInSelectionMode: Bool = false,
        onCreated: @escaping (DocumentRoute) -> Void
    ) {
        self.recordID = recordID
        self.startInSelectionMode = startInSelectionMode
        self.onCreated = onCreated
        _isSelecting = State(initialValue: startInSelectionMode)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PPCanvas()
                if let record = model.record(id: recordID),
                   let url = model.url(for: recordID) {
                    pageList(record: record, url: url)
                } else {
                    PPEmptyState(
                        kind: .workspace,
                        title: "Pages unavailable",
                        message: "Return to the library and reopen this document."
                    )
                    .padding(PPSpacing.regular)
                }
            }
            .navigationTitle(
                (
                    startInSelectionMode
                        ? "Split PDF"
                        : "Organize pages"
                ).localizedUI
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            isSelecting
                                ? "Cancel"
                                : "Select"
                        ).localizedUI
                    ) {
                        withAnimation(
                            reduceMotion ? nil : .easeOut(duration: 0.18)
                        ) {
                            isSelecting.toggle()
                            selectedIndices.removeAll()
                        }
                    }
                    .disabled(model.isProcessing(recordID))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .disabled(model.isProcessing(recordID))
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        if model.canUndoPageChange(recordID: recordID) {
                            Button {
                                Task {
                                    _ = await model.undoLastPageChange(
                                        recordID: recordID
                                    )
                                }
                            } label: {
                                Label(
                                    "Undo Last Page Change",
                                    systemImage: "arrow.uturn.backward"
                                )
                            }
                            Divider()
                        }
                        Button {
                            if let record = model.record(id: recordID) {
                                Task {
                                    await model.insertBlankPage(
                                        recordID: recordID,
                                        after: record.profile.pageCount - 1
                                    )
                                }
                            }
                        } label: {
                            Label("Add Blank Page", systemImage: "doc.badge.plus")
                        }

                        Button {
                            isImportingPages = true
                        } label: {
                            Label("Add Pages from PDF", systemImage: "doc.on.doc")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(model.isProcessing(recordID))
                    .accessibilityLabel("Add pages")
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting {
                    extractionBar
                } else if model.isProcessing(recordID) {
                    HStack(spacing: PPSpacing.small) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Updating working copy")
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
        }
        .confirmationDialog(
            "Remove this page?",
            isPresented: Binding(
                get: { pendingDeleteIndex != nil },
                set: { if !$0 { pendingDeleteIndex = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Page", role: .destructive) {
                guard let index = pendingDeleteIndex else { return }
                pendingDeleteIndex = nil
                Task {
                    await model.deletePage(recordID: recordID, index: index)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteIndex = nil
            }
        } message: {
            Text("Only the private working copy changes.")
        }
        .confirmationDialog(
            "Remove \(selectedIndices.count) selected pages?",
            isPresented: $isConfirmingBulkDelete,
            titleVisibility: .visible
        ) {
            Button("Remove Pages", role: .destructive) {
                let indices = selectedIndices
                Task {
                    if await model.deletePages(
                        recordID: recordID,
                        indices: indices
                    ) {
                        selectedIndices.removeAll()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The private working copy keeps at least one page. You can undo this once."
            )
        }
        .fileImporter(
            isPresented: $isImportingPages,
            allowedContentTypes: [.pdf]
        ) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result {
                    model.present(error)
                }
                return
            }
            Task {
                await model.appendPages(recordID: recordID, from: url)
            }
        }
        .sheet(isPresented: $isChoosingDestination) {
            PageCopyDestinationSheet(
                sourceRecordID: recordID,
                selectedCount: selectedIndices.count
            ) { destinationID in
                let indices = selectedIndices
                Task {
                    if await model.copyPages(
                        from: recordID,
                        indices: indices,
                        to: destinationID
                    ) {
                        selectedIndices.removeAll()
                        isSelecting = false
                    }
                }
            }
        }
        .sheet(isPresented: $isSelectingRange) {
            if let record = model.record(id: recordID) {
                PageRangeSelectionSheet(
                    pageCount: record.profile.pageCount
                ) { range in
                    selectedIndices = Set(range)
                }
                .presentationDetents([.medium])
            }
        }
        .sheet(isPresented: $isPresentingRuleWorkbench) {
            PageRuleWorkbench(
                recordID: recordID,
                currentSelection: selectedIndices
            ) { selection in
                selectedIndices = selection
                isSelecting = true
                isPresentingRuleWorkbench = false
            } onReorder: { order, label in
                isPresentingRuleWorkbench = false
                Task {
                    _ = await model.reorderPages(
                        recordID: recordID,
                        order: order,
                        label: label
                    )
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $isPresentingPageNumbers) {
            if let record = model.record(id: recordID) {
                PageNumberingSheet(
                    pageCount: record.profile.pageCount,
                    onApply: { payload in
                        await model.applyPageNumbers(
                            recordID: recordID,
                            payload: payload
                        )
                    },
                    onRemoveAll: {
                        await model.removeGeneratedPageNumbers(
                            recordID: recordID
                        )
                    }
                )
                .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $isPresentingWatermark) {
            if let record = model.record(id: recordID) {
                WatermarkSheet(
                    pageCount: record.profile.pageCount,
                    onApply: { payload in
                        await model.applyWatermark(
                            recordID: recordID,
                            payload: payload
                        )
                    },
                    onRemoveAll: {
                        await model.removeGeneratedWatermarks(
                            recordID: recordID
                        )
                    }
                )
                .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $isPresentingBatesNumbers) {
            if let record = model.record(id: recordID) {
                BatesNumberingSheet(
                    pageCount: record.profile.pageCount,
                    onApply: { payload in
                        await model.applyBatesNumbers(
                            recordID: recordID,
                            payload: payload
                        )
                    },
                    onRemoveAll: {
                        await model.removeGeneratedBatesNumbers(
                            recordID: recordID
                        )
                    }
                )
                .presentationDetents([.large])
            }
        }
        .sheet(
            isPresented: Binding(
                get: { replacementTargetIndex != nil },
                set: {
                    if !$0 {
                        replacementTargetIndex = nil
                    }
                }
            )
        ) {
            if let replacementTargetIndex {
                PageReplacementSheet(
                    destinationRecordID: recordID,
                    destinationPageIndex: replacementTargetIndex
                ) {
                    self.replacementTargetIndex = nil
                }
                .presentationDetents([.large])
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { cropPageIndex != nil },
                set: {
                    if !$0 {
                        cropPageIndex = nil
                    }
                }
            )
        ) {
            if let cropPageIndex {
                PageCropEditorView(
                    recordID: recordID,
                    pageIndex: cropPageIndex
                ) {
                    self.cropPageIndex = nil
                }
            }
        }
        .fullScreenCover(isPresented: $isPreparingPages) {
            PagePreparationView(
                recordID: recordID,
                initialSelection: preparationInitialSelection
            ) {
                isPreparingPages = false
                selectedIndices.removeAll()
                isSelecting = false
            }
        }
        .interactiveDismissDisabled(model.isProcessing(recordID))
        .sensoryFeedback(.selection, trigger: selectedIndices)
        .sensoryFeedback(
            .success,
            trigger: model.refreshToken(for: recordID)
        )
        .onChange(
            of: model.record(id: recordID)?.profile.pageCount
        ) { _, pageCount in
            guard let pageCount else { return }
            selectedIndices = selectedIndices.filter {
                $0 >= 0 && $0 < pageCount
            }
        }
    }

    private func pageList(
        record: DocumentRecord,
        url: URL
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: PPSpacing.medium) {
                organizerHeader(record)
                if !startInSelectionMode {
                    organizerCommandDeck(record)
                }

                LazyVGrid(
                    columns: pageColumns,
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    ForEach(
                        0..<record.profile.pageCount,
                        id: \.self
                    ) { index in
                        pageRow(
                            index: index,
                            pageCount: record.profile.pageCount,
                            url: url
                        )
                    }
                }
            }
            .frame(maxWidth: 1_080)
            .padding(PPSpacing.regular)
            .frame(maxWidth: .infinity)
            .id(model.refreshToken(for: recordID))
        }
    }

    private func organizerHeader(_ record: DocumentRecord) -> some View {
        WorkflowCommandHeader(
            eyebrow: startInSelectionMode
                ? "SPLIT WORKFLOW"
                : "PAGE WORKFLOW",
            title: startInSelectionMode
                ? "Choose pages"
                : "Organize pages",
            detail:
                startInSelectionMode
                    ? "Choose the pages to extract into a separate PDF."
                    : "Move, rotate, trim, or remove pages in the private copy.",
            symbol: "square.grid.2x2",
            tint: PPColor.accent,
            metrics: [
                WorkflowMetric(
                    value: "\(record.profile.pageCount)",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: "\(selectedIndices.count)",
                    label: "Selected",
                    symbol: "checkmark.circle",
                    tint: selectedIndices.isEmpty
                        ? PPColor.textSecondary
                        : PPColor.mint
                ),
                WorkflowMetric(
                    value: model.canUndoPageChange(recordID: recordID)
                        ? "Ready"
                        : "Clean",
                    label: "Undo",
                    symbol: "arrow.uturn.backward",
                    tint: model.canUndoPageChange(recordID: recordID)
                        ? PPColor.amber
                        : PPColor.textSecondary
                )
            ]
        )
    }

    private func organizerCommandDeck(
        _ record: DocumentRecord
    ) -> some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "PAGE BENCH",
                detail: "Direct actions preserve one-step recovery",
                symbol: "square.grid.3x3",
                count: record.profile.pageCount,
                tint: PPColor.cyan
            )

            LazyVGrid(
                columns: commandColumns,
                alignment: .leading,
                spacing: 0
            ) {
                organizerCommand(
                    "Prepare",
                    detail: "Inspect margins",
                    symbol: "rectangle.inset.filled",
                    tint: PPColor.cyan
                ) {
                    preparationInitialSelection = []
                    isPreparingPages = true
                }

                organizerCommand(
                    "Blank page",
                    detail: "Append at end",
                    symbol: "doc.badge.plus",
                    tint: PPColor.accent
                ) {
                    Task {
                        await model.insertBlankPage(
                            recordID: recordID,
                            after: record.profile.pageCount - 1
                        )
                    }
                }

                organizerCommand(
                    "Import pages",
                    detail: "Append another PDF",
                    symbol: "doc.on.doc",
                    tint: PPColor.rose
                ) {
                    isImportingPages = true
                }

                organizerCommand(
                    "Page numbers",
                    detail: "Number a page range",
                    symbol: "number.square",
                    tint: PPColor.cyan
                ) {
                    isPresentingPageNumbers = true
                }

                organizerCommand(
                    "Bates",
                    detail: "Assign page IDs",
                    symbol: "number.square.fill",
                    tint: PPColor.amber
                ) {
                    isPresentingBatesNumbers = true
                }

                organizerCommand(
                    "Watermark",
                    detail: "Mark a page range",
                    symbol: "textformat.alt",
                    tint: PPColor.rose
                ) {
                    isPresentingWatermark = true
                }

                organizerCommand(
                    "Rules",
                    detail: "Select or arrange",
                    symbol: "line.3.horizontal.decrease",
                    tint: PPColor.mint
                ) {
                    isPresentingRuleWorkbench = true
                }

                organizerCommand(
                    "Undo",
                    detail: model.canUndoPageChange(recordID: recordID)
                        ? "Restore last layout"
                        : "No pending change",
                    symbol: "arrow.uturn.backward",
                    tint: PPColor.amber,
                    disabled:
                        !model.canUndoPageChange(recordID: recordID)
                ) {
                    Task {
                        _ = await model.undoLastPageChange(
                            recordID: recordID
                        )
                    }
                }
            }
        }
    }

    private var pageColumns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: dynamicTypeSize.isAccessibilitySize
                        ? 260
                        : 168,
                    maximum: 244
                ),
                spacing: PPSpacing.small,
                alignment: .top
            )
        ]
    }

    private var commandColumns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: dynamicTypeSize.isAccessibilitySize
                        ? 240
                        : 132,
                    maximum: 220
                ),
                spacing: 0
            )
        ]
    }

    private func organizerCommand(
        _ title: String,
        detail: String,
        symbol: String,
        tint: Color,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(
                        disabled
                            ? PPColor.textSecondary
                            : tint
                    )
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    Text(detail.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 46)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(
                        disabled
                            ? PPColor.border
                            : tint.opacity(0.72)
                    )
                    .frame(width: 2)
                    .padding(.vertical, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled || model.isProcessing(recordID))
    }

    private func pageRow(
        index: Int,
        pageCount: Int,
        url: URL
    ) -> some View {
        let selected = selectedIndices.contains(index)

        return VStack(spacing: 0) {
            Button {
                if isSelecting {
                    toggleSelection(index)
                } else {
                    withAnimation(
                        reduceMotion
                            ? nil
                            : .snappy(duration: 0.18)
                    ) {
                        isSelecting = true
                        selectedIndices = [index]
                    }
                }
            } label: {
                ZStack(alignment: .topLeading) {
                    PDFPageThumbnailView(
                        url: url,
                        pageIndex: index,
                        refreshToken: model.refreshToken(for: recordID),
                        width: 112
                    )
                    .shadow(
                        color: .black.opacity(0.12),
                        radius: 5,
                        y: 3
                    )

                    Text(String(format: "%03d", index + 1))
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(
                            selected ? Color.white : PPColor.textPrimary
                        )
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .background(
                            selected
                                ? PPColor.accent
                                : PPColor.elevated.opacity(0.92)
                        )
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(
                                    selected
                                        ? Color.white.opacity(0.7)
                                        : PPColor.accent.opacity(0.56)
                                )
                                .frame(height: 1)
                        }
                        .offset(x: -8, y: -5)

                    if isSelecting {
                        Image(
                            systemName: selected
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            selected
                                ? PPColor.accent
                                : PPColor.textSecondary
                        )
                        .background(Circle().fill(PPColor.elevated))
                        .offset(x: 96, y: -5)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, PPSpacing.medium)
                .padding(.bottom, PPSpacing.small)
                .overlay {
                    StudioStageMarks(
                        tint: selected
                            ? PPColor.accent
                            : PPColor.textSecondary,
                        inset: 5,
                        arm: 8
                    )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isSelecting
                    ? (
                        selected
                            ? "Deselect page \(index + 1)"
                            : "Select page \(index + 1)"
                    )
                    : "Select page \(index + 1)"
            )

            if !isSelecting {
                HStack(spacing: 0) {
                    tileAction(
                        "Rotate clockwise",
                        symbol: "rotate.right",
                        tint: PPColor.accent
                    ) {
                        Task {
                            await model.rotatePage(
                                recordID: recordID,
                                index: index
                            )
                        }
                    }
                    tileAction(
                        "Crop page",
                        symbol: "crop",
                        tint: PPColor.cyan
                    ) {
                        cropPageIndex = index
                    }
                    pageActionMenu(
                        index: index,
                        pageCount: pageCount
                    )
                }
            }
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(
                    selected
                        ? PPColor.accent
                        : PPColor.border.opacity(0.72)
                )
                .frame(width: selected ? 2 : 0.6)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
        .contextMenu {
            Button {
                Task {
                    await model.duplicatePage(
                        recordID: recordID,
                        index: index
                    )
                }
            } label: {
                Label(
                    "Duplicate Page",
                    systemImage: "plus.square.on.square"
                )
            }

            Button {
                Task {
                    await model.rotatePage(
                        recordID: recordID,
                        index: index,
                        direction: .counterclockwise
                    )
                }
            } label: {
                Label(
                    "Rotate Counterclockwise",
                    systemImage: "rotate.left"
                )
            }

            Button {
                Task {
                    await model.insertBlankPage(
                        recordID: recordID,
                        at: index
                    )
                }
            } label: {
                Label(
                    "Insert Blank Before",
                    systemImage: "doc.badge.plus"
                )
            }

            Button {
                Task {
                    await model.insertBlankPage(
                        recordID: recordID,
                        after: index
                    )
                }
            } label: {
                Label("Insert Blank After", systemImage: "doc.badge.plus")
            }

            Button {
                cropPageIndex = index
            } label: {
                Label("Crop Page", systemImage: "crop")
            }

            if model.documents.contains(where: {
                $0.id != recordID && !$0.profile.isLocked
            }) {
                Button {
                    replacementTargetIndex = index
                } label: {
                    Label(
                        "Replace from PDF",
                        systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard"
                    )
                }
            }
        }
        .disabled(model.isProcessing(recordID))
        .draggable(pageDragIdentifier(index))
        .dropDestination(for: String.self) { items, _ in
            guard !isSelecting,
                  !model.isProcessing(recordID),
                  let item = items.first,
                  let sourceIndex = pageIndex(from: item),
                  sourceIndex != index
            else { return false }
            Task {
                await model.movePage(
                    recordID: recordID,
                    from: sourceIndex,
                    to: index
                )
            }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityHint("Drag to reorder this page")
    }

    private func tileAction(
        _ label: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isProcessing(recordID))
        .accessibilityLabel(label.localizedUI)
    }

    private func pageActionMenu(
        index: Int,
        pageCount: Int
    ) -> some View {
        Menu {
            Button {
                Task {
                    await model.movePage(
                        recordID: recordID,
                        index: index,
                        direction: .earlier
                    )
                }
            } label: {
                Label("Move earlier", systemImage: "arrow.left")
            }
            .disabled(index == 0)

            Button {
                Task {
                    await model.movePage(
                        recordID: recordID,
                        index: index,
                        direction: .later
                    )
                }
            } label: {
                Label("Move later", systemImage: "arrow.right")
            }
            .disabled(index == pageCount - 1)

            Button {
                Task {
                    await model.movePage(
                        recordID: recordID,
                        from: index,
                        to: 0
                    )
                }
            } label: {
                Label(
                    "Move to Beginning",
                    systemImage: "arrow.left.to.line"
                )
            }
            .disabled(index == 0)

            Button {
                Task {
                    await model.movePage(
                        recordID: recordID,
                        from: index,
                        to: pageCount - 1
                    )
                }
            } label: {
                Label(
                    "Move to End",
                    systemImage: "arrow.right.to.line"
                )
            }
            .disabled(index == pageCount - 1)

            Divider()

            Button {
                Task {
                    await model.rotatePage(
                        recordID: recordID,
                        index: index,
                        direction: .counterclockwise
                    )
                }
            } label: {
                Label(
                    "Rotate Counterclockwise",
                    systemImage: "rotate.left"
                )
            }

            Button {
                Task {
                    await model.duplicatePage(
                        recordID: recordID,
                        index: index
                    )
                }
            } label: {
                Label(
                    "Duplicate Page",
                    systemImage: "plus.square.on.square"
                )
            }

            Divider()

            Button {
                Task {
                    await model.insertBlankPage(
                        recordID: recordID,
                        at: index
                    )
                }
            } label: {
                Label(
                    "Insert Blank Before",
                    systemImage: "doc.badge.plus"
                )
            }

            Button {
                Task {
                    await model.insertBlankPage(
                        recordID: recordID,
                        after: index
                    )
                }
            } label: {
                Label(
                    "Insert Blank After",
                    systemImage: "doc.badge.plus"
                )
            }

            if model.documents.contains(where: {
                $0.id != recordID && !$0.profile.isLocked
            }) {
                Button {
                    replacementTargetIndex = index
                } label: {
                    Label(
                        "Replace from PDF",
                        systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard"
                    )
                }
            }

            Divider()

            Button(role: .destructive) {
                pendingDeleteIndex = index
            } label: {
                Label("Remove Page", systemImage: "trash")
            }
            .disabled(pageCount == 1)
        } label: {
            Image(systemName: "ellipsis")
                .font(.caption.weight(.bold))
                .foregroundStyle(PPColor.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isProcessing(recordID))
        .accessibilityLabel("More page actions")
    }

    private var extractionBar: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: PPSpacing.medium))
            : AnyLayout(HStackLayout(spacing: PPSpacing.medium))

        return layout {
            Menu {
                if let record = model.record(id: recordID) {
                    Button("All Pages") {
                        selectedIndices = Set(
                            0..<record.profile.pageCount
                        )
                    }
                    .keyboardShortcut("a", modifiers: .command)
                    Button("Odd Pages") {
                        selectedIndices = Set(
                            (0..<record.profile.pageCount).filter {
                                $0.isMultiple(of: 2)
                            }
                        )
                    }
                    Button("Even Pages") {
                        selectedIndices = Set(
                            (0..<record.profile.pageCount).filter {
                                !$0.isMultiple(of: 2)
                            }
                        )
                    }
                    Button("Page Range…") {
                        isSelectingRange = true
                    }
                    Button("Rule Workbench…") {
                        isPresentingRuleWorkbench = true
                    }
                    Button("Invert Selection") {
                        selectedIndices = Set(
                            0..<record.profile.pageCount
                        ).subtracting(selectedIndices)
                    }
                    if !selectedIndices.isEmpty {
                        Divider()
                        Button("Clear Selection") {
                            selectedIndices.removeAll()
                        }
                    }
                }
            } label: {
                Label(
                    selectedIndices.isEmpty
                        ? "Select".localizedUI
                        : pageSelectionTitle,
                    systemImage: "checklist"
                )
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.textPrimary))
            .accessibilityIdentifier("pageSelectionMenu")
            .accessibilityLabel("Page selection")
            .accessibilityValue(
                AppLocalization.format(
                    "%lld pages selected",
                    selectedIndices.count
                )
            )

            Menu {
                if hasCopyDestination {
                    Button {
                        isChoosingDestination = true
                    } label: {
                        Label(
                            "Copy to Document",
                            systemImage: "doc.on.doc"
                        )
                    }
                }

                Button {
                    let indices = selectedIndices
                    Task {
                        if await model.duplicatePages(
                            recordID: recordID,
                            indices: indices
                        ) {
                            selectedIndices = duplicatedPageIndices(
                                for: indices
                            )
                        }
                    }
                } label: {
                    Label(
                        "Duplicate Pages",
                        systemImage: "plus.square.on.square"
                    )
                }
                .keyboardShortcut("d", modifiers: .command)

                Button {
                    let indices = selectedIndices
                    Task {
                        _ = await model.rotatePages(
                            recordID: recordID,
                            indices: indices
                        )
                    }
                } label: {
                    Label(
                        "Rotate Clockwise",
                        systemImage: "rotate.right"
                    )
                }

                Button {
                    let indices = selectedIndices
                    Task {
                        _ = await model.rotatePages(
                            recordID: recordID,
                            indices: indices,
                            direction: .counterclockwise
                        )
                    }
                } label: {
                    Label(
                        "Rotate Counterclockwise",
                        systemImage: "rotate.left"
                    )
                }

                Button {
                    preparationInitialSelection = selectedIndices
                    isPreparingPages = true
                } label: {
                    Label(
                        "Prepare Selected Pages",
                        systemImage: "rectangle.inset.filled"
                    )
                }
                Button(role: .destructive) {
                    isConfirmingBulkDelete = true
                } label: {
                    Label("Remove Pages", systemImage: "trash")
                }
                .disabled(
                    selectedIndices.count
                        >= (model.record(id: recordID)?
                            .profile.pageCount ?? 0)
                )
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .buttonStyle(PPQuietButtonStyle(tint: PPColor.textPrimary))
            .accessibilityIdentifier("pageSelectionActions")
            .disabled(
                selectedIndices.isEmpty
                    || model.isProcessing(recordID)
            )

            Button {
                Task {
                    if let created = await model.extractPages(
                        recordID: recordID,
                        indices: selectedIndices
                    ) {
                        isSelecting = false
                        selectedIndices.removeAll()
                        dismiss()
                        try? await Task.sleep(for: .milliseconds(220))
                        onCreated(DocumentRoute(recordID: created.id))
                    }
                }
            } label: {
                Label(
                    selectedIndices.isEmpty
                        ? "Choose Pages"
                        : "Extract \(selectedIndices.count)",
                    systemImage: "doc.on.doc"
                )
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(selectedIndices.isEmpty || model.isProcessing(recordID))
            .accessibilityIdentifier("extractPagesButton")
        }
        .padding(PPSpacing.regular)
        .background(PPColor.canvas.opacity(0.98))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.7))
                .frame(height: 0.6)
        }
    }

    private func toggleSelection(_ index: Int) {
        if selectedIndices.contains(index) {
            selectedIndices.remove(index)
        } else {
            selectedIndices.insert(index)
        }
    }

    private var hasCopyDestination: Bool {
        model.documents.contains {
            $0.id != recordID
                && $0.isWorkingCopy
                && !$0.profile.isLocked
        }
    }

    private var pageSelectionTitle: String {
        AppLocalization.format(
            "%lld of %lld pages selected",
            selectedIndices.count,
            model.record(id: recordID)?.profile.pageCount
                ?? selectedIndices.count
        )
    }

    private func duplicatedPageIndices(
        for sourceIndices: Set<Int>
    ) -> Set<Int> {
        let sorted = sourceIndices.sorted()
        return Set(
            sorted.enumerated().map { offset, sourceIndex in
                sourceIndex + offset + 1
            }
        )
    }

    private func pageDragIdentifier(_ index: Int) -> String {
        "paperpath-page-\(index)"
    }

    private func pageIndex(from identifier: String) -> Int? {
        guard identifier.hasPrefix("paperpath-page-") else { return nil }
        return Int(identifier.dropFirst("paperpath-page-".count))
    }
}

private struct ReplacementScanReviewSession:
    Identifiable,
    @unchecked Sendable {
    let id = UUID()
    let images: [UIImage]
    let initialOptions: ScanProcessingOptions
    let displayName: String
}

private struct PageReplacementSheet: View {
    private enum SourceMode:
        String,
        CaseIterable,
        Identifiable {
        case library
        case files
        case photos
        case camera

        var id: String { rawValue }
        var title: String {
            switch self {
            case .library: return "Library"
            case .files: return "Files"
            case .photos: return "Photos"
            case .camera: return "Camera"
            }
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let destinationRecordID: UUID
    let destinationPageIndex: Int
    let onComplete: () -> Void

    @State private var sourceRecordID: UUID?
    @State private var sourcePageIndex = 0
    @State private var isReplacing = false
    @State private var sourceMode = SourceMode.library
    @State private var isImportingExternalSource = false
    @State private var isPreparingExternalSource = false
    @State private var externalSource: PDFExternalPageSource?
    @State private var sourceAssessment:
        PDFPagePreparationAssessment?
    @State private var destinationAssessment:
        PDFPagePreparationAssessment?
    @State private var externalPreparationTask:
        Task<Void, Never>?
    @State private var photoItem: PhotosPickerItem?
    @State private var isPresentingScanner = false
    @State private var replacementScanReview:
        ReplacementScanReviewSession?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.medium
                    ) {
                        replacementHeader
                        sourceDocumentPicker
                        if effectiveSourceURL != nil {
                            replacementComparison
                        }
                        if let geometryNotice {
                            geometryNoticeView(geometryNotice)
                        }
                        sourcePageGrid
                    }
                    .frame(maxWidth: 920)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }

                replaceCommand
            }
            .background(PPColor.canvas)
            .navigationTitle("Replace page".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".localizedUI) {
                        dismiss()
                    }
                    .disabled(isReplacing)
                }
            }
        }
        .onAppear {
            if sourceRecordID == nil {
                sourceRecordID = candidates.first?.id
                if candidates.isEmpty {
                    sourceMode = .files
                }
            }
        }
        .task {
            destinationAssessment =
                await model.pagePreparationAssessment(
                    recordID: destinationRecordID
                )
        }
        .task(id: sourceRecordID) {
            guard sourceMode == .library,
                  let sourceRecordID
            else { return }
            sourceAssessment =
                await model.pagePreparationAssessment(
                    recordID: sourceRecordID
                )
        }
        .fileImporter(
            isPresented: $isImportingExternalSource,
            allowedContentTypes: [.pdf]
        ) { result in
            guard case .success(let url) = result else {
                if case .failure(let error) = result {
                    model.present(error)
                }
                return
            }
            prepareExternalSource(url)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            preparePhotoSource(item)
        }
        .fullScreenCover(isPresented: $isPresentingScanner) {
            DocumentScannerView(
                onComplete: { images in
                    isPresentingScanner = false
                    DispatchQueue.main.async {
                        replacementScanReview =
                            ReplacementScanReviewSession(
                                images: images,
                                initialOptions: .document,
                                displayName:
                                    "Reviewed Camera Scan".localizedUI
                            )
                    }
                },
                onCancel: {
                    isPresentingScanner = false
                },
                onError: { error in
                    isPresentingScanner = false
                    model.present(error)
                }
            )
            .ignoresSafeArea()
        }
        .sheet(item: $replacementScanReview) { session in
            ScanReviewView(
                images: session.images,
                initialOptions: session.initialOptions,
                purpose: .replacePage
            ) { pages in
                replacementScanReview = nil
                prepareImageSource(
                    pages,
                    displayName: session.displayName
                )
            }
        }
        .onDisappear {
            externalPreparationTask?.cancel()
            externalPreparationTask = nil
            replacementScanReview = nil
            if let externalSource {
                model.discardExternalPageSource(externalSource)
            }
        }
        .interactiveDismissDisabled(isReplacing)
    }

    private var candidates: [DocumentRecord] {
        model.documents
            .filter {
                $0.id != destinationRecordID
                    && !$0.profile.isLocked
            }
            .sorted {
                ($0.lastViewedAt ?? $0.modifiedAt)
                    > ($1.lastViewedAt ?? $1.modifiedAt)
            }
    }

    private var sourceRecord: DocumentRecord? {
        guard let sourceRecordID else { return nil }
        return model.record(id: sourceRecordID)
    }

    private var effectiveSourceURL: URL? {
        switch sourceMode {
        case .library:
            guard let sourceRecord else { return nil }
            return model.url(for: sourceRecord.id)
        case .files, .photos, .camera:
            return externalSource?.url
        }
    }

    private var effectivePageCount: Int {
        switch sourceMode {
        case .library:
            return sourceRecord?.profile.pageCount ?? 0
        case .files, .photos, .camera:
            return externalSource?.pageCount ?? 0
        }
    }

    private var effectiveSourceAssessment:
        PDFPagePreparationAssessment? {
        switch sourceMode {
        case .library: return sourceAssessment
        case .files, .photos, .camera:
            return externalSource?.assessment
        }
    }

    private var replacementHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "ATOMIC REPLACEMENT",
            title: AppLocalization.format(
                "Replace page %lld",
                destinationPageIndex + 1
            ),
            detail:
                "Choose one source page. The page count and target position stay unchanged.",
            symbol: "arrow.triangle.2.circlepath.doc.on.clipboard",
            tint: PPColor.rose,
            metrics: [
                WorkflowMetric(
                    value: "\(destinationPageIndex + 1)",
                    label: "Target",
                    symbol: "scope",
                    tint: PPColor.rose
                ),
                WorkflowMetric(
                    value: effectivePageCount > 0
                        ? "\(effectivePageCount)"
                        : "—",
                    label: "Source pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value: "\(sourcePageIndex + 1)",
                    label: "Chosen",
                    symbol: "checkmark.circle",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "Ready",
                    label: "Undo",
                    symbol: "arrow.uturn.backward",
                    tint: PPColor.amber
                )
            ]
        )
    }

    private var sourceDocumentPicker: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "SOURCE PDF",
                detail: sourceMode == .library
                    ? "Unlocked private copies"
                    : "Temporary protected source",
                symbol: "doc.on.doc",
                count: sourceMode == .library
                    ? candidates.count
                    : externalSource.map { _ in 1 } ?? 0,
                tint: PPColor.cyan
            )

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        sourceModeControl
                            .frame(maxWidth: .infinity)
                        sourceSelectionControl
                    }
                } else {
                    HStack(
                        alignment: .center,
                        spacing: PPSpacing.medium
                    ) {
                        sourceModeControl
                        sourceSelectionControl
                    }
                }
            }
            .onChange(of: sourceRecordID) { _, _ in
                sourcePageIndex = 0
                sourceAssessment = nil
            }
            .onChange(of: sourceMode) { _, _ in
                externalPreparationTask?.cancel()
                externalPreparationTask = nil
                discardPreparedSource()
                isPreparingExternalSource = false
                if sourceMode != .photos {
                    photoItem = nil
                }
                sourcePageIndex = 0
            }
        }
    }

    private var sourceSelectionControl: some View {
        HStack(spacing: PPSpacing.small) {
            switch sourceMode {
            case .library:
                Picker(
                    "Source PDF",
                    selection: $sourceRecordID
                ) {
                    ForEach(candidates) { record in
                        Text(record.displayName)
                            .tag(Optional(record.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .files:
                Button {
                    isImportingExternalSource = true
                } label: {
                    Label(
                        externalSource == nil
                            ? "Choose PDF"
                            : "Choose Another",
                        systemImage: "folder"
                    )
                }
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.cyan)
                )
                .disabled(isPreparingExternalSource)
                Spacer(minLength: 0)
                if isPreparingExternalSource {
                    ProgressView()
                        .controlSize(.small)
                } else if let externalSource {
                    sourceSummary(externalSource)
                }
            case .photos:
                PhotosPicker(
                    selection: $photoItem,
                    matching: .images
                ) {
                    Label(
                        externalSource == nil
                            ? "Choose Photo"
                            : "Choose Another",
                        systemImage: "photo"
                    )
                }
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.cyan)
                )
                .disabled(isPreparingExternalSource)
                Spacer(minLength: 0)
                sourcePreparationStatus
            case .camera:
                Button {
                    beginReplacementScan()
                } label: {
                    Label(
                        externalSource == nil
                            ? "Scan Page"
                            : "Scan Again",
                        systemImage: "viewfinder"
                    )
                }
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.cyan)
                )
                .disabled(isPreparingExternalSource)
                Spacer(minLength: 0)
                sourcePreparationStatus
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceSummary(
        _ source: PDFExternalPageSource
    ) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(source.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
            Text(
                "\(source.pageCount) pages · \(source.formattedSize)"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(PPColor.textSecondary)
        }
    }

    private var sourceModeControl: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Menu {
                    ForEach(SourceMode.allCases) { mode in
                        Button {
                            sourceMode = mode
                        } label: {
                            Label(
                                mode.title.localizedUI,
                                systemImage: sourceMode == mode
                                    ? "checkmark"
                                    : sourceModeSymbol(mode)
                            )
                        }
                    }
                } label: {
                    HStack(spacing: PPSpacing.small) {
                        Label(
                            sourceMode.title.localizedUI,
                            systemImage: sourceModeSymbol(sourceMode)
                        )
                        Spacer(minLength: PPSpacing.small)
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, PPSpacing.small)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Picker("Source location", selection: $sourceMode) {
                    ForEach(SourceMode.allCases) { mode in
                        Text(mode.title.localizedUI).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .frame(
            maxWidth: dynamicTypeSize.isAccessibilitySize
                ? .infinity
                : 260
        )
        .accessibilityIdentifier("replacementSourceMode")
    }

    private func sourceModeSymbol(
        _ mode: SourceMode
    ) -> String {
        switch mode {
        case .library: return "books.vertical"
        case .files: return "folder"
        case .photos: return "photo"
        case .camera: return "viewfinder"
        }
    }

    @ViewBuilder
    private var replacementComparison: some View {
        if let destinationURL = model.url(
            for: destinationRecordID
        ),
           let sourceURL = effectiveSourceURL,
           effectivePageCount > 0 {
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                StudioSectionRule(
                    title: "REPLACEMENT PREVIEW",
                    detail: "Current page → selected source",
                    symbol: "rectangle.split.2x1",
                    tint: PPColor.rose
                )

                ViewThatFits(in: .horizontal) {
                    HStack(
                        alignment: .center,
                        spacing: PPSpacing.medium
                    ) {
                        replacementPreview(
                            url: destinationURL,
                            pageIndex: destinationPageIndex,
                            label: "CURRENT",
                            tint: PPColor.rose,
                            refreshToken: model.refreshToken(
                                for: destinationRecordID
                            )
                        )
                        replacementArrow(horizontal: true)
                        replacementPreview(
                            url: sourceURL,
                            pageIndex: sourcePageIndex,
                            label: "REPLACEMENT",
                            tint: PPColor.mint,
                            refreshToken:
                                sourceMode == .library
                                    ? sourceRecordID.map {
                                        model.refreshToken(for: $0)
                                    } ?? 0
                                    : 0
                        )
                    }

                    VStack(
                        alignment: .leading,
                        spacing: PPSpacing.small
                    ) {
                        replacementPreview(
                            url: destinationURL,
                            pageIndex: destinationPageIndex,
                            label: "CURRENT",
                            tint: PPColor.rose,
                            refreshToken: model.refreshToken(
                                for: destinationRecordID
                            )
                        )
                        replacementArrow(horizontal: false)
                        replacementPreview(
                            url: sourceURL,
                            pageIndex: sourcePageIndex,
                            label: "REPLACEMENT",
                            tint: PPColor.mint,
                            refreshToken:
                                sourceMode == .library
                                    ? sourceRecordID.map {
                                        model.refreshToken(for: $0)
                                    } ?? 0
                                    : 0
                        )
                    }
                }
            }
        }
    }

    private func replacementPreview(
        url: URL,
        pageIndex: Int,
        label: String,
        tint: Color,
        refreshToken: Int
    ) -> some View {
        HStack(spacing: PPSpacing.medium) {
            PDFPageThumbnailView(
                url: url,
                pageIndex: pageIndex,
                refreshToken: refreshToken,
                width: 78
            )
            .shadow(
                color: .black.opacity(0.1),
                radius: 4,
                y: 2
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(label.localizedUI)
                    .font(.caption2.smallCaps().weight(.bold))
                    .foregroundStyle(tint)
                Text(
                    AppLocalization.format(
                        "Page %lld",
                        pageIndex + 1
                    )
                )
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(PPColor.textPrimary)
                Text(
                    (
                        label == "CURRENT"
                        ? "Will be replaced"
                        : "Will become the new page"
                    ).localizedUI
                )
                .font(.caption)
                .foregroundStyle(PPColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, PPSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint.opacity(0.76))
                .frame(width: 2)
        }
        .accessibilityElement(children: .combine)
    }

    private func replacementArrow(
        horizontal: Bool
    ) -> some View {
        Image(
            systemName: horizontal
                ? "arrow.right"
                : "arrow.down"
        )
        .font(.caption.weight(.bold))
        .foregroundStyle(PPColor.textSecondary)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var sourcePageGrid: some View {
        if let sourceURL = effectiveSourceURL,
           effectivePageCount > 0 {
            VStack(alignment: .leading, spacing: PPSpacing.small) {
                StudioSectionRule(
                    title: "SOURCE PAGE",
                    detail: "Preview before replacing",
                    symbol: "rectangle.stack",
                    count: effectivePageCount,
                    tint: PPColor.mint
                )

                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(
                                minimum: horizontalSizeClass == .regular
                                    ? 112
                                    : 92,
                                maximum: 148
                            ),
                            spacing: PPSpacing.small
                        )
                    ],
                    spacing: PPSpacing.small
                ) {
                    ForEach(
                        0..<effectivePageCount,
                        id: \.self
                    ) { index in
                        Button {
                            sourcePageIndex = index
                        } label: {
                            VStack(spacing: 5) {
                                PDFPageThumbnailView(
                                    url: sourceURL,
                                    pageIndex: index,
                                    refreshToken:
                                        sourceMode == .library
                                        ? sourceRecordID.map {
                                            model.refreshToken(for: $0)
                                        } ?? 0
                                        : 0,
                                    width: 82
                                )
                                .shadow(
                                    color: .black.opacity(0.1),
                                    radius: 4,
                                    y: 2
                                )
                                Text(
                                    AppLocalization.format(
                                        "Page %lld",
                                        index + 1
                                    )
                                )
                                .font(
                                    .caption2
                                        .monospacedDigit()
                                        .weight(.semibold)
                                )
                                .foregroundStyle(
                                    index == sourcePageIndex
                                        ? PPColor.mint
                                        : PPColor.textSecondary
                                )
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, PPSpacing.small)
                            .background(
                                index == sourcePageIndex
                                    ? PPColor.mint.opacity(0.055)
                                    : PPColor.surface.opacity(0.55)
                            )
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(
                                        index == sourcePageIndex
                                            ? PPColor.mint
                                            : PPColor.border
                                    )
                                    .frame(
                                        width: index == sourcePageIndex
                                            ? 2
                                            : 0.6
                                    )
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            PPEmptyState(
                kind: .workspace,
                title: "No source PDF",
                message: sourceMode == .library
                    ? "Import another unlocked PDF before replacing this page."
                    : sourceMode == .files
                        ? "Choose a PDF from Files. It stays temporary and is removed after replacement."
                        : sourceMode == .photos
                            ? "Choose a photo. It becomes one temporary protected PDF page."
                            : "Scan one or more paper pages, then choose the replacement page."
            )
        }
    }

    private struct GeometryNotice {
        let title: String
        let detail: String
        let tint: Color
        let symbol: String
    }

    private var geometryNotice: GeometryNotice? {
        guard let destination = destinationAssessment?.pages.first(
            where: {
                $0.pageIndex == destinationPageIndex
            }
        ),
              let source = effectiveSourceAssessment?.pages.first(
                where: {
                    $0.pageIndex == sourcePageIndex
                }
              )
        else { return nil }
        let widthDelta = abs(
            destination.widthPoints - source.widthPoints
        ) / max(destination.widthPoints, source.widthPoints)
        let heightDelta = abs(
            destination.heightPoints - source.heightPoints
        ) / max(destination.heightPoints, source.heightPoints)
        let orientationChanged =
            destination.isLandscape != source.isLandscape
        if orientationChanged || max(widthDelta, heightDelta) > 0.08 {
            return GeometryNotice(
                title: "Page geometry changes",
                detail:
                    "\(destination.pointSizeLabel) → \(source.pointSizeLabel) · \(source.orientationTitle.localizedUI)",
                tint: PPColor.amber,
                symbol: "aspectratio"
            )
        }
        return GeometryNotice(
            title: "Page geometry aligned",
            detail:
                "\(source.paperClass.title) · \(source.pointSizeLabel)",
            tint: PPColor.mint,
            symbol: "checkmark.rectangle"
        )
    }

    private func geometryNoticeView(
        _ notice: GeometryNotice
    ) -> some View {
        HStack(spacing: PPSpacing.small) {
            Image(systemName: notice.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(notice.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(notice.title.localizedUI)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                Text(notice.detail.localizedUI)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
            }
            Spacer(minLength: 0)
            Text("PREVIEWED".localizedUI)
                .font(.caption2.smallCaps().weight(.bold))
                .foregroundStyle(notice.tint)
        }
        .padding(.horizontal, PPSpacing.small)
        .frame(minHeight: 46)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(notice.tint.opacity(0.72))
                .frame(width: 2)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.56))
                .frame(height: 0.6)
        }
    }

    private var replaceCommand: some View {
        Button {
            isReplacing = true
            Task {
                let succeeded: Bool
                switch sourceMode {
                case .library:
                    guard let sourceRecordID else {
                        isReplacing = false
                        return
                    }
                    succeeded = await model.replacePage(
                        recordID: destinationRecordID,
                        index: destinationPageIndex,
                        from: sourceRecordID,
                        sourceIndex: sourcePageIndex
                    )
                case .files, .photos, .camera:
                    guard let externalSource else {
                        isReplacing = false
                        return
                    }
                    succeeded = await model.replacePage(
                        recordID: destinationRecordID,
                        index: destinationPageIndex,
                        from: externalSource,
                        sourceIndex: sourcePageIndex
                    )
                }
                isReplacing = false
                guard succeeded else { return }
                dismiss()
                onComplete()
            }
        } label: {
            Label(
                isReplacing
                    ? "Replacing page"
                    : AppLocalization.format(
                        "Replace with page %lld",
                        sourcePageIndex + 1
                    ),
                systemImage: isReplacing
                    ? "hourglass"
                    : "arrow.triangle.2.circlepath"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PPPrimaryButtonStyle())
        .disabled(
            effectiveSourceURL == nil
                || isReplacing
                || isPreparingExternalSource
        )
        .padding(PPSpacing.regular)
        .background(.bar)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private func prepareExternalSource(_ url: URL) {
        externalPreparationTask?.cancel()
        isPreparingExternalSource = true
        discardPreparedSource()
        externalPreparationTask = Task {
            let prepared = await model.prepareExternalPageSource(
                from: url
            )
            guard !Task.isCancelled else {
                if let prepared {
                    model.discardExternalPageSource(prepared)
                }
                return
            }
            externalSource = prepared
            sourcePageIndex = 0
            isPreparingExternalSource = false
            externalPreparationTask = nil
        }
    }

    @ViewBuilder
    private var sourcePreparationStatus: some View {
        if isPreparingExternalSource {
            ProgressView()
                .controlSize(.small)
        } else if let externalSource {
            VStack(alignment: .trailing, spacing: 1) {
                Text(externalSource.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(1)
                Text(
                    "\(externalSource.pageCount) pages · \(externalSource.formattedSize)"
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PPColor.textSecondary)
            }
        }
    }

    private func preparePhotoSource(_ item: PhotosPickerItem) {
        externalPreparationTask?.cancel()
        isPreparingExternalSource = true
        discardPreparedSource()
        externalPreparationTask = Task {
            guard let data = try? await item.loadTransferable(
                type: Data.self
            ),
                  data.count <= 32 * 1_024 * 1_024,
                  let image = await Self.downsampledImage(from: data)
            else {
                guard !Task.isCancelled else { return }
                isPreparingExternalSource = false
                externalPreparationTask = nil
                photoItem = nil
                model.present(PaperPathError.unreadableImage)
                return
            }
            guard !Task.isCancelled else { return }
            isPreparingExternalSource = false
            photoItem = nil
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled,
                  sourceMode == .photos
            else { return }
            externalPreparationTask = nil
            replacementScanReview = ReplacementScanReviewSession(
                images: [image],
                initialOptions: .original,
                displayName: "Reviewed Photo Page".localizedUI
            )
        }
    }

    private func prepareImageSource(
        _ pages: [ScanPageImage],
        displayName: String
    ) {
        externalPreparationTask?.cancel()
        isPreparingExternalSource = true
        discardPreparedSource()
        externalPreparationTask = Task {
            let prepared = await model.prepareImagePageSource(
                pages: pages,
                displayName: displayName
            )
            guard !Task.isCancelled else {
                if let prepared {
                    model.discardExternalPageSource(prepared)
                }
                return
            }
            externalSource = prepared
            sourcePageIndex = 0
            isPreparingExternalSource = false
            externalPreparationTask = nil
        }
    }

    private func discardPreparedSource() {
        if let externalSource {
            model.discardExternalPageSource(externalSource)
            self.externalSource = nil
        }
    }

    private func beginReplacementScan() {
        guard VNDocumentCameraViewController.isSupported else {
            model.present(PaperPathError.cameraUnavailable)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            model.presentCameraPermissionDenied()
        case .authorized, .notDetermined:
            isPresentingScanner = true
        @unknown default:
            model.present(PaperPathError.cameraUnavailable)
        }
    }

    nonisolated private static func downsampledImage(
        from data: Data
    ) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(
                data as CFData,
                nil
            ) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_400
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }
}

private struct PageRuleWorkbench: View {
    private enum NumberRule: String, CaseIterable, Identifiable {
        case all
        case odd
        case even

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    private enum OrientationRule:
        String,
        CaseIterable,
        Identifiable {
        case any
        case portrait
        case landscape

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    private enum PaperRule: String, CaseIterable, Identifiable {
        case any
        case a4
        case letter
        case legal
        case square
        case custom

        var id: String { rawValue }
        var title: String {
            switch self {
            case .any: return "Any"
            case .a4: return "A4"
            case .letter: return "Letter"
            case .legal: return "Legal"
            case .square: return "Square"
            case .custom: return "Custom"
            }
        }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let recordID: UUID
    let currentSelection: Set<Int>
    let onSelect: (Set<Int>) -> Void
    let onReorder: ([Int], String) -> Void

    @State private var assessment: PDFPagePreparationAssessment?
    @State private var numberRule = NumberRule.all
    @State private var orientationRule = OrientationRule.any
    @State private var paperRule = PaperRule.any
    @State private var isLoading = false
    @State private var analysisTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.large
                ) {
                    ruleHeader
                    selectionRules
                    matchPreview
                    arrangementRules
                }
                .frame(maxWidth: 920)
                .padding(PPSpacing.regular)
                .frame(maxWidth: .infinity)
            }
            .background(PPColor.canvas)
            .navigationTitle("Page rules".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel".localizedUI) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Select matches".localizedUI) {
                        onSelect(matchingIndices)
                    }
                    .disabled(matchingIndices.isEmpty)
                }
            }
        }
        .onAppear {
            startAssessment()
        }
        .onDisappear {
            analysisTask?.cancel()
            analysisTask = nil
        }
    }

    private var pageCount: Int {
        model.record(id: recordID)?.profile.pageCount ?? 0
    }

    private var ruleHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "DETERMINISTIC RULES",
            title: "Select and arrange pages",
            detail:
                "Every match is visible before selection. Reordering always keeps every page.",
            symbol: "line.3.horizontal.decrease",
            tint: PPColor.mint,
            metrics: [
                WorkflowMetric(
                    value: "\(pageCount)",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: "\(matchingIndices.count)",
                    label: "Matches",
                    symbol: "scope",
                    tint: PPColor.mint
                ),
                WorkflowMetric(
                    value: "\(assessment?.geometryVariantCount ?? 0)",
                    label: "Formats",
                    symbol: "rectangle.3.group",
                    tint: PPColor.amber
                ),
                WorkflowMetric(
                    value: "\(currentSelection.count)",
                    label: "Current",
                    symbol: "checkmark.circle",
                    tint: PPColor.cyan
                )
            ]
        )
    }

    private var selectionRules: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "MATCH",
                detail: "Rules combine with AND",
                symbol: "scope",
                tint: PPColor.mint
            )

            ViewThatFits(in: .horizontal) {
                HStack(
                    alignment: .top,
                    spacing: PPSpacing.medium
                ) {
                    numberRuleControl
                    orientationRuleControl
                    paperRuleControl
                }
                VStack(
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    numberRuleControl
                    orientationRuleControl
                    paperRuleControl
                }
            }
        }
    }

    private var numberRuleControl: some View {
        ruleControl("PAGE NUMBER") {
            Picker("Page number", selection: $numberRule) {
                ForEach(NumberRule.allCases) { rule in
                    Text(rule.title.localizedUI).tag(rule)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var orientationRuleControl: some View {
        ruleControl("ORIENTATION") {
            Picker("Orientation", selection: $orientationRule) {
                ForEach(OrientationRule.allCases) { rule in
                    Text(rule.title.localizedUI).tag(rule)
                }
            }
            .pickerStyle(.segmented)
            .disabled(assessment == nil)
        }
    }

    private var paperRuleControl: some View {
        ruleControl("PAPER") {
            Picker("Paper", selection: $paperRule) {
                ForEach(PaperRule.allCases) { rule in
                    Text(rule.title.localizedUI).tag(rule)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(assessment == nil)
        }
    }

    private func ruleControl<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionEyebrow(text: title)
            content()
        }
        .frame(
            minWidth: dynamicTypeSize.isAccessibilitySize
                ? nil
                : 190,
            maxWidth: .infinity,
            alignment: .leading
        )
    }

    private var matchPreview: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "MATCH PREVIEW",
                detail: isLoading
                    ? "Reading page geometry on device"
                    : "Page numbers before any action",
                symbol: "number",
                count: matchingIndices.count,
                tint: PPColor.cyan
            )

            if isLoading {
                HStack(spacing: PPSpacing.small) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Inspecting page geometry".localizedUI)
                        .font(.caption)
                        .foregroundStyle(PPColor.textSecondary)
                }
                .frame(minHeight: 42)
            } else {
                Text(matchSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PPColor.textPrimary)
                    .lineLimit(4)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: 42,
                        alignment: .topLeading
                    )
                    .padding(.vertical, PPSpacing.small)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(PPColor.cyan.opacity(0.72))
                            .frame(width: 2)
                    }
                    .padding(.leading, PPSpacing.small)
            }
        }
    }

    private var arrangementRules: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            StudioSectionRule(
                title: "ARRANGE",
                detail: "Whole-document recoverable operations",
                symbol: "arrow.up.arrow.down",
                tint: PPColor.amber
            )

            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: 184, maximum: 280),
                        spacing: 0
                    )
                ],
                spacing: 0
            ) {
                arrangementAction(
                    "Reverse all",
                    detail: "Last page becomes first",
                    symbol: "arrow.up.arrow.down"
                ) {
                    onReorder(
                        Array((0..<pageCount).reversed()),
                        "Reverse page order".localizedUI
                    )
                }
                arrangementAction(
                    "Odd then even",
                    detail: "1, 3, 5… then 2, 4, 6…",
                    symbol: "list.number"
                ) {
                    onReorder(
                        oddIndices + evenIndices,
                        "Group odd and even pages".localizedUI
                    )
                }
                arrangementAction(
                    "Even then odd",
                    detail: "2, 4, 6… then 1, 3, 5…",
                    symbol: "list.number.rtl"
                ) {
                    onReorder(
                        evenIndices + oddIndices,
                        "Group even and odd pages".localizedUI
                    )
                }
                arrangementAction(
                    "Interleave halves",
                    detail: "Alternate first and second stacks",
                    symbol: "square.2.layers.3d"
                ) {
                    onReorder(
                        interleavedHalfOrder,
                        "Interleave page halves".localizedUI
                    )
                }
            }
        }
    }

    private func arrangementAction(
        _ title: String,
        detail: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: PPSpacing.small) {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PPColor.amber)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title.localizedUI)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PPColor.textPrimary)
                    Text(detail.localizedUI)
                        .font(.caption2)
                        .foregroundStyle(PPColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PPSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 48)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(PPColor.amber.opacity(0.72))
                    .frame(width: 2)
                    .padding(.vertical, 6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(pageCount < 2 || model.isProcessing(recordID))
    }

    private var matchingIndices: Set<Int> {
        Set((0..<pageCount).filter { index in
            guard numberMatches(index) else { return false }
            guard orientationRule != .any || paperRule != .any else {
                return true
            }
            guard let item = assessment?.pages.first(where: {
                $0.pageIndex == index
            }) else { return false }
            return orientationMatches(item) && paperMatches(item)
        })
    }

    private func numberMatches(_ index: Int) -> Bool {
        switch numberRule {
        case .all: return true
        case .odd: return index.isMultiple(of: 2)
        case .even: return !index.isMultiple(of: 2)
        }
    }

    private func orientationMatches(
        _ item: PDFPagePreparationItem
    ) -> Bool {
        switch orientationRule {
        case .any: return true
        case .portrait: return !item.isLandscape
        case .landscape: return item.isLandscape
        }
    }

    private func paperMatches(
        _ item: PDFPagePreparationItem
    ) -> Bool {
        switch paperRule {
        case .any: return true
        case .a4: return item.paperClass == .a4
        case .letter: return item.paperClass == .letter
        case .legal: return item.paperClass == .legal
        case .square: return item.paperClass == .square
        case .custom: return item.paperClass == .custom
        }
    }

    private var matchSummary: String {
        let pages = matchingIndices.sorted()
        guard !pages.isEmpty else {
            return "No pages match these rules.".localizedUI
        }
        let visible = pages.prefix(48).map {
            String($0 + 1)
        }.joined(separator: " · ")
        if pages.count > 48 {
            return visible + AppLocalization.format(
                " · +%lld more",
                pages.count - 48
            )
        }
        return visible
    }

    private var oddIndices: [Int] {
        (0..<pageCount).filter { $0.isMultiple(of: 2) }
    }

    private var evenIndices: [Int] {
        (0..<pageCount).filter { !$0.isMultiple(of: 2) }
    }

    private var interleavedHalfOrder: [Int] {
        let split = (pageCount + 1) / 2
        let first = Array(0..<split)
        let second = Array(split..<pageCount)
        var result: [Int] = []
        result.reserveCapacity(pageCount)
        for index in 0..<max(first.count, second.count) {
            if first.indices.contains(index) {
                result.append(first[index])
            }
            if second.indices.contains(index) {
                result.append(second[index])
            }
        }
        return result
    }

    private func startAssessment() {
        analysisTask?.cancel()
        isLoading = true
        analysisTask = Task {
            let loaded = await model.pagePreparationAssessment(
                recordID: recordID
            )
            guard !Task.isCancelled else { return }
            assessment = loaded
            isLoading = false
            analysisTask = nil
        }
    }
}

private struct PagePreparationView: View {
    private enum ReviewMode: String, CaseIterable, Identifiable {
        case changes
        case all

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let recordID: UUID
    let initialSelection: Set<Int>
    let onComplete: () -> Void

    @State private var assessment: PDFPagePreparationAssessment?
    @State private var selectedPages: Set<Int> = []
    @State private var reviewMode = ReviewMode.changes
    @State private var safetyPadding = 0.02
    @State private var analysisTask: Task<Void, Never>?
    @State private var applyTask: Task<Void, Never>?
    @State private var assessmentGeneration = 0
    @State private var selectionFeedback = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: PPSpacing.medium) {
                        preparationHeader
                        preparationControls
                        pageEvidence
                    }
                    .frame(maxWidth: 1_080)
                    .padding(PPSpacing.regular)
                    .frame(maxWidth: .infinity)
                }

                bottomCommand
            }
            .background(PPColor.canvas)
            .navigationTitle("Prepare Pages".localizedUI)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(
                        (
                            isBusy
                                ? "Stop"
                                : "Cancel"
                        ).localizedUI
                    ) {
                        if isBusy {
                            stopWork()
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rescan".localizedUI) {
                        startAssessment()
                    }
                    .disabled(isBusy)
                }
            }
        }
        .onAppear {
            startAssessment()
        }
        .onDisappear {
            analysisTask?.cancel()
            applyTask?.cancel()
            analysisTask = nil
            applyTask = nil
        }
        .sensoryFeedback(
            .selection,
            trigger: selectionFeedback
        )
    }

    private var preparationHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "PAGE PREPARATION",
            title: "Review detected margins",
            detail:
                "Local page evidence stays visible before one recoverable batch update.",
            symbol: "rectangle.inset.filled",
            tint: PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(assessment?.pages.count ?? 0)",
                    label: "Pages",
                    symbol: "doc.on.doc",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: "\(suggestedPages.count)",
                    label: "Suggested",
                    symbol: "crop",
                    tint: suggestedPages.isEmpty
                        ? PPColor.textSecondary
                        : PPColor.cyan
                ),
                WorkflowMetric(
                    value:
                        "\(assessment?.geometryVariantCount ?? 0)",
                    label: "Formats",
                    symbol: "rectangle.3.group",
                    tint: PPColor.amber
                ),
                WorkflowMetric(
                    value: "\(effectiveSelection.count)",
                    label: "Selected",
                    symbol: "checkmark.circle",
                    tint: effectiveSelection.isEmpty
                        ? PPColor.textSecondary
                        : PPColor.mint
                )
            ]
        )
    }

    private var preparationControls: some View {
        VStack(alignment: .leading, spacing: PPSpacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: PPSpacing.large) {
                    reviewModePicker
                    safetyPaddingControl
                }
                VStack(alignment: .leading, spacing: PPSpacing.small) {
                    reviewModePicker
                    safetyPaddingControl
                }
            }

            HStack(spacing: PPSpacing.medium) {
                Button {
                    selectedPages = Set(
                        suggestedPages.map(\.pageIndex)
                    )
                    selectionFeedback += 1
                } label: {
                    Label(
                        "Select Suggested",
                        systemImage: "checkmark.circle"
                    )
                }
                .buttonStyle(
                    PPQuietButtonStyle(tint: PPColor.cyan)
                )
                .disabled(suggestedPages.isEmpty || isBusy)

                Button {
                    selectedPages.removeAll()
                    selectionFeedback += 1
                } label: {
                    Label(
                        "Keep All",
                        systemImage: "rectangle"
                    )
                }
                .buttonStyle(PPQuietButtonStyle())
                .disabled(selectedPages.isEmpty || isBusy)
            }
        }
        .padding(.horizontal, PPSpacing.small)
        .padding(.vertical, PPSpacing.small)
        .background(PPColor.surface.opacity(0.62))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(PPColor.border.opacity(0.62))
                .frame(height: 0.6)
        }
    }

    private var reviewModePicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionEyebrow(text: "REVIEW")
            Picker("Review", selection: $reviewMode) {
                ForEach(ReviewMode.allCases) { mode in
                    Text(mode.title.localizedUI).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(minWidth: 220)
        }
    }

    private var safetyPaddingControl: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                SectionEyebrow(text: "SAFETY PADDING")
                Spacer()
                Text(
                    AppLocalization.format(
                        "%.1f%%",
                        safetyPadding * 100
                    )
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(PPColor.cyan)
            }
            Slider(
                value: $safetyPadding,
                in: 0.005...0.06,
                step: 0.005
            )
            .tint(PPColor.cyan)
        }
        .frame(minWidth: 220)
    }

    @ViewBuilder
    private var pageEvidence: some View {
        if assessment != nil {
            if filteredPages.isEmpty {
                PPEmptyState(
                    kind: .workspace,
                    title: "No safe margin changes",
                    message:
                        "Keep the current page boxes or review every page."
                )
                .padding(.vertical, PPSpacing.xLarge)
            } else {
                LazyVGrid(
                    columns: pageColumns,
                    alignment: .leading,
                    spacing: PPSpacing.small
                ) {
                    ForEach(filteredPages) { item in
                        preparationRow(item)
                    }
                }
            }
        } else if analysisTask != nil {
            VStack(spacing: PPSpacing.medium) {
                if let progress = model.progress(for: recordID) {
                    LocalOperationProgressView(progress: progress)
                } else {
                    ProgressView()
                    Text("Inspecting page geometry".localizedUI)
                        .font(.subheadline)
                        .foregroundStyle(PPColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, PPSpacing.xLarge)
        } else {
            PPEmptyState(
                kind: .workspace,
                title: "Page evidence unavailable",
                message: "Rescan the private working copy."
            )
            .padding(.vertical, PPSpacing.xLarge)
        }
    }

    private var pageColumns: [GridItem] {
        let count = horizontalSizeClass == .regular
            && !dynamicTypeSize.isAccessibilitySize
            ? 2
            : 1
        return Array(
            repeating: GridItem(
                .flexible(),
                spacing: PPSpacing.small
            ),
            count: count
        )
    }

    private func preparationRow(
        _ item: PDFPagePreparationItem
    ) -> some View {
        let proposed = item.proposedInsets(
            safetyPadding: safetyPadding
        )
        let isSuggested = item.isSuggested(
            safetyPadding: safetyPadding
        )
        let isSelected = selectedPages.contains(item.pageIndex)
            && isSuggested

        return Button {
            guard isSuggested, !isBusy else { return }
            if selectedPages.contains(item.pageIndex) {
                selectedPages.remove(item.pageIndex)
            } else {
                selectedPages.insert(item.pageIndex)
            }
            selectionFeedback += 1
        } label: {
            HStack(spacing: PPSpacing.medium) {
                if let url = model.url(for: recordID) {
                    PDFPageThumbnailView(
                        url: url,
                        pageIndex: item.pageIndex,
                        refreshToken: model.refreshToken(for: recordID),
                        width: 54,
                        height: 70
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: PPSpacing.small) {
                        Text("Page \(item.pageIndex + 1)")
                            .font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(PPColor.textPrimary)
                        Text(item.paperClass.title)
                            .font(.caption2.smallCaps().weight(.bold))
                            .foregroundStyle(PPColor.accent)
                    }
                    Text(
                        "\(item.pointSizeLabel) · \(item.orientationTitle.localizedUI)"
                    )
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.textSecondary)
                    .lineLimit(1)
                    HStack(spacing: PPSpacing.small) {
                        evidenceValue(
                            "\(Int(proposed.retainedArea * 100))%",
                            label: "retained"
                        )
                        evidenceValue(
                            item.confidence.title,
                            label: "confidence"
                        )
                        evidenceValue(
                            AppLocalization.format(
                                "%.1f%%",
                                item.inkCoverage * 100
                            ),
                            label: "ink"
                        )
                    }
                }

                Spacer(minLength: PPSpacing.small)

                Image(
                    systemName: isSelected
                        ? "checkmark.circle.fill"
                        : (
                            isSuggested
                                ? "circle"
                                : "minus.circle"
                        )
                )
                .font(.title3)
                .foregroundStyle(
                    isSelected
                        ? PPColor.mint
                        : (
                            isSuggested
                                ? PPColor.textSecondary
                                : PPColor.amber
                        )
                )
            }
            .padding(.horizontal, PPSpacing.small)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSuggested || isBusy)
        .background(
            isSelected
                ? PPColor.mint.opacity(0.055)
                : PPColor.surface.opacity(0.62)
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(
                    isSelected
                        ? PPColor.mint.opacity(0.48)
                        : PPColor.border.opacity(0.62)
                )
                .frame(height: isSelected ? 1 : 0.6)
        }
        .accessibilityLabel(
            AppLocalization.format(
                "Page %lld, %@, %lld percent retained",
                item.pageIndex + 1,
                item.confidence.title.localizedUI,
                Int(proposed.retainedArea * 100)
            )
        )
        .accessibilityHint(
            isSuggested
                ? (
                    isSelected
                        ? "Keeps this page unchanged"
                        : "Includes the detected margins"
                )
                : "This page stays unchanged because evidence is limited"
        )
    }

    private func evidenceValue(
        _ value: String,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.localizedUI)
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(PPColor.textPrimary)
                .lineLimit(1)
            Text(label.localizedUI)
                .font(.caption2)
                .foregroundStyle(PPColor.textSecondary)
                .lineLimit(1)
        }
    }

    private var bottomCommand: some View {
        VStack(spacing: PPSpacing.small) {
            if let progress = model.progress(for: recordID),
               applyTask != nil {
                LocalOperationProgressView(progress: progress)
            }

            Button {
                applyPreparation()
            } label: {
                Label(
                    applyTask == nil
                        ? AppLocalization.format(
                            "Prepare %lld Pages",
                            effectiveSelection.count
                        )
                        : "Applying Page Preparation".localizedUI,
                    systemImage: applyTask == nil
                        ? "rectangle.inset.filled"
                        : "hourglass"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(effectiveSelection.isEmpty || isBusy)
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

    private var suggestedPages: [PDFPagePreparationItem] {
        (assessment?.pages ?? []).filter {
            $0.isSuggested(safetyPadding: safetyPadding)
        }
    }

    private var filteredPages: [PDFPagePreparationItem] {
        switch reviewMode {
        case .changes:
            return suggestedPages
        case .all:
            return assessment?.pages ?? []
        }
    }

    private var effectiveSelection: Set<Int> {
        selectedPages.intersection(
            Set(suggestedPages.map(\.pageIndex))
        )
    }

    private var isBusy: Bool {
        analysisTask != nil || applyTask != nil
    }

    private func startAssessment() {
        analysisTask?.cancel()
        assessmentGeneration += 1
        let generation = assessmentGeneration
        assessment = nil
        selectedPages.removeAll()
        analysisTask = Task {
            let loaded = await model.pagePreparationAssessment(
                recordID: recordID
            )
            guard !Task.isCancelled,
                  generation == assessmentGeneration,
                  let loaded
            else {
                if generation == assessmentGeneration {
                    analysisTask = nil
                }
                return
            }
            assessment = loaded
            let suggestions = Set(
                loaded.pages.filter {
                    $0.isSuggested(
                        safetyPadding: safetyPadding
                    )
                }.map(\.pageIndex)
            )
            selectedPages = initialSelection.isEmpty
                ? suggestions
                : initialSelection.intersection(suggestions)
            withAnimation(
                reduceMotion ? nil : .easeOut(duration: 0.18)
            ) {
                analysisTask = nil
            }
        }
    }

    private func applyPreparation() {
        guard let assessment else { return }
        guard model.record(id: recordID)?.contentRevisionID
            == assessment.revisionID
        else {
            startAssessment()
            return
        }
        let selected = effectiveSelection
        let requests = Dictionary(
            assessment.pages.compactMap {
                item -> (Int, PDFPageCropInsets)? in
                guard selected.contains(item.pageIndex) else {
                    return nil
                }
                let proposed = item.proposedInsets(
                    safetyPadding: safetyPadding
                )
                guard proposed.isValid else { return nil }
                return (item.pageIndex, proposed)
            },
            uniquingKeysWith: { _, newest in newest }
        )
        guard !requests.isEmpty else { return }
        applyTask = Task {
            let succeeded = await model.cropPages(
                recordID: recordID,
                insetsByPage: requests
            )
            guard !Task.isCancelled else {
                applyTask = nil
                return
            }
            applyTask = nil
            guard succeeded else { return }
            dismiss()
            onComplete()
        }
    }

    private func stopWork() {
        assessmentGeneration += 1
        analysisTask?.cancel()
        applyTask?.cancel()
        analysisTask = nil
        applyTask = nil
    }
}

private struct PageCropEditorView: View {
    private enum CropPreset: String, CaseIterable, Identifiable {
        case none
        case light
        case standard
        case tight
        case custom

        var id: String { rawValue }
        var title: String { rawValue.capitalized }

        var insets: PDFPageCropInsets {
            let value: Double
            switch self {
            case .none: value = 0
            case .light: value = 0.02
            case .standard: value = 0.04
            case .tight: value = 0.08
            case .custom: value = 0
            }
            return PDFPageCropInsets(
                top: value,
                right: value,
                bottom: value,
                left: value
            )
        }
    }

    private enum Edge {
        case top
        case right
        case bottom
        case left
    }

    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let recordID: UUID
    let pageIndex: Int
    let onComplete: () -> Void

    @State private var insets =
        CropPreset.standard.insets
    @State private var preset = CropPreset.standard
    @State private var preview: UIImage?
    @State private var pageAspectRatio: CGFloat = 612 / 792
    @State private var isApplying = false
    @State private var operationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                cropSurface(availableSize: proxy.size)
            }
            .background(PPColor.canvas)
            .safeAreaInset(edge: .top, spacing: 0) {
                cropContextHeader
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                cropControls
            }
            .navigationTitle("Crop Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button((isApplying ? "Stop" : "Cancel").localizedUI) {
                        if isApplying {
                            operationTask?.cancel()
                            operationTask = nil
                            isApplying = false
                        } else {
                            dismiss()
                        }
                    }
                }
            }
            .task {
                guard let url = model.url(for: recordID) else {
                    return
                }
                let loaded =
                    await PDFEditorPreviewLoader.shared.preview(
                        url: url,
                        pageIndex: pageIndex,
                        revision: model.refreshToken(for: recordID),
                        longEdge: 1_800
                    )
                guard !Task.isCancelled, let loaded else {
                    return
                }
                preview = loaded.image
                pageAspectRatio = CGFloat(loaded.aspectRatio)
            }
            .onChange(of: preset) { _, value in
                guard value != .custom else { return }
                insets = value.insets
            }
            .interactiveDismissDisabled(isApplying)
            .onDisappear {
                operationTask?.cancel()
                operationTask = nil
            }
        }
    }

    private var cropContextHeader: some View {
        WorkflowCommandHeader(
            eyebrow: "PAGE GEOMETRY",
            title: AppLocalization.format(
                "Crop page %lld",
                pageIndex + 1
            ),
            detail: "Adjust the visible crop box in this private working copy.",
            symbol: "crop",
            tint: PPColor.cyan,
            metrics: [
                WorkflowMetric(
                    value: "\(Int(insets.retainedArea * 100))%",
                    label: "Retained",
                    symbol: "rectangle.inset.filled",
                    tint: insets.isValid
                        ? PPColor.mint
                        : PPColor.amber
                ),
                WorkflowMetric(
                    value:
                        "\(Int(insets.retainedWidth * 100))%",
                    label: "Width",
                    symbol: "arrow.left.and.right",
                    tint: PPColor.cyan
                ),
                WorkflowMetric(
                    value:
                        "\(Int(insets.retainedHeight * 100))%",
                    label: "Height",
                    symbol: "arrow.up.and.down",
                    tint: PPColor.accent
                ),
                WorkflowMetric(
                    value: preset.title,
                    label: "Preset",
                    symbol: "slider.horizontal.3",
                    tint: PPColor.textSecondary
                )
            ]
        )
        .padding(.horizontal, PPSpacing.regular)
        .padding(.top, PPSpacing.small)
    }

    private func cropSurface(
        availableSize: CGSize
    ) -> some View {
        let pageSize = fittedPageSize(in: availableSize)
        let cropRect = CGRect(
            x: CGFloat(insets.left) * pageSize.width,
            y: CGFloat(insets.top) * pageSize.height,
            width: CGFloat(insets.retainedWidth) * pageSize.width,
            height: CGFloat(insets.retainedHeight) * pageSize.height
        )
        return ZStack {
            PPColor.canvas
            ZStack {
                Color.white
                if let preview {
                    Image(uiImage: preview)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }

                cropMask(pageSize: pageSize, cropRect: cropRect)

                Rectangle()
                    .stroke(
                        insets.isValid
                            ? PPColor.cyan
                            : PPColor.amber,
                        style: StrokeStyle(
                            lineWidth: 2,
                            dash: [7, 3]
                        )
                    )
                    .frame(
                        width: cropRect.width,
                        height: cropRect.height
                    )
                    .position(
                        x: cropRect.midX,
                        y: cropRect.midY
                    )
            }
            .frame(width: pageSize.width, height: pageSize.height)
            .clipped()
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        }
    }

    private func cropMask(
        pageSize: CGSize,
        cropRect: CGRect
    ) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(
                    width: pageSize.width,
                    height: cropRect.minY
                )
                .position(
                    x: pageSize.width / 2,
                    y: cropRect.minY / 2
                )
            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(
                    width: pageSize.width,
                    height: pageSize.height - cropRect.maxY
                )
                .position(
                    x: pageSize.width / 2,
                    y: cropRect.maxY
                        + (pageSize.height - cropRect.maxY) / 2
                )
            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(
                    width: cropRect.minX,
                    height: cropRect.height
                )
                .position(
                    x: cropRect.minX / 2,
                    y: cropRect.midY
                )
            Rectangle()
                .fill(Color.black.opacity(0.42))
                .frame(
                    width: pageSize.width - cropRect.maxX,
                    height: cropRect.height
                )
                .position(
                    x: cropRect.maxX
                        + (pageSize.width - cropRect.maxX) / 2,
                    y: cropRect.midY
                )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var cropControls: some View {
        VStack(spacing: PPSpacing.small) {
            Picker("Crop preset", selection: $preset) {
                ForEach(
                    CropPreset.allCases.filter { $0 != .custom }
                ) { option in
                    Text(option.title.localizedUI).tag(option)
                }
            }
            .pickerStyle(.segmented)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: PPSpacing.medium),
                    GridItem(.flexible(), spacing: PPSpacing.medium)
                ],
                spacing: PPSpacing.small
            ) {
                edgeControl("Top", edge: .top)
                edgeControl("Bottom", edge: .bottom)
                edgeControl("Left", edge: .left)
                edgeControl("Right", edge: .right)
            }

            Button {
                applyCrop()
            } label: {
                Label(
                    isApplying ? "Applying Crop" : "Apply Crop",
                    systemImage: isApplying ? "hourglass" : "crop"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PPPrimaryButtonStyle())
            .disabled(
                isApplying
                    || !insets.isValid
                    || insets == .none
            )
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

    private func edgeControl(
        _ title: String,
        edge: Edge
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title.localizedUI)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(Int(value(for: edge) * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PPColor.cyan)
            }
            Slider(
                value: edgeBinding(edge),
                in: 0...0.35
            )
            .tint(PPColor.cyan)
        }
    }

    private func edgeBinding(_ edge: Edge) -> Binding<Double> {
        Binding(
            get: { value(for: edge) },
            set: { requested in
                preset = .custom
                setValue(requested, for: edge)
            }
        )
    }

    private func value(for edge: Edge) -> Double {
        switch edge {
        case .top: return insets.top
        case .right: return insets.right
        case .bottom: return insets.bottom
        case .left: return insets.left
        }
    }

    private func setValue(
        _ requested: Double,
        for edge: Edge
    ) {
        let value = min(max(0, requested), 0.35)
        switch edge {
        case .top:
            insets.top = min(value, 0.84 - insets.bottom)
        case .right:
            insets.right = min(value, 0.84 - insets.left)
        case .bottom:
            insets.bottom = min(value, 0.84 - insets.top)
        case .left:
            insets.left = min(value, 0.84 - insets.right)
        }
    }

    private func applyCrop() {
        guard insets.isValid else { return }
        isApplying = true
        let requestedInsets = insets
        operationTask = Task {
            let succeeded = await model.cropPage(
                recordID: recordID,
                index: pageIndex,
                insets: requestedInsets
            )
            guard !Task.isCancelled else {
                isApplying = false
                operationTask = nil
                return
            }
            isApplying = false
            operationTask = nil
            guard succeeded else { return }
            dismiss()
            onComplete()
        }
    }

    private func fittedPageSize(
        in availableSize: CGSize
    ) -> CGSize {
        let maximum = CGSize(
            width: max(1, availableSize.width - 32),
            height: max(1, availableSize.height - 24)
        )
        guard maximum.width / maximum.height > pageAspectRatio else {
            return CGSize(
                width: maximum.width,
                height: maximum.width / pageAspectRatio
            )
        }
        return CGSize(
            width: maximum.height * pageAspectRatio,
            height: maximum.height
        )
    }
}

private struct PageRangeSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let pageCount: Int
    let onSelect: (ClosedRange<Int>) -> Void

    @State private var startPage = 1
    @State private var endPage: Int

    init(
        pageCount: Int,
        onSelect: @escaping (ClosedRange<Int>) -> Void
    ) {
        self.pageCount = max(1, pageCount)
        self.onSelect = onSelect
        _endPage = State(initialValue: min(max(1, pageCount), 10))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(
                        "First page: \(startPage)",
                        value: $startPage,
                        in: 1...max(1, endPage)
                    )
                    Stepper(
                        "Last page: \(endPage)",
                        value: $endPage,
                        in: min(startPage, pageCount)...pageCount
                    )
                } footer: {
                    Text(
                        "\(max(0, endPage - startPage + 1)) pages will be selected."
                    )
                }
            }
            .navigationTitle("Select Page Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Select") {
                        onSelect(
                            (startPage - 1)...(endPage - 1)
                        )
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct PageCopyDestinationSheet: View {
    @EnvironmentObject private var model: PaperPathModel
    @Environment(\.dismiss) private var dismiss

    let sourceRecordID: UUID
    let selectedCount: Int
    let onSelect: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List(destinations) { record in
                Button {
                    onSelect(record.id)
                    dismiss()
                } label: {
                    HStack(spacing: PPSpacing.medium) {
                        Image(systemName: record.profile.kind.symbol)
                            .foregroundStyle(PPColor.accent)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.displayName)
                                .foregroundStyle(PPColor.textPrimary)
                                .lineLimit(1)
                            Text(
                                "\(record.profile.pageCount) pages · append \(selectedCount)"
                            )
                            .font(.caption)
                            .foregroundStyle(PPColor.textSecondary)
                        }
                    }
                }
            }
            .overlay {
                if destinations.isEmpty {
                    ContentUnavailableView(
                        "No destination PDF",
                        systemImage: "doc.on.doc",
                        description: Text(
                            "Import or create another PDF first."
                        )
                    )
                }
            }
            .navigationTitle("Copy Pages To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var destinations: [DocumentRecord] {
        model.documents.filter {
            $0.id != sourceRecordID
                && $0.isWorkingCopy
                && !$0.profile.isLocked
        }
    }
}
